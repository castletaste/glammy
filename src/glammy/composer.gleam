//// Middleware pipeline. Ported in spirit from grammY's
//// `src/composer.ts`. The basic shape: a `Middleware` is
//// `fn(Context, Next) -> Nil`, where `Next` is a zero-arg thunk that
//// hands control to the next middleware in line. A middleware that
//// does NOT call `next` short-circuits the rest of the chain — same
//// semantics as the JS original.

import glammy/context.{type Context}
import glammy/filter.{type Filter, type Query}
import glammy/types.{type Message, type MessageEntity, MessageEntity}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string

/// Continue with the next middleware in the composed pipeline.
pub type Next =
  fn() -> Nil

/// One immutable composer pipeline step.
pub type Middleware =
  fn(Context, Next) -> Nil

/// An immutable, ordered middleware pipeline.
pub opaque type Composer {
  Composer(stack: List(Middleware))
}

/// Create an empty composer.
pub fn new() -> Composer {
  Composer(stack: [])
}

/// Append a middleware to the composer. Returns a new composer with
/// the middleware tacked on — the original value is unchanged.
pub fn use_middleware(composer: Composer, middleware: Middleware) -> Composer {
  Composer(stack: list.append(composer.stack, [middleware]))
}

/// Sugar: append a *handler* (a function that just takes `Context` and
/// returns `Nil`). The most common case — the handler doesn't care
/// about middleware chaining and always passes control on.
pub fn handle(composer: Composer, handler: fn(Context) -> Nil) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    handler(ctx)
    next()
  })
}

// =====================================================================
//                        Filtering combinators
// =====================================================================

/// Append a handler that runs only when the typed filter matches the
/// update.
pub fn on(
  composer: Composer,
  filter_: Filter,
  handler: fn(Context) -> Nil,
) -> Composer {
  when(composer, filter.matches(filter_, _), handler)
}

/// Append a handler that runs only when the parsed filter query
/// matches.
pub fn on_query(
  composer: Composer,
  query: Query,
  handler: fn(Context) -> Nil,
) -> Composer {
  when(composer, filter.matches_query(query, _), handler)
}

/// Append a handler that runs only when the predicate returns `True`.
pub fn filter(
  composer: Composer,
  pred: fn(Context) -> Bool,
  handler: fn(Context) -> Nil,
) -> Composer {
  when(composer, pred, handler)
}

/// Append a handler that runs only when the predicate returns
/// `False` — the inverse of `filter`.
pub fn drop(
  composer: Composer,
  pred: fn(Context) -> Bool,
  handler: fn(Context) -> Nil,
) -> Composer {
  when(composer, fn(ctx) { !pred(ctx) }, handler)
}

/// If `pred(ctx)` is `True` run `on_true`, otherwise run `on_false`.
/// Both branches receive the same context.
pub fn branch(
  composer: Composer,
  pred: fn(Context) -> Bool,
  on_true: fn(Context) -> Nil,
  on_false: fn(Context) -> Nil,
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    case pred(ctx) {
      True -> on_true(ctx)
      False -> on_false(ctx)
    }
    next()
  })
}

/// Route to one of several sub-handlers based on a key extractor.
/// Keys that don't appear in the routes table are silently ignored
/// (the chain proceeds without dispatching anywhere).
pub fn route(
  composer: Composer,
  key_fn: fn(Context) -> String,
  routes: List(#(String, fn(Context) -> Nil)),
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    let key = key_fn(ctx)
    case list.key_find(routes, key) {
      Ok(handler) -> handler(ctx)
      Error(_) -> Nil
    }
    next()
  })
}

/// Run a handler in a separate, unlinked BEAM process, then immediately move
/// on to the next middleware in the chain. Failures in the fire-and-forget
/// handler cannot take down update dispatch. This primitive is unbounded and
/// provides no backpressure, completion observation, or per-key ordering. Use
/// `glammy/keyed_executor` for bounded production work.
pub fn fork(composer: Composer, handler: fn(Context) -> Nil) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    let _ = process.spawn_unlinked(fn() { handler(ctx) })
    next()
  })
}

/// Build a middleware lazily on every invocation. Use this when the
/// handler needs to capture per-update state computed elsewhere.
pub fn lazy(
  composer: Composer,
  factory: fn(Context) -> fn(Context) -> Nil,
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    let handler = factory(ctx)
    handler(ctx)
    next()
  })
}

/// Concatenate another composer's middleware onto this one.
pub fn append(parent: Composer, child: Composer) -> Composer {
  Composer(stack: list.append(parent.stack, child.stack))
}

// =====================================================================
//                        Command / hears / specifics
// =====================================================================

/// Append a handler for an unaddressed `/<command>` found in message text or a
/// media caption's leading `bot_command` entity. Text takes precedence when a
/// message contains both.
///
/// Addressed commands require the current bot username and are handled by
/// `command_for_bot`; accepting every `@username` would route commands meant
/// for another bot.
pub fn command(
  composer: Composer,
  name: String,
  handler: fn(Context) -> Nil,
) -> Composer {
  command_any(composer, [name], handler)
}

