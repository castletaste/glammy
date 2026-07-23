import glammy/api
import glammy/chat_action
import glammy/error
import glammy/helpers
import glammy/https_url
import glammy/inline_query_results as iqr
import glammy/input_file
import glammy/input_media
import glammy/internal/http_response
import glammy/keyboard
import glammy/media_options
import glammy/message_options
import glammy/multipart.{type Part, FilePart, TextPart}
import glammy/parse_mode
import glammy/reaction
import glammy/thumbnail
import glammy/types
import glammy/webhook_secret
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const ok_bool = "{\"ok\":true,\"result\":true}"

const ok_message = "{\"ok\":true,\"result\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0}}"

const ok_sent_guest_message = "{\"ok\":true,\"result\":{\"inline_message_id\":\"guest-inline-1\"}}"

const ok_empty_list = "{\"ok\":true,\"result\":[]}"

const ok_chat_invite_link = "{\"ok\":true,\"result\":{\"invite_link\":\"https://t.me/+x\",\"creator\":{\"id\":1,\"is_bot\":true,\"first_name\":\"bot\"},\"creates_join_request\":true,\"is_primary\":false,\"is_revoked\":false}}"

pub fn forum_topic_decoder_preserves_implicit_name_test() {
  let body =
    "{\"message_thread_id\":42,\"name\":\"General\",\"icon_color\":7322096,\"is_name_implicit\":true}"
  let assert Ok(topic) = json.parse(body, api.forum_topic_decoder())
  assert topic.message_thread_id == 42
  assert topic.is_name_implicit == Some(True)
}

fn fake_response(body: String) -> api.Transformer {
  fn(_next, _method, _payload) { Ok(body) }
}

fn recording_response(
  recorder: process.Subject(#(String, api.Payload)),
  body: String,
) -> api.Transformer {
  fn(_next, method, payload) {
    process.send(recorder, #(method, payload))
    Ok(body)
  }
}

pub fn game_score_is_non_negative_test() {
  assert api.game_score(-1) == Error(api.NegativeGameScore(-1))
  let assert Ok(score) = api.game_score(0)
  assert api.game_score_value(score) == 0
}

pub fn send_game_encodes_only_game_first_keyboard_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_message))
  let trailing =
    keyboard.inline()
    |> keyboard.inline_url("Rules", "https://example.com/rules")
  let options =
    api.SendGameOptions(
      ..api.default_send_game_options(),
      business_connection_id: Some("business-1"),
      message_thread_id: Some(7),
      reply_markup: Some(keyboard.game_inline_keyboard_with("Play", trailing)),
    )

  let assert Ok(_) =
    api.send_game_with_options(client, api.ChatIntId(1), "maze", options)
  let assert Ok(#("sendGame", api.JsonPayload(fields))) =
    helpers.receive_event(recorder)
  let payload = fields |> json.object |> json.to_string
  assert string.contains(payload, "\"business_connection_id\":\"business-1\"")
  assert string.contains(payload, "\"message_thread_id\":7")
  assert string.contains(
    payload,
    "\"reply_markup\":{\"inline_keyboard\":[[{\"text\":\"Play\",\"callback_game\":{}}],[{\"text\":\"Rules\",\"url\":\"https://example.com/rules\"}]]}",
  )
}

pub fn send_invoice_encodes_only_pay_first_keyboard_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_message))
  let trailing =
    keyboard.inline()
    |> keyboard.inline_text("Receipt", "receipt")
  let invoice =
    api.SendInvoiceOptions(
      message_thread_id: None,
      direct_messages_topic_id: None,
      title: "Gleam mug",
      description: "One typed mug",
      payload: "order-1",
      provider_token: None,
      currency: "XTR",
      prices: [#("Mug", 100)],
      max_tip_amount: None,
      suggested_tip_amounts: None,
      start_parameter: None,
      provider_data: None,
      photo_url: None,
      photo_size: None,
      photo_width: None,
      photo_height: None,
      need_name: None,
      need_phone_number: None,
      need_email: None,
      need_shipping_address: None,
      send_phone_number_to_provider: None,
      send_email_to_provider: None,
      is_flexible: None,
      disable_notification: None,
      protect_content: None,
      allow_paid_broadcast: None,
      message_effect_id: None,
      reply_parameters: None,
      reply_markup: Some(keyboard.invoice_inline_keyboard_with("Pay", trailing)),
    )

  let assert Ok(_) = api.send_invoice(client, api.ChatIntId(1), invoice)
  let assert Ok(#("sendInvoice", api.JsonPayload(fields))) =
    helpers.receive_event(recorder)
  let payload = fields |> json.object |> json.to_string
  assert string.contains(
    payload,
    "\"reply_markup\":{\"inline_keyboard\":[[{\"text\":\"Pay\",\"pay\":true}],[{\"text\":\"Receipt\",\"callback_data\":\"receipt\"}]]}",
  )
}

pub fn set_game_score_decodes_chat_and_inline_results_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let message_body =
    "{\"ok\":true,\"result\":{\"message_id\":7,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0}}"
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, message_body))
  let assert Ok(score) = api.game_score(42)
  let assert Ok(api.ChatGameMessageUpdated(message)) =
    api.set_game_score(
      client,
      9,
      score,
      api.ChatGameMessage(chat_id: 1, message_id: 7),
      None,
      None,
    )
  assert message.message_id == 7
  let assert Ok(#("setGameScore", api.JsonPayload(fields))) =
    helpers.receive_event(recorder)
  let payload = json.object(fields) |> json.to_string
  assert string.contains(payload, "\"chat_id\":1")
  assert string.contains(payload, "\"message_id\":7")
  assert !string.contains(payload, "inline_message_id")

  let inline_client =
    api.new("token")
    |> api.with_transformer(fake_response("{\"ok\":true,\"result\":true}"))
  assert api.set_game_score(
      inline_client,
      9,
      score,
      api.InlineGameMessage("inline-1"),
      None,
      None,
    )
    == Ok(api.InlineGameMessageUpdated)
}

