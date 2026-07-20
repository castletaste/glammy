//// Bot composition and a defensive long-polling driver.
////
//// Polling classifies permanent failures instead of retrying poison responses
//// forever. Each update handler runs behind a monitored, unlinked broker with
//// a bounded direct worker, so one panic or hang cannot take down polling.

import glammy/api.{type Api}
import glammy/composer.{type Composer}
import glammy/context
import glammy/error.{type GlammyError}
import glammy/internal/clock
import glammy/types.{type Update}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const handler_stop_timeout_ms = 1000

const default_callback_timeout_ms = 5000

const callback_stop_timeout_ms = 1000

/// Controls whether long polling continues after an update handler fails.
pub type HandlerFailurePolicy {
  /// Report a confirmed handler crash, advance the offset, and continue.
  /// Gate failures and timeout/outcome uncertainty always stop fail-closed.
  SkipFailedUpdate
  /// Stop at the failed update. A short poll checkpoints any successful prefix
  /// without confirming the failure; checkpoint uncertainty is returned typed.
  StopOnHandlerFailure
}

/// Configuration for the defensive long-polling loop.
pub type PollingOptions {
  PollingOptions(
    /// Maximum number of updates fetched per request (1-100).
    limit: Int,
    /// Telegram long-poll timeout in seconds (0-50).
    timeout_seconds: Int,
    /// Maximum runtime for one update handler (1-4,294,967,295ms).
    handler_timeout_ms: Int,
    handler_failure_policy: HandlerFailurePolicy,
    allowed_updates: Option(List(String)),
    drop_pending_updates: Bool,
    verify_token: Bool,
  )
}

/// A failure raised by an isolated update handler or its dispatch boundary.
pub type BotRuntimeError {
  /// The reason can contain application-owned exception values and stacks.
  /// Treat it as sensitive and log it only through an explicit policy.
  HandlerCrashed(update_id: Int, reason: String)
  /// The handler is confirmed stopped after missing its deadline, but effects
  /// it performed before termination may already have happened.
  HandlerTimedOut(update_id: Int, timeout_ms: Int)
  /// The handler could not be confirmed stopped after its termination grace.
  HandlerTerminationTimedOut(update_id: Int, timeout_ms: Int)
  /// The isolation broker died after dispatch may have begun, so the handler
  /// must be treated as possibly still running.
  HandlerOutcomeUnknown(update_id: Int)
  UpdateGateFailed(update_id: Int, code: String, message: String)
  /// A pre-dispatch gate terminated exceptionally. Details are deliberately
  /// omitted because gates may handle credentials and storage errors.
  UpdateGateCrashed(update_id: Int)
}

/// Whether a pre-dispatch gate consumed an update or permits middleware.
pub type UpdateAction {
  Continue
  Consumed
}

/// A stable machine code plus an operator-facing gate failure description.
pub type UpdateGateError {
  UpdateGateError(code: String, message: String)
}

/// A fail-closed hook that runs before the ordinary middleware composer.
pub type UpdateGate =
  fn(context.Context) -> Result(UpdateAction, UpdateGateError)

/// Validation, API, or handler failures returned by long polling.
pub type BotError {
  InvalidPollingLimit(Int)
  InvalidPollingTimeout(Int)
  /// Handler deadlines must fit BEAM's positive receive-timeout range.
  InvalidHandlerTimeout(Int)
  ApiFailure(GlammyError)
  UpdateHandlerFailure(BotRuntimeError)
  /// A handler stopped the batch, but Telegram could not confirm the already
  /// consumed prefix. The failed update is still retained; earlier updates may
  /// replay because the checkpoint outcome is unknown.
  UpdateCheckpointFailure(
    update_failure: BotRuntimeError,
    checkpoint_failure: GlammyError,
  )
}

/// A rejected bot-level runtime configuration value.
pub type BotConfigError {
  /// Callback deadlines must fit BEAM's positive receive-timeout range.
  InvalidCallbackTimeout(Int)
}

/// Default long-polling options.
pub fn default_polling_options() -> PollingOptions {
  PollingOptions(
    limit: 100,
    timeout_seconds: 30,
    handler_timeout_ms: 60_000,
    handler_failure_policy: SkipFailedUpdate,
    allowed_updates: None,
    drop_pending_updates: False,
    verify_token: True,
  )
}

