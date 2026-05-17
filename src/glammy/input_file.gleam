//// `InputFile` — values that can stand in wherever the Telegram Bot API
//// asks for a file. Ported from grammY's notion of an `InputFile`:
////
//// - `FileId(id)` — a known file_id from a previous upload. Cheapest;
////   no upload required.
//// - `FileUrl(url)` — a remote URL that Telegram fetches itself.
//// - `FileBytes(bytes, filename, mime_type)` — raw bytes uploaded as
////   multipart.
//// - `FilePath(path, filename, mime_type)` — a local file path; the
////   caller loads the bytes before sending (glammy does not do disk
////   I/O inside the library).
////
//// The convenience constructors (`from_path`, `from_url`, `from_bytes`)
//// infer the filename from the source where possible — see
//// `infer_filename`.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type InputFile {
  FileId(id: String)
  FileUrl(url: String)
  FileBytes(bytes: BitArray, filename: String, mime_type: Option(String))
  FilePath(path: String, filename: String, mime_type: Option(String))
}

/// Build an `InputFile` from a local path, inferring the filename from
/// the last path segment.
pub fn from_path(path: String) -> InputFile {
  FilePath(path:, filename: filename_from_path(path), mime_type: None)
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
    FilePath(..) -> True
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
    FilePath(..) -> "attach://" <> attach_name
  }
}

/// The filename associated with this input file, if known. For `FileId`
/// the answer is `None` (the file_id alone reveals nothing about the
/// underlying file). For `FileUrl`, glammy infers the filename from the
/// URL's last segment.
pub fn infer_filename(file: InputFile) -> Option(String) {
  case file {
    FileBytes(filename:, ..) -> Some(filename)
    FilePath(filename:, ..) -> Some(filename)
    FileUrl(url:) -> Some(filename_from_url(url))
    FileId(_) -> None
  }
}

/// Pull the MIME type if known.
pub fn mime_type(file: InputFile) -> Option(String) {
  case file {
    FileBytes(mime_type:, ..) -> mime_type
    FilePath(mime_type:, ..) -> mime_type
    _ -> None
  }
}

// =====================================================================
//                          internal helpers
// =====================================================================

fn filename_from_path(path: String) -> String {
  path
  |> string.split("/")
  |> list.last
  |> result_or("")
}

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

fn result_or(r: Result(a, b), default: a) -> a {
  case r {
    Ok(v) -> v
    Error(_) -> default
  }
}