pub fn http_response_classification_preserves_error_contract_test() {
  case
    http_response.classify("getMe", 500, <<"{\"ok\":true,\"result\":{}}":utf8>>)
  {
    Error(error.HttpStatusError(method: "getMe", status: 500, ..)) -> Nil
    _ -> panic as "expected HttpStatusError"
  }

  let telegram_error =
    "{\"ok\":false,\"error_code\":400,\"description\":\"bad request\"}"
  let assert Ok(preserved) =
    http_response.classify("getMe", 400, <<telegram_error:utf8>>)
  let client =
    api.new("token") |> api.with_transformer(fake_response(preserved))
  case api.get_me(client) {
    Error(error.ApiError(error_code: 400, description: "bad request", ..)) ->
      Nil
    _ -> panic as "expected preserved Telegram ApiError"
  }

  case http_response.classify("getMe", 200, <<255>>) {
    Error(error.DecodeError(method: "getMe", message: "non-utf8 response body")) ->
      Nil
    _ -> panic as "expected DecodeError"
  }

  case http_response.classify("getMe", 503, <<255>>) {
    Error(error.HttpStatusError(
      method: "getMe",
      status: 503,
      body: "<non-utf8 response body>",
    )) -> Nil
    _ -> panic as "expected non-UTF8 503 to remain an HTTP status error"
  }

  case http_response.classify("getMe", 500, <<"{\"ok\":false}":utf8>>) {
    Error(error.HttpStatusError(method: "getMe", status: 500, ..)) -> Nil
    _ -> panic as "expected incomplete envelope to remain an HTTP error"
  }
}

