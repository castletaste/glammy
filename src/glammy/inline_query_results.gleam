//// Builders for the various `InlineQueryResult*` shapes that
//// `answerInlineQuery` accepts. Each builder returns a `json.Json`
//// ready to drop into the results array.

import glammy/internal/json_utils.{put_optional, put_optional_json}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

pub type InputMessageContent {
  InputTextMessageContent(
    message_text: String,
    parse_mode: Option(String),
    disable_web_page_preview: Option(Bool),
  )
  InputLocationMessageContent(
    latitude: Float,
    longitude: Float,
    horizontal_accuracy: Option(Float),
    live_period: Option(Int),
  )
  InputVenueMessageContent(
    latitude: Float,
    longitude: Float,
    title: String,
    address: String,
  )
  InputContactMessageContent(
    phone_number: String,
    first_name: String,
    last_name: Option(String),
  )
  InputInvoiceMessageContent(
    title: String,
    description: String,
    payload: String,
    provider_token: Option(String),
    currency: String,
    prices: List(#(String, Int)),
  )
}

pub fn input_message_content_to_json(
  content: InputMessageContent,
) -> json.Json {
  case content {
    InputTextMessageContent(
      message_text:,
      parse_mode:,
      disable_web_page_preview:,
    ) ->
      json.object(
        [#("message_text", json.string(message_text))]
        |> put_optional("parse_mode", parse_mode, json.string)
        |> put_optional(
          "disable_web_page_preview",
          disable_web_page_preview,
          json.bool,
        ),
      )
    InputLocationMessageContent(
      latitude:,
      longitude:,
      horizontal_accuracy:,
      live_period:,
    ) ->
      json.object(
        [
          #("latitude", json.float(latitude)),
          #("longitude", json.float(longitude)),
        ]
        |> put_optional("horizontal_accuracy", horizontal_accuracy, json.float)
        |> put_optional("live_period", live_period, json.int),
      )
    InputVenueMessageContent(latitude:, longitude:, title:, address:) ->
      json.object([
        #("latitude", json.float(latitude)),
        #("longitude", json.float(longitude)),
        #("title", json.string(title)),
        #("address", json.string(address)),
      ])
    InputContactMessageContent(phone_number:, first_name:, last_name:) ->
      json.object(
        [
          #("phone_number", json.string(phone_number)),
          #("first_name", json.string(first_name)),
        ]
        |> put_optional("last_name", last_name, json.string),
      )
    InputInvoiceMessageContent(
      title:,
      description:,
      payload:,
      provider_token:,
      currency:,
      prices:,
    ) ->
      json.object(
        [
          #("title", json.string(title)),
          #("description", json.string(description)),
          #("payload", json.string(payload)),
          #("currency", json.string(currency)),
          #(
            "prices",
            json.array(prices, fn(p) {
              json.object([
                #("label", json.string(p.0)),
                #("amount", json.int(p.1)),
              ])
            }),
          ),
        ]
        |> put_optional("provider_token", provider_token, json.string),
      )
  }
}

// =====================================================================
//                            Result builders
// =====================================================================

pub fn article(
  id: String,
  title: String,
  input_message_content: InputMessageContent,
  description: Option(String),
  url: Option(String),
  thumbnail_url: Option(String),
  reply_markup: Option(json.Json),
) -> json.Json {
  json.object(
    [
      #("type", json.string("article")),
      #("id", json.string(id)),
      #("title", json.string(title)),
      #(
        "input_message_content",
        input_message_content_to_json(input_message_content),
      ),
    ]
    |> put_optional("description", description, json.string)
    |> put_optional("url", url, json.string)
    |> put_optional("thumbnail_url", thumbnail_url, json.string)
    |> put_optional_json("reply_markup", reply_markup),
  )
}

pub fn photo(
  id: String,
  photo_url: String,
  thumbnail_url: String,
  caption: Option(String),
  title: Option(String),
  description: Option(String),
  reply_markup: Option(json.Json),
  input_message_content: Option(InputMessageContent),
) -> json.Json {
  [
    #("type", json.string("photo")),
    #("id", json.string(id)),
    #("photo_url", json.string(photo_url)),
    #("thumbnail_url", json.string(thumbnail_url)),
  ]
  |> put_optional("title", title, json.string)
  |> put_optional("description", description, json.string)
  |> finish_result(caption, reply_markup, input_message_content)
}

