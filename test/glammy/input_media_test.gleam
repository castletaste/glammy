//// Tests mirroring grammY's `test/convenience/input_media.test.ts`.
//// grammY's `InputMediaBuilder` produces JS objects; glammy's
//// `input_media.to_json` produces JSON values, so we round-trip
//// through `gleam/json` for comparison.

import glammy/input_file
import glammy/input_media
import gleam/json
import gleam/option.{None, Some}

const file_id_token = "FILE_ID"

fn file() {
  input_file.FileId(file_id_token)
}

fn render(media: input_media.InputMedia) -> String {
  input_media.to_json(media, fn(f) {
    case f {
      input_file.FileId(id) -> id
      _ -> "attach://x"
    }
  })
  |> json.to_string
}

pub fn builds_photos_test() {
  let media =
    input_media.InputMediaPhoto(
      media: file(),
      caption: Some("photo caption"),
      parse_mode: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  assert render(media)
    == "{\"type\":\"photo\",\"media\":\"FILE_ID\",\"caption\":\"photo caption\"}"
}

pub fn builds_videos_test() {
  let media =
    input_media.InputMediaVideo(
      media: file(),
      thumbnail: None,
      caption: Some("video caption"),
      parse_mode: None,
      width: None,
      height: None,
      duration: None,
      supports_streaming: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  assert render(media)
    == "{\"type\":\"video\",\"media\":\"FILE_ID\",\"caption\":\"video caption\"}"
}

pub fn builds_animations_test() {
  let media =
    input_media.InputMediaAnimation(
      media: file(),
      thumbnail: None,
      caption: Some("animation caption"),
      parse_mode: None,
      width: None,
      height: None,
      duration: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  assert render(media)
    == "{\"type\":\"animation\",\"media\":\"FILE_ID\",\"caption\":\"animation caption\"}"
}

pub fn builds_audios_test() {
  let media =
    input_media.InputMediaAudio(
      media: file(),
      thumbnail: None,
      caption: Some("audio caption"),
      parse_mode: None,
      duration: None,
      performer: None,
      title: None,
    )
  assert render(media)
    == "{\"type\":\"audio\",\"media\":\"FILE_ID\",\"caption\":\"audio caption\"}"
}

pub fn builds_documents_test() {
  let media =
    input_media.InputMediaDocument(
      media: file(),
      thumbnail: None,
      caption: Some("document caption"),
      parse_mode: None,
      disable_content_type_detection: None,
    )
  assert render(media)
    == "{\"type\":\"document\",\"media\":\"FILE_ID\",\"caption\":\"document caption\"}"
}

// =====================================================================
//                        Extra coverage
// =====================================================================

pub fn input_media_video_with_attach_test() {
  let video_file = input_file.FileBytes(<<1, 2, 3>>, "v.mp4", Some("video/mp4"))
  let thumb_file = input_file.FileBytes(<<4, 5>>, "t.jpg", Some("image/jpeg"))
  let media =
    input_media.InputMediaVideo(
      media: video_file,
      thumbnail: Some(thumb_file),
      caption: None,
      parse_mode: None,
      width: Some(1920),
      height: Some(1080),
      duration: Some(30),
      supports_streaming: Some(True),
      has_spoiler: None,
      show_caption_above_media: None,
    )
  let json_str =
    input_media.to_json(media, fn(f) {
      case f {
        input_file.FileBytes(filename:, ..) -> "attach://" <> filename
        _ -> "fallback"
      }
    })
    |> json.to_string
  assert json_str
    == "{\"type\":\"video\","
    <> "\"media\":\"attach://v.mp4\","
    <> "\"thumbnail\":\"attach://t.jpg\","
    <> "\"width\":1920,\"height\":1080,\"duration\":30,"
    <> "\"supports_streaming\":true}"
}

pub fn input_media_document_with_url_test() {
  let media =
    input_media.InputMediaDocument(
      media: input_file.FileUrl("https://example.com/doc.pdf"),
      thumbnail: None,
      caption: None,
      parse_mode: None,
      disable_content_type_detection: Some(True),
    )
  let json_str =
    input_media.to_json(media, fn(f) {
      case f {
        input_file.FileUrl(url) -> url
        _ -> "fallback"
      }
    })
    |> json.to_string
  assert json_str
    == "{\"type\":\"document\","
    <> "\"media\":\"https://example.com/doc.pdf\","
    <> "\"disable_content_type_detection\":true}"
}
