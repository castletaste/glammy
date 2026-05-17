//// Tests mirroring grammY's `test/convenience/session.test.ts`. Many
//// grammY tests verify JS-mutation semantics (`ctx.session = null`
//// triggers delete) and exception-based error paths; glammy's session
//// is a pure-function model where the handler returns the new value
//// (or the same value to write nothing observable). The behavioural
//// invariants — read/write/persist across calls, key independence,
//// custom storage backends — are all covered here.

import glammy/api
import glammy/composer
import glammy/context
import glammy/session
import glammy/types.{type Update}
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}

fn dummy_api() -> api.Api {
  api.new("0:test")
}

fn make_message(text: String, chat_id: Int) -> Update {
  let body =
    "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":"
    <> int.to_string(chat_id)
    <> ",\"type\":\"private\"},\"date\":0,\"text\":\""
    <> text
    <> "\"}}"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  u
}

// =====================================================================
//                      Storage interface tests
// =====================================================================

pub fn storage_round_trips_test() {
  let storage = session.memory_storage()

  assert session.storage_get(storage, "k") == None

  session.storage_set(storage, "k", 42)
  assert session.storage_get(storage, "k") == Some(42)

  session.storage_set(storage, "k", 100)
  assert session.storage_get(storage, "k") == Some(100)

  session.storage_delete(storage, "k")
  assert session.storage_get(storage, "k") == None
}

pub fn storage_keys_are_independent_test() {
  let storage: session.Storage(String) = session.memory_storage()
  session.storage_set(storage, "a", "alpha")
  session.storage_set(storage, "b", "beta")
  assert session.storage_get(storage, "a") == Some("alpha")
  assert session.storage_get(storage, "b") == Some("beta")
}

// =====================================================================
//                       Middleware behaviour
// =====================================================================

pub fn with_session_loads_and_persists_test() {
  let recorder: process.Subject(Int) = process.new_subject()
  let storage: session.Storage(Int) = session.memory_storage()

  let comp =
    composer.new()
    |> session.with_session(storage, session.by_chat_id, 0, fn(_ctx, n) {
      let next = n + 1
      process.send(recorder, next)
      next
    })

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))

  assert process.receive(recorder, 50) == Ok(1)
  assert process.receive(recorder, 50) == Ok(2)
  assert process.receive(recorder, 50) == Ok(3)
}

pub fn different_chats_have_independent_sessions_test() {
  let recorder: process.Subject(#(Int, Int)) = process.new_subject()
  let storage: session.Storage(Int) = session.memory_storage()

  let comp =
    composer.new()
    |> session.with_session(storage, session.by_chat_id, 0, fn(ctx, n) {
      let assert Some(c) = context.chat(ctx)
      let next = n + 1
      process.send(recorder, #(c.id, next))
      next
    })

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 2), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 2), dummy_api()))

  assert process.receive(recorder, 50) == Ok(#(1, 1))
  assert process.receive(recorder, 50) == Ok(#(2, 1))
  assert process.receive(recorder, 50) == Ok(#(1, 2))
  assert process.receive(recorder, 50) == Ok(#(2, 2))
}

pub fn session_chain_continues_after_handler_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let storage: session.Storage(Int) = session.memory_storage()

  let comp =
    composer.new()
    |> session.with_session(storage, session.by_chat_id, 0, fn(_ctx, n) {
      process.send(recorder, "session")
      n
    })
    |> composer.handle(fn(_ctx) {
      process.send(recorder, "after")
      Nil
    })

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  assert process.receive(recorder, 50) == Ok("session")
  assert process.receive(recorder, 50) == Ok("after")
}

pub fn skips_when_key_fn_returns_none_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let storage: session.Storage(Int) = session.memory_storage()
  let comp =
    composer.new()
    |> session.with_session(storage, fn(_ctx) { None }, 0, fn(_ctx, n) {
      process.send(recorder, "ran")
      n
    })
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  assert process.receive(recorder, 50) == Error(Nil)
}

// =====================================================================
//             IO with primitives / objects (grammY parity)
// =====================================================================

pub fn does_io_with_primitives_test() {
  let storage: session.Storage(Int) = session.memory_storage()
  let recorder: process.Subject(Int) = process.new_subject()

  let comp =
    composer.new()
    |> session.with_session(storage, session.by_chat_id, 0, fn(_ctx, n) {
      process.send(recorder, n)
      n + 1
    })

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))

  assert process.receive(recorder, 50) == Ok(0)
  assert process.receive(recorder, 50) == Ok(1)
  assert session.storage_get(storage, "1") == Some(2)
}