/// A bot API client paired with its middleware composer and error handlers.
pub opaque type Bot {
  Bot(
    api: Api,
    composer: Composer,
    update_gates: List(UpdateGate),
    error_handler: fn(GlammyError) -> Nil,
    runtime_error_handler: fn(BotRuntimeError) -> Nil,
    callback_timeout_ms: Int,
  )
}

/// Create a bot from an API client and composer.
pub fn new(api: Api, composer: Composer) -> Bot {
  Bot(
    api:,
    composer:,
    update_gates: [],
    error_handler: default_error_handler,
    runtime_error_handler: default_runtime_error_handler,
    callback_timeout_ms: default_callback_timeout_ms,
  )
}

/// Set the deadline shared by configured diagnostic callbacks.
///
/// The default is 5000ms. Values must be between 1 and 4,294,967,295ms. A
/// callback that misses its deadline is killed and given a further 1000ms for
/// termination confirmation. Callback failure never replaces the API or
/// runtime error that the callback was observing.
pub fn with_callback_timeout(
  bot: Bot,
  timeout_ms: Int,
) -> Result(Bot, BotConfigError) {
  case clock.is_valid_process_timeout(timeout_ms) {
    True -> Ok(Bot(..bot, callback_timeout_ms: timeout_ms))
    False -> Error(InvalidCallbackTimeout(timeout_ms))
  }
}

/// Register a pre-dispatch gate in registration order.
///
/// A gate can report an update consumed after application-owned persistence,
/// allow the next gate/normal middleware, or fail. `Consumed` short-circuits
/// later gates, so specialized owners such as conversations must be registered
/// before broader catch-all executors. A failure becomes `UpdateGateFailed`, so
/// polling never advances past that update under either handler policy; an
/// earlier successful batch prefix can still be checkpointed. Webhook adapters
/// can request a retry. Gate-backed once-only effects still require
/// application-owned idempotency or a durable journal.
pub fn with_update_gate(bot: Bot, gate: UpdateGate) -> Bot {
  Bot(..bot, update_gates: list.append(bot.update_gates, [gate]))
}

/// Replace the Telegram/network error handler.
///
/// The direct callback process is isolated behind an owner-aware guard. A
/// panic, self-termination, owner exit, or configured deadline cannot escape
/// into the bot runner. This does not supervise processes spawned by callback
/// application code.
pub fn on_error(bot: Bot, handler: fn(GlammyError) -> Nil) -> Bot {
  Bot(..bot, error_handler: handler)
}

/// Replace the isolated update-handler failure callback.
///
/// The direct callback process is isolated behind an owner-aware guard. A
/// panic, self-termination, owner exit, or configured deadline cannot escape
/// into the bot runner. This does not supervise processes spawned by callback
/// application code.
pub fn on_runtime_error(bot: Bot, handler: fn(BotRuntimeError) -> Nil) -> Bot {
  Bot(..bot, runtime_error_handler: handler)
}

fn default_error_handler(error_value: GlammyError) -> Nil {
  io.println_error("glammy: " <> error.describe(error_value))
}

fn default_runtime_error_handler(error_value: BotRuntimeError) -> Nil {
  io.println_error("glammy runtime: " <> describe_runtime_error(error_value))
}

/// Return a stable runtime-error summary safe for default production logs.
///
/// Application-controlled panic reasons, stacks, gate codes, and gate messages
/// are deliberately omitted. An explicit `on_runtime_error` callback still
/// receives the complete typed value when detailed diagnostics are appropriate.
pub fn describe_runtime_error(error_value: BotRuntimeError) -> String {
  case error_value {
    HandlerCrashed(update_id:, ..) ->
      "handler crashed for update " <> int.to_string(update_id)
    HandlerTimedOut(update_id:, timeout_ms:) ->
      "handler timed out for update "
      <> int.to_string(update_id)
      <> " after "
      <> int.to_string(timeout_ms)
      <> "ms"
    HandlerTerminationTimedOut(update_id:, timeout_ms:) ->
      "handler termination remained unconfirmed for update "
      <> int.to_string(update_id)
      <> " after "
      <> int.to_string(timeout_ms)
      <> "ms"
    HandlerOutcomeUnknown(update_id:) ->
      "handler outcome is unknown for update " <> int.to_string(update_id)
    UpdateGateFailed(update_id:, ..) ->
      "update gate failed for update " <> int.to_string(update_id)
    UpdateGateCrashed(update_id:) ->
      "update gate crashed for update " <> int.to_string(update_id)
  }
}

