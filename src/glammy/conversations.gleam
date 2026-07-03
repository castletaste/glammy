//// A minimal conversations primitive — much smaller in scope than the
//// `@grammyjs/conversations` plugin (which implements persistent
//// continuations across bot restarts), but enough to write linear
//// "ask, wait, branch" flows in one process lifetime.
////
//// The idea: a handler enters a conversation by calling `start` and
//// providing a thunk. Inside the thunk, the handler can call
//// `wait_for_message` to suspend until the next update from the same
//// user arrives. The `conversations` middleware routes incoming updates
//// to the right waiting handler.
////
//// Usage:
////
//// ```gleam
//// let registry = conversations.new_registry()
//// composer.new()
//// |> composer.use_middleware(conversations.middleware(registry))
//// |> composer.command("ask", fn(ctx) {
////   conversations.start(registry, ctx, fn(wait) {
////     let _ = context.reply(ctx, "What's your name?")
////     let assert Ok(next_ctx) = wait(5000)
////     let assert option.Some(name) = context.message_text(next_ctx)
////     let _ = context.reply(ctx, "Hi, " <> name <> "!")
////     Nil
////   })
//// })
//// ```
////
//// Caveats:
//// - State is lost if the bot restarts mid-conversation.
//// - One conversation per user_id at a time; a second `start` from the
////   same user replaces the first.

import glammy/composer.{type Middleware}
import glammy/context.{type Context}
import glammy/types.{type Update}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}

pub opaque type Registry {
  Registry(commands: Subject(Command))
}

type Command {
  Register(key: String, subject: Subject(Update))
  Unregister(key: String)
  TryRoute(update: Update, key: String, reply_to: Subject(Bool))
}

/// Create an empty in-memory conversation registry.
pub fn new_registry() -> Registry {
  let setup: Subject(Subject(Command)) = process.new_subject()
  let _ =
    process.spawn(fn() {
      let commands: Subject(Command) = process.new_subject()
      process.send(setup, commands)
      registry_loop(commands, dict.new())
    })
  Registry(commands: process.receive_forever(setup))
}

fn registry_loop(
  commands: Subject(Command),
  waiters: Dict(String, Subject(Update)),
) -> Nil {
  case process.receive_forever(commands) {
    Register(key:, subject:) ->
      registry_loop(commands, dict.insert(waiters, key, subject))
    Unregister(key:) -> registry_loop(commands, dict.delete(waiters, key))
    TryRoute(update:, key:, reply_to:) ->
      case dict.get(waiters, key) {
        Ok(subject) -> {
          process.send(subject, update)
          process.send(reply_to, True)
          registry_loop(commands, dict.delete(waiters, key))
        }
        Error(_) -> {
          process.send(reply_to, False)
          registry_loop(commands, waiters)
        }
      }
  }
}

/// Composer middleware that consults the registry on every incoming
/// update. If a handler is currently waiting for the user's next update,
/// the update is delivered to that handler and the middleware chain
/// stops here (we don't call `next`). Otherwise the chain proceeds as
/// usual.
pub fn middleware(registry: Registry) -> Middleware {
  fn(ctx: Context, next: fn() -> Nil) -> Nil {
    case key_for(ctx) {
      None -> next()
      Some(key) -> {
        let reply = process.new_subject()
        process.send(
          registry.commands,
          TryRoute(update: ctx.update, key:, reply_to: reply),
        )
        case process.receive_forever(reply) {
          True -> Nil
          False -> next()
        }
      }
    }
  }
}

/// Run a synchronous "conversation" thunk. The thunk receives a `wait`
/// function it can call to suspend execution until the next update from
/// the same user arrives.
///
/// `start` blocks until the thunk returns, so it's expected to be
/// invoked from a handler that is itself part of a composer chain.
pub fn start(
  registry: Registry,
  ctx: Context,
  thunk: fn(WaitFn) -> Nil,
) -> Nil {
  case key_for(ctx) {
    None -> thunk(fn(_timeout) { Error(Timeout) })
    Some(key) ->
      thunk(fn(timeout_ms) {
        let subject: Subject(Update) = process.new_subject()
        process.send(registry.commands, Register(key:, subject:))
        let result = case process.receive(subject, timeout_ms) {
          Ok(update) -> Ok(update_to_ctx(update, ctx))
          Error(_) -> {
            process.send(registry.commands, Unregister(key:))
            Error(Timeout)
          }
        }
        result
      })
  }
}

/// The continuation function passed to a conversation thunk.
pub type WaitFn =
  fn(Int) -> Result(Context, WaitError)

pub type WaitError {
  Timeout
}

fn key_for(ctx: Context) -> Option(String) {
  context.from(ctx) |> option.map(fn(u) { int.to_string(u.id) })
}

fn update_to_ctx(update: Update, original: Context) -> Context {
  context.new(update, original.api)
}
