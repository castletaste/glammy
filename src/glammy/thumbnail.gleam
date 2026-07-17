//// Upload-only thumbnail values for Telegram multipart methods.
////
//// Telegram does not permit thumbnail reuse by file id or URL. Keeping only
//// bytes in this opaque type makes that transport contract unrepresentable.

import glammy/input_file.{type InputFile, FileBytes}
import gleam/option.{type Option}

/// Bytes that Telegram accepts only as a fresh multipart thumbnail upload.
pub opaque type Thumbnail {
  Thumbnail(body: BitArray, filename: String, content_type: Option(String))
}

/// Create an upload-only thumbnail from bytes already read by the caller.
pub fn new(
  body: BitArray,
  filename: String,
  content_type: Option(String),
) -> Thumbnail {
  Thumbnail(body:, filename:, content_type:)
}

/// Convert a thumbnail to the package's multipart file representation.
pub fn to_input_file(thumbnail: Thumbnail) -> InputFile {
  FileBytes(
    bytes: thumbnail.body,
    filename: thumbnail.filename,
    mime_type: thumbnail.content_type,
  )
}
