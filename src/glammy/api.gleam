//// Telegram Bot API client. Ports the ideas from grammY's `src/core/api.ts`,
//// `src/core/client.ts`, and `src/core/payload.ts` into Gleam.
////
//// Built-in execution sends methods to
//// `https://api.telegram.org/bot<token>/<method>`. Calls fall into two
//// categories:
////
//// - JSON calls (`call`) — `application/json` body. Used for the
////   majority of methods.
//// - Multipart calls (`call_multipart`) — `multipart/form-data`. Used
////   whenever the request contains an `InputFile` that needs uploading.
////
//// Both go through the same transformer chain (see `with_transformer`) when
//// using `execute`, `call`, or the typed wrappers. Applications can instead
//// use `prepare_json_call` / `prepare_multipart_call`, `to_http_request`, and
//// `from_http_response` to own HTTP dispatch completely.

import glammy/chat_action.{type ChatAction}
import glammy/error.{
  type GlammyError, ApiError, DecodeError as ApiDecodeError, HttpError,
}
import glammy/https_url.{type HttpsUrl}
import glammy/inline_query_results.{
  type InlineQueryResult, type InlineQueryResults, type InlineQueryResultsButton,
}
import glammy/input_file.{type FileIdOrUpload, type InputFile}
import glammy/input_media.{type MediaGroup, type ReuseOnlyInputMedia}
import glammy/internal/clock
import glammy/internal/http_response
import glammy/internal/json_utils
import glammy/keyboard.{
  type GameInlineKeyboard, type InlineKeyboard, type InvoiceInlineKeyboard,
  type ReplyMarkup,
}
import glammy/media_options.{
  type SendAnimationOptions, type SendAudioOptions, type SendDocumentOptions,
  type SendPhotoOptions, type SendStickerOptions, type SendVideoNoteOptions,
  type SendVideoOptions, type SendVoiceOptions,
}
import glammy/message_options.{type MessageDelivery, type ReplyParameters}
import glammy/multipart.{type Part, FilePart, TextPart}
import glammy/parse_mode.{type ParseMode}
import glammy/reaction.{type ReactionChange}
import glammy/thumbnail.{type Thumbnail}
import glammy/types.{
  type BotCommand, type BotCommandScope, type BotCommands, type CallbackQuery,
  type ChatInviteLink, type ChatMember, type ChatPermissions, type File,
  type InputPollOptions, type LinkPreviewOptions, type Message, type Poll,
  type PollQuestion, type SentGuestMessage, type Update, type User,
  type WebhookInfo, ResponseParameters,
}
import glammy/webhook_secret.{type WebhookSecret}
import gleam/dynamic/decode.{type Decoder}
import gleam/http.{Post}
import gleam/http/request
import gleam/http/response
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

/// Encode a `ChatId` as JSON for Bot API payloads.
pub fn chat_id_to_json(id: ChatId) -> json.Json {
  case id {
    ChatIntId(n) -> json.int(n)
    ChatUsername(s) -> json.string(s)
  }
}

/// Render a `ChatId` as the string form used in multipart fields.
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

// Keep the token behind a closure so generic runtime inspection renders a
// function reference rather than the captured secret. `to_http_request` is the
// intentional reveal boundary because Telegram requires the token in its URL.
type Secret {
  Secret(reveal: fn() -> String)
}

/// A configured Telegram Bot API client.
///
/// The bot token remains hidden until a request is materialised at the
/// transport boundary.
pub opaque type Api {
  Api(
    token: Secret,
    base_url: String,
    timeout_ms: Int,
    transformers: List(Transformer),
  )
}

/// Invalid local API client configuration.
pub type ApiConfigError {
  /// The HTTP timeout must be strictly positive.
  NonPositiveTimeout(Int)
  /// The HTTP timeout exceeds the largest finite BEAM timer value.
  TimeoutTooLarge(Int)
}

/// Build a new client. `token` is the bot token from `@BotFather`.
pub fn new(token: String) -> Api {
  Api(
    token: Secret(fn() { token }),
    base_url: "https://api.telegram.org",
    timeout_ms: 60_000,
    transformers: [],
  )
}

/// Override the base URL — useful for the local Bot API server or tests.
pub fn with_base_url(api: Api, base_url: String) -> Api {
  Api(..api, base_url:)
}

/// Override the HTTP timeout with a BEAM-safe positive millisecond value.
pub fn with_timeout(api: Api, timeout_ms: Int) -> Result(Api, ApiConfigError) {
  case timeout_ms > 0, timeout_ms <= clock.max_process_timeout_ms {
    False, _ -> Error(NonPositiveTimeout(timeout_ms))
    True, False -> Error(TimeoutTooLarge(timeout_ms))
    True, True -> Ok(Api(..api, timeout_ms:))
  }
}

/// Register a transformer. Transformers are applied in the order
/// registered; the *first* registered transformer is the outermost wrapper.
pub fn with_transformer(api: Api, transformer: Transformer) -> Api {
  Api(..api, transformers: list.append(api.transformers, [transformer]))
}

/// Register a transformer ahead of every existing transformer.
///
/// This is useful for infrastructure interceptors such as durable replay,
/// tracing, or circuit breakers that must observe calls before user plugins.
pub fn with_outermost_transformer(api: Api, transformer: Transformer) -> Api {
  Api(..api, transformers: [transformer, ..api.transformers])
}

// =====================================================================
//                          Calling methods
// =====================================================================

/// A Bot API call whose response decoder travels with its method and payload.
///
/// The value deliberately does not contain the bot token. Convert it to a
/// standard `gleam/http` request only at the transport boundary with
/// `to_http_request`. This lets applications use any HTTP client while keeping
/// response decoding tied to the call that produced the request.
pub opaque type PreparedCall(value) {
  PreparedCall(method: String, payload: Payload, decoder: Decoder(value))
}