pub fn send_media_group_uses_validated_multipart_album_test() {
  let first =
    input_media.InputMediaPhoto(
      media: input_file.FileBytes(<<1, 2>>, "one.jpg", None),
      caption: None,
      parse_mode: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  let second =
    input_media.InputMediaPhoto(
      media: input_file.FileId("existing"),
      caption: None,
      parse_mode: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  let assert Ok(group) = input_media.media_group([first, second])
  let response =
    "{\"ok\":true,\"result\":[{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0},{\"message_id\":2,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0}]}"
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, response))
  let assert Ok(messages) =
    api.send_media_group(
      client,
      api.ChatIntId(1),
      group,
      api.default_send_media_group_options(),
    )
  assert list.length(messages) == 2
  let assert Ok(#("sendMediaGroup", api.MultipartPayload(parts))) =
    helpers.receive_event(recorder)
  assert text_part(parts, "chat_id") == Ok("1")
  let assert Ok(media_json) = text_part(parts, "media")
  assert string.contains(media_json, "attach://media_0")
  assert string.contains(media_json, "\"media\":\"existing\"")
  assert file_part_names(parts) == ["media_0"]
}

pub fn timeout_and_poll_collection_invariants_test() {
  let client = api.new("token")
  assert api.with_timeout(client, 0) == Error(api.NonPositiveTimeout(0))
  assert api.with_timeout(client, -10) == Error(api.NonPositiveTimeout(-10))
  let assert Ok(_) = api.with_timeout(client, 1)
  let assert Ok(_) = api.with_timeout(client, 4_294_967_295)
  assert api.with_timeout(client, 4_294_967_296)
    == Error(api.TimeoutTooLarge(4_294_967_296))

  let assert Ok(option) = types.input_poll_option("one")
  assert types.input_poll_options([]) == Error(types.NoPollOptions)
  let assert Ok(one_option) = types.input_poll_options(list.repeat(option, 1))
  let assert Ok(five_options) = types.input_poll_options(list.repeat(option, 5))
  let assert Ok(twelve_options) =
    types.input_poll_options(list.repeat(option, 12))
  assert types.input_poll_options(list.repeat(option, 13))
    == Error(types.TooManyPollOptions(13))

  let _regular = api.regular_poll(one_option)
  assert api.quiz_poll(one_option, -1, [], None)
    == Error(api.NegativeCorrectOptionId(-1))
  assert api.quiz_poll(one_option, 1, [], None)
    == Error(api.CorrectOptionIdOutOfRange(id: 1, option_count: 1))
  assert api.quiz_poll(twelve_options, 12, [], None)
    == Error(api.CorrectOptionIdOutOfRange(id: 12, option_count: 12))
  assert api.quiz_poll(one_option, 0, [0], None)
    == Error(api.CorrectOptionIdsNotIncreasing(0, 0))
  assert api.quiz_poll(five_options, 2, [1], None)
    == Error(api.CorrectOptionIdsNotIncreasing(2, 1))
  let assert Ok(_) = api.quiz_poll(five_options, 0, [2, 4], None)
}

pub fn poll_text_invariants_are_structural_test() {
  [
    0,
    31,
    0x00A0,
    0x030A,
    0x0333,
    0x033F,
    0x1680,
    0x180E,
    0x2000,
    0x200B,
    0x200F,
    0x2028,
    0x202F,
    0x205F,
    0x2800,
    0x3000,
    0xFEFF,
    0xFFFC,
    0xE0000,
    0xE007F,
  ]
  |> list.each(fn(value) {
    let assert Ok(codepoint) = string.utf_codepoint(value)
    let telegram_blank_text = string.from_utf_codepoints([codepoint])
    assert types.input_poll_option(telegram_blank_text)
      == Error(types.EmptyPollOptionText)
    assert types.poll_question(telegram_blank_text)
      == Error(types.EmptyPollQuestion)
  })

  let assert Ok(zero_width_space) = string.utf_codepoint(0x200B)
  let telegram_blank_control = string.from_utf_codepoints([zero_width_space])
  let assert Ok(next_line) = string.utf_codepoint(0x0085)
  let telegram_nonblank_pattern_whitespace =
    string.from_utf_codepoints([next_line])

  assert types.input_poll_option("") == Error(types.EmptyPollOptionText)
  assert types.input_poll_option(" \n\t") == Error(types.EmptyPollOptionText)
  assert types.input_poll_option(string.repeat("x", 101))
    == Error(types.PollOptionTextTooLong(101))
  let assert Ok(_) = types.input_poll_option(string.repeat("x", 100))
  let assert Ok(_) = types.input_poll_option("x" <> telegram_blank_control)
  let assert Ok(_) =
    types.input_poll_option(telegram_nonblank_pattern_whitespace)
  assert types.input_poll_option(string.repeat("é", 51))
    == Error(types.PollOptionTextTooLong(102))
  assert types.poll_question("") == Error(types.EmptyPollQuestion)
  assert types.poll_question(" \n\t") == Error(types.EmptyPollQuestion)
  assert types.poll_question(string.repeat("x", 301))
    == Error(types.PollQuestionTooLong(301))
  let assert Ok(_) = types.poll_question(string.repeat("x", 300))
  let assert Ok(_) = types.poll_question("x" <> telegram_blank_control)
  let assert Ok(_) = types.poll_question(telegram_nonblank_pattern_whitespace)
  let assert Ok(option) = types.input_poll_option("one")
  let assert Ok(question) = types.poll_question("Pick one")
  assert types.poll_question_text(question) == "Pick one"
  let assert Ok(_) = types.input_poll_options([option])

  assert api.poll_explanation(string.repeat("x", 201))
    == Error(api.PollExplanationTooLong(201))
  assert api.poll_explanation("one\ntwo\nthree\nfour")
    == Error(api.TooManyPollExplanationLineFeeds(3))
  assert api.poll_explanation("one\r\ntwo\r\nthree\r\nfour")
    == Error(api.TooManyPollExplanationLineFeeds(3))
  let assert Ok(_) = api.poll_explanation(string.repeat("x", 200))
  assert api.poll_description(string.repeat("x", 1025))
    == Error(api.PollDescriptionTooLong(1025))
  let assert Ok(_) = api.poll_description(string.repeat("x", 1024))
}

pub fn set_webhook_uses_the_shared_validated_secret_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_bool))
  let assert Ok(secret) = webhook_secret.new("ABC_secret-123")
  assert https_url.new("http://example.com/hook")
    == Error(https_url.InvalidHttpsUrl)
  assert https_url.new("https:///missing-host")
    == Error(https_url.InvalidHttpsUrl)
  let assert Ok(url) = https_url.new("https://example.com/hook")
  let options =
    api.SetWebhookOptions(
      ..api.default_set_webhook_options(),
      secret_token: Some(secret),
    )

  assert api.set_webhook(client, url, options) == Ok(True)
  let assert Ok(#("setWebhook", api.JsonPayload(fields))) =
    helpers.receive_event(recorder)
  let payload = fields |> json.object |> json.to_string
  assert string.contains(payload, "\"secret_token\":\"ABC_secret-123\"")
}

