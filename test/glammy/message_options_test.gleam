import glammy/message_options
import glammy/parse_mode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub fn reply_and_delivery_variants_encode_only_legal_fields_test() {
  let same_chat =
    message_options.SameChatReplyParameters(
      message_id: 1,
      allow_sending_without_reply: Some(True),
      quote: Some(message_options.ReplyQuote(
        text: "hello",
        parse_mode: Some(parse_mode.Html),
        position: Some(0),
      )),
      checklist_task_id: None,
      poll_option_id: None,
    )
    |> message_options.reply_parameters_to_json
    |> json.to_string
  assert string.contains(same_chat, "\"message_id\":1")
  assert string.contains(same_chat, "\"allow_sending_without_reply\":true")
  assert !string.contains(same_chat, "chat_id")

  let cross_chat =
    message_options.reply_to_message_in_chat(
      2,
      message_options.ReplyChatUsername("@source"),
    )
    |> message_options.reply_parameters_to_json
    |> json.to_string
  assert string.contains(cross_chat, "\"message_id\":2")
  assert string.contains(cross_chat, "\"chat_id\":\"@source\"")
  assert !string.contains(cross_chat, "allow_sending_without_reply")

  let ephemeral =
    message_options.ephemeral_delivery(9, Some("callback"), Some(3))
    |> message_options.delivery_json_fields
    |> json.object
    |> json.to_string
  assert string.contains(ephemeral, "\"receiver_user_id\":9")
  assert string.contains(ephemeral, "\"callback_query_id\":\"callback\"")
  assert string.contains(
    ephemeral,
    "\"reply_parameters\":{\"ephemeral_message_id\":3}",
  )

  let regular =
    message_options.reply_delivery(message_options.reply_to_message(4))
    |> message_options.delivery_json_fields
    |> json.object
    |> json.to_string
  assert regular == "{\"reply_parameters\":{\"message_id\":4}}"
  assert message_options.standard_delivery()
    |> message_options.delivery_json_fields
    |> list.is_empty
}
