//// A bounded, keyed executor for slow or expensive work.
////
//// Jobs with the same key run one at a time in FIFO order. Jobs with different
//// keys may run concurrently up to the configured global limit. Capacity
//// counts all accepted jobs, both active and queued.
////
//// Every accepted job has one outcome guard. The guard is the only process
//// that writes to the caller's outcome subject, so completion, cancellation,
//// and executor termination cannot publish competing terminal outcomes.
//// State and acknowledgements are intentionally volatile: an admission `Ok`
//// means only that the in-memory executor accepted the job, never that the job
//// completed or that its external effects happened exactly once.

import glammy/bot
import glammy/context
import glammy/internal/clock
import glammy/internal/ffi
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

const default_stop_timeout_ms = 5000

const default_admission_timeout_ms = 5000

const default_job_timeout_ms = 300_000

const actor_initialisation_timeout_ms = 1000

const forced_stop_confirmation_timeout_ms = 1000

/// Configuration for a keyed executor.
pub type Options {
  Options(
    /// Maximum number of jobs running at once across all keys.
    max_concurrency: Int,
    /// Maximum accepted jobs, counting both active and queued jobs.
    capacity: Int,
    /// Maximum time to obtain a linearized in-memory admission decision.
    /// Must be within BEAM's `1..4_294_967_295` millisecond range.
    admission_timeout_ms: Int,
    /// Maximum runtime of an active job, measured from its actual `Begin`.
    /// Must be within BEAM's `1..4_294_967_295` millisecond range.
    job_timeout_ms: Int,
    /// Maximum time `stop` waits before forcefully terminating the executor.
    /// Must be within BEAM's `1..4_294_967_295` millisecond range.
    stop_timeout_ms: Int,
  )
}

/// Failures raised before an executor starts.
pub type StartError {
  InvalidMaxConcurrency(Int)
  InvalidCapacity(Int)
  CapacityBelowConcurrency(capacity: Int, max_concurrency: Int)
  InvalidAdmissionTimeout(Int)
  InvalidJobTimeout(Int)
  InvalidStopTimeout(Int)
  StartFailed(String)
}

/// A job could not be admitted to the volatile in-memory executor.
pub type AdmissionError {
  /// Active plus queued jobs already equal the configured capacity.
  AtCapacity(capacity: Int)
  /// Shutdown has started, so no new jobs are accepted.
  ExecutorStopping
  /// The executor is no longer running.
  ExecutorNotRunning
  /// The request reached the executor after its admission deadline.
  AdmissionDeadlineExceeded
  /// Admission may have committed, but its acknowledgement was not observed.
  /// Await the job outcome or use application-owned idempotency before retrying.
  AdmissionOutcomeUnknown
}

/// The one terminal outcome emitted for every accepted job.
pub type JobOutcome(result) {
  /// The operation returned normally. `result` may itself be a typed `Result`.
  Completed(result)
  /// The operation panicked, threw, exited, or otherwise failed to report.
  Crashed(class: String, value: String, stacktrace: String)
  /// The runtime deadline expired. The actual user-operation process is
  /// confirmed down before this is observable. External effects that happened
  /// before termination may still have occurred.
  TimedOut(timeout_ms: Int)
  /// Shutdown won the scheduler race before completion was committed. This is
  /// not observable until the actual user-operation process is confirmed down.
  Cancelled
  /// The executor terminated outside its bounded normal stop protocol. This is
  /// not observable until any actual user-operation process is confirmed down.
  ExecutorTerminated
}

/// A bounded stop could not complete cleanly.
pub type StopError {
  /// The configured monitor barrier expired and forced termination was used.
  StopTimedOut
  /// The executor exited abnormally while stopping.
  StopFailed(String)
}

/// A running keyed executor.
pub opaque type Executor(key, result) {
  Executor(
    subject: Subject(ExecutorMessage(key, result)),
    pid: Pid,
    admission_timeout_ms: Int,
    stop_timeout_ms: Int,
    forced_stop_reason: String,
  )
}

type Job(key, result) {
  Job(
    key: key,
    operation: fn() -> result,
    outcome_guard: Subject(OutcomeGuardMessage(result)),
  )
}

type RunningJob(key, result) {
  RunningJob(
    job: Job(key, result),
    task_pid: Pid,
    worker_monitor: Monitor,
    task_monitor: Monitor,
    reported: Option(JobOutcome(result)),
    worker_down: Option(process.ExitReason),
    task_down: Option(process.ExitReason),
  )
}

type ExecutorState(key, result) {
  ExecutorState(
    subject: Subject(ExecutorMessage(key, result)),
    max_concurrency: Int,
    capacity: Int,
    job_timeout_ms: Int,
    accepted: Int,
    pending: Dict(key, Fifo(Job(key, result))),
    ready_keys: Fifo(key),
    active_keys: Dict(key, Pid),
    running: Dict(Pid, RunningJob(key, result)),
    tasks: Dict(Pid, Pid),
    stopping: Bool,
    stop_waiters: List(Subject(Nil)),
  )
}

type ExecutorMessage(key, result) {
  Submit(
    key: key,
    operation: fn() -> result,
    outcome: Subject(JobOutcome(result)),
    deadline_ms: Int,
    caller_pid: Pid,
    began: Subject(Nil),
    reply_to: Subject(Result(Nil, AdmissionError)),
  )
  WorkerReported(
    worker_pid: Pid,
    outcome: JobOutcome(result),
    reply_to: Subject(Nil),
  )
  WorkerDown(process.Down)
  Stop(reply_to: Subject(Nil))
}

type OutcomeGuardMessage(result) {
  Accept
  RegisterWorker(worker_pid: Pid, reply_to: Subject(Nil))
  AttachTask(task_pid: Pid, reply_to: Subject(Nil))
  Deliver(outcome: JobOutcome(result), reply_to: Subject(Nil))
  Dismiss
}

type OutcomeGuardEvent(result) {
  GuardAccepted
  GuardWorkerRegistered(worker_pid: Pid, reply_to: Subject(Nil))
  GuardTaskAttached(task_pid: Pid, reply_to: Subject(Nil))
  GuardDelivery(outcome: JobOutcome(result), reply_to: Subject(Nil))
  GuardDismissed
  GuardExecutorDown(process.Down)
  GuardWorkerDown(process.Down)
  GuardTaskDown(process.Down)
}

type GuardWorker {
  GuardWorker(pid: Pid, monitor: Monitor, down: Bool)
}

type OutcomeGuardStartEvent(result) {
  OutcomeGuardStarted(Subject(OutcomeGuardMessage(result)))
  OutcomeGuardStartDown(process.Down)
}

type GuardTask {
  GuardTask(pid: Pid, monitor: Monitor, down: Bool)
}