pub fn video(
  id: String,
  video_url: String,
  mime_type: String,
  thumbnail_url: String,
  title: String,
  caption: Option(String),
  description: Option(String),
  reply_markup: Option(json.Json),
  input_message_content: Option(InputMessageContent),
) -> json.Json {
  [
    #("type", json.string("video")),
    #("id", json.string(id)),
    #("video_url", json.string(video_url)),
    #("mime_type", json.string(mime_type)),
    #("thumbnail_url", json.string(thumbnail_url)),
    #("title", json.string(title)),
  ]
  |> put_optional("description", description, json.string)
  |> finish_result(caption, reply_markup, input_message_content)
}

pub fn audio(
  id: String,
  audio_url: String,
  title: String,
  performer: Option(String),
  audio_duration: Option(Int),
  caption: Option(String),
  reply_markup: Option(json.Json),
  input_message_content: Option(InputMessageContent),
) -> json.Json {
  [
    #("type", json.string("audio")),
    #("id", json.string(id)),
    #("audio_url", json.string(audio_url)),
    #("title", json.string(title)),
  ]
  |> put_optional("performer", performer, json.string)
  |> put_optional("audio_duration", audio_duration, json.int)
  |> finish_result(caption, reply_markup, input_message_content)
}

pub fn voice(
  id: String,
  voice_url: String,
  title: String,
  voice_duration: Option(Int),
  caption: Option(String),
  reply_markup: Option(json.Json),
  input_message_content: Option(InputMessageContent),
) -> json.Json {
  [
    #("type", json.string("voice")),
    #("id", json.string(id)),
    #("voice_url", json.string(voice_url)),
    #("title", json.string(title)),
  ]
  |> put_optional("voice_duration", voice_duration, json.int)
  |> finish_result(caption, reply_markup, input_message_content)
}

pub fn document(
  id: String,
  title: String,
  document_url: String,
  mime_type: String,
  caption: Option(String),
  description: Option(String),
  reply_markup: Option(json.Json),
  input_message_content: Option(InputMessageContent),
) -> json.Json {
  [
    #("type", json.string("document")),
    #("id", json.string(id)),
    #("title", json.string(title)),
    #("document_url", json.string(document_url)),
    #("mime_type", json.string(mime_type)),
  ]
  |> put_optional("description", description, json.string)
  |> finish_result(caption, reply_markup, input_message_content)
}

pub fn location(
  id: String,
  latitude: Float,
  longitude: Float,
  title: String,
  horizontal_accuracy: Option(Float),
  reply_markup: Option(json.Json),
  input_message_content: Option(InputMessageContent),
) -> json.Json {
  [
    #("type", json.string("location")),
    #("id", json.string(id)),
    #("latitude", json.float(latitude)),
    #("longitude", json.float(longitude)),
    #("title", json.string(title)),
  ]
  |> put_optional("horizontal_accuracy", horizontal_accuracy, json.float)
  |> finish_result(None, reply_markup, input_message_content)
}

pub fn venue(
  id: String,
  latitude: Float,
  longitude: Float,
  title: String,
  address: String,
  reply_markup: Option(json.Json),
  input_message_content: Option(InputMessageContent),
) -> json.Json {
  [
    #("type", json.string("venue")),
    #("id", json.string(id)),
    #("latitude", json.float(latitude)),
    #("longitude", json.float(longitude)),
    #("title", json.string(title)),
    #("address", json.string(address)),
  ]
  |> finish_result(None, reply_markup, input_message_content)
}

pub fn contact(
  id: String,
  phone_number: String,
  first_name: String,
  last_name: Option(String),
  vcard: Option(String),
  reply_markup: Option(json.Json),
  input_message_content: Option(InputMessageContent),
) -> json.Json {
  [
    #("type", json.string("contact")),
    #("id", json.string(id)),
    #("phone_number", json.string(phone_number)),
    #("first_name", json.string(first_name)),
  ]
  |> put_optional("last_name", last_name, json.string)
  |> put_optional("vcard", vcard, json.string)
  |> finish_result(None, reply_markup, input_message_content)
}

pub fn sticker(
  id: String,
  sticker_file_id: String,
  reply_markup: Option(json.Json),
  input_message_content: Option(InputMessageContent),
) -> json.Json {
  [
    #("type", json.string("sticker")),
    #("id", json.string(id)),
    #("sticker_file_id", json.string(sticker_file_id)),
  ]
  |> finish_result(None, reply_markup, input_message_content)
}

pub fn cached_photo(
  id: String,
  photo_file_id: String,
  caption: Option(String),
  reply_markup: Option(json.Json),
) -> json.Json {
  [
    #("type", json.string("photo")),
    #("id", json.string(id)),
    #("photo_file_id", json.string(photo_file_id)),
  ]
  |> finish_result(caption, reply_markup, None)
}

pub fn game(
  id: String,
  game_short_name: String,
  reply_markup: Option(json.Json),
) -> json.Json {
  [
    #("type", json.string("game")),
    #("id", json.string(id)),
    #("game_short_name", json.string(game_short_name)),
  ]
  |> finish_result(None, reply_markup, None)
}