pub fn set_webhook_certificate_is_an_upload_only_multipart_field_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_bool))
  let assert Ok(url) = https_url.new("https://example.com/hook")
  let assert Ok(secret) = webhook_secret.new("certificate-secret")
  let certificate =
    api.webhook_certificate(
      <<1, 2, 3>>,
      "public.pem",
      Some("application/x-pem-file"),
    )
  let options =
    api.SetWebhookOptions(
      ip_address: Some("203.0.113.10"),
      max_connections: Some(20),
      allowed_updates: Some(["message", "callback_query"]),
      drop_pending_updates: Some(True),
      secret_token: Some(secret),
    )

  assert api.set_webhook_with_certificate(client, url, certificate, options)
    == Ok(True)
  let assert Ok(#("setWebhook", api.MultipartPayload(parts))) =
    helpers.receive_event(recorder)
  assert parts
    == [
      TextPart(name: "url", value: "https://example.com/hook"),
      FilePart(
        name: "certificate",
        filename: "public.pem",
        content_type: Some("application/x-pem-file"),
        body: <<1, 2, 3>>,
      ),
      TextPart(name: "ip_address", value: "203.0.113.10"),
      TextPart(name: "max_connections", value: "20"),
      TextPart(
        name: "allowed_updates",
        value: "[\"message\",\"callback_query\"]",
      ),
      TextPart(name: "drop_pending_updates", value: "true"),
      TextPart(name: "secret_token", value: "certificate-secret"),
    ]
}

pub fn send_message_uses_typed_modern_options_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_message))
  let markup =
    keyboard.reply()
    |> keyboard.reply_text("Continue")
    |> keyboard.reply_markup
  let options =
    api.SendMessageOptions(
      ..api.default_send_message_options(),
      parse_mode: Some(parse_mode.Html),
      direct_messages_topic_id: Some(12),
      delivery: message_options.ephemeral_delivery(
        34,
        Some("callback"),
        Some(7),
      ),
      allow_paid_broadcast: Some(True),
      message_effect_id: Some("effect"),
      link_preview_options: Some(types.LinkPreviewOptions(
        is_disabled: Some(True),
        url: None,
        prefer_small_media: None,
        prefer_large_media: None,
        show_above_text: None,
      )),
      reply_markup: Some(markup),
    )
  let assert Ok(_) =
    api.send_message(client, api.ChatIntId(1), "hello", options)
  let assert Ok(#("sendMessage", api.JsonPayload(fields))) =
    helpers.receive_event(recorder)
  let payload = fields |> json.object |> json.to_string
  assert string.contains(payload, "\"parse_mode\":\"HTML\"")
  assert string.contains(payload, "\"direct_messages_topic_id\":12")
  assert string.contains(payload, "\"receiver_user_id\":34")
  assert string.contains(payload, "\"callback_query_id\":\"callback\"")
  assert string.contains(payload, "\"allow_paid_broadcast\":true")
  assert string.contains(payload, "\"message_effect_id\":\"effect\"")
  assert string.contains(payload, "\"link_preview_options\":")
  assert string.contains(
    payload,
    "\"reply_parameters\":{\"ephemeral_message_id\":7}",
  )
  assert string.contains(payload, "\"keyboard\":")
  assert !string.contains(payload, "reply_to_message_id")
  assert !string.contains(payload, "disable_web_page_preview")
}

pub fn batch_message_ids_are_validated_before_delete_test() {
  assert api.message_ids([]) == Error(api.InvalidMessageIdsCount(0))
  assert api.message_ids([1, 0, 2]) == Error(api.NonPositiveMessageId(0))
  let assert Ok(ids) = api.message_ids([4, 8])
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_bool))
  assert api.delete_messages(client, api.ChatIntId(1), ids) == Ok(True)
  let assert Ok(#("deleteMessages", api.JsonPayload(fields))) =
    helpers.receive_event(recorder)
  assert fields
    |> json.object
    |> json.to_string
    |> string.contains("\"message_ids\":[4,8]")
}

pub fn forward_message_ids_require_strictly_increasing_order_test() {
  assert api.forward_message_ids([]) == Error(api.InvalidMessageIdsCount(0))
  assert api.forward_message_ids([1, 0]) == Error(api.NonPositiveMessageId(0))
  assert api.forward_message_ids([2, 1])
    == Error(api.MessageIdsNotStrictlyIncreasing(
      previous_message_id: 2,
      message_id: 1,
    ))
  assert api.forward_message_ids([1, 1])
    == Error(api.MessageIdsNotStrictlyIncreasing(
      previous_message_id: 1,
      message_id: 1,
    ))

  let assert Ok(ids) = api.forward_message_ids([4, 8])
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_empty_list))
  assert api.forward_messages(
      client,
      api.ChatIntId(1),
      from_chat_id: api.ChatIntId(2),
      message_ids: ids,
    )
    == Ok([])
  let assert Ok(#("forwardMessages", api.JsonPayload(fields))) =
    helpers.receive_event(recorder)
  assert fields
    |> json.object
    |> json.to_string
    |> string.contains("\"message_ids\":[4,8]")
}