type Fifo(value) {
  Fifo(front: List(value), back: List(value))
}

/// Build options with a five-minute job deadline and five-second admission and
/// stop deadlines.
pub fn default_options(max_concurrency: Int, capacity: Int) -> Options {
  Options(
    max_concurrency:,
    capacity:,
    admission_timeout_ms: default_admission_timeout_ms,
    job_timeout_ms: default_job_timeout_ms,
    stop_timeout_ms: default_stop_timeout_ms,
  )
}

/// Start a keyed executor with the default finite lifecycle deadlines.
pub fn start(
  max_concurrency: Int,
  capacity: Int,
) -> Result(Executor(key, result), StartError) {
  start_with_options(default_options(max_concurrency, capacity))
}

/// Start a keyed executor with explicit lifecycle options.
pub fn start_with_options(
  options: Options,
) -> Result(Executor(key, result), StartError) {
  use _ <- result.try(validate_options(options))
  actor.new_with_initialiser(actor_initialisation_timeout_ms, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(WorkerDown)
    let state =
      ExecutorState(
        subject:,
        max_concurrency: options.max_concurrency,
        capacity: options.capacity,
        job_timeout_ms: options.job_timeout_ms,
        accepted: 0,
        pending: dict.new(),
        ready_keys: fifo_new(),
        active_keys: dict.new(),
        running: dict.new(),
        tasks: dict.new(),
        stopping: False,
        stop_waiters: [],
      )
    actor.initialised(state)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) {
    // The handle owns the lifecycle. Worker and outcome guards monitor this
    // pid, while an unrelated starter-process exit must not orphan accepted
    // work without a terminal outcome.
    process.unlink(started.pid)
    let forced_stop_reason =
      "glammy-keyed-executor-forced-stop:" <> string.inspect(reference.new())
    Executor(
      subject: started.data,
      pid: started.pid,
      admission_timeout_ms: options.admission_timeout_ms,
      stop_timeout_ms: options.stop_timeout_ms,
      forced_stop_reason:,
    )
  })
  |> result.map_error(fn(error) { StartFailed(string.inspect(error)) })
}

fn validate_options(options: Options) -> Result(Nil, StartError) {
  case options.max_concurrency > 0 {
    False -> Error(InvalidMaxConcurrency(options.max_concurrency))
    True ->
      case options.capacity > 0 {
        False -> Error(InvalidCapacity(options.capacity))
        True ->
          case options.capacity >= options.max_concurrency {
            False ->
              Error(CapacityBelowConcurrency(
                capacity: options.capacity,
                max_concurrency: options.max_concurrency,
              ))
            True ->
              case
                clock.is_valid_process_timeout(options.admission_timeout_ms)
              {
                False ->
                  Error(InvalidAdmissionTimeout(options.admission_timeout_ms))
                True ->
                  case clock.is_valid_process_timeout(options.job_timeout_ms) {
                    False -> Error(InvalidJobTimeout(options.job_timeout_ms))
                    True ->
                      case
                        clock.is_valid_process_timeout(options.stop_timeout_ms)
                      {
                        True -> Ok(Nil)
                        False ->
                          Error(InvalidStopTimeout(options.stop_timeout_ms))
                      }
                  }
              }
          }
      }
  }
}

/// Admit a job for `key`, or return typed backpressure.
///
/// `Ok(Nil)` is only a linearized receipt that the volatile in-memory queue
/// accepted the job. Completion is reported exactly once to `outcome`. The
/// subject may be owned by an application actor, making this suitable for
/// submitting slow LLM work without raw fire-and-forget processes.
pub fn submit(
  executor: Executor(key, result),
  key: key,
  operation: fn() -> result,
  outcome: Subject(JobOutcome(result)),
) -> Result(Nil, AdmissionError) {
  let caller_pid = process.self()
  case process.is_alive(executor.pid) {
    False -> Error(ExecutorNotRunning)
    True -> {
      // A broker owns all short-lived reply subjects. Timeout races therefore
      // cannot leak late admission messages into a long-lived bot process.
      let result_subject = process.new_subject()
      let deadline_ms = clock.deadline_after(executor.admission_timeout_ms)
      let broker =
        process.spawn_unlinked(fn() {
          process.send(
            result_subject,
            submit_from_broker(
              executor,
              key,
              operation,
              outcome,
              deadline_ms,
              caller_pid,
            ),
          )
        })
      let monitor = process.monitor(broker)
      let selector =
        process.new_selector()
        |> process.select_map(result_subject, AdmissionBrokerReply)
        |> process.select_specific_monitor(monitor, AdmissionBrokerDown)
      let response = process.selector_receive_forever(selector)
      process.demonitor_process(monitor)
      case response {
        AdmissionBrokerReply(result) -> result
        AdmissionBrokerDown(_) -> Error(AdmissionOutcomeUnknown)
      }
    }
  }
}

fn submit_from_broker(
  executor: Executor(key, result),
  key: key,
  operation: fn() -> result,
  outcome: Subject(JobOutcome(result)),
  deadline_ms: Int,
  caller_pid: Pid,
) -> Result(Nil, AdmissionError) {
  let reply = process.new_subject()
  let began = process.new_subject()
  let executor_monitor = process.monitor(executor.pid)
  let caller_monitor = process.monitor(caller_pid)
  actor.send(
    executor.subject,
    Submit(
      key:,
      operation:,
      outcome:,
      deadline_ms:,
      caller_pid:,
      began:,
      reply_to: reply,
    ),
  )
  let selector =
    process.new_selector()
    |> process.select_map(reply, AdmissionReply)
    |> process.select_map(began, fn(_) { AdmissionBegan })
    |> process.select_specific_monitor(executor_monitor, AdmissionExecutorDown)
    |> process.select_specific_monitor(caller_monitor, AdmissionCallerDown)
  let response = await_admission(selector, deadline_ms, False)
  process.demonitor_process(executor_monitor)
  process.demonitor_process(caller_monitor)
  response
}

fn await_admission(
  selector: process.Selector(AdmissionCallOutcome),
  deadline_ms: Int,
  admission_began: Bool,
) -> Result(Nil, AdmissionError) {
  case
    process.selector_receive(selector, within: clock.remaining_ms(deadline_ms))
  {
    Ok(AdmissionReply(result)) -> result
    Ok(AdmissionBegan) -> await_admission(selector, deadline_ms, True)
    Ok(AdmissionExecutorDown(_)) if admission_began ->
      Error(AdmissionOutcomeUnknown)
    Ok(AdmissionExecutorDown(_)) -> Error(ExecutorNotRunning)
    Ok(AdmissionCallerDown(_)) -> Error(AdmissionDeadlineExceeded)
    Error(Nil) if admission_began -> Error(AdmissionOutcomeUnknown)
    Error(Nil) -> Error(AdmissionDeadlineExceeded)
  }
}

