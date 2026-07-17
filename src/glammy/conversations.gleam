//// In-process linear conversations backed by `gleam_otp` actors.
////
//// Starting a conversation is non-blocking: its thunk runs in a dedicated
//// worker while the polling handler returns immediately. Registration is
//// acknowledged before `start` returns, so an immediate reply cannot overtake
//// the registry. Conversation and wait generations prevent stale timeouts from
//// deleting a newer waiter. Optional typed outcome callbacks observe worker
//// completion, stop, typed infrastructure failure, or crash without linking
//// failures back to the caller.
////
//// A route is acknowledged only after the matching wait has dequeued its
//// delivery and the registry has accepted that process-local receipt. This is
//// not durable completion of the user thunk: a crash after receipt still needs
//// an application journal if the update must be replayed across process loss.

import glammy/bot
import glammy/composer.{type Middleware}
import glammy/context.{type Context}
import glammy/internal/clock
import glammy/types.{type Update}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

const default_call_timeout_ms = 1000

const graceful_stop_timeout_ms = 50

// =====================================================================
//                         Public contracts
// =====================================================================

/// Failures raised while starting, calling, or stopping a registry actor.
pub type RegistryError {
  /// Actor-call timeouts must be within `1..4_294_967_295` milliseconds.
  InvalidCallTimeout(Int)
  StartFailed(String)
  CallTimeout
  /// Routing began but no accepted-or-rejected receipt can be proven. The
  /// update may already belong to the conversation and must not run downstream.
  /// A retry needs reconciliation or idempotency: a late accepted receipt may
  /// still execute after this error has been returned.
  RouteOutcomeUnknown
  /// A wait-state mutation began but its acknowledgement was lost. The worker
  /// is fail-stopped before its thunk can continue, and its observer receives
  /// `ConversationFailed(WaitStateOutcomeUnknown)`.
  WaitStateOutcomeUnknown
  /// Opening a conversation began but its acknowledgement was lost. The new
  /// worker is cancelled, but an older conversation may already be replaced.
  OpenOutcomeUnknown
  /// The bounded registry-and-workers shutdown barrier did not complete. The
  /// registry, a tracked worker, or both may still be alive.
  RegistryStopTimeout
  Stopped
}

/// Failures raised while starting or stopping one conversation.
pub type ConversationError {
  MissingKey
  RegistryUnavailable(RegistryError)
  WorkerStartFailed(String)
  StopTimeout
}

/// Failures returned while waiting for the next routed update.
pub type WaitError {
  Timeout
  /// Wait timeouts must be within `0..4_294_967_295` milliseconds.
  InvalidWaitTimeout(Int)
  Cancelled
  RegistryUnavailableWhileWaiting(RegistryError)
}

/// How a registered conversation worker finished.
pub type ConversationOutcome {
  ConversationCompleted
  ConversationStopped
  ConversationFailed(RegistryError)
  ConversationCrashed(reason: String)
}

/// Receives one terminal outcome from an unlinked lifecycle observer.
pub type OutcomeHandler =
  fn(ConversationOutcome) -> Nil

/// Waits up to the supplied milliseconds for the local mailbox receive.
///
/// Registering and pausing the waiter are separate bounded registry calls, so
/// the total wall-clock duration can exceed the supplied receive timeout.
pub type WaitFn =
  fn(Int) -> Result(Context, WaitError)

/// Derives the routing key used to associate updates with conversations.
pub type KeyFn =
  fn(Context) -> Option(String)

/// A running, process-safe conversation registry.
pub opaque type Registry {
  Registry(
    subject: Subject(RegistryMessage),
    pid: Pid,
    lifecycle_subject: Subject(RegistryLifecycleMessage),
    lifecycle_pid: Pid,
    key_fn: KeyFn,
    call_timeout_ms: Int,
  )
}

/// A handle to one registered conversation worker.
pub opaque type Conversation {
  Conversation(
    registry: Registry,
    key: String,
    token: Int,
    worker_subject: Subject(FlowMessage),
    worker_pid: Pid,
    lifecycle_subject: Subject(WorkerLifecycleMessage),
  )
}

/// Create a registry keyed by destination chat id plus sender user id.
pub fn new_registry() -> Result(Registry, RegistryError) {
  new_registry_with_key(by_chat_and_user)
}

/// Create a registry with a custom conversation key.
pub fn new_registry_with_key(key_fn: KeyFn) -> Result(Registry, RegistryError) {
  new_registry_with_options(key_fn, default_call_timeout_ms)
}

/// Create a registry with a custom key and a BEAM-safe actor-call timeout.
pub fn new_registry_with_options(
  key_fn: KeyFn,
  call_timeout_ms: Int,
) -> Result(Registry, RegistryError) {
  case clock.is_valid_process_timeout(call_timeout_ms) {
    False -> Error(InvalidCallTimeout(call_timeout_ms))
    True -> {
      let initial_state =
        RegistryState(owners: dict.new(), processes: dict.new(), next_token: 1)
      use started <- result.try(
        actor.new_with_initialiser(1000, fn(subject) {
          let selector =
            process.new_selector()
            |> process.select(subject)
            |> process.select_monitors(WorkerDown)
          actor.initialised(initial_state)
          |> actor.selecting(selector)
          |> actor.returning(subject)
          |> Ok
        })
        |> actor.on_message(handle_registry_message)
        |> actor.start
        |> result.map_error(fn(error) { StartFailed(string.inspect(error)) }),
      )
      case start_registry_lifecycle(started.pid) {
        Error(error) -> {
          // `actor.start` links the registry to this caller. Unlink before an
          // explicit cleanup kill so the constructor can return its typed
          // lifecycle-start failure instead of killing its own caller.
          process.unlink(started.pid)
          process.kill(started.pid)
          Error(error)
        }
        Ok(lifecycle) ->
          Ok(Registry(
            subject: started.data,
            pid: started.pid,
            lifecycle_subject: lifecycle.subject,
            lifecycle_pid: lifecycle.pid,
            key_fn:,
            call_timeout_ms:,
          ))
      }
    }
  }
}

/// Stop the registry and cancel all active conversations. Idempotent.
pub fn stop_registry(registry: Registry) -> Result(Nil, RegistryError) {
  case process.is_alive(registry.lifecycle_pid) {
    False -> Ok(Nil)
    True -> {
      // The lifecycle coordinator only exits after the registry and every
      // worker it acknowledged have gone DOWN. Monitoring that coordinator
      // turns normal, concurrent, and post-crash shutdown into one barrier.
      let monitor = process.monitor(registry.lifecycle_pid)
      case process.is_alive(registry.pid) {
        True -> {
          let _ =
            registry_call(registry, fn(reply) { StopRegistry(reply_to: reply) })
          Nil
        }
        False -> Nil
      }
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(monitor, RegistryStopped)
      let stopped = process.selector_receive(selector, registry.call_timeout_ms)
      process.demonitor_process(monitor)
      case stopped {
        Ok(RegistryStopped(process.ProcessDown(_, _, process.Normal))) ->
          Ok(Nil)
        Ok(RegistryStopped(process.ProcessDown(_, _, process.Killed))) ->
          Error(Stopped)
        Ok(RegistryStopped(process.ProcessDown(_, _, process.Abnormal(reason)))) ->
          case string.lowercase(string.inspect(reason)) == "noproc" {
            // A monitor installed in the tiny is_alive/monitor race reports
            // `noproc`. The coordinator can normally disappear only after the
            // full registry+workers barrier has completed.
            True -> Ok(Nil)
            False ->
              Error(StartFailed(
                "registry lifecycle coordinator crashed: "
                <> string.inspect(reason),
              ))
          }
        Ok(RegistryStopped(process.PortDown(_, _, _))) -> Error(Stopped)
        Error(_) -> Error(RegistryStopTimeout)
      }
    }
  }
}

