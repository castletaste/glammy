//// Builders for the various `InlineQueryResult*` shapes that
//// `answerInlineQuery` accepts. Each builder returns an opaque typed value;
//// only this module can construct its internal JSON representation.

import glammy/https_url.{type HttpsUrl}
import glammy/internal/json_utils
import glammy/keyboard.{type GameInlineKeyboard, type InlineKeyboard}
import glammy/parse_mode.{type ParseMode}
import glammy/types.{type LinkPreviewOptions}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A Telegram inline-query result built by this module.
///
/// The constructor is private so `api.answer_inline_query` cannot receive an
/// arbitrary JSON value by accident.
pub opaque type InlineQueryResult {
  InlineQueryResult(json.Json)
}

/// A Bot API-compatible collection of at most 50 inline-query results.
pub opaque type InlineQueryResults {
  InlineQueryResults(List(InlineQueryResult))
}

/// Why a list could not be used with `answerInlineQuery`.
pub type InlineQueryResultsError {
  TooManyInlineQueryResults(count: Int)
}

/// Validate a list for use with `answerInlineQuery`.
pub fn results(
  items: List(InlineQueryResult),
) -> Result(InlineQueryResults, InlineQueryResultsError) {
  let count = list.length(items)
  case count <= 50 {
    True -> Ok(InlineQueryResults(items))
    False -> Error(TooManyInlineQueryResults(count))
  }
}

/// Unwrap a validated inline-query result collection for transport.
pub fn results_to_list(results: InlineQueryResults) -> List(InlineQueryResult) {
  let InlineQueryResults(items) = results
  items
}

/// Encode a typed inline-query result for transport or inspection.
pub fn to_json(result: InlineQueryResult) -> json.Json {
  let InlineQueryResult(value) = result
  value
}

/// The mutually-exclusive action on an `answerInlineQuery` results button.
pub opaque type InlineQueryResultsButton {
  InlineQueryWebAppButton(text: String, url: HttpsUrl)
  InlineQueryStartButton(text: String, start_parameter: String)
}

/// Why a deep-link start parameter is not accepted by Telegram.
pub type InlineQueryResultsButtonError {
  InvalidStartParameterLength(length: Int)
  InvalidStartParameterCharacter(character: String)
}

/// Build a button that opens a Mini App at a validated HTTPS URL.
pub fn results_web_app_button(
  text: String,
  url: HttpsUrl,
) -> InlineQueryResultsButton {
  InlineQueryWebAppButton(text:, url:)
}

/// Build a validated `t.me/<bot>?start=<parameter>` results button.
pub fn results_start_button(
  text: String,
  start_parameter: String,
) -> Result(InlineQueryResultsButton, InlineQueryResultsButtonError) {
  let characters = string.to_graphemes(start_parameter)
  let length = list.length(characters)
  case length >= 1 && length <= 64 {
    False -> Error(InvalidStartParameterLength(length))
    True -> {
      use _ <- result.try(validate_start_parameter_characters(characters))
      Ok(InlineQueryStartButton(text:, start_parameter:))
    }
  }
}

fn validate_start_parameter_characters(
  characters: List(String),
) -> Result(Nil, InlineQueryResultsButtonError) {
  case characters {
    [] -> Ok(Nil)
    [character, ..rest] ->
      case
        string.contains(
          "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-",
          character,
        )
      {
        True -> validate_start_parameter_characters(rest)
        False -> Error(InvalidStartParameterCharacter(character))
      }
  }
}