fn run_callback_safely(
  callback: fn(value) -> Nil,
  value: value,
  callback_name: String,
  timeout_ms: Int,
) -> Nil {
  let owner_pid = process.self()
  let reply = process.new_subject()
  let #(_guard, guard_monitor) =
    spawn_monitored(fn() {
      run_callback_guard(
        owner_pid,
        reply,
        callback,
        value,
        callback_name,
        timeout_ms,
      )
    })
  let selector =
    process.new_selector()
    |> process.select_map(reply, CallbackGuardReply)
    |> process.select_specific_monitor(guard_monitor, CallbackGuardDown)
  let outcome = process.selector_receive_forever(selector)
  process.demonitor_process(guard_monitor)
  case outcome {
    CallbackGuardReply(CallbackCompleted) -> Nil
    CallbackGuardReply(CallbackCrashed) -> report_callback_crash(callback_name)
    CallbackGuardReply(CallbackTimedOut) ->
      report_callback_timeout(callback_name)
    CallbackGuardReply(CallbackTerminationUnconfirmed) ->
      report_callback_termination_unconfirmed(callback_name)
    CallbackGuardDown(_) ->
      report_callback_termination_unconfirmed(callback_name)
  }
}

type CallbackCallerEvent {
  CallbackGuardReply(CallbackResult)
  CallbackGuardDown(process.Down)
}

type CallbackResult {
  CallbackCompleted
  CallbackCrashed
  CallbackTimedOut
  CallbackTerminationUnconfirmed
}

type OwnedTaskEvent(value) {
  OwnedTaskReported(value)
  OwnedTaskWorkerExit(process.ExitMessage)
  OwnedTaskOwnerMonitorDown(process.Down)
}

type OwnedTaskOutcome(value) {
  OwnedTaskCompleted(value)
  OwnedTaskCrashed(process.ExitReason)
  OwnedTaskTimedOut
  OwnedTaskTerminationUnconfirmed
  OwnedTaskOwnerGone
  OwnedTaskOwnerGoneUnconfirmed
}

type OwnedTaskStopReason {
  OwnedTaskDeadlineReached
  OwnedTaskLostOwner
}

fn run_owned_task(
  owner_pid: process.Pid,
  timeout_ms: Int,
  termination_timeout_ms: Int,
  operation: fn() -> value,
) -> OwnedTaskOutcome(value) {
  // Linking contains an unexpected supervisor death; trapping exits lets the
  // supervisor classify ordinary direct-task failures.
  process.trap_exits(True)
  let owner_monitor = process.monitor(owner_pid)
  let reports: process.Subject(value) = process.new_subject()
  let worker = process.spawn(fn() { process.send(reports, operation()) })
  let selector =
    process.new_selector()
    |> process.select_map(reports, OwnedTaskReported)
    |> process.select_trapped_exits(OwnedTaskWorkerExit)
    |> process.select_specific_monitor(owner_monitor, OwnedTaskOwnerMonitorDown)
  supervise_owned_task(
    selector,
    worker,
    owner_monitor,
    termination_timeout_ms,
    clock.deadline_after(timeout_ms),
  )
}

fn supervise_owned_task(
  selector: process.Selector(OwnedTaskEvent(value)),
  worker: process.Pid,
  owner_monitor: process.Monitor,
  termination_timeout_ms: Int,
  deadline_ms: Int,
) -> OwnedTaskOutcome(value) {
  case process.selector_receive(selector, clock.remaining_ms(deadline_ms)) {
    Ok(OwnedTaskReported(value)) ->
      confirm_completed_owned_task(
        selector,
        worker,
        owner_monitor,
        termination_timeout_ms,
        value,
        clock.deadline_after(termination_timeout_ms),
      )
    Ok(OwnedTaskWorkerExit(process.ExitMessage(_, reason))) -> {
      process.demonitor_process(owner_monitor)
      OwnedTaskCrashed(reason)
    }
    Ok(OwnedTaskOwnerMonitorDown(_)) ->
      stop_owned_task(
        worker,
        owner_monitor,
        termination_timeout_ms,
        OwnedTaskLostOwner,
      )
    Error(Nil) ->
      stop_owned_task(
        worker,
        owner_monitor,
        termination_timeout_ms,
        OwnedTaskDeadlineReached,
      )
  }
}

