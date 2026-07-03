//// Telegram Bot API client. Ports the ideas from grammY's `src/core/api.ts`,
//// `src/core/client.ts`, and `src/core/payload.ts` into Gleam.
////
//// Every method call goes to `https://api.telegram.org/bot<token>/<method>`.
//// Calls fall into two categories:
////
//// - JSON calls (`call`) — `application/json` body. Used for the
////   majority of methods.
//// - Multipart calls (`call_multipart`) — `multipart/form-data`. Used
////   whenever the request contains an `InputFile` that needs uploading.
////
//// Both go through the same transformer chain (see `with_transformer`),
//// so plugins like rate-limiting, logging, or retry-on-429 can intercept
//// every outgoing request.

import glammy/error.{
  type GlammyError, ApiError, DecodeError as ApiDecodeError, HttpError,
}
import glammy/input_file.{type InputFile}
import glammy/internal/json_utils.{put_optional, put_optional_json}
import glammy/multipart.{type Part, FilePart, TextPart}
import glammy/types.{
  type BotCommand, type CallbackQuery, type ChatInviteLink, type ChatMember,
  type File, type Message, type Poll, type Update, type User, type WebhookInfo,
  ResponseParameters, bot_command_decoder, callback_query_decoder,
  chat_invite_link_decoder, chat_member_decoder, file_decoder, message_decoder,
  poll_decoder, response_parameters_decoder, update_decoder, user_decoder,
  webhook_info_decoder,
}
import gleam/bit_array
import gleam/dynamic/decode.{type Decoder}
import gleam/http.{Post}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// =====================================================================
//                            ChatId / Payload
// =====================================================================

/// A Telegram chat is identified either numerically or by `@username`.
pub type ChatId {
  ChatIntId(Int)
  ChatUsername(String)
}

pub fn chat_id_to_json(id: ChatId) -> json.Json {
  case id {
    ChatIntId(n) -> json.int(n)
    ChatUsername(s) -> json.string(s)
  }
}

pub fn chat_id_to_string(id: ChatId) -> String {
  case id {
    ChatIntId(n) -> int.to_string(n)
    ChatUsername(s) -> s
  }
}