/// Append a handler for `/<command>` and
/// `/<command>@<this_bot_username>` in message text or a media caption,
/// rejecting commands addressed to another bot. Text takes precedence when
/// both are present. `bot_username` may be passed with or without the leading
/// `@`.
pub fn command_for_bot(
  composer: Composer,
  name: String,
  bot_username: String,
  handler: fn(Context) -> Nil,
) -> Composer {
  let expected_bot = normalize_bot_username(bot_username)
  when(
    composer,
    fn(ctx) {
      case extract_command(ctx) {
        Some(ParsedCommand(command_name, target)) if command_name == name ->
          case target {
            None -> True
            Some(actual_bot) ->
              string.lowercase(actual_bot) == string.lowercase(expected_bot)
          }
        _ -> False
      }
    },
    handler,
  )
}

/// Like `command` but accepts a list of accepted names (OR), including commands
/// carried by media captions.
pub fn command_any(
  composer: Composer,
  names: List(String),
  handler: fn(Context) -> Nil,
) -> Composer {
  when(
    composer,
    fn(ctx) {
      case extract_command(ctx) {
        Some(ParsedCommand(command_name, None)) ->
          list.contains(names, command_name)
        _ -> False
      }
    },
    handler,
  )
}

/// Append a handler that fires when the message text or media caption exactly
/// equals the given string. Text takes precedence when both are present.
/// For substring, regex, or fuzzy matching, use `hears_when`.
pub fn hears(
  composer: Composer,
  needle: String,
  handler: fn(Context) -> Nil,
) -> Composer {
  when(composer, text_pred(fn(text) { text == needle }), handler)
}

/// Append a handler that fires when the message text or media caption passes
/// the caller-supplied predicate. Text takes precedence when both are present.
/// Use this for regex / fuzzy matching: implement the matching yourself and
/// return Bool.
pub fn hears_when(
  composer: Composer,
  pred: fn(String) -> Bool,
  handler: fn(Context) -> Nil,
) -> Composer {
  when(composer, text_pred(pred), handler)
}

/// Handle callback queries whose `data` exactly matches `expected`.
pub fn callback_query(
  composer: Composer,
  expected: String,
  handler: fn(Context) -> Nil,
) -> Composer {
  when(composer, context.has_callback_data(_, expected), handler)
}

/// Filter on chat type (`types.Private` / `types.Group` /
/// `types.Supergroup` / `types.Channel`).
///
/// ```gleam
/// composer.chat_type(composer, types.Private, handler)
/// ```
pub fn chat_type(
  composer: Composer,
  type_: types.ChatType,
  handler: fn(Context) -> Nil,
) -> Composer {
  when(
    composer,
    fn(ctx) {
      case context.chat(ctx) {
        Some(c) -> c.type_ == type_
        None -> False
      }
    },
    handler,
  )
}

// =====================================================================
//                         Execution
// =====================================================================

/// Execute the composer's chain for a single context.
pub fn run(composer: Composer, ctx: Context) -> Nil {
  let final_next = fn() { Nil }
  let entry =
    list.fold_right(composer.stack, final_next, fn(next_built, mw) {
      fn() { mw(ctx, next_built) }
    })
  entry()
}

// =====================================================================
//                          internals
// =====================================================================

/// Shared skeleton behind the filtering combinators: run `handler`
/// and then always call `next` when `pred(ctx)` is `True`; otherwise
/// just call `next`.
fn when(
  composer: Composer,
  pred: fn(Context) -> Bool,
  handler: fn(Context) -> Nil,
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    case pred(ctx) {
      True -> {
        handler(ctx)
        next()
      }
      False -> next()
    }
  })
}

/// Build a `Context` predicate from a `String` predicate, evaluated against the
/// update's message text or media caption.
fn text_pred(check: fn(String) -> Bool) -> fn(Context) -> Bool {
  fn(ctx) {
    case context.message(ctx) {
      Some(message) ->
        case message_text_and_entities(message) {
          Some(#(text, _)) -> check(text)
          None -> False
        }
      None -> False
    }
  }
}

type ParsedCommand {
  ParsedCommand(name: String, target: option.Option(String))
}

fn extract_command(ctx: Context) -> option.Option(ParsedCommand) {
  case context.message(ctx) {
    Some(m) -> command_from_message(m)
    None -> None
  }
}

fn command_from_message(message: Message) -> option.Option(ParsedCommand) {
  case message_text_and_entities(message) {
    Some(#(
      text,
      [MessageEntity(type_: "bot_command", offset: 0, length: len, ..), ..],
    )) -> {
      let raw = string.slice(text, 0, len)
      let without_slash = case string.starts_with(raw, "/") {
        True -> string.drop_start(raw, 1)
        False -> raw
      }
      let #(command_name, target) = case string.split_once(without_slash, "@") {
        Ok(#(command_name, target)) -> #(command_name, Some(target))
        Error(_) -> #(without_slash, None)
      }
      Some(ParsedCommand(name: command_name, target:))
    }
    _ -> None
  }
}

fn message_text_and_entities(
  message: Message,
) -> option.Option(#(String, List(MessageEntity))) {
  case message.text {
    Some(text) -> Some(#(text, message.entities))
    None ->
      case message.caption {
        Some(caption) -> Some(#(caption, message.caption_entities))
        None -> None
      }
  }
}

fn normalize_bot_username(username: String) -> String {
  case string.starts_with(username, "@") {
    True -> string.drop_start(username, 1)
    False -> username
  }
}
