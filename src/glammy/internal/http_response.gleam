//// Pure HTTP response classification for the built-in `httpc` adapter.

import glammy/error.{type GlammyError, DecodeError, HttpStatusError}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/string

/// Preserve Telegram `{ok: false}` envelopes for the typed API decoder, while
/// classifying proxy/server status failures and invalid UTF-8 at the transport
/// boundary.
pub fn classify(
  method: String,
  status: Int,
  body: BitArray,
) -> Result(String, GlammyError) {
  case status >= 200 && status < 300 {
    True ->
      case bit_array.to_string(body) {
        Ok(decoded_body) -> Ok(decoded_body)
        Error(_) ->
          Error(DecodeError(method:, message: "non-utf8 response body"))
      }
    False ->
      case bit_array.to_string(body) {
        Ok(decoded_body) ->
          case is_telegram_error_envelope(decoded_body) {
            True -> Ok(decoded_body)
            False ->
              Error(HttpStatusError(
                method:,
                status:,
                body: string.slice(decoded_body, 0, 1024),
              ))
          }
        Error(_) ->
          Error(HttpStatusError(
            method:,
            status:,
            body: "<non-utf8 response body>",
          ))
      }
  }
}

fn is_telegram_error_envelope(body: String) -> Bool {
  let error_decoder = {
    use ok <- decode.field("ok", decode.bool)
    use error_code <- decode.field("error_code", decode.int)
    use description <- decode.field("description", decode.string)
    decode.success(#(ok, error_code, description))
  }
  case json.parse(body, error_decoder) {
    Ok(#(False, _, _)) -> True
    _ -> False
  }
}