/// `Payload` is the input to a transformer / the HTTP layer. Either a
/// JSON body or a multipart form body.
pub type Payload {
  JsonPayload(fields: List(#(String, json.Json)))
  MultipartPayload(parts: List(Part))
}

// =====================================================================
//                            Transformers
// =====================================================================

/// Low-level call function. Given a method name and a payload, returns
/// the raw response body string (the JSON envelope `{ok, result, …}`).
pub type ApiCallFn =
  fn(String, Payload) -> Result(String, GlammyError)

/// A transformer wraps the next call function. It can short-circuit by
/// returning a fake response or modify the request before delegating.
/// This mirrors grammY's `Transformer` (`src/core/api.ts`).
pub type Transformer =
  fn(ApiCallFn, String, Payload) -> Result(String, GlammyError)

// =====================================================================
//                              Api client
// =====================================================================

pub opaque type Api {
  Api(
    token: String,
    base_url: String,
    timeout_ms: Int,
    transformers: List(Transformer),
  )
}

/// Build a new client. `token` is the bot token from `@BotFather`.
pub fn new(token: String) -> Api {
  Api(
    token:,
    base_url: "https://api.telegram.org",
    timeout_ms: 60_000,
    transformers: [],
  )
}

/// Override the base URL — useful for the local Bot API server or tests.
pub fn with_base_url(api: Api, base_url: String) -> Api {
  Api(..api, base_url:)
}

/// Override the HTTP timeout in milliseconds.
pub fn with_timeout(api: Api, timeout_ms: Int) -> Api {
  Api(..api, timeout_ms:)
}

/// Register a transformer. Transformers are applied in the order
/// registered; the *first* registered transformer is the outermost wrapper.
pub fn with_transformer(api: Api, transformer: Transformer) -> Api {
  Api(..api, transformers: list.append(api.transformers, [transformer]))
}

// =====================================================================
//                          Calling methods
// =====================================================================

/// Call any Bot API method with a JSON body. Returns the decoded value.
pub fn call(
  api: Api,
  method: String,
  fields: List(#(String, json.Json)),
  decoder: Decoder(t),
) -> Result(t, GlammyError) {
  run_call(api, method, JsonPayload(fields:), decoder)
}

/// Call any Bot API method with a multipart body. Use this when at least
/// one field is an `InputFile` that requires uploading.
pub fn call_multipart(
  api: Api,
  method: String,
  parts: List(Part),
  decoder: Decoder(t),
) -> Result(t, GlammyError) {
  run_call(api, method, MultipartPayload(parts:), decoder)
}

fn run_call(
  api: Api,
  method: String,
  payload: Payload,
  decoder: Decoder(t),
) -> Result(t, GlammyError) {
  let chain =
    compose_chain(api.transformers, fn(m, p) { default_http_call(api, m, p) })
  case chain(method, payload) {
    Ok(body) -> decode_envelope(method, body, decoder)
    Error(e) -> Error(e)
  }
}

fn compose_chain(
  transformers: List(Transformer),
  base: ApiCallFn,
) -> ApiCallFn {
  // Apply transformers right-to-left so that the first registered
  // transformer is the OUTERMOST wrapper.
  list.fold_right(transformers, base, fn(next, t) {
    fn(method, payload) { t(next, method, payload) }
  })
}

fn default_http_call(
  api: Api,
  method: String,
  payload: Payload,
) -> Result(String, GlammyError) {
  let url = api.base_url <> "/bot" <> api.token <> "/" <> method
  use base_req <- result.try(
    request.to(url)
    |> result.replace_error(ApiDecodeError(method:, message: "bad URL")),
  )
  let #(body_bits, content_type) = case payload {
    JsonPayload(fields) -> #(
      <<json.to_string(json.object(fields)):utf8>>,
      "application/json",
    )
    MultipartPayload(parts) -> {
      let encoded = multipart.encode(parts)
      #(encoded.body, encoded.content_type)
    }
  }
  let req =
    base_req
    |> request.set_method(Post)
    |> request.set_header("content-type", content_type)
    |> request.set_header("accept", "application/json")
    |> request.set_body(body_bits)

  let config =
    httpc.configure()
    |> httpc.timeout(api.timeout_ms)
    |> httpc.verify_tls(True)

  case httpc.dispatch_bits(config, req) {
    Ok(resp) ->
      bit_array.to_string(resp.body)
      |> result.replace_error(ApiDecodeError(
        method:,
        message: "non-utf8 response body",
      ))
    Error(e) -> Error(HttpError(method:, reason: e))
  }
}

fn decode_envelope(
  method: String,
  body: String,
  decoder: Decoder(t),
) -> Result(t, GlammyError) {
  let envelope_decoder = {
    use ok <- decode.field("ok", decode.bool)
    case ok {
      True -> {
        use payload <- decode.field("result", decoder)
        decode.success(Ok(payload))
      }
      False -> {
        use error_code <- decode.field("error_code", decode.int)
        use description <- decode.field("description", decode.string)
        use parameters <- decode.optional_field(
          "parameters",
          ResponseParameters(migrate_to_chat_id: None, retry_after: None),
          response_parameters_decoder(),
        )
        decode.success(
          Error(ApiError(method:, error_code:, description:, parameters:)),
        )
      }
    }
  }
  case json.parse(body, envelope_decoder) {
    Ok(inner) -> inner
    Error(err) ->
      Error(ApiDecodeError(method:, message: describe_json_error(err)))
  }
}

fn describe_json_error(err: json.DecodeError) -> String {
  case err {
    json.UnexpectedEndOfInput -> "unexpected end of input"
    json.UnexpectedByte(b) -> "unexpected byte " <> b
    json.UnexpectedSequence(s) -> "unexpected sequence " <> s
    json.UnableToDecode(errs) -> {
      let parts =
        list.map(errs, fn(e) {
          "expected "
          <> e.expected
          <> ", found "
          <> e.found
          <> " at ["
          <> string.join(e.path, ", ")
          <> "]"
        })
      "unable to decode: " <> string.join(parts, "; ")
    }
  }
}

// =====================================================================
//                          Common option helpers
// =====================================================================

fn opt_extra(
  extras: List(#(String, String)),
  key: String,
  value: Option(String),
) -> List(#(String, String)) {
  case value {
    None -> extras
    Some(v) -> list.append(extras, [#(key, v)])
  }
}

fn opt_int_extra(
  extras: List(#(String, String)),
  key: String,
  value: Option(Int),
) -> List(#(String, String)) {
  opt_extra(extras, key, option.map(value, int.to_string))
}

fn opt_bool_extra(
  extras: List(#(String, String)),
  key: String,
  value: Option(Bool),
) -> List(#(String, String)) {
  opt_extra(
    extras,
    key,
    option.map(value, fn(v) {
      case v {
        True -> "true"
        False -> "false"
      }
    }),
  )
}

fn file_to_parts(
  parts: List(Part),
  field_name: String,
  attach_name: String,
  file: InputFile,
) -> List(Part) {
  case file {
    input_file.FileId(id) ->
      list.append(parts, [TextPart(name: field_name, value: id)])
    input_file.FileUrl(url) ->
      list.append(parts, [TextPart(name: field_name, value: url)])
    input_file.FileBytes(bytes:, filename:, mime_type:) ->
      list.append(parts, [
        TextPart(name: field_name, value: "attach://" <> attach_name),
        FilePart(
          name: attach_name,
          filename: filename,
          content_type: mime_type,
          body: bytes,
        ),
      ])
    input_file.FilePath(path: _, filename: _, mime_type: _) ->
      // `FilePath` requires the caller to read the bytes first; we don't
      // do disk I/O in this module to keep it deterministic for tests.
      panic as "FilePath InputFile must be converted to FileBytes via input_file.read"
  }
}

// =====================================================================
//                           Read-only methods
// =====================================================================

pub fn get_me(api: Api) -> Result(User, GlammyError) {
  call(api, "getMe", [], user_decoder())
}

pub fn log_out(api: Api) -> Result(Bool, GlammyError) {
  call(api, "logOut", [], decode.bool)
}

pub fn close(api: Api) -> Result(Bool, GlammyError) {
  call(api, "close", [], decode.bool)
}

pub fn get_webhook_info(api: Api) -> Result(WebhookInfo, GlammyError) {
  call(api, "getWebhookInfo", [], webhook_info_decoder())
}

pub fn get_updates(
  api: Api,
  offset offset: Option(Int),
  limit limit: Option(Int),
  timeout timeout: Option(Int),
  allowed_updates allowed_updates: Option(List(String)),
) -> Result(List(Update), GlammyError) {
  let fields =
    []
    |> put_optional("offset", offset, json.int)
    |> put_optional("limit", limit, json.int)
    |> put_optional("timeout", timeout, json.int)
    |> put_optional("allowed_updates", allowed_updates, fn(items) {
      json.array(items, json.string)
    })
  call(api, "getUpdates", fields, decode.list(update_decoder()))
}

pub fn set_webhook(
  api: Api,
  url: String,
  options: SetWebhookOptions,
) -> Result(Bool, GlammyError) {
  let fields =
    [#("url", json.string(url))]
    |> put_optional("ip_address", options.ip_address, json.string)
    |> put_optional("max_connections", options.max_connections, json.int)
    |> put_optional("allowed_updates", options.allowed_updates, fn(xs) {
      json.array(xs, json.string)
    })
    |> put_optional(
      "drop_pending_updates",
      options.drop_pending_updates,
      json.bool,
    )
    |> put_optional("secret_token", options.secret_token, json.string)
  call(api, "setWebhook", fields, decode.bool)
}

pub type SetWebhookOptions {
  SetWebhookOptions(
    ip_address: Option(String),
    max_connections: Option(Int),
    allowed_updates: Option(List(String)),
    drop_pending_updates: Option(Bool),
    secret_token: Option(String),
  )
}

pub fn default_set_webhook_options() -> SetWebhookOptions {
  SetWebhookOptions(
    ip_address: None,
    max_connections: None,
    allowed_updates: None,
    drop_pending_updates: None,
    secret_token: None,
  )
}

pub fn delete_webhook(
  api: Api,
  drop_pending_updates: Option(Bool),
) -> Result(Bool, GlammyError) {
  let fields =
    []
    |> put_optional("drop_pending_updates", drop_pending_updates, json.bool)
  call(api, "deleteWebhook", fields, decode.bool)
}

// =====================================================================
//                         Send & edit messages
// =====================================================================

pub type SendMessageOptions {
  SendMessageOptions(
    parse_mode: Option(String),
    message_thread_id: Option(Int),
    reply_to_message_id: Option(Int),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    disable_web_page_preview: Option(Bool),
    reply_markup: Option(json.Json),
    business_connection_id: Option(String),
  )
}

pub fn default_send_message_options() -> SendMessageOptions {
  SendMessageOptions(
    parse_mode: None,
    message_thread_id: None,
    reply_to_message_id: None,
    disable_notification: None,
    protect_content: None,
    disable_web_page_preview: None,
    reply_markup: None,
    business_connection_id: None,
  )
}

pub fn send_message(
  api: Api,
  chat_id: ChatId,
  text: String,
  options: SendMessageOptions,
) -> Result(Message, GlammyError) {
  let fields =
    [#("chat_id", chat_id_to_json(chat_id)), #("text", json.string(text))]
    |> put_optional("parse_mode", options.parse_mode, json.string)
    |> put_optional("message_thread_id", options.message_thread_id, json.int)
    |> put_optional(
      "reply_to_message_id",
      options.reply_to_message_id,
      json.int,
    )
    |> put_optional(
      "disable_notification",
      options.disable_notification,
      json.bool,
    )
    |> put_optional("protect_content", options.protect_content, json.bool)
    |> put_optional(
      "disable_web_page_preview",
      options.disable_web_page_preview,
      json.bool,
    )
    |> put_optional_json("reply_markup", options.reply_markup)
    |> put_optional(
      "business_connection_id",
      options.business_connection_id,
      json.string,
    )
  call(api, "sendMessage", fields, message_decoder())
}

pub fn forward_message(
  api: Api,
  chat_id: ChatId,
  from_chat_id: ChatId,
  message_id: Int,
) -> Result(Message, GlammyError) {
  call(
    api,
    "forwardMessage",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("from_chat_id", chat_id_to_json(from_chat_id)),
      #("message_id", json.int(message_id)),
    ],
    message_decoder(),
  )
}

pub fn forward_messages(
  api: Api,
  chat_id: ChatId,
  from_chat_id: ChatId,
  message_ids: List(Int),
) -> Result(List(Int), GlammyError) {
  call(
    api,
    "forwardMessages",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("from_chat_id", chat_id_to_json(from_chat_id)),
      #("message_ids", json.array(message_ids, json.int)),
    ],
    decode.list({
      use mid <- decode.field("message_id", decode.int)
      decode.success(mid)
    }),
  )
}

pub fn copy_message(
  api: Api,
  chat_id: ChatId,
  from_chat_id: ChatId,
  message_id: Int,
  caption: Option(String),
) -> Result(Int, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("from_chat_id", chat_id_to_json(from_chat_id)),
      #("message_id", json.int(message_id)),
    ]
    |> put_optional("caption", caption, json.string)
  call(api, "copyMessage", fields, {
    use mid <- decode.field("message_id", decode.int)
    decode.success(mid)
  })
}

pub fn delete_message(
  api: Api,
  chat_id: ChatId,
  message_id: Int,
) -> Result(Bool, GlammyError) {
  call(
    api,
    "deleteMessage",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_id", json.int(message_id)),
    ],
    decode.bool,
  )
}

pub fn delete_messages(
  api: Api,
  chat_id: ChatId,
  message_ids: List(Int),
) -> Result(Bool, GlammyError) {
  call(
    api,
    "deleteMessages",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_ids", json.array(message_ids, json.int)),
    ],
    decode.bool,
  )
}

pub fn edit_message_text(
  api: Api,
  chat_id: ChatId,
  message_id: Int,
  text: String,
  parse_mode: Option(String),
  reply_markup: Option(json.Json),
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_id", json.int(message_id)),
      #("text", json.string(text)),
    ]
    |> put_optional("parse_mode", parse_mode, json.string)
    |> put_optional_json("reply_markup", reply_markup)
  call(api, "editMessageText", fields, message_decoder())
}

pub fn edit_message_caption(
  api: Api,
  chat_id: ChatId,
  message_id: Int,
  caption: String,
  parse_mode: Option(String),
  reply_markup: Option(json.Json),
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_id", json.int(message_id)),
      #("caption", json.string(caption)),
    ]
    |> put_optional("parse_mode", parse_mode, json.string)
    |> put_optional_json("reply_markup", reply_markup)
  call(api, "editMessageCaption", fields, message_decoder())
}

pub fn edit_message_reply_markup(
  api: Api,
  chat_id: ChatId,
  message_id: Int,
  reply_markup: Option(json.Json),
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_id", json.int(message_id)),
    ]
    |> put_optional_json("reply_markup", reply_markup)
  call(api, "editMessageReplyMarkup", fields, message_decoder())
}

