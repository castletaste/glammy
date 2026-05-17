//// Tests mirroring grammY's `test/core/client.test.ts`. We use a
//// stubbing transformer to intercept calls before the HTTP layer runs.

import glammy/api
import glammy/error

/// Build a transformer that always returns the given body string,
/// regardless of method/payload. Useful for end-to-end testing the
/// envelope decoder without hitting the network.
fn fake_response(body: String) -> api.Transformer {
  fn(_next, _method, _payload) { Ok(body) }
}

pub fn returns_payloads_test() {
  let api_ =
    api.new("secret-token")
    |> api.with_transformer(fake_response(
      "{\"ok\":true,\"result\":{\"id\":1,\"is_bot\":true,\"first_name\":\"BotName\"}}",
    ))
  let assert Ok(user) = api.get_me(api_)
  assert user.id == 1
  assert user.is_bot == True
  assert user.first_name == "BotName"
}

pub fn throws_errors_test() {
  let api_ =
    api.new("secret-token")
    |> api.with_transformer(fake_response(
      "{\"ok\":false,\"error_code\":42,\"description\":\"evil\"}",
    ))
  let assert Error(err) = api.get_me(api_)
  case err {
    error.ApiError(method:, error_code:, description:, ..) -> {
      assert method == "getMe"
      assert error_code == 42
      assert description == "evil"
    }
    _ -> panic as "expected ApiError"
  }
  assert error.describe(err) == "Call to 'getMe' failed! (42: evil)"
}

pub fn decodes_get_me_full_user_test() {
  let api_ =
    api.new("token")
    |> api.with_transformer(fake_response(
      "{\"ok\":true,\"result\":{\"id\":42,\"is_bot\":true,\"first_name\":\"Bot\",\"username\":\"bot_username\",\"can_join_groups\":true}}",
    ))
  let assert Ok(user) = api.get_me(api_)
  assert user.username == option.Some("bot_username")
  assert user.can_join_groups == option.Some(True)
}

import gleam/option