/// Prepare a JSON Bot API call without performing I/O.
pub fn prepare_json_call(
  method: String,
  fields: List(#(String, json.Json)),
  decoder: Decoder(value),
) -> PreparedCall(value) {
  PreparedCall(method:, payload: JsonPayload(fields:), decoder:)
}

/// Prepare a multipart Bot API call without performing I/O.
pub fn prepare_multipart_call(
  method: String,
  parts: List(Part),
  decoder: Decoder(value),
) -> PreparedCall(value) {
  PreparedCall(method:, payload: MultipartPayload(parts:), decoder:)
}

/// Convert a prepared call to a standard `gleam/http` request without sending
/// it.
///
/// Telegram requires the bot token in the URL. Treat the returned request as a
/// secret and redact its path from logs.
pub fn to_http_request(
  api: Api,
  call: PreparedCall(value),
) -> Result(request.Request(BitArray), GlammyError) {
  payload_to_http_request(api, call.method, call.payload)
}

/// Decode a standard `gleam/http` response for its matching prepared call.
///
/// HTTP status failures, Telegram error envelopes, UTF-8 failures, and result
/// decoding failures remain distinct `GlammyError` variants.
pub fn from_http_response(
  call: PreparedCall(value),
  response: response.Response(BitArray),
) -> Result(value, GlammyError) {
  use body <- result.try(http_response.classify(
    call.method,
    response.status,
    response.body,
  ))
  decode_envelope(call.method, body, call.decoder)
}

/// Execute a prepared call with the built-in `gleam_httpc` transport.
///
/// Registered transformers are preserved for backwards compatibility. New
/// custom transports should use `to_http_request` and `from_http_response`.
pub fn execute(
  api: Api,
  call: PreparedCall(value),
) -> Result(value, GlammyError) {
  let chain =
    compose_chain(api.transformers, fn(method, payload) {
      default_http_call(api, method, payload)
    })
  use body <- result.try(chain(call.method, call.payload))
  decode_envelope(call.method, body, call.decoder)
}

/// Call any Bot API method with a JSON body. Returns the decoded value.
pub fn call(
  api: Api,
  method: String,
  fields: List(#(String, json.Json)),
  decoder: Decoder(t),
) -> Result(t, GlammyError) {
  execute(api, prepare_json_call(method, fields, decoder))
}

/// Call any Bot API method with a multipart body. Use this when at least
/// one field is an `InputFile` that requires uploading.
pub fn call_multipart(
  api: Api,
  method: String,
  parts: List(Part),
  decoder: Decoder(t),
) -> Result(t, GlammyError) {
  execute(api, prepare_multipart_call(method, parts, decoder))
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
  use req <- result.try(payload_to_http_request(api, method, payload))

  let config =
    httpc.configure()
    |> httpc.timeout(api.timeout_ms)
    |> httpc.verify_tls(True)

  case httpc.dispatch_bits(config, req) {
    Ok(resp) -> http_response.classify(method, resp.status, resp.body)
    Error(e) -> Error(HttpError(method:, reason: e))
  }
}

fn payload_to_http_request(
  api: Api,
  method: String,
  payload: Payload,
) -> Result(request.Request(BitArray), GlammyError) {
  let Secret(reveal_token) = api.token
  let url = api.base_url <> "/bot" <> reveal_token() <> "/" <> method
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
  Ok(req)
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
          types.response_parameters_decoder(),
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
  }
}

// =====================================================================
//                           Read-only methods
// =====================================================================

/// Call Telegram's `getMe` method.
pub fn get_me(api: Api) -> Result(User, GlammyError) {
  call(api, "getMe", [], types.user_decoder())
}

/// Call Telegram's `logOut` method.
pub fn log_out(api: Api) -> Result(Bool, GlammyError) {
  call(api, "logOut", [], decode.bool)
}

/// Call Telegram's `close` method.
pub fn close(api: Api) -> Result(Bool, GlammyError) {
  call(api, "close", [], decode.bool)
}

/// Call Telegram's `getWebhookInfo` method.
pub fn get_webhook_info(api: Api) -> Result(WebhookInfo, GlammyError) {
  call(api, "getWebhookInfo", [], types.webhook_info_decoder())
}

/// Call Telegram's `getUpdates` method.
pub fn get_updates(
  api: Api,
  offset offset: Option(Int),
  limit limit: Option(Int),
  timeout timeout: Option(Int),
  allowed_updates allowed_updates: Option(List(String)),
) -> Result(List(Update), GlammyError) {
  let fields =
    []
    |> json_utils.put_optional("offset", offset, json.int)
    |> json_utils.put_optional("limit", limit, json.int)
    |> json_utils.put_optional("timeout", timeout, json.int)
    |> json_utils.put_optional("allowed_updates", allowed_updates, fn(items) {
      json.array(items, json.string)
    })
  call(api, "getUpdates", fields, decode.list(types.update_decoder()))
}

/// Register an official Bot API webhook at a validated absolute HTTPS URL.
///
/// A self-hosted Local Bot API server can accept HTTP webhook URLs. Keep that
/// deployment-specific exception explicit with `prepare_json_call`; this
/// high-level method intentionally preserves the public Bot API's TLS rule.
pub fn set_webhook(
  api: Api,
  url: HttpsUrl,
  options: SetWebhookOptions,
) -> Result(Bool, GlammyError) {
  let fields =
    [#("url", json.string(https_url.to_string(url)))]
    |> json_utils.put_optional("ip_address", options.ip_address, json.string)
    |> json_utils.put_optional(
      "max_connections",
      options.max_connections,
      json.int,
    )
    |> json_utils.put_optional(
      "allowed_updates",
      options.allowed_updates,
      fn(xs) { json.array(xs, json.string) },
    )
    |> json_utils.put_optional(
      "drop_pending_updates",
      options.drop_pending_updates,
      json.bool,
    )
    |> json_utils.put_optional("secret_token", options.secret_token, fn(secret) {
      json.string(webhook_secret.to_string(secret))
    })
  call(api, "setWebhook", fields, decode.bool)
}

/// A public-key certificate that is always uploaded as multipart bytes.
///
/// Telegram explicitly rejects a file identifier or URL for this field, so
/// this type deliberately cannot represent either of those `InputFile` forms.
pub opaque type WebhookCertificate {
  WebhookCertificate(
    bytes: BitArray,
    filename: String,
    mime_type: Option(String),
  )
}

/// Build an upload-only public-key certificate for `setWebhook`.
pub fn webhook_certificate(
  bytes: BitArray,
  filename: String,
  mime_type: Option(String),
) -> WebhookCertificate {
  WebhookCertificate(bytes:, filename:, mime_type:)
}

/// Register a webhook and upload a self-signed public-key certificate.
///
/// The URL and secret retain the same validated types as `set_webhook`; only
/// the transport changes to `multipart/form-data` for the required upload.
pub fn set_webhook_with_certificate(
  api: Api,
  url: HttpsUrl,
  certificate: WebhookCertificate,
  options: SetWebhookOptions,
) -> Result(Bool, GlammyError) {
  let option_parts =
    []
    |> opt_extra("ip_address", options.ip_address)
    |> opt_int_extra("max_connections", options.max_connections)
    |> opt_extra(
      "allowed_updates",
      option.map(options.allowed_updates, fn(updates) {
        updates |> json.array(json.string) |> json.to_string
      }),
    )
    |> opt_bool_extra("drop_pending_updates", options.drop_pending_updates)
    |> opt_extra(
      "secret_token",
      option.map(options.secret_token, webhook_secret.to_string),
    )
  let parts = [
    TextPart(name: "url", value: https_url.to_string(url)),
    FilePart(
      name: "certificate",
      filename: certificate.filename,
      content_type: certificate.mime_type,
      body: certificate.bytes,
    ),
    ..list.map(option_parts, fn(part) { TextPart(name: part.0, value: part.1) })
  ]
  call_multipart(api, "setWebhook", parts, decode.bool)
}

/// Optional registration settings accepted by Telegram's `setWebhook` method.
pub type SetWebhookOptions {
  SetWebhookOptions(
    ip_address: Option(String),
    max_connections: Option(Int),
    allowed_updates: Option(List(String)),
    drop_pending_updates: Option(Bool),
    secret_token: Option(WebhookSecret),
  )
}

/// Default options for `set_webhook`.
pub fn default_set_webhook_options() -> SetWebhookOptions {
  SetWebhookOptions(
    ip_address: None,
    max_connections: None,
    allowed_updates: None,
    drop_pending_updates: None,
    secret_token: None,
  )
}

/// Call Telegram's `deleteWebhook` method.
pub fn delete_webhook(
  api: Api,
  drop_pending_updates: Option(Bool),
) -> Result(Bool, GlammyError) {
  let fields =
    []
    |> json_utils.put_optional(
      "drop_pending_updates",
      drop_pending_updates,
      json.bool,
    )
  call(api, "deleteWebhook", fields, decode.bool)
}

// =====================================================================
//                         Send & edit messages
// =====================================================================

/// Optional fields accepted by Telegram's `sendMessage` method.
pub type SendMessageOptions {
  SendMessageOptions(
    parse_mode: Option(ParseMode),
    message_thread_id: Option(Int),
    direct_messages_topic_id: Option(Int),
    delivery: MessageDelivery,
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    link_preview_options: Option(LinkPreviewOptions),
    reply_markup: Option(ReplyMarkup),
    business_connection_id: Option(String),
  )
}

/// Default options for `send_message`.
pub fn default_send_message_options() -> SendMessageOptions {
  SendMessageOptions(
    parse_mode: None,
    message_thread_id: None,
    direct_messages_topic_id: None,
    delivery: message_options.standard_delivery(),
    disable_notification: None,
    protect_content: None,
    allow_paid_broadcast: None,
    message_effect_id: None,
    link_preview_options: None,
    reply_markup: None,
    business_connection_id: None,
  )
}

/// Call Telegram's `sendMessage` method.
pub fn send_message(
  api: Api,
  chat_id: ChatId,
  text: String,
  options options: SendMessageOptions,
) -> Result(Message, GlammyError) {
  let fields =
    [#("chat_id", chat_id_to_json(chat_id)), #("text", json.string(text))]
    |> json_utils.put_optional("parse_mode", options.parse_mode, fn(mode) {
      json.string(parse_mode.to_string(mode))
    })
    |> json_utils.put_optional(
      "message_thread_id",
      options.message_thread_id,
      json.int,
    )
    |> json_utils.put_optional(
      "direct_messages_topic_id",
      options.direct_messages_topic_id,
      json.int,
    )
    |> json_utils.put_optional(
      "disable_notification",
      options.disable_notification,
      json.bool,
    )
    |> json_utils.put_optional(
      "protect_content",
      options.protect_content,
      json.bool,
    )
    |> json_utils.put_optional(
      "allow_paid_broadcast",
      options.allow_paid_broadcast,
      json.bool,
    )
    |> json_utils.put_optional(
      "message_effect_id",
      options.message_effect_id,
      json.string,
    )
    |> json_utils.put_optional(
      "link_preview_options",
      options.link_preview_options,
      types.link_preview_options_to_json,
    )
  let fields =
    list.append(fields, message_options.delivery_json_fields(options.delivery))
  let fields =
    fields
    |> json_utils.put_optional(
      "reply_markup",
      options.reply_markup,
      keyboard.reply_markup_to_json,
    )
    |> json_utils.put_optional(
      "business_connection_id",
      options.business_connection_id,
      json.string,
    )
  call(api, "sendMessage", fields, types.message_decoder())
}

/// Call Telegram's `forwardMessage` method.
pub fn forward_message(
  api: Api,
  chat_id: ChatId,
  from_chat_id from_chat_id: ChatId,
  message_id message_id: Int,
) -> Result(Message, GlammyError) {
  call(
    api,
    "forwardMessage",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("from_chat_id", chat_id_to_json(from_chat_id)),
      #("message_id", json.int(message_id)),
    ],
    types.message_decoder(),
  )
}

/// A validated 1–100-element batch of positive Telegram message identifiers.
pub opaque type MessageIds {
  MessageIds(values: List(Int))
}

/// A validated strictly increasing batch for Telegram's `forwardMessages`.
pub opaque type ForwardMessageIds {
  ForwardMessageIds(values: List(Int))
}

/// Why a batch of Telegram message identifiers is invalid.
pub type MessageIdsError {
  InvalidMessageIdsCount(count: Int)
  NonPositiveMessageId(message_id: Int)
  MessageIdsNotStrictlyIncreasing(previous_message_id: Int, message_id: Int)
}

/// Validate the 1–100 positive identifiers accepted by batch message methods.
pub fn message_ids(values: List(Int)) -> Result(MessageIds, MessageIdsError) {
  use _ <- result.try(validate_message_ids(values))
  Ok(MessageIds(values:))
}

/// Validate the ordered identifiers required by `forwardMessages`.
pub fn forward_message_ids(
  values: List(Int),
) -> Result(ForwardMessageIds, MessageIdsError) {
  use _ <- result.try(validate_message_ids(values))
  use _ <- result.try(validate_strictly_increasing_message_ids(values))
  Ok(ForwardMessageIds(values:))
}

fn validate_message_ids(values: List(Int)) -> Result(Nil, MessageIdsError) {
  let count = list.length(values)
  case count >= 1 && count <= 100 {
    False -> Error(InvalidMessageIdsCount(count))
    True ->
      case list.find(values, fn(value) { value <= 0 }) {
        Ok(message_id) -> Error(NonPositiveMessageId(message_id))
        Error(_) -> Ok(Nil)
      }
  }
}

fn validate_strictly_increasing_message_ids(
  values: List(Int),
) -> Result(Nil, MessageIdsError) {
  case values {
    [] | [_] -> Ok(Nil)
    [previous, message_id, ..rest] ->
      case message_id > previous {
        True -> validate_strictly_increasing_message_ids([message_id, ..rest])
        False ->
          Error(MessageIdsNotStrictlyIncreasing(
            previous_message_id: previous,
            message_id:,
          ))
      }
  }
}

/// Call Telegram's `forwardMessages` method.
pub fn forward_messages(
  api: Api,
  chat_id: ChatId,
  from_chat_id from_chat_id: ChatId,
  message_ids message_ids: ForwardMessageIds,
) -> Result(List(Int), GlammyError) {
  let ForwardMessageIds(values) = message_ids
  call(
    api,
    "forwardMessages",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("from_chat_id", chat_id_to_json(from_chat_id)),
      #("message_ids", json.array(values, json.int)),
    ],
    decode.list({
      use mid <- decode.field("message_id", decode.int)
      decode.success(mid)
    }),
  )
}

/// Call Telegram's `copyMessage` method.
pub fn copy_message(
  api: Api,
  chat_id: ChatId,
  from_chat_id from_chat_id: ChatId,
  message_id message_id: Int,
  caption caption: Option(String),
) -> Result(Int, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("from_chat_id", chat_id_to_json(from_chat_id)),
      #("message_id", json.int(message_id)),
    ]
    |> json_utils.put_optional("caption", caption, json.string)
  call(api, "copyMessage", fields, {
    use mid <- decode.field("message_id", decode.int)
    decode.success(mid)
  })
}

/// Call Telegram's `deleteMessage` method.
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

/// Call Telegram's `deleteMessages` method.
pub fn delete_messages(
  api: Api,
  chat_id: ChatId,
  message_ids: MessageIds,
) -> Result(Bool, GlammyError) {
  let MessageIds(values) = message_ids
  call(
    api,
    "deleteMessages",
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_ids", json.array(values, json.int)),
    ],
    decode.bool,
  )
}

/// Call Telegram's `editMessageText` method.
pub fn edit_message_text(
  api: Api,
  chat_id: ChatId,
  message_id message_id: Int,
  text text: String,
  parse_mode parse_mode: Option(ParseMode),
  reply_markup reply_markup: Option(InlineKeyboard),
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_id", json.int(message_id)),
      #("text", json.string(text)),
    ]
    |> json_utils.put_optional("parse_mode", parse_mode, fn(mode) {
      json.string(parse_mode.to_string(mode))
    })
    |> json_utils.put_optional(
      "reply_markup",
      reply_markup,
      keyboard.inline_to_json,
    )
  call(api, "editMessageText", fields, types.message_decoder())
}

/// Call Telegram's `editMessageCaption` method.
pub fn edit_message_caption(
  api: Api,
  chat_id: ChatId,
  message_id message_id: Int,
  caption caption: String,
  parse_mode parse_mode: Option(ParseMode),
  reply_markup reply_markup: Option(InlineKeyboard),
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_id", json.int(message_id)),
      #("caption", json.string(caption)),
    ]
    |> json_utils.put_optional("parse_mode", parse_mode, fn(mode) {
      json.string(parse_mode.to_string(mode))
    })
    |> json_utils.put_optional(
      "reply_markup",
      reply_markup,
      keyboard.inline_to_json,
    )
  call(api, "editMessageCaption", fields, types.message_decoder())
}

/// Call Telegram's `editMessageReplyMarkup` method.
pub fn edit_message_reply_markup(
  api: Api,
  chat_id: ChatId,
  message_id message_id: Int,
  reply_markup reply_markup: Option(InlineKeyboard),
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_id", json.int(message_id)),
    ]
    |> json_utils.put_optional(
      "reply_markup",
      reply_markup,
      keyboard.inline_to_json,
    )
  call(api, "editMessageReplyMarkup", fields, types.message_decoder())
}

/// The three identifiers that address one ephemeral message.
///
/// Keeping them together prevents edits from accidentally mixing a receiver
/// or ephemeral id from a different message.
pub opaque type EphemeralMessageTarget {
  EphemeralMessageTarget(
    chat_id: ChatId,
    receiver_user_id: Int,
    ephemeral_message_id: Int,
  )
}

