//// Compact facade for the common bot → composer → context flow.
////
//// The focused modules remain available for advanced use, while a small bot
//// can keep one `glammy` import:
////
//// ```gleam
//// import glammy
//// import gleam/io
//// import gleam/string
////
//// pub fn main() {
////   let client = glammy.api("123456:ABC-DEF...")
////   let handlers =
////     glammy.composer()
////     |> glammy.command("start", fn(ctx) {
////       case glammy.reply(ctx, "Hello!") {
////         Ok(_) -> Nil
////         Error(error) -> io.println_error(string.inspect(error))
////       }
////     })
////
////   case glammy.bot(client, handlers) |> glammy.start {
////     Ok(_) -> Nil
////     Error(error) -> io.println_error(string.inspect(error))
////   }
//// }
//// ```

import glammy/api as bot_api
import glammy/bot as bot_runtime
import glammy/composer as middleware
import glammy/context as update_context
import glammy/types

/// Create a Telegram Bot API client.
pub fn api(token: String) -> bot_api.Api {
  bot_api.new(token)
}

/// Create an empty immutable middleware composer.
pub fn composer() -> middleware.Composer {
  middleware.new()
}

/// Add a handler for an unaddressed slash command.
pub fn command(
  composer: middleware.Composer,
  name: String,
  handler: fn(update_context.Context) -> Nil,
) -> middleware.Composer {
  middleware.command(composer, name, handler)
}

/// Add a handler for messages whose text or caption exactly equals `needle`.
pub fn hears(
  composer: middleware.Composer,
  needle: String,
  handler: fn(update_context.Context) -> Nil,
) -> middleware.Composer {
  middleware.hears(composer, needle, handler)
}

/// Combine an API client and composer into a bot runtime.
pub fn bot(api: bot_api.Api, composer: middleware.Composer) -> bot_runtime.Bot {
  bot_runtime.new(api, composer)
}

/// Reply to the chat in the current update.
pub fn reply(
  context: update_context.Context,
  text: String,
) -> Result(types.Message, update_context.ReplyError) {
  update_context.reply(context, text)
}

/// Start long polling with safe defaults.
pub fn start(bot: bot_runtime.Bot) -> Result(Nil, bot_runtime.BotError) {
  bot_runtime.start(bot, bot_runtime.default_polling_options())
}

/// Start long polling with explicit options.
pub fn start_with(
  bot: bot_runtime.Bot,
  options: bot_runtime.PollingOptions,
) -> Result(Nil, bot_runtime.BotError) {
  bot_runtime.start(bot, options)
}