type RegistryStopOutcome {
  RegistryStopped(process.Down)
}

// A registry lifecycle coordinator is the shutdown truth source. The registry
// start() waits for TrackStartingConversation before unlinking its worker.
// The coordinator exits normally only after the registry and all tracked
// workers have terminated, so its DOWN is a reusable shutdown barrier.
type RegistryLifecycle {
  RegistryLifecycle(subject: Subject(RegistryLifecycleMessage), pid: Pid)
}

type RegistryLifecycleState {
  RegistryLifecycleState(
    registry_pid: Pid,
    workers: Dict(Pid, TrackedConversation),
    stopping: Bool,
  )
}

type TrackedConversation {
  TrackedConversation(
    worker_monitor: Monitor,
    starter_pid: Option(Pid),
    starter_monitor: Option(Monitor),
    safe_to_kill: Bool,
  )
}

type RegistryLifecycleMessage {
  TrackStartingConversation(
    worker_pid: Pid,
    starter_pid: Pid,
    reply_to: Subject(Result(Nil, RegistryError)),
  )
  WorkerUnlinked(worker_pid: Pid, reply_to: Subject(Result(Nil, RegistryError)))
  CommitConversation(Pid)
  RegistryLifecycleDown(process.Down)
}

fn start_registry_lifecycle(
  registry_pid: Pid,
) -> Result(RegistryLifecycle, RegistryError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let _ = process.monitor(registry_pid)
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(RegistryLifecycleDown)
    actor.initialised(RegistryLifecycleState(
      registry_pid:,
      workers: dict.new(),
      stopping: False,
    ))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_registry_lifecycle_message)
  |> actor.start
  |> result.map(fn(started) {
    // The coordinator must outlive an abnormal registry/creator exit long
    // enough to drain every tracked worker and publish the shutdown barrier.
    process.unlink(started.pid)
    RegistryLifecycle(subject: started.data, pid: started.pid)
  })
  |> result.map_error(fn(error) {
    StartFailed("registry lifecycle coordinator: " <> string.inspect(error))
  })
}

fn handle_registry_lifecycle_message(
  state: RegistryLifecycleState,
  message: RegistryLifecycleMessage,
) -> actor.Next(RegistryLifecycleState, RegistryLifecycleMessage) {
  case message {
    TrackStartingConversation(worker_pid:, starter_pid:, reply_to:) -> {
      case state.stopping {
        True -> {
          process.send(reply_to, Error(Stopped))
          actor.continue(state)
        }
        False -> {
          let tracked =
            TrackedConversation(
              worker_monitor: process.monitor(worker_pid),
              starter_pid: Some(starter_pid),
              starter_monitor: Some(process.monitor(starter_pid)),
              safe_to_kill: False,
            )
          process.send(reply_to, Ok(Nil))
          actor.continue(
            RegistryLifecycleState(
              ..state,
              workers: dict.insert(state.workers, worker_pid, tracked),
            ),
          )
        }
      }
    }
    WorkerUnlinked(worker_pid:, reply_to:) ->
      case dict.get(state.workers, worker_pid) {
        Error(_) -> {
          process.send(reply_to, Error(Stopped))
          actor.continue(state)
        }
        Ok(tracked) -> {
          let unlinked = TrackedConversation(..tracked, safe_to_kill: True)
          case state.stopping {
            True -> {
              process.kill(worker_pid)
              process.send(reply_to, Error(Stopped))
            }
            False -> process.send(reply_to, Ok(Nil))
          }
          actor.continue(
            RegistryLifecycleState(
              ..state,
              workers: dict.insert(state.workers, worker_pid, unlinked),
            ),
          )
        }
      }
    CommitConversation(pid) -> {
      case dict.get(state.workers, pid) {
        Error(_) -> actor.continue(state)
        Ok(tracked) -> {
          demonitor_optional(tracked.starter_monitor)
          let committed =
            TrackedConversation(
              ..tracked,
              starter_pid: None,
              starter_monitor: None,
              safe_to_kill: True,
            )
          actor.continue(
            RegistryLifecycleState(
              ..state,
              workers: dict.insert(state.workers, pid, committed),
            ),
          )
        }
      }
    }
    RegistryLifecycleDown(process.ProcessDown(_, pid, _)) ->
      case pid == state.registry_pid {
        True -> {
          state.workers
          |> dict.to_list
          |> list.each(fn(entry) {
            let #(worker_pid, tracked) = entry
            case tracked.safe_to_kill {
              True -> process.kill(worker_pid)
              False -> Nil
            }
          })
          case dict.is_empty(state.workers) {
            True -> actor.stop()
            False ->
              actor.continue(RegistryLifecycleState(..state, stopping: True))
          }
        }
        False -> {
          let workers = case dict.get(state.workers, pid) {
            Ok(tracked) -> {
              process.demonitor_process(tracked.worker_monitor)
              demonitor_optional(tracked.starter_monitor)
              dict.delete(state.workers, pid)
            }
            Error(_) -> cancel_starts_owned_by(state.workers, pid)
          }
          case state.stopping && dict.is_empty(workers) {
            True -> actor.stop()
            False -> actor.continue(RegistryLifecycleState(..state, workers:))
          }
        }
      }
    RegistryLifecycleDown(process.PortDown(_, _, _)) -> actor.continue(state)
  }
}

fn cancel_starts_owned_by(
  workers: Dict(Pid, TrackedConversation),
  starter_pid: Pid,
) -> Dict(Pid, TrackedConversation) {
  workers
  |> dict.map_values(fn(worker_pid, tracked) {
    case tracked.starter_pid == Some(starter_pid) {
      False -> tracked
      True -> {
        process.kill(worker_pid)
        demonitor_optional(tracked.starter_monitor)
        TrackedConversation(
          ..tracked,
          starter_pid: None,
          starter_monitor: None,
          safe_to_kill: True,
        )
      }
    }
  })
}

fn demonitor_optional(monitor: Option(Monitor)) -> Nil {
  case monitor {
    Some(monitor) -> process.demonitor_process(monitor)
    None -> Nil
  }
}

type RegistryLifecycleCallOutcome {
  RegistryLifecycleReply(Result(Nil, RegistryError))
  RegistryLifecycleCallDown(process.Down)
}

fn registry_lifecycle_track_starting(
  registry: Registry,
  worker_pid: Pid,
) -> Result(Nil, RegistryError) {
  let starter_pid = process.self()
  registry_lifecycle_call(registry, fn(reply) {
    TrackStartingConversation(worker_pid:, starter_pid:, reply_to: reply)
  })
}

fn registry_lifecycle_mark_unlinked(
  registry: Registry,
  worker_pid: Pid,
) -> Result(Nil, RegistryError) {
  registry_lifecycle_call(registry, fn(reply) {
    WorkerUnlinked(worker_pid:, reply_to: reply)
  })
}

fn registry_lifecycle_call(
  registry: Registry,
  make_message: fn(Subject(Result(Nil, RegistryError))) ->
    RegistryLifecycleMessage,
) -> Result(Nil, RegistryError) {
  case process.is_alive(registry.lifecycle_pid) {
    False -> Error(Stopped)
    True -> {
      let outcome = process.new_subject()
      let broker =
        process.spawn_unlinked(fn() {
          let reply = process.new_subject()
          let monitor = process.monitor(registry.lifecycle_pid)
          process.send(registry.lifecycle_subject, make_message(reply))
          let selector =
            process.new_selector()
            |> process.select_map(reply, RegistryLifecycleReply)
            |> process.select_specific_monitor(
              monitor,
              RegistryLifecycleCallDown,
            )
          let response =
            process.selector_receive(selector, registry.call_timeout_ms)
          process.demonitor_process(monitor)
          process.send(outcome, case response {
            Ok(RegistryLifecycleReply(result)) -> result
            Ok(RegistryLifecycleCallDown(_)) -> Error(Stopped)
            Error(_) -> Error(CallTimeout)
          })
        })
      let monitor = process.monitor(broker)
      let selector =
        process.new_selector()
        |> process.select_map(outcome, RegistryLifecycleReply)
        |> process.select_specific_monitor(monitor, RegistryLifecycleCallDown)
      let response = process.selector_receive_forever(selector)
      process.demonitor_process(monitor)
      case response {
        RegistryLifecycleReply(result) -> result
        RegistryLifecycleCallDown(_) -> Error(Stopped)
      }
    }
  }
}

