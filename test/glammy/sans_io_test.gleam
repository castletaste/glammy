import glammy/api
import glammy/error
import glammy/multipart.{FilePart, TextPart}
import glammy/types
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/option
import gleam/string

pub fn api_debug_output_does_not_reveal_token_test() {
  let token = "123456:debug-must-not-leak"
  let rendered = string.inspect(api.new(token))
  assert !string.contains(rendered, token)
}

pub fn custom_transport_builds_standard_json_request_test() {
  let client =
    api.new("123456:test-secret")
    |> api.with_base_url("https://transport.example")
  let call =
    api.prepare_json_call(
      "setWebhook",
      [#("url", json.string("https://bot.example/hook"))],
      decode.bool,
    )

  let assert Ok(req) = api.to_http_request(client, call)
  assert req.method == http.Post
  assert req.host == "transport.example"
  assert req.path == "/bot123456:test-secret/setWebhook"
  assert request.get_header(req, "content-type") == Ok("application/json")
  assert request.get_header(req, "accept") == Ok("application/json")
  let assert Ok(body) = bit_array.to_string(req.body)
  assert body == "{\"url\":\"https://bot.example/hook\"}"
}

pub fn custom_transport_builds_standard_multipart_request_test() {
  let client =
    api.new("test-token")
    |> api.with_base_url("https://transport.example")
  let call =
    api.prepare_multipart_call(
      "sendDocument",
      [
        TextPart(name: "chat_id", value: "42"),
        FilePart(
          name: "document",
          filename: "hello.txt",
          content_type: option.Some("text/plain"),
          body: <<"hello":utf8>>,
        ),
      ],
      decode.bool,
    )

  let assert Ok(req) = api.to_http_request(client, call)
  let assert Ok(content_type) = request.get_header(req, "content-type")
  assert string.starts_with(content_type, "multipart/form-data; boundary=")
  let assert Ok(body) = bit_array.to_string(req.body)
  assert string.contains(body, "name=\"chat_id\"")
  assert string.contains(body, "name=\"document\"; filename=\"hello.txt\"")
  assert string.contains(body, "hello")
}

pub fn matching_prepared_call_decodes_custom_transport_response_test() {
  let call = api.prepare_json_call("getMe", [], types.user_decoder())
  let http_response =
    response.new(200)
    |> response.set_body(<<
      "{\"ok\":true,\"result\":{\"id\":7,\"is_bot\":true,\"first_name\":\"Gleam Bot\"}}":utf8,
    >>)

  let assert Ok(user) = api.from_http_response(call, http_response)
  assert user.id == 7
  assert user.first_name == "Gleam Bot"
}

pub fn custom_transport_preserves_http_status_error_test() {
  let call = api.prepare_json_call("getMe", [], types.user_decoder())
  let http_response =
    response.new(503)
    |> response.set_body(<<"upstream unavailable":utf8>>)

  case api.from_http_response(call, http_response) {
    Error(error.HttpStatusError(
      method: "getMe",
      status: 503,
      body: "upstream unavailable",
    )) -> Nil
    _ -> panic as "expected HttpStatusError"
  }
}

pub fn custom_transport_preserves_telegram_error_envelope_test() {
  let call = api.prepare_json_call("getMe", [], types.user_decoder())
  let http_response =
    response.new(429)
    |> response.set_body(<<
      "{\"ok\":false,\"error_code\":429,\"description\":\"retry later\"}":utf8,
    >>)

  case api.from_http_response(call, http_response) {
    Error(error.ApiError(
      method: "getMe",
      error_code: 429,
      description: "retry later",
      ..,
    )) -> Nil
    _ -> panic as "expected ApiError"
  }
}

pub fn prepared_call_keeps_decoder_bound_to_method_test() {
  let call = api.prepare_json_call("getMe", [], types.user_decoder())
  let http_response =
    response.new(200)
    |> response.set_body(<<"{\"ok\":true,\"result\":true}":utf8>>)

  case api.from_http_response(call, http_response) {
    Error(error.DecodeError(method: "getMe", ..)) -> Nil
    _ -> panic as "expected method-specific DecodeError"
  }
}
