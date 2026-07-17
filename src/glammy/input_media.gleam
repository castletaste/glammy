//// `InputMedia*` builders — for the `editMessageMedia` and
//// `sendMediaGroup` endpoints. Variants stay typed until encoded at the
//// multipart payload boundary.
////
//// Use `media_group` to validate an album before passing it to
//// `glammy/api.send_media_group`.

import glammy/input_file.{type InputFile}
import glammy/internal/json_utils
import glammy/parse_mode.{type ParseMode}
import glammy/thumbnail.{type Thumbnail}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A typed Telegram input-media payload for editing or album delivery.
pub type InputMedia {
  /// Photo media with photo-specific caption and spoiler options.
  InputMediaPhoto(
    media: InputFile,
    caption: Option(String),
    parse_mode: Option(ParseMode),
    has_spoiler: Option(Bool),
    show_caption_above_media: Option(Bool),
  )
  /// Video media with upload-only thumbnail and video metadata.
  InputMediaVideo(
    media: InputFile,
    thumbnail: Option(Thumbnail),
    caption: Option(String),
    parse_mode: Option(ParseMode),
    width: Option(Int),
    height: Option(Int),
    duration: Option(Int),
    supports_streaming: Option(Bool),
    has_spoiler: Option(Bool),
    show_caption_above_media: Option(Bool),
  )
  /// Audio media with upload-only thumbnail and track metadata.
  InputMediaAudio(
    media: InputFile,
    thumbnail: Option(Thumbnail),
    caption: Option(String),
    parse_mode: Option(ParseMode),
    duration: Option(Int),
    performer: Option(String),
    title: Option(String),
  )
  /// Document media with upload-only thumbnail and content detection control.
  InputMediaDocument(
    media: InputFile,
    thumbnail: Option(Thumbnail),
    caption: Option(String),
    parse_mode: Option(ParseMode),
    disable_content_type_detection: Option(Bool),
  )
  /// Animation media; valid for edits but intentionally rejected in albums.
  InputMediaAnimation(
    media: InputFile,
    thumbnail: Option(Thumbnail),
    caption: Option(String),
    parse_mode: Option(ParseMode),
    width: Option(Int),
    height: Option(Int),
    duration: Option(Int),
    has_spoiler: Option(Bool),
    show_caption_above_media: Option(Bool),
  )
}

/// Proof that an input-media value contains only an existing Telegram file id
/// or a remote URL, with no multipart-only thumbnail.
///
/// Ephemeral media edits cannot upload a new file. The constructor below
/// validates that restriction once so the typed API cannot accidentally emit
/// an unusable `attach://` reference in a JSON request.
pub opaque type ReuseOnlyInputMedia {
  ReuseOnlyInputMedia(InputMedia)
}

/// Why input media cannot be used by a reuse-only endpoint.
pub type ReuseOnlyInputMediaError {
  MediaUploadNotAllowed
  ThumbnailUploadNotAllowed
}

/// Validate media for an endpoint that accepts only file ids or remote URLs.
pub fn reuse_only_media(
  media: InputMedia,
) -> Result(ReuseOnlyInputMedia, ReuseOnlyInputMediaError) {
  let #(file, thumbnail_value) = media_files(media)
  case input_file.requires_upload(file), thumbnail_value {
    True, _ -> Error(MediaUploadNotAllowed)
    False, Some(_) -> Error(ThumbnailUploadNotAllowed)
    False, None -> Ok(ReuseOnlyInputMedia(media))
  }
}

/// Encode already-validated reuse-only media for a JSON request.
pub fn reuse_only_to_json(media: ReuseOnlyInputMedia) -> json.Json {
  let ReuseOnlyInputMedia(value) = media
  to_json(value, input_file.to_payload_value(_, "reuse_only"))
}

/// A Telegram-compatible media album. Construction validates the endpoint's
/// cross-item constraints so `api.send_media_group` cannot receive an invalid
/// raw list.
pub opaque type MediaGroup {
  MediaGroup(items: List(InputMedia))
}

