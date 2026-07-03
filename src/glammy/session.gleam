//// Per-chat (or per-user) session storage. Pure-Gleam, no process
//// dictionary tricks: state is threaded explicitly through a
//// handler-with-state combinator.
////
//// Usage:
////
//// ```gleam
//// let storage: session.Storage(Int) = session.memory_storage()
////
//// composer.new()
//// |> session.with_session(storage, session.by_chat_id, 0, fn(ctx, n) {
////   let _ = context.reply(ctx, "count = " <> int.to_string(n + 1))
////   n + 1  // returned value is persisted automatically
//// })
//// ```

import glammy/composer.{type Composer}
import glammy/context.{type Context}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}

// =====================================================================
//                         Storage interface
// =====================================================================

/// A `Storage(v)` is the pluggable persistence layer. Implementations
/// provide `get` / `set` / `delete` — wire up your own via
/// `custom_storage` to back this with Redis, ETS, Postgres, …
pub opaque type Storage(value) {
  Storage(
    get: fn(String) -> Option(value),
    set: fn(String, value) -> Nil,
    delete: fn(String) -> Nil,
  )
}

pub fn custom_storage(
  get get: fn(String) -> Option(value),
  set set: fn(String, value) -> Nil,
  delete delete: fn(String) -> Nil,
) -> Storage(value) {
  Storage(get:, set:, delete:)
}

pub fn storage_get(storage: Storage(value), key: String) -> Option(value) {
  storage.get(key)
}

pub fn storage_set(storage: Storage(value), key: String, value: value) -> Nil {
  storage.set(key, value)
}

pub fn storage_delete(storage: Storage(value), key: String) -> Nil {
  storage.delete(key)
}

// =====================================================================
//                       In-memory storage (default)
// =====================================================================

type Msg(value) {
  Get(key: String, reply_to: Subject(Option(value)))
  Set(key: String, value: value)
  Delete(key: String)
}

/// Create an in-memory storage backed by a spawned BEAM process. State
/// is held in the process's mailbox loop — perfect for development /
/// tests, fine for low-traffic production bots.
pub fn memory_storage() -> Storage(value) {
  // The state-holding process creates its OWN subject (so the subject's
  // owner is the storage process) and hands it back to the caller via
  // a one-shot setup subject owned by the caller.
  let setup: Subject(Subject(Msg(value))) = process.new_subject()
  let _ =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(setup, subject)
      run_storage_loop(subject, dict.new())
    })
  let subject = process.receive_forever(setup)
  Storage(
    get: fn(key) {
      let reply = process.new_subject()
      process.send(subject, Get(key:, reply_to: reply))
      process.receive_forever(reply)
    },
    set: fn(key, value) { process.send(subject, Set(key:, value:)) },
    delete: fn(key) { process.send(subject, Delete(key:)) },
  )
}

fn run_storage_loop(
  subject: Subject(Msg(value)),
  state: Dict(String, value),
) -> Nil {
  case process.receive_forever(subject) {
    Get(key:, reply_to:) -> {
      process.send(reply_to, option.from_result(dict.get(state, key)))
      run_storage_loop(subject, state)
    }
    Set(key:, value:) ->
      run_storage_loop(subject, dict.insert(state, key, value))
    Delete(key:) -> run_storage_loop(subject, dict.delete(state, key))
  }
}

// =====================================================================
//                          Key functions
// =====================================================================

pub type KeyFn =
  fn(Context) -> Option(String)

/// Key by `chat.id` (the most common choice). Returns `None` when the
/// update has no associated chat (e.g. inline queries).
pub fn by_chat_id(ctx: Context) -> Option(String) {
  context.chat(ctx)
  |> option.map(fn(c) { int.to_string(c.id) })
}

/// Key by `from.id`.
pub fn by_user_id(ctx: Context) -> Option(String) {
  context.from(ctx)
  |> option.map(fn(u) { int.to_string(u.id) })
}

/// Key by both chat and user combined.
pub fn by_chat_and_user(ctx: Context) -> Option(String) {
  case context.chat(ctx), context.from(ctx) {
    Some(c), Some(u) -> Some(int.to_string(c.id) <> ":" <> int.to_string(u.id))
    _, _ -> None
  }
}

// =====================================================================
//                         Composer integration
// =====================================================================

/// Attach a session-aware handler to a composer. The handler receives
/// the current context and the loaded session value, and must return
/// the new session value (often the same one unchanged).
///
/// Internally this:
/// 1. Looks up the storage key via `key_fn(ctx)`.
/// 2. Loads the stored value, falling back to `default` if absent.
/// 3. Calls `handler(ctx, value)`.
/// 4. Persists the returned value back to storage.
/// 5. Continues to the next middleware in the chain.
///
/// If `key_fn` returns `None` for this update (e.g. inline queries
/// have no chat), the handler is skipped entirely and the chain
/// proceeds normally.
pub fn with_session(
  composer: Composer,
  storage: Storage(value),
  key_fn: KeyFn,
  default: value,
  handler: fn(Context, value) -> value,
) -> Composer {
  composer.use_middleware(composer, fn(ctx, next) {
    run(storage, ctx, key_fn, default, handler)
    next()
  })
}

/// Lower-level: run a session-aware operation directly without wrapping
/// it in a composer. Useful inside custom middleware or one-off handlers.
pub fn run(
  storage: Storage(value),
  ctx: Context,
  key_fn: KeyFn,
  default: value,
  handler: fn(Context, value) -> value,
) -> Nil {
  case key_fn(ctx) {
    None -> Nil
    Some(key) -> {
      let initial = case storage.get(key) {
        Some(v) -> v
        None -> default
      }
      let final = handler(ctx, initial)
      storage.set(key, final)
    }
  }
}