pub fn gif(
  id: String,
  gif_url: String,
  thumbnail_url: String,
  title: Option(String),
  caption: Option(String),
  reply_markup: Option(json.Json),
  input_message_content: Option(InputMessageContent),
) -> json.Json {
  [
    #("type", json.string("gif")),
    #("id", json.string(id)),
    #("gif_url", json.string(gif_url)),
    #("thumbnail_url", json.string(thumbnail_url)),
  ]
  |> put_optional("title", title, json.string)
  |> finish_result(caption, reply_markup, input_message_content)
}

pub fn mpeg4_gif(
  id: String,
  mpeg4_url: String,
  thumbnail_url: String,
  title: Option(String),
  caption: Option(String),
  reply_markup: Option(json.Json),
  input_message_content: Option(InputMessageContent),
) -> json.Json {
  [
    #("type", json.string("mpeg4_gif")),
    #("id", json.string(id)),
    #("mpeg4_url", json.string(mpeg4_url)),
    #("thumbnail_url", json.string(thumbnail_url)),
  ]
  |> put_optional("title", title, json.string)
  |> finish_result(caption, reply_markup, input_message_content)
}

pub fn cached_audio(
  id: String,
  audio_file_id: String,
  caption: Option(String),
  reply_markup: Option(json.Json),
) -> json.Json {
  [
    #("type", json.string("audio")),
    #("id", json.string(id)),
    #("audio_file_id", json.string(audio_file_id)),
  ]
  |> finish_result(caption, reply_markup, None)
}

pub fn cached_document(
  id: String,
  title: String,
  document_file_id: String,
  caption: Option(String),
  reply_markup: Option(json.Json),
) -> json.Json {
  [
    #("type", json.string("document")),
    #("id", json.string(id)),
    #("title", json.string(title)),
    #("document_file_id", json.string(document_file_id)),
  ]
  |> finish_result(caption, reply_markup, None)
}

pub fn cached_video(
  id: String,
  title: String,
  video_file_id: String,
  caption: Option(String),
  reply_markup: Option(json.Json),
) -> json.Json {
  [
    #("type", json.string("video")),
    #("id", json.string(id)),
    #("title", json.string(title)),
    #("video_file_id", json.string(video_file_id)),
  ]
  |> finish_result(caption, reply_markup, None)
}

pub fn cached_voice(
  id: String,
  title: String,
  voice_file_id: String,
  caption: Option(String),
  reply_markup: Option(json.Json),
) -> json.Json {
  [
    #("type", json.string("voice")),
    #("id", json.string(id)),
    #("title", json.string(title)),
    #("voice_file_id", json.string(voice_file_id)),
  ]
  |> finish_result(caption, reply_markup, None)
}

pub fn cached_gif(
  id: String,
  gif_file_id: String,
  caption: Option(String),
  reply_markup: Option(json.Json),
) -> json.Json {
  [
    #("type", json.string("gif")),
    #("id", json.string(id)),
    #("gif_file_id", json.string(gif_file_id)),
  ]
  |> finish_result(caption, reply_markup, None)
}

pub fn cached_mpeg4_gif(
  id: String,
  mpeg4_file_id: String,
  caption: Option(String),
  reply_markup: Option(json.Json),
) -> json.Json {
  [
    #("type", json.string("mpeg4_gif")),
    #("id", json.string(id)),
    #("mpeg4_file_id", json.string(mpeg4_file_id)),
  ]
  |> finish_result(caption, reply_markup, None)
}

pub fn cached_sticker(
  id: String,
  sticker_file_id: String,
  reply_markup: Option(json.Json),
) -> json.Json {
  [
    #("type", json.string("sticker")),
    #("id", json.string(id)),
    #("sticker_file_id", json.string(sticker_file_id)),
  ]
  |> finish_result(None, reply_markup, None)
}

// =====================================================================
//                          Helpers
// =====================================================================

fn finish_result(
  fields: List(#(String, json.Json)),
  caption: Option(String),
  reply_markup: Option(json.Json),
  input: Option(InputMessageContent),
) -> json.Json {
  fields
  |> put_optional("caption", caption, json.string)
  |> put_optional_json("reply_markup", reply_markup)
  |> opt_input_content(input)
  |> json.object
}

fn opt_input_content(
  fields: List(#(String, json.Json)),
  input: Option(InputMessageContent),
) -> List(#(String, json.Json)) {
  case input {
    None -> fields
    Some(c) ->
      list.append(fields, [
        #("input_message_content", input_message_content_to_json(c)),
      ])
  }
}