/// Why a list cannot be represented as a Telegram media album.
pub type MediaGroupError {
  /// Telegram albums contain two to ten items.
  InvalidMediaGroupSize(size: Int)
  /// Telegram does not allow animations inside media groups.
  AnimationNotAllowedInMediaGroup
  /// Audio/document albums cannot mix their kind with other media.
  MixedMediaGroupKinds
}

type MediaGroupKind {
  VisualMediaGroup
  AudioMediaGroup
  DocumentMediaGroup
}

/// Validate a 2–10 item Telegram media group. Photos and videos may be mixed;
/// audio and document albums must contain only their own kind.
pub fn media_group(
  items: List(InputMedia),
) -> Result(MediaGroup, MediaGroupError) {
  let size = list.length(items)
  case size >= 2 && size <= 10 {
    False -> Error(InvalidMediaGroupSize(size:))
    True -> {
      use kinds <- result.try(list.try_map(items, media_group_kind))
      case kinds {
        [first, ..rest] ->
          case list.all(rest, fn(kind) { kind == first }) {
            True -> Ok(MediaGroup(items:))
            False -> Error(MixedMediaGroupKinds)
          }
        [] -> Error(InvalidMediaGroupSize(size:))
      }
    }
  }
}

fn media_group_kind(
  media: InputMedia,
) -> Result(MediaGroupKind, MediaGroupError) {
  case media {
    InputMediaPhoto(..) | InputMediaVideo(..) -> Ok(VisualMediaGroup)
    InputMediaAudio(..) -> Ok(AudioMediaGroup)
    InputMediaDocument(..) -> Ok(DocumentMediaGroup)
    InputMediaAnimation(..) -> Error(AnimationNotAllowedInMediaGroup)
  }
}

/// Return the already-validated items in an album.
pub fn media_group_items(group: MediaGroup) -> List(InputMedia) {
  group.items
}

/// Encode an `InputMedia` as JSON. `attach_resolver` is called with the
/// inner `InputFile` for `media` slots so the caller can register the file
/// under a multipart attachment name. Upload-only thumbnails are resolved
/// through the same function after typed conversion. The returned
/// string is what goes in the JSON `media` / `thumbnail` field (either
/// `attach://<name>` or a plain file_id / URL).
pub fn to_json(
  media: InputMedia,
  attach_resolver: fn(InputFile) -> String,
) -> json.Json {
  encode(media, attach_resolver, attach_resolver)
}