/// Address an ephemeral message explicitly.
pub fn ephemeral_message_target(
  chat_id: ChatId,
  receiver_user_id: Int,
  ephemeral_message_id: Int,
) -> EphemeralMessageTarget {
  EphemeralMessageTarget(chat_id:, receiver_user_id:, ephemeral_message_id:)
}

/// Recover an edit target from a decoded ephemeral message.
pub fn ephemeral_target_from_message(
  message: Message,
) -> Option(EphemeralMessageTarget) {
  case message.receiver_user, message.ephemeral_message_id {
    Some(receiver), Some(ephemeral_message_id) ->
      Some(ephemeral_message_target(
        ChatIntId(message.chat.id),
        receiver.id,
        ephemeral_message_id,
      ))
    _, _ -> None
  }
}

fn ephemeral_target_fields(
  target: EphemeralMessageTarget,
) -> List(#(String, json.Json)) {
  let EphemeralMessageTarget(chat_id:, receiver_user_id:, ephemeral_message_id:) =
    target
  [
    #("chat_id", chat_id_to_json(chat_id)),
    #("receiver_user_id", json.int(receiver_user_id)),
    #("ephemeral_message_id", json.int(ephemeral_message_id)),
  ]
}

/// Optional formatting for `edit_ephemeral_message_text`.
pub type EditEphemeralTextOptions {
  EditEphemeralTextOptions(
    parse_mode: Option(ParseMode),
    link_preview_options: Option(LinkPreviewOptions),
    reply_markup: Option(InlineKeyboard),
  )
}

/// Default ephemeral text-edit options.
pub fn default_edit_ephemeral_text_options() -> EditEphemeralTextOptions {
  EditEphemeralTextOptions(
    parse_mode: None,
    link_preview_options: None,
    reply_markup: None,
  )
}

/// Edit an ephemeral text message.
pub fn edit_ephemeral_message_text(
  api: Api,
  target: EphemeralMessageTarget,
  text: String,
  options: EditEphemeralTextOptions,
) -> Result(Bool, GlammyError) {
  let fields =
    target
    |> ephemeral_target_fields
    |> list.append([#("text", json.string(text))])
    |> json_utils.put_optional("parse_mode", options.parse_mode, fn(mode) {
      json.string(parse_mode.to_string(mode))
    })
    |> json_utils.put_optional(
      "link_preview_options",
      options.link_preview_options,
      types.link_preview_options_to_json,
    )
    |> json_utils.put_optional(
      "reply_markup",
      options.reply_markup,
      keyboard.inline_to_json,
    )
  call(api, "editEphemeralMessageText", fields, decode.bool)
}

/// Optional formatting for `edit_ephemeral_message_caption`.
pub type EditEphemeralCaptionOptions {
  EditEphemeralCaptionOptions(
    parse_mode: Option(ParseMode),
    reply_markup: Option(InlineKeyboard),
  )
}

/// Default ephemeral caption-edit options.
pub fn default_edit_ephemeral_caption_options() -> EditEphemeralCaptionOptions {
  EditEphemeralCaptionOptions(parse_mode: None, reply_markup: None)
}

/// Edit or remove an ephemeral media caption.
pub fn edit_ephemeral_message_caption(
  api: Api,
  target: EphemeralMessageTarget,
  caption: Option(String),
  options: EditEphemeralCaptionOptions,
) -> Result(Bool, GlammyError) {
  let fields =
    target
    |> ephemeral_target_fields
    |> json_utils.put_optional("caption", caption, json.string)
    |> json_utils.put_optional("parse_mode", options.parse_mode, fn(mode) {
      json.string(parse_mode.to_string(mode))
    })
    |> json_utils.put_optional(
      "reply_markup",
      options.reply_markup,
      keyboard.inline_to_json,
    )
  call(api, "editEphemeralMessageCaption", fields, decode.bool)
}

/// Replace an ephemeral message's media using an existing file id or URL.
///
/// Telegram does not accept a new multipart upload for this endpoint;
/// `ReuseOnlyInputMedia` proves that the JSON payload contains no attachment.
pub fn edit_ephemeral_message_media(
  api: Api,
  target: EphemeralMessageTarget,
  media: ReuseOnlyInputMedia,
  reply_markup: Option(InlineKeyboard),
) -> Result(Bool, GlammyError) {
  let fields =
    target
    |> ephemeral_target_fields
    |> list.append([#("media", input_media.reuse_only_to_json(media))])
    |> json_utils.put_optional(
      "reply_markup",
      reply_markup,
      keyboard.inline_to_json,
    )
  call(api, "editEphemeralMessageMedia", fields, decode.bool)
}

/// Replace or remove an ephemeral message's inline keyboard.
pub fn edit_ephemeral_message_reply_markup(
  api: Api,
  target: EphemeralMessageTarget,
  reply_markup: Option(InlineKeyboard),
) -> Result(Bool, GlammyError) {
  let fields =
    target
    |> ephemeral_target_fields
    |> json_utils.put_optional(
      "reply_markup",
      reply_markup,
      keyboard.inline_to_json,
    )
  call(api, "editEphemeralMessageReplyMarkup", fields, decode.bool)
}

/// Delete one ephemeral message.
pub fn delete_ephemeral_message(
  api: Api,
  target: EphemeralMessageTarget,
) -> Result(Bool, GlammyError) {
  call(
    api,
    "deleteEphemeralMessage",
    ephemeral_target_fields(target),
    decode.bool,
  )
}

/// Call Telegram's `stopPoll` method.
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
    types.poll_decoder(),
  )
}

/// Optional routing fields for Telegram's `sendChatAction` method.
pub type SendChatActionOptions {
  SendChatActionOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
  )
}

/// Default routing for `send_chat_action`.
pub fn default_send_chat_action_options() -> SendChatActionOptions {
  SendChatActionOptions(business_connection_id: None, message_thread_id: None)
}

/// Call Telegram's `sendChatAction` method.
pub fn send_chat_action(
  api: Api,
  chat_id: ChatId,
  action: ChatAction,
  options options: SendChatActionOptions,
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("action", json.string(chat_action.to_string(action))),
    ]
    |> json_utils.put_optional(
      "business_connection_id",
      options.business_connection_id,
      json.string,
    )
    |> json_utils.put_optional(
      "message_thread_id",
      options.message_thread_id,
      json.int,
    )
  call(api, "sendChatAction", fields, decode.bool)
}

// =====================================================================
//                            Send media
// =====================================================================

type CommonMediaOptions {
  CommonMediaOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
    direct_messages_topic_id: Option(Int),
    delivery: MessageDelivery,
    caption: Option(String),
    parse_mode: Option(ParseMode),
    show_caption_above_media: Option(Bool),
    has_spoiler: Option(Bool),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_markup: Option(ReplyMarkup),
  )
}