pub fn stop_poll(
  api: Api,
  chat_id: ChatId,
  message_id: Int,
) -> Result(Poll, GlammyError) {
  call(
    api,
    "stopPoll",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_id", json.int(message_id)),
    ],
    poll_decoder(),
  )
}

pub fn send_chat_action(
  api: Api,
  chat_id: ChatId,
  action: String,
) -> Result(Bool, GlammyError) {
  call(
    api,
    "sendChatAction",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("action", json.string(action)),
    ],
    decode.bool,
  )
}

// =====================================================================
//                            Send media
// =====================================================================

pub type SendMediaOptions {
  SendMediaOptions(
    caption: Option(String),
    parse_mode: Option(String),
    show_caption_above_media: Option(Bool),
    has_spoiler: Option(Bool),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    reply_to_message_id: Option(Int),
    message_thread_id: Option(Int),
    reply_markup: Option(json.Json),
    business_connection_id: Option(String),
  )
}

pub fn default_send_media_options() -> SendMediaOptions {
  SendMediaOptions(
    caption: None,
    parse_mode: None,
    show_caption_above_media: None,
    has_spoiler: None,
    disable_notification: None,
    protect_content: None,
    reply_to_message_id: None,
    message_thread_id: None,
    reply_markup: None,
    business_connection_id: None,
  )
}