/// Context-friendly admission using a key and operation derived from a value.
///
/// For a bot handler, `value` can be `glammy/context.Context`, `key_fn` can
/// select a chat or user id, and `operation` can perform the slow LLM call.
pub fn submit_with_key(
  executor: Executor(key, result),
  value: value,
  key_fn: fn(value) -> key,
  operation: fn(value) -> result,
  outcome: Subject(JobOutcome(result)),
) -> Result(Nil, AdmissionError) {
  submit(executor, key_fn(value), fn() { operation(value) }, outcome)
}

/// Derive the canonical per-chat executor key from a bot context.
///
/// Updates without a Telegram chat id return `None` and therefore pass through
/// an `update_gate` that uses this helper.
pub fn by_chat_id(ctx: context.Context) -> Option(String) {
  case context.chat_id(ctx) {
    Some(chat_id) -> Some(int.to_string(chat_id))
    None -> None
  }
}

/// Return the scheduler pid for OTP supervision, monitoring, and diagnostics.
///
/// Killing this process is an abnormal lifecycle path. Accepted jobs still
/// receive `ExecutorTerminated` through their outcome guards.
pub fn process_id(executor: Executor(key, result)) -> Pid {
  executor.pid
}

/// Build a fail-closed bot gate backed by this executor.
///
/// `None` from `key_fn` leaves the update on the normal middleware path.
/// `Some(key)` transfers ownership of the entire update to `operation`; after
/// admission the ordinary bot composer is not run. Use a selective key
/// function, or explicitly run the intended sub-composer inside `operation`.
/// Accepted work consumes the update only after the volatile admission ACK.
/// Backpressure, timeout, uncertain admission, and lifecycle failures become a
/// typed `UpdateGateError`, so polling retains the update instead of advancing.
/// Register specialized owners such as `conversations.update_gate` first;
/// otherwise this broader gate can consume their replies before they route.
pub fn update_gate(
  executor: Executor(key, result),
  key_fn: fn(context.Context) -> Option(key),
  operation: fn(context.Context) -> result,
  outcomes: Subject(JobOutcome(result)),
) -> bot.UpdateGate {
  fn(ctx) {
    case key_fn(ctx) {
      None -> Ok(bot.Continue)
      Some(key) ->
        case submit(executor, key, fn() { operation(ctx) }, outcomes) {
          Ok(Nil) -> Ok(bot.Consumed)
          Error(error) ->
            Error(bot.UpdateGateError(
              admission_error_code(error),
              admission_error_message(error),
            ))
        }
    }
  }
}

/// Stable machine code used by `update_gate` for an admission failure.
pub fn admission_error_code(error: AdmissionError) -> String {
  case error {
    AtCapacity(_) -> "keyed_executor_capacity"
    ExecutorStopping -> "keyed_executor_stopping"
    ExecutorNotRunning -> "keyed_executor_stopped"
    AdmissionDeadlineExceeded -> "keyed_executor_admission_timeout"
    AdmissionOutcomeUnknown -> "keyed_executor_admission_unknown"
  }
}

/// Operator-facing description used by `update_gate`.
pub fn admission_error_message(error: AdmissionError) -> String {
  case error {
    AtCapacity(capacity) ->
      "keyed executor reached active-plus-queued capacity "
      <> string.inspect(capacity)
    ExecutorStopping -> "keyed executor is stopping"
    ExecutorNotRunning -> "keyed executor is not running"
    AdmissionDeadlineExceeded -> "keyed executor admission deadline expired"
    AdmissionOutcomeUnknown ->
      "keyed executor admission outcome is unknown; reconcile before retry"
  }
}

type AdmissionCallOutcome {
  AdmissionReply(Result(Nil, AdmissionError))
  AdmissionBegan
  AdmissionExecutorDown(process.Down)
  AdmissionCallerDown(process.Down)
}

type AdmissionBrokerOutcome {
  AdmissionBrokerReply(Result(Nil, AdmissionError))
  AdmissionBrokerDown(process.Down)
}

/// Cancel queued work, terminate active workers, and wait for the monitor
/// barrier. Calls are idempotent. Callers already waiting on the same live
/// scheduler classify its single `DOWN` reason identically; calls that begin
/// after the scheduler terminated return `Ok(Nil)`.
///
/// If the configured deadline expires, the scheduler is forcefully terminated.
/// A job keeps a completion or cancellation already chosen by its guard;
/// otherwise that same guard publishes `ExecutorTerminated`. `Cancelled` and
/// `ExecutorTerminated` are published only after the real user-operation
/// process is confirmed down, even if it traps exits.
pub fn stop(executor: Executor(key, result)) -> Result(Nil, StopError) {
  // Install the monitor without a preceding liveness check. If termination
  // already won, BEAM reports `noproc`, which is the idempotent stopped state;
  // if it happens afterwards, this monitor retains the real exit reason.
  let reply = process.new_subject()
  let monitor = process.monitor(executor.pid)
  let deadline_ms = clock.deadline_after(executor.stop_timeout_ms)
  actor.send(executor.subject, Stop(reply))
  let selector =
    process.new_selector()
    |> process.select_map(reply, StopReply)
    |> process.select_specific_monitor(monitor, StopExecutorDown)
  case await_stop_down(selector, deadline_ms) {
    Ok(down) -> {
      process.demonitor_process(monitor)
      stop_result_from_reason(down_reason(down), executor.forced_stop_reason)
    }
    Error(Nil) -> {
      process.send_abnormal_exit(executor.pid, executor.forced_stop_reason)
      let confirmation =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
      let result = case
        process.selector_receive(
          confirmation,
          within: forced_stop_confirmation_timeout_ms,
        )
      {
        Ok(down) ->
          stop_result_from_reason(
            down_reason(down),
            executor.forced_stop_reason,
          )
        Error(Nil) -> Error(StopTimedOut)
      }
      process.demonitor_process(monitor)
      result
    }
  }
}

fn await_stop_down(
  selector: process.Selector(StopCallOutcome),
  deadline_ms: Int,
) -> Result(process.Down, Nil) {
  case
    process.selector_receive(selector, within: clock.remaining_ms(deadline_ms))
  {
    Ok(StopReply(Nil)) ->
      // A reply is only a progress signal. The actor's single DOWN reason is
      // the stop linearization point shared by all waiting callers.
      await_stop_down(selector, deadline_ms)
    Ok(StopExecutorDown(down)) -> Ok(down)
    Error(Nil) -> Error(Nil)
  }
}