fn confirm_completed_owned_task(
  selector: process.Selector(OwnedTaskEvent(value)),
  worker: process.Pid,
  owner_monitor: process.Monitor,
  termination_timeout_ms: Int,
  value: value,
  deadline_ms: Int,
) -> OwnedTaskOutcome(value) {
  case process.selector_receive(selector, clock.remaining_ms(deadline_ms)) {
    Ok(OwnedTaskWorkerExit(_)) -> {
      process.demonitor_process(owner_monitor)
      OwnedTaskCompleted(value)
    }
    Ok(OwnedTaskOwnerMonitorDown(_)) ->
      stop_owned_task(
        worker,
        owner_monitor,
        termination_timeout_ms,
        OwnedTaskLostOwner,
      )
    Ok(OwnedTaskReported(_)) ->
      confirm_completed_owned_task(
        selector,
        worker,
        owner_monitor,
        termination_timeout_ms,
        value,
        deadline_ms,
      )
    Error(Nil) -> {
      let confirmed =
        kill_and_confirm_owned_task(worker, termination_timeout_ms)
      process.demonitor_process(owner_monitor)
      case confirmed {
        True -> OwnedTaskCompleted(value)
        False -> OwnedTaskTerminationUnconfirmed
      }
    }
  }
}

fn stop_owned_task(
  worker: process.Pid,
  owner_monitor: process.Monitor,
  termination_timeout_ms: Int,
  reason: OwnedTaskStopReason,
) -> OwnedTaskOutcome(value) {
  let confirmed = kill_and_confirm_owned_task(worker, termination_timeout_ms)
  process.demonitor_process(owner_monitor)
  case reason, confirmed {
    OwnedTaskDeadlineReached, True -> OwnedTaskTimedOut
    OwnedTaskDeadlineReached, False -> OwnedTaskTerminationUnconfirmed
    OwnedTaskLostOwner, True -> OwnedTaskOwnerGone
    OwnedTaskLostOwner, False -> OwnedTaskOwnerGoneUnconfirmed
  }
}

fn kill_and_confirm_owned_task(worker: process.Pid, timeout_ms: Int) -> Bool {
  process.kill(worker)
  wait_for_owned_task_exit(worker, clock.deadline_after(timeout_ms))
}

fn wait_for_owned_task_exit(worker: process.Pid, deadline_ms: Int) -> Bool {
  let selector =
    process.new_selector()
    |> process.select_trapped_exits(fn(exit) { exit })
  case process.selector_receive(selector, clock.remaining_ms(deadline_ms)) {
    Ok(process.ExitMessage(pid, _)) ->
      case pid == worker {
        True -> True
        False -> wait_for_owned_task_exit(worker, deadline_ms)
      }
    Error(Nil) -> False
  }
}

fn run_callback_guard(
  owner_pid: process.Pid,
  reply: process.Subject(CallbackResult),
  callback: fn(value) -> Nil,
  value: value,
  callback_name: String,
  timeout_ms: Int,
) -> Nil {
  let outcome =
    run_owned_task(owner_pid, timeout_ms, callback_stop_timeout_ms, fn() {
      case try_run(fn() { callback(value) }) {
        Ok(Nil) -> CallbackCompleted
        Error(_) -> CallbackCrashed
      }
    })
  case outcome {
    OwnedTaskCompleted(result) -> process.send(reply, result)
    OwnedTaskCrashed(_) -> process.send(reply, CallbackCrashed)
    OwnedTaskTimedOut -> process.send(reply, CallbackTimedOut)
    OwnedTaskTerminationUnconfirmed ->
      process.send(reply, CallbackTerminationUnconfirmed)
    OwnedTaskOwnerGone -> Nil
    OwnedTaskOwnerGoneUnconfirmed ->
      report_callback_termination_unconfirmed(callback_name)
  }
}

fn report_callback_crash(callback_name: String) -> Nil {
  // Do not print the callback's exception value or stack: application
  // callbacks may handle credentials and other sensitive values.
  io.println_error(
    "glammy: configured " <> callback_name <> " callback crashed; continuing",
  )
}

