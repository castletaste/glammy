//// Webhook integration. glammy doesn't ship its own HTTP server (that
//// would mean pulling `wisp` or `mist` as a dependency), so this module
//// is framework-agnostic — you wire it up to whichever Gleam HTTP server
//// you already use.
////
//// The flow is:
////
//// 1. Your server receives `POST /telegram/webhook` with a JSON body.
//// 2. Optionally verify the `X-Telegram-Bot-Api-Secret-Token` header
////    via `handle_with_secret`.
//// 3. Hand the body to `handle/2` to dispatch through the bot.
//// 4. Reply `200 OK` with an empty body.

import glammy/api
import glammy/bot.{type Bot}

pub type WebhookError {
  /// The provided body was not valid JSON / not a valid Update.
  ParseError(message: String)
  /// The `secret_token` did not match the expected value.
  BadSecretToken
}

/// Dispatch a single update body through the bot. Returns `Ok(Nil)` when
/// the update parsed and was dispatched (regardless of what middleware
/// did), and `Error(ParseError(...))` if the body wasn't a valid update.
pub fn handle(bot_: Bot, body: String) -> Result(Nil, WebhookError) {
  case api.parse_update(body) {
    Ok(update) -> {
      bot.handle_update(bot_, update)
      Ok(Nil)
    }
    Error(msg) -> Error(ParseError(message: msg))
  }
}

/// Same as `handle` but also requires that the
/// `X-Telegram-Bot-Api-Secret-Token` HTTP header matches the configured
/// secret. Use this when you set `secret_token` in `api.set_webhook`.
pub fn handle_with_secret(
  bot_: Bot,
  body: String,
  header_value: String,
  expected_secret: String,
) -> Result(Nil, WebhookError) {
  case verify_secret(header_value, expected_secret) {
    True -> handle(bot_, body)
    False -> Error(BadSecretToken)
  }
}

/// Constant-time string comparison — avoids timing-leak attacks when
/// verifying the secret token. Delegates to Erlang's
/// `crypto:hash_equals/2` (documented constant-time) when the strings
/// have equal byte length; differing lengths short-circuit to `False`.
/// (The length check itself does not leak useful timing information.)
pub fn verify_secret(provided: String, expected: String) -> Bool {
  let a = <<provided:utf8>>
  let b = <<expected:utf8>>
  case byte_size(a) == byte_size(b) {
    True -> hash_equals(a, b)
    False -> False
  }
}

@external(erlang, "crypto", "hash_equals")
fn hash_equals(a: BitArray, b: BitArray) -> Bool

@external(erlang, "erlang", "byte_size")
fn byte_size(a: BitArray) -> Int