/// Encode a results button for `answerInlineQuery`.
pub fn results_button_to_json(button: InlineQueryResultsButton) -> json.Json {
  case button {
    InlineQueryWebAppButton(text:, url:) ->
      json.object([
        #("text", json.string(text)),
        #(
          "web_app",
          json.object([#("url", json.string(https_url.to_string(url)))]),
        ),
      ])
    InlineQueryStartButton(text:, start_parameter:) ->
      json.object([
        #("text", json.string(text)),
        #("start_parameter", json.string(start_parameter)),
      ])
  }
}

/// The two source forms accepted by Telegram for an inline video result.
///
/// HTML players must carry replacement message content. MP4 files may
/// optionally replace the media with message content.
pub type InlineVideoSource {
  Mp4Video(input_message_content: Option(InputMessageContent))
  HtmlVideo(input_message_content: InputMessageContent)
}

/// MIME types accepted by Telegram for non-cached inline documents.
pub type InlineDocumentMimeType {
  PdfDocument
  ZipDocument
}

/// Typed message content that an inline result may send instead of its media.
pub type InputMessageContent {
  /// Text content with typed formatting and link-preview policy.
  InputTextMessageContent(
    message_text: String,
    parse_mode: Option(ParseMode),
    link_preview_options: Option(LinkPreviewOptions),
  )
  /// Location content.
  InputLocationMessageContent(
    latitude: Float,
    longitude: Float,
    horizontal_accuracy: Option(Float),
    live_period: Option(Int),
  )
  /// Venue content.
  InputVenueMessageContent(
    latitude: Float,
    longitude: Float,
    title: String,
    address: String,
  )
  /// Contact content.
  InputContactMessageContent(
    phone_number: String,
    first_name: String,
    last_name: Option(String),
  )
  /// Invoice content.
  InputInvoiceMessageContent(
    title: String,
    description: String,
    payload: String,
    provider_token: Option(String),
    currency: String,
    prices: List(#(String, Int)),
  )
}

/// Render `InputMessageContent` as Telegram JSON.
pub fn input_message_content_to_json(
  content: InputMessageContent,
) -> json.Json {
  case content {
    InputTextMessageContent(message_text:, parse_mode:, link_preview_options:) ->
      json.object(
        [#("message_text", json.string(message_text))]
        |> json_utils.put_optional("parse_mode", parse_mode, fn(mode) {
          json.string(parse_mode.to_string(mode))
        })
        |> json_utils.put_optional(
          "link_preview_options",
          link_preview_options,
          types.link_preview_options_to_json,
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
        |> json_utils.put_optional(
          "horizontal_accuracy",
          horizontal_accuracy,
          json.float,
        )
        |> json_utils.put_optional("live_period", live_period, json.int),
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
        |> json_utils.put_optional("last_name", last_name, json.string),
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
        |> json_utils.put_optional(
          "provider_token",
          provider_token,
          json.string,
        ),
      )
  }
}

// =====================================================================
//                            Result builders
// =====================================================================

/// Build an `InlineQueryResultArticle` value.
pub fn article(
  id: String,
  title: String,
  input_message_content: InputMessageContent,
  description description: Option(String),
  url url: Option(String),
  thumbnail_url thumbnail_url: Option(String),
  reply_markup reply_markup: Option(InlineKeyboard),
) -> InlineQueryResult {
  InlineQueryResult(json.object(
    [
      #("type", json.string("article")),
      #("id", json.string(id)),
      #("title", json.string(title)),
      #(
        "input_message_content",
        input_message_content_to_json(input_message_content),
      ),
    ]
    |> json_utils.put_optional("description", description, json.string)
    |> json_utils.put_optional("url", url, json.string)
    |> json_utils.put_optional("thumbnail_url", thumbnail_url, json.string)
    |> json_utils.put_optional(
      "reply_markup",
      reply_markup,
      keyboard.inline_to_json,
    ),
  ))
}

/// Build an `InlineQueryResultPhoto` value.
pub fn photo(
  id: String,
  photo_url: String,
  thumbnail_url: String,
  caption caption: Option(String),
  title title: Option(String),
  description description: Option(String),
  reply_markup reply_markup: Option(InlineKeyboard),
  input_message_content input_message_content: Option(InputMessageContent),
  parse_mode parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  [
    #("type", json.string("photo")),
    #("id", json.string(id)),
    #("photo_url", json.string(photo_url)),
    #("thumbnail_url", json.string(thumbnail_url)),
  ]
  |> json_utils.put_optional("title", title, json.string)
  |> json_utils.put_optional("description", description, json.string)
  |> finish_result(caption, parse_mode, reply_markup, input_message_content)
}

/// Build an `InlineQueryResultVideo` value.
pub fn video(
  id: String,
  video_url: String,
  source: InlineVideoSource,
  thumbnail_url: String,
  title: String,
  caption caption: Option(String),
  description description: Option(String),
  reply_markup reply_markup: Option(InlineKeyboard),
  parse_mode parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  let #(mime_type, input_message_content) = case source {
    Mp4Video(input_message_content) -> #("video/mp4", input_message_content)
    HtmlVideo(input_message_content) -> #(
      "text/html",
      Some(input_message_content),
    )
  }
  [
    #("type", json.string("video")),
    #("id", json.string(id)),
    #("video_url", json.string(video_url)),
    #("mime_type", json.string(mime_type)),
    #("thumbnail_url", json.string(thumbnail_url)),
    #("title", json.string(title)),
  ]
  |> json_utils.put_optional("description", description, json.string)
  |> finish_result(caption, parse_mode, reply_markup, input_message_content)
}

/// Build an `InlineQueryResultAudio` value.
pub fn audio(
  id: String,
  audio_url: String,
  title: String,
  performer performer: Option(String),
  audio_duration audio_duration: Option(Int),
  caption caption: Option(String),
  reply_markup reply_markup: Option(InlineKeyboard),
  input_message_content input_message_content: Option(InputMessageContent),
  parse_mode parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  [
    #("type", json.string("audio")),
    #("id", json.string(id)),
    #("audio_url", json.string(audio_url)),
    #("title", json.string(title)),
  ]
  |> json_utils.put_optional("performer", performer, json.string)
  |> json_utils.put_optional("audio_duration", audio_duration, json.int)
  |> finish_result(caption, parse_mode, reply_markup, input_message_content)
}

/// Build an `InlineQueryResultVoice` value.
pub fn voice(
  id: String,
  voice_url: String,
  title: String,
  voice_duration voice_duration: Option(Int),
  caption caption: Option(String),
  reply_markup reply_markup: Option(InlineKeyboard),
  input_message_content input_message_content: Option(InputMessageContent),
  parse_mode parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  [
    #("type", json.string("voice")),
    #("id", json.string(id)),
    #("voice_url", json.string(voice_url)),
    #("title", json.string(title)),
  ]
  |> json_utils.put_optional("voice_duration", voice_duration, json.int)
  |> finish_result(caption, parse_mode, reply_markup, input_message_content)
}

/// Build an `InlineQueryResultDocument` value.
pub fn document(
  id: String,
  title: String,
  document_url: String,
  mime_type: InlineDocumentMimeType,
  caption caption: Option(String),
  description description: Option(String),
  reply_markup reply_markup: Option(InlineKeyboard),
  input_message_content input_message_content: Option(InputMessageContent),
  parse_mode parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  let mime_type = case mime_type {
    PdfDocument -> "application/pdf"
    ZipDocument -> "application/zip"
  }
  [
    #("type", json.string("document")),
    #("id", json.string(id)),
    #("title", json.string(title)),
    #("document_url", json.string(document_url)),
    #("mime_type", json.string(mime_type)),
  ]
  |> json_utils.put_optional("description", description, json.string)
  |> finish_result(caption, parse_mode, reply_markup, input_message_content)
}

/// Build an `InlineQueryResultLocation` value.
pub fn location(
  id: String,
  latitude: Float,
  longitude: Float,
  title: String,
  horizontal_accuracy horizontal_accuracy: Option(Float),
  reply_markup reply_markup: Option(InlineKeyboard),
  input_message_content input_message_content: Option(InputMessageContent),
) -> InlineQueryResult {
  [
    #("type", json.string("location")),
    #("id", json.string(id)),
    #("latitude", json.float(latitude)),
    #("longitude", json.float(longitude)),
    #("title", json.string(title)),
  ]
  |> json_utils.put_optional(
    "horizontal_accuracy",
    horizontal_accuracy,
    json.float,
  )
  |> finish_result(None, None, reply_markup, input_message_content)
}

/// Build an `InlineQueryResultVenue` value.
pub fn venue(
  id: String,
  latitude: Float,
  longitude: Float,
  title: String,
  address: String,
  reply_markup reply_markup: Option(InlineKeyboard),
  input_message_content input_message_content: Option(InputMessageContent),
) -> InlineQueryResult {
  [
    #("type", json.string("venue")),
    #("id", json.string(id)),
    #("latitude", json.float(latitude)),
    #("longitude", json.float(longitude)),
    #("title", json.string(title)),
    #("address", json.string(address)),
  ]
  |> finish_result(None, None, reply_markup, input_message_content)
}

/// Build an `InlineQueryResultContact` value.
pub fn contact(
  id: String,
  phone_number: String,
  first_name: String,
  last_name last_name: Option(String),
  vcard vcard: Option(String),
  reply_markup reply_markup: Option(InlineKeyboard),
  input_message_content input_message_content: Option(InputMessageContent),
) -> InlineQueryResult {
  [
    #("type", json.string("contact")),
    #("id", json.string(id)),
    #("phone_number", json.string(phone_number)),
    #("first_name", json.string(first_name)),
  ]
  |> json_utils.put_optional("last_name", last_name, json.string)
  |> json_utils.put_optional("vcard", vcard, json.string)
  |> finish_result(None, None, reply_markup, input_message_content)
}

/// Build an `InlineQueryResultCachedPhoto` value.
pub fn cached_photo(
  id: String,
  photo_file_id: String,
  caption: Option(String),
  reply_markup: Option(InlineKeyboard),
  parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  [
    #("type", json.string("photo")),
    #("id", json.string(id)),
    #("photo_file_id", json.string(photo_file_id)),
  ]
  |> finish_result(caption, parse_mode, reply_markup, None)
}

/// Build an `InlineQueryResultGame` value.
///
/// `None` lets Telegram add its automatic Play button. A custom keyboard uses
/// `GameInlineKeyboard`, which keeps the required game-launch button first.
pub fn game(
  id: String,
  game_short_name: String,
  reply_markup: Option(GameInlineKeyboard),
) -> InlineQueryResult {
  InlineQueryResult(
    [
      #("type", json.string("game")),
      #("id", json.string(id)),
      #("game_short_name", json.string(game_short_name)),
    ]
    |> json_utils.put_optional(
      "reply_markup",
      reply_markup,
      keyboard.game_inline_keyboard_to_json,
    )
    |> json.object,
  )
}

/// Build an `InlineQueryResultGif` value.
pub fn gif(
  id: String,
  gif_url: String,
  thumbnail_url: String,
  title title: Option(String),
  caption caption: Option(String),
  reply_markup reply_markup: Option(InlineKeyboard),
  input_message_content input_message_content: Option(InputMessageContent),
  parse_mode parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  [
    #("type", json.string("gif")),
    #("id", json.string(id)),
    #("gif_url", json.string(gif_url)),
    #("thumbnail_url", json.string(thumbnail_url)),
  ]
  |> json_utils.put_optional("title", title, json.string)
  |> finish_result(caption, parse_mode, reply_markup, input_message_content)
}

/// Build an `InlineQueryResultMpeg4Gif` value.
pub fn mpeg4_gif(
  id: String,
  mpeg4_url: String,
  thumbnail_url: String,
  title title: Option(String),
  caption caption: Option(String),
  reply_markup reply_markup: Option(InlineKeyboard),
  input_message_content input_message_content: Option(InputMessageContent),
  parse_mode parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  [
    #("type", json.string("mpeg4_gif")),
    #("id", json.string(id)),
    #("mpeg4_url", json.string(mpeg4_url)),
    #("thumbnail_url", json.string(thumbnail_url)),
  ]
  |> json_utils.put_optional("title", title, json.string)
  |> finish_result(caption, parse_mode, reply_markup, input_message_content)
}

/// Build an `InlineQueryResultCachedAudio` value.
pub fn cached_audio(
  id: String,
  audio_file_id: String,
  caption: Option(String),
  reply_markup: Option(InlineKeyboard),
  parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  [
    #("type", json.string("audio")),
    #("id", json.string(id)),
    #("audio_file_id", json.string(audio_file_id)),
  ]
  |> finish_result(caption, parse_mode, reply_markup, None)
}

/// Build an `InlineQueryResultCachedDocument` value.
pub fn cached_document(
  id: String,
  title: String,
  document_file_id: String,
  caption: Option(String),
  reply_markup: Option(InlineKeyboard),
  parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  [
    #("type", json.string("document")),
    #("id", json.string(id)),
    #("title", json.string(title)),
    #("document_file_id", json.string(document_file_id)),
  ]
  |> finish_result(caption, parse_mode, reply_markup, None)
}

/// Build an `InlineQueryResultCachedVideo` value.
pub fn cached_video(
  id: String,
  title: String,
  video_file_id: String,
  caption: Option(String),
  reply_markup: Option(InlineKeyboard),
  parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  [
    #("type", json.string("video")),
    #("id", json.string(id)),
    #("title", json.string(title)),
    #("video_file_id", json.string(video_file_id)),
  ]
  |> finish_result(caption, parse_mode, reply_markup, None)
}

/// Build an `InlineQueryResultCachedVoice` value.
pub fn cached_voice(
  id: String,
  title: String,
  voice_file_id: String,
  caption: Option(String),
  reply_markup: Option(InlineKeyboard),
  parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  [
    #("type", json.string("voice")),
    #("id", json.string(id)),
    #("title", json.string(title)),
    #("voice_file_id", json.string(voice_file_id)),
  ]
  |> finish_result(caption, parse_mode, reply_markup, None)
}

/// Build an `InlineQueryResultCachedGif` value.
pub fn cached_gif(
  id: String,
  gif_file_id: String,
  caption: Option(String),
  reply_markup: Option(InlineKeyboard),
  parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  [
    #("type", json.string("gif")),
    #("id", json.string(id)),
    #("gif_file_id", json.string(gif_file_id)),
  ]
  |> finish_result(caption, parse_mode, reply_markup, None)
}

/// Build an `InlineQueryResultCachedMpeg4Gif` value.
pub fn cached_mpeg4_gif(
  id: String,
  mpeg4_file_id: String,
  caption: Option(String),
  reply_markup: Option(InlineKeyboard),
  parse_mode: Option(ParseMode),
) -> InlineQueryResult {
  [
    #("type", json.string("mpeg4_gif")),
    #("id", json.string(id)),
    #("mpeg4_file_id", json.string(mpeg4_file_id)),
  ]
  |> finish_result(caption, parse_mode, reply_markup, None)
}

/// Build an `InlineQueryResultCachedSticker` value.
pub fn cached_sticker(
  id: String,
  sticker_file_id: String,
  reply_markup: Option(InlineKeyboard),
  input_message_content: Option(InputMessageContent),
) -> InlineQueryResult {
  [
    #("type", json.string("sticker")),
    #("id", json.string(id)),
    #("sticker_file_id", json.string(sticker_file_id)),
  ]
  |> finish_result(None, None, reply_markup, input_message_content)
}

// =====================================================================
//                          Helpers
// =====================================================================

fn finish_result(
  fields: List(#(String, json.Json)),
  caption: Option(String),
  parse_mode: Option(ParseMode),
  reply_markup: Option(InlineKeyboard),
  input: Option(InputMessageContent),
) -> InlineQueryResult {
  InlineQueryResult(
    fields
    |> json_utils.put_optional("caption", caption, json.string)
    |> json_utils.put_optional("parse_mode", parse_mode, fn(mode) {
      json.string(parse_mode.to_string(mode))
    })
    |> json_utils.put_optional(
      "reply_markup",
      reply_markup,
      keyboard.inline_to_json,
    )
    |> json_utils.put_optional(
      "input_message_content",
      input,
      input_message_content_to_json,
    )
    |> json.object,
  )
}