fn report_callback_timeout(callback_name: String) -> Nil {
  io.println_error(
    "glammy: configured " <> callback_name <> " callback timed out; continuing",
  )
}

fn report_callback_termination_unconfirmed(callback_name: String) -> Nil {
  io.println_error(
    "glammy: configured "
    <> callback_name
    <> " callback termination remained unconfirmed; continuing",
  )
}

fn report_error(bot: Bot, error_value: GlammyError) -> Nil {
  run_callback_safely(
    bot.error_handler,
    error_value,
    "error",
    bot.callback_timeout_ms,
  )
}

fn report_runtime_error(bot: Bot, error_value: BotRuntimeError) -> Nil {
  run_callback_safely(
    bot.runtime_error_handler,
    error_value,
    "runtime error",
    bot.callback_timeout_ms,
  )
}

/// Dispatch one parsed update synchronously.
///
/// Webhook adapters that need panic isolation should use
/// `handle_update_isolated`.
pub fn handle_update(bot: Bot, update: Update) -> Nil {
  case handle_update_result(bot, update) {
    Ok(Nil) -> Nil
    Error(runtime_error) -> report_runtime_error(bot, runtime_error)
  }
}

/// Dispatch one update and preserve typed gate failure for polling/webhooks.
pub fn handle_update_result(
  bot: Bot,
  update: Update,
) -> Result(Nil, BotRuntimeError) {
  dispatch_update(bot, update, fn(_) { Nil })
}

type DispatchPhase {
  RunningUpdateGates
  RunningMiddleware
}

fn dispatch_update(
  bot: Bot,
  update: Update,
  observe_phase: fn(DispatchPhase) -> Nil,
) -> Result(Nil, BotRuntimeError) {
  let ctx = context.new(update, bot.api)
  observe_phase(RunningUpdateGates)
  case run_update_gates(bot.update_gates, ctx) {
    Error(UpdateGateError(code:, message:)) ->
      Error(UpdateGateFailed(update.update_id, code, message))
    Ok(Consumed) -> Ok(Nil)
    Ok(Continue) -> {
      observe_phase(RunningMiddleware)
      composer.run(bot.composer, ctx)
      Ok(Nil)
    }
  }
}

fn run_update_gates(
  gates: List(UpdateGate),
  ctx: context.Context,
) -> Result(UpdateAction, UpdateGateError) {
  case gates {
    [] -> Ok(Continue)
    [gate, ..rest] ->
      case gate(ctx) {
        Ok(Continue) -> run_update_gates(rest, ctx)
        Ok(Consumed) -> Ok(Consumed)
        Error(error) -> Error(error)
      }
  }
}

/// Dispatch one update through an unlinked monitored broker and linked worker.
///
/// `timeout_ms` must be between 1 and 4,294,967,295ms; an out-of-range value
/// is rejected as `HandlerTimedOut` without starting application code.
///
/// A timeout confirms process termination before returning, but cannot roll
/// back effects completed before that termination. Use an idempotent update
/// gate or durable journal when those effects must be exactly-once.
pub fn handle_update_isolated(
  bot: Bot,
  update: Update,
  timeout_ms: Int,
) -> Result(Nil, BotRuntimeError) {
  case clock.is_valid_process_timeout(timeout_ms) {
    False -> Error(HandlerTimedOut(update_id: update.update_id, timeout_ms:))
    True -> {
      // The unlinked broker owns the worker protocol and monitors this direct
      // caller. If the caller disappears, the broker hard-stops the direct
      // dispatch worker rather than orphaning it.
      let owner_pid = process.self()
      let outcome = process.new_subject()
      let #(_broker, monitor) =
        spawn_monitored(fn() {
          case run_handler_from_broker(owner_pid, bot, update, timeout_ms) {
            Some(result) -> process.send(outcome, result)
            None -> Nil
          }
        })
      let selector =
        process.new_selector()
        |> process.select_map(outcome, HandlerBrokerReply)
        |> process.select_specific_monitor(monitor, HandlerBrokerDown)
      let response = process.selector_receive_forever(selector)
      process.demonitor_process(monitor)
      case response {
        HandlerBrokerReply(result) -> result
        HandlerBrokerDown(_) ->
          Error(HandlerOutcomeUnknown(update_id: update.update_id))
      }
    }
  }
}

