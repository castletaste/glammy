//// Per-chat (or per-user) session storage.
////
//// Storage processes only perform short versioned reads and compare-and-set
//// commits. User transitions run in the caller and describe any side effect
//// as an `after_commit` thunk, so slow Telegram calls never block unrelated
//// session keys and effects are not repeated during optimistic retries.
//// Present keys receive globally unique revisions. Deleted-key tombstones are
//// compacted into one absence epoch, preventing ABA without unbounded maps.
//// If a custom mutating callback does not return success after it starts, its
//// external outcome is unknowable. The adapter returns
//// `MutationOutcomeUnknown` and retires its actor so a stale local revision
//// cannot be reused; reconcile the backend and create a new adapter.

import glammy/composer.{type Composer}
import glammy/context.{type Context}
import glammy/internal/clock
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

const default_call_timeout_ms = 5000

const update_attempt_limit = 32

// =====================================================================
//                         Storage interface
// =====================================================================

/// Failures raised while starting or calling a storage actor.
pub type StorageError {
  /// Actor-call timeouts must be within BEAM's finite receive range:
  /// `1..4_294_967_295` milliseconds.
  InvalidCallTimeout(Int)
  StartFailed(String)
  CallTimeout
  /// A mutating callback began but did not produce an observed success.
  /// It may have committed externally. Reconcile before creating a fresh
  /// adapter; never blindly retry the mutation on this `Storage`.
  MutationOutcomeUnknown(StorageMutation)
  Stopped
  /// A typed failure reported by a custom backend read.
  BackendError(String)
  /// A custom backend read panicked rather than returning a value.
  BackendFailed(class: String, value: String, stacktrace: String)
  /// A pure state transition panicked.
  HandlerFailed(class: String, value: String, stacktrace: String)
  /// The value changed on every bounded optimistic retry.
  ConflictLimitReached
  /// State is already committed, but its one-shot side effect failed.
  AfterCommitFailed(class: String, value: String, stacktrace: String)
}

/// A storage operation whose external mutation outcome became unknowable.
pub type StorageMutation {
  SetMutation
  DeleteMutation
  CompareSetMutation
}

/// A running, process-safe storage adapter.
pub opaque type Storage(value) {
  Storage(
    subject: Subject(StorageMessage(value)),
    pid: Pid,
    call_timeout_ms: Int,
  )
}

type Backend(value) {
  Memory(Dict(String, value))
  Custom(
    get: fn(String) -> Result(Option(value), String),
    set: fn(String, value) -> Result(Nil, String),
    delete: fn(String) -> Result(Nil, String),
  )
}

type StorageState(value) {
  StorageState(
    backend: Backend(value),
    present_versions: Dict(String, Int),
    next_revision: Int,
    absence_epoch: Int,
  )
}

type Revision {
  Present(Int)
  Missing(Int)
}

