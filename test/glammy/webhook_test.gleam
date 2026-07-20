//// Tests mirroring the portable subset of grammY's
//// `test/convenience/webhook.test.ts`. Many grammY tests cover JS-only
//// concerns (framework adapters, async timeouts, webhook reply
//// envelope, concurrent dispatch) — none of those apply here; glammy
//// is framework-agnostic and synchronous.

import glammy/api
import glammy/bot
import glammy/composer
import glammy/context
import glammy/helpers.{dummy_api, receive_event}
import glammy/webhook
import glammy/webhook_secret
import gleam/erlang/process
import gleam/option.{Some}
import gleam/string

const message_update_body = "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"hi\"}}"

const update_with_unknown_fields = "{\"update_id\":2,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"hi\"},\"future_field\":{\"unknown\":42}}"

fn make_bot() -> bot.Bot {
  bot.new(dummy_api(), composer.new())
}

fn make_bot_with(comp: composer.Composer) -> bot.Bot {
  bot.new(dummy_api(), comp)
}

fn secret(value: String) -> webhook_secret.WebhookSecret {
  let assert Ok(secret) = webhook_secret.new(value)
  secret
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
  assert receive_event(recorder) == Ok("dispatched")
}

pub fn ignores_unknown_fields_in_body_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_ctx) { process.send(recorder, "dispatched") })
  let bot_ = make_bot_with(comp)

  assert webhook.handle(bot_, update_with_unknown_fields) == Ok(Nil)
  assert receive_event(recorder) == Ok("dispatched")
}

pub fn isolated_handler_dispatches_successfully_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_) { process.send(recorder, "isolated") })

  assert webhook.handle_isolated(
      make_bot_with(comp),
      message_update_body,
      timeout_ms: helpers.async_timeout_ms,
    )
    == Ok(Nil)
  assert receive_event(recorder) == Ok("isolated")
}

pub fn isolated_handler_panic_is_typed_error_test() {
  let comp =
    composer.new()
    |> composer.handle(fn(_) { panic as "webhook handler failed" })

  case
    webhook.handle_isolated(
      make_bot_with(comp),
      message_update_body,
      timeout_ms: helpers.async_timeout_ms,
    )
  {
    Error(webhook.HandlerFailed(bot.HandlerCrashed(update_id: 1, reason: _))) ->
      Nil
    _ -> panic as "expected typed HandlerCrashed"
  }
}

pub fn isolated_handler_timeout_is_typed_error_test() {
  let comp =
    composer.new()
    |> composer.handle(fn(_) { process.sleep_forever() })

  assert webhook.handle_isolated(
      make_bot_with(comp),
      message_update_body,
      timeout_ms: 5,
    )
    == Error(
      webhook.HandlerFailed(bot.HandlerTimedOut(update_id: 1, timeout_ms: 5)),
    )
}

pub fn synchronous_gate_failure_is_retriable_webhook_error_test() {
  let comp =
    composer.new()
    |> composer.handle(fn(_) { panic as "gate failure must stop dispatch" })
  let bot_ =
    make_bot_with(comp)
    |> bot.with_update_gate(fn(_) {
      Error(bot.UpdateGateError(code: "journal", message: "store unavailable"))
    })

  assert webhook.handle(bot_, message_update_body)
    == Error(
      webhook.HandlerFailed(bot.UpdateGateFailed(
        update_id: 1,
        code: "journal",
        message: "store unavailable",
      )),
    )
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
      header_value: "secret-token-123",
      expected_secret: secret("secret-token-123"),
    )
    == Ok(Nil)
}

pub fn rejects_requests_with_wrong_secret_token_test() {
  let result =
    webhook.handle_with_secret(
      make_bot(),
      message_update_body,
      header_value: "wrong",
      expected_secret: secret("right"),
    )
  assert result == Error(webhook.BadSecretToken)
}

pub fn isolated_with_secret_rejects_before_dispatch_test() {
  let comp =
    composer.new()
    |> composer.handle(fn(_) { panic as "must not dispatch" })
  assert webhook.handle_isolated_with_secret(
      make_bot_with(comp),
      message_update_body,
      header_value: "wrong",
      expected_secret: secret("right"),
      timeout_ms: helpers.async_timeout_ms,
    )
    == Error(webhook.BadSecretToken)
}

pub fn handle_without_secret_works_without_header_test() {
  // `handle` (without `_with_secret`) doesn't even look at headers
  assert webhook.handle(make_bot(), message_update_body) == Ok(Nil)
}

pub fn configured_secret_cannot_be_empty_test() {
  assert webhook_secret.new("") == Error(webhook_secret.EmptyWebhookSecret)
}

pub fn configured_secret_debug_output_does_not_leak_test() {
  let raw_secret = "debug-must-not-leak_123"
  let configured = secret(raw_secret)
  let options =
    api.SetWebhookOptions(
      ..api.default_set_webhook_options(),
      secret_token: Some(configured),
    )
  assert !string.contains(string.inspect(configured), raw_secret)
  assert !string.contains(string.inspect(options), raw_secret)
}

pub fn rejects_when_header_is_empty_but_secret_isnt_test() {
  let result =
    webhook.handle_with_secret(
      make_bot(),
      message_update_body,
      header_value: "",
      expected_secret: secret("x"),
    )
  assert result == Error(webhook.BadSecretToken)
}

// =====================================================================
//                     verify_secret unit tests
// =====================================================================

pub fn verify_secret_matches_equal_strings_test() {
  assert webhook.verify_secret("a", secret("a")) == True
}

pub fn verify_secret_rejects_unequal_strings_test() {
  assert webhook.verify_secret("a", secret("b")) == False
}

pub fn verify_secret_rejects_different_lengths_test() {
  assert webhook.verify_secret("abc", secret("abcd")) == False
  assert webhook.verify_secret("abcd", secret("abc")) == False
}

pub fn verify_secret_rejects_empty_header_test() {
  assert webhook.verify_secret("", secret("configured")) == False
}

pub fn secret_validation_rejects_overlong_values_test() {
  let overlong = string.repeat("a", 257)
  assert webhook_secret.new(overlong)
    == Error(webhook_secret.WebhookSecretTooLong(257))
  assert webhook.verify_secret(overlong, secret("configured")) == False
}

pub fn secret_validation_rejects_non_token_characters_test() {
  assert webhook_secret.new("привет")
    == Error(webhook_secret.InvalidWebhookSecretCharacter("п"))
  assert webhook_secret.new("has space")
    == Error(webhook_secret.InvalidWebhookSecretCharacter(" "))
  assert webhook_secret.new("bad!")
    == Error(webhook_secret.InvalidWebhookSecretCharacter("!"))
  assert webhook.verify_secret("привет", secret("configured")) == False
}

pub fn verify_secret_typical_telegram_token_test() {
  let token = "ABCdef-0123456789-XYZ"
  assert webhook.verify_secret(token, secret(token)) == True
  assert webhook.verify_secret(token, secret(token <> "x")) == False
  assert webhook.verify_secret(token <> "x", secret(token)) == False
}