fn send_media_via_multipart(
  api: Api,
  method: String,
  chat_id: ChatId,
  file_field: String,
  file: InputFile,
  options: SendMediaOptions,
  extra_text_parts: List(#(String, String)),
) -> Result(Message, GlammyError) {
  let option_extras =
    []
    |> opt_extra("caption", options.caption)
    |> opt_extra("parse_mode", options.parse_mode)
    |> opt_bool_extra(
      "show_caption_above_media",
      options.show_caption_above_media,
    )
    |> opt_bool_extra("has_spoiler", options.has_spoiler)
    |> opt_bool_extra("disable_notification", options.disable_notification)
    |> opt_bool_extra("protect_content", options.protect_content)
    |> opt_int_extra("reply_to_message_id", options.reply_to_message_id)
    |> opt_int_extra("message_thread_id", options.message_thread_id)
    |> opt_extra(
      "reply_markup",
      option.map(options.reply_markup, json.to_string),
    )
    |> opt_extra("business_connection_id", options.business_connection_id)
  let base_parts = [
    TextPart(name: "chat_id", value: chat_id_to_string(chat_id)),
  ]
  let with_file = file_to_parts(base_parts, file_field, file_field, file)
  let with_options =
    list.fold(
      list.append(extra_text_parts, option_extras),
      with_file,
      fn(parts, pair) {
        list.append(parts, [TextPart(name: pair.0, value: pair.1)])
      },
    )
  call_multipart(api, method, with_options, message_decoder())
}

pub fn send_photo(
  api: Api,
  chat_id: ChatId,
  photo: InputFile,
  options: SendMediaOptions,
) -> Result(Message, GlammyError) {
  send_media_via_multipart(
    api,
    "sendPhoto",
    chat_id,
    "photo",
    photo,
    options,
    [],
  )
}

pub fn send_document(
  api: Api,
  chat_id: ChatId,
  document: InputFile,
  options: SendMediaOptions,
) -> Result(Message, GlammyError) {
  send_media_via_multipart(
    api,
    "sendDocument",
    chat_id,
    "document",
    document,
    options,
    [],
  )
}

pub fn send_video(
  api: Api,
  chat_id: ChatId,
  video: InputFile,
  duration: Option(Int),
  width: Option(Int),
  height: Option(Int),
  options: SendMediaOptions,
) -> Result(Message, GlammyError) {
  let extras =
    []
    |> opt_int_extra("duration", duration)
    |> opt_int_extra("width", width)
    |> opt_int_extra("height", height)
  send_media_via_multipart(
    api,
    "sendVideo",
    chat_id,
    "video",
    video,
    options,
    extras,
  )
}

pub fn send_audio(
  api: Api,
  chat_id: ChatId,
  audio: InputFile,
  duration: Option(Int),
  performer: Option(String),
  title: Option(String),
  options: SendMediaOptions,
) -> Result(Message, GlammyError) {
  let extras =
    []
    |> opt_extra("performer", performer)
    |> opt_extra("title", title)
    |> opt_int_extra("duration", duration)
  send_media_via_multipart(
    api,
    "sendAudio",
    chat_id,
    "audio",
    audio,
    options,
    extras,
  )
}

pub fn send_voice(
  api: Api,
  chat_id: ChatId,
  voice: InputFile,
  duration: Option(Int),
  options: SendMediaOptions,
) -> Result(Message, GlammyError) {
  let extras = opt_int_extra([], "duration", duration)
  send_media_via_multipart(
    api,
    "sendVoice",
    chat_id,
    "voice",
    voice,
    options,
    extras,
  )
}

pub fn send_animation(
  api: Api,
  chat_id: ChatId,
  animation: InputFile,
  duration: Option(Int),
  width: Option(Int),
  height: Option(Int),
  options: SendMediaOptions,
) -> Result(Message, GlammyError) {
  let extras =
    []
    |> opt_int_extra("duration", duration)
    |> opt_int_extra("width", width)
    |> opt_int_extra("height", height)
  send_media_via_multipart(
    api,
    "sendAnimation",
    chat_id,
    "animation",
    animation,
    options,
    extras,
  )
}

pub fn send_video_note(
  api: Api,
  chat_id: ChatId,
  video_note: InputFile,
  duration: Option(Int),
  length: Option(Int),
  options: SendMediaOptions,
) -> Result(Message, GlammyError) {
  let extras =
    []
    |> opt_int_extra("duration", duration)
    |> opt_int_extra("length", length)
  send_media_via_multipart(
    api,
    "sendVideoNote",
    chat_id,
    "video_note",
    video_note,
    options,
    extras,
  )
}

pub fn send_sticker(
  api: Api,
  chat_id: ChatId,
  sticker: InputFile,
  options: SendMediaOptions,
) -> Result(Message, GlammyError) {
  send_media_via_multipart(
    api,
    "sendSticker",
    chat_id,
    "sticker",
    sticker,
    options,
    [],
  )
}

// =====================================================================
//                         Location / Venue / Contact / Poll / Dice
// =====================================================================

pub fn send_location(
  api: Api,
  chat_id: ChatId,
  latitude: Float,
  longitude: Float,
  live_period: Option(Int),
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("latitude", json.float(latitude)),
      #("longitude", json.float(longitude)),
    ]
    |> put_optional("live_period", live_period, json.int)
  call(api, "sendLocation", fields, message_decoder())
}

pub fn send_venue(
  api: Api,
  chat_id: ChatId,
  latitude: Float,
  longitude: Float,
  title: String,
  address: String,
) -> Result(Message, GlammyError) {
  let fields = [
    #("chat_id", chat_id_to_json(chat_id)),
    #("latitude", json.float(latitude)),
    #("longitude", json.float(longitude)),
    #("title", json.string(title)),
    #("address", json.string(address)),
  ]
  call(api, "sendVenue", fields, message_decoder())
}

pub fn send_contact(
  api: Api,
  chat_id: ChatId,
  phone_number: String,
  first_name: String,
  last_name: Option(String),
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("phone_number", json.string(phone_number)),
      #("first_name", json.string(first_name)),
    ]
    |> put_optional("last_name", last_name, json.string)
  call(api, "sendContact", fields, message_decoder())
}

