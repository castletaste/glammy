//// Tests mirroring the portable subset of grammY's
//// `test/convenience/webhook.test.ts`. Many grammY tests cover JS-only
//// concerns (framework adapters, async timeouts, webhook reply
//// envelope, concurrent dispatch) — none of those apply here; glammy
//// is framework-agnostic and synchronous.

import glammy/api
import glammy/bot
import glammy/composer
import glammy/context
import glammy/webhook
import gleam/erlang/process

const message_update_body = "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"hi\"}}"

const update_with_unknown_fields = "{\"update_id\":2,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"hi\"},\"future_field\":{\"unknown\":42}}"

fn make_bot() -> bot.Bot {
  bot.new(api.new("0:test"), composer.new())
}

fn make_bot_with(comp: composer.Composer) -> bot.Bot {
  bot.new(api.new("0:test"), comp)
}

// =====================================================================
//                    Basic functionality
// =====================================================================

pub fn processes_updates_successfully_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(ctx) {
      let _ = context.message_text(ctx)
      process.send(recorder, "dispatched")
      Nil
    })
  let bot_ = make_bot_with(comp)

  assert webhook.handle(bot_, message_update_body) == Ok(Nil)
  assert process.receive(recorder, 50) == Ok("dispatched")
}

pub fn ignores_unknown_fields_in_body_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_ctx) { process.send(recorder, "dispatched") })
  let bot_ = make_bot_with(comp)

  assert webhook.handle(bot_, update_with_unknown_fields) == Ok(Nil)
  assert process.receive(recorder, 50) == Ok("dispatched")
}

pub fn rejects_invalid_body_test() {
  let result = webhook.handle(make_bot(), "not-json")
  case result {
    Error(webhook.ParseError(_)) -> Nil
    _ -> panic as "expected ParseError"
  }
}

pub fn rejects_empty_body_test() {
  let result = webhook.handle(make_bot(), "")
  case result {
    Error(webhook.ParseError(_)) -> Nil
    _ -> panic as "expected ParseError for empty body"
  }
}

pub fn rejects_body_without_update_id_test() {
  let result = webhook.handle(make_bot(), "{\"message\":{}}")
  case result {
    Error(webhook.ParseError(_)) -> Nil
    _ -> panic as "expected ParseError when update_id missing"
  }
}

// =====================================================================
//                  Secret token validation
// =====================================================================

pub fn accepts_requests_with_correct_secret_token_test() {
  assert webhook.handle_with_secret(
      make_bot(),
      message_update_body,
      "secret-token-123",
      "secret-token-123",
    )
    == Ok(Nil)
}

pub fn rejects_requests_with_wrong_secret_token_test() {
  let result =
    webhook.handle_with_secret(
      make_bot(),
      message_update_body,
      "wrong",
      "right",
    )
  assert result == Error(webhook.BadSecretToken)
}

pub fn handle_without_secret_works_without_header_test() {
  // `handle` (without `_with_secret`) doesn't even look at headers
  assert webhook.handle(make_bot(), message_update_body) == Ok(Nil)
}

pub fn rejects_when_secret_is_empty_but_header_isnt_test() {
  let result =
    webhook.handle_with_secret(make_bot(), message_update_body, "x", "")
  assert result == Error(webhook.BadSecretToken)
}

pub fn rejects_when_header_is_empty_but_secret_isnt_test() {
  let result =
    webhook.handle_with_secret(make_bot(), message_update_body, "", "x")
  assert result == Error(webhook.BadSecretToken)
}

// =====================================================================
//                     verify_secret unit tests
// =====================================================================

pub fn verify_secret_matches_equal_strings_test() {
  assert webhook.verify_secret("a", "a") == True
}

pub fn verify_secret_rejects_unequal_strings_test() {
  assert webhook.verify_secret("a", "b") == False
}

pub fn verify_secret_rejects_different_lengths_test() {
  assert webhook.verify_secret("abc", "abcd") == False
  assert webhook.verify_secret("abcd", "abc") == False
}

pub fn verify_secret_empty_strings_equal_test() {
  assert webhook.verify_secret("", "") == True
}

pub fn verify_secret_handles_unicode_test() {
  assert webhook.verify_secret("привет", "привет") == True
  assert webhook.verify_secret("привет", "Привет") == False
}

pub fn verify_secret_typical_telegram_token_test() {
  let token = "ABCdef-0123456789-XYZ"
  assert webhook.verify_secret(token, token) == True
  assert webhook.verify_secret(token, token <> "x") == False
  assert webhook.verify_secret(token <> "x", token) == False
}