type StorageMessage(value) {
  Get(key: String, reply_to: Subject(Result(Option(value), StorageError)))
  Set(
    key: String,
    value: value,
    deadline_ms: Int,
    began: Subject(Nil),
    reply_to: Subject(Result(Nil, StorageError)),
  )
  Delete(
    key: String,
    deadline_ms: Int,
    began: Subject(Nil),
    reply_to: Subject(Result(Nil, StorageError)),
  )
  ReadVersioned(
    key: String,
    reply_to: Subject(Result(#(Option(value), Revision), StorageError)),
  )
  CompareSet(
    key: String,
    expected_revision: Revision,
    value: value,
    deadline_ms: Int,
    began: Subject(Nil),
    reply_to: Subject(Result(Bool, StorageError)),
  )
  Stop(reply_to: Subject(Result(Nil, StorageError)))
}

/// Build a serialized storage adapter from infallible callbacks.
///
/// Use `custom_storage_result` for Redis, Postgres, or any backend that can
/// fail. Atomicity is local to this returned `Storage`; a shared distributed
/// backend still needs a cross-node transaction or CAS implementation.
pub fn custom_storage(
  get get: fn(String) -> Option(value),
  set set: fn(String, value) -> Nil,
  delete delete: fn(String) -> Nil,
) -> Result(Storage(value), StorageError) {
  custom_storage_result(
    get: fn(key) { Ok(get(key)) },
    set: fn(key, value) { Ok(set(key, value)) },
    delete: fn(key) { Ok(delete(key)) },
  )
}

/// Build an infallible custom storage with a bounded actor-call timeout.
pub fn custom_storage_with_timeout(
  get get: fn(String) -> Option(value),
  set set: fn(String, value) -> Nil,
  delete delete: fn(String) -> Nil,
  call_timeout_ms call_timeout_ms: Int,
) -> Result(Storage(value), StorageError) {
  custom_storage_result_with_timeout(
    get: fn(key) { Ok(get(key)) },
    set: fn(key, value) { Ok(set(key, value)) },
    delete: fn(key) { Ok(delete(key)) },
    call_timeout_ms:,
  )
}

/// Build a custom storage whose callbacks report backend failures explicitly.
///
/// A read callback's `Error` is returned as `BackendError`. Once a mutation
/// callback has started, neither `Error` nor a panic proves that the external
/// write was rolled back. Both become `MutationOutcomeUnknown`, and this
/// adapter is retired to prevent reuse of stale local revision state.
pub fn custom_storage_result(
  get get: fn(String) -> Result(Option(value), String),
  set set: fn(String, value) -> Result(Nil, String),
  delete delete: fn(String) -> Result(Nil, String),
) -> Result(Storage(value), StorageError) {
  custom_storage_result_with_timeout(
    get:,
    set:,
    delete:,
    call_timeout_ms: default_call_timeout_ms,
  )
}

/// Build a typed custom storage with a bounded actor-call timeout.
///
/// Backend callbacks should enforce their own network/database timeout too.
/// A mutation callback invocation is the certainty boundary: an expired
/// deadline before invocation is a definite `CallTimeout`; any unobserved
/// success afterwards is `MutationOutcomeUnknown` and retires this adapter.
pub fn custom_storage_result_with_timeout(
  get get: fn(String) -> Result(Option(value), String),
  set set: fn(String, value) -> Result(Nil, String),
  delete delete: fn(String) -> Result(Nil, String),
  call_timeout_ms call_timeout_ms: Int,
) -> Result(Storage(value), StorageError) {
  start_storage(Custom(get:, set:, delete:), call_timeout_ms)
}

/// Read a value from storage.
pub fn storage_get(
  storage: Storage(value),
  key: String,
) -> Result(Option(value), StorageError) {
  use response <- result.try(storage_call(storage, Get(key:, reply_to: _)))
  response
}

/// Write a value through storage and advance its local CAS version.
///
/// A custom callback that starts but does not return success yields
/// `MutationOutcomeUnknown` and retires this adapter.
pub fn storage_set(
  storage: Storage(value),
  key: String,
  value: value,
) -> Result(Nil, StorageError) {
  use response <- result.try(
    storage_mutation_call(storage, SetMutation, fn(reply, began, deadline_ms) {
      Set(key:, value:, deadline_ms:, began:, reply_to: reply)
    }),
  )
  response
}

/// Delete a value and advance its local CAS version.
///
/// A custom callback that starts but does not return success yields
/// `MutationOutcomeUnknown` and retires this adapter.
pub fn storage_delete(
  storage: Storage(value),
  key: String,
) -> Result(Nil, StorageError) {
  use response <- result.try(
    storage_mutation_call(
      storage,
      DeleteMutation,
      fn(reply, began, deadline_ms) {
        Delete(key:, deadline_ms:, began:, reply_to: reply)
      },
    ),
  )
  response
}

/// Atomically transform and persist one value.
///
/// `operation` must be pure and reasonably fast. It may be retried when a
/// concurrent update wins the compare-and-set race. A delete can also make
/// transitions for unrelated missing keys retry because all missing keys share
/// one bounded absence epoch.
pub fn storage_update(
  storage: Storage(value),
  key: String,
  default: value,
  operation: fn(value) -> value,
) -> Result(value, StorageError) {
  update_with_return(
    storage,
    key,
    default,
    fn(value) { #(operation(value), Nil) },
    update_attempt_limit,
  )
  |> result.map(fn(pair) { pair.0 })
}

/// Stop the storage actor. Calling this more than once is safe.
pub fn storage_stop(storage: Storage(value)) -> Result(Nil, StorageError) {
  case process.is_alive(storage.pid) {
    False -> Ok(Nil)
    True -> {
      // The actor acknowledges `Stop` immediately before returning
      // `actor.stop()`. Monitor it before the call and do not report success
      // until OTP confirms that the process is actually down; otherwise a
      // concurrent or immediately repeated stop can race the actor shutdown.
      let monitor = process.monitor(storage.pid)
      let response = storage_call(storage, Stop(reply_to: _))
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(monitor, StorageStopped)
      let stopped = process.selector_receive(selector, storage.call_timeout_ms)
      process.demonitor_process(monitor)
      case response, stopped {
        _, Ok(StorageStopped(_)) -> Ok(Nil)
        Error(error), Error(_) -> Error(error)
        Ok(_), Error(_) -> Error(CallTimeout)
      }
    }
  }
}

type StorageStopOutcome {
  StorageStopped(process.Down)
}

// =====================================================================
//                       In-memory storage actor
// =====================================================================

/// Create an in-memory storage actor.
pub fn memory_storage() -> Result(Storage(value), StorageError) {
  memory_storage_with_timeout(default_call_timeout_ms)
}

/// Create an in-memory storage actor with a bounded call timeout.
pub fn memory_storage_with_timeout(
  call_timeout_ms: Int,
) -> Result(Storage(value), StorageError) {
  start_storage(Memory(dict.new()), call_timeout_ms)
}

fn start_storage(
  backend: Backend(value),
  call_timeout_ms: Int,
) -> Result(Storage(value), StorageError) {
  case clock.is_valid_process_timeout(call_timeout_ms) {
    False -> Error(InvalidCallTimeout(call_timeout_ms))
    True ->
      actor.new(StorageState(
        backend:,
        present_versions: dict.new(),
        next_revision: 1,
        absence_epoch: 0,
      ))
      |> actor.on_message(handle_storage_message)
      |> actor.start
      |> result.map(fn(started) {
        Storage(subject: started.data, pid: started.pid, call_timeout_ms:)
      })
      |> result.map_error(fn(error) { StartFailed(string.inspect(error)) })
  }
}

fn handle_storage_message(
  state: StorageState(value),
  message: StorageMessage(value),
) -> actor.Next(StorageState(value), StorageMessage(value)) {
  case message {
    Get(key:, reply_to:) -> {
      let response = backend_get(state.backend, key)
      process.send(reply_to, result.map(response, fn(pair) { pair.0 }))
      continue_with_backend(state, response)
    }
    Set(key:, value:, deadline_ms:, began:, reply_to:) ->
      case begin_mutation(deadline_ms, began, reply_to) {
        False -> actor.continue(state)
        True -> {
          let response = backend_set(state.backend, key, value)
          case response {
            Ok(backend) -> {
              process.send(reply_to, Ok(Nil))
              actor.continue(store_present(state, backend, key))
            }
            Error(_) -> {
              process.send(reply_to, Error(MutationOutcomeUnknown(SetMutation)))
              actor.stop()
            }
          }
        }
      }
    Delete(key:, deadline_ms:, began:, reply_to:) ->
      case begin_mutation(deadline_ms, began, reply_to) {
        False -> actor.continue(state)
        True -> {
          let response = backend_delete(state.backend, key)
          case response {
            Ok(backend) -> {
              process.send(reply_to, Ok(Nil))
              actor.continue(
                StorageState(
                  ..state,
                  backend:,
                  present_versions: dict.delete(state.present_versions, key),
                  absence_epoch: state.absence_epoch + 1,
                ),
              )
            }
            Error(_) -> {
              process.send(
                reply_to,
                Error(MutationOutcomeUnknown(DeleteMutation)),
              )
              actor.stop()
            }
          }
        }
      }
    ReadVersioned(key:, reply_to:) -> {
      let response = backend_get(state.backend, key)
      case response {
        Error(error) -> {
          process.send(reply_to, Error(error))
          actor.continue(state)
        }
        Ok(#(stored, backend)) -> {
          let #(next_state, revision) = case stored {
            Some(_) -> ensure_present_revision(state, backend, key)
            None -> mark_missing(state, backend, key)
          }
          process.send(reply_to, Ok(#(stored, revision)))
          actor.continue(next_state)
        }
      }
    }
    CompareSet(
      key:,
      expected_revision:,
      value:,
      deadline_ms:,
      began:,
      reply_to:,
    ) ->
      case revision_matches(state, key, expected_revision) {
        False -> {
          process.send(reply_to, Ok(False))
          actor.continue(state)
        }
        True ->
          case begin_mutation(deadline_ms, began, reply_to) {
            False -> actor.continue(state)
            True -> {
              let response = backend_set(state.backend, key, value)
              case response {
                Ok(backend) -> {
                  process.send(reply_to, Ok(True))
                  actor.continue(store_present(state, backend, key))
                }
                Error(_) -> {
                  process.send(
                    reply_to,
                    Error(MutationOutcomeUnknown(CompareSetMutation)),
                  )
                  actor.stop()
                }
              }
            }
          }
      }
    Stop(reply_to:) -> {
      process.send(reply_to, Ok(Nil))
      actor.stop()
    }
  }
}

fn begin_mutation(
  deadline_ms: Int,
  began: Subject(Nil),
  reply_to: Subject(Result(value, StorageError)),
) -> Bool {
  case clock.expired(deadline_ms) {
    True -> {
      process.send(reply_to, Error(CallTimeout))
      False
    }
    False -> {
      process.send(began, Nil)
      case clock.expired(deadline_ms) {
        True -> {
          process.send(reply_to, Error(CallTimeout))
          False
        }
        False -> True
      }
    }
  }
}

fn continue_with_backend(
  state: StorageState(value),
  response: Result(#(read, Backend(value)), StorageError),
) -> actor.Next(StorageState(value), StorageMessage(value)) {
  case response {
    Ok(#(_, backend)) -> actor.continue(StorageState(..state, backend:))
    Error(_) -> actor.continue(state)
  }
}

fn store_present(
  state: StorageState(value),
  backend: Backend(value),
  key: String,
) -> StorageState(value) {
  StorageState(
    ..state,
    backend:,
    present_versions: dict.insert(
      state.present_versions,
      key,
      state.next_revision,
    ),
    next_revision: state.next_revision + 1,
  )
}

fn ensure_present_revision(
  state: StorageState(value),
  backend: Backend(value),
  key: String,
) -> #(StorageState(value), Revision) {
  case dict.get(state.present_versions, key) {
    Ok(revision) -> #(StorageState(..state, backend:), Present(revision))
    Error(_) -> {
      let next_state = store_present(state, backend, key)
      #(next_state, Present(state.next_revision))
    }
  }
}

fn mark_missing(
  state: StorageState(value),
  backend: Backend(value),
  key: String,
) -> #(StorageState(value), Revision) {
  let absence_epoch = case dict.has_key(state.present_versions, key) {
    True -> state.absence_epoch + 1
    False -> state.absence_epoch
  }
  let next_state =
    StorageState(
      ..state,
      backend:,
      present_versions: dict.delete(state.present_versions, key),
      absence_epoch:,
    )
  #(next_state, Missing(absence_epoch))
}

fn revision_matches(
  state: StorageState(value),
  key: String,
  expected: Revision,
) -> Bool {
  case expected {
    Present(revision) -> dict.get(state.present_versions, key) == Ok(revision)
    Missing(epoch) ->
      !dict.has_key(state.present_versions, key) && state.absence_epoch == epoch
  }
}

fn backend_get(
  backend: Backend(value),
  key: String,
) -> Result(#(Option(value), Backend(value)), StorageError) {
  case backend {
    Memory(values) -> Ok(#(option.from_result(dict.get(values, key)), backend))
    Custom(get:, ..) -> {
      use response <- result.try(safely_run_backend(fn() { get(key) }))
      use value <- result.try(result.map_error(response, BackendError))
      Ok(#(value, backend))
    }
  }
}

fn backend_set(
  backend: Backend(value),
  key: String,
  value: value,
) -> Result(Backend(value), StorageError) {
  case backend {
    Memory(values) -> Ok(Memory(dict.insert(values, key, value)))
    Custom(set:, ..) -> {
      use response <- result.try(safely_run_backend(fn() { set(key, value) }))
      use _ <- result.try(result.map_error(response, BackendError))
      Ok(backend)
    }
  }
}

fn backend_delete(
  backend: Backend(value),
  key: String,
) -> Result(Backend(value), StorageError) {
  case backend {
    Memory(values) -> Ok(Memory(dict.delete(values, key)))
    Custom(delete:, ..) -> {
      use response <- result.try(safely_run_backend(fn() { delete(key) }))
      use _ <- result.try(result.map_error(response, BackendError))
      Ok(backend)
    }
  }
}

fn update_with_return(
  storage: Storage(value),
  key: String,
  default: value,
  operation: fn(value) -> #(value, returned),
  attempts_left: Int,
) -> Result(#(value, returned), StorageError) {
  case attempts_left <= 0 {
    True -> Error(ConflictLimitReached)
    False -> {
      use response <- result.try(
        storage_call(storage, ReadVersioned(key:, reply_to: _)),
      )
      use #(stored, revision) <- result.try(response)
      let initial = option.unwrap(stored, default)
      use transition <- result.try(
        safely_run_handler(fn() { operation(initial) }),
      )
      use response <- result.try(
        storage_mutation_call(
          storage,
          CompareSetMutation,
          fn(reply, began, deadline_ms) {
            CompareSet(
              key:,
              expected_revision: revision,
              value: transition.0,
              deadline_ms:,
              began:,
              reply_to: reply,
            )
          },
        ),
      )
      use committed <- result.try(response)
      case committed {
        True -> Ok(transition)
        False ->
          update_with_return(
            storage,
            key,
            default,
            operation,
            attempts_left - 1,
          )
      }
    }
  }
}

fn storage_mutation_call(
  storage: Storage(value),
  mutation: StorageMutation,
  make_message: fn(Subject(reply), Subject(Nil), Int) -> StorageMessage(value),
) -> Result(reply, StorageError) {
  case process.is_alive(storage.pid) {
    False -> Error(Stopped)
    True -> {
      let deadline_ms = clock.deadline_after(storage.call_timeout_ms)
      let outcome = process.new_subject()
      let broker =
        process.spawn_unlinked(fn() {
          process.send(
            outcome,
            storage_mutation_call_from_broker(
              storage,
              mutation,
              deadline_ms,
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

fn storage_mutation_call_from_broker(
  storage: Storage(value),
  mutation: StorageMutation,
  deadline_ms: Int,
  make_message: fn(Subject(reply), Subject(Nil), Int) -> StorageMessage(value),
) -> Result(reply, StorageError) {
  let reply = process.new_subject()
  let began = process.new_subject()
  let monitor = process.monitor(storage.pid)
  actor.send(storage.subject, make_message(reply, began, deadline_ms))
  let selector =
    process.new_selector()
    |> process.select_map(reply, ActorReply)
    |> process.select_specific_monitor(monitor, StorageDown)
  let response =
    process.selector_receive(selector, clock.remaining_ms(deadline_ms))
  let mutation_began = process.receive(began, 0) == Ok(Nil)
  process.demonitor_process(monitor)
  case response {
    Ok(ActorReply(value)) -> Ok(value)
    Ok(StorageDown(_)) if mutation_began ->
      Error(MutationOutcomeUnknown(mutation))
    Ok(StorageDown(_)) -> Error(Stopped)
    Error(_) if mutation_began -> Error(MutationOutcomeUnknown(mutation))
    Error(_) -> Error(CallTimeout)
  }
}

type CallOutcome(reply) {
  BrokerReply(Result(reply, StorageError))
  BrokerDown(process.Down)
}

fn storage_call(
  storage: Storage(value),
  make_message: fn(Subject(reply)) -> StorageMessage(value),
) -> Result(reply, StorageError) {
  case process.is_alive(storage.pid) {
    False -> Error(Stopped)
    True -> {
      // The broker owns the actor reply subject. If the call times out it
      // exits, so a late actor response is discarded instead of leaking an
      // unselectable message into the long-lived caller's mailbox.
      let outcome = process.new_subject()
      let broker =
        process.spawn_unlinked(fn() {
          process.send(outcome, storage_call_from_broker(storage, make_message))
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
  ActorReply(reply)
  StorageDown(process.Down)
}

fn storage_call_from_broker(
  storage: Storage(value),
  make_message: fn(Subject(reply)) -> StorageMessage(value),
) -> Result(reply, StorageError) {
  let reply = process.new_subject()
  let monitor = process.monitor(storage.pid)
  actor.send(storage.subject, make_message(reply))
  let selector =
    process.new_selector()
    |> process.select_map(reply, ActorReply)
    |> process.select_specific_monitor(monitor, StorageDown)
  let response = process.selector_receive(selector, storage.call_timeout_ms)
  process.demonitor_process(monitor)
  case response {
    Ok(ActorReply(value)) -> Ok(value)
    Ok(StorageDown(_)) -> Error(Stopped)
    Error(_) -> Error(CallTimeout)
  }
}

fn safely_run_backend(operation: fn() -> value) -> Result(value, StorageError) {
  let reply: Subject(value) = process.new_subject()
  case try_run(fn() { process.send(reply, operation()) }) {
    Ok(Nil) ->
      case process.receive(reply, 0) {
        Ok(value) -> Ok(value)
        Error(_) ->
          Error(BackendFailed(
            class: "error",
            value: "backend returned without a value",
            stacktrace: "[]",
          ))
      }
    Error(#(class, value, stacktrace)) ->
      Error(BackendFailed(class:, value:, stacktrace:))
  }
}

fn safely_run_handler(operation: fn() -> value) -> Result(value, StorageError) {
  let reply: Subject(value) = process.new_subject()
  case try_run(fn() { process.send(reply, operation()) }) {
    Ok(Nil) ->
      case process.receive(reply, 0) {
        Ok(value) -> Ok(value)
        Error(_) ->
          Error(HandlerFailed(
            class: "error",
            value: "handler returned without a value",
            stacktrace: "[]",
          ))
      }
    Error(#(class, value, stacktrace)) ->
      Error(HandlerFailed(class:, value:, stacktrace:))
  }
}

fn safely_run_after_commit(
  operation: fn() -> Nil,
) -> Result(Nil, StorageError) {
  case try_run(operation) {
    Ok(Nil) -> Ok(Nil)
    Error(#(class, value, stacktrace)) ->
      Error(AfterCommitFailed(class:, value:, stacktrace:))
  }
}

@external(erlang, "glammy_ffi", "try_run")
fn try_run(operation: fn() -> Nil) -> Result(Nil, #(String, String, String))

// =====================================================================
//                          Key functions
// =====================================================================

/// Derives the storage key used to associate a context with session state.
pub type KeyFn =
  fn(Context) -> Option(String)

/// Key by the context's destination chat id.
pub fn by_chat_id(ctx: Context) -> Option(String) {
  context.chat_id(ctx) |> option.map(int.to_string)
}

/// Key by `from.id`.
pub fn by_user_id(ctx: Context) -> Option(String) {
  context.from(ctx)
  |> option.map(fn(user) { int.to_string(user.id) })
}

/// Key by both chat and user combined.
pub fn by_chat_and_user(ctx: Context) -> Option(String) {
  case context.chat_id(ctx), context.from(ctx) {
    Some(chat_id), Some(user) ->
      Some(int.to_string(chat_id) <> ":" <> int.to_string(user.id))
    _, _ -> None
  }
}

// =====================================================================
//                         Composer integration
// =====================================================================

/// A pure next value plus a one-shot effect to run after commit.
pub opaque type SessionUpdate(value) {
  SessionUpdate(value: value, after_commit: fn() -> Nil)
}

/// Persist a value without a post-commit effect.
pub fn update(value: value) -> SessionUpdate(value) {
  SessionUpdate(value:, after_commit: fn() { Nil })
}

/// Persist a value, then invoke `after_commit` at most once after an observed
/// commit.
///
/// The thunk is not repeated across optimistic retries. A process crash after
/// commit can omit it; use a transactional outbox when durable delivery is
/// required.
pub fn update_then(
  value: value,
  after_commit: fn() -> Nil,
) -> SessionUpdate(value) {
  SessionUpdate(value:, after_commit:)
}

/// Attach an optimistic, atomic session transition to a composer.
///
/// The handler must only construct a `SessionUpdate`; put API calls, replies,
/// and other effects in `update_then`. On storage failure `on_error` is called
/// and the middleware chain stops for that update.
pub fn with_session(
  composer: Composer,
  storage: Storage(value),
  key_fn: KeyFn,
  default: value,
  handler: fn(Context, value) -> SessionUpdate(value),
  on_error on_error: fn(Context, StorageError) -> Nil,
) -> Composer {
  composer.use_middleware(composer, fn(ctx, next) {
    case run(storage, ctx, key_fn, default, handler) {
      Ok(Nil) -> next()
      Error(error) -> on_error(ctx, error)
    }
  })
}

/// Atomically commit one session transition and invoke its effect at most once
/// after this process observes the commit. An unknown mutation outcome never
/// runs the effect; reconcile the custom backend before deciding whether the
/// durable transition or its effect still needs compensation.
pub fn run(
  storage: Storage(value),
  ctx: Context,
  key_fn: KeyFn,
  default: value,
  handler: fn(Context, value) -> SessionUpdate(value),
) -> Result(Nil, StorageError) {
  case key_fn(ctx) {
    None -> Ok(Nil)
    Some(key) -> {
      use #(_, after_commit) <- result.try(update_with_return(
        storage,
        key,
        default,
        fn(value) {
          let SessionUpdate(value:, after_commit:) = handler(ctx, value)
          #(value, after_commit)
        },
        update_attempt_limit,
      ))
      safely_run_after_commit(after_commit)
    }
  }
}