fn send_media_via_multipart(
  api: Api,
  method: String,
  chat_id: ChatId,
  file_field: String,
  file: InputFile,
  thumbnail_value: Option(Thumbnail),
  options: CommonMediaOptions,
  extra_text_parts: List(#(String, String)),
) -> Result(Message, GlammyError) {
  let option_extras =
    []
    |> opt_extra("business_connection_id", options.business_connection_id)
    |> opt_int_extra("message_thread_id", options.message_thread_id)
    |> opt_int_extra(
      "direct_messages_topic_id",
      options.direct_messages_topic_id,
    )
    |> opt_extra("caption", options.caption)
    |> opt_extra(
      "parse_mode",
      option.map(options.parse_mode, parse_mode.to_string),
    )
    |> opt_bool_extra(
      "show_caption_above_media",
      options.show_caption_above_media,
    )
    |> opt_bool_extra("has_spoiler", options.has_spoiler)
    |> opt_bool_extra("disable_notification", options.disable_notification)
    |> opt_bool_extra("protect_content", options.protect_content)
    |> opt_bool_extra("allow_paid_broadcast", options.allow_paid_broadcast)
    |> opt_extra("message_effect_id", options.message_effect_id)
  let option_extras =
    list.append(
      option_extras,
      message_options.delivery_text_fields(options.delivery),
    )
  let option_extras =
    option_extras
    |> opt_extra(
      "reply_markup",
      option.map(options.reply_markup, fn(markup) {
        markup |> keyboard.reply_markup_to_json |> json.to_string
      }),
    )
  let base_parts = [
    TextPart(name: "chat_id", value: chat_id_to_string(chat_id)),
  ]
  let with_file = file_to_parts(base_parts, file_field, file_field, file)
  let with_thumbnail = case thumbnail_value {
    None -> with_file
    Some(value) ->
      file_to_parts(
        with_file,
        "thumbnail",
        "thumbnail",
        thumbnail.to_input_file(value),
      )
  }
  let with_options =
    list.fold(
      list.append(extra_text_parts, option_extras),
      with_thumbnail,
      fn(parts, pair) {
        list.append(parts, [TextPart(name: pair.0, value: pair.1)])
      },
    )
  call_multipart(api, method, with_options, types.message_decoder())
}

/// Call Telegram's `sendPhoto` method.
pub fn send_photo(
  api: Api,
  chat_id: ChatId,
  photo: InputFile,
  options options: SendPhotoOptions,
) -> Result(Message, GlammyError) {
  send_media_via_multipart(
    api,
    "sendPhoto",
    chat_id,
    "photo",
    photo,
    None,
    CommonMediaOptions(
      business_connection_id: options.business_connection_id,
      message_thread_id: options.message_thread_id,
      direct_messages_topic_id: options.direct_messages_topic_id,
      delivery: options.delivery,
      caption: options.caption,
      parse_mode: options.parse_mode,
      show_caption_above_media: options.show_caption_above_media,
      has_spoiler: options.has_spoiler,
      disable_notification: options.disable_notification,
      protect_content: options.protect_content,
      allow_paid_broadcast: options.allow_paid_broadcast,
      message_effect_id: options.message_effect_id,
      reply_markup: options.reply_markup,
    ),
    [],
  )
}

/// Call Telegram's `sendDocument` method.
pub fn send_document(
  api: Api,
  chat_id: ChatId,
  document: InputFile,
  options options: SendDocumentOptions,
) -> Result(Message, GlammyError) {
  send_media_via_multipart(
    api,
    "sendDocument",
    chat_id,
    "document",
    document,
    options.thumbnail,
    CommonMediaOptions(
      business_connection_id: options.business_connection_id,
      message_thread_id: options.message_thread_id,
      direct_messages_topic_id: options.direct_messages_topic_id,
      delivery: options.delivery,
      caption: options.caption,
      parse_mode: options.parse_mode,
      show_caption_above_media: None,
      has_spoiler: None,
      disable_notification: options.disable_notification,
      protect_content: options.protect_content,
      allow_paid_broadcast: options.allow_paid_broadcast,
      message_effect_id: options.message_effect_id,
      reply_markup: options.reply_markup,
    ),
    opt_bool_extra(
      [],
      "disable_content_type_detection",
      options.disable_content_type_detection,
    ),
  )
}

/// Call Telegram's `sendVideo` method.
pub fn send_video(
  api: Api,
  chat_id: ChatId,
  video: InputFile,
  options options: SendVideoOptions,
) -> Result(Message, GlammyError) {
  let extras =
    []
    |> opt_int_extra("duration", options.duration)
    |> opt_int_extra("width", options.width)
    |> opt_int_extra("height", options.height)
    |> opt_bool_extra("supports_streaming", options.supports_streaming)
  send_media_via_multipart(
    api,
    "sendVideo",
    chat_id,
    "video",
    video,
    options.thumbnail,
    CommonMediaOptions(
      business_connection_id: options.business_connection_id,
      message_thread_id: options.message_thread_id,
      direct_messages_topic_id: options.direct_messages_topic_id,
      delivery: options.delivery,
      caption: options.caption,
      parse_mode: options.parse_mode,
      show_caption_above_media: options.show_caption_above_media,
      has_spoiler: options.has_spoiler,
      disable_notification: options.disable_notification,
      protect_content: options.protect_content,
      allow_paid_broadcast: options.allow_paid_broadcast,
      message_effect_id: options.message_effect_id,
      reply_markup: options.reply_markup,
    ),
    extras,
  )
}

/// Call Telegram's `sendAudio` method.
pub fn send_audio(
  api: Api,
  chat_id: ChatId,
  audio: InputFile,
  options options: SendAudioOptions,
) -> Result(Message, GlammyError) {
  let extras =
    []
    |> opt_extra("performer", options.performer)
    |> opt_extra("title", options.title)
    |> opt_int_extra("duration", options.duration)
  send_media_via_multipart(
    api,
    "sendAudio",
    chat_id,
    "audio",
    audio,
    options.thumbnail,
    CommonMediaOptions(
      business_connection_id: options.business_connection_id,
      message_thread_id: options.message_thread_id,
      direct_messages_topic_id: options.direct_messages_topic_id,
      delivery: options.delivery,
      caption: options.caption,
      parse_mode: options.parse_mode,
      show_caption_above_media: None,
      has_spoiler: None,
      disable_notification: options.disable_notification,
      protect_content: options.protect_content,
      allow_paid_broadcast: options.allow_paid_broadcast,
      message_effect_id: options.message_effect_id,
      reply_markup: options.reply_markup,
    ),
    extras,
  )
}

/// Call Telegram's `sendVoice` method.
pub fn send_voice(
  api: Api,
  chat_id: ChatId,
  voice: InputFile,
  options options: SendVoiceOptions,
) -> Result(Message, GlammyError) {
  let extras = opt_int_extra([], "duration", options.duration)
  send_media_via_multipart(
    api,
    "sendVoice",
    chat_id,
    "voice",
    voice,
    None,
    CommonMediaOptions(
      business_connection_id: options.business_connection_id,
      message_thread_id: options.message_thread_id,
      direct_messages_topic_id: options.direct_messages_topic_id,
      delivery: options.delivery,
      caption: options.caption,
      parse_mode: options.parse_mode,
      show_caption_above_media: None,
      has_spoiler: None,
      disable_notification: options.disable_notification,
      protect_content: options.protect_content,
      allow_paid_broadcast: options.allow_paid_broadcast,
      message_effect_id: options.message_effect_id,
      reply_markup: options.reply_markup,
    ),
    extras,
  )
}

/// Call Telegram's `sendAnimation` method.
pub fn send_animation(
  api: Api,
  chat_id: ChatId,
  animation: InputFile,
  options options: SendAnimationOptions,
) -> Result(Message, GlammyError) {
  let extras =
    []
    |> opt_int_extra("duration", options.duration)
    |> opt_int_extra("width", options.width)
    |> opt_int_extra("height", options.height)
  send_media_via_multipart(
    api,
    "sendAnimation",
    chat_id,
    "animation",
    animation,
    options.thumbnail,
    CommonMediaOptions(
      business_connection_id: options.business_connection_id,
      message_thread_id: options.message_thread_id,
      direct_messages_topic_id: options.direct_messages_topic_id,
      delivery: options.delivery,
      caption: options.caption,
      parse_mode: options.parse_mode,
      show_caption_above_media: options.show_caption_above_media,
      has_spoiler: options.has_spoiler,
      disable_notification: options.disable_notification,
      protect_content: options.protect_content,
      allow_paid_broadcast: options.allow_paid_broadcast,
      message_effect_id: options.message_effect_id,
      reply_markup: options.reply_markup,
    ),
    extras,
  )
}

/// Call Telegram's `sendVideoNote` method.
pub fn send_video_note(
  api: Api,
  chat_id: ChatId,
  video_note: FileIdOrUpload,
  options options: SendVideoNoteOptions,
) -> Result(Message, GlammyError) {
  let extras =
    []
    |> opt_int_extra("duration", options.duration)
    |> opt_int_extra("length", options.length)
  send_media_via_multipart(
    api,
    "sendVideoNote",
    chat_id,
    "video_note",
    input_file.file_id_or_upload_to_input_file(video_note),
    options.thumbnail,
    CommonMediaOptions(
      business_connection_id: options.business_connection_id,
      message_thread_id: options.message_thread_id,
      direct_messages_topic_id: options.direct_messages_topic_id,
      delivery: options.delivery,
      caption: None,
      parse_mode: None,
      show_caption_above_media: None,
      has_spoiler: None,
      disable_notification: options.disable_notification,
      protect_content: options.protect_content,
      allow_paid_broadcast: options.allow_paid_broadcast,
      message_effect_id: options.message_effect_id,
      reply_markup: options.reply_markup,
    ),
    extras,
  )
}

/// Call Telegram's `sendSticker` method.
pub fn send_sticker(
  api: Api,
  chat_id: ChatId,
  sticker: InputFile,
  options options: SendStickerOptions,
) -> Result(Message, GlammyError) {
  send_media_via_multipart(
    api,
    "sendSticker",
    chat_id,
    "sticker",
    sticker,
    None,
    CommonMediaOptions(
      business_connection_id: options.business_connection_id,
      message_thread_id: options.message_thread_id,
      direct_messages_topic_id: options.direct_messages_topic_id,
      delivery: options.delivery,
      caption: None,
      parse_mode: None,
      show_caption_above_media: None,
      has_spoiler: None,
      disable_notification: options.disable_notification,
      protect_content: options.protect_content,
      allow_paid_broadcast: options.allow_paid_broadcast,
      message_effect_id: options.message_effect_id,
      reply_markup: options.reply_markup,
    ),
    opt_extra([], "emoji", options.emoji),
  )
}

/// Optional delivery fields accepted by Telegram's `sendMediaGroup` method.
pub type SendMediaGroupOptions {
  SendMediaGroupOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
    direct_messages_topic_id: Option(Int),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_parameters: Option(ReplyParameters),
  )
}

/// Default optional fields for `sendMediaGroup`.
pub fn default_send_media_group_options() -> SendMediaGroupOptions {
  SendMediaGroupOptions(
    business_connection_id: None,
    message_thread_id: None,
    direct_messages_topic_id: None,
    disable_notification: None,
    protect_content: None,
    allow_paid_broadcast: None,
    message_effect_id: None,
    reply_parameters: None,
  )
}

/// Send a validated photo/video, audio, or document album.
pub fn send_media_group(
  api: Api,
  chat_id: ChatId,
  media: MediaGroup,
  options options: SendMediaGroupOptions,
) -> Result(List(Message), GlammyError) {
  let prepared =
    media
    |> input_media.media_group_items
    |> list.index_map(input_media.prepare_multipart)
  let media_json =
    prepared
    |> list.map(fn(item) { item.0 })
    |> json.preprocessed_array
    |> json.to_string
  let option_parts =
    []
    |> opt_extra("business_connection_id", options.business_connection_id)
    |> opt_int_extra("message_thread_id", options.message_thread_id)
    |> opt_int_extra(
      "direct_messages_topic_id",
      options.direct_messages_topic_id,
    )
    |> opt_bool_extra("disable_notification", options.disable_notification)
    |> opt_bool_extra("protect_content", options.protect_content)
    |> opt_bool_extra("allow_paid_broadcast", options.allow_paid_broadcast)
    |> opt_extra("message_effect_id", options.message_effect_id)
    |> opt_extra(
      "reply_parameters",
      option.map(options.reply_parameters, fn(parameters) {
        parameters
        |> message_options.reply_parameters_to_json
        |> json.to_string
      }),
    )
  let base_parts = [
    TextPart(name: "chat_id", value: chat_id_to_string(chat_id)),
    TextPart(name: "media", value: media_json),
    ..list.map(option_parts, fn(part) { TextPart(name: part.0, value: part.1) })
  ]
  let parts =
    list.fold(prepared, base_parts, fn(parts, item) {
      list.fold(item.1, parts, add_media_group_attachment)
    })
  call_multipart(
    api,
    "sendMediaGroup",
    parts,
    decode.list(types.message_decoder()),
  )
}

fn add_media_group_attachment(
  parts: List(Part),
  attachment: #(String, InputFile),
) -> List(Part) {
  case attachment.1 {
    input_file.FileBytes(bytes:, filename:, mime_type:) ->
      list.append(parts, [
        FilePart(
          name: attachment.0,
          filename:,
          content_type: mime_type,
          body: bytes,
        ),
      ])
    input_file.FileId(_) | input_file.FileUrl(_) -> parts
  }
}

// =====================================================================
//                         Location / Venue / Contact / Poll / Dice
// =====================================================================

/// Call Telegram's `sendLocation` method.
pub fn send_location(
  api: Api,
  chat_id: ChatId,
  latitude latitude: Float,
  longitude longitude: Float,
  live_period live_period: Option(Int),
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("latitude", json.float(latitude)),
      #("longitude", json.float(longitude)),
    ]
    |> json_utils.put_optional("live_period", live_period, json.int)
  call(api, "sendLocation", fields, types.message_decoder())
}

/// Call Telegram's `sendVenue` method.
pub fn send_venue(
  api: Api,
  chat_id: ChatId,
  latitude latitude: Float,
  longitude longitude: Float,
  title title: String,
  address address: String,
) -> Result(Message, GlammyError) {
  let fields = [
    #("chat_id", chat_id_to_json(chat_id)),
    #("latitude", json.float(latitude)),
    #("longitude", json.float(longitude)),
    #("title", json.string(title)),
    #("address", json.string(address)),
  ]
  call(api, "sendVenue", fields, types.message_decoder())
}

/// Call Telegram's `sendContact` method.
pub fn send_contact(
  api: Api,
  chat_id: ChatId,
  phone_number phone_number: String,
  first_name first_name: String,
  last_name last_name: Option(String),
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("phone_number", json.string(phone_number)),
      #("first_name", json.string(first_name)),
    ]
    |> json_utils.put_optional("last_name", last_name, json.string)
  call(api, "sendContact", fields, types.message_decoder())
}

/// One of Telegram's six supported animated dice.
///
/// This type is outbound-only. Incoming `types.Dice.emoji` stays a `String`
/// so a future Telegram value remains decodable before Glammy is upgraded.
pub type DiceEmoji {
  Dice
  Darts
  Basketball
  Football
  SlotMachine
  Bowling
}

fn dice_emoji_to_string(emoji: DiceEmoji) -> String {
  case emoji {
    Dice -> "🎲"
    Darts -> "🎯"
    Basketball -> "🏀"
    Football -> "⚽"
    SlotMachine -> "🎰"
    Bowling -> "🎳"
  }
}