pub fn send_dice(
  api: Api,
  chat_id: ChatId,
  emoji: Option(String),
) -> Result(Message, GlammyError) {
  let fields =
    [#("chat_id", chat_id_to_json(chat_id))]
    |> put_optional("emoji", emoji, json.string)
  call(api, "sendDice", fields, message_decoder())
}

pub type SendPollOptions {
  SendPollOptions(
    is_anonymous: Option(Bool),
    type_: Option(String),
    allows_multiple_answers: Option(Bool),
    correct_option_id: Option(Int),
    explanation: Option(String),
    open_period: Option(Int),
    close_date: Option(Int),
    is_closed: Option(Bool),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    reply_to_message_id: Option(Int),
  )
}

pub fn default_send_poll_options() -> SendPollOptions {
  SendPollOptions(
    is_anonymous: None,
    type_: None,
    allows_multiple_answers: None,
    correct_option_id: None,
    explanation: None,
    open_period: None,
    close_date: None,
    is_closed: None,
    disable_notification: None,
    protect_content: None,
    reply_to_message_id: None,
  )
}

pub fn send_poll(
  api: Api,
  chat_id: ChatId,
  question: String,
  options: List(String),
  opts: SendPollOptions,
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("question", json.string(question)),
      #(
        "options",
        json.array(options, fn(o) { json.object([#("text", json.string(o))]) }),
      ),
    ]
    |> put_optional("is_anonymous", opts.is_anonymous, json.bool)
    |> put_optional("type", opts.type_, json.string)
    |> put_optional(
      "allows_multiple_answers",
      opts.allows_multiple_answers,
      json.bool,
    )
    |> put_optional("correct_option_id", opts.correct_option_id, json.int)
    |> put_optional("explanation", opts.explanation, json.string)
    |> put_optional("open_period", opts.open_period, json.int)
    |> put_optional("close_date", opts.close_date, json.int)
    |> put_optional("is_closed", opts.is_closed, json.bool)
    |> put_optional(
      "disable_notification",
      opts.disable_notification,
      json.bool,
    )
    |> put_optional("protect_content", opts.protect_content, json.bool)
    |> put_optional("reply_to_message_id", opts.reply_to_message_id, json.int)
  call(api, "sendPoll", fields, message_decoder())
}

// =====================================================================
//                          answer*  helpers
// =====================================================================

pub type AnswerCallbackQueryOptions {
  AnswerCallbackQueryOptions(
    text: Option(String),
    show_alert: Option(Bool),
    url: Option(String),
    cache_time: Option(Int),
  )
}

pub fn default_answer_callback_query_options() -> AnswerCallbackQueryOptions {
  AnswerCallbackQueryOptions(
    text: None,
    show_alert: None,
    url: None,
    cache_time: None,
  )
}

pub fn answer_callback_query(
  api: Api,
  callback_query_id: String,
  options: AnswerCallbackQueryOptions,
) -> Result(Bool, GlammyError) {
  let fields =
    [#("callback_query_id", json.string(callback_query_id))]
    |> put_optional("text", options.text, json.string)
    |> put_optional("show_alert", options.show_alert, json.bool)
    |> put_optional("url", options.url, json.string)
    |> put_optional("cache_time", options.cache_time, json.int)
  call(api, "answerCallbackQuery", fields, decode.bool)
}

pub fn answer_inline_query(
  api: Api,
  inline_query_id: String,
  results: List(json.Json),
  cache_time: Option(Int),
  is_personal: Option(Bool),
  next_offset: Option(String),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("inline_query_id", json.string(inline_query_id)),
      #("results", json.preprocessed_array(results)),
    ]
    |> put_optional("cache_time", cache_time, json.int)
    |> put_optional("is_personal", is_personal, json.bool)
    |> put_optional("next_offset", next_offset, json.string)
  call(api, "answerInlineQuery", fields, decode.bool)
}

pub fn answer_shipping_query(
  api: Api,
  shipping_query_id: String,
  ok: Bool,
  shipping_options: Option(json.Json),
  error_message: Option(String),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("shipping_query_id", json.string(shipping_query_id)),
      #("ok", json.bool(ok)),
    ]
    |> put_optional_json("shipping_options", shipping_options)
    |> put_optional("error_message", error_message, json.string)
  call(api, "answerShippingQuery", fields, decode.bool)
}

pub fn answer_pre_checkout_query(
  api: Api,
  pre_checkout_query_id: String,
  ok: Bool,
  error_message: Option(String),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("pre_checkout_query_id", json.string(pre_checkout_query_id)),
      #("ok", json.bool(ok)),
    ]
    |> put_optional("error_message", error_message, json.string)
  call(api, "answerPreCheckoutQuery", fields, decode.bool)
}

// =====================================================================
//                       Chat management
// =====================================================================

pub fn ban_chat_member(
  api: Api,
  chat_id: ChatId,
  user_id: Int,
  until_date: Option(Int),
  revoke_messages: Option(Bool),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("user_id", json.int(user_id)),
    ]
    |> put_optional("until_date", until_date, json.int)
    |> put_optional("revoke_messages", revoke_messages, json.bool)
  call(api, "banChatMember", fields, decode.bool)
}

pub fn unban_chat_member(
  api: Api,
  chat_id: ChatId,
  user_id: Int,
  only_if_banned: Option(Bool),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("user_id", json.int(user_id)),
    ]
    |> put_optional("only_if_banned", only_if_banned, json.bool)
  call(api, "unbanChatMember", fields, decode.bool)
}

pub fn restrict_chat_member(
  api: Api,
  chat_id: ChatId,
  user_id: Int,
  permissions: json.Json,
  until_date: Option(Int),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("user_id", json.int(user_id)),
      #("permissions", permissions),
    ]
    |> put_optional("until_date", until_date, json.int)
  call(api, "restrictChatMember", fields, decode.bool)
}

pub fn promote_chat_member(
  api: Api,
  chat_id: ChatId,
  user_id: Int,
  rights: PromoteRights,
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("user_id", json.int(user_id)),
    ]
    |> put_optional("is_anonymous", rights.is_anonymous, json.bool)
    |> put_optional("can_manage_chat", rights.can_manage_chat, json.bool)
    |> put_optional(
      "can_delete_messages",
      rights.can_delete_messages,
      json.bool,
    )
    |> put_optional(
      "can_manage_video_chats",
      rights.can_manage_video_chats,
      json.bool,
    )
    |> put_optional(
      "can_restrict_members",
      rights.can_restrict_members,
      json.bool,
    )
    |> put_optional(
      "can_promote_members",
      rights.can_promote_members,
      json.bool,
    )
    |> put_optional("can_change_info", rights.can_change_info, json.bool)
    |> put_optional("can_invite_users", rights.can_invite_users, json.bool)
    |> put_optional("can_post_messages", rights.can_post_messages, json.bool)
    |> put_optional("can_edit_messages", rights.can_edit_messages, json.bool)
    |> put_optional("can_pin_messages", rights.can_pin_messages, json.bool)
    |> put_optional("can_post_stories", rights.can_post_stories, json.bool)
    |> put_optional("can_edit_stories", rights.can_edit_stories, json.bool)
    |> put_optional("can_delete_stories", rights.can_delete_stories, json.bool)
    |> put_optional("can_manage_topics", rights.can_manage_topics, json.bool)
  call(api, "promoteChatMember", fields, decode.bool)
}

