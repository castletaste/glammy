//// Tests mirroring grammY's `test/types.test.ts`. The grammY tests
//// exercise its `InputFile` class which auto-loads from paths/URLs;
//// glammy's `InputFile` is intentionally a description-only value and
//// performs no disk or network I/O itself. The tests here cover the
//// subset of behaviour that is meaningful here: filename inference.

import glammy/input_file
import gleam/option.{None, Some}

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

pub fn url_free_sources_convert_to_general_input_files_test() {
  let assert Ok(file_id) = input_file.file_id_source(" video-note-id ")
  assert input_file.file_id_or_upload_to_input_file(file_id)
    == input_file.FileId("video-note-id")
  let upload = input_file.upload_source(<<1, 2>>, "note.mp4", Some("video/mp4"))
  assert input_file.file_id_or_upload_to_input_file(upload)
    == input_file.FileBytes(<<1, 2>>, "note.mp4", Some("video/mp4"))
}

pub fn url_free_file_id_source_rejects_invalid_values_test() {
  assert input_file.file_id_source("") == Error(input_file.EmptyFileIdSource)
  assert input_file.file_id_source("   ") == Error(input_file.EmptyFileIdSource)
  assert input_file.file_id_source("https://example.com/note.mp4")
    == Error(input_file.RemoteUrlSourceNotAllowed)
  assert input_file.file_id_source("HTTP://example.com/note.mp4")
    == Error(input_file.RemoteUrlSourceNotAllowed)
  assert input_file.file_id_source("file://note.mp4")
    == Error(input_file.RemoteUrlSourceNotAllowed)
  assert input_file.file_id_source("data:video/mp4;base64,AAAA")
    == Error(input_file.RemoteUrlSourceNotAllowed)
  assert input_file.file_id_source("mailto:bot@example.com")
    == Error(input_file.RemoteUrlSourceNotAllowed)
  assert input_file.file_id_source("custom+transport:note")
    == Error(input_file.RemoteUrlSourceNotAllowed)
  assert input_file.file_id_source("attach://video_note")
    == Error(input_file.AttachmentSourceNotAllowed)
  assert input_file.file_id_source("ATTACH:video_note")
    == Error(input_file.AttachmentSourceNotAllowed)
}
