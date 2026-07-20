//// Webhook integration. glammy doesn't ship its own HTTP server (that
//// would mean pulling `wisp` or `mist` as a dependency), so this module
//// is framework-agnostic — you wire it up to whichever Gleam HTTP server
//// you already use.
////
//// The flow is:
////
//// 1. Your server receives `POST /telegram/webhook` with a JSON body.
//// 2. Optionally verify the `X-Telegram-Bot-Api-Secret-Token` header.
//// 3. Prefer `handle_isolated_with_secret` at an HTTP boundary so a panic or
////    hung middleware cannot take down the request process.
//// 4. Reply `200 OK` with an empty body.

import glammy/api
import glammy/bot.{type Bot, type BotRuntimeError}
import glammy/types.{type Update}
import glammy/webhook_secret.{type WebhookSecret}
import gleam/result

/// Failures raised while validating or dispatching a webhook update.
pub type WebhookError {
  /// The provided body was not valid JSON / not a valid Update.
  ParseError(api.JsonParseError)
  /// The `secret_token` did not match the expected value.
  BadSecretToken
  /// Dispatch failed, or isolated middleware crashed/exceeded its timeout.
  HandlerFailed(BotRuntimeError)
}

/// Dispatch a single update body synchronously through the bot.
///
/// This function deliberately preserves direct synchronous semantics and does
/// not catch middleware panics. Typed update-gate failures are still returned
/// as `HandlerFailed`. Prefer `handle_isolated` at an HTTP boundary.
pub fn handle(bot_: Bot, body: String) -> Result(Nil, WebhookError) {
  use update <- result.try(parse_body(body))
  bot.handle_update_result(bot_, update)
  |> result.map_error(HandlerFailed)
}

/// Parse and dispatch one update in a monitored, unlinked process.
///
/// Middleware panics and timeouts are returned as `HandlerFailed`, keeping the
/// caller's HTTP process alive.
pub fn handle_isolated(
  bot_: Bot,
  body: String,
  timeout_ms timeout_ms: Int,
) -> Result(Nil, WebhookError) {
  use update <- result.try(parse_body(body))
  bot.handle_update_isolated(bot_, update, timeout_ms)
  |> result.map_error(HandlerFailed)
}

/// Same as `handle` but also requires that the
/// `X-Telegram-Bot-Api-Secret-Token` HTTP header matches the configured
/// secret. This keeps `handle`'s synchronous semantics; prefer
/// `handle_isolated_with_secret` at an HTTP boundary.
pub fn handle_with_secret(
  bot_: Bot,
  body: String,
  header_value header_value: String,
  expected_secret expected_secret: WebhookSecret,
) -> Result(Nil, WebhookError) {
  case verify_secret(header_value, expected_secret) {
    True -> handle(bot_, body)
    False -> Error(BadSecretToken)
  }
}

/// Same as `handle_isolated`, but first verifies the Telegram secret header.
pub fn handle_isolated_with_secret(
  bot_: Bot,
  body: String,
  header_value header_value: String,
  expected_secret expected_secret: WebhookSecret,
  timeout_ms timeout_ms: Int,
) -> Result(Nil, WebhookError) {
  case verify_secret(header_value, expected_secret) {
    True -> handle_isolated(bot_, body, timeout_ms:)
    False -> Error(BadSecretToken)
  }
}

/// Compare valid Telegram webhook secrets through fixed-size digests.
///
/// The configured value is already guaranteed valid by `WebhookSecret`.
/// The untrusted header is validated before both values are hashed to fixed-size
/// SHA-256 digests for Erlang's constant-time `hash_equals/2`.
pub fn verify_secret(provided: String, expected: WebhookSecret) -> Bool {
  case webhook_secret.new(provided) {
    Error(_) -> False
    Ok(provided_secret) -> {
      let a = <<webhook_secret.to_string(provided_secret):utf8>>
      let b = <<webhook_secret.to_string(expected):utf8>>
      hash_equals(hash(Sha256, a), hash(Sha256, b))
    }
  }
}

fn parse_body(body: String) -> Result(Update, WebhookError) {
  api.parse_update(body) |> result.map_error(ParseError)
}

@external(erlang, "crypto", "hash_equals")
fn hash_equals(a: BitArray, b: BitArray) -> Bool

type HashAlgorithm {
  Sha256
}

@external(erlang, "crypto", "hash")
fn hash(algorithm: HashAlgorithm, value: BitArray) -> BitArray
