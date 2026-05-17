//// Tests mirroring grammY's `test/core/payload.test.ts` plus a few
//// glammy-specific corners.

import glammy/multipart
import gleam/bit_array
import gleam/option.{None, Some}
import gleam/string

pub fn encode_text_part_test() {
  let encoded = multipart.encode([multipart.TextPart(name: "key", value: "v")])
  let assert Ok(body_string) = bit_array.to_string(encoded.body)
  assert string.contains(
    body_string,
    "content-disposition: form-data; name=\"key\"",
  )
  assert string.contains(body_string, "v\r\n")
  assert string.starts_with(
    encoded.content_type,
    "multipart/form-data; boundary=",
  )
}

pub fn encode_file_part_test() {
  let part =
    multipart.FilePart(
      name: "photo",
      filename: "cat.png",
      content_type: Some("image/png"),
      body: <<"PNGDATA":utf8>>,
    )
  let encoded = multipart.encode([part])
  let assert Ok(body_string) = bit_array.to_string(encoded.body)
  assert string.contains(body_string, "filename=\"cat.png\"")
  assert string.contains(body_string, "content-type: image/png")
  assert string.contains(body_string, "PNGDATA")
}

pub fn encode_falls_back_to_octet_stream_test() {
  let part =
    multipart.FilePart(
      name: "blob",
      filename: "unknown.bin",
      content_type: None,
      body: <<1, 2, 3>>,
    )
  let encoded = multipart.encode([part])
  let assert Ok(body_string) = bit_array.to_string(encoded.body)
  assert string.contains(body_string, "content-type: application/octet-stream")
}

pub fn encode_terminates_with_closing_boundary_test() {
  let encoded = multipart.encode([multipart.TextPart(name: "a", value: "b")])
  let assert Ok(body_string) = bit_array.to_string(encoded.body)
  let assert Ok(#(_, boundary)) =
    string.split_once(encoded.content_type, "boundary=")
  let closing = "--" <> boundary <> "--\r\n"
  assert string.ends_with(body_string, closing)
}

/// grammY's `builds multipart/form-data streams` test.
pub fn builds_multipart_form_data_streams_test() {
  let document =
    multipart.FilePart(
      name: "document",
      filename: "my-file",
      content_type: None,
      body: <<"abc":utf8>>,
    )
  let parts = [
    multipart.TextPart(name: "chat_id", value: "42"),
    document,
  ]
  let encoded = multipart.encode(parts)
  let assert Ok(body_string) = bit_array.to_string(encoded.body)
  let assert Ok(#(_, boundary)) =
    string.split_once(encoded.content_type, "boundary=")

  // Verify the structure: opening boundary, two parts in order, closing
  // boundary.
  assert string.contains(body_string, "--" <> boundary)
  assert string.contains(
    body_string,
    "content-disposition: form-data; name=\"chat_id\"",
  )
  assert string.contains(body_string, "42\r\n")
  assert string.contains(
    body_string,
    "content-disposition: form-data; name=\"document\"",
  )
  assert string.contains(body_string, "filename=\"my-file\"")
  assert string.contains(body_string, "content-type: application/octet-stream")
  assert string.contains(body_string, "abc")
  assert string.ends_with(body_string, "--" <> boundary <> "--\r\n")
}

/// grammY's `builds … repeatedly` test verifies that each call uses a
/// fresh boundary (so the same parts can be retransmitted without
/// colliding boundary tokens).
pub fn boundary_is_fresh_on_each_call_test() {
  let parts = [multipart.TextPart(name: "k", value: "v")]
  let first = multipart.encode(parts)
  let second = multipart.encode(parts)
  let third = multipart.encode(parts)
  assert first.content_type != second.content_type
  assert second.content_type != third.content_type
  assert first.content_type != third.content_type
}

/// Verify that text parts are correctly delimited by CRLFs.
pub fn text_part_has_correct_delimiters_test() {
  let encoded =
    multipart.encode([multipart.TextPart(name: "field", value: "VALUE")])
  let assert Ok(body) = bit_array.to_string(encoded.body)
  // The pattern: …name="field"\r\n\r\nVALUE\r\n--<boundary>--\r\n
  assert string.contains(body, "name=\"field\"\r\n\r\nVALUE\r\n")
}
