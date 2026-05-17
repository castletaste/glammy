//// Middleware pipeline. Ported in spirit from grammY's
//// `src/composer.ts`. The basic shape: a `Middleware` is
//// `fn(Context, Next) -> Nil`, where `Next` is a zero-arg thunk that
//// hands control to the next middleware in line. A middleware that
//// does NOT call `next` short-circuits the rest of the chain — same
//// semantics as the JS original.

import glammy/context.{type Context}
import glammy/filter.{type Filter, type Query}
import glammy/types.{type Message, MessageEntity}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub type Next =
  fn() -> Nil

pub type Middleware =
  fn(Context, Next) -> Nil

pub opaque type Composer {
  Composer(stack: List(Middleware))
}

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
  filter: Filter,
  handler: fn(Context) -> Nil,
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    case filter.matches(filter, ctx) {
      True -> {
        handler(ctx)
        next()
      }
      False -> next()
    }
  })
}

/// Append a handler that runs only when the parsed filter query
/// matches.
pub fn on_query(
  composer: Composer,
  query: Query,
  handler: fn(Context) -> Nil,
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    case filter.matches_query(query, ctx) {
      True -> {
        handler(ctx)
        next()
      }
      False -> next()
    }
  })
}

/// Append a handler that runs only when the predicate returns `True`.
pub fn filter(
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

/// Append a handler that runs only when the predicate returns
/// `False` — the inverse of `filter`.
pub fn drop(
  composer: Composer,
  pred: fn(Context) -> Bool,
  handler: fn(Context) -> Nil,
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    case pred(ctx) {
      True -> next()
      False -> {
        handler(ctx)
        next()
      }
    }
  })
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

/// Run a handler in a separate BEAM process, then immediately move on
/// to the next middleware in the chain. Useful for fire-and-forget
/// side-effects that shouldn't block update dispatch.
pub fn fork(composer: Composer, handler: fn(Context) -> Nil) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    let _ = process.spawn(fn() { handler(ctx) })
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

/// Append a handler for `/<command>` (and `/<command>@<bot_username>`).
/// Mirrors grammY's `bot.command(name, handler)`.
pub fn command(
  composer: Composer,
  name: String,
  handler: fn(Context) -> Nil,
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    case extract_command(ctx) {
      Some(cmd) if cmd == name -> {
        handler(ctx)
        next()
      }
      _ -> next()
    }
  })
}

/// Like `command` but accepts a list of accepted names (OR).
pub fn command_any(
  composer: Composer,
  names: List(String),
  handler: fn(Context) -> Nil,
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    case extract_command(ctx) {
      Some(cmd) ->
        case list.contains(names, cmd) {
          True -> {
            handler(ctx)
            next()
          }
          False -> next()
        }
      None -> next()
    }
  })
}

/// Append a handler that fires when the message text *contains* the
/// given substring. Mirrors grammY's `bot.hears` — substring form only.
/// For regex matching, use `hears_when`.
pub fn hears(
  composer: Composer,
  needle: String,
  handler: fn(Context) -> Nil,
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    case context.message_text(ctx) {
      Some(text) ->
        case string.contains(text, needle) {
          True -> {
            handler(ctx)
            next()
          }
          False -> next()
        }
      None -> next()
    }
  })
}

/// Append a handler that fires when the message text passes the
/// caller-supplied predicate. Use this for regex / fuzzy matching:
/// implement the matching yourself and return Bool.
pub fn hears_when(
  composer: Composer,
  pred: fn(String) -> Bool,
  handler: fn(Context) -> Nil,
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    case context.message_text(ctx) {
      Some(text) ->
        case pred(text) {
          True -> {
            handler(ctx)
            next()
          }
          False -> next()
        }
      None -> next()
    }
  })
}

/// Handle callback queries whose `data` exactly matches `expected`.
pub fn callback_query(
  composer: Composer,
  expected: String,
  handler: fn(Context) -> Nil,
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    case context.has_callback_data(ctx, expected) {
      True -> {
        handler(ctx)
        next()
      }
      False -> next()
    }
  })
}

/// Filter on chat type ("private" / "group" / "supergroup" / "channel").
pub fn chat_type(
  composer: Composer,
  type_: String,
  handler: fn(Context) -> Nil,
) -> Composer {
  use_middleware(composer, fn(ctx, next) {
    let matches = case context.chat(ctx) {
      Some(c) ->
        case c.type_, type_ {
          types.Private, "private" -> True
          types.Group, "group" -> True
          types.Supergroup, "supergroup" -> True
          types.Channel, "channel" -> True
          _, _ -> False
        }
      None -> False
    }
    case matches {
      True -> {
        handler(ctx)
        next()
      }
      False -> next()
    }
  })
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

fn extract_command(ctx: Context) -> option.Option(String) {
  case context.message(ctx) {
    Some(m) -> command_from_message(m)
    None -> None
  }
}

fn command_from_message(message: Message) -> option.Option(String) {
  case message.text, message.entities {
    Some(text),
      [MessageEntity(type_: "bot_command", offset: 0, length: len, ..), ..]
    -> {
      let raw = string.slice(text, 0, len)
      let without_slash = case string.starts_with(raw, "/") {
        True -> string.drop_start(raw, 1)
        False -> raw
      }
      let bare = case string.split_once(without_slash, "@") {
        Ok(#(cmd, _bot)) -> cmd
        Error(_) -> without_slash
      }
      Some(bare)
    }
    _, _ -> None
  }
}