fn stop_result_from_reason(
  reason: process.ExitReason,
  forced_stop_reason: String,
) -> Result(Nil, StopError) {
  case reason {
    process.Normal -> Ok(Nil)
    reason ->
      case is_noproc(reason), is_forced_stop(reason, forced_stop_reason) {
        // A monitor installed after termination has no historical exit reason.
        // For an idempotent stop this is the same state as the liveness fast path.
        True, _ -> Ok(Nil)
        // Another concurrent caller may have won this executor's private
        // forced-stop race. All live-barrier observers converge.
        False, True -> Error(StopTimedOut)
        False, False -> Error(StopFailed(describe_exit_reason(reason)))
      }
  }
}

fn is_noproc(reason: process.ExitReason) -> Bool {
  case reason {
    process.Abnormal(value) ->
      case decode.run(value, atom.decoder()) {
        Ok(value) -> atom.to_string(value) == "noproc"
        Error(_) -> False
      }
    _ -> False
  }
}

fn is_forced_stop(reason: process.ExitReason, expected: String) -> Bool {
  case reason {
    process.Abnormal(value) -> decode.run(value, decode.string) == Ok(expected)
    _ -> False
  }
}

type StopCallOutcome {
  StopReply(Nil)
  StopExecutorDown(process.Down)
}

fn handle_message(
  state: ExecutorState(key, result),
  message: ExecutorMessage(key, result),
) -> actor.Next(ExecutorState(key, result), ExecutorMessage(key, result)) {
  case message {
    Submit(
      key:,
      operation:,
      outcome:,
      deadline_ms:,
      caller_pid:,
      began:,
      reply_to:,
    ) ->
      handle_submit(
        state,
        key,
        operation,
        outcome,
        deadline_ms,
        caller_pid,
        began,
        reply_to,
      )
    WorkerReported(worker_pid:, outcome:, reply_to:) ->
      handle_worker_report(state, worker_pid, outcome, reply_to)
    WorkerDown(down) -> handle_worker_down(state, down)
    Stop(reply_to:) -> handle_stop(state, reply_to)
  }
}

fn handle_submit(
  state: ExecutorState(key, result),
  key: key,
  operation: fn() -> result,
  outcome: Subject(JobOutcome(result)),
  deadline_ms: Int,
  caller_pid: Pid,
  began: Subject(Nil),
  reply_to: Subject(Result(Nil, AdmissionError)),
) -> actor.Next(ExecutorState(key, result), ExecutorMessage(key, result)) {
  case
    clock.expired(deadline_ms),
    state.stopping,
    state.accepted >= state.capacity
  {
    True, _, _ -> {
      process.send(reply_to, Error(AdmissionDeadlineExceeded))
      actor.continue(state)
    }
    False, True, _ -> {
      process.send(reply_to, Error(ExecutorStopping))
      actor.continue(state)
    }
    False, False, True -> {
      process.send(reply_to, Error(AtCapacity(state.capacity)))
      actor.continue(state)
    }
    False, False, False -> {
      case start_outcome_guard(process.self(), outcome, deadline_ms) {
        Error(Nil) -> {
          process.send(reply_to, Error(AdmissionDeadlineExceeded))
          actor.continue(state)
        }
        Ok(guard) -> {
          // The marker is deliberately before the authoritative deadline and
          // caller-liveness check. Once it is observed, a lost reply is typed
          // as uncertain; without it, this actor can only reject stale work.
          process.send(began, Nil)
          case clock.expired(deadline_ms) || !process.is_alive(caller_pid) {
            True -> {
              process.send(guard, Dismiss)
              process.send(reply_to, Error(AdmissionDeadlineExceeded))
              actor.continue(state)
            }
            False -> {
              process.send(guard, Accept)
              let job = Job(key:, operation:, outcome_guard: guard)
              let state = enqueue_job(state, job) |> dispatch_available
              // This acknowledgement is deliberately after the job is
              // represented in scheduler state. It is not completion or
              // durable persistence.
              process.send(reply_to, Ok(Nil))
              actor.continue(state)
            }
          }
        }
      }
    }
  }
}

fn enqueue_job(
  state: ExecutorState(key, result),
  job: Job(key, result),
) -> ExecutorState(key, result) {
  let had_pending = dict.has_key(state.pending, job.key)
  let queue =
    dict.get(state.pending, job.key)
    |> result.unwrap(fifo_new())
    |> fifo_push(job)
  let pending = dict.insert(state.pending, job.key, queue)
  let ready_keys = case
    dict.has_key(state.active_keys, job.key) || had_pending
  {
    True -> state.ready_keys
    False -> fifo_push(state.ready_keys, job.key)
  }
  ExecutorState(..state, accepted: state.accepted + 1, pending:, ready_keys:)
}