fn encode(
  media: InputMedia,
  media_resolver: fn(InputFile) -> String,
  thumbnail_resolver: fn(InputFile) -> String,
) -> json.Json {
  case media {
    InputMediaPhoto(
      media: m,
      caption:,
      parse_mode:,
      has_spoiler:,
      show_caption_above_media:,
    ) ->
      json.object(
        [
          #("type", json.string("photo")),
          #("media", json.string(media_resolver(m))),
        ]
        |> json_utils.put_optional("caption", caption, json.string)
        |> json_utils.put_optional("parse_mode", parse_mode, fn(mode) {
          json.string(parse_mode.to_string(mode))
        })
        |> json_utils.put_optional("has_spoiler", has_spoiler, json.bool)
        |> json_utils.put_optional(
          "show_caption_above_media",
          show_caption_above_media,
          json.bool,
        ),
      )
    InputMediaVideo(
      media: m,
      thumbnail:,
      caption:,
      parse_mode:,
      width:,
      height:,
      duration:,
      supports_streaming:,
      has_spoiler:,
      show_caption_above_media:,
    ) ->
      json.object(
        [
          #("type", json.string("video")),
          #("media", json.string(media_resolver(m))),
        ]
        |> opt_thumb(thumbnail, thumbnail_resolver)
        |> json_utils.put_optional("caption", caption, json.string)
        |> json_utils.put_optional("parse_mode", parse_mode, fn(mode) {
          json.string(parse_mode.to_string(mode))
        })
        |> json_utils.put_optional("width", width, json.int)
        |> json_utils.put_optional("height", height, json.int)
        |> json_utils.put_optional("duration", duration, json.int)
        |> json_utils.put_optional(
          "supports_streaming",
          supports_streaming,
          json.bool,
        )
        |> json_utils.put_optional("has_spoiler", has_spoiler, json.bool)
        |> json_utils.put_optional(
          "show_caption_above_media",
          show_caption_above_media,
          json.bool,
        ),
      )
    InputMediaAudio(
      media: m,
      thumbnail:,
      caption:,
      parse_mode:,
      duration:,
      performer:,
      title:,
    ) ->
      json.object(
        [
          #("type", json.string("audio")),
          #("media", json.string(media_resolver(m))),
        ]
        |> opt_thumb(thumbnail, thumbnail_resolver)
        |> json_utils.put_optional("caption", caption, json.string)
        |> json_utils.put_optional("parse_mode", parse_mode, fn(mode) {
          json.string(parse_mode.to_string(mode))
        })
        |> json_utils.put_optional("duration", duration, json.int)
        |> json_utils.put_optional("performer", performer, json.string)
        |> json_utils.put_optional("title", title, json.string),
      )
    InputMediaDocument(
      media: m,
      thumbnail:,
      caption:,
      parse_mode:,
      disable_content_type_detection:,
    ) ->
      json.object(
        [
          #("type", json.string("document")),
          #("media", json.string(media_resolver(m))),
        ]
        |> opt_thumb(thumbnail, thumbnail_resolver)
        |> json_utils.put_optional("caption", caption, json.string)
        |> json_utils.put_optional("parse_mode", parse_mode, fn(mode) {
          json.string(parse_mode.to_string(mode))
        })
        |> json_utils.put_optional(
          "disable_content_type_detection",
          disable_content_type_detection,
          json.bool,
        ),
      )
    InputMediaAnimation(
      media: m,
      thumbnail:,
      caption:,
      parse_mode:,
      width:,
      height:,
      duration:,
      has_spoiler:,
      show_caption_above_media:,
    ) ->
      json.object(
        [
          #("type", json.string("animation")),
          #("media", json.string(media_resolver(m))),
        ]
        |> opt_thumb(thumbnail, thumbnail_resolver)
        |> json_utils.put_optional("caption", caption, json.string)
        |> json_utils.put_optional("parse_mode", parse_mode, fn(mode) {
          json.string(parse_mode.to_string(mode))
        })
        |> json_utils.put_optional("width", width, json.int)
        |> json_utils.put_optional("height", height, json.int)
        |> json_utils.put_optional("duration", duration, json.int)
        |> json_utils.put_optional("has_spoiler", has_spoiler, json.bool)
        |> json_utils.put_optional(
          "show_caption_above_media",
          show_caption_above_media,
          json.bool,
        ),
      )
  }
}

/// Prepare one album item for multipart encoding. Attachment names are stable
/// and unique per item; callers only need to add parts for `FileBytes` values.
pub fn prepare_multipart(
  media: InputMedia,
  index: Int,
) -> #(json.Json, List(#(String, InputFile))) {
  let suffix = int.to_string(index)
  let media_name = "media_" <> suffix
  let thumbnail_name = "thumbnail_" <> suffix
  let #(media_file, thumbnail_file) = media_files(media)
  let encoded =
    encode(
      media,
      input_file.to_payload_value(_, media_name),
      input_file.to_payload_value(_, thumbnail_name),
    )
  let attachments = case thumbnail_file {
    Some(file) -> [
      #(media_name, media_file),
      #(thumbnail_name, thumbnail.to_input_file(file)),
    ]
    None -> [#(media_name, media_file)]
  }
  #(encoded, attachments)
}

fn media_files(media: InputMedia) -> #(InputFile, Option(Thumbnail)) {
  case media {
    InputMediaPhoto(media:, ..) -> #(media, None)
    InputMediaVideo(media:, thumbnail:, ..)
    | InputMediaAudio(media:, thumbnail:, ..)
    | InputMediaDocument(media:, thumbnail:, ..)
    | InputMediaAnimation(media:, thumbnail:, ..) -> #(media, thumbnail)
  }
}

fn opt_thumb(
  fields: List(#(String, json.Json)),
  thumbnail_value: Option(Thumbnail),
  attach_resolver: fn(InputFile) -> String,
) -> List(#(String, json.Json)) {
  case thumbnail_value {
    Some(f) ->
      list.append(fields, [
        #("thumbnail", json.string(attach_resolver(thumbnail.to_input_file(f)))),
      ])
    None -> fields
  }
}