type HandlerBrokerOutcome {
  HandlerBrokerReply(Result(Nil, BotRuntimeError))
  HandlerBrokerDown(process.Down)
}

fn run_handler_from_broker(
  owner_pid: process.Pid,
  bot: Bot,
  update: Update,
  timeout_ms: Int,
) -> Option(Result(Nil, BotRuntimeError)) {
  let reported = process.new_subject()
  let phase: process.Subject(DispatchPhase) = process.new_subject()
  let outcome =
    run_owned_task(owner_pid, timeout_ms, handler_stop_timeout_ms, fn() {
      try_run(fn() {
        process.send(
          reported,
          dispatch_update(bot, update, fn(current_phase) {
            process.send(phase, current_phase)
          }),
        )
      })
    })
  case outcome {
    OwnedTaskCompleted(execution) ->
      Some(handler_result_from_report(
        execution,
        reported,
        phase,
        update.update_id,
      ))
    OwnedTaskCrashed(down) ->
      Some(Error(classify_handler_down(update.update_id, phase, down)))
    OwnedTaskTimedOut ->
      Some(Error(HandlerTimedOut(update_id: update.update_id, timeout_ms:)))
    OwnedTaskTerminationUnconfirmed ->
      Some(
        Error(HandlerTerminationTimedOut(
          update_id: update.update_id,
          timeout_ms: handler_stop_timeout_ms,
        )),
      )
    OwnedTaskOwnerGone | OwnedTaskOwnerGoneUnconfirmed -> None
  }
}

