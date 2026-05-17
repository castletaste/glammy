//// `InputMedia*` builders — for the `editMessageMedia` and
//// `sendMediaGroup` endpoints. Each builder produces a `json.Json`
//// suitable for placing in the payload.
////
//// Note: glammy's media-group endpoint requires that any local-file
//// `InputFile` first be turned into bytes (`FileBytes`) before the
//// JSON is constructed — the multipart parts must be supplied
//// separately. See `glammy/api.send_media_group`.

import glammy/input_file.{type InputFile}
import glammy/internal/json_utils.{put_optional}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

pub type InputMedia {
  InputMediaPhoto(
    media: InputFile,
    caption: Option(String),
    parse_mode: Option(String),
    has_spoiler: Option(Bool),
    show_caption_above_media: Option(Bool),
  )
  InputMediaVideo(
    media: InputFile,
    thumbnail: Option(InputFile),
    caption: Option(String),
    parse_mode: Option(String),
    width: Option(Int),
    height: Option(Int),
    duration: Option(Int),
    supports_streaming: Option(Bool),
    has_spoiler: Option(Bool),
    show_caption_above_media: Option(Bool),
  )
  InputMediaAudio(
    media: InputFile,
    thumbnail: Option(InputFile),
    caption: Option(String),
    parse_mode: Option(String),
    duration: Option(Int),
    performer: Option(String),
    title: Option(String),
  )
  InputMediaDocument(
    media: InputFile,
    thumbnail: Option(InputFile),
    caption: Option(String),
    parse_mode: Option(String),
    disable_content_type_detection: Option(Bool),
  )
  InputMediaAnimation(
    media: InputFile,
    thumbnail: Option(InputFile),
    caption: Option(String),
    parse_mode: Option(String),
    width: Option(Int),
    height: Option(Int),
    duration: Option(Int),
    has_spoiler: Option(Bool),
    show_caption_above_media: Option(Bool),
  )
}

/// Encode an `InputMedia` as JSON. `attach_resolver` is called with the
/// inner `InputFile` for `media` / `thumbnail` slots so the caller can
/// register the file under a multipart attachment name. The returned
/// string is what goes in the JSON `media` / `thumbnail` field (either
/// `attach://<name>` or a plain file_id / URL).
pub fn to_json(
  media: InputMedia,
  attach_resolver: fn(InputFile) -> String,
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
          #("media", json.string(attach_resolver(m))),
        ]
        |> put_optional("caption", caption, json.string)
        |> put_optional("parse_mode", parse_mode, json.string)
        |> put_optional("has_spoiler", has_spoiler, json.bool)
        |> put_optional(
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
          #("media", json.string(attach_resolver(m))),
        ]
        |> opt_thumb(thumbnail, attach_resolver)
        |> put_optional("caption", caption, json.string)
        |> put_optional("parse_mode", parse_mode, json.string)
        |> put_optional("width", width, json.int)
        |> put_optional("height", height, json.int)
        |> put_optional("duration", duration, json.int)
        |> put_optional("supports_streaming", supports_streaming, json.bool)
        |> put_optional("has_spoiler", has_spoiler, json.bool)
        |> put_optional(
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
          #("media", json.string(attach_resolver(m))),
        ]
        |> opt_thumb(thumbnail, attach_resolver)
        |> put_optional("caption", caption, json.string)
        |> put_optional("parse_mode", parse_mode, json.string)
        |> put_optional("duration", duration, json.int)
        |> put_optional("performer", performer, json.string)
        |> put_optional("title", title, json.string),
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
          #("media", json.string(attach_resolver(m))),
        ]
        |> opt_thumb(thumbnail, attach_resolver)
        |> put_optional("caption", caption, json.string)
        |> put_optional("parse_mode", parse_mode, json.string)
        |> put_optional(
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
          #("media", json.string(attach_resolver(m))),
        ]
        |> opt_thumb(thumbnail, attach_resolver)
        |> put_optional("caption", caption, json.string)
        |> put_optional("parse_mode", parse_mode, json.string)
        |> put_optional("width", width, json.int)
        |> put_optional("height", height, json.int)
        |> put_optional("duration", duration, json.int)
        |> put_optional("has_spoiler", has_spoiler, json.bool)
        |> put_optional(
          "show_caption_above_media",
          show_caption_above_media,
          json.bool,
        ),
      )
  }
}

fn opt_thumb(
  fields: List(#(String, json.Json)),
  thumbnail: Option(InputFile),
  attach_resolver: fn(InputFile) -> String,
) -> List(#(String, json.Json)) {
  case thumbnail {
    Some(f) ->
      list.append(fields, [
        #("thumbnail", json.string(attach_resolver(f))),
      ])
    None -> fields
  }
}