/// Call Telegram's `sendDice` method.
pub fn send_dice(
  api: Api,
  chat_id: ChatId,
  emoji: Option(DiceEmoji),
) -> Result(Message, GlammyError) {
  let fields =
    [#("chat_id", chat_id_to_json(chat_id))]
    |> json_utils.put_optional("emoji", emoji, fn(value) {
      json.string(dice_emoji_to_string(value))
    })
  call(api, "sendDice", fields, types.message_decoder())
}

/// Plain quiz explanation text whose protocol bounds are already proven.
pub opaque type PollExplanation {
  PollExplanation(text: String)
}

/// Why plain quiz explanation text is not Telegram-compatible.
pub type PollExplanationError {
  PollExplanationTooLong(length: Int)
  TooManyPollExplanationLineFeeds(count: Int)
}

/// Validate a plain quiz explanation of at most 200 codepoints and two LFs.
///
/// Parsed/entity forms use the explicit prepared-call escape hatch because
/// validating source markup would not prove Telegram's post-parse limits.
pub fn poll_explanation(
  text: String,
) -> Result(PollExplanation, PollExplanationError) {
  let length = poll_text_length(text)
  let line_feeds = poll_line_feed_count(text)
  case length > 200, line_feeds > 2 {
    True, _ -> Error(PollExplanationTooLong(length))
    _, True -> Error(TooManyPollExplanationLineFeeds(line_feeds))
    False, False -> Ok(PollExplanation(text))
  }
}

fn poll_explanation_text(explanation: PollExplanation) -> String {
  explanation.text
}

/// A plain poll description whose Bot API length bound is already proven.
pub opaque type PollDescription {
  PollDescription(text: String)
}

/// Why plain poll description text is not Telegram-compatible.
pub type PollDescriptionError {
  PollDescriptionTooLong(length: Int)
}

/// Validate a plain poll description of at most 1024 Unicode codepoints.
///
/// Parsed/entity forms remain available through `prepare_json_call`.
pub fn poll_description(
  text: String,
) -> Result(PollDescription, PollDescriptionError) {
  let length = poll_text_length(text)
  case length <= 1024 {
    True -> Ok(PollDescription(text))
    False -> Error(PollDescriptionTooLong(length))
  }
}

fn poll_description_text(description: PollDescription) -> String {
  description.text
}

fn poll_text_length(text: String) -> Int {
  text |> string.to_utf_codepoints |> list.length
}

fn poll_line_feed_count(text: String) -> Int {
  text
  |> string.to_utf_codepoints
  |> list.filter(fn(codepoint) { string.utf_codepoint_to_int(codepoint) == 10 })
  |> list.length
}

/// A complete, validated outbound poll definition.
///
/// Options and kind live in the same opaque value, so quiz answer identifiers
/// and quiz-only explanations cannot be validated against one definition and
/// sent with another.
pub opaque type SendPoll {
  SendRegularPoll(
    options: InputPollOptions,
    is_anonymous: Bool,
    allow_adding_options: Bool,
  )
  SendQuizPoll(
    options: InputPollOptions,
    first_correct_option_id: Int,
    other_correct_option_ids: List(Int),
    is_anonymous: Bool,
    explanation: Option(PollExplanation),
  )
}

/// Why quiz answer identifiers could not form a valid `SendPoll`.
pub type SendPollError {
  NegativeCorrectOptionId(id: Int)
  CorrectOptionIdOutOfRange(id: Int, option_count: Int)
  CorrectOptionIdsNotIncreasing(previous: Int, next: Int)
}

/// Build a regular poll from an already size-validated option collection.
pub fn regular_poll(options: InputPollOptions) -> SendPoll {
  SendRegularPoll(options:, is_anonymous: True, allow_adding_options: False)
}

/// Build a public regular poll, optionally allowing voters to add answers.
///
/// Telegram only supports adding options to public regular polls, so the
/// capability lives on this constructor instead of in generic send options.
pub fn public_regular_poll(
  options: InputPollOptions,
  allow_adding_options: Bool,
) -> SendPoll {
  SendRegularPoll(options:, is_anonymous: False, allow_adding_options:)
}

/// Build a quiz whose correct identifiers belong to this exact option list.
pub fn quiz_poll(
  options: InputPollOptions,
  first_correct_option_id: Int,
  other_correct_option_ids: List(Int),
  explanation: Option(PollExplanation),
) -> Result(SendPoll, SendPollError) {
  build_quiz_poll(
    options,
    first_correct_option_id,
    other_correct_option_ids,
    True,
    explanation,
  )
}

/// Build a non-anonymous quiz whose answer identifiers match its options.
pub fn public_quiz_poll(
  options: InputPollOptions,
  first_correct_option_id: Int,
  other_correct_option_ids: List(Int),
  explanation: Option(PollExplanation),
) -> Result(SendPoll, SendPollError) {
  build_quiz_poll(
    options,
    first_correct_option_id,
    other_correct_option_ids,
    False,
    explanation,
  )
}

fn build_quiz_poll(
  options: InputPollOptions,
  first_correct_option_id: Int,
  other_correct_option_ids: List(Int),
  is_anonymous: Bool,
  explanation: Option(PollExplanation),
) -> Result(SendPoll, SendPollError) {
  let option_count =
    options
    |> types.input_poll_options_to_list
    |> list.length
  use _ <- result.try(validate_correct_option_id(
    first_correct_option_id,
    option_count,
  ))
  use _ <- result.try(validate_following_correct_option_ids(
    first_correct_option_id,
    other_correct_option_ids,
    option_count,
  ))
  Ok(SendQuizPoll(
    options:,
    first_correct_option_id:,
    other_correct_option_ids:,
    is_anonymous:,
    explanation:,
  ))
}

fn validate_correct_option_id(
  id: Int,
  option_count: Int,
) -> Result(Nil, SendPollError) {
  case id {
    id if id < 0 -> Error(NegativeCorrectOptionId(id))
    id if id >= option_count ->
      Error(CorrectOptionIdOutOfRange(id:, option_count:))
    _ -> Ok(Nil)
  }
}

fn validate_following_correct_option_ids(
  previous: Int,
  remaining: List(Int),
  option_count: Int,
) -> Result(Nil, SendPollError) {
  case remaining {
    [] -> Ok(Nil)
    [next, ..rest] -> {
      use _ <- result.try(validate_correct_option_id(next, option_count))
      case next > previous {
        False -> Error(CorrectOptionIdsNotIncreasing(previous, next))
        True -> validate_following_correct_option_ids(next, rest, option_count)
      }
    }
  }
}

fn send_poll_fields(
  poll: SendPoll,
) -> #(
  InputPollOptions,
  String,
  Bool,
  Bool,
  Option(List(Int)),
  Option(PollExplanation),
) {
  case poll {
    SendRegularPoll(options:, is_anonymous:, allow_adding_options:) -> #(
      options,
      "regular",
      is_anonymous,
      allow_adding_options,
      None,
      None,
    )
    SendQuizPoll(
      options:,
      first_correct_option_id: first,
      other_correct_option_ids: rest,
      is_anonymous:,
      explanation:,
    ) -> #(
      options,
      "quiz",
      is_anonymous,
      False,
      Some([first, ..rest]),
      explanation,
    )
  }
}

/// Why a bounded poll transport value could not be constructed.
pub type PollConfigurationError {
  PollOpenPeriodOutOfRange(seconds: Int)
  NonPositivePollCloseDate(timestamp: Int)
  TooManyPollCountryCodes(count: Int)
  InvalidPollCountryCode(code: String)
}

/// A mutually-exclusive schedule for automatically closing a poll.
pub opaque type PollSchedule {
  DefaultPollSchedule
  PollOpenFor(seconds: Int)
  PollCloseAt(timestamp: Int)
}

/// Do not request automatic poll closure.
pub fn default_poll_schedule() -> PollSchedule {
  DefaultPollSchedule
}

/// Keep a poll open for Telegram's supported 5..2,628,000 seconds.
pub fn poll_open_for(
  seconds: Int,
) -> Result(PollSchedule, PollConfigurationError) {
  case seconds >= 5 && seconds <= 2_628_000 {
    True -> Ok(PollOpenFor(seconds))
    False -> Error(PollOpenPeriodOutOfRange(seconds))
  }
}

/// Close a poll at a positive Unix timestamp.
///
/// Telegram additionally requires this to be 5..2,628,000 seconds in the
/// future; that time-relative rule is checked by the server.
pub fn poll_close_at(
  timestamp: Int,
) -> Result(PollSchedule, PollConfigurationError) {
  case timestamp > 0 {
    True -> Ok(PollCloseAt(timestamp))
    False -> Error(NonPositivePollCloseDate(timestamp))
  }
}

fn poll_schedule_fields(schedule: PollSchedule) -> #(Option(Int), Option(Int)) {
  case schedule {
    DefaultPollSchedule -> #(None, None)
    PollOpenFor(seconds) -> #(Some(seconds), None)
    PollCloseAt(timestamp) -> #(None, Some(timestamp))
  }
}

/// A checked list of at most twelve two-letter uppercase country codes.
pub opaque type PollCountryCodes {
  PollCountryCodes(List(String))
}

/// Validate country-code shape and Telegram's maximum list size.
///
/// This accepts all two-letter ASCII uppercase codes, including Telegram's
/// special `FT` value. Whether a code is currently assigned by ISO remains a
/// server-owned, evolving registry check.
pub fn poll_country_codes(
  codes: List(String),
) -> Result(PollCountryCodes, PollConfigurationError) {
  case list.length(codes) > 12 {
    True -> Error(TooManyPollCountryCodes(list.length(codes)))
    False -> {
      use _ <- result.try(validate_poll_country_codes(codes))
      Ok(PollCountryCodes(codes))
    }
  }
}

fn validate_poll_country_codes(
  codes: List(String),
) -> Result(Nil, PollConfigurationError) {
  case codes {
    [] -> Ok(Nil)
    [code, ..rest] ->
      case string.to_graphemes(code) {
        [first, second] ->
          case
            string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", first)
            && string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", second)
          {
            True -> validate_poll_country_codes(rest)
            False -> Error(InvalidPollCountryCode(code))
          }
        _ -> Error(InvalidPollCountryCode(code))
      }
  }
}

fn poll_country_codes_to_list(codes: PollCountryCodes) -> List(String) {
  let PollCountryCodes(values) = codes
  values
}

/// Optional fields accepted by Telegram's Bot API 10.2 `sendPoll` method.
pub type SendPollOptions {
  SendPollOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
    allows_multiple_answers: Option(Bool),
    allows_revoting: Option(Bool),
    shuffle_options: Option(Bool),
    hide_results_until_closes: Option(Bool),
    members_only: Option(Bool),
    country_codes: Option(PollCountryCodes),
    schedule: PollSchedule,
    is_closed: Option(Bool),
    description: Option(PollDescription),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_parameters: Option(ReplyParameters),
    reply_markup: Option(ReplyMarkup),
  )
}

/// Default options for `send_poll`.
pub fn default_send_poll_options() -> SendPollOptions {
  SendPollOptions(
    business_connection_id: None,
    message_thread_id: None,
    allows_multiple_answers: None,
    allows_revoting: None,
    shuffle_options: None,
    hide_results_until_closes: None,
    members_only: None,
    country_codes: None,
    schedule: default_poll_schedule(),
    is_closed: None,
    description: None,
    disable_notification: None,
    protect_content: None,
    allow_paid_broadcast: None,
    message_effect_id: None,
    reply_parameters: None,
    reply_markup: None,
  )
}

/// Send a poll whose question, option texts/count, kind, and quiz answer ids
/// have already passed their structural constructors.
pub fn send_poll(
  api: Api,
  chat_id: ChatId,
  question question: PollQuestion,
  poll poll: SendPoll,
  opts opts: SendPollOptions,
) -> Result(Message, GlammyError) {
  let #(
    options,
    poll_kind,
    is_anonymous,
    allow_adding_options,
    correct_option_ids,
    explanation,
  ) = send_poll_fields(poll)
  let #(open_period, close_date) = poll_schedule_fields(opts.schedule)
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("question", json.string(types.poll_question_text(question))),
      #(
        "options",
        options
          |> types.input_poll_options_to_list
          |> json.array(types.input_poll_option_to_json),
      ),
      #("type", json.string(poll_kind)),
      #("is_anonymous", json.bool(is_anonymous)),
      #("allow_adding_options", json.bool(allow_adding_options)),
    ]
    |> json_utils.put_optional(
      "business_connection_id",
      opts.business_connection_id,
      json.string,
    )
    |> json_utils.put_optional(
      "message_thread_id",
      opts.message_thread_id,
      json.int,
    )
    |> json_utils.put_optional(
      "allows_multiple_answers",
      opts.allows_multiple_answers,
      json.bool,
    )
    |> json_utils.put_optional(
      "allows_revoting",
      opts.allows_revoting,
      json.bool,
    )
    |> json_utils.put_optional(
      "shuffle_options",
      opts.shuffle_options,
      json.bool,
    )
    |> json_utils.put_optional(
      "hide_results_until_closes",
      opts.hide_results_until_closes,
      json.bool,
    )
    |> json_utils.put_optional("members_only", opts.members_only, json.bool)
    |> json_utils.put_optional("country_codes", opts.country_codes, fn(codes) {
      codes
      |> poll_country_codes_to_list
      |> json.array(json.string)
    })
    |> json_utils.put_optional(
      "correct_option_ids",
      correct_option_ids,
      fn(ids) { json.array(ids, json.int) },
    )
    |> json_utils.put_optional("explanation", explanation, fn(value) {
      json.string(poll_explanation_text(value))
    })
    |> json_utils.put_optional("open_period", open_period, json.int)
    |> json_utils.put_optional("close_date", close_date, json.int)
    |> json_utils.put_optional("is_closed", opts.is_closed, json.bool)
    |> json_utils.put_optional("description", opts.description, fn(value) {
      json.string(poll_description_text(value))
    })
    |> json_utils.put_optional(
      "disable_notification",
      opts.disable_notification,
      json.bool,
    )
    |> json_utils.put_optional(
      "allow_paid_broadcast",
      opts.allow_paid_broadcast,
      json.bool,
    )
    |> json_utils.put_optional(
      "message_effect_id",
      opts.message_effect_id,
      json.string,
    )
    |> json_utils.put_optional(
      "protect_content",
      opts.protect_content,
      json.bool,
    )
    |> json_utils.put_optional(
      "reply_parameters",
      opts.reply_parameters,
      message_options.reply_parameters_to_json,
    )
    |> json_utils.put_optional(
      "reply_markup",
      opts.reply_markup,
      keyboard.reply_markup_to_json,
    )
  call(api, "sendPoll", fields, types.message_decoder())
}

