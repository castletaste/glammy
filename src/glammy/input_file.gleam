//// `InputFile` — values that can stand in wherever the Telegram Bot API
//// asks for a file. Ported from grammY's notion of an `InputFile`:
////
//// - `FileId(id)` — a known file_id from a previous upload. Cheapest;
////   no upload required.
//// - `FileUrl(url)` — a remote URL that Telegram fetches itself.
//// - `FileBytes(bytes, filename, mime_type)` — raw bytes uploaded as
////   multipart.
////
//// Local paths are deliberately not represented: a sans-I/O value must
//// contain the bytes it promises to upload. Read files at the application
//// boundary and pass them to `from_bytes`.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A Telegram file reference or an in-memory upload.
pub type InputFile {
  FileId(id: String)
  FileUrl(url: String)
  FileBytes(bytes: BitArray, filename: String, mime_type: Option(String))
}

/// A file source for endpoints that categorically reject remote URLs.
///
/// Telegram's `sendVideoNote` accepts only an existing `file_id` or a new
/// multipart upload. Opaque construction prevents URLs and forged
/// `attach://` references from being labelled as file identifiers.
pub opaque type FileIdOrUpload {
  FileIdOnly(id: String)
  UploadOnly(bytes: BitArray, filename: String, mime_type: Option(String))
}

/// Why a string could not be used as an existing Telegram file identifier.
pub type FileIdSourceError {
  EmptyFileIdSource
  RemoteUrlSourceNotAllowed
  AttachmentSourceNotAllowed
}

/// Build a URL-free source from an existing Telegram `file_id`.
///
/// Leading and trailing whitespace is removed. Empty values, URL-like strings,
/// and `attach:` references are rejected before they reach `sendVideoNote`.
pub fn file_id_source(id: String) -> Result(FileIdOrUpload, FileIdSourceError) {
  let id = string.trim(id)
  let lowercase_id = string.lowercase(id)
  let is_attachment = string.starts_with(lowercase_id, "attach:")
  let is_remote_url = has_uri_scheme(id)
  case id, is_attachment, is_remote_url {
    "", _, _ -> Error(EmptyFileIdSource)
    _, True, _ -> Error(AttachmentSourceNotAllowed)
    _, _, True -> Error(RemoteUrlSourceNotAllowed)
    _, False, False -> Ok(FileIdOnly(id:))
  }
}

fn has_uri_scheme(value: String) -> Bool {
  case string.split(value, ":") {
    [scheme, _, ..] ->
      case string.to_graphemes(scheme) {
        [first, ..rest] ->
          is_ascii_letter(first) && list.all(rest, is_uri_scheme_character)
        [] -> False
      }
    _ -> False
  }
}

fn is_uri_scheme_character(character: String) -> Bool {
  is_ascii_letter(character) || string.contains("0123456789+.-", character)
}

fn is_ascii_letter(character: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    character,
  )
}

/// Build a URL-free source from bytes that will be uploaded as multipart data.
pub fn upload_source(
  bytes: BitArray,
  filename: String,
  mime_type: Option(String),
) -> FileIdOrUpload {
  UploadOnly(bytes:, filename:, mime_type:)
}

/// Convert a URL-free source into the general `InputFile` representation used
/// by the multipart transport.
pub fn file_id_or_upload_to_input_file(source: FileIdOrUpload) -> InputFile {
  case source {
    FileIdOnly(id) -> FileId(id)
    UploadOnly(bytes:, filename:, mime_type:) ->
      FileBytes(bytes:, filename:, mime_type:)
  }
}

/// Build an `InputFile` from raw bytes.
pub fn from_bytes(bytes: BitArray, filename: String) -> InputFile {
  FileBytes(bytes:, filename:, mime_type: None)
}

/// Build an `InputFile` from a remote URL. Telegram fetches the file
/// itself — no bytes are uploaded by glammy.
pub fn from_url(url: String) -> InputFile {
  FileUrl(url:)
}

/// Build an `InputFile` from a known `file_id` (returned by a prior
/// upload). This is the cheapest variant: no upload, no fetch.
pub fn from_file_id(id: String) -> InputFile {
  FileId(id:)
}

/// Does this `InputFile` require a multipart upload?
pub fn requires_upload(file: InputFile) -> Bool {
  case file {
    FileBytes(..) -> True
    _ -> False
  }
}

/// Produce the JSON-string form for in-payload encoding. For non-multipart
/// inputs (`FileId` / `FileUrl`) the value is the literal string Telegram
/// expects. For multipart inputs the value is an `attach://<name>` token
/// that references a part in the multipart body.
pub fn to_payload_value(file: InputFile, attach_name: String) -> String {
  case file {
    FileId(id) -> id
    FileUrl(url) -> url
    FileBytes(..) -> "attach://" <> attach_name
  }
}

/// The filename associated with this input file, if known. For `FileId`
/// the answer is `None` (the file_id alone reveals nothing about the
/// underlying file). For `FileUrl`, glammy infers the filename from the
/// URL's last segment.
pub fn infer_filename(file: InputFile) -> Option(String) {
  case file {
    FileBytes(filename:, ..) -> Some(filename)
    FileUrl(url:) -> Some(filename_from_url(url))
    FileId(_) -> None
  }
}

/// Pull the MIME type if known.
pub fn mime_type(file: InputFile) -> Option(String) {
  case file {
    FileBytes(mime_type:, ..) -> mime_type
    _ -> None
  }
}

// =====================================================================
//                          internal helpers
// =====================================================================

fn filename_from_url(url: String) -> String {
  // Strip the scheme + leading `//`, then take everything after the
  // host. If the result is empty (no path component), fall back to the
  // host.
  let without_scheme = case string.split_once(url, "://") {
    Ok(#(_, rest)) -> rest
    Error(_) -> url
  }
  case string.split(without_scheme, "/") {
    [host, ..segments] ->
      case list.last(segments) {
        Ok(s) ->
          case s {
            "" -> host
            value -> value
          }
        Error(_) -> host
      }
    _ -> without_scheme
  }
}
