import glammy/api
import glammy/parse_mode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}

const receive_timeout_ms = 1000

type CapturedCall {
  CapturedCall(method: String, payload: api.Payload)
}

fn capturing_api(calls: process.Subject(CapturedCall)) -> api.Api {
  api.new("0:test")
  |> api.with_transformer(fn(_, method, payload) {
    process.send(calls, CapturedCall(method:, payload:))
    Ok("{\"ok\":true,\"result\":true}")
  })
}

fn payload_json(payload: api.Payload) -> String {
  case payload {
    api.JsonPayload(fields) -> json.object(fields) |> json.to_string
    api.MultipartPayload(_) -> panic as "expected JSON payload"
  }
}

pub fn send_message_draft_encodes_current_bot_api_fields_test() {
  let calls = process.new_subject()
  let client = capturing_api(calls)
  let options =
    api.SendMessageDraftOptions(
      message_thread_id: Some(17),
      parse_mode: Some(parse_mode.MarkdownV2),
    )

  assert api.send_message_draft(client, 42, 9001, "partial", options:)
    == Ok(True)
  let assert Ok(CapturedCall(method:, payload:)) =
    process.receive(calls, receive_timeout_ms)

  assert method == "sendMessageDraft"
  assert payload_json(payload)
    == "{\"chat_id\":42,\"draft_id\":9001,\"text\":\"partial\",\"message_thread_id\":17,\"parse_mode\":\"MarkdownV2\"}"
}

pub fn send_message_draft_preserves_empty_text_and_omits_defaults_test() {
  let calls = process.new_subject()
  let client = capturing_api(calls)

  assert api.send_message_draft(
      client,
      42,
      9002,
      "",
      options: api.default_send_message_draft_options(),
    )
    == Ok(True)
  let assert Ok(CapturedCall(method:, payload:)) =
    process.receive(calls, receive_timeout_ms)

  assert method == "sendMessageDraft"
  assert payload_json(payload)
    == "{\"chat_id\":42,\"draft_id\":9002,\"text\":\"\"}"
}

pub fn send_message_draft_default_options_are_empty_test() {
  let options = api.default_send_message_draft_options()
  assert options.message_thread_id == None
  assert options.parse_mode == None
}