// =====================================================================
//                          answer*  helpers
// =====================================================================

/// Optional notification and redirect fields for `answerCallbackQuery`.
pub type AnswerCallbackQueryOptions {
  AnswerCallbackQueryOptions(
    text: Option(String),
    show_alert: Option(Bool),
    url: Option(String),
    cache_time: Option(Int),
  )
}

/// Default options for `answer_callback_query`.
pub fn default_answer_callback_query_options() -> AnswerCallbackQueryOptions {
  AnswerCallbackQueryOptions(
    text: None,
    show_alert: None,
    url: None,
    cache_time: None,
  )
}

/// Call Telegram's `answerCallbackQuery` method.
pub fn answer_callback_query(
  api: Api,
  callback_query_id: String,
  options: AnswerCallbackQueryOptions,
) -> Result(Bool, GlammyError) {
  let fields =
    [#("callback_query_id", json.string(callback_query_id))]
    |> json_utils.put_optional("text", options.text, json.string)
    |> json_utils.put_optional("show_alert", options.show_alert, json.bool)
    |> json_utils.put_optional("url", options.url, json.string)
    |> json_utils.put_optional("cache_time", options.cache_time, json.int)
  call(api, "answerCallbackQuery", fields, decode.bool)
}

/// Call Telegram's `answerInlineQuery` method.
pub fn answer_inline_query(
  api: Api,
  inline_query_id: String,
  results results: InlineQueryResults,
  cache_time cache_time: Option(Int),
  is_personal is_personal: Option(Bool),
  next_offset next_offset: Option(String),
) -> Result(Bool, GlammyError) {
  answer_inline_query_with_options(
    api,
    inline_query_id,
    results,
    AnswerInlineQueryOptions(
      cache_time:,
      is_personal:,
      next_offset:,
      button: None,
    ),
  )
}

/// Optional cache, pagination, and action-button fields for an inline answer.
pub type AnswerInlineQueryOptions {
  AnswerInlineQueryOptions(
    cache_time: Option(Int),
    is_personal: Option(Bool),
    next_offset: Option(String),
    button: Option(InlineQueryResultsButton),
  )
}

/// Default options for `answer_inline_query_with_options`.
pub fn default_answer_inline_query_options() -> AnswerInlineQueryOptions {
  AnswerInlineQueryOptions(
    cache_time: None,
    is_personal: None,
    next_offset: None,
    button: None,
  )
}

/// Call `answerInlineQuery`, including its mutually-exclusive results button.
pub fn answer_inline_query_with_options(
  api: Api,
  inline_query_id: String,
  results: InlineQueryResults,
  options: AnswerInlineQueryOptions,
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("inline_query_id", json.string(inline_query_id)),
      #(
        "results",
        results
          |> inline_query_results.results_to_list
          |> list.map(inline_query_results.to_json)
          |> json.preprocessed_array,
      ),
    ]
    |> json_utils.put_optional("cache_time", options.cache_time, json.int)
    |> json_utils.put_optional("is_personal", options.is_personal, json.bool)
    |> json_utils.put_optional("next_offset", options.next_offset, json.string)
    |> json_utils.put_optional(
      "button",
      options.button,
      inline_query_results.results_button_to_json,
    )
  call(api, "answerInlineQuery", fields, decode.bool)
}

/// Answer a guest-mode update with one typed inline result.
///
/// Read the query identifier from `Message.guest_query_id` (or
/// `context.guest_query_id`) on a `GuestMessageUpdate`.
pub fn answer_guest_query(
  api: Api,
  guest_query_id: String,
  result: InlineQueryResult,
) -> Result(SentGuestMessage, GlammyError) {
  call(
    api,
    "answerGuestQuery",
    [
      #("guest_query_id", json.string(guest_query_id)),
      #("result", inline_query_results.to_json(result)),
    ],
    types.sent_guest_message_decoder(),
  )
}

/// A labeled amount in the smallest units of a currency.
pub type LabeledPrice {
  LabeledPrice(label: String, amount: Int)
}

/// One delivery choice offered for a shipping query.
pub type ShippingOption {
  ShippingOption(id: String, title: String, prices: List(LabeledPrice))
}

/// A valid answer to Telegram's `ShippingQuery`.
pub type ShippingQueryAnswer {
  /// Accept the address and provide available shipping choices.
  ShippingOptions(List(ShippingOption))
  /// Reject the address with a user-facing explanation.
  ShippingError(String)
}

fn shipping_option_to_json(option: ShippingOption) -> json.Json {
  json.object([
    #("id", json.string(option.id)),
    #("title", json.string(option.title)),
    #(
      "prices",
      json.array(option.prices, fn(price) {
        json.object([
          #("label", json.string(price.label)),
          #("amount", json.int(price.amount)),
        ])
      }),
    ),
  ])
}

/// Call Telegram's `answerShippingQuery` method.
pub fn answer_shipping_query(
  api: Api,
  shipping_query_id: String,
  answer: ShippingQueryAnswer,
) -> Result(Bool, GlammyError) {
  let fields = case answer {
    ShippingOptions(options) -> [
      #("shipping_query_id", json.string(shipping_query_id)),
      #("ok", json.bool(True)),
      #("shipping_options", json.array(options, shipping_option_to_json)),
    ]
    ShippingError(message) -> [
      #("shipping_query_id", json.string(shipping_query_id)),
      #("ok", json.bool(False)),
      #("error_message", json.string(message)),
    ]
  }
  call(api, "answerShippingQuery", fields, decode.bool)
}

/// A valid answer to Telegram's `PreCheckoutQuery`.
pub type PreCheckoutQueryAnswer {
  /// Approve checkout and continue payment.
  ApprovePreCheckout
  /// Reject checkout with a user-facing explanation.
  RejectPreCheckout(String)
}

/// Call Telegram's `answerPreCheckoutQuery` method.
pub fn answer_pre_checkout_query(
  api: Api,
  pre_checkout_query_id: String,
  answer: PreCheckoutQueryAnswer,
) -> Result(Bool, GlammyError) {
  let fields = case answer {
    ApprovePreCheckout -> [
      #("pre_checkout_query_id", json.string(pre_checkout_query_id)),
      #("ok", json.bool(True)),
    ]
    RejectPreCheckout(message) -> [
      #("pre_checkout_query_id", json.string(pre_checkout_query_id)),
      #("ok", json.bool(False)),
      #("error_message", json.string(message)),
    ]
  }
  call(api, "answerPreCheckoutQuery", fields, decode.bool)
}

// =====================================================================
//                       Chat management
// =====================================================================

/// Call Telegram's `banChatMember` method.
pub fn ban_chat_member(
  api: Api,
  chat_id: ChatId,
  user_id user_id: Int,
  until_date until_date: Option(Int),
  revoke_messages revoke_messages: Option(Bool),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("user_id", json.int(user_id)),
    ]
    |> json_utils.put_optional("until_date", until_date, json.int)
    |> json_utils.put_optional("revoke_messages", revoke_messages, json.bool)
  call(api, "banChatMember", fields, decode.bool)
}

/// Call Telegram's `unbanChatMember` method.
pub fn unban_chat_member(
  api: Api,
  chat_id: ChatId,
  user_id user_id: Int,
  only_if_banned only_if_banned: Option(Bool),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("user_id", json.int(user_id)),
    ]
    |> json_utils.put_optional("only_if_banned", only_if_banned, json.bool)
  call(api, "unbanChatMember", fields, decode.bool)
}

/// Call Telegram's `restrictChatMember` method.
pub fn restrict_chat_member(
  api: Api,
  chat_id: ChatId,
  user_id user_id: Int,
  permissions permissions: ChatPermissions,
  until_date until_date: Option(Int),
  use_independent_chat_permissions use_independent_chat_permissions: Option(
    Bool,
  ),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("user_id", json.int(user_id)),
      #("permissions", types.chat_permissions_to_json(permissions)),
    ]
    |> json_utils.put_optional("until_date", until_date, json.int)
    |> json_utils.put_optional(
      "use_independent_chat_permissions",
      use_independent_chat_permissions,
      json.bool,
    )
  call(api, "restrictChatMember", fields, decode.bool)
}

/// Call Telegram's `promoteChatMember` method.
pub fn promote_chat_member(
  api: Api,
  chat_id: ChatId,
  user_id user_id: Int,
  rights rights: PromoteRights,
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("user_id", json.int(user_id)),
    ]
    |> json_utils.put_optional("is_anonymous", rights.is_anonymous, json.bool)
    |> json_utils.put_optional(
      "can_manage_chat",
      rights.can_manage_chat,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_delete_messages",
      rights.can_delete_messages,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_manage_video_chats",
      rights.can_manage_video_chats,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_restrict_members",
      rights.can_restrict_members,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_promote_members",
      rights.can_promote_members,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_change_info",
      rights.can_change_info,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_invite_users",
      rights.can_invite_users,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_post_messages",
      rights.can_post_messages,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_edit_messages",
      rights.can_edit_messages,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_pin_messages",
      rights.can_pin_messages,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_post_stories",
      rights.can_post_stories,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_edit_stories",
      rights.can_edit_stories,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_delete_stories",
      rights.can_delete_stories,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_manage_topics",
      rights.can_manage_topics,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_manage_direct_messages",
      rights.can_manage_direct_messages,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_manage_tags",
      rights.can_manage_tags,
      json.bool,
    )
  call(api, "promoteChatMember", fields, decode.bool)
}

/// Optional administrator rights accepted by `promoteChatMember`.
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
    can_manage_direct_messages: Option(Bool),
    can_manage_tags: Option(Bool),
  )
}

/// Default empty rights set for `promote_chat_member`.
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
    can_manage_direct_messages: None,
    can_manage_tags: None,
  )
}

/// Call Telegram's `setChatAdministratorCustomTitle` method.
pub fn set_chat_administrator_custom_title(
  api: Api,
  chat_id: ChatId,
  user_id user_id: Int,
  custom_title custom_title: String,
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

/// Call Telegram's `setChatPermissions` method.
pub fn set_chat_permissions(
  api: Api,
  chat_id: ChatId,
  permissions: ChatPermissions,
  use_independent_chat_permissions use_independent_chat_permissions: Option(
    Bool,
  ),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("permissions", types.chat_permissions_to_json(permissions)),
    ]
    |> json_utils.put_optional(
      "use_independent_chat_permissions",
      use_independent_chat_permissions,
      json.bool,
    )
  call(api, "setChatPermissions", fields, decode.bool)
}