/// Start a conversation worker without blocking the calling middleware.
/// Registration is active before this function returns.
pub fn start(
  registry: Registry,
  ctx: Context,
  thunk: fn(WaitFn) -> Nil,
) -> Result(Conversation, ConversationError) {
  start_with_outcome(registry, ctx, thunk, fn(_) { Nil })
}

/// Start a conversation and observe its terminal worker outcome once.
///
/// The callback runs in an unlinked lifecycle process, so it must not rely on
/// the caller's mailbox. `ConversationStopped` covers explicit stop,
/// replacement by the same key, and registry termination.
/// `ConversationFailed` reports a typed infrastructure ambiguity before the
/// user thunk can continue; `ConversationCrashed` reports an untyped worker
/// exit; and normal return reports `ConversationCompleted`.
pub fn start_with_outcome(
  registry: Registry,
  ctx: Context,
  thunk: fn(WaitFn) -> Nil,
  on_outcome: OutcomeHandler,
) -> Result(Conversation, ConversationError) {
  case registry.key_fn(ctx) {
    None -> Error(MissingKey)
    Some(key) -> {
      use worker <- result.try(start_worker(registry, key, ctx))
      // Keep the actor.start link until the lifecycle coordinator has
      // acknowledged both the worker and its starter. After unlinking, caller
      // death before CommitConversation deterministically cancels the worker.
      case registry_lifecycle_track_starting(registry, worker.pid) {
        Error(error) -> {
          process.unlink(worker.pid)
          process.kill(worker.pid)
          Error(RegistryUnavailable(error))
        }
        Ok(Nil) -> {
          process.unlink(worker.pid)
          case registry_lifecycle_mark_unlinked(registry, worker.pid) {
            Error(error) -> {
              process.kill(worker.pid)
              Error(RegistryUnavailable(error))
            }
            Ok(Nil) ->
              case registry_open_call(registry, key, worker.data, worker.pid) {
                Error(error) -> {
                  process.kill(worker.pid)
                  Error(RegistryUnavailable(error))
                }
                Ok(#(token, generation)) -> {
                  let lifecycle_subject =
                    guard_worker_lifecycle(
                      registry.pid,
                      worker.pid,
                      worker.data,
                      on_outcome,
                    )
                  actor.send(
                    worker.data,
                    Begin(token:, generation:, thunk:, lifecycle_subject:),
                  )
                  process.send(
                    registry.lifecycle_subject,
                    CommitConversation(worker.pid),
                  )
                  Ok(Conversation(
                    registry:,
                    key:,
                    token:,
                    worker_subject: worker.data,
                    worker_pid: worker.pid,
                    lifecycle_subject:,
                  ))
                }
              }
          }
        }
      }
    }
  }
}

/// Stop one conversation through a bounded multi-phase shutdown.
///
/// Closing the registration, the cooperative grace period, and the hard-stop
/// confirmation each have their own bound, so total wall time can span more
/// than one registry call timeout.
pub fn stop_conversation(
  conversation: Conversation,
) -> Result(Nil, ConversationError) {
  let close_result =
    close_registration(
      conversation.registry,
      conversation.key,
      conversation.token,
    )
  process.send(conversation.lifecycle_subject, WorkerStopRequested)
  let graceful_timeout = case
    conversation.registry.call_timeout_ms < graceful_stop_timeout_ms
  {
    True -> conversation.registry.call_timeout_ms
    False -> graceful_stop_timeout_ms
  }
  let stop_result = case
    wait_for_stop(conversation.worker_pid, graceful_timeout)
  {
    Ok(Nil) as stopped -> stopped
    Error(StopTimeout) -> {
      process.kill(conversation.worker_pid)
      wait_for_stop(
        conversation.worker_pid,
        conversation.registry.call_timeout_ms,
      )
    }
    Error(error) -> Error(error)
  }
  case close_result, stop_result {
    Error(error), _ -> Error(RegistryUnavailable(error))
    _, Error(error) -> Error(error)
    Ok(Nil), Ok(Nil) -> Ok(Nil)
  }
}

// =====================================================================
//                           Middleware
// =====================================================================

/// Route replies to active conversations.
///
/// Errors that are known to have happened before routing continue downstream.
/// An outcome-unknown route fails closed so one update is never processed both
/// inside and outside the conversation.
///
/// This generic middleware cannot make polling retain an uncertain update;
/// long-polling bots should use `update_gate` at `bot.with_update_gate`.
pub fn middleware(registry: Registry) -> Middleware {
  middleware_with_error(registry, fn(error) {
    io.println_error("glammy conversation registry: " <> string.inspect(error))
  })
}

/// Route replies with an application-provided registry error handler.
pub fn middleware_with_error(
  registry: Registry,
  on_error: fn(RegistryError) -> Nil,
) -> Middleware {
  fn(ctx: Context, next: fn() -> Nil) -> Nil {
    case registry.key_fn(ctx) {
      None -> next()
      Some(key) ->
        case registry_route_call(registry, ctx.update, key) {
          Ok(True) -> Nil
          Ok(False) -> next()
          Error(RouteOutcomeUnknown) -> on_error(RouteOutcomeUnknown)
          Error(error) -> {
            on_error(error)
            next()
          }
        }
    }
  }
}

/// Route conversations at the bot's typed pre-dispatch boundary.
///
/// Long-polling users should install this with `bot.with_update_gate` instead
/// of relying on generic middleware: an ambiguous receipt becomes a gate error,
/// so the polling driver retains the update rather than acknowledging it. A
/// retained ambiguous update still needs application idempotency or a durable
/// journal before retry because its original receipt may be accepted late.
/// Register this specialized gate before a broader keyed-executor gate; the
/// first gate that returns `Consumed` short-circuits the remaining gates.
pub fn update_gate(registry: Registry) -> bot.UpdateGate {
  fn(ctx: Context) {
    case registry.key_fn(ctx) {
      None -> Ok(bot.Continue)
      Some(key) ->
        case registry_route_call(registry, ctx.update, key) {
          Ok(True) -> Ok(bot.Consumed)
          Ok(False) -> Ok(bot.Continue)
          Error(error) -> Error(registry_update_gate_error(error))
        }
    }
  }
}

fn registry_update_gate_error(error: RegistryError) -> bot.UpdateGateError {
  let #(code, message) = case error {
    InvalidCallTimeout(_) -> #(
      "conversation_invalid_call_timeout",
      "conversation registry call timeout is invalid",
    )
    StartFailed(_) -> #(
      "conversation_registry_start_failed",
      "conversation registry failed",
    )
    CallTimeout -> #(
      "conversation_registry_call_timeout",
      "conversation registry timed out",
    )
    RouteOutcomeUnknown -> #(
      "conversation_route_outcome_unknown",
      "conversation route receipt outcome is unknown",
    )
    WaitStateOutcomeUnknown -> #(
      "conversation_wait_state_outcome_unknown",
      "conversation wait-state outcome is unknown",
    )
    OpenOutcomeUnknown -> #(
      "conversation_open_outcome_unknown",
      "conversation open outcome is unknown",
    )
    RegistryStopTimeout -> #(
      "conversation_registry_stop_timeout",
      "conversation registry stop timed out",
    )
    Stopped -> #(
      "conversation_registry_stopped",
      "conversation registry is stopped",
    )
  }
  bot.UpdateGateError(code, message)
}

