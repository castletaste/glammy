//// Validated Telegram webhook secrets shared by webhook registration and
//// request verification.
////
//// Telegram accepts 1–256 ASCII characters from `[A-Za-z0-9_-]`. Keeping the
//// constructor private means an invalid configured secret cannot reach either
//// `setWebhook` or the verification boundary.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

const allowed_characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"

/// A Telegram-compatible `secret_token`.
pub opaque type WebhookSecret {
  WebhookSecret(reveal: fn() -> String)
}

/// Why a string could not be used as a Telegram webhook secret.
pub type WebhookSecretError {
  EmptyWebhookSecret
  WebhookSecretTooLong(length: Int)
  InvalidWebhookSecretCharacter(character: String)
}

/// Validate and wrap a Telegram webhook secret.
pub fn new(value: String) -> Result(WebhookSecret, WebhookSecretError) {
  let characters = string.to_graphemes(value)
  let length = list.length(characters)
  case length {
    0 -> Error(EmptyWebhookSecret)
    n if n > 256 -> Error(WebhookSecretTooLong(n))
    _ ->
      case first_invalid_character(characters) {
        Some(character) -> Error(InvalidWebhookSecretCharacter(character))
        None -> Ok(WebhookSecret(fn() { value }))
      }
  }
}

/// Reveal the validated string for transport or comparison.
pub fn to_string(secret: WebhookSecret) -> String {
  let WebhookSecret(reveal) = secret
  reveal()
}

fn first_invalid_character(characters: List(String)) -> Option(String) {
  case characters {
    [] -> None
    [character, ..rest] ->
      case string.contains(allowed_characters, character) {
        True -> first_invalid_character(rest)
        False -> Some(character)
      }
  }
}