pub fn does_io_with_objects_test() {
  let storage: session.Storage(Dict(String, Int)) = session.memory_storage()
  let recorder: process.Subject(Int) = process.new_subject()

  let comp =
    composer.new()
    |> session.with_session(
      storage,
      session.by_chat_id,
      dict.new(),
      fn(_ctx, d) {
        let size = dict.size(d)
        process.send(recorder, size)
        case size {
          0 -> dict.insert(d, "foo", 0)
          1 -> dict.insert(d, "bar", 0)
          _ -> dict.insert(d, "baz", 0)
        }
      },
    )

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))

  assert process.receive(recorder, 50) == Ok(0)
  assert process.receive(recorder, 50) == Ok(1)
  assert process.receive(recorder, 50) == Ok(2)
}

// =====================================================================
//                       Custom storage backend
// =====================================================================

pub fn works_with_custom_storage_test() {
  // Spy storage that records all calls into a Subject.
  let calls: process.Subject(String) = process.new_subject()
  let backing: process.Subject(Dict(String, Int)) = process.new_subject()
  process.send(backing, dict.new())

  let read = fn(key: String) -> Option(Int) {
    process.send(calls, "read:" <> key)
    let assert Ok(d) = process.receive(backing, 50)
    process.send(backing, d)
    case dict.get(d, key) {
      Ok(v) -> Some(v)
      Error(_) -> None
    }
  }
  let write = fn(key: String, value: Int) -> Nil {
    process.send(calls, "write:" <> key <> "=" <> int.to_string(value))
    let assert Ok(d) = process.receive(backing, 50)
    process.send(backing, dict.insert(d, key, value))
  }
  let delete = fn(key: String) -> Nil {
    process.send(calls, "delete:" <> key)
    let assert Ok(d) = process.receive(backing, 50)
    process.send(backing, dict.delete(d, key))
  }
  let storage = session.custom_storage(get: read, set: write, delete: delete)

  let comp =
    composer.new()
    |> session.with_session(storage, session.by_chat_id, 0, fn(_, n) { n + 1 })

  composer.run(comp, context.new(make_message("hi", 42), dummy_api()))
  // Should call read once with "42", then write once with "42=1".
  assert process.receive(calls, 50) == Ok("read:42")
  assert process.receive(calls, 50) == Ok("write:42=1")
}

// =====================================================================
//                          Custom key prefixing
// =====================================================================

pub fn works_with_custom_session_keys_test() {
  let storage: session.Storage(Int) = session.memory_storage()
  let prefixed_by_square = fn(ctx) {
    case context.chat(ctx) {
      Some(c) -> Some("xyz-" <> int.to_string(c.id * c.id))
      None -> None
    }
  }

  let comp =
    composer.new()
    |> session.with_session(storage, prefixed_by_square, 0, fn(_, n) { n + 1 })

  composer.run(comp, context.new(make_message("hi", 42), dummy_api()))
  composer.run(comp, context.new(make_message("hi", 42), dummy_api()))
  // chat 42 → key "xyz-1764", value 2 after two calls
  assert session.storage_get(storage, "xyz-1764") == Some(2)
}

// =====================================================================
//                       by_user_id / by_chat_and_user
// =====================================================================

const message_with_user = "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":7,\"type\":\"private\"},\"date\":0,\"text\":\"hi\",\"from\":{\"id\":99,\"is_bot\":false,\"first_name\":\"U\"}}}"

pub fn by_user_id_keys_test() {
  let storage: session.Storage(Int) = session.memory_storage()
  let comp =
    composer.new()
    |> session.with_session(storage, session.by_user_id, 0, fn(_, n) { n + 1 })

  let assert Ok(u) = json.parse(message_with_user, types.update_decoder())
  composer.run(comp, context.new(u, dummy_api()))
  composer.run(comp, context.new(u, dummy_api()))
  assert session.storage_get(storage, "99") == Some(2)
}

pub fn by_chat_and_user_keys_test() {
  let storage: session.Storage(Int) = session.memory_storage()
  let comp =
    composer.new()
    |> session.with_session(storage, session.by_chat_and_user, 0, fn(_, n) {
      n + 1
    })

  let assert Ok(u) = json.parse(message_with_user, types.update_decoder())
  composer.run(comp, context.new(u, dummy_api()))
  // chat=7, user=99 → key "7:99"
  assert session.storage_get(storage, "7:99") == Some(1)
}

// =====================================================================
//                       Pass-through (handler doesn't change)
// =====================================================================

pub fn passes_through_updates_test() {
  let storage: session.Storage(Int) = session.memory_storage()
  let recorder: process.Subject(String) = process.new_subject()

  let comp =
    composer.new()
    |> session.with_session(storage, session.by_chat_id, 0, fn(_ctx, n) {
      process.send(recorder, "session-ran")
      n
    })
    |> composer.handle(fn(_ctx) {
      process.send(recorder, "downstream-ran")
      Nil
    })

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  assert process.receive(recorder, 50) == Ok("session-ran")
  assert process.receive(recorder, 50) == Ok("downstream-ran")
}