fn dispatch_available(
  state: ExecutorState(key, result),
) -> ExecutorState(key, result) {
  case dict.size(state.running) >= state.max_concurrency {
    True -> state
    False ->
      case fifo_pop(state.ready_keys) {
        Error(Nil) -> state
        Ok(#(key, ready_keys)) ->
          case dict.get(state.pending, key) {
            Error(Nil) ->
              dispatch_available(ExecutorState(..state, ready_keys:))
            Ok(queue) -> {
              let assert Ok(#(job, remaining)) = fifo_pop(queue)
              let pending = case fifo_is_empty(remaining) {
                True -> dict.delete(state.pending, key)
                False -> dict.insert(state.pending, key, remaining)
              }
              case
                start_worker(
                  state.subject,
                  process.self(),
                  job.operation,
                  job.outcome_guard,
                )
              {
                Error(outcome) -> {
                  // The accepted job failed before a running handle existed.
                  // Publish its guarded terminal outcome, release capacity,
                  // and keep this key eligible for its remaining FIFO tail.
                  deliver_outcome(job.outcome_guard, outcome)
                  let ready_keys = case dict.has_key(pending, key) {
                    True -> fifo_push(ready_keys, key)
                    False -> ready_keys
                  }
                  ExecutorState(
                    ..state,
                    accepted: state.accepted - 1,
                    pending:,
                    ready_keys:,
                  )
                  |> dispatch_available
                }
                Ok(WorkerHandle(worker_pid:, task_pid:, begin:)) -> {
                  let worker_monitor = process.monitor(worker_pid)
                  let task_monitor = process.monitor(task_pid)
                  let running_job =
                    RunningJob(
                      job:,
                      task_pid:,
                      worker_monitor:,
                      task_monitor:,
                      reported: None,
                      worker_down: None,
                      task_down: None,
                    )
                  let state =
                    ExecutorState(
                      ..state,
                      pending:,
                      ready_keys:,
                      active_keys: dict.insert(
                        state.active_keys,
                        key,
                        worker_pid,
                      ),
                      running: dict.insert(
                        state.running,
                        worker_pid,
                        running_job,
                      ),
                      tasks: dict.insert(state.tasks, task_pid, worker_pid),
                    )
                  process.send(begin, Begin(state.job_timeout_ms))
                  state
                  |> dispatch_available
                }
              }
            }
          }
      }
  }
}

fn handle_worker_report(
  state: ExecutorState(key, result),
  worker_pid: Pid,
  outcome: JobOutcome(result),
  reply_to: Subject(Nil),
) -> actor.Next(ExecutorState(key, result), ExecutorMessage(key, result)) {
  process.send(reply_to, Nil)
  case dict.get(state.running, worker_pid) {
    Error(Nil) -> actor.continue(state)
    Ok(running_job) -> {
      let reported = case state.stopping {
        // Stop is the linearization winner if its message was handled first.
        True -> running_job.reported
        False -> Some(outcome)
      }
      actor.continue(
        ExecutorState(
          ..state,
          running: dict.insert(
            state.running,
            worker_pid,
            RunningJob(..running_job, reported:),
          ),
        ),
      )
    }
  }
}

fn handle_worker_down(
  state: ExecutorState(key, result),
  down: process.Down,
) -> actor.Next(ExecutorState(key, result), ExecutorMessage(key, result)) {
  case down_pid(down) {
    None -> actor.continue(state)
    Some(pid) ->
      case dict.get(state.running, pid) {
        Ok(running_job) -> {
          // A wrapper must never be the lifetime authority for user code. If
          // it disappears, hard-kill the actual task and wait for task DOWN.
          case running_job.task_down {
            None -> process.kill(running_job.task_pid)
            Some(_) -> Nil
          }
          let running_job =
            RunningJob(..running_job, worker_down: Some(down_reason(down)))
          let state =
            ExecutorState(
              ..state,
              running: dict.insert(state.running, pid, running_job),
            )
          finish_running_if_down(state, pid)
        }
        Error(Nil) ->
          case dict.get(state.tasks, pid) {
            Error(Nil) -> actor.continue(state)
            Ok(worker_pid) ->
              case dict.get(state.running, worker_pid) {
                Error(Nil) -> actor.continue(state)
                Ok(running_job) -> {
                  let running_job =
                    RunningJob(
                      ..running_job,
                      task_down: Some(down_reason(down)),
                    )
                  let state =
                    ExecutorState(
                      ..state,
                      running: dict.insert(
                        state.running,
                        worker_pid,
                        running_job,
                      ),
                    )
                  finish_running_if_down(state, worker_pid)
                }
              }
          }
      }
  }
}

fn finish_running_if_down(
  state: ExecutorState(key, result),
  worker_pid: Pid,
) -> actor.Next(ExecutorState(key, result), ExecutorMessage(key, result)) {
  case dict.get(state.running, worker_pid) {
    Error(Nil) -> actor.continue(state)
    Ok(running_job) ->
      case running_job.worker_down, running_job.task_down {
        Some(worker_reason), Some(_) -> {
          process.demonitor_process(running_job.worker_monitor)
          process.demonitor_process(running_job.task_monitor)
          let outcome = case running_job.reported, state.stopping {
            Some(outcome), _ -> outcome
            None, True -> Cancelled
            None, False -> crash_from_exit(worker_reason)
          }
          // Both the supervisor and the actual user-code process are confirmed
          // DOWN before any terminal outcome or key release is observable.
          deliver_outcome(running_job.job.outcome_guard, outcome)
          let pending_has_key = dict.has_key(state.pending, running_job.job.key)
          let ready_keys = case state.stopping || !pending_has_key {
            True -> state.ready_keys
            False -> fifo_push(state.ready_keys, running_job.job.key)
          }
          let state =
            ExecutorState(
              ..state,
              accepted: state.accepted - 1,
              ready_keys:,
              active_keys: dict.delete(state.active_keys, running_job.job.key),
              running: dict.delete(state.running, worker_pid),
              tasks: dict.delete(state.tasks, running_job.task_pid),
            )
          case state.stopping && dict.is_empty(state.running) {
            True -> finish_stop(state)
            False -> actor.continue(dispatch_available(state))
          }
        }
        _, _ -> actor.continue(state)
      }
  }
}

fn handle_stop(
  state: ExecutorState(key, result),
  reply_to: Subject(Nil),
) -> actor.Next(ExecutorState(key, result), ExecutorMessage(key, result)) {
  case state.stopping {
    True ->
      actor.continue(
        ExecutorState(..state, stop_waiters: [reply_to, ..state.stop_waiters]),
      )
    False -> {
      let queued = pending_jobs(state.pending)
      list.each(queued, fn(job) {
        deliver_outcome(job.outcome_guard, Cancelled)
      })
      dict.to_list(state.running)
      |> list.each(fn(entry) {
        let #(worker_pid, running_job) = entry
        // `kill` is untrappable. Killing the actual task directly prevents a
        // user operation that enabled `trap_exits` from surviving its wrapper.
        process.kill(running_job.task_pid)
        process.kill(worker_pid)
      })
      let state =
        ExecutorState(
          ..state,
          accepted: dict.size(state.running),
          pending: dict.new(),
          ready_keys: fifo_new(),
          stopping: True,
          stop_waiters: [reply_to],
        )
      case dict.is_empty(state.running) {
        True -> finish_stop(state)
        False -> actor.continue(state)
      }
    }
  }
}

fn finish_stop(
  state: ExecutorState(key, result),
) -> actor.Next(ExecutorState(key, result), ExecutorMessage(key, result)) {
  list.each(state.stop_waiters, fn(waiter) { process.send(waiter, Nil) })
  actor.stop()
}

fn pending_jobs(
  pending: Dict(key, Fifo(Job(key, result))),
) -> List(Job(key, result)) {
  dict.values(pending)
  |> list.fold([], fn(jobs, queue) { list.append(jobs, fifo_to_list(queue)) })
}

fn start_outcome_guard(
  executor_pid: Pid,
  target: Subject(JobOutcome(result)),
  deadline_ms: Int,
) -> Result(Subject(OutcomeGuardMessage(result)), Nil) {
  let ready: Subject(Subject(OutcomeGuardMessage(result))) =
    process.new_subject()
  let guard_pid =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      let monitor = process.monitor(executor_pid)
      let selector =
        process.new_selector()
        |> process.select_map(subject, fn(message) {
          case message {
            Accept -> GuardAccepted
            RegisterWorker(worker_pid:, reply_to:) ->
              GuardWorkerRegistered(worker_pid:, reply_to:)
            AttachTask(task_pid:, reply_to:) ->
              GuardTaskAttached(task_pid:, reply_to:)
            Deliver(outcome:, reply_to:) -> GuardDelivery(outcome:, reply_to:)
            Dismiss -> GuardDismissed
          }
        })
        |> process.select_specific_monitor(monitor, GuardExecutorDown)
      process.send(ready, subject)
      run_outcome_guard(selector, monitor, target, False, False, None, None)
    })
  let guard_monitor = process.monitor(guard_pid)
  let selector =
    process.new_selector()
    |> process.select_map(ready, OutcomeGuardStarted)
    |> process.select_specific_monitor(guard_monitor, OutcomeGuardStartDown)
  let result =
    process.selector_receive(selector, within: clock.remaining_ms(deadline_ms))
  process.demonitor_process(guard_monitor)
  case result {
    Ok(OutcomeGuardStarted(subject)) -> Ok(subject)
    Ok(OutcomeGuardStartDown(_)) | Error(Nil) -> {
      process.kill(guard_pid)
      Error(Nil)
    }
  }
}

