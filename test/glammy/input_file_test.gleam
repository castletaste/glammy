//// Tests mirroring grammY's `test/types.test.ts`. The grammY tests
//// exercise its `InputFile` class which auto-loads from paths/URLs;
//// glammy's `InputFile` is intentionally a description-only value and
//// performs no disk or network I/O itself. The tests here cover the
//// subset of behaviour that is meaningful here: filename inference.

import glammy/input_file
import gleam/option.{None, Some}

pub fn filename_from_path_test() {
  assert input_file.infer_filename(input_file.from_path("/tmp/file.txt"))
    == Some("file.txt")
}

pub fn filename_from_url_with_path_test() {
  assert input_file.infer_filename(input_file.from_url(
      "https://grammy.dev/file.txt",
    ))
    == Some("file.txt")
}

pub fn filename_from_url_no_path_falls_back_to_host_test() {
  assert input_file.infer_filename(input_file.from_url("https://grammy.dev"))
    == Some("grammy.dev")
}

pub fn file_id_has_no_inferable_filename_test() {
  assert input_file.infer_filename(input_file.from_file_id("abc123")) == None
}

pub fn from_bytes_preserves_filename_test() {
  let file = input_file.from_bytes(<<65, 66, 67>>, "AB.bin")
  assert input_file.infer_filename(file) == Some("AB.bin")
  assert input_file.requires_upload(file) == True
}

pub fn from_path_requires_upload_test() {
  assert input_file.requires_upload(input_file.from_path("/tmp/x")) == True
}

pub fn file_id_and_url_do_not_require_upload_test() {
  assert input_file.requires_upload(input_file.from_file_id("x")) == False
  assert input_file.requires_upload(input_file.from_url("https://x")) == False
}

pub fn payload_value_for_file_id_test() {
  assert input_file.to_payload_value(input_file.from_file_id("abc"), "n")
    == "abc"
}

pub fn payload_value_for_url_test() {
  assert input_file.to_payload_value(
      input_file.from_url("https://example.com/x"),
      "n",
    )
    == "https://example.com/x"
}

pub fn payload_value_for_bytes_uses_attach_scheme_test() {
  let file = input_file.from_bytes(<<1, 2, 3>>, "x.bin")
  assert input_file.to_payload_value(file, "photo") == "attach://photo"
}