// =====================================================================
//                         Registry actor
// =====================================================================

type RouteReply {
  RouteAccepted
  RouteRejected
  RouteAmbiguous
}

type PendingRoute {
  PendingRoute(reply_to: Subject(RouteReply))
}

type Owner {
  Owner(
    token: Int,
    generation: Int,
    waiting: Bool,
    pending_route: Option(PendingRoute),
    subject: Subject(FlowMessage),
    pid: Pid,
    monitor: Monitor,
  )
}

type RegistryState {
  RegistryState(
    owners: Dict(String, Owner),
    processes: Dict(Pid, String),
    next_token: Int,
  )
}

type PauseWaitResult {
  PausedBeforeDelivery
  DeliveryAlreadyClaimed
  WaitRegistrationGone
}

type RegisterWaitProgress {
  WaitRegistered(generation: Int)
  WaitOwnerGone
}

type PauseWaitProgress {
  WaitPaused
  WaitDeliveryClaimed
  WaitPauseOwnerGone
}

type DeliveryReceiptProgress {
  DeliveryReceiptAccepted
  DeliveryReceiptRejected
}

type RegistryMessage {
  Open(
    key: String,
    worker_subject: Subject(FlowMessage),
    worker_pid: Pid,
    deadline_ms: Int,
    began: Subject(Nil),
    reply_to: Subject(Result(#(Int, Int), RegistryError)),
  )
  RegisterWait(
    key: String,
    token: Int,
    deadline_ms: Int,
    progress: Subject(RegisterWaitProgress),
    reply_to: Subject(Result(Option(Int), RegistryError)),
  )
  PauseWait(
    key: String,
    token: Int,
    generation: Int,
    deadline_ms: Int,
    progress: Subject(PauseWaitProgress),
    reply_to: Subject(Result(PauseWaitResult, RegistryError)),
  )
  AcceptDelivery(
    key: String,
    token: Int,
    generation: Int,
    worker_pid: Pid,
    deadline_ms: Int,
    progress: Subject(DeliveryReceiptProgress),
    reply_to: Subject(Result(Bool, RegistryError)),
  )
  Close(key: String, token: Int, reply_to: Subject(Nil))
  TryRoute(
    update: Update,
    key: String,
    deadline_ms: Int,
    began: Subject(Nil),
    reply_to: Subject(RouteReply),
  )
  StopRegistry(reply_to: Subject(Nil))
  WorkerDown(process.Down)
}

fn handle_registry_message(
  state: RegistryState,
  message: RegistryMessage,
) -> actor.Next(RegistryState, RegistryMessage) {
  case message {
    Open(key:, worker_subject:, worker_pid:, deadline_ms:, began:, reply_to:) ->
      case clock.expired(deadline_ms) || !process.is_alive(worker_pid) {
        True -> {
          process.send(reply_to, Error(CallTimeout))
          actor.continue(state)
        }
        False -> {
          // Once this marker is visible, replacing the previous owner may be
          // irreversible even if the acknowledgement misses its deadline.
          process.send(began, Nil)
          let state = remove_existing_owner(state, key, True)
          let token = state.next_token
          let monitor = process.monitor(worker_pid)
          let owner =
            Owner(
              token:,
              generation: 0,
              waiting: True,
              pending_route: None,
              subject: worker_subject,
              pid: worker_pid,
              monitor:,
            )
          process.send(reply_to, Ok(#(token, 0)))
          actor.continue(RegistryState(
            owners: dict.insert(state.owners, key, owner),
            processes: dict.insert(state.processes, worker_pid, key),
            next_token: token + 1,
          ))
        }
      }
    RegisterWait(key:, token:, deadline_ms:, progress:, reply_to:) ->
      case clock.expired(deadline_ms) {
        True -> {
          process.send(reply_to, Error(CallTimeout))
          actor.continue(state)
        }
        False ->
          case dict.get(state.owners, key) {
            Ok(owner) ->
              case
                owner.token == token && process.is_alive(owner.pid),
                owner.pending_route
              {
                True, None -> {
                  let generation = owner.generation + 1
                  // This decision marker precedes both the reply and the state
                  // transition. Since the actor is serial, observing it proves
                  // the transition will precede the next routed update.
                  process.send(progress, WaitRegistered(generation))
                  process.send(reply_to, Ok(Some(generation)))
                  actor.continue(
                    RegistryState(
                      ..state,
                      owners: dict.insert(
                        state.owners,
                        key,
                        Owner(
                          ..owner,
                          generation:,
                          waiting: True,
                          pending_route: None,
                        ),
                      ),
                    ),
                  )
                }
                _, _ -> {
                  process.send(progress, WaitOwnerGone)
                  process.send(reply_to, Ok(None))
                  actor.continue(state)
                }
              }
            Error(_) -> {
              process.send(progress, WaitOwnerGone)
              process.send(reply_to, Ok(None))
              actor.continue(state)
            }
          }
      }
    PauseWait(key:, token:, generation:, deadline_ms:, progress:, reply_to:) ->
      case clock.expired(deadline_ms) {
        True -> {
          process.send(reply_to, Error(CallTimeout))
          actor.continue(state)
        }
        False ->
          case dict.get(state.owners, key) {
            Ok(owner) ->
              case owner.token == token && owner.generation == generation {
                False -> {
                  process.send(progress, WaitPauseOwnerGone)
                  process.send(reply_to, Ok(WaitRegistrationGone))
                  actor.continue(state)
                }
                True ->
                  case owner.waiting, owner.pending_route {
                    False, Some(_) -> {
                      process.send(progress, WaitDeliveryClaimed)
                      process.send(reply_to, Ok(DeliveryAlreadyClaimed))
                      actor.continue(state)
                    }
                    False, None -> {
                      process.send(progress, WaitPauseOwnerGone)
                      process.send(reply_to, Ok(WaitRegistrationGone))
                      actor.continue(state)
                    }
                    True, _ -> {
                      process.send(progress, WaitPaused)
                      process.send(reply_to, Ok(PausedBeforeDelivery))
                      actor.continue(
                        RegistryState(
                          ..state,
                          owners: dict.insert(
                            state.owners,
                            key,
                            Owner(..owner, waiting: False),
                          ),
                        ),
                      )
                    }
                  }
              }
            Error(_) -> {
              process.send(progress, WaitPauseOwnerGone)
              process.send(reply_to, Ok(WaitRegistrationGone))
              actor.continue(state)
            }
          }
      }
    AcceptDelivery(
      key:,
      token:,
      generation:,
      worker_pid:,
      deadline_ms:,
      progress:,
      reply_to:,
    ) ->
      case clock.expired(deadline_ms) {
        True -> {
          process.send(reply_to, Error(CallTimeout))
          actor.continue(state)
        }
        False ->
          case dict.get(state.owners, key) {
            Ok(owner) ->
              case
                owner.token == token
                && owner.generation == generation
                && owner.pid == worker_pid,
                owner.pending_route
              {
                True, Some(PendingRoute(route_reply)) -> {
                  // This is the exact process-local success boundary: the
                  // matching wait has dequeued Deliver and this serial actor
                  // has accepted its receipt. It does not prove that the user
                  // thunk completed; durable replay needs an external journal.
                  process.send(progress, DeliveryReceiptAccepted)
                  process.send(route_reply, RouteAccepted)
                  process.send(reply_to, Ok(True))
                  actor.continue(
                    RegistryState(
                      ..state,
                      owners: dict.insert(
                        state.owners,
                        key,
                        Owner(..owner, pending_route: None),
                      ),
                    ),
                  )
                }
                _, _ -> {
                  process.send(progress, DeliveryReceiptRejected)
                  process.send(reply_to, Ok(False))
                  actor.continue(state)
                }
              }
            Error(_) -> {
              process.send(progress, DeliveryReceiptRejected)
              process.send(reply_to, Ok(False))
              actor.continue(state)
            }
          }
      }
    Close(key:, token:, reply_to:) -> {
      process.send(reply_to, Nil)
      case dict.get(state.owners, key) {
        Ok(owner) ->
          case owner.token == token {
            True -> actor.continue(remove_existing_owner(state, key, False))
            False -> actor.continue(state)
          }
        Error(_) -> actor.continue(state)
      }
    }
    TryRoute(update:, key:, deadline_ms:, began:, reply_to:) ->
      case dict.get(state.owners, key) {
        Ok(owner) ->
          case owner.waiting && process.is_alive(owner.pid) {
            True ->
              case begin_route(deadline_ms, began, reply_to) {
                False -> actor.continue(state)
                True -> {
                  actor.send(
                    owner.subject,
                    Deliver(
                      token: owner.token,
                      generation: owner.generation,
                      update:,
                    ),
                  )
                  actor.continue(
                    RegistryState(
                      ..state,
                      owners: dict.insert(
                        state.owners,
                        key,
                        Owner(
                          ..owner,
                          waiting: False,
                          pending_route: Some(PendingRoute(reply_to)),
                        ),
                      ),
                    ),
                  )
                }
              }
            False -> {
              case owner.pending_route {
                // A prior Deliver is still ownership-ambiguous. No later
                // update for this key may escape downstream until its receipt
                // resolves, including a polling retry of the same update.
                Some(_) -> process.send(reply_to, RouteAmbiguous)
                None -> process.send(reply_to, RouteRejected)
              }
              case process.is_alive(owner.pid) {
                True -> actor.continue(state)
                False ->
                  actor.continue(remove_existing_owner(state, key, False))
              }
            }
          }
        Error(_) -> {
          process.send(reply_to, RouteRejected)
          actor.continue(state)
        }
      }
    StopRegistry(reply_to:) -> {
      state.owners
      |> dict.values
      |> list.each(fn(owner) {
        fail_pending_route_closed(owner)
        process.kill(owner.pid)
        process.demonitor_process(owner.monitor)
      })
      process.send(reply_to, Nil)
      actor.stop()
    }
    WorkerDown(down) ->
      case down {
        process.ProcessDown(_, pid, _) ->
          case dict.get(state.processes, pid) {
            Ok(key) -> actor.continue(remove_existing_owner(state, key, False))
            Error(_) -> actor.continue(state)
          }
        process.PortDown(_, _, _) -> actor.continue(state)
      }
  }
}

fn begin_route(
  deadline_ms: Int,
  began: Subject(Nil),
  reply_to: Subject(RouteReply),
) -> Bool {
  case clock.expired(deadline_ms) {
    True -> {
      process.send(reply_to, RouteRejected)
      False
    }
    False -> {
      process.send(began, Nil)
      case clock.expired(deadline_ms) {
        True -> {
          process.send(reply_to, RouteRejected)
          False
        }
        False -> True
      }
    }
  }
}

fn remove_existing_owner(
  state: RegistryState,
  key: String,
  cancel: Bool,
) -> RegistryState {
  case dict.get(state.owners, key) {
    Error(_) -> state
    Ok(owner) -> {
      fail_pending_route_closed(owner)
      case cancel {
        True -> process.kill(owner.pid)
        False -> Nil
      }
      process.demonitor_process(owner.monitor)
      RegistryState(
        ..state,
        owners: dict.delete(state.owners, key),
        processes: dict.delete(state.processes, owner.pid),
      )
    }
  }
}

fn fail_pending_route_closed(owner: Owner) -> Nil {
  case owner.pending_route {
    // Deliver has already been sent. Without a receipt the registry cannot
    // distinguish an untouched mailbox from a dequeue followed by a crash, so
    // returning False would permit double processing downstream.
    Some(PendingRoute(reply_to)) -> process.send(reply_to, RouteAmbiguous)
    None -> Nil
  }
}

type RegistryCallOutcome(reply) {
  BrokerReply(Result(reply, RegistryError))
  BrokerDown(process.Down)
}

fn registry_call(
  registry: Registry,
  make_message: fn(Subject(reply)) -> RegistryMessage,
) -> Result(reply, RegistryError) {
  registry_call_raw(
    registry.subject,
    registry.pid,
    registry.call_timeout_ms,
    make_message,
  )
}

fn registry_call_raw(
  registry_subject: Subject(RegistryMessage),
  registry_pid: Pid,
  call_timeout_ms: Int,
  make_message: fn(Subject(reply)) -> RegistryMessage,
) -> Result(reply, RegistryError) {
  case process.is_alive(registry_pid) {
    False -> Error(Stopped)
    True -> {
      // A short-lived broker owns the reply subject. Late replies after a
      // timeout go to a dead process instead of polluting the caller mailbox.
      let outcome = process.new_subject()
      let broker =
        process.spawn_unlinked(fn() {
          process.send(
            outcome,
            registry_call_from_broker(
              registry_subject,
              registry_pid,
              call_timeout_ms,
              make_message,
            ),
          )
        })
      let monitor = process.monitor(broker)
      let selector =
        process.new_selector()
        |> process.select_map(outcome, BrokerReply)
        |> process.select_specific_monitor(monitor, BrokerDown)
      let response = process.selector_receive_forever(selector)
      process.demonitor_process(monitor)
      case response {
        BrokerReply(result) -> result
        BrokerDown(_) -> Error(Stopped)
      }
    }
  }
}

type ActorCallOutcome(reply) {
  RegistryReply(reply)
  RegistryDown(process.Down)
}

fn registry_call_from_broker(
  registry_subject: Subject(RegistryMessage),
  registry_pid: Pid,
  call_timeout_ms: Int,
  make_message: fn(Subject(reply)) -> RegistryMessage,
) -> Result(reply, RegistryError) {
  let reply = process.new_subject()
  let monitor = process.monitor(registry_pid)
  actor.send(registry_subject, make_message(reply))
  let selector =
    process.new_selector()
    |> process.select_map(reply, RegistryReply)
    |> process.select_specific_monitor(monitor, RegistryDown)
  let response = process.selector_receive(selector, call_timeout_ms)
  process.demonitor_process(monitor)
  case response {
    Ok(RegistryReply(value)) -> Ok(value)
    Ok(RegistryDown(_)) -> Error(Stopped)
    Error(_) -> Error(CallTimeout)
  }
}

fn registry_open_call(
  registry: Registry,
  key: String,
  worker_subject: Subject(FlowMessage),
  worker_pid: Pid,
) -> Result(#(Int, Int), RegistryError) {
  case process.is_alive(registry.pid) {
    False -> Error(Stopped)
    True -> {
      let deadline_ms = clock.deadline_after(registry.call_timeout_ms)
      let outcome = process.new_subject()
      let broker =
        process.spawn_unlinked(fn() {
          process.send(
            outcome,
            registry_open_call_from_broker(
              registry,
              key,
              worker_subject,
              worker_pid,
              deadline_ms,
            ),
          )
        })
      let monitor = process.monitor(broker)
      let selector =
        process.new_selector()
        |> process.select_map(outcome, BrokerReply)
        |> process.select_specific_monitor(monitor, BrokerDown)
      let response = process.selector_receive_forever(selector)
      process.demonitor_process(monitor)
      case response {
        BrokerReply(result) -> result
        BrokerDown(_) -> Error(OpenOutcomeUnknown)
      }
    }
  }
}

fn registry_open_call_from_broker(
  registry: Registry,
  key: String,
  worker_subject: Subject(FlowMessage),
  worker_pid: Pid,
  deadline_ms: Int,
) -> Result(#(Int, Int), RegistryError) {
  let reply = process.new_subject()
  let began = process.new_subject()
  let monitor = process.monitor(registry.pid)
  actor.send(
    registry.subject,
    Open(
      key:,
      worker_subject:,
      worker_pid:,
      deadline_ms:,
      began:,
      reply_to: reply,
    ),
  )
  let selector =
    process.new_selector()
    |> process.select_map(reply, RegistryReply)
    |> process.select_specific_monitor(monitor, RegistryDown)
  let response =
    process.selector_receive(selector, clock.remaining_ms(deadline_ms))
  let open_began = process.receive(began, 0) == Ok(Nil)
  process.demonitor_process(monitor)
  case response {
    Ok(RegistryReply(result)) -> result
    Ok(RegistryDown(_)) if open_began -> Error(OpenOutcomeUnknown)
    Ok(RegistryDown(_)) -> Error(Stopped)
    Error(_) if open_began -> Error(OpenOutcomeUnknown)
    Error(_) -> Error(CallTimeout)
  }
}

type WaitStateResolution(value) {
  WaitStateResolved(Result(value, RegistryError))
  WaitStateAmbiguous
}

type WaitStateBrokerOutcome(value) {
  WaitStateBrokerReply(WaitStateResolution(value))
  WaitStateBrokerDown(process.Down)
}

fn resolve_wait_state_call(
  outcome: Subject(WaitStateResolution(value)),
  broker: Pid,
) -> Result(value, RegistryError) {
  let monitor = process.monitor(broker)
  let selector =
    process.new_selector()
    |> process.select_map(outcome, WaitStateBrokerReply)
    |> process.select_specific_monitor(monitor, WaitStateBrokerDown)
  let response = process.selector_receive_forever(selector)
  process.demonitor_process(monitor)
  case response {
    WaitStateBrokerReply(WaitStateResolved(result)) -> result
    WaitStateBrokerReply(WaitStateAmbiguous) | WaitStateBrokerDown(_) -> {
      // Continuing after an ambiguous wait-state or receipt decision can lose
      // or duplicate an already-claimed update. The WaitFn boundary converts
      // this value to a typed failed outcome and fail-stops the worker before
      // user code can observe or continue under unknown ownership.
      Error(WaitStateOutcomeUnknown)
    }
  }
}

fn registry_register_wait_call(
  registry: Registry,
  key: String,
  token: Int,
) -> Result(Option(Int), RegistryError) {
  case process.is_alive(registry.pid) {
    False -> Error(Stopped)
    True -> {
      let deadline_ms = clock.deadline_after(registry.call_timeout_ms)
      let outcome = process.new_subject()
      let broker =
        process.spawn_unlinked(fn() {
          process.send(
            outcome,
            registry_register_wait_call_from_broker(
              registry,
              key,
              token,
              deadline_ms,
            ),
          )
        })
      resolve_wait_state_call(outcome, broker)
    }
  }
}

fn registry_register_wait_call_from_broker(
  registry: Registry,
  key: String,
  token: Int,
  deadline_ms: Int,
) -> WaitStateResolution(Option(Int)) {
  let reply = process.new_subject()
  let progress = process.new_subject()
  let monitor = process.monitor(registry.pid)
  actor.send(
    registry.subject,
    RegisterWait(key:, token:, deadline_ms:, progress:, reply_to: reply),
  )
  let selector =
    process.new_selector()
    |> process.select_map(reply, RegistryReply)
    |> process.select_specific_monitor(monitor, RegistryDown)
  let response =
    process.selector_receive(selector, clock.remaining_ms(deadline_ms))
  let decision = process.receive(progress, 0)
  process.demonitor_process(monitor)
  case response, decision {
    Ok(RegistryReply(result)), _ -> WaitStateResolved(result)
    Ok(RegistryDown(_)), _ -> WaitStateAmbiguous
    Error(_), Ok(WaitRegistered(generation)) ->
      WaitStateResolved(Ok(Some(generation)))
    Error(_), Ok(WaitOwnerGone) -> WaitStateResolved(Ok(None))
    Error(_), Error(_) -> WaitStateResolved(Error(CallTimeout))
  }
}

fn registry_pause_wait_call(
  registry: Registry,
  key: String,
  token: Int,
  generation: Int,
) -> Result(PauseWaitResult, RegistryError) {
  case process.is_alive(registry.pid) {
    False -> Error(Stopped)
    True -> {
      let deadline_ms = clock.deadline_after(registry.call_timeout_ms)
      let outcome = process.new_subject()
      let broker =
        process.spawn_unlinked(fn() {
          process.send(
            outcome,
            registry_pause_wait_call_from_broker(
              registry,
              key,
              token,
              generation,
              deadline_ms,
            ),
          )
        })
      resolve_wait_state_call(outcome, broker)
    }
  }
}

fn registry_pause_wait_call_from_broker(
  registry: Registry,
  key: String,
  token: Int,
  generation: Int,
  deadline_ms: Int,
) -> WaitStateResolution(PauseWaitResult) {
  let reply = process.new_subject()
  let progress = process.new_subject()
  let monitor = process.monitor(registry.pid)
  actor.send(
    registry.subject,
    PauseWait(
      key:,
      token:,
      generation:,
      deadline_ms:,
      progress:,
      reply_to: reply,
    ),
  )
  let selector =
    process.new_selector()
    |> process.select_map(reply, RegistryReply)
    |> process.select_specific_monitor(monitor, RegistryDown)
  let response =
    process.selector_receive(selector, clock.remaining_ms(deadline_ms))
  let decision = process.receive(progress, 0)
  process.demonitor_process(monitor)
  case response, decision {
    Ok(RegistryReply(Ok(value))), _ -> WaitStateResolved(Ok(value))
    Ok(RegistryReply(Error(CallTimeout))), _ -> WaitStateAmbiguous
    Ok(RegistryReply(Error(error))), _ -> WaitStateResolved(Error(error))
    Ok(RegistryDown(_)), _ -> WaitStateAmbiguous
    Error(_), Ok(WaitPaused) -> WaitStateResolved(Ok(PausedBeforeDelivery))
    Error(_), Ok(WaitDeliveryClaimed) ->
      WaitStateResolved(Ok(DeliveryAlreadyClaimed))
    Error(_), Ok(WaitPauseOwnerGone) ->
      WaitStateResolved(Ok(WaitRegistrationGone))
    Error(_), Error(_) -> WaitStateAmbiguous
  }
}

fn registry_accept_delivery_call(
  registry: Registry,
  key: String,
  token: Int,
  generation: Int,
) -> Result(Bool, RegistryError) {
  case process.is_alive(registry.pid) {
    False -> Error(Stopped)
    True -> {
      let deadline_ms = clock.deadline_after(registry.call_timeout_ms)
      let outcome = process.new_subject()
      let worker_pid = process.self()
      let broker =
        process.spawn_unlinked(fn() {
          process.send(
            outcome,
            registry_accept_delivery_call_from_broker(
              registry,
              key,
              token,
              generation,
              worker_pid,
              deadline_ms,
            ),
          )
        })
      resolve_wait_state_call(outcome, broker)
    }
  }
}

fn registry_accept_delivery_call_from_broker(
  registry: Registry,
  key: String,
  token: Int,
  generation: Int,
  worker_pid: Pid,
  deadline_ms: Int,
) -> WaitStateResolution(Bool) {
  let reply = process.new_subject()
  let progress = process.new_subject()
  let monitor = process.monitor(registry.pid)
  actor.send(
    registry.subject,
    AcceptDelivery(
      key:,
      token:,
      generation:,
      worker_pid:,
      deadline_ms:,
      progress:,
      reply_to: reply,
    ),
  )
  let selector =
    process.new_selector()
    |> process.select_map(reply, RegistryReply)
    |> process.select_specific_monitor(monitor, RegistryDown)
  let response =
    process.selector_receive(selector, clock.remaining_ms(deadline_ms))
  let decision = process.receive(progress, 0)
  process.demonitor_process(monitor)
  case response, decision {
    Ok(RegistryReply(Ok(value))), _ -> WaitStateResolved(Ok(value))
    Ok(RegistryReply(Error(CallTimeout))), _ -> WaitStateAmbiguous
    Ok(RegistryReply(Error(error))), _ -> WaitStateResolved(Error(error))
    _, Ok(DeliveryReceiptAccepted) -> WaitStateResolved(Ok(True))
    _, Ok(DeliveryReceiptRejected) -> WaitStateResolved(Ok(False))
    Ok(RegistryDown(_)), Error(_) | Error(_), Error(_) -> WaitStateAmbiguous
  }
}

fn registry_route_call(
  registry: Registry,
  update: Update,
  key: String,
) -> Result(Bool, RegistryError) {
  case process.is_alive(registry.pid) {
    False -> Error(Stopped)
    True -> {
      let deadline_ms = clock.deadline_after(registry.call_timeout_ms)
      let outcome = process.new_subject()
      let broker =
        process.spawn_unlinked(fn() {
          process.send(
            outcome,
            registry_route_call_from_broker(registry, update, key, deadline_ms),
          )
        })
      let monitor = process.monitor(broker)
      let selector =
        process.new_selector()
        |> process.select_map(outcome, BrokerReply)
        |> process.select_specific_monitor(monitor, BrokerDown)
      let response = process.selector_receive_forever(selector)
      process.demonitor_process(monitor)
      case response {
        BrokerReply(result) -> result
        // The broker may have died after the registry claimed the update but
        // before forwarding its acknowledgement. Fail closed: downstream must
        // never process the same update under that uncertainty.
        BrokerDown(_) -> Error(RouteOutcomeUnknown)
      }
    }
  }
}

fn registry_route_call_from_broker(
  registry: Registry,
  update: Update,
  key: String,
  deadline_ms: Int,
) -> Result(Bool, RegistryError) {
  let reply = process.new_subject()
  let began = process.new_subject()
  let monitor = process.monitor(registry.pid)
  actor.send(
    registry.subject,
    TryRoute(update:, key:, deadline_ms:, began:, reply_to: reply),
  )
  let selector =
    process.new_selector()
    |> process.select_map(reply, RegistryReply)
    |> process.select_specific_monitor(monitor, RegistryDown)
  let response =
    process.selector_receive(selector, clock.remaining_ms(deadline_ms))
  let route_began = process.receive(began, 0) == Ok(Nil)
  process.demonitor_process(monitor)
  case response {
    Ok(RegistryReply(RouteAccepted)) -> Ok(True)
    Ok(RegistryReply(RouteRejected)) -> Ok(False)
    Ok(RegistryReply(RouteAmbiguous)) -> Error(RouteOutcomeUnknown)
    Ok(RegistryDown(_)) if route_began -> Error(RouteOutcomeUnknown)
    Ok(RegistryDown(_)) -> Error(Stopped)
    Error(_) if route_began -> Error(RouteOutcomeUnknown)
    Error(_) -> Error(CallTimeout)
  }
}

// =====================================================================
//                        Conversation worker
// =====================================================================

type FlowMessage {
  Begin(
    token: Int,
    generation: Int,
    thunk: fn(WaitFn) -> Nil,
    lifecycle_subject: Subject(WorkerLifecycleMessage),
  )
  Deliver(token: Int, generation: Int, update: Update)
  Cancel
}

type FlowState {
  FlowState(
    registry: Registry,
    key: String,
    original: Context,
    subject: Subject(FlowMessage),
    pending: List(FlowMessage),
  )
}

fn start_worker(
  registry: Registry,
  key: String,
  original: Context,
) -> Result(actor.Started(Subject(FlowMessage)), ConversationError) {
  actor.new_with_initialiser(1000, fn(subject) {
    actor.initialised(
      FlowState(registry:, key:, original:, subject:, pending: []),
    )
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_flow_message)
  |> actor.start
  |> result.map_error(fn(error) { WorkerStartFailed(string.inspect(error)) })
}

type WorkerGuardOutcome {
  GuardRegistryDown(process.Down)
  GuardWorkerDown(process.Down)
  GuardLifecycleMessage(WorkerLifecycleMessage)
}

type WorkerLifecycleMessage {
  WorkerStopRequested
  WorkerFailed(RegistryError)
}

fn guard_worker_lifecycle(
  registry_pid: Pid,
  worker_pid: Pid,
  worker_subject: Subject(FlowMessage),
  on_outcome: OutcomeHandler,
) -> Subject(WorkerLifecycleMessage) {
  let ready: Subject(Subject(WorkerLifecycleMessage)) = process.new_subject()
  process.spawn_unlinked(fn() {
    let lifecycle_subject: Subject(WorkerLifecycleMessage) =
      process.new_subject()
    let registry_monitor = process.monitor(registry_pid)
    let worker_monitor = process.monitor(worker_pid)
    let selector =
      process.new_selector()
      |> process.select_specific_monitor(registry_monitor, GuardRegistryDown)
      |> process.select_specific_monitor(worker_monitor, GuardWorkerDown)
      |> process.select_map(lifecycle_subject, GuardLifecycleMessage)
    process.send(ready, lifecycle_subject)
    observe_worker_lifecycle(
      selector,
      registry_monitor,
      worker_monitor,
      worker_pid,
      worker_subject,
      on_outcome,
      False,
    )
  })
  process.receive_forever(ready)
}

fn observe_worker_lifecycle(
  selector: process.Selector(WorkerGuardOutcome),
  registry_monitor: Monitor,
  worker_monitor: Monitor,
  worker_pid: Pid,
  worker_subject: Subject(FlowMessage),
  on_outcome: OutcomeHandler,
  stop_requested: Bool,
) -> Nil {
  case process.selector_receive_forever(selector) {
    GuardLifecycleMessage(WorkerStopRequested) -> {
      actor.send(worker_subject, Cancel)
      observe_worker_lifecycle(
        selector,
        registry_monitor,
        worker_monitor,
        worker_pid,
        worker_subject,
        on_outcome,
        True,
      )
    }
    GuardLifecycleMessage(WorkerFailed(error)) -> {
      process.demonitor_process(registry_monitor)
      process.kill(worker_pid)
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(worker_monitor, GuardWorkerDown)
      let _ = process.selector_receive_forever(selector)
      process.demonitor_process(worker_monitor)
      on_outcome(ConversationFailed(error))
    }
    GuardRegistryDown(_) -> {
      process.demonitor_process(registry_monitor)
      process.kill(worker_pid)
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(worker_monitor, GuardWorkerDown)
      let _ = process.selector_receive_forever(selector)
      process.demonitor_process(worker_monitor)
      on_outcome(ConversationStopped)
    }
    GuardWorkerDown(down) -> {
      process.demonitor_process(registry_monitor)
      process.demonitor_process(worker_monitor)
      on_outcome(worker_outcome(down, stop_requested))
    }
  }
}

fn worker_outcome(
  down: process.Down,
  stop_requested: Bool,
) -> ConversationOutcome {
  case down {
    process.ProcessDown(_, _, process.Normal) ->
      case stop_requested {
        True -> ConversationStopped
        False -> ConversationCompleted
      }
    process.ProcessDown(_, _, process.Killed) -> ConversationStopped
    process.ProcessDown(_, _, process.Abnormal(reason)) ->
      ConversationCrashed(string.inspect(reason))
    process.PortDown(_, _, _) ->
      ConversationCrashed("conversation worker monitor received a port exit")
  }
}

fn handle_flow_message(
  state: FlowState,
  message: FlowMessage,
) -> actor.Next(FlowState, FlowMessage) {
  case message {
    Deliver(..) ->
      actor.continue(FlowState(..state, pending: [message, ..state.pending]))
    Begin(token:, generation:, thunk:, lifecycle_subject:) -> {
      state.pending
      |> list.reverse
      |> list.each(actor.send(state.subject, _))
      let registration: Subject(Option(Int)) = process.new_subject()
      process.send(registration, Some(generation))
      thunk(fn(timeout_ms) {
        case wait_for_update(state, token, registration, timeout_ms) {
          Error(RegistryUnavailableWhileWaiting(WaitStateOutcomeUnknown)) -> {
            process.send(
              lifecycle_subject,
              WorkerFailed(WaitStateOutcomeUnknown),
            )
            process.kill(process.self())
            Error(RegistryUnavailableWhileWaiting(WaitStateOutcomeUnknown))
          }
          result -> result
        }
      })
      let _ = close_registration(state.registry, state.key, token)
      actor.stop()
    }
    Cancel -> actor.stop()
  }
}

fn wait_for_update(
  state: FlowState,
  token: Int,
  registration: Subject(Option(Int)),
  timeout_ms: Int,
) -> Result(Context, WaitError) {
  case clock.is_valid_process_timeout_or_zero(timeout_ms) {
    False -> Error(InvalidWaitTimeout(timeout_ms))
    True -> wait_for_update_with_timeout(state, token, registration, timeout_ms)
  }
}

fn wait_for_update_with_timeout(
  state: FlowState,
  token: Int,
  registration: Subject(Option(Int)),
  timeout_ms: Int,
) -> Result(Context, WaitError) {
  let active_generation = process.receive_forever(registration)
  let generation_result = case active_generation {
    Some(generation) -> Ok(Some(generation))
    None ->
      registry_register_wait_call(state.registry, state.key, token)
      |> result.map_error(RegistryUnavailableWhileWaiting)
  }
  case generation_result {
    Error(error) -> {
      process.send(registration, None)
      Error(error)
    }
    Ok(None) -> {
      process.send(registration, None)
      Error(Cancelled)
    }
    Ok(Some(generation)) -> {
      let received =
        receive_delivery(state.subject, token, generation, timeout_ms)
      let result = case received {
        Ok(update) -> accept_received_update(state, token, generation, update)
        Error(Cancelled) -> Error(Cancelled)
        Error(Timeout) ->
          case
            registry_pause_wait_call(
              state.registry,
              state.key,
              token,
              generation,
            )
          {
            Error(error) -> Error(RegistryUnavailableWhileWaiting(error))
            Ok(PausedBeforeDelivery) -> Error(Timeout)
            Ok(WaitRegistrationGone) -> Error(Cancelled)
            Ok(DeliveryAlreadyClaimed) ->
              case receive_claimed_delivery(state.subject, token, generation) {
                Ok(update) ->
                  accept_received_update(state, token, generation, update)
                Error(error) -> Error(error)
              }
          }
        Error(error) -> Error(error)
      }
      // Keep the per-worker wait token held through receipt acceptance. A
      // concurrent next wait must not overwrite an unresolved pending route.
      process.send(registration, None)
      result
    }
  }
}

fn accept_received_update(
  state: FlowState,
  token: Int,
  generation: Int,
  update: Update,
) -> Result(Context, WaitError) {
  case
    registry_accept_delivery_call(state.registry, state.key, token, generation)
  {
    Ok(True) -> Ok(update_to_ctx(update, state.original))
    Ok(False) -> Error(Cancelled)
    // Deliver is already out of the mailbox. Any unresolved receipt call is
    // ownership-ambiguous, even when registry death was observed before the
    // broker could send AcceptDelivery, so the WaitFn boundary must fail-stop.
    Error(_) -> Error(RegistryUnavailableWhileWaiting(WaitStateOutcomeUnknown))
  }
}

fn receive_claimed_delivery(
  subject: Subject(FlowMessage),
  token: Int,
  generation: Int,
) -> Result(Update, WaitError) {
  case process.receive_forever(subject) {
    Cancel -> Error(Cancelled)
    Begin(..) -> receive_claimed_delivery(subject, token, generation)
    Deliver(token: delivered_token, generation: delivered_generation, update:) ->
      case delivered_token == token && delivered_generation == generation {
        True -> Ok(update)
        False -> receive_claimed_delivery(subject, token, generation)
      }
  }
}

fn receive_delivery(
  subject: Subject(FlowMessage),
  token: Int,
  generation: Int,
  timeout_ms: Int,
) -> Result(Update, WaitError) {
  receive_delivery_until(
    subject,
    token,
    generation,
    clock.deadline_after(timeout_ms),
  )
}

fn receive_delivery_until(
  subject: Subject(FlowMessage),
  token: Int,
  generation: Int,
  deadline_ms: Int,
) -> Result(Update, WaitError) {
  let remaining_ms = deadline_ms - clock.now_ms()
  case remaining_ms < 0 {
    True -> Error(Timeout)
    False ->
      case process.receive(subject, remaining_ms) {
        Error(_) -> Error(Timeout)
        Ok(Cancel) -> Error(Cancelled)
        Ok(Begin(..)) ->
          receive_delivery_until(subject, token, generation, deadline_ms)
        Ok(Deliver(
          token: delivered_token,
          generation: delivered_generation,
          update:,
        )) ->
          case delivered_token == token && delivered_generation == generation {
            True -> Ok(update)
            False ->
              receive_delivery_until(subject, token, generation, deadline_ms)
          }
      }
  }
}

fn close_registration(
  registry: Registry,
  key: String,
  token: Int,
) -> Result(Nil, RegistryError) {
  registry_call(registry, fn(reply) { Close(key:, token:, reply_to: reply) })
}

type StopOutcome {
  WorkerStopped(process.Down)
}

fn wait_for_stop(pid: Pid, timeout_ms: Int) -> Result(Nil, ConversationError) {
  case process.is_alive(pid) {
    False -> Ok(Nil)
    True -> {
      let monitor = process.monitor(pid)
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(monitor, WorkerStopped)
      let stopped = process.selector_receive(selector, timeout_ms)
      process.demonitor_process(monitor)
      case stopped {
        Ok(WorkerStopped(_)) -> Ok(Nil)
        Error(_) -> Error(StopTimeout)
      }
    }
  }
}

// =====================================================================
//                            Key helpers
// =====================================================================

/// Key a conversation by destination chat id and sender user id.
pub fn by_chat_and_user(ctx: Context) -> Option(String) {
  case context.chat_id(ctx), context.from(ctx) {
    Some(chat_id), Some(user) ->
      Some(int.to_string(chat_id) <> ":" <> int.to_string(user.id))
    _, _ -> None
  }
}

/// Key a conversation by sender user id.
pub fn by_user_id(ctx: Context) -> Option(String) {
  context.from(ctx) |> option.map(fn(user) { int.to_string(user.id) })
}

/// Key a conversation by the context's destination chat id.
pub fn by_chat_id(ctx: Context) -> Option(String) {
  context.chat_id(ctx) |> option.map(int.to_string)
}

fn update_to_ctx(update: Update, original: Context) -> Context {
  context.new(update, original.api)
}