pub fn typed_actions_commands_permissions_and_reactions_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_bool))

  let action_options =
    api.SendChatActionOptions(
      business_connection_id: Some("biz"),
      message_thread_id: Some(9),
    )
  assert api.send_chat_action(
      client,
      api.ChatIntId(1),
      chat_action.UploadPhoto,
      options: action_options,
    )
    == Ok(True)
  let assert Ok(#("sendChatAction", api.JsonPayload(action_fields))) =
    helpers.receive_event(recorder)
  let action_payload = action_fields |> json.object |> json.to_string
  assert string.contains(action_payload, "\"action\":\"upload_photo\"")
  assert string.contains(action_payload, "\"business_connection_id\":\"biz\"")

  let command_options =
    api.MyCommandsOptions(
      scope: Some(
        types.BotCommandScopeChat(types.BotCommandScopeChatUsername("@scope")),
      ),
      language_code: Some("en"),
    )
  let assert Ok(command) = types.bot_command("start", "Start", Some(True))
  assert types.bot_command("Start", "bad alphabet", None)
    == Error(types.InvalidBotCommandCharacter)
  assert types.bot_command("", "missing", None)
    == Error(types.InvalidBotCommandLength(0))
  assert types.bot_commands(list.repeat(command, 101))
    == Error(types.TooManyBotCommands(101))
  let assert Ok(commands) = types.bot_commands([command])
  assert api.set_my_commands(client, commands, command_options) == Ok(True)
  let assert Ok(#("setMyCommands", api.JsonPayload(command_fields))) =
    helpers.receive_event(recorder)
  let command_payload = command_fields |> json.object |> json.to_string
  assert string.contains(command_payload, "\"is_ephemeral\":true")
  assert string.contains(command_payload, "\"chat_id\":\"@scope\"")

  let permissions =
    types.ChatPermissions(
      ..types.default_chat_permissions(),
      can_react_to_messages: Some(True),
      can_edit_tag: Some(False),
    )
  assert api.set_chat_permissions(
      client,
      api.ChatIntId(1),
      permissions,
      use_independent_chat_permissions: Some(True),
    )
    == Ok(True)
  let assert Ok(#("setChatPermissions", api.JsonPayload(permission_fields))) =
    helpers.receive_event(recorder)
  let permission_payload = permission_fields |> json.object |> json.to_string
  assert string.contains(permission_payload, "\"can_react_to_messages\":true")
  assert string.contains(permission_payload, "\"can_edit_tag\":false")
  assert string.contains(
    permission_payload,
    "\"use_independent_chat_permissions\":true",
  )

  assert api.set_message_reaction(
      client,
      api.ChatIntId(1),
      7,
      reaction.SetReaction(reaction.Emoji("🔥")),
      None,
    )
    == Ok(True)
  let assert Ok(#("setMessageReaction", api.JsonPayload(reaction_fields))) =
    helpers.receive_event(recorder)
  let reaction_payload = reaction_fields |> json.object |> json.to_string
  assert string.contains(
    reaction_payload,
    "\"reaction\":[{\"type\":\"emoji\",\"emoji\":\"🔥\"}]",
  )

  assert api.set_message_reaction(
      client,
      api.ChatIntId(1),
      7,
      reaction.ClearReaction,
      None,
    )
    == Ok(True)
  let assert Ok(#("setMessageReaction", api.JsonPayload(clear_fields))) =
    helpers.receive_event(recorder)
  let clear_payload = clear_fields |> json.object |> json.to_string
  assert string.contains(clear_payload, "\"reaction\":[]")
}

pub fn send_poll_uses_bound_definition_and_current_fields_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_message))
  let assert Ok(option) = types.input_poll_option("four")
  let assert Ok(question) = types.poll_question("2+2?")
  let assert Ok(options) = types.input_poll_options([option])
  let assert Ok(explanation) = api.poll_explanation("Because four")
  let assert Ok(description) = api.poll_description("Tiny quiz")
  let assert Ok(poll) = api.quiz_poll(options, 0, [], Some(explanation))
  let assert Ok(countries) = api.poll_country_codes(["TH"])
  let assert Ok(schedule) = api.poll_open_for(60)
  let poll_options =
    api.SendPollOptions(
      ..api.default_send_poll_options(),
      allows_revoting: Some(True),
      members_only: Some(False),
      country_codes: Some(countries),
      schedule:,
      description: Some(description),
      reply_parameters: Some(message_options.reply_to_message(4)),
    )
  let assert Ok(_) =
    api.send_poll(client, api.ChatIntId(1), question, poll, poll_options)
  let assert Ok(#("sendPoll", api.JsonPayload(fields))) =
    helpers.receive_event(recorder)
  let payload = fields |> json.object |> json.to_string
  assert string.contains(payload, "\"type\":\"quiz\"")
  assert string.contains(payload, "\"question\":\"2+2?\"")
  assert string.contains(payload, "\"explanation\":\"Because four\"")
  assert string.contains(payload, "\"description\":\"Tiny quiz\"")
  assert !string.contains(payload, "parse_mode")
  assert string.contains(payload, "\"correct_option_ids\":[0]")
  assert string.contains(payload, "\"allows_revoting\":true")
  assert string.contains(payload, "\"members_only\":false")
  assert string.contains(payload, "\"country_codes\":[\"TH\"]")
  assert string.contains(payload, "\"open_period\":60")
  assert string.contains(payload, "\"is_anonymous\":true")
  assert string.contains(payload, "\"allow_adding_options\":false")
  assert !string.contains(payload, "correct_option_id\"")
  assert !string.contains(payload, "reply_to_message_id")

  let assert Ok(regular_question) = types.poll_question("Pick one")
  let assert Ok(_) =
    api.send_poll(
      client,
      api.ChatIntId(1),
      regular_question,
      api.regular_poll(options),
      api.default_send_poll_options(),
    )
  let assert Ok(#("sendPoll", api.JsonPayload(regular_fields))) =
    helpers.receive_event(recorder)
  let regular_payload = regular_fields |> json.object |> json.to_string
  assert string.contains(regular_payload, "\"type\":\"regular\"")
  assert !string.contains(regular_payload, "correct_option_ids")
  assert !string.contains(regular_payload, "explanation")
}

pub fn invite_link_options_reject_invalid_cross_field_states_test() {
  assert api.chat_invite_link_options(
      Some(string.repeat("x", 33)),
      None,
      None,
      None,
    )
    == Error(api.InviteLinkNameTooLong(33))
  assert api.chat_invite_link_options(None, None, Some(0), None)
    == Error(api.InviteLinkMemberLimitOutOfRange(0))
  assert api.chat_invite_link_options(None, Some(0), None, None)
    == Error(api.NonPositiveInviteLinkExpireDate(0))
  assert api.chat_invite_link_options(None, None, Some(100_000), None)
    == Error(api.InviteLinkMemberLimitOutOfRange(100_000))
  assert api.chat_invite_link_options(None, None, Some(10), Some(True))
    == Error(api.JoinRequestWithMemberLimit)

  let assert Ok(options) =
    api.chat_invite_link_options(Some("moderated"), None, None, Some(True))
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_chat_invite_link))
  let assert Ok(_) =
    api.create_chat_invite_link(client, api.ChatIntId(1), options)
  let assert Ok(#("createChatInviteLink", api.JsonPayload(fields))) =
    helpers.receive_event(recorder)
  let payload = fields |> json.object |> json.to_string
  assert string.contains(payload, "\"name\":\"moderated\"")
  assert string.contains(payload, "\"creates_join_request\":true")
  assert !string.contains(payload, "member_limit")
}

pub fn poll_transport_invariants_are_structural_test() {
  assert api.poll_open_for(4) == Error(api.PollOpenPeriodOutOfRange(4))
  assert api.poll_open_for(2_628_001)
    == Error(api.PollOpenPeriodOutOfRange(2_628_001))
  assert api.poll_close_at(0) == Error(api.NonPositivePollCloseDate(0))
  assert api.poll_country_codes(["th"])
    == Error(api.InvalidPollCountryCode("th"))
  assert api.poll_country_codes([
      "AA",
      "AB",
      "AC",
      "AD",
      "AE",
      "AF",
      "AG",
      "AH",
      "AI",
      "AJ",
      "AK",
      "AL",
      "AM",
    ])
    == Error(api.TooManyPollCountryCodes(13))

  let assert Ok(option) = types.input_poll_option("one")
  let assert Ok(options) = types.input_poll_options([option])
  let assert Ok(question) = types.poll_question("Extend me")
  let public_poll = api.public_regular_poll(options, True)
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_message))
  let assert Ok(_) =
    api.send_poll(
      client,
      api.ChatIntId(1),
      question,
      public_poll,
      api.default_send_poll_options(),
    )
  let assert Ok(#("sendPoll", api.JsonPayload(fields))) =
    helpers.receive_event(recorder)
  let payload = fields |> json.object |> json.to_string
  assert string.contains(payload, "\"type\":\"regular\"")
  assert string.contains(payload, "\"is_anonymous\":false")
  assert string.contains(payload, "\"allow_adding_options\":true")
}

pub fn send_dice_only_encodes_supported_emoji_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_message))

  let assert Ok(_) =
    api.send_dice(client, api.ChatIntId(1), Some(api.SlotMachine))
  let assert Ok(#("sendDice", api.JsonPayload(fields))) =
    helpers.receive_event(recorder)
  assert fields |> json.object |> json.to_string |> string.contains("\"🎰\"")
}