fn run_outcome_guard(
  selector: process.Selector(OutcomeGuardEvent(result)),
  executor_monitor: Monitor,
  target: Subject(JobOutcome(result)),
  accepted: Bool,
  executor_down: Bool,
  worker: Option(GuardWorker),
  task: Option(GuardTask),
) -> Nil {
  case process.selector_receive_forever(selector) {
    GuardAccepted ->
      run_outcome_guard(
        selector,
        executor_monitor,
        target,
        True,
        executor_down,
        worker,
        task,
      )
    GuardWorkerRegistered(worker_pid:, reply_to:) -> {
      let worker_monitor = process.monitor(worker_pid)
      let selector =
        process.select_specific_monitor(
          selector,
          worker_monitor,
          GuardWorkerDown,
        )
      // A worker cannot create the user task until this monitor is installed.
      // Therefore executor DOWN may publish immediately only when no worker
      // has crossed this acknowledgement barrier.
      process.send(reply_to, Nil)
      run_outcome_guard(
        selector,
        executor_monitor,
        target,
        accepted,
        executor_down,
        Some(GuardWorker(worker_pid, worker_monitor, False)),
        task,
      )
    }
    GuardTaskAttached(task_pid:, reply_to:) -> {
      let task_monitor = process.monitor(task_pid)
      let selector =
        process.select_specific_monitor(selector, task_monitor, GuardTaskDown)
      process.send(reply_to, Nil)
      case executor_down {
        True -> process.kill(task_pid)
        False -> Nil
      }
      run_outcome_guard(
        selector,
        executor_monitor,
        target,
        accepted,
        executor_down,
        worker,
        Some(GuardTask(task_pid, task_monitor, False)),
      )
    }
    GuardWorkerDown(_) ->
      case worker {
        None ->
          run_outcome_guard(
            selector,
            executor_monitor,
            target,
            accepted,
            executor_down,
            worker,
            task,
          )
        Some(GuardWorker(pid:, monitor: worker_monitor, ..)) -> {
          let worker = Some(GuardWorker(pid, worker_monitor, True))
          case executor_down {
            True ->
              finish_guard_after_executor_down(
                executor_monitor,
                target,
                accepted,
                worker,
                task,
              )
            False ->
              run_outcome_guard(
                selector,
                executor_monitor,
                target,
                accepted,
                executor_down,
                worker,
                task,
              )
          }
        }
      }
    GuardTaskDown(_) ->
      case task {
        None ->
          run_outcome_guard(
            selector,
            executor_monitor,
            target,
            accepted,
            executor_down,
            worker,
            task,
          )
        Some(GuardTask(pid:, monitor: task_monitor, ..)) ->
          run_outcome_guard(
            selector,
            executor_monitor,
            target,
            accepted,
            executor_down,
            worker,
            Some(GuardTask(pid, task_monitor, True)),
          )
      }
    GuardDismissed -> {
      ensure_guard_task_down(task, True)
      ensure_guard_worker_down(worker)
      process.demonitor_process(executor_monitor)
    }
    GuardDelivery(outcome:, reply_to:) -> {
      ensure_guard_task_down(task, False)
      ensure_guard_worker_down(worker)
      process.demonitor_process(executor_monitor)
      case accepted {
        True -> process.send(target, outcome)
        False -> Nil
      }
      process.send(reply_to, Nil)
    }
    GuardExecutorDown(_) -> {
      case worker {
        // A worker must register and be monitored before it may create the
        // task. If no worker crossed that barrier, no user process can start
        // after this outcome even when a late registration message exists.
        None ->
          finish_guard_after_executor_down(
            executor_monitor,
            target,
            accepted,
            worker,
            task,
          )
        Some(GuardWorker(down: True, ..)) ->
          finish_guard_after_executor_down(
            executor_monitor,
            target,
            accepted,
            worker,
            task,
          )
        Some(_) ->
          // The registered worker owns the startup race and confirms any task
          // down before it exits. Keep serving AttachTask while awaiting its
          // monitor rather than publishing a premature terminal outcome.
          run_outcome_guard(
            selector,
            executor_monitor,
            target,
            accepted,
            True,
            worker,
            task,
          )
      }
    }
  }
}

fn finish_guard_after_executor_down(
  executor_monitor: Monitor,
  target: Subject(JobOutcome(result)),
  accepted: Bool,
  worker: Option(GuardWorker),
  task: Option(GuardTask),
) -> Nil {
  // A registered worker exits only after its task is down. The direct task
  // monitor remains the final defence against a wrapper protocol failure.
  ensure_guard_task_down(task, True)
  ensure_guard_worker_down(worker)
  process.demonitor_process(executor_monitor)
  case accepted {
    True -> process.send(target, ExecutorTerminated)
    False -> Nil
  }
}

fn deliver_outcome(
  guard: Subject(OutcomeGuardMessage(result)),
  outcome: JobOutcome(result),
) -> Nil {
  let delivered = process.new_subject()
  process.send(guard, Deliver(outcome:, reply_to: delivered))
  process.receive_forever(delivered)
}

fn ensure_guard_task_down(task: Option(GuardTask), kill: Bool) -> Nil {
  case task {
    None -> Nil
    Some(GuardTask(monitor:, down: True, ..)) ->
      process.demonitor_process(monitor)
    Some(GuardTask(pid:, monitor:, down: False)) -> {
      case kill {
        True -> process.kill(pid)
        False -> Nil
      }
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
      let _ = process.selector_receive_forever(selector)
      process.demonitor_process(monitor)
    }
  }
}

fn ensure_guard_worker_down(worker: Option(GuardWorker)) -> Nil {
  case worker {
    None -> Nil
    Some(GuardWorker(monitor:, down: True, ..)) ->
      process.demonitor_process(monitor)
    Some(GuardWorker(monitor:, down: False, ..)) -> {
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
      let _ = process.selector_receive_forever(selector)
      process.demonitor_process(monitor)
    }
  }
}

type TaskReport(result) {
  TaskReport(
    outcome: JobOutcome(result),
    finished_ms: Int,
    reply_to: Subject(Nil),
  )
}