pub type PromoteRights {
  PromoteRights(
    is_anonymous: Option(Bool),
    can_manage_chat: Option(Bool),
    can_delete_messages: Option(Bool),
    can_manage_video_chats: Option(Bool),
    can_restrict_members: Option(Bool),
    can_promote_members: Option(Bool),
    can_change_info: Option(Bool),
    can_invite_users: Option(Bool),
    can_post_messages: Option(Bool),
    can_edit_messages: Option(Bool),
    can_pin_messages: Option(Bool),
    can_post_stories: Option(Bool),
    can_edit_stories: Option(Bool),
    can_delete_stories: Option(Bool),
    can_manage_topics: Option(Bool),
  )
}

pub fn default_promote_rights() -> PromoteRights {
  PromoteRights(
    is_anonymous: None,
    can_manage_chat: None,
    can_delete_messages: None,
    can_manage_video_chats: None,
    can_restrict_members: None,
    can_promote_members: None,
    can_change_info: None,
    can_invite_users: None,
    can_post_messages: None,
    can_edit_messages: None,
    can_pin_messages: None,
    can_post_stories: None,
    can_edit_stories: None,
    can_delete_stories: None,
    can_manage_topics: None,
  )
}

pub fn set_chat_administrator_custom_title(
  api: Api,
  chat_id: ChatId,
  user_id: Int,
  custom_title: String,
) -> Result(Bool, GlammyError) {
  call(
    api,
    "setChatAdministratorCustomTitle",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("user_id", json.int(user_id)),
      #("custom_title", json.string(custom_title)),
    ],
    decode.bool,
  )
}

pub fn set_chat_permissions(
  api: Api,
  chat_id: ChatId,
  permissions: json.Json,
) -> Result(Bool, GlammyError) {
  call(
    api,
    "setChatPermissions",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("permissions", permissions),
    ],
    decode.bool,
  )
}

pub fn export_chat_invite_link(
  api: Api,
  chat_id: ChatId,
) -> Result(String, GlammyError) {
  call(
    api,
    "exportChatInviteLink",
    [#("chat_id", chat_id_to_json(chat_id))],
    decode.string,
  )
}

pub fn create_chat_invite_link(
  api: Api,
  chat_id: ChatId,
  name: Option(String),
  expire_date: Option(Int),
  member_limit: Option(Int),
  creates_join_request: Option(Bool),
) -> Result(ChatInviteLink, GlammyError) {
  let fields =
    [#("chat_id", chat_id_to_json(chat_id))]
    |> put_optional("name", name, json.string)
    |> put_optional("expire_date", expire_date, json.int)
    |> put_optional("member_limit", member_limit, json.int)
    |> put_optional("creates_join_request", creates_join_request, json.bool)
  call(api, "createChatInviteLink", fields, chat_invite_link_decoder())
}

pub fn edit_chat_invite_link(
  api: Api,
  chat_id: ChatId,
  invite_link: String,
  name: Option(String),
  expire_date: Option(Int),
  member_limit: Option(Int),
  creates_join_request: Option(Bool),
) -> Result(ChatInviteLink, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("invite_link", json.string(invite_link)),
    ]
    |> put_optional("name", name, json.string)
    |> put_optional("expire_date", expire_date, json.int)
    |> put_optional("member_limit", member_limit, json.int)
    |> put_optional("creates_join_request", creates_join_request, json.bool)
  call(api, "editChatInviteLink", fields, chat_invite_link_decoder())
}

pub fn revoke_chat_invite_link(
  api: Api,
  chat_id: ChatId,
  invite_link: String,
) -> Result(ChatInviteLink, GlammyError) {
  call(
    api,
    "revokeChatInviteLink",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("invite_link", json.string(invite_link)),
    ],
    chat_invite_link_decoder(),
  )
}

fn chat_join_request_action(
  api: Api,
  method: String,
  chat_id: ChatId,
  user_id: Int,
) -> Result(Bool, GlammyError) {
  call(
    api,
    method,
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("user_id", json.int(user_id)),
    ],
    decode.bool,
  )
}

pub fn approve_chat_join_request(
  api: Api,
  chat_id: ChatId,
  user_id: Int,
) -> Result(Bool, GlammyError) {
  chat_join_request_action(api, "approveChatJoinRequest", chat_id, user_id)
}

pub fn decline_chat_join_request(
  api: Api,
  chat_id: ChatId,
  user_id: Int,
) -> Result(Bool, GlammyError) {
  chat_join_request_action(api, "declineChatJoinRequest", chat_id, user_id)
}

pub fn set_chat_title(
  api: Api,
  chat_id: ChatId,
  title: String,
) -> Result(Bool, GlammyError) {
  call(
    api,
    "setChatTitle",
    [#("chat_id", chat_id_to_json(chat_id)), #("title", json.string(title))],
    decode.bool,
  )
}

pub fn set_chat_description(
  api: Api,
  chat_id: ChatId,
  description: String,
) -> Result(Bool, GlammyError) {
  call(
    api,
    "setChatDescription",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("description", json.string(description)),
    ],
    decode.bool,
  )
}

pub fn pin_chat_message(
  api: Api,
  chat_id: ChatId,
  message_id: Int,
  disable_notification: Option(Bool),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_id", json.int(message_id)),
    ]
    |> put_optional("disable_notification", disable_notification, json.bool)
  call(api, "pinChatMessage", fields, decode.bool)
}