pub fn endpoint_specific_media_options_and_thumbnail_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_message))
  let thumb = thumbnail.new(<<1, 2, 3>>, "thumb.jpg", Some("image/jpeg"))
  let document_options =
    media_options.SendDocumentOptions(
      ..media_options.default_send_document_options(),
      thumbnail: Some(thumb),
      caption: Some("doc"),
      parse_mode: Some(parse_mode.Html),
      direct_messages_topic_id: Some(10),
      delivery: message_options.ephemeral_delivery(11, Some("cb"), Some(5)),
      allow_paid_broadcast: Some(True),
      message_effect_id: Some("fx"),
    )
  let assert Ok(_) =
    api.send_document(
      client,
      api.ChatIntId(1),
      input_file.FileId("document-id"),
      document_options,
    )
  let assert Ok(#("sendDocument", api.MultipartPayload(document_parts))) =
    helpers.receive_event(recorder)
  assert file_part_names(document_parts) == ["thumbnail"]
  assert text_part(document_parts, "parse_mode") == Ok("HTML")
  assert text_part(document_parts, "direct_messages_topic_id") == Ok("10")
  assert text_part(document_parts, "receiver_user_id") == Ok("11")
  assert text_part(document_parts, "callback_query_id") == Ok("cb")
  assert text_part(document_parts, "allow_paid_broadcast") == Ok("true")
  let assert Ok(reply_json) = text_part(document_parts, "reply_parameters")
  assert string.contains(reply_json, "\"ephemeral_message_id\":5")

  let video_options =
    media_options.SendVideoOptions(
      ..media_options.default_send_video_options(),
      duration: Some(3),
      width: Some(640),
      height: Some(360),
    )
  let assert Ok(_) =
    api.send_video(
      client,
      api.ChatIntId(1),
      input_file.FileId("video-id"),
      video_options,
    )
  let assert Ok(#("sendVideo", api.MultipartPayload(video_parts))) =
    helpers.receive_event(recorder)
  assert text_part(video_parts, "duration") == Ok("3")
  assert text_part(video_parts, "width") == Ok("640")
  assert text_part(video_parts, "height") == Ok("360")

  let assert Ok(video_note) = input_file.file_id_source("video-note-id")
  let assert Ok(_) =
    api.send_video_note(
      client,
      api.ChatIntId(1),
      video_note,
      media_options.default_send_video_note_options(),
    )
  let assert Ok(#("sendVideoNote", api.MultipartPayload(video_note_parts))) =
    helpers.receive_event(recorder)
  assert text_part(video_note_parts, "video_note") == Ok("video-note-id")

  let sticker_options =
    media_options.SendStickerOptions(
      ..media_options.default_send_sticker_options(),
      emoji: Some("⭐"),
    )
  let assert Ok(_) =
    api.send_sticker(
      client,
      api.ChatIntId(1),
      input_file.FileId("sticker-id"),
      sticker_options,
    )
  let assert Ok(#("sendSticker", api.MultipartPayload(sticker_parts))) =
    helpers.receive_event(recorder)
  assert text_part(sticker_parts, "emoji") == Ok("⭐")
  assert text_part(sticker_parts, "caption") == Error(Nil)
}

pub fn json_parse_errors_keep_domain_context_test() {
  case api.parse_update("{}") {
    Error(api.JsonParseError(kind: api.UpdateJson, ..)) -> Nil
    _ -> panic as "expected UpdateJson parse error"
  }
  case api.parse_callback_query("{}") {
    Error(api.JsonParseError(kind: api.CallbackQueryJson, ..)) -> Nil
    _ -> panic as "expected CallbackQueryJson parse error"
  }
}

pub fn inline_shipping_and_checkout_answers_are_typed_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_bool))
  let result =
    iqr.article(
      "id",
      "Title",
      iqr.InputTextMessageContent(
        message_text: "Body",
        parse_mode: Some(parse_mode.Html),
        link_preview_options: None,
      ),
      description: None,
      url: None,
      thumbnail_url: None,
      reply_markup: None,
    )
  let assert Ok(results) = iqr.results([result])
  assert api.answer_inline_query(
      client,
      "query",
      results:,
      cache_time: None,
      is_personal: None,
      next_offset: None,
    )
    == Ok(True)
  let assert Ok(#("answerInlineQuery", api.JsonPayload(inline_fields))) =
    helpers.receive_event(recorder)
  let inline_payload = inline_fields |> json.object |> json.to_string
  assert string.contains(inline_payload, "\"type\":\"article\"")

  let shipping =
    api.ShippingOptions([
      api.ShippingOption(id: "fast", title: "Fast", prices: [
        api.LabeledPrice("Delivery", 500),
      ]),
    ])
  assert api.answer_shipping_query(client, "shipping", shipping) == Ok(True)
  let assert Ok(#("answerShippingQuery", api.JsonPayload(shipping_fields))) =
    helpers.receive_event(recorder)
  let shipping_payload = shipping_fields |> json.object |> json.to_string
  assert string.contains(shipping_payload, "\"ok\":true")
  assert string.contains(shipping_payload, "\"shipping_options\":[")
  assert !string.contains(shipping_payload, "error_message")

  assert api.answer_pre_checkout_query(
      client,
      "checkout",
      api.RejectPreCheckout("declined"),
    )
    == Ok(True)
  let assert Ok(#("answerPreCheckoutQuery", api.JsonPayload(checkout_fields))) =
    helpers.receive_event(recorder)
  let checkout_payload = checkout_fields |> json.object |> json.to_string
  assert string.contains(checkout_payload, "\"ok\":false")
  assert string.contains(checkout_payload, "\"error_message\":\"declined\"")
}

pub fn guest_query_answer_is_typed_end_to_end_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_sent_guest_message))
  let result =
    iqr.article(
      "guest-result",
      "Answer",
      iqr.InputTextMessageContent("Hello", None, None),
      None,
      None,
      None,
      None,
    )

  assert api.answer_guest_query(client, "guest-query-1", result)
    == Ok(types.SentGuestMessage("guest-inline-1"))
  let assert Ok(#("answerGuestQuery", api.JsonPayload(fields))) =
    helpers.receive_event(recorder)
  let payload = fields |> json.object |> json.to_string
  assert string.contains(payload, "\"guest_query_id\":\"guest-query-1\"")
  assert string.contains(payload, "\"result\":{\"type\":\"article\"")
}

pub fn ephemeral_and_join_query_flows_are_typed_test() {
  let recorder: process.Subject(#(String, api.Payload)) = process.new_subject()
  let client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_bool))
  let target = api.ephemeral_message_target(api.ChatIntId(-100), 7, 41)

  assert api.edit_ephemeral_message_text(
      client,
      target,
      "edited",
      api.EditEphemeralTextOptions(
        ..api.default_edit_ephemeral_text_options(),
        parse_mode: Some(parse_mode.Html),
      ),
    )
    == Ok(True)
  let assert Ok(#("editEphemeralMessageText", api.JsonPayload(text_fields))) =
    helpers.receive_event(recorder)
  let text_payload = text_fields |> json.object |> json.to_string
  assert string.contains(text_payload, "\"chat_id\":-100")
  assert string.contains(text_payload, "\"receiver_user_id\":7")
  assert string.contains(text_payload, "\"ephemeral_message_id\":41")
  assert string.contains(text_payload, "\"parse_mode\":\"HTML\"")

  assert api.edit_ephemeral_message_caption(
      client,
      target,
      Some("caption"),
      api.default_edit_ephemeral_caption_options(),
    )
    == Ok(True)
  let assert Ok(#("editEphemeralMessageCaption", _)) =
    helpers.receive_event(recorder)
  let media =
    input_media.InputMediaPhoto(
      media: input_file.from_file_id("existing-photo"),
      caption: Some("updated"),
      parse_mode: None,
      has_spoiler: None,
      show_caption_above_media: None,
    )
  let assert Ok(media) = input_media.reuse_only_media(media)
  assert api.edit_ephemeral_message_media(client, target, media, None)
    == Ok(True)
  let assert Ok(#("editEphemeralMessageMedia", api.JsonPayload(media_fields))) =
    helpers.receive_event(recorder)
  let media_payload = media_fields |> json.object |> json.to_string
  assert string.contains(media_payload, "\"media\":{\"type\":\"photo\"")
  assert string.contains(media_payload, "\"media\":\"existing-photo\"")
  assert api.edit_ephemeral_message_reply_markup(client, target, None)
    == Ok(True)
  let assert Ok(#("editEphemeralMessageReplyMarkup", _)) =
    helpers.receive_event(recorder)
  assert api.delete_ephemeral_message(client, target) == Ok(True)
  let assert Ok(#("deleteEphemeralMessage", _)) =
    helpers.receive_event(recorder)

  assert api.answer_chat_join_request_query(
      client,
      "join-query",
      api.QueueJoinRequestQuery,
    )
    == Ok(True)
  let assert Ok(#("answerChatJoinRequestQuery", api.JsonPayload(join_fields))) =
    helpers.receive_event(recorder)
  assert join_fields
    |> json.object
    |> json.to_string
    |> string.contains("\"result\":\"queue\"")
  let assert Ok(join_url) = https_url.new("https://example.com/join")
  assert api.send_chat_join_request_web_app(client, "join-query", join_url)
    == Ok(True)
  let assert Ok(#("sendChatJoinRequestWebApp", _)) =
    helpers.receive_event(recorder)

  let admins_client =
    api.new("token")
    |> api.with_transformer(recording_response(recorder, ok_empty_list))
  assert api.get_chat_administrators_with_options(
      admins_client,
      api.ChatIntId(-100),
      Some(True),
    )
    == Ok([])
  let assert Ok(#("getChatAdministrators", api.JsonPayload(admin_fields))) =
    helpers.receive_event(recorder)
  assert admin_fields
    |> json.object
    |> json.to_string
    |> string.contains("\"return_bots\":true")
}

fn text_part(parts: List(Part), name: String) -> Result(String, Nil) {
  case parts {
    [] -> Error(Nil)
    [TextPart(name: part_name, value:), ..rest] ->
      case part_name == name {
        True -> Ok(value)
        False -> text_part(rest, name)
      }
    [_, ..rest] -> text_part(rest, name)
  }
}

fn file_part_names(parts: List(Part)) -> List(String) {
  parts
  |> list.filter_map(fn(part) {
    case part {
      FilePart(name:, ..) -> Ok(name)
      TextPart(..) -> Error(Nil)
    }
  })
}