type TaskEvent(result) {
  TaskBegan(deadline_ms: Int, timeout_ms: Int)
  TaskFinished(TaskReport(result))
}

type TaskControl {
  Begin(timeout_ms: Int)
}

type TaskStarted {
  TaskStarted(task_pid: Pid, begin: Subject(TaskControl))
}

type WorkerHandle {
  WorkerHandle(worker_pid: Pid, task_pid: Pid, begin: Subject(TaskControl))
}

type WorkerEvent(result) {
  WorkerTaskBegan(deadline_ms: Int, timeout_ms: Int)
  WorkerTaskReport(TaskReport(result))
  WorkerTaskDown(process.Down)
  WorkerExecutorDown(process.Down)
}

type WorkerStartEvent {
  WorkerGuardRegistered(Nil)
  WorkerGuardAttached(Nil)
  WorkerTaskStarted(TaskStarted)
  WorkerStartTaskDown(process.Down)
  WorkerStartExecutorDown(process.Down)
}

type WorkerReadyEvent {
  WorkerReady(WorkerHandle)
  WorkerStartupDown(process.Down)
}

type WorkerReportAck {
  WorkerReportAccepted(Nil)
  WorkerReportExecutorDown(process.Down)
}

fn start_worker(
  executor_subject: Subject(ExecutorMessage(key, result)),
  executor_pid: Pid,
  operation: fn() -> result,
  outcome_guard: Subject(OutcomeGuardMessage(result)),
) -> Result(WorkerHandle, JobOutcome(result)) {
  let ready: Subject(WorkerHandle) = process.new_subject()
  let worker_pid =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      let executor_monitor = process.monitor(executor_pid)
      // The guard monitors this startup worker before it acknowledges. No user
      // task is created before that barrier, so executor death either wins
      // before any task exists or waits for this worker's DOWN confirmation.
      let registered = process.new_subject()
      process.send(
        outcome_guard,
        RegisterWorker(worker_pid: process.self(), reply_to: registered),
      )
      let start_selector =
        process.new_selector()
        |> process.select_map(registered, WorkerGuardRegistered)
        |> process.select_specific_monitor(
          executor_monitor,
          WorkerStartExecutorDown,
        )
      case process.selector_receive_forever(start_selector) {
        WorkerGuardRegistered(Nil) ->
          run_registered_worker(
            ready,
            executor_subject,
            executor_monitor,
            operation,
            outcome_guard,
          )
        WorkerStartExecutorDown(_) -> {
          process.demonitor_process(executor_monitor)
        }
        WorkerGuardAttached(_) | WorkerStartTaskDown(_) -> Nil
        WorkerTaskStarted(_) -> Nil
      }
    })
  let worker_monitor = process.monitor(worker_pid)
  let selector =
    process.new_selector()
    |> process.select_map(ready, WorkerReady)
    |> process.select_specific_monitor(worker_monitor, WorkerStartupDown)
  let result = case process.selector_receive_forever(selector) {
    WorkerReady(handle) -> Ok(handle)
    WorkerStartupDown(down) -> Error(crash_from_exit(down_reason(down)))
  }
  process.demonitor_process(worker_monitor)
  result
}

fn run_registered_worker(
  ready: Subject(WorkerHandle),
  executor_subject: Subject(ExecutorMessage(key, result)),
  executor_monitor: Monitor,
  operation: fn() -> result,
  outcome_guard: Subject(OutcomeGuardMessage(result)),
) -> Nil {
  let reports = process.new_subject()
  let task_started = process.new_subject()
  let task_pid =
    process.spawn(fn() { run_task(operation, reports, task_started) })
  let task_monitor = process.monitor(task_pid)
  let fallback_begin = process.new_subject()
  let fallback_handle = WorkerHandle(process.self(), task_pid, fallback_begin)
  let start_selector =
    process.new_selector()
    |> process.select_map(task_started, WorkerTaskStarted)
    |> process.select_specific_monitor(task_monitor, WorkerStartTaskDown)
    |> process.select_specific_monitor(
      executor_monitor,
      WorkerStartExecutorDown,
    )
  case process.selector_receive_forever(start_selector) {
    WorkerTaskStarted(TaskStarted(begin:, ..)) ->
      attach_registered_task(
        ready,
        executor_subject,
        executor_monitor,
        reports,
        outcome_guard,
        task_pid,
        task_monitor,
        begin,
      )
    WorkerStartTaskDown(down) -> {
      // Return a handle even when the task died before publishing its own
      // Begin subject. The scheduler can then linearize the accepted job while
      // this worker reports the startup crash; the fallback subject is never
      // consumed by user code.
      process.send(ready, fallback_handle)
      report_worker_outcome(
        executor_subject,
        executor_monitor,
        crash_from_exit(down_reason(down)),
      )
    }
    WorkerStartExecutorDown(_) -> {
      process.kill(task_pid)
      wait_for_task_down(task_monitor)
    }
    WorkerGuardRegistered(_) | WorkerGuardAttached(_) -> Nil
  }
}

fn attach_registered_task(
  ready: Subject(WorkerHandle),
  executor_subject: Subject(ExecutorMessage(key, result)),
  executor_monitor: Monitor,
  reports: Subject(TaskEvent(result)),
  outcome_guard: Subject(OutcomeGuardMessage(result)),
  task_pid: Pid,
  task_monitor: Monitor,
  begin: Subject(TaskControl),
) -> Nil {
  // The outcome arbiter learns and monitors the true task pid before the
  // scheduler can release `Begin`, closing abrupt-death terminal races.
  let attached = process.new_subject()
  process.send(
    outcome_guard,
    AttachTask(task_pid: task_pid, reply_to: attached),
  )
  let start_selector =
    process.new_selector()
    |> process.select_map(attached, WorkerGuardAttached)
    |> process.select_specific_monitor(task_monitor, WorkerStartTaskDown)
    |> process.select_specific_monitor(
      executor_monitor,
      WorkerStartExecutorDown,
    )
  let handle = WorkerHandle(process.self(), task_pid, begin)
  case process.selector_receive_forever(start_selector) {
    WorkerGuardAttached(Nil) -> {
      process.send(ready, handle)
      let selector =
        process.new_selector()
        |> process.select_map(reports, fn(event) {
          case event {
            TaskBegan(deadline_ms:, timeout_ms:) ->
              WorkerTaskBegan(deadline_ms:, timeout_ms:)
            TaskFinished(report) -> WorkerTaskReport(report)
          }
        })
        |> process.select_specific_monitor(task_monitor, WorkerTaskDown)
        |> process.select_specific_monitor(executor_monitor, WorkerExecutorDown)
      observe_task(
        selector,
        executor_subject,
        executor_monitor,
        task_pid,
        None,
        None,
      )
    }
    WorkerStartTaskDown(down) -> {
      process.send(ready, handle)
      report_worker_outcome(
        executor_subject,
        executor_monitor,
        crash_from_exit(down_reason(down)),
      )
    }
    WorkerStartExecutorDown(_) -> {
      process.kill(task_pid)
      wait_for_task_down(task_monitor)
    }
    WorkerGuardRegistered(_) | WorkerTaskStarted(_) -> Nil
  }
}

