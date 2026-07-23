//// Minimal multipart/form-data encoder. We hand-roll this rather than
//// pulling a dependency, both because the Telegram-specific surface is
//// tiny (a few text fields + file parts) and because every dependency
//// is part of our attack surface.
////
//// The output is a `BitArray` that the caller hands to `gleam/httpc`
//// together with the matching `content-type: multipart/form-data;
//// boundary=…` header.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option}
import gleam/string

/// One text or binary field in a multipart request body.
pub type Part {
  /// Plain text field, e.g. `chat_id=42`.
  TextPart(name: String, value: String)
  /// Binary file part.
  FilePart(
    name: String,
    filename: String,
    content_type: Option(String),
    body: BitArray,
  )
}

/// A complete multipart body paired with its `Content-Type` header value.
pub type Encoded {
  Encoded(body: BitArray, content_type: String)
}

const crlf: BitArray = <<"\r\n":utf8>>

/// Encode text and file parts into a multipart/form-data body.
pub fn encode(parts: List(Part)) -> Encoded {
  let boundary = random_boundary()
  let closing =
    <<"--":utf8, boundary:utf8, "--":utf8>>
    |> bit_array.append(crlf)
  let body =
    parts
    |> list.map(encode_part(_, boundary))
    |> list.append([closing])
    |> bit_array.concat
  Encoded(body:, content_type: "multipart/form-data; boundary=" <> boundary)
}

fn encode_part(part: Part, boundary: String) -> BitArray {
  let prefix = "--" <> boundary <> "\r\ncontent-disposition: form-data; name=\""
  case part {
    TextPart(name:, value:) -> {
      let name = escape_disposition_parameter(name)
      <<prefix:utf8, name:utf8, "\"":utf8>>
      |> bit_array.append(crlf)
      |> bit_array.append(crlf)
      |> bit_array.append(<<value:utf8>>)
      |> bit_array.append(crlf)
    }
    FilePart(name:, filename:, content_type:, body:) -> {
      let name = escape_disposition_parameter(name)
      let filename = escape_disposition_parameter(filename)
      let content_type = safe_content_type(content_type)
      <<
        prefix:utf8,
        name:utf8,
        "\"; filename=\"":utf8,
        filename:utf8,
        "\"":utf8,
      >>
      |> bit_array.append(crlf)
      |> bit_array.append(<<"content-type: ":utf8, content_type:utf8>>)
      |> bit_array.append(crlf)
      |> bit_array.append(crlf)
      |> bit_array.append(body)
      |> bit_array.append(crlf)
    }
  }
}

// Quoted Content-Disposition parameters must not be able to terminate the
// header line or the quoted value. Percent encoding keeps the original value
// recognisable while ensuring that user-controlled filenames stay data.
fn escape_disposition_parameter(value: String) -> String {
  value
  |> string.to_utf_codepoints
  |> list.map(fn(codepoint) {
    case string.utf_codepoint_to_int(codepoint) {
      10 -> "%0A"
      13 -> "%0D"
      34 -> "%22"
      37 -> "%25"
      92 -> "%5C"
      _ -> string.from_utf_codepoints([codepoint])
    }
  })
  |> string.concat
}

fn safe_content_type(content_type: Option(String)) -> String {
  let fallback = "application/octet-stream"
  let content_type = option.unwrap(content_type, fallback)
  let contains_control_character =
    content_type
    |> string.to_utf_codepoints
    |> list.any(fn(codepoint) {
      let value = string.utf_codepoint_to_int(codepoint)
      value < 32 || value == 127
    })
  case content_type == "" || contains_control_character {
    True -> fallback
    False -> content_type
  }
}

/// Build a boundary token that won't collide with normal payloads. We
/// use 16 bytes of cryptographically strong randomness, hex-encoded;
/// the boundary doesn't need crypto-grade randomness for correctness,
/// but using a strong source is simpler than reasoning about
/// uniqueness elsewhere.
fn random_boundary() -> String {
  let random =
    strong_rand_bytes(16)
    |> bit_array.base16_encode
    |> string.lowercase
  "glammy-" <> random
}

@external(erlang, "crypto", "strong_rand_bytes")
fn strong_rand_bytes(n: Int) -> BitArray
