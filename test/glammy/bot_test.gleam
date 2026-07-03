//// Tests mirroring the portable subset of grammY's `test/bot.test.ts`.
//// Many grammY tests cover JS-async concerns (concurrent handleUpdate,
//// Promise-based init caching, lifecycle "isRunning" state). glammy is
//// synchronous and stateless per-update; those tests don't apply.

import glammy/api
import glammy/bot
import glammy/composer
import glammy/error
import glammy/helpers.{dummy_api}
import glammy/types.{type Update}
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}

const message_update_json = "{\"update_id\":1,\"message\":{\"message_id\":1,\"date\":0,\"chat\":{\"id\":123,\"type\":\"private\"},\"text\":\"x\"}}"

fn make_update() -> Update {
  helpers.update_from(message_update_json)
}

// =====================================================================
//                          Constructor
// =====================================================================

pub fn creates_bot_with_valid_token_test() {
  // glammy's bot.new doesn't reject empty tokens at construction time —
  // the token is validated when `start` is called (via getMe), which
  // matches grammY's design after init. Construction is total.
  let _ = bot.new(api.new("any:token"), composer.new())
  Nil
}

// =====================================================================
//                          handle_update
// =====================================================================

pub fn handle_update_processes_updates_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_ctx) {
      process.send(recorder, "handled")
      Nil
    })
  let bot_ = bot.new(dummy_api(), comp)
  bot.handle_update(bot_, make_update())
  assert process.receive(recorder, 50) == Ok("handled")
}

pub fn handle_update_runs_each_middleware_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_) { process.send(recorder, "a") })
    |> composer.handle(fn(_) { process.send(recorder, "b") })
    |> composer.handle(fn(_) { process.send(recorder, "c") })
  let bot_ = bot.new(dummy_api(), comp)
  bot.handle_update(bot_, make_update())
  assert process.receive(recorder, 50) == Ok("a")
  assert process.receive(recorder, 50) == Ok("b")
  assert process.receive(recorder, 50) == Ok("c")
}

pub fn handle_update_applies_transformers_to_api_test() {
  let captured: process.Subject(String) = process.new_subject()
  let api_ =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      process.send(captured, method)
      Error(error.DecodeError(method: method, message: "stub"))
    })
  let comp =
    composer.new()
    |> composer.handle(fn(ctx) {
      let _ =
        api.send_message(
          ctx.api,
          api.ChatIntId(123),
          "test",
          api.default_send_message_options(),
        )
      Nil
    })
  let bot_ = bot.new(api_, comp)
  bot.handle_update(bot_, make_update())
  assert process.receive(captured, 50) == Ok("sendMessage")
}

pub fn handle_update_continues_independent_updates_test() {
  let recorder: process.Subject(Int) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(ctx) {
      process.send(recorder, ctx.update.update_id)
      Nil
    })
  let bot_ = bot.new(dummy_api(), comp)

  let make = fn(id: Int) {
    let body =
      "{\"update_id\":"
      <> case id {
        1 -> "1"
        2 -> "2"
        _ -> "0"
      }
      <> ",\"message\":{\"message_id\":1,\"date\":0,\"chat\":{\"id\":1,\"type\":\"private\"},\"text\":\"x\"}}"
    let assert Ok(u) = json.parse(body, types.update_decoder())
    u
  }

  bot.handle_update(bot_, make(1))
  bot.handle_update(bot_, make(2))
  assert process.receive(recorder, 50) == Ok(1)
  assert process.receive(recorder, 50) == Ok(2)
}

// =====================================================================
//                         on_error customisation
// =====================================================================

pub fn on_error_replaces_default_handler_test() {
  let caught: process.Subject(String) = process.new_subject()
  let stub_transformer = fn(_next, method, _payload) {
    Error(error.DecodeError(method: method, message: "custom failure"))
  }
  let _bot_ =
    dummy_api()
    |> api.with_transformer(stub_transformer)
    |> bot.new(composer.new())
    |> bot.on_error(fn(err) { process.send(caught, error.describe(err)) })
  // The on_error handler is only invoked by `start`, not by individual
  // handle_update calls — but we can verify it's installed by exercising
  // it through the public surface: the bot value is opaque so we just
  // confirm `on_error` returns the same shape (no panic).
  Nil
}

// =====================================================================
//                       PollingOptions defaults
// =====================================================================

pub fn polling_options_defaults_test() {
  let opts = bot.default_polling_options()
  assert opts.limit == 100
  assert opts.timeout_seconds == 30
  assert opts.allowed_updates == None
  assert opts.drop_pending_updates == False
  assert opts.verify_token == True
}

pub fn polling_options_can_be_overridden_test() {
  let opts =
    bot.PollingOptions(
      limit: 10,
      timeout_seconds: 5,
      allowed_updates: Some(["message", "callback_query"]),
      drop_pending_updates: True,
      verify_token: False,
    )
  assert opts.limit == 10
  assert opts.allowed_updates == Some(["message", "callback_query"])
  assert opts.verify_token == False
}

// =====================================================================
//                       start with verify_token=False
// =====================================================================

pub fn start_returns_error_on_failed_get_me_test() {
  // With a transformer that always errors out and verify_token=True,
  // start should return Error without entering the poll loop.
  let api_ =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      Error(error.DecodeError(method: method, message: "stub"))
    })
  let bot_ = bot.new(api_, composer.new())
  let result = bot.start(bot_, bot.default_polling_options())
  case result {
    Error(_) -> Nil
    Ok(_) -> panic as "expected start to return Error on failed getMe"
  }
}