fn handler_result_from_report(
  execution: Result(Nil, #(String, String, String)),
  reported: process.Subject(Result(Nil, BotRuntimeError)),
  phase: process.Subject(DispatchPhase),
  update_id: Int,
) -> Result(Nil, BotRuntimeError) {
  case execution {
    Ok(Nil) ->
      case process.receive(reported, 0) {
        Ok(result) -> result
        Error(Nil) ->
          Error(classify_dispatch_crash(
            update_id,
            phase,
            "handler returned without reporting a result",
          ))
      }
    Error(#(class, value, stacktrace)) ->
      Error(classify_dispatch_crash(
        update_id,
        phase,
        class <> ": " <> value <> " " <> stacktrace,
      ))
  }
}

fn classify_handler_down(
  update_id: Int,
  phase: process.Subject(DispatchPhase),
  reason: process.ExitReason,
) -> BotRuntimeError {
  case reason {
    process.Normal ->
      classify_dispatch_crash(
        update_id,
        phase,
        "handler exited without reporting a result",
      )
    reason ->
      classify_dispatch_crash(update_id, phase, describe_exit_reason(reason))
  }
}

fn classify_dispatch_crash(
  update_id: Int,
  phase: process.Subject(DispatchPhase),
  handler_reason: String,
) -> BotRuntimeError {
  case latest_dispatch_phase(phase, None) {
    Some(RunningUpdateGates) -> UpdateGateCrashed(update_id:)
    _ -> HandlerCrashed(update_id:, reason: handler_reason)
  }
}

fn latest_dispatch_phase(
  phase: process.Subject(DispatchPhase),
  latest: Option(DispatchPhase),
) -> Option(DispatchPhase) {
  case process.receive(phase, 0) {
    Ok(current) -> latest_dispatch_phase(phase, Some(current))
    Error(_) -> latest
  }
}

@external(erlang, "glammy_ffi", "try_run")
fn try_run(operation: fn() -> Nil) -> Result(Nil, #(String, String, String))

// Unlike a separate spawn followed by monitor, this cannot lose ordering when
// a guard or broker reports and exits before its caller installs the monitor.
@external(erlang, "erlang", "spawn_monitor")
fn spawn_monitored(operation: fn() -> Nil) -> #(process.Pid, process.Monitor)

fn describe_exit_reason(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    process.Abnormal(value) -> string.inspect(value)
  }
}

/// Run long polling until a permanent API/decode error or configured handler
/// failure stops it. Credential verification, the optional initial drain, and
/// polling all back off and retry transient network, 408, 429, and 5xx
/// failures. Permanent 4xx and decode failures return `ApiFailure` rather than
/// retrying the same poison response forever. If a failure happens while
/// checkpointing a consumed batch prefix, `UpdateCheckpointFailure` preserves
/// both the update failure and the uncertain API outcome.
pub fn start(bot: Bot, options: PollingOptions) -> Result(Nil, BotError) {
  use _ <- result.try(validate_options(options))
  use _ <- result.try(verify_credentials(bot, options))
  use initial_offset <- result.try(case options.drop_pending_updates {
    True -> drain_pending(bot, options)
    False -> Ok(None)
  })
  poll_loop(bot, options, initial_offset, 0)
}

fn validate_options(options: PollingOptions) -> Result(Nil, BotError) {
  case options.limit >= 1 && options.limit <= 100 {
    False -> Error(InvalidPollingLimit(options.limit))
    True ->
      case options.timeout_seconds >= 0 && options.timeout_seconds <= 50 {
        False -> Error(InvalidPollingTimeout(options.timeout_seconds))
        True ->
          case clock.is_valid_process_timeout(options.handler_timeout_ms) {
            True -> Ok(Nil)
            False -> Error(InvalidHandlerTimeout(options.handler_timeout_ms))
          }
      }
  }
}

fn verify_credentials(
  bot: Bot,
  options: PollingOptions,
) -> Result(Nil, BotError) {
  case options.verify_token {
    False -> Ok(Nil)
    True -> {
      use _ <- result.try(retry_startup_api_call(
        bot,
        fn() { api.get_me(bot.api) },
        0,
      ))
      Ok(Nil)
    }
  }
}

fn drain_pending(
  bot: Bot,
  options: PollingOptions,
) -> Result(Option(Int), BotError) {
  use updates <- result.try(retry_startup_api_call(
    bot,
    fn() {
      api.get_updates(
        bot.api,
        offset: Some(-1),
        limit: Some(1),
        timeout: Some(0),
        allowed_updates: options.allowed_updates,
      )
    },
    0,
  ))
  last_update_id(updates)
  |> option.map(fn(id) { id + 1 })
  |> Ok
}

fn retry_startup_api_call(
  bot: Bot,
  operation: fn() -> Result(value, GlammyError),
  attempt: Int,
) -> Result(value, BotError) {
  case operation() {
    Ok(value) -> Ok(value)
    Error(error_value) -> {
      report_error(bot, error_value)
      case retry_delay_ms(error_value, attempt) {
        None -> Error(ApiFailure(error_value))
        Some(delay_ms) -> {
          process.sleep(delay_ms)
          retry_startup_api_call(bot, operation, attempt + 1)
        }
      }
    }
  }
}

fn poll_loop(
  bot: Bot,
  options: PollingOptions,
  offset: Option(Int),
  consecutive_errors: Int,
) -> Result(Nil, BotError) {
  case
    api.get_updates(
      bot.api,
      offset: offset,
      limit: Some(options.limit),
      timeout: Some(options.timeout_seconds),
      allowed_updates: options.allowed_updates,
    )
  {
    Ok(updates) -> {
      case process_updates(bot, options, updates) {
        Ok(Nil) -> {
          let next_offset =
            last_update_id(updates)
            |> option.map(fn(id) { id + 1 })
            |> option.or(offset)
          poll_loop(bot, options, next_offset, 0)
        }
        Error(UpdateBatchFailure(runtime_error:, checkpoint_offset: None)) ->
          Error(UpdateHandlerFailure(runtime_error))
        Error(UpdateBatchFailure(
          runtime_error:,
          checkpoint_offset: Some(checkpoint_offset),
        )) ->
          checkpoint_successful_prefix(
            bot,
            options,
            checkpoint_offset,
            runtime_error,
          )
      }
    }
    Error(error_value) -> {
      report_error(bot, error_value)
      case retry_delay_ms(error_value, consecutive_errors) {
        None -> Error(ApiFailure(error_value))
        Some(delay_ms) -> {
          process.sleep(delay_ms)
          poll_loop(bot, options, offset, consecutive_errors + 1)
        }
      }
    }
  }
}

type UpdateBatchFailure {
  UpdateBatchFailure(
    runtime_error: BotRuntimeError,
    checkpoint_offset: Option(Int),
  )
}

fn process_updates(
  bot: Bot,
  options: PollingOptions,
  updates: List(Update),
) -> Result(Nil, UpdateBatchFailure) {
  process_updates_loop(bot, options, updates, False)
}

fn process_updates_loop(
  bot: Bot,
  options: PollingOptions,
  updates: List(Update),
  has_consumed_prefix: Bool,
) -> Result(Nil, UpdateBatchFailure) {
  case updates {
    [] -> Ok(Nil)
    [update, ..rest] ->
      case handle_update_isolated(bot, update, options.handler_timeout_ms) {
        Ok(Nil) -> process_updates_loop(bot, options, rest, True)
        Error(runtime_error) -> {
          report_runtime_error(bot, runtime_error)
          case runtime_error {
            // Gate/store failures are retriable and must never be converted
            // into offset advancement past the failed update.
            UpdateGateFailed(..) ->
              stop_batch(runtime_error, update.update_id, has_consumed_prefix)
            UpdateGateCrashed(..) ->
              stop_batch(runtime_error, update.update_id, has_consumed_prefix)
            // A timed-out handler is stopped, but unlinked descendants or
            // effects started before its deadline may still outlive it. Never
            // turn that ownership uncertainty into Telegram offset progress.
            HandlerTimedOut(..) ->
              stop_batch(runtime_error, update.update_id, has_consumed_prefix)
            // A worker that has not confirmed DOWN can still be executing.
            // Continuing the batch would violate sequential dispatch.
            HandlerTerminationTimedOut(..) ->
              stop_batch(runtime_error, update.update_id, has_consumed_prefix)
            HandlerOutcomeUnknown(..) ->
              stop_batch(runtime_error, update.update_id, has_consumed_prefix)
            _ ->
              case options.handler_failure_policy {
                SkipFailedUpdate ->
                  process_updates_loop(bot, options, rest, True)
                StopOnHandlerFailure ->
                  stop_batch(
                    runtime_error,
                    update.update_id,
                    has_consumed_prefix,
                  )
              }
          }
        }
      }
  }
}

fn stop_batch(
  runtime_error: BotRuntimeError,
  failed_update_id: Int,
  has_consumed_prefix: Bool,
) -> Result(Nil, UpdateBatchFailure) {
  let checkpoint_offset = case has_consumed_prefix {
    True -> Some(failed_update_id)
    False -> None
  }
  Error(UpdateBatchFailure(runtime_error:, checkpoint_offset:))
}

fn checkpoint_successful_prefix(
  bot: Bot,
  options: PollingOptions,
  checkpoint_offset: Int,
  runtime_error: BotRuntimeError,
) -> Result(Nil, BotError) {
  // Telegram confirms only updates with ids lower than the supplied offset.
  // Using the failed id checkpoints the consumed prefix while retaining the
  // failed update, even if this short-poll response itself is discarded.
  case
    api.get_updates(
      bot.api,
      offset: Some(checkpoint_offset),
      limit: Some(1),
      timeout: Some(0),
      allowed_updates: options.allowed_updates,
    )
  {
    Ok(_) -> Error(UpdateHandlerFailure(runtime_error))
    Error(checkpoint_failure) -> {
      report_error(bot, checkpoint_failure)
      Error(UpdateCheckpointFailure(runtime_error, checkpoint_failure))
    }
  }
}

fn retry_delay_ms(error_value: GlammyError, attempt: Int) -> Option(Int) {
  case error_value {
    error.HttpError(..) -> Some(backoff_ms(attempt))
    error.HttpStatusError(status:, ..) ->
      case status == 408 || status == 429 || status >= 500 {
        True -> Some(backoff_ms(attempt))
        False -> None
      }
    error.ApiError(error_code:, parameters:, ..) ->
      case error_code == 429 {
        True ->
          case parameters.retry_after {
            Some(seconds) ->
              case seconds > 0 {
                True -> Some(seconds * 1000)
                False -> Some(backoff_ms(attempt))
              }
            None -> Some(backoff_ms(attempt))
          }
        False ->
          case error_code == 408 || error_code >= 500 {
            True -> Some(backoff_ms(attempt))
            False -> None
          }
      }
    error.DecodeError(..) -> None
  }
}

fn last_update_id(updates: List(Update)) -> Option(Int) {
  list.last(updates)
  |> result.map(fn(update) { update.update_id })
  |> option.from_result
}

fn backoff_ms(attempt: Int) -> Int {
  case attempt {
    0 -> 1000
    1 -> 2000
    2 -> 5000
    3 -> 10_000
    _ -> 30_000
  }
}