/// Call Telegram's `exportChatInviteLink` method.
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

/// Validated optional fields shared by invite-link create and edit methods.
pub opaque type ChatInviteLinkOptions {
  ChatInviteLinkOptions(
    name: Option(String),
    expire_date: Option(Int),
    member_limit: Option(Int),
    creates_join_request: Option(Bool),
  )
}

/// Why invite-link options cannot be accepted by Telegram.
pub type ChatInviteLinkOptionsError {
  InviteLinkNameTooLong(length: Int)
  NonPositiveInviteLinkExpireDate(timestamp: Int)
  InviteLinkMemberLimitOutOfRange(limit: Int)
  JoinRequestWithMemberLimit
}

/// Validate one partial invite-link option set.
///
/// Names contain at most 32 codepoints, expiry timestamps are positive, member
/// limits are 1..99999, and a request cannot both limit direct joins and
/// require administrator approval. Whether `expire_date` is in the future
/// remains a server-time check.
pub fn chat_invite_link_options(
  name: Option(String),
  expire_date: Option(Int),
  member_limit: Option(Int),
  creates_join_request: Option(Bool),
) -> Result(ChatInviteLinkOptions, ChatInviteLinkOptionsError) {
  let name_length = case name {
    Some(value) -> value |> string.to_utf_codepoints |> list.length
    None -> 0
  }
  case name_length > 32 {
    True -> Error(InviteLinkNameTooLong(name_length))
    False ->
      case expire_date {
        Some(timestamp) if timestamp <= 0 ->
          Error(NonPositiveInviteLinkExpireDate(timestamp))
        _ ->
          case member_limit {
            Some(limit) if limit < 1 || limit > 99_999 ->
              Error(InviteLinkMemberLimitOutOfRange(limit))
            _ ->
              case creates_join_request == Some(True) && member_limit != None {
                True -> Error(JoinRequestWithMemberLimit)
                False ->
                  Ok(ChatInviteLinkOptions(
                    name:,
                    expire_date:,
                    member_limit:,
                    creates_join_request:,
                  ))
              }
          }
      }
  }
}

fn chat_invite_link_option_fields(
  options: ChatInviteLinkOptions,
) -> List(#(String, json.Json)) {
  []
  |> json_utils.put_optional("name", options.name, json.string)
  |> json_utils.put_optional("expire_date", options.expire_date, json.int)
  |> json_utils.put_optional("member_limit", options.member_limit, json.int)
  |> json_utils.put_optional(
    "creates_join_request",
    options.creates_join_request,
    json.bool,
  )
}

/// Call Telegram's `createChatInviteLink` method.
pub fn create_chat_invite_link(
  api: Api,
  chat_id: ChatId,
  options: ChatInviteLinkOptions,
) -> Result(ChatInviteLink, GlammyError) {
  let fields =
    [#("chat_id", chat_id_to_json(chat_id))]
    |> list.append(chat_invite_link_option_fields(options), _)
  call(api, "createChatInviteLink", fields, types.chat_invite_link_decoder())
}

/// Call Telegram's `editChatInviteLink` method.
pub fn edit_chat_invite_link(
  api: Api,
  chat_id: ChatId,
  invite_link invite_link: String,
  options options: ChatInviteLinkOptions,
) -> Result(ChatInviteLink, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("invite_link", json.string(invite_link)),
    ]
    |> list.append(chat_invite_link_option_fields(options), _)
  call(api, "editChatInviteLink", fields, types.chat_invite_link_decoder())
}

/// Call Telegram's `revokeChatInviteLink` method.
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
    types.chat_invite_link_decoder(),
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

/// Call Telegram's `approveChatJoinRequest` method.
pub fn approve_chat_join_request(
  api: Api,
  chat_id: ChatId,
  user_id: Int,
) -> Result(Bool, GlammyError) {
  chat_join_request_action(api, "approveChatJoinRequest", chat_id, user_id)
}

/// Call Telegram's `declineChatJoinRequest` method.
pub fn decline_chat_join_request(
  api: Api,
  chat_id: ChatId,
  user_id: Int,
) -> Result(Bool, GlammyError) {
  chat_join_request_action(api, "declineChatJoinRequest", chat_id, user_id)
}

/// A finite decision for a join-request query.
pub type JoinRequestQueryResult {
  ApproveJoinRequestQuery
  DeclineJoinRequestQuery
  QueueJoinRequestQuery
}

fn join_request_query_result_to_string(
  result: JoinRequestQueryResult,
) -> String {
  case result {
    ApproveJoinRequestQuery -> "approve"
    DeclineJoinRequestQuery -> "decline"
    QueueJoinRequestQuery -> "queue"
  }
}

/// Resolve a join-request query within Telegram's ten-second deadline.
pub fn answer_chat_join_request_query(
  api: Api,
  chat_join_request_query_id: String,
  query_result: JoinRequestQueryResult,
) -> Result(Bool, GlammyError) {
  call(
    api,
    "answerChatJoinRequestQuery",
    [
      #("chat_join_request_query_id", json.string(chat_join_request_query_id)),
      #(
        "result",
        json.string(join_request_query_result_to_string(query_result)),
      ),
    ],
    decode.bool,
  )
}

/// Open a Mini App at a validated HTTPS URL before resolving a join request.
pub fn send_chat_join_request_web_app(
  api: Api,
  chat_join_request_query_id: String,
  web_app_url: HttpsUrl,
) -> Result(Bool, GlammyError) {
  call(
    api,
    "sendChatJoinRequestWebApp",
    [
      #("chat_join_request_query_id", json.string(chat_join_request_query_id)),
      #("web_app_url", json.string(https_url.to_string(web_app_url))),
    ],
    decode.bool,
  )
}

/// Call Telegram's `setChatTitle` method.
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

/// Call Telegram's `setChatDescription` method.
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

/// Call Telegram's `pinChatMessage` method.
pub fn pin_chat_message(
  api: Api,
  chat_id: ChatId,
  message_id message_id: Int,
  disable_notification disable_notification: Option(Bool),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_id", json.int(message_id)),
    ]
    |> json_utils.put_optional(
      "disable_notification",
      disable_notification,
      json.bool,
    )
  call(api, "pinChatMessage", fields, decode.bool)
}