pub fn unpin_chat_message(
  api: Api,
  chat_id: ChatId,
  message_id: Option(Int),
) -> Result(Bool, GlammyError) {
  let fields =
    [#("chat_id", chat_id_to_json(chat_id))]
    |> put_optional("message_id", message_id, json.int)
  call(api, "unpinChatMessage", fields, decode.bool)
}

pub fn unpin_all_chat_messages(
  api: Api,
  chat_id: ChatId,
) -> Result(Bool, GlammyError) {
  call(
    api,
    "unpinAllChatMessages",
    [#("chat_id", chat_id_to_json(chat_id))],
    decode.bool,
  )
}

pub fn leave_chat(api: Api, chat_id: ChatId) -> Result(Bool, GlammyError) {
  call(api, "leaveChat", [#("chat_id", chat_id_to_json(chat_id))], decode.bool)
}

pub fn get_chat_member(
  api: Api,
  chat_id: ChatId,
  user_id: Int,
) -> Result(ChatMember, GlammyError) {
  call(
    api,
    "getChatMember",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("user_id", json.int(user_id)),
    ],
    chat_member_decoder(),
  )
}

pub fn get_chat_administrators(
  api: Api,
  chat_id: ChatId,
) -> Result(List(ChatMember), GlammyError) {
  call(
    api,
    "getChatAdministrators",
    [#("chat_id", chat_id_to_json(chat_id))],
    decode.list(chat_member_decoder()),
  )
}

pub fn get_chat_member_count(
  api: Api,
  chat_id: ChatId,
) -> Result(Int, GlammyError) {
  call(
    api,
    "getChatMemberCount",
    [#("chat_id", chat_id_to_json(chat_id))],
    decode.int,
  )
}

// =====================================================================
//                              Files
// =====================================================================

pub fn get_file(api: Api, file_id: String) -> Result(File, GlammyError) {
  call(api, "getFile", [#("file_id", json.string(file_id))], file_decoder())
}

// =====================================================================
//                       MyCommands / My* settings
// =====================================================================

fn scope_language_fields(
  scope: Option(json.Json),
  language_code: Option(String),
) -> List(#(String, json.Json)) {
  []
  |> put_optional_json("scope", scope)
  |> put_optional("language_code", language_code, json.string)
}

fn set_my_string(
  api: Api,
  method: String,
  key: String,
  value: Option(String),
  language_code: Option(String),
) -> Result(Bool, GlammyError) {
  let fields =
    []
    |> put_optional(key, value, json.string)
    |> put_optional("language_code", language_code, json.string)
  call(api, method, fields, decode.bool)
}

pub fn set_my_commands(
  api: Api,
  commands: List(#(String, String)),
  scope: Option(json.Json),
  language_code: Option(String),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #(
        "commands",
        json.array(commands, fn(c) {
          json.object([
            #("command", json.string(c.0)),
            #("description", json.string(c.1)),
          ])
        }),
      ),
    ]
    |> list.append(scope_language_fields(scope, language_code), _)
  call(api, "setMyCommands", fields, decode.bool)
}

pub fn get_my_commands(
  api: Api,
  scope: Option(json.Json),
  language_code: Option(String),
) -> Result(List(BotCommand), GlammyError) {
  call(
    api,
    "getMyCommands",
    scope_language_fields(scope, language_code),
    decode.list(bot_command_decoder()),
  )
}

pub fn delete_my_commands(
  api: Api,
  scope: Option(json.Json),
  language_code: Option(String),
) -> Result(Bool, GlammyError) {
  call(
    api,
    "deleteMyCommands",
    scope_language_fields(scope, language_code),
    decode.bool,
  )
}

pub fn set_my_name(
  api: Api,
  name: Option(String),
  language_code: Option(String),
) -> Result(Bool, GlammyError) {
  set_my_string(api, "setMyName", "name", name, language_code)
}

pub fn set_my_description(
  api: Api,
  description: Option(String),
  language_code: Option(String),
) -> Result(Bool, GlammyError) {
  set_my_string(
    api,
    "setMyDescription",
    "description",
    description,
    language_code,
  )
}

pub fn set_my_short_description(
  api: Api,
  short_description: Option(String),
  language_code: Option(String),
) -> Result(Bool, GlammyError) {
  set_my_string(
    api,
    "setMyShortDescription",
    "short_description",
    short_description,
    language_code,
  )
}

// =====================================================================
//                       Forum topics
// =====================================================================

pub type ForumTopic {
  ForumTopic(
    message_thread_id: Int,
    name: String,
    icon_color: Int,
    icon_custom_emoji_id: Option(String),
  )
}

pub fn forum_topic_decoder() -> Decoder(ForumTopic) {
  use message_thread_id <- decode.field("message_thread_id", decode.int)
  use name <- decode.field("name", decode.string)
  use icon_color <- decode.field("icon_color", decode.int)
  use icon_custom_emoji_id <- decode.optional_field(
    "icon_custom_emoji_id",
    None,
    decode.optional(decode.string),
  )
  decode.success(ForumTopic(
    message_thread_id:,
    name:,
    icon_color:,
    icon_custom_emoji_id:,
  ))
}

pub fn create_forum_topic(
  api: Api,
  chat_id: ChatId,
  name: String,
  icon_color: Option(Int),
  icon_custom_emoji_id: Option(String),
) -> Result(ForumTopic, GlammyError) {
  let fields =
    [#("chat_id", chat_id_to_json(chat_id)), #("name", json.string(name))]
    |> put_optional("icon_color", icon_color, json.int)
    |> put_optional("icon_custom_emoji_id", icon_custom_emoji_id, json.string)
  call(api, "createForumTopic", fields, forum_topic_decoder())
}

pub fn edit_forum_topic(
  api: Api,
  chat_id: ChatId,
  message_thread_id: Int,
  name: Option(String),
  icon_custom_emoji_id: Option(String),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_thread_id", json.int(message_thread_id)),
    ]
    |> put_optional("name", name, json.string)
    |> put_optional("icon_custom_emoji_id", icon_custom_emoji_id, json.string)
  call(api, "editForumTopic", fields, decode.bool)
}

fn forum_topic_action(
  api: Api,
  method: String,
  chat_id: ChatId,
  message_thread_id: Int,
) -> Result(Bool, GlammyError) {
  call(
    api,
    method,
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_thread_id", json.int(message_thread_id)),
    ],
    decode.bool,
  )
}

pub fn close_forum_topic(
  api: Api,
  chat_id: ChatId,
  message_thread_id: Int,
) -> Result(Bool, GlammyError) {
  forum_topic_action(api, "closeForumTopic", chat_id, message_thread_id)
}

pub fn reopen_forum_topic(
  api: Api,
  chat_id: ChatId,
  message_thread_id: Int,
) -> Result(Bool, GlammyError) {
  forum_topic_action(api, "reopenForumTopic", chat_id, message_thread_id)
}

pub fn delete_forum_topic(
  api: Api,
  chat_id: ChatId,
  message_thread_id: Int,
) -> Result(Bool, GlammyError) {
  forum_topic_action(api, "deleteForumTopic", chat_id, message_thread_id)
}

pub fn unpin_all_forum_topic_messages(
  api: Api,
  chat_id: ChatId,
  message_thread_id: Int,
) -> Result(Bool, GlammyError) {
  forum_topic_action(
    api,
    "unpinAllForumTopicMessages",
    chat_id,
    message_thread_id,
  )
}

// =====================================================================
//                              Reactions
// =====================================================================

pub fn set_message_reaction(
  api: Api,
  chat_id: ChatId,
  message_id: Int,
  reaction: Option(List(json.Json)),
  is_big: Option(Bool),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_id", json.int(message_id)),
    ]
    |> put_optional("reaction", reaction, fn(items) {
      json.preprocessed_array(items)
    })
    |> put_optional("is_big", is_big, json.bool)
  call(api, "setMessageReaction", fields, decode.bool)
}

// =====================================================================
//                              Payments
// =====================================================================

pub type SendInvoiceOptions {
  SendInvoiceOptions(
    title: String,
    description: String,
    payload: String,
    provider_token: Option(String),
    currency: String,
    prices: List(#(String, Int)),
    max_tip_amount: Option(Int),
    suggested_tip_amounts: Option(List(Int)),
    start_parameter: Option(String),
    provider_data: Option(String),
    photo_url: Option(String),
    photo_size: Option(Int),
    photo_width: Option(Int),
    photo_height: Option(Int),
    need_name: Option(Bool),
    need_phone_number: Option(Bool),
    need_email: Option(Bool),
    need_shipping_address: Option(Bool),
    send_phone_number_to_provider: Option(Bool),
    send_email_to_provider: Option(Bool),
    is_flexible: Option(Bool),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    reply_to_message_id: Option(Int),
    reply_markup: Option(json.Json),
  )
}

pub fn send_invoice(
  api: Api,
  chat_id: ChatId,
  invoice: SendInvoiceOptions,
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("title", json.string(invoice.title)),
      #("description", json.string(invoice.description)),
      #("payload", json.string(invoice.payload)),
      #("currency", json.string(invoice.currency)),
      #(
        "prices",
        json.array(invoice.prices, fn(p) {
          json.object([
            #("label", json.string(p.0)),
            #("amount", json.int(p.1)),
          ])
        }),
      ),
    ]
    |> put_optional("provider_token", invoice.provider_token, json.string)
    |> put_optional("max_tip_amount", invoice.max_tip_amount, json.int)
    |> put_optional(
      "suggested_tip_amounts",
      invoice.suggested_tip_amounts,
      fn(xs) { json.array(xs, json.int) },
    )
    |> put_optional("start_parameter", invoice.start_parameter, json.string)
    |> put_optional("provider_data", invoice.provider_data, json.string)
    |> put_optional("photo_url", invoice.photo_url, json.string)
    |> put_optional("photo_size", invoice.photo_size, json.int)
    |> put_optional("photo_width", invoice.photo_width, json.int)
    |> put_optional("photo_height", invoice.photo_height, json.int)
    |> put_optional("need_name", invoice.need_name, json.bool)
    |> put_optional("need_phone_number", invoice.need_phone_number, json.bool)
    |> put_optional("need_email", invoice.need_email, json.bool)
    |> put_optional(
      "need_shipping_address",
      invoice.need_shipping_address,
      json.bool,
    )
    |> put_optional(
      "send_phone_number_to_provider",
      invoice.send_phone_number_to_provider,
      json.bool,
    )
    |> put_optional(
      "send_email_to_provider",
      invoice.send_email_to_provider,
      json.bool,
    )
    |> put_optional("is_flexible", invoice.is_flexible, json.bool)
    |> put_optional(
      "disable_notification",
      invoice.disable_notification,
      json.bool,
    )
    |> put_optional("protect_content", invoice.protect_content, json.bool)
    |> put_optional(
      "reply_to_message_id",
      invoice.reply_to_message_id,
      json.int,
    )
    |> put_optional_json("reply_markup", invoice.reply_markup)
  call(api, "sendInvoice", fields, message_decoder())
}

pub fn refund_star_payment(
  api: Api,
  user_id: Int,
  telegram_payment_charge_id: String,
) -> Result(Bool, GlammyError) {
  call(
    api,
    "refundStarPayment",
    [
      #("user_id", json.int(user_id)),
      #("telegram_payment_charge_id", json.string(telegram_payment_charge_id)),
    ],
    decode.bool,
  )
}

// =====================================================================
//                              Games
// =====================================================================

pub fn send_game(
  api: Api,
  chat_id: ChatId,
  game_short_name: String,
) -> Result(Message, GlammyError) {
  call(
    api,
    "sendGame",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("game_short_name", json.string(game_short_name)),
    ],
    message_decoder(),
  )
}

pub fn set_game_score(
  api: Api,
  user_id: Int,
  score: Int,
  chat_id: Option(Int),
  message_id: Option(Int),
  inline_message_id: Option(String),
  force: Option(Bool),
  disable_edit_message: Option(Bool),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("user_id", json.int(user_id)),
      #("score", json.int(score)),
    ]
    |> put_optional("chat_id", chat_id, json.int)
    |> put_optional("message_id", message_id, json.int)
    |> put_optional("inline_message_id", inline_message_id, json.string)
    |> put_optional("force", force, json.bool)
    |> put_optional("disable_edit_message", disable_edit_message, json.bool)
  call(api, "setGameScore", fields, decode.bool)
}

// =====================================================================
//                       Webhook helper (parsing)
// =====================================================================

fn parse_with(body: String, decoder: Decoder(t)) -> Result(t, String) {
  json.parse(body, decoder)
  |> result.map_error(describe_json_error)
}

pub fn parse_update(body: String) -> Result(Update, String) {
  parse_with(body, update_decoder())
}

pub fn parse_callback_query(body: String) -> Result(CallbackQuery, String) {
  parse_with(body, callback_query_decoder())
}
