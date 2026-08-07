//// Session storage, atomicity, failure, and lifecycle tests.

import glammy/composer
import glammy/context
import glammy/helpers.{
  dummy_api, message_update as make_message, no_event, receive_event, receive_n,
}
import glammy/session
import glammy/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/system
import gleam/string

const timeout_protocol_ms = 75

const stop_stress_count = 32

fn memory_storage() -> session.Storage(value) {
  let assert Ok(storage) = session.memory_storage()
  storage
}

fn ignore_storage_error(_ctx, _error) -> Nil {
  Nil
}

// =====================================================================
//                      Storage interface tests
// =====================================================================

pub fn storage_round_trips_test() {
  let storage = memory_storage()

  assert session.storage_get(storage, "k") == Ok(None)
  assert session.storage_set(storage, "k", 42) == Ok(Nil)
  assert session.storage_get(storage, "k") == Ok(Some(42))
  assert session.storage_set(storage, "k", 100) == Ok(Nil)
  assert session.storage_get(storage, "k") == Ok(Some(100))
  assert session.storage_delete(storage, "k") == Ok(Nil)
  assert session.storage_get(storage, "k") == Ok(None)
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn storage_keys_are_independent_test() {
  let storage: session.Storage(String) = memory_storage()
  assert session.storage_set(storage, "a", "alpha") == Ok(Nil)
  assert session.storage_set(storage, "b", "beta") == Ok(Nil)
  assert session.storage_get(storage, "a") == Ok(Some("alpha"))
  assert session.storage_get(storage, "b") == Ok(Some("beta"))
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn storage_calls_fail_after_stop_test() {
  let storage: session.Storage(Int) = memory_storage()
  assert session.storage_stop(storage) == Ok(Nil)
  assert session.storage_stop(storage) == Ok(Nil)
  assert session.storage_get(storage, "k") == Error(session.Stopped)
}

pub fn invalid_call_timeout_is_rejected_test() {
  assert session.memory_storage_with_timeout(0)
    == Error(session.InvalidCallTimeout(0))
}

pub fn process_timeout_boundary_is_validated_test() {
  let maximum: Result(session.Storage(Int), session.StorageError) =
    session.memory_storage_with_timeout(4_294_967_295)
  let assert Ok(storage) = maximum
  assert session.storage_stop(storage) == Ok(Nil)

  let too_large: Result(session.Storage(Int), session.StorageError) =
    session.memory_storage_with_timeout(4_294_967_296)
  assert too_large == Error(session.InvalidCallTimeout(4_294_967_296))
}

pub fn bounded_storage_call_times_out_test() {
  let backend_finished: process.Subject(Nil) = process.new_subject()
  let assert Ok(storage) =
    session.custom_storage_with_timeout(
      get: fn(_key) {
        process.sleep(75)
        process.send(backend_finished, Nil)
        None
      },
      set: fn(_, _) { Nil },
      delete: fn(_) { Nil },
      call_timeout_ms: 10,
    )

  assert session.storage_get(storage, "slow") == Error(session.CallTimeout)
  assert receive_event(backend_finished) == Ok(Nil)
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn queued_storage_set_expires_without_running_callback_test() {
  let get_started: process.Subject(process.Subject(Nil)) = process.new_subject()
  let get_result: process.Subject(Result(Option(Int), session.StorageError)) =
    process.new_subject()
  let set_calls: process.Subject(Nil) = process.new_subject()
  let assert Ok(storage) =
    session.custom_storage_with_timeout(
      get: fn(_) {
        let release: process.Subject(Nil) = process.new_subject()
        process.send(get_started, release)
        process.receive_forever(release)
        None
      },
      set: fn(_, _) { process.send(set_calls, Nil) },
      delete: fn(_) { Nil },
      call_timeout_ms: timeout_protocol_ms,
    )

  let _ =
    process.spawn_unlinked(fn() {
      process.send(get_result, session.storage_get(storage, "blocker"))
    })
  let assert Ok(release_get) = receive_event(get_started)

  // `Set` is queued behind the blocked `Get`, so its deadline elapses before
  // the actor can emit `began`. It is therefore safe to retry and must not run
  // the backend callback later when the actor drains its mailbox.
  assert session.storage_set(storage, "k", 42) == Error(session.CallTimeout)
  assert receive_event(get_result) == Ok(Error(session.CallTimeout))
  process.send(release_get, Nil)

  // Stop is queued after Set. Its DOWN acknowledgement is also our barrier
  // proving the actor inspected and rejected the expired Set.
  assert session.storage_stop(storage) == Ok(Nil)
  assert no_event(set_calls)
}

pub fn started_storage_set_reports_unknown_then_completes_test() {
  let set_started: process.Subject(process.Subject(Nil)) = process.new_subject()
  let set_completed: process.Subject(Nil) = process.new_subject()
  let result: process.Subject(Result(Nil, session.StorageError)) =
    process.new_subject()
  let assert Ok(storage) =
    session.custom_storage_with_timeout(
      get: fn(_) { None },
      set: fn(_, _) {
        let release: process.Subject(Nil) = process.new_subject()
        process.send(set_started, release)
        process.receive_forever(release)
        process.send(set_completed, Nil)
      },
      delete: fn(_) { Nil },
      call_timeout_ms: timeout_protocol_ms,
    )

  let _ =
    process.spawn_unlinked(fn() {
      process.send(result, session.storage_set(storage, "k", 42))
    })
  let assert Ok(release_set) = receive_event(set_started)

  assert receive_event(result)
    == Ok(Error(session.MutationOutcomeUnknown(session.SetMutation)))
  process.send(release_set, Nil)
  assert receive_event(set_completed) == Ok(Nil)
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn concurrent_storage_stop_is_idempotent_and_waits_for_down_test() {
  let storage: session.Storage(Int) = memory_storage()
  let ready: process.Subject(process.Subject(Nil)) = process.new_subject()
  let outcomes: process.Subject(Result(Nil, session.StorageError)) =
    process.new_subject()

  list_each_int(stop_stress_count, fn(_) {
    let _ =
      process.spawn_unlinked(fn() {
        let release: process.Subject(Nil) = process.new_subject()
        process.send(ready, release)
        process.receive_forever(release)
        process.send(outcomes, session.storage_stop(storage))
      })
    Nil
  })
  collect_release_subjects(ready, stop_stress_count)
  |> list.each(fn(release) { process.send(release, Nil) })

  assert receive_ok_nil_results(outcomes, stop_stress_count)
  assert session.storage_stop(storage) == Ok(Nil)
  assert session.storage_stop(storage) == Ok(Nil)
  assert session.storage_get(storage, "k") == Error(session.Stopped)
}

pub fn backend_panics_are_typed_errors_test() {
  let assert Ok(storage) =
    session.custom_storage(
      get: fn(_) { panic as "backend exploded" },
      set: fn(_, _) { Nil },
      delete: fn(_) { Nil },
    )

  case session.storage_get(storage, "k") {
    Error(error) -> {
      let description = string.inspect(error)
      assert string.contains(description, "BackendFailed")
      assert string.contains(description, "backend exploded")
    }
    _ -> panic as "expected BackendFailed"
  }
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn storage_set_lost_ack_is_unknown_and_retires_storage_test() {
  let committed: process.Subject(Nil) = process.new_subject()
  let assert Ok(storage) =
    session.custom_storage_result(
      get: fn(_) { Ok(None) },
      set: fn(_, _) {
        process.send(committed, Nil)
        Error("lost acknowledgement")
      },
      delete: fn(_) { Ok(Nil) },
    )

  let outcome = session.storage_set(storage, "k", 1)
  assert receive_event(committed) == Ok(Nil)
  assert outcome == Error(session.MutationOutcomeUnknown(session.SetMutation))

  // The adapter cannot reuse its now-stale local revision after an external
  // commit whose acknowledgement was lost.
  assert session.storage_stop(storage) == Ok(Nil)
  assert session.storage_get(storage, "k") == Error(session.Stopped)
}

pub fn session_backend_panic_after_commit_is_unknown_and_skips_effect_test() {
  let committed: process.Subject(Nil) = process.new_subject()
  let effects: process.Subject(Nil) = process.new_subject()
  let assert Ok(storage) =
    session.custom_storage_result(
      get: fn(_) { Ok(Some(0)) },
      set: fn(_, _) {
        process.send(committed, Nil)
        panic as "backend panicked after commit"
      },
      delete: fn(_) { Ok(Nil) },
    )

  let outcome =
    session.run(
      storage,
      context.new(make_message("hi", 1), dummy_api()),
      session.by_chat_id,
      0,
      fn(_, count) {
        session.update_then(count + 1, fn() { process.send(effects, Nil) })
      },
    )

  assert receive_event(committed) == Ok(Nil)
  assert outcome
    == Error(session.MutationOutcomeUnknown(session.CompareSetMutation))
  assert no_event(effects)
  assert session.storage_stop(storage) == Ok(Nil)
  assert session.storage_get(storage, "1") == Error(session.Stopped)
  assert no_event(effects)
}

pub fn update_handler_panics_are_typed_errors_test() {
  let storage: session.Storage(Int) = memory_storage()
  let result =
    session.storage_update(storage, "k", 0, fn(_) { panic as "handler exploded" })
  case result {
    Error(error) -> {
      let description = string.inspect(error)
      assert string.contains(description, "HandlerFailed")
      assert string.contains(description, "handler exploded")
    }
    _ -> panic as "expected HandlerFailed"
  }
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn after_commit_failure_preserves_committed_state_test() {
  let storage: session.Storage(Int) = memory_storage()
  let result =
    session.run(
      storage,
      context.new(make_message("hi", 1), dummy_api()),
      session.by_chat_id,
      0,
      fn(_, count) {
        session.update_then(count + 1, fn() { panic as "effect exploded" })
      },
    )
  case result {
    Error(error) -> {
      let description = string.inspect(error)
      assert string.contains(description, "AfterCommitFailed")
      assert string.contains(description, "effect exploded")
    }
    _ -> panic as "expected AfterCommitFailed"
  }
  assert session.storage_get(storage, "1") == Ok(Some(1))
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn session_run_started_cas_timeout_skips_after_commit_test() {
  let cas_started: process.Subject(process.Subject(Nil)) = process.new_subject()
  let cas_completed: process.Subject(Nil) = process.new_subject()
  let effects: process.Subject(Nil) = process.new_subject()
  let outcome: process.Subject(Result(Nil, session.StorageError)) =
    process.new_subject()
  let assert Ok(storage) =
    session.custom_storage_with_timeout(
      get: fn(_) { Some(0) },
      set: fn(_, _) {
        let release: process.Subject(Nil) = process.new_subject()
        process.send(cas_started, release)
        process.receive_forever(release)
        process.send(cas_completed, Nil)
      },
      delete: fn(_) { Nil },
      call_timeout_ms: timeout_protocol_ms,
    )

  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        outcome,
        session.run(
          storage,
          context.new(make_message("hi", 1), dummy_api()),
          session.by_chat_id,
          0,
          fn(_, count) {
            session.update_then(count + 1, fn() { process.send(effects, Nil) })
          },
        ),
      )
    })
  let assert Ok(release_cas) = receive_event(cas_started)

  assert receive_event(outcome)
    == Ok(Error(session.MutationOutcomeUnknown(session.CompareSetMutation)))
  assert no_event(effects)
  process.send(release_cas, Nil)
  assert receive_event(cas_completed) == Ok(Nil)
  assert session.storage_stop(storage) == Ok(Nil)
  assert no_event(effects)
}

// =====================================================================
//                       Middleware behaviour
// =====================================================================

pub fn with_session_loads_and_persists_test() {
  let recorder: process.Subject(Int) = process.new_subject()
  let storage: session.Storage(Int) = memory_storage()

  let comp =
    composer.new()
    |> session.with_session(
      storage,
      session.by_chat_id,
      0,
      fn(_ctx, count) {
        let next = count + 1
        session.update_then(next, fn() { process.send(recorder, next) })
      },
      on_error: ignore_storage_error,
    )

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))

  assert receive_event(recorder) == Ok(1)
  assert receive_event(recorder) == Ok(2)
  assert receive_event(recorder) == Ok(3)
  assert session.storage_get(storage, "1") == Ok(Some(3))
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn concurrent_session_updates_are_atomic_test() {
  let storage: session.Storage(Int) = memory_storage()
  let ready: process.Subject(process.Subject(Nil)) = process.new_subject()
  let completed: process.Subject(Nil) = process.new_subject()
  let effects: process.Subject(Nil) = process.new_subject()
  let failures: process.Subject(session.StorageError) = process.new_subject()

  list_each_int(20, fn(_) {
    let _ =
      process.spawn(fn() {
        // Every worker reaches its first transition after reading version 0,
        // then waits on its own gate. Retries skip the barrier.
        let first_attempt: process.Subject(Bool) = process.new_subject()
        process.send(first_attempt, True)
        let comp =
          composer.new()
          |> session.with_session(
            storage,
            session.by_chat_id,
            0,
            fn(_, count) {
              let assert Ok(is_first) = process.receive(first_attempt, 0)
              process.send(first_attempt, False)
              case is_first {
                True -> {
                  let release: process.Subject(Nil) = process.new_subject()
                  process.send(ready, release)
                  process.receive_forever(release)
                }
                False -> Nil
              }
              session.update_then(count + 1, fn() { process.send(effects, Nil) })
            },
            on_error: fn(_, error) { process.send(failures, error) },
          )
        composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
        process.send(completed, Nil)
      })
    Nil
  })

  collect_release_subjects(ready, 20)
  |> list.each(fn(release) { process.send(release, Nil) })
  assert receive_n(completed, 20)
  assert receive_n(effects, 20)
  assert no_event(effects)
  assert no_event(failures)
  assert session.storage_get(storage, "1") == Ok(Some(20))
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn missing_revision_rejects_set_delete_recreate_aba_test() {
  let storage: session.Storage(Int) = memory_storage()
  let ready: process.Subject(process.Subject(Nil)) = process.new_subject()
  let completed: process.Subject(Result(Int, session.StorageError)) =
    process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let first_attempt: process.Subject(Bool) = process.new_subject()
      process.send(first_attempt, True)
      let result =
        session.storage_update(storage, "k", 0, fn(value) {
          let assert Ok(is_first) = process.receive(first_attempt, 0)
          process.send(first_attempt, False)
          case is_first {
            True -> {
              let release: process.Subject(Nil) = process.new_subject()
              process.send(ready, release)
              process.receive_forever(release)
            }
            False -> Nil
          }
          value + 1
        })
      process.send(completed, result)
    })

  let assert Ok(release) = receive_event(ready)
  assert session.storage_set(storage, "k", 1) == Ok(Nil)
  assert session.storage_delete(storage, "k") == Ok(Nil)
  assert session.storage_set(storage, "k", 5) == Ok(Nil)
  process.send(release, Nil)

  assert receive_event(completed) == Ok(Ok(6))
  assert session.storage_get(storage, "k") == Ok(Some(6))
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn present_revision_rejects_set_delete_recreate_aba_test() {
  let storage: session.Storage(Int) = memory_storage()
  assert session.storage_set(storage, "k", 0) == Ok(Nil)
  let ready: process.Subject(process.Subject(Nil)) = process.new_subject()
  let completed: process.Subject(Result(Int, session.StorageError)) =
    process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let first_attempt: process.Subject(Bool) = process.new_subject()
      process.send(first_attempt, True)
      let result =
        session.storage_update(storage, "k", 0, fn(value) {
          let assert Ok(is_first) = process.receive(first_attempt, 0)
          process.send(first_attempt, False)
          case is_first {
            True -> {
              let release: process.Subject(Nil) = process.new_subject()
              process.send(ready, release)
              process.receive_forever(release)
            }
            False -> Nil
          }
          value + 1
        })
      process.send(completed, result)
    })

  let assert Ok(release) = receive_event(ready)
  assert session.storage_set(storage, "k", 1) == Ok(Nil)
  assert session.storage_delete(storage, "k") == Ok(Nil)
  assert session.storage_set(storage, "k", 5) == Ok(Nil)
  process.send(release, Nil)

  assert receive_event(completed) == Ok(Ok(6))
  assert session.storage_get(storage, "k") == Ok(Some(6))
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn deleted_key_revision_metadata_is_compacted_under_churn_test() {
  let storage: session.Storage(Int) = memory_storage()
  list_each_int(500, fn(index) {
    let key = "gone-" <> int.to_string(index)
    assert session.storage_set(storage, key, index) == Ok(Nil)
    assert session.storage_delete(storage, key) == Ok(Nil)
  })

  let state = system.get_state(from: storage_pid(3, storage))
  let versions = storage_present_versions(3, state)
  assert dict.size(versions) == 0
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn different_chats_have_independent_sessions_test() {
  let storage: session.Storage(Int) = memory_storage()
  let comp =
    composer.new()
    |> session.with_session(
      storage,
      session.by_chat_id,
      0,
      fn(_, count) { session.update(count + 1) },
      on_error: ignore_storage_error,
    )

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 2), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  assert session.storage_get(storage, "1") == Ok(Some(2))
  assert session.storage_get(storage, "2") == Ok(Some(1))
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn session_chain_continues_after_success_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let storage: session.Storage(Int) = memory_storage()
  let comp =
    composer.new()
    |> session.with_session(
      storage,
      session.by_chat_id,
      0,
      fn(_, count) {
        session.update_then(count, fn() { process.send(recorder, "session") })
      },
      on_error: ignore_storage_error,
    )
    |> composer.handle(fn(_) { process.send(recorder, "after") })

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  assert receive_event(recorder) == Ok("session")
  assert receive_event(recorder) == Ok("after")
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn storage_failure_calls_handler_and_stops_chain_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let storage: session.Storage(Int) = memory_storage()
  assert session.storage_stop(storage) == Ok(Nil)
  let comp =
    composer.new()
    |> session.with_session(
      storage,
      session.by_chat_id,
      0,
      fn(_, count) { session.update(count + 1) },
      on_error: fn(_, error) {
        case error {
          session.Stopped -> process.send(recorder, "stopped")
          _ -> process.send(recorder, "other")
        }
      },
    )
    |> composer.handle(fn(_) { process.send(recorder, "downstream") })

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  assert receive_event(recorder) == Ok("stopped")
  assert no_event(recorder)
}

pub fn skips_when_key_fn_returns_none_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let storage: session.Storage(Int) = memory_storage()
  let comp =
    composer.new()
    |> session.with_session(
      storage,
      fn(_) { None },
      0,
      fn(_, count) {
        session.update_then(count, fn() { process.send(recorder, "ran") })
      },
      on_error: ignore_storage_error,
    )
    |> composer.handle(fn(_) { process.send(recorder, "next") })

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  assert receive_event(recorder) == Ok("next")
  assert no_event(recorder)
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn does_io_with_objects_test() {
  let storage: session.Storage(Dict(String, Int)) = memory_storage()
  let comp =
    composer.new()
    |> session.with_session(
      storage,
      session.by_chat_id,
      dict.new(),
      fn(_, values) {
        session.update(dict.insert(values, int.to_string(dict.size(values)), 0))
      },
      on_error: ignore_storage_error,
    )

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  let assert Ok(Some(values)) = session.storage_get(storage, "1")
  assert dict.size(values) == 3
  assert session.storage_stop(storage) == Ok(Nil)
}

// =====================================================================
//                       Custom storage backend
// =====================================================================

pub fn works_with_custom_storage_test() {
  let calls: process.Subject(String) = process.new_subject()

  let read = fn(key: String) -> Option(Int) {
    process.send(calls, "read:" <> key)
    None
  }
  let write = fn(key: String, value: Int) -> Nil {
    process.send(calls, "write:" <> key <> "=" <> int.to_string(value))
  }
  let delete = fn(_key: String) -> Nil { Nil }
  let assert Ok(storage) =
    session.custom_storage(get: read, set: write, delete: delete)

  assert session.storage_update(storage, "42", 0, fn(count) { count + 1 })
    == Ok(1)
  assert receive_event(calls) == Ok("read:42")
  assert receive_event(calls) == Ok("write:42=1")
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn custom_storage_delete_callback_runs_exactly_once_test() {
  let calls: process.Subject(String) = process.new_subject()
  let assert Ok(storage) =
    session.custom_storage(
      get: fn(_) { None },
      set: fn(_, _) { Nil },
      delete: fn(key) { process.send(calls, "delete:" <> key) },
    )

  assert session.storage_delete(storage, "42") == Ok(Nil)
  assert receive_event(calls) == Ok("delete:42")
  assert no_event(calls)
  assert session.storage_stop(storage) == Ok(Nil)
}

pub fn typed_custom_storage_preserves_backend_error_test() {
  let assert Ok(storage) =
    session.custom_storage_result(
      get: fn(_) { Error("redis unavailable") },
      set: fn(_, _) { Ok(Nil) },
      delete: fn(_) { Ok(Nil) },
    )
  assert session.storage_get(storage, "k")
    == Error(session.BackendError("redis unavailable"))
  assert session.storage_stop(storage) == Ok(Nil)
}

// =====================================================================
//                            Key functions
// =====================================================================

const message_with_user = "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":7,\"type\":\"private\"},\"date\":0,\"text\":\"hi\",\"from\":{\"id\":99,\"is_bot\":false,\"first_name\":\"U\"}}}"

const business_connection_with_user = "{\"update_id\":2,\"business_connection\":{\"id\":\"conn\",\"user\":{\"id\":99,\"is_bot\":false,\"first_name\":\"U\"},\"user_chat_id\":700,\"date\":1,\"is_enabled\":true}}"

pub fn built_in_key_functions_test() {
  let assert Ok(update) = json.parse(message_with_user, types.update_decoder())
  let ctx = context.new(update, dummy_api())
  assert session.by_chat_id(ctx) == Some("7")
  assert session.by_user_id(ctx) == Some("99")
  assert session.by_chat_and_user(ctx) == Some("7:99")

  let assert Ok(business_update) =
    json.parse(business_connection_with_user, types.update_decoder())
  let business_ctx = context.new(business_update, dummy_api())
  assert session.by_chat_id(business_ctx) == Some("700")
  assert session.by_user_id(business_ctx) == Some("99")
  assert session.by_chat_and_user(business_ctx) == Some("700:99")
}

pub fn works_with_custom_session_keys_test() {
  let storage: session.Storage(Int) = memory_storage()
  let key_by_square = fn(ctx) {
    case context.chat(ctx) {
      Some(chat) -> Some("xyz-" <> int.to_string(chat.id * chat.id))
      None -> None
    }
  }
  let comp =
    composer.new()
    |> session.with_session(
      storage,
      key_by_square,
      0,
      fn(_, count) { session.update(count + 1) },
      on_error: ignore_storage_error,
    )

  composer.run(comp, context.new(make_message("hi", 42), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 42), dummy_api()))
  assert session.storage_get(storage, "xyz-1764") == Ok(Some(2))
  assert session.storage_stop(storage) == Ok(Nil)
}

fn collect_release_subjects(
  ready: process.Subject(process.Subject(Nil)),
  remaining: Int,
) -> List(process.Subject(Nil)) {
  case remaining <= 0 {
    True -> []
    False -> {
      let assert Ok(release) = receive_event(ready)
      [release, ..collect_release_subjects(ready, remaining - 1)]
    }
  }
}

fn list_each_int(count: Int, operation: fn(Int) -> Nil) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      operation(count)
      list_each_int(count - 1, operation)
    }
  }
}

fn receive_ok_nil_results(
  outcomes: process.Subject(Result(Nil, error)),
  remaining: Int,
) -> Bool {
  case remaining <= 0 {
    True -> True
    False ->
      case receive_event(outcomes) {
        Ok(Ok(Nil)) -> receive_ok_nil_results(outcomes, remaining - 1)
        _ -> False
      }
  }
}

@external(erlang, "erlang", "element")
fn storage_pid(index: Int, storage: session.Storage(value)) -> process.Pid

@external(erlang, "erlang", "element")
fn storage_present_versions(index: Int, state: Dynamic) -> Dict(String, Int)
