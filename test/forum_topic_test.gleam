import glammy/api
import glammy/types
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}

pub fn forum_topic_api_payloads_test() {
  let calls = process.new_subject()
  let client = capturing_api(calls)

  let assert Ok(created) =
    api.create_forum_topic(
      client,
      api.ChatIntId(-100),
      "New chat",
      Some(7_322_096),
      None,
    )
  assert created.message_thread_id == 77
  assert created.is_name_implicit == Some(True)
  assert receive_call(calls)
    == #(
      "createForumTopic",
      "{\"chat_id\":-100,\"name\":\"New chat\",\"icon_color\":7322096}",
    )

  assert api.edit_forum_topic(
      client,
      api.ChatIntId(-100),
      77,
      Some("Roadmap"),
      None,
    )
    == Ok(True)
  assert receive_call(calls)
    == #(
      "editForumTopic",
      "{\"chat_id\":-100,\"message_thread_id\":77,\"name\":\"Roadmap\"}",
    )

  assert api.close_forum_topic(client, api.ChatIntId(-100), 77) == Ok(True)
  assert receive_call(calls)
    == #("closeForumTopic", "{\"chat_id\":-100,\"message_thread_id\":77}")

  assert api.reopen_forum_topic(client, api.ChatIntId(-100), 77) == Ok(True)
  assert receive_call(calls)
    == #("reopenForumTopic", "{\"chat_id\":-100,\"message_thread_id\":77}")
}

pub fn general_forum_topic_uses_special_endpoints_test() {
  let calls = process.new_subject()
  let client = capturing_api(calls)

  assert api.edit_general_forum_topic(
      client,
      api.ChatIntId(-100),
      "General roadmap",
    )
    == Ok(True)
  assert receive_call(calls)
    == #(
      "editGeneralForumTopic",
      "{\"chat_id\":-100,\"name\":\"General roadmap\"}",
    )

  assert api.close_general_forum_topic(client, api.ChatIntId(-100)) == Ok(True)
  assert receive_call(calls)
    == #("closeGeneralForumTopic", "{\"chat_id\":-100}")

  assert api.reopen_general_forum_topic(client, api.ChatIntId(-100)) == Ok(True)
  assert receive_call(calls)
    == #("reopenGeneralForumTopic", "{\"chat_id\":-100}")
}

pub fn message_decoder_surfaces_all_forum_topic_service_updates_test() {
  let body =
    "{\"update_id\":1,\"message\":{\"message_id\":1,\"message_thread_id\":77,\"date\":0,\"chat\":{\"id\":-100,\"type\":\"supergroup\"},"
    <> "\"forum_topic_created\":{\"name\":\"New chat\",\"icon_color\":7322096,\"is_name_implicit\":true},"
    <> "\"forum_topic_edited\":{\"name\":\"Roadmap\",\"icon_custom_emoji_id\":\"emoji\"},"
    <> "\"forum_topic_closed\":{},\"forum_topic_reopened\":{},"
    <> "\"general_forum_topic_hidden\":{},\"general_forum_topic_unhidden\":{}}}"
  let assert Ok(types.Update(kind: types.MessageUpdate(message), ..)) =
    json.parse(body, types.update_decoder())

  assert message.message_thread_id == Some(77)
  assert message.forum_topic_created
    == Some(types.ForumTopicCreated(
      name: "New chat",
      icon_color: 7_322_096,
      icon_custom_emoji_id: None,
      is_name_implicit: Some(True),
    ))
  assert message.forum_topic_edited
    == Some(types.ForumTopicEdited(
      name: Some("Roadmap"),
      icon_custom_emoji_id: Some("emoji"),
    ))
  assert message.forum_topic_closed == Some(types.ForumTopicClosed)
  assert message.forum_topic_reopened == Some(types.ForumTopicReopened)
  assert message.general_forum_topic_hidden
    == Some(types.GeneralForumTopicHidden)
  assert message.general_forum_topic_unhidden
    == Some(types.GeneralForumTopicUnhidden)
}

fn capturing_api(calls: process.Subject(#(String, String))) -> api.Api {
  api.new("0:test")
  |> api.with_transformer(fn(_, method, payload) {
    let encoded = case payload {
      api.JsonPayload(fields) -> json.object(fields) |> json.to_string
      api.MultipartPayload(_) -> "multipart"
    }
    process.send(calls, #(method, encoded))
    case method {
      "createForumTopic" ->
        Ok(
          "{\"ok\":true,\"result\":{\"message_thread_id\":77,\"name\":\"New chat\",\"icon_color\":7322096,\"is_name_implicit\":true}}",
        )
      _ -> Ok("{\"ok\":true,\"result\":true}")
    }
  })
}

fn receive_call(
  calls: process.Subject(#(String, String)),
) -> #(String, String) {
  let assert Ok(call) = process.receive(calls, 100)
  call
}
