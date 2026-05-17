//// Minimal multipart/form-data encoder. We hand-roll this rather than
//// pulling a dependency, both because the Telegram-specific surface is
//// tiny (a few text fields + file parts) and because every dependency
//// is part of our attack surface.
////
//// The output is a `BitArray` that the caller hands to `gleam/httpc`
//// together with the matching `content-type: multipart/form-data;
//// boundary=…` header.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option}

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

pub type Encoded {
  Encoded(body: BitArray, content_type: String)
}

const crlf: BitArray = <<"\r\n":utf8>>

pub fn encode(parts: List(Part)) -> Encoded {
  let boundary = random_boundary()
  let body =
    list.fold(parts, <<>>, fn(acc, part) {
      bit_array.concat([acc, encode_part(part, boundary)])
    })
  let closing =
    <<"--":utf8, boundary:utf8, "--":utf8>>
    |> bit_array.append(crlf)
  Encoded(
    body: bit_array.append(body, closing),
    content_type: "multipart/form-data; boundary=" <> boundary,
  )
}

fn encode_part(part: Part, boundary: String) -> BitArray {
  let prefix = "--" <> boundary <> "\r\ncontent-disposition: form-data; name=\""
  case part {
    TextPart(name:, value:) ->
      <<prefix:utf8, name:utf8, "\"":utf8>>
      |> bit_array.append(crlf)
      |> bit_array.append(crlf)
      |> bit_array.append(<<value:utf8>>)
      |> bit_array.append(crlf)
    FilePart(name:, filename:, content_type:, body:) -> {
      let ct = option.unwrap(content_type, "application/octet-stream")
      <<
        prefix:utf8,
        name:utf8,
        "\"; filename=\"":utf8,
        filename:utf8,
        "\"":utf8,
      >>
      |> bit_array.append(crlf)
      |> bit_array.append(<<"content-type: ":utf8, ct:utf8>>)
      |> bit_array.append(crlf)
      |> bit_array.append(crlf)
      |> bit_array.append(body)
      |> bit_array.append(crlf)
    }
  }
}

/// Build a boundary token that won't collide with normal payloads. We
/// use 16 bytes of cryptographically strong randomness, hex-encoded;
/// the boundary doesn't need crypto-grade randomness for correctness,
/// but using a strong source is simpler than reasoning about
/// uniqueness elsewhere.
fn random_boundary() -> String {
  "glammy-" <> hex_encode(strong_rand_bytes(16))
}

@external(erlang, "crypto", "strong_rand_bytes")
fn strong_rand_bytes(n: Int) -> BitArray

fn hex_encode(bits: BitArray) -> String {
  do_hex_encode(bits, "")
}

fn do_hex_encode(bits: BitArray, acc: String) -> String {
  case bits {
    <<>> -> acc
    <<byte:int-size(8), rest:bits>> -> {
      let high = int.bitwise_shift_right(byte, 4)
      let low = int.bitwise_and(byte, 15)
      do_hex_encode(rest, acc <> hex_digit(high) <> hex_digit(low))
    }
    _ -> acc
  }
}

fn hex_digit(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    10 -> "a"
    11 -> "b"
    12 -> "c"
    13 -> "d"
    14 -> "e"
    15 -> "f"
    _ -> "0"
  }
}