/// Call Telegram's `unpinChatMessage` method.
pub fn unpin_chat_message(
  api: Api,
  chat_id: ChatId,
  message_id: Option(Int),
) -> Result(Bool, GlammyError) {
  let fields =
    [#("chat_id", chat_id_to_json(chat_id))]
    |> json_utils.put_optional("message_id", message_id, json.int)
  call(api, "unpinChatMessage", fields, decode.bool)
}

/// Call Telegram's `unpinAllChatMessages` method.
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

/// Call Telegram's `leaveChat` method.
pub fn leave_chat(api: Api, chat_id: ChatId) -> Result(Bool, GlammyError) {
  call(api, "leaveChat", [#("chat_id", chat_id_to_json(chat_id))], decode.bool)
}

/// Call Telegram's `getChatMember` method.
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
    types.chat_member_decoder(),
  )
}

/// Call Telegram's `getChatAdministrators` method.
pub fn get_chat_administrators(
  api: Api,
  chat_id: ChatId,
) -> Result(List(ChatMember), GlammyError) {
  get_chat_administrators_with_options(api, chat_id, None)
}

/// Call `getChatAdministrators`, optionally retaining administrator bots.
pub fn get_chat_administrators_with_options(
  api: Api,
  chat_id: ChatId,
  return_bots: Option(Bool),
) -> Result(List(ChatMember), GlammyError) {
  let fields =
    [#("chat_id", chat_id_to_json(chat_id))]
    |> json_utils.put_optional("return_bots", return_bots, json.bool)
  call(
    api,
    "getChatAdministrators",
    fields,
    decode.list(types.chat_member_decoder()),
  )
}

/// Call Telegram's `getChatMemberCount` method.
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

/// Call Telegram's `getFile` method.
pub fn get_file(api: Api, file_id: String) -> Result(File, GlammyError) {
  call(
    api,
    "getFile",
    [#("file_id", json.string(file_id))],
    types.file_decoder(),
  )
}

// =====================================================================
//                       MyCommands / My* settings
// =====================================================================

fn scope_language_fields(
  scope: Option(BotCommandScope),
  language_code: Option(String),
) -> List(#(String, json.Json)) {
  []
  |> json_utils.put_optional("scope", scope, types.bot_command_scope_to_json)
  |> json_utils.put_optional("language_code", language_code, json.string)
}

/// Scope and language selection shared by bot command methods.
pub type MyCommandsOptions {
  MyCommandsOptions(
    scope: Option(BotCommandScope),
    language_code: Option(String),
  )
}

/// Default scope and language selection for command methods.
pub fn default_my_commands_options() -> MyCommandsOptions {
  MyCommandsOptions(scope: None, language_code: None)
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
    |> json_utils.put_optional(key, value, json.string)
    |> json_utils.put_optional("language_code", language_code, json.string)
  call(api, method, fields, decode.bool)
}

/// Call Telegram's `setMyCommands` method.
pub fn set_my_commands(
  api: Api,
  commands: BotCommands,
  options: MyCommandsOptions,
) -> Result(Bool, GlammyError) {
  let commands = types.bot_commands_to_list(commands)
  let fields =
    [
      #("commands", json.array(commands, types.bot_command_to_json)),
    ]
    |> list.append(
      scope_language_fields(options.scope, options.language_code),
      _,
    )
  call(api, "setMyCommands", fields, decode.bool)
}

/// Call Telegram's `getMyCommands` method.
pub fn get_my_commands(
  api: Api,
  options: MyCommandsOptions,
) -> Result(List(BotCommand), GlammyError) {
  call(
    api,
    "getMyCommands",
    scope_language_fields(options.scope, options.language_code),
    decode.list(types.bot_command_decoder()),
  )
}

/// Call Telegram's `deleteMyCommands` method.
pub fn delete_my_commands(
  api: Api,
  options: MyCommandsOptions,
) -> Result(Bool, GlammyError) {
  call(
    api,
    "deleteMyCommands",
    scope_language_fields(options.scope, options.language_code),
    decode.bool,
  )
}

/// Call Telegram's `setMyName` method.
pub fn set_my_name(
  api: Api,
  name: Option(String),
  language_code: Option(String),
) -> Result(Bool, GlammyError) {
  set_my_string(api, "setMyName", "name", name, language_code)
}

/// Call Telegram's `setMyDescription` method.
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

/// Call Telegram's `setMyShortDescription` method.
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

/// A forum topic created in a Telegram supergroup.
pub type ForumTopic {
  ForumTopic(
    message_thread_id: Int,
    name: String,
    icon_color: Int,
    icon_custom_emoji_id: Option(String),
    is_name_implicit: Option(Bool),
  )
}

/// Decode a Telegram `ForumTopic` value from JSON.
pub fn forum_topic_decoder() -> Decoder(ForumTopic) {
  use message_thread_id <- decode.field("message_thread_id", decode.int)
  use name <- decode.field("name", decode.string)
  use icon_color <- decode.field("icon_color", decode.int)
  use icon_custom_emoji_id <- decode.optional_field(
    "icon_custom_emoji_id",
    None,
    decode.optional(decode.string),
  )
  use is_name_implicit <- json_utils.opt_bool("is_name_implicit")
  decode.success(ForumTopic(
    message_thread_id:,
    name:,
    icon_color:,
    icon_custom_emoji_id:,
    is_name_implicit:,
  ))
}

/// Call Telegram's `createForumTopic` method.
pub fn create_forum_topic(
  api: Api,
  chat_id: ChatId,
  name name: String,
  icon_color icon_color: Option(Int),
  icon_custom_emoji_id icon_custom_emoji_id: Option(String),
) -> Result(ForumTopic, GlammyError) {
  let fields =
    [#("chat_id", chat_id_to_json(chat_id)), #("name", json.string(name))]
    |> json_utils.put_optional("icon_color", icon_color, json.int)
    |> json_utils.put_optional(
      "icon_custom_emoji_id",
      icon_custom_emoji_id,
      json.string,
    )
  call(api, "createForumTopic", fields, forum_topic_decoder())
}

/// Call Telegram's `editForumTopic` method.
pub fn edit_forum_topic(
  api: Api,
  chat_id: ChatId,
  message_thread_id message_thread_id: Int,
  name name: Option(String),
  icon_custom_emoji_id icon_custom_emoji_id: Option(String),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_thread_id", json.int(message_thread_id)),
    ]
    |> json_utils.put_optional("name", name, json.string)
    |> json_utils.put_optional(
      "icon_custom_emoji_id",
      icon_custom_emoji_id,
      json.string,
    )
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

/// Call Telegram's `closeForumTopic` method.
pub fn close_forum_topic(
  api: Api,
  chat_id: ChatId,
  message_thread_id: Int,
) -> Result(Bool, GlammyError) {
  forum_topic_action(api, "closeForumTopic", chat_id, message_thread_id)
}

/// Call Telegram's `reopenForumTopic` method.
pub fn reopen_forum_topic(
  api: Api,
  chat_id: ChatId,
  message_thread_id: Int,
) -> Result(Bool, GlammyError) {
  forum_topic_action(api, "reopenForumTopic", chat_id, message_thread_id)
}

/// Call Telegram's `deleteForumTopic` method.
pub fn delete_forum_topic(
  api: Api,
  chat_id: ChatId,
  message_thread_id: Int,
) -> Result(Bool, GlammyError) {
  forum_topic_action(api, "deleteForumTopic", chat_id, message_thread_id)
}

/// Call Telegram's `unpinAllForumTopicMessages` method.
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

/// Call Telegram's `setMessageReaction` method.
pub fn set_message_reaction(
  api: Api,
  chat_id: ChatId,
  message_id message_id: Int,
  change change: ReactionChange,
  is_big is_big: Option(Bool),
) -> Result(Bool, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("message_id", json.int(message_id)),
    ]
    |> list.append([#("reaction", reaction.change_to_json(change))], _)
    |> json_utils.put_optional("is_big", is_big, json.bool)
  call(api, "setMessageReaction", fields, decode.bool)
}

// =====================================================================
//                              Payments
// =====================================================================

/// Typed invoice and delivery fields for Telegram's `sendInvoice` method.
pub type SendInvoiceOptions {
  SendInvoiceOptions(
    message_thread_id: Option(Int),
    direct_messages_topic_id: Option(Int),
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
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_parameters: Option(ReplyParameters),
    reply_markup: Option(InvoiceInlineKeyboard),
  )
}

/// Call Telegram's `sendInvoice` method.
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
    |> json_utils.put_optional(
      "message_thread_id",
      invoice.message_thread_id,
      json.int,
    )
    |> json_utils.put_optional(
      "direct_messages_topic_id",
      invoice.direct_messages_topic_id,
      json.int,
    )
    |> json_utils.put_optional(
      "provider_token",
      invoice.provider_token,
      json.string,
    )
    |> json_utils.put_optional(
      "max_tip_amount",
      invoice.max_tip_amount,
      json.int,
    )
    |> json_utils.put_optional(
      "suggested_tip_amounts",
      invoice.suggested_tip_amounts,
      fn(xs) { json.array(xs, json.int) },
    )
    |> json_utils.put_optional(
      "start_parameter",
      invoice.start_parameter,
      json.string,
    )
    |> json_utils.put_optional(
      "provider_data",
      invoice.provider_data,
      json.string,
    )
    |> json_utils.put_optional("photo_url", invoice.photo_url, json.string)
    |> json_utils.put_optional("photo_size", invoice.photo_size, json.int)
    |> json_utils.put_optional("photo_width", invoice.photo_width, json.int)
    |> json_utils.put_optional("photo_height", invoice.photo_height, json.int)
    |> json_utils.put_optional("need_name", invoice.need_name, json.bool)
    |> json_utils.put_optional(
      "need_phone_number",
      invoice.need_phone_number,
      json.bool,
    )
    |> json_utils.put_optional("need_email", invoice.need_email, json.bool)
    |> json_utils.put_optional(
      "need_shipping_address",
      invoice.need_shipping_address,
      json.bool,
    )
    |> json_utils.put_optional(
      "send_phone_number_to_provider",
      invoice.send_phone_number_to_provider,
      json.bool,
    )
    |> json_utils.put_optional(
      "send_email_to_provider",
      invoice.send_email_to_provider,
      json.bool,
    )
    |> json_utils.put_optional("is_flexible", invoice.is_flexible, json.bool)
    |> json_utils.put_optional(
      "disable_notification",
      invoice.disable_notification,
      json.bool,
    )
    |> json_utils.put_optional(
      "protect_content",
      invoice.protect_content,
      json.bool,
    )
    |> json_utils.put_optional(
      "allow_paid_broadcast",
      invoice.allow_paid_broadcast,
      json.bool,
    )
    |> json_utils.put_optional(
      "message_effect_id",
      invoice.message_effect_id,
      json.string,
    )
    |> json_utils.put_optional(
      "reply_parameters",
      invoice.reply_parameters,
      message_options.reply_parameters_to_json,
    )
    |> json_utils.put_optional(
      "reply_markup",
      invoice.reply_markup,
      keyboard.invoice_inline_keyboard_to_json,
    )
  call(api, "sendInvoice", fields, types.message_decoder())
}

/// Call Telegram's `refundStarPayment` method.
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

/// A validated, non-negative Telegram game score.
pub opaque type GameScore {
  GameScore(value: Int)
}

/// Why a game score could not be validated for an outbound request.
pub type GameScoreError {
  NegativeGameScore(value: Int)
}

/// Validate a score before it can enter a `setGameScore` request.
pub fn game_score(value: Int) -> Result(GameScore, GameScoreError) {
  case value >= 0 {
    True -> Ok(GameScore(value:))
    False -> Error(NegativeGameScore(value:))
  }
}

/// Extract the integer value of a validated game score.
pub fn game_score_value(score: GameScore) -> Int {
  score.value
}

/// A valid target for `setGameScore`. The constructors make it impossible to
/// send only half of a chat-message target or combine chat and inline fields.
pub type GameScoreTarget {
  ChatGameMessage(chat_id: Int, message_id: Int)
  InlineGameMessage(inline_message_id: String)
}

/// Telegram returns the edited message for chat games and `True` for inline
/// games. Keep both success shapes explicit instead of erasing one as `Bool`.
pub type GameScoreResult {
  ChatGameMessageUpdated(Message)
  InlineGameMessageUpdated
}

/// Optional fields accepted by Telegram's Bot API 10.2 `sendGame` method.
///
/// A non-empty keyboard has its required game-launch button encoded in the
/// `GameInlineKeyboard` type, so ordinary keyboards cannot accidentally be
/// attached to this endpoint.
pub type SendGameOptions {
  SendGameOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_parameters: Option(ReplyParameters),
    reply_markup: Option(GameInlineKeyboard),
  )
}

/// Default options for `send_game_with_options`.
pub fn default_send_game_options() -> SendGameOptions {
  SendGameOptions(
    business_connection_id: None,
    message_thread_id: None,
    disable_notification: None,
    protect_content: None,
    allow_paid_broadcast: None,
    message_effect_id: None,
    reply_parameters: None,
    reply_markup: None,
  )
}

/// Call Telegram's `sendGame` method.
pub fn send_game(
  api: Api,
  chat_id: ChatId,
  game_short_name: String,
) -> Result(Message, GlammyError) {
  send_game_with_options(
    api,
    chat_id,
    game_short_name,
    default_send_game_options(),
  )
}

/// Call Telegram's `sendGame` method with its complete typed option set.
pub fn send_game_with_options(
  api: Api,
  chat_id: ChatId,
  game_short_name: String,
  options: SendGameOptions,
) -> Result(Message, GlammyError) {
  let fields =
    [
      #("chat_id", chat_id_to_json(chat_id)),
      #("game_short_name", json.string(game_short_name)),
    ]
    |> json_utils.put_optional(
      "business_connection_id",
      options.business_connection_id,
      json.string,
    )
    |> json_utils.put_optional(
      "message_thread_id",
      options.message_thread_id,
      json.int,
    )
    |> json_utils.put_optional(
      "disable_notification",
      options.disable_notification,
      json.bool,
    )
    |> json_utils.put_optional(
      "protect_content",
      options.protect_content,
      json.bool,
    )
    |> json_utils.put_optional(
      "allow_paid_broadcast",
      options.allow_paid_broadcast,
      json.bool,
    )
    |> json_utils.put_optional(
      "message_effect_id",
      options.message_effect_id,
      json.string,
    )
    |> json_utils.put_optional(
      "reply_parameters",
      options.reply_parameters,
      message_options.reply_parameters_to_json,
    )
    |> json_utils.put_optional(
      "reply_markup",
      options.reply_markup,
      keyboard.game_inline_keyboard_to_json,
    )
  call(api, "sendGame", fields, types.message_decoder())
}

/// Call Telegram's `setGameScore` method.
pub fn set_game_score(
  api: Api,
  user_id user_id: Int,
  score score: GameScore,
  target target: GameScoreTarget,
  force force: Option(Bool),
  disable_edit_message disable_edit_message: Option(Bool),
) -> Result(GameScoreResult, GlammyError) {
  let target_fields = case target {
    ChatGameMessage(chat_id:, message_id:) -> [
      #("chat_id", json.int(chat_id)),
      #("message_id", json.int(message_id)),
    ]
    InlineGameMessage(inline_message_id:) -> [
      #("inline_message_id", json.string(inline_message_id)),
    ]
  }
  let fields =
    list.append(
      [
        #("user_id", json.int(user_id)),
        #("score", json.int(score.value)),
      ],
      target_fields,
    )
    |> json_utils.put_optional("force", force, json.bool)
    |> json_utils.put_optional(
      "disable_edit_message",
      disable_edit_message,
      json.bool,
    )
  call(api, "setGameScore", fields, game_score_result_decoder())
}

fn game_score_result_decoder() -> Decoder(GameScoreResult) {
  decode.one_of(
    decode.map(types.message_decoder(), ChatGameMessageUpdated),
    or: [
      decode.then(decode.bool, fn(updated) {
        case updated {
          True -> decode.success(InlineGameMessageUpdated)
          False ->
            decode.failure(InlineGameMessageUpdated, "setGameScore result True")
        }
      }),
    ],
  )
}

// =====================================================================
//                       Webhook helper (parsing)
// =====================================================================

/// The domain object a JSON parser was trying to decode.
pub type JsonValueKind {
  /// A Telegram update body.
  UpdateJson
  /// A standalone callback-query body.
  CallbackQueryJson
}

/// A JSON decode failure with domain context retained.
pub type JsonParseError {
  JsonParseError(kind: JsonValueKind, message: String)
}

fn parse_with(
  body: String,
  decoder: Decoder(value),
  kind: JsonValueKind,
) -> Result(value, JsonParseError) {
  json.parse(body, decoder)
  |> result.map_error(fn(error) {
    JsonParseError(kind:, message: describe_json_error(error))
  })
}

/// Parse a webhook JSON body into an `Update`.
pub fn parse_update(body: String) -> Result(Update, JsonParseError) {
  parse_with(body, types.update_decoder(), UpdateJson)
}

/// Parse a JSON body into a `CallbackQuery`.
pub fn parse_callback_query(
  body: String,
) -> Result(CallbackQuery, JsonParseError) {
  parse_with(body, types.callback_query_decoder(), CallbackQueryJson)
}
