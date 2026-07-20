//// Error variants raised by glammy when talking to the Telegram Bot API.

import glammy/types.{type ResponseParameters}
import gleam/httpc
import gleam/int

/// Failures produced while preparing, sending, or decoding a Bot API call.
pub type GlammyError {
  /// The HTTP call succeeded, but Telegram returned `ok: false`. This
  /// mirrors `GrammyError` in the grammY source — the request reached
  /// Telegram's servers and was rejected for an application-level
  /// reason (bad token, chat-not-found, flood, …).
  ApiError(
    method: String,
    error_code: Int,
    description: String,
    parameters: ResponseParameters,
  )
  /// The HTTP request itself failed (network, TLS, timeout). Mirrors
  /// grammY's `HttpError`.
  HttpError(method: String, reason: httpc.HttpError)
  /// The server returned a non-success HTTP status without a valid Telegram
  /// `{ok: false, ...}` error envelope.
  HttpStatusError(method: String, status: Int, body: String)
  /// The HTTP response body could not be parsed as a Telegram API
  /// response.
  DecodeError(method: String, message: String)
}

/// Human-readable single-line description of an error. Suitable for
/// logging.
pub fn describe(err: GlammyError) -> String {
  case err {
    ApiError(method:, error_code:, description:, ..) ->
      "Call to '"
      <> method
      <> "' failed! ("
      <> int.to_string(error_code)
      <> ": "
      <> description
      <> ")"
    HttpError(method:, ..) -> "Network request for '" <> method <> "' failed!"
    HttpStatusError(method:, status:, ..) ->
      "HTTP " <> int.to_string(status) <> " returned for '" <> method <> "'"
    DecodeError(method:, message:) ->
      "Decode error in '" <> method <> "': " <> message
  }
}
