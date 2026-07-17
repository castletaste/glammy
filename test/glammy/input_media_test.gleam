//// Tests mirroring grammY's `test/convenience/input_media.test.ts`.
//// grammY's `InputMediaBuilder` produces JS objects; glammy's
//// `input_media.to_json` produces JSON values, so we round-trip
//// through `gleam/json` for comparison.

import glammy/input_file
import glammy/input_media
import glammy/thumbnail
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
  let thumb_file = thumbnail.new(<<4, 5>>, "t.jpg", Some("image/jpeg"))
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

pub fn reuse_only_media_rejects_uploads_and_upload_thumbnails_test() {
  let upload =
    input_media.InputMediaPhoto(
      media: input_file.from_bytes(<<1>>, "photo.jpg"),
      caption: None,
      parse_mode: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  assert input_media.reuse_only_media(upload)
    == Error(input_media.MediaUploadNotAllowed)

  let with_thumbnail =
    input_media.InputMediaVideo(
      media: input_file.from_file_id("video-id"),
      thumbnail: Some(thumbnail.new(<<2>>, "thumb.jpg", None)),
      caption: None,
      parse_mode: None,
      width: None,
      height: None,
      duration: None,
      supports_streaming: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  assert input_media.reuse_only_media(with_thumbnail)
    == Error(input_media.ThumbnailUploadNotAllowed)

  let reusable =
    input_media.InputMediaPhoto(
      media: input_file.from_url("https://example.com/photo.jpg"),
      caption: Some("caption"),
      parse_mode: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  let assert Ok(reusable) = input_media.reuse_only_media(reusable)
  assert reusable |> input_media.reuse_only_to_json |> json.to_string
    == "{\"type\":\"photo\",\"media\":\"https://example.com/photo.jpg\",\"caption\":\"caption\"}"
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

pub fn media_group_validates_endpoint_constraints_test() {
  let photo =
    input_media.InputMediaPhoto(
      media: file(),
      caption: None,
      parse_mode: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  let animation =
    input_media.InputMediaAnimation(
      media: file(),
      thumbnail: None,
      caption: None,
      parse_mode: None,
      width: None,
      height: None,
      duration: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  let audio =
    input_media.InputMediaAudio(
      media: file(),
      thumbnail: None,
      caption: None,
      parse_mode: None,
      duration: None,
      performer: None,
      title: None,
    )
  assert input_media.media_group([photo])
    == Error(input_media.InvalidMediaGroupSize(1))
  assert input_media.media_group([photo, animation])
    == Error(input_media.AnimationNotAllowedInMediaGroup)
  assert input_media.media_group([photo, audio])
    == Error(input_media.MixedMediaGroupKinds)
}

pub fn media_group_accepts_typed_upload_thumbnail_test() {
  let video_with_thumbnail =
    input_media.InputMediaVideo(
      media: file(),
      thumbnail: Some(thumbnail.new(<<1>>, "thumb.jpg", Some("image/jpeg"))),
      caption: None,
      parse_mode: None,
      width: None,
      height: None,
      duration: None,
      supports_streaming: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  let photo =
    input_media.InputMediaPhoto(
      media: file(),
      caption: None,
      parse_mode: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  let assert Ok(_) = input_media.media_group([video_with_thumbnail, photo])
}