fn run_task(
  operation: fn() -> result,
  reports: Subject(TaskEvent(result)),
  started: Subject(TaskStarted),
) -> Nil {
  let begin = process.new_subject()
  process.send(started, TaskStarted(process.self(), begin))
  let Begin(timeout_ms) = process.receive_forever(begin)
  let deadline_ms = clock.deadline_after(timeout_ms)
  process.send(reports, TaskBegan(deadline_ms:, timeout_ms:))
  let outcome = safely_run(operation)
  let finished_ms = clock.now_ms()
  let reply = process.new_subject()
  process.send(
    reports,
    TaskFinished(TaskReport(outcome:, finished_ms:, reply_to: reply)),
  )
  process.receive_forever(reply)
}

fn safely_run(operation: fn() -> result) -> JobOutcome(result) {
  case ffi.try_run(operation) {
    Ok(result) -> Completed(result)
    Error(ffi.CaughtException(class:, value:, stacktrace:)) ->
      Crashed(class: ffi.exception_class_name(class), value:, stacktrace:)
  }
}

fn observe_task(
  selector: process.Selector(WorkerEvent(result)),
  executor_subject: Subject(ExecutorMessage(key, result)),
  executor_monitor: Monitor,
  task_pid: Pid,
  runtime_deadline: Option(#(Int, Int)),
  reported: Option(JobOutcome(result)),
) -> Nil {
  let event = case runtime_deadline, reported {
    Some(#(deadline_ms, _)), None ->
      process.selector_receive(
        selector,
        within: clock.remaining_ms(deadline_ms),
      )
    _, _ -> Ok(process.selector_receive_forever(selector))
  }
  case event {
    Ok(WorkerTaskBegan(deadline_ms:, timeout_ms:)) ->
      observe_task(
        selector,
        executor_subject,
        executor_monitor,
        task_pid,
        Some(#(deadline_ms, timeout_ms)),
        reported,
      )
    Ok(WorkerTaskReport(TaskReport(outcome:, finished_ms:, reply_to:))) -> {
      process.send(reply_to, Nil)
      case runtime_deadline {
        Some(#(deadline_ms, timeout_ms)) if finished_ms >= deadline_ms -> {
          process.kill(task_pid)
          wait_for_worker_task_down(selector)
          report_worker_outcome(
            executor_subject,
            executor_monitor,
            TimedOut(timeout_ms),
          )
        }
        _ ->
          observe_task(
            selector,
            executor_subject,
            executor_monitor,
            task_pid,
            runtime_deadline,
            Some(outcome),
          )
      }
    }
    Ok(WorkerTaskDown(down)) -> {
      let outcome = case reported {
        Some(outcome) -> outcome
        None -> crash_from_exit(down_reason(down))
      }
      report_worker_outcome(executor_subject, executor_monitor, outcome)
    }
    Ok(WorkerExecutorDown(_)) -> {
      process.kill(task_pid)
      wait_for_worker_task_down(selector)
    }
    Error(Nil) -> {
      let assert Some(#(_, timeout_ms)) = runtime_deadline
      process.kill(task_pid)
      wait_for_worker_task_down(selector)
      report_worker_outcome(
        executor_subject,
        executor_monitor,
        TimedOut(timeout_ms),
      )
    }
  }
}

fn wait_for_worker_task_down(
  selector: process.Selector(WorkerEvent(result)),
) -> Nil {
  case process.selector_receive_forever(selector) {
    WorkerTaskBegan(..) -> wait_for_worker_task_down(selector)
    WorkerTaskReport(TaskReport(reply_to:, ..)) -> {
      process.send(reply_to, Nil)
      wait_for_worker_task_down(selector)
    }
    WorkerTaskDown(_) -> Nil
    WorkerExecutorDown(_) -> wait_for_worker_task_down(selector)
  }
}

fn wait_for_task_down(monitor: Monitor) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
  let _ = process.selector_receive_forever(selector)
  process.demonitor_process(monitor)
}

fn report_worker_outcome(
  executor_subject: Subject(ExecutorMessage(key, result)),
  executor_monitor: Monitor,
  outcome: JobOutcome(result),
) -> Nil {
  let reply = process.new_subject()
  actor.send(executor_subject, WorkerReported(process.self(), outcome, reply))
  let selector =
    process.new_selector()
    |> process.select_map(reply, WorkerReportAccepted)
    |> process.select_specific_monitor(
      executor_monitor,
      WorkerReportExecutorDown,
    )
  let _ = process.selector_receive_forever(selector)
  process.demonitor_process(executor_monitor)
  Nil
}

fn crash_from_exit(reason: process.ExitReason) -> JobOutcome(result) {
  case reason {
    process.Normal ->
      Crashed(
        class: "exit",
        value: "worker exited without a terminal report",
        stacktrace: "[]",
      )
    process.Killed -> Crashed(class: "exit", value: "killed", stacktrace: "[]")
    process.Abnormal(value) ->
      Crashed(class: "exit", value: string.inspect(value), stacktrace: "[]")
  }
}

fn down_pid(down: process.Down) -> Option(Pid) {
  case down {
    process.ProcessDown(_, pid, _) -> Some(pid)
    process.PortDown(..) -> None
  }
}

fn down_reason(down: process.Down) -> process.ExitReason {
  case down {
    process.ProcessDown(_, _, reason) -> reason
    process.PortDown(_, _, reason) -> reason
  }
}

fn describe_exit_reason(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    process.Abnormal(value) -> string.inspect(value)
  }
}

fn fifo_new() -> Fifo(value) {
  Fifo(front: [], back: [])
}

fn fifo_push(queue: Fifo(value), value: value) -> Fifo(value) {
  Fifo(..queue, back: [value, ..queue.back])
}

fn fifo_pop(queue: Fifo(value)) -> Result(#(value, Fifo(value)), Nil) {
  case queue.front {
    [value, ..rest] -> Ok(#(value, Fifo(front: rest, back: queue.back)))
    [] ->
      case list.reverse(queue.back) {
        [] -> Error(Nil)
        [value, ..rest] -> Ok(#(value, Fifo(front: rest, back: [])))
      }
  }
}

fn fifo_is_empty(queue: Fifo(value)) -> Bool {
  queue.front == [] && queue.back == []
}

fn fifo_to_list(queue: Fifo(value)) -> List(value) {
  list.append(queue.front, list.reverse(queue.back))
}
