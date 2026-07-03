//// Shared test setup helpers. This module intentionally has no `_test`
//// suffix so gleeunit does not treat it as a test suite — it only
//// exports helpers consumed by other test modules.

import glammy/api
import glammy/context
import glammy/types.{type Update}
import gleam/int
import gleam/json

/// A dummy `Api` pointed at a fake token, used wherever a test needs an
/// `Api` value but never actually issues a network call.
pub fn dummy_api() -> api.Api {
  api.new("0:test")
}

/// Parses a raw update JSON body into a `types.Update`, panicking (via
/// `let assert`) if the body doesn't decode — tests intentionally fail
/// loudly on malformed fixtures rather than handling the error.
pub fn update_from(body: String) -> types.Update {
  let assert Ok(u) = json.parse(body, types.update_decoder())
  u
}

/// Parses a raw update JSON body and wraps it in a `Context` together
/// with `dummy_api()`.
pub fn ctx_from(body: String) -> context.Context {
  context.new(update_from(body), dummy_api())
}

/// Builds a private-chat text-message update, e.g. for composer/session
/// tests that only care about the message text and chat id.
pub fn message_update(text: String, chat_id: Int) -> Update {
  let body =
    "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":"
    <> int.to_string(chat_id)
    <> ",\"type\":\"private\"},\"date\":0,\"text\":\""
    <> text
    <> "\"}}"
  update_from(body)
}

/// Builds a private-chat text-message update that also carries a
/// `from` field with the given user id — for tests that key state off
/// the sending user (e.g. conversations).
pub fn message_update_from(text: String, from_id: Int) -> Update {
  let body =
    "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\""
    <> text
    <> "\",\"from\":{\"id\":"
    <> int.to_string(from_id)
    <> ",\"is_bot\":false,\"first_name\":\"X\"}}}"
  update_from(body)
}
