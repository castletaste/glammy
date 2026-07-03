//// The bot — a thin wrapper around an `Api` client and a `Composer`
//// chain, plus a long-polling driver. Ported in spirit from grammY's
//// `src/bot.ts` (`Bot.start`, `Bot.handleUpdate`).

import glammy/api.{type Api}
import glammy/composer.{type Composer}
import glammy/context
import glammy/error.{type GlammyError}
import glammy/types.{type Update}
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type PollingOptions {
  PollingOptions(
    /// Maximum number of updates fetched per `getUpdates` request.
    /// Telegram caps this at 100.
    limit: Int,
    /// Long-poll timeout in seconds. Telegram allows 0-50.
    timeout_seconds: Int,
    /// Specific update types to receive, or `None` to use Telegram's
    /// default (everything except `chat_member`/`message_reaction*`).
    allowed_updates: Option(List(String)),
    /// If `True`, the bot fetches and drops any pending updates once on
    /// start, so it begins from a clean slate.
    drop_pending_updates: Bool,
    /// If `True`, `start` verifies the bot token by calling `getMe`
    /// before entering the poll loop. Defaults to `True`.
    verify_token: Bool,
  )
}

/// Default long-polling options for `start`.
pub fn default_polling_options() -> PollingOptions {
  PollingOptions(
    limit: 100,
    timeout_seconds: 30,
    allowed_updates: None,
    drop_pending_updates: False,
    verify_token: True,
  )
}

pub opaque type Bot {
  Bot(api: Api, composer: Composer, error_handler: fn(GlammyError) -> Nil)
}

/// Create a bot from an `Api` client and a `Composer` chain.
pub fn new(api: Api, composer: Composer) -> Bot {
  Bot(api:, composer:, error_handler: default_error_handler)
}

/// Replace the default error handler with a custom one — same idea as
/// grammY's `bot.catch`. The handler is invoked when long polling itself
/// errors (network failure, decode failure, …) — NOT for errors inside
/// individual middleware, which middleware must handle themselves.
pub fn on_error(bot: Bot, handler: fn(GlammyError) -> Nil) -> Bot {
  Bot(..bot, error_handler: handler)
}

fn default_error_handler(err: GlammyError) -> Nil {
  io.println_error("glammy: " <> error.describe(err))
}

/// Dispatch one already-parsed update through the bot's composer. Useful
/// for webhook adapters that get updates from elsewhere.
pub fn handle_update(bot: Bot, update: Update) -> Nil {
  let ctx = context.new(update, bot.api)
  composer.run(bot.composer, ctx)
}

/// Run the bot using long polling. Blocks the calling process until
/// either a fatal error occurs or `verify_token` fails.
///
/// Returns:
/// - `Ok(Nil)` is unreachable in normal operation — the loop runs
///   forever unless the calling process is killed externally.
/// - `Error(e)` only when `verify_token` is enabled and the initial
///   `getMe` call fails. Transient errors during polling do NOT
///   terminate the loop; they are passed to the registered error
///   handler and the loop backs off and retries.
pub fn start(bot: Bot, options: PollingOptions) -> Result(Nil, GlammyError) {
  use _bot_info <- result.try(verify_credentials(bot, options))
  let initial_offset = case options.drop_pending_updates {
    True -> drain_pending(bot, options)
    False -> None
  }
  poll_loop(bot, options, initial_offset, 0)
  Ok(Nil)
}

fn verify_credentials(
  bot: Bot,
  options: PollingOptions,
) -> Result(Nil, GlammyError) {
  case options.verify_token {
    False -> Ok(Nil)
    True ->
      case api.get_me(bot.api) {
        Ok(_) -> Ok(Nil)
        Error(e) -> {
          bot.error_handler(e)
          Error(e)
        }
      }
  }
}

fn drain_pending(bot: Bot, options: PollingOptions) -> Option(Int) {
  api.get_updates(
    bot.api,
    offset: Some(-1),
    limit: Some(1),
    timeout: Some(0),
    allowed_updates: options.allowed_updates,
  )
  |> result.map(fn(updates) {
    case last_update_id(updates) {
      Some(id) -> Some(id + 1)
      None -> None
    }
  })
  |> result.unwrap(None)
}

fn poll_loop(
  bot: Bot,
  options: PollingOptions,
  offset: Option(Int),
  consecutive_errors: Int,
) -> Nil {
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
      list.each(updates, handle_update(bot, _))
      let next_offset =
        last_update_id(updates)
        |> option.map(fn(id) { id + 1 })
        |> option.or(offset)
      poll_loop(bot, options, next_offset, 0)
    }
    Error(e) -> {
      bot.error_handler(e)
      process.sleep(backoff_ms(consecutive_errors))
      poll_loop(bot, options, offset, consecutive_errors + 1)
    }
  }
}

fn last_update_id(updates: List(Update)) -> Option(Int) {
  list.last(updates)
  |> result.map(fn(u) { u.update_id })
  |> option.from_result
}

/// Exponential-ish backoff capped at 30 s. Same idea as grammY's
/// `retryAfter` handling, just simpler.
fn backoff_ms(attempt: Int) -> Int {
  case attempt {
    0 -> 1000
    1 -> 2000
    2 -> 5000
    3 -> 10_000
    _ -> 30_000
  }
}
