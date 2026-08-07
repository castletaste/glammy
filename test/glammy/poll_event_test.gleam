import glammy/api
import glammy/bot
import glammy/composer
import glammy/context
import glammy/error.{type GlammyError}
import glammy/types
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/string

const receive_timeout_ms = 3000

const negative_timeout_ms = 25

const one_update = "{\"ok\":true,\"result\":[{\"update_id\":7}]}"

const two_updates = "{\"ok\":true,\"result\":[{\"update_id\":1},{\"update_id\":2}]}"

const update_three = "{\"ok\":true,\"result\":[{\"update_id\":3}]}"

const update_four = "{\"ok\":true,\"result\":[{\"update_id\":4}]}"

const no_updates = "{\"ok\":true,\"result\":[]}"

type Call {
  Call(method: String, payload: String)
}

type ScriptMessage {
  Execute(
    method: String,
    payload: String,
    reply: process.Subject(Result(String, GlammyError)),
  )
}

fn http_status(status: Int) -> GlammyError {
  error.HttpStatusError(method: "getUpdates", status:, body: "discarded")
}

fn retry_after(seconds: Int) -> GlammyError {
  error.ApiError(
    method: "getUpdates",
    error_code: 429,
    description: "discarded",
    parameters: types.ResponseParameters(
      migrate_to_chat_id: option.None,
      retry_after: option.Some(seconds),
    ),
  )
}

fn polling_options(policy: bot.HandlerFailurePolicy) -> bot.PollingOptions {
  bot.PollingOptions(
    ..bot.default_polling_options(),
    timeout_seconds: 0,
    handler_timeout_ms: 1000,
    handler_failure_policy: policy,
    verify_token: False,
  )
}

fn scripted_api(
  responses: List(Result(String, GlammyError)),
  calls: process.Subject(Call),
  initial_pending_update_count: Int,
) -> api.Api {
  let ready: process.Subject(process.Subject(ScriptMessage)) =
    process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let inbox = process.new_subject()
      process.send(ready, inbox)
      script_loop(inbox, responses, calls)
    })
  let assert Ok(script) = process.receive(ready, receive_timeout_ms)

  api.new("0:test")
  |> api.with_transformer(fn(_, method, payload) {
    case method {
      "getWebhookInfo" ->
        Ok(
          "{\"ok\":true,\"result\":{\"url\":\"\",\"has_custom_certificate\":false,\"pending_update_count\":"
          <> int.to_string(initial_pending_update_count)
          <> "}}",
        )
      _ -> {
        let reply = process.new_subject()
        process.send(script, Execute(method, payload_json(payload), reply))
        process.receive_forever(reply)
      }
    }
  })
}

fn script_loop(
  inbox: process.Subject(ScriptMessage),
  responses: List(Result(String, GlammyError)),
  calls: process.Subject(Call),
) -> Nil {
  let Execute(method:, payload:, reply:) = process.receive_forever(inbox)
  process.send(calls, Call(method, payload))
  case responses {
    [response, ..rest] -> {
      process.send(reply, response)
      script_loop(inbox, rest, calls)
    }
    [] -> {
      process.send(
        reply,
        Error(error.DecodeError(method:, message: "test script exhausted")),
      )
      script_loop(inbox, [], calls)
    }
  }
}

fn payload_json(payload: api.Payload) -> String {
  case payload {
    api.JsonPayload(fields) -> json.object(fields) |> json.to_string
    api.MultipartPayload(_) -> "multipart"
  }
}

fn quiet_bot(client: api.Api, pipeline: composer.Composer) -> bot.Bot {
  bot.new(client, pipeline)
  |> bot.on_error(fn(_) { Nil })
  |> bot.on_runtime_error(fn(_) { Nil })
}

fn start_in_background(
  app: bot.Bot,
  options: bot.PollingOptions,
  outcome: process.Subject(Result(Nil, bot.BotError)),
) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      process.send(outcome, bot.start(app, options))
    })
  Nil
}

fn assert_poll_succeeded(events: process.Subject(bot.PollEvent), count: Int) {
  case count {
    0 -> Nil
    _ -> {
      assert process.receive(events, receive_timeout_ms)
        == Ok(bot.PollSucceeded)
      assert_poll_succeeded(events, count - 1)
    }
  }
}

pub fn success_event_waits_for_handler_and_next_poll_uses_offset_test() {
  let calls = process.new_subject()
  let client = scripted_api([Ok(one_update), Error(http_status(401))], calls, 1)
  let handler_started: process.Subject(process.Subject(Nil)) =
    process.new_subject()
  let events = process.new_subject()
  let outcome = process.new_subject()
  let pipeline =
    composer.new()
    |> composer.handle(fn(_) {
      let release = process.new_subject()
      process.send(handler_started, release)
      process.receive_forever(release)
    })
  let app =
    quiet_bot(client, pipeline)
    |> bot.on_poll_event(fn(event) { process.send(events, event) })

  start_in_background(app, polling_options(bot.SkipFailedUpdate), outcome)
  let assert Ok(release) = process.receive(handler_started, receive_timeout_ms)
  assert process.receive(events, negative_timeout_ms) == Error(Nil)
  process.send(release, Nil)

  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollSucceeded)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollCaughtUp)
  let assert Ok(bot.PollStopped(error.HttpStatusError(status: 401, ..))) =
    process.receive(events, receive_timeout_ms)
  let assert Ok(Error(bot.ApiFailure(error.HttpStatusError(status: 401, ..)))) =
    process.receive(outcome, receive_timeout_ms)

  let assert Ok(Call(method: "getUpdates", payload: first_payload)) =
    process.receive(calls, receive_timeout_ms)
  let assert Ok(Call(method: "getUpdates", payload: second_payload)) =
    process.receive(calls, receive_timeout_ms)
  assert !string.contains(first_payload, "\"offset\"")
  assert string.contains(second_payload, "\"offset\":8")
}

pub fn initial_backlog_opens_on_first_partial_batch_only_test() {
  let calls = process.new_subject()
  let client =
    scripted_api(
      [
        Ok(two_updates),
        Ok(update_three),
        Ok(update_four),
        Error(http_status(401)),
      ],
      calls,
      3,
    )
  let events = process.new_subject()
  let outcome = process.new_subject()
  let app =
    quiet_bot(client, composer.new())
    |> bot.on_poll_event(fn(event) { process.send(events, event) })
  let options =
    bot.PollingOptions(..polling_options(bot.SkipFailedUpdate), limit: 2)

  start_in_background(app, options, outcome)

  // A full batch keeps the initial backlog barrier closed.
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollSucceeded)
  // The first smaller batch opens it after processing and offset derivation.
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollSucceeded)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollCaughtUp)
  // A later partial batch does not repeat before the next bounded interval.
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollSucceeded)
  let assert Ok(bot.PollStopped(error.HttpStatusError(status: 401, ..))) =
    process.receive(events, receive_timeout_ms)
  let assert Ok(Error(bot.ApiFailure(error.HttpStatusError(status: 401, ..)))) =
    process.receive(outcome, receive_timeout_ms)

  let assert Ok(Call(payload: first_payload, ..)) =
    process.receive(calls, receive_timeout_ms)
  let assert Ok(Call(payload: first_partial_payload, ..)) =
    process.receive(calls, receive_timeout_ms)
  let assert Ok(Call(payload: second_partial_payload, ..)) =
    process.receive(calls, receive_timeout_ms)
  let assert Ok(Call(payload: terminal_payload, ..)) =
    process.receive(calls, receive_timeout_ms)
  assert !string.contains(first_payload, "\"offset\"")
  assert string.contains(first_partial_payload, "\"offset\":3")
  assert string.contains(second_partial_payload, "\"offset\":4")
  assert string.contains(terminal_payload, "\"offset\":5")
}

pub fn initial_backlog_waits_past_old_batch_cap_for_true_boundary_test() {
  let calls = process.new_subject()
  let client =
    scripted_api(
      [
        Ok(two_updates),
        Ok(two_updates),
        Ok(two_updates),
        Ok(two_updates),
        Ok(two_updates),
        Ok(two_updates),
        Ok(two_updates),
        Ok(two_updates),
        Ok(two_updates),
        Error(http_status(401)),
      ],
      calls,
      18,
    )
  let events = process.new_subject()
  let outcome = process.new_subject()
  let app =
    quiet_bot(client, composer.new())
    |> bot.on_poll_event(fn(event) { process.send(events, event) })
  let options =
    bot.PollingOptions(..polling_options(bot.SkipFailedUpdate), limit: 2)

  start_in_background(app, options, outcome)

  // The old fixed eight-batch boundary must not publish while two startup
  // updates from Telegram's pending-count snapshot remain unprocessed.
  assert_poll_succeeded(events, 8)
  // The ninth batch reaches the actual startup high-water boundary.
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollSucceeded)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollCaughtUp)
  let assert Ok(bot.PollStopped(error.HttpStatusError(status: 401, ..))) =
    process.receive(events, receive_timeout_ms)
  let assert Ok(Error(bot.ApiFailure(error.HttpStatusError(status: 401, ..)))) =
    process.receive(outcome, receive_timeout_ms)
}

pub fn continuous_full_batches_repeat_the_bounded_caught_up_event_test() {
  let calls = process.new_subject()
  let responses =
    list.append(list.repeat(Ok(two_updates), times: 16), [
      Error(http_status(401)),
    ])
  let client = scripted_api(responses, calls, 16)
  let events = process.new_subject()
  let outcome = process.new_subject()
  let app =
    quiet_bot(client, composer.new())
    |> bot.on_poll_event(fn(event) { process.send(events, event) })
  let options =
    bot.PollingOptions(..polling_options(bot.SkipFailedUpdate), limit: 2)

  start_in_background(app, options, outcome)

  // The first bounded window opens the startup barrier.
  assert_poll_succeeded(events, 7)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollSucceeded)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollCaughtUp)

  // An observer restarted after that pulse receives another one after the next
  // bounded window, even though no poll was empty or partial.
  assert_poll_succeeded(events, 7)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollSucceeded)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollCaughtUp)

  let assert Ok(bot.PollStopped(error.HttpStatusError(status: 401, ..))) =
    process.receive(events, receive_timeout_ms)
  let assert Ok(Error(bot.ApiFailure(error.HttpStatusError(status: 401, ..)))) =
    process.receive(outcome, receive_timeout_ms)
}

pub fn continuous_partial_batches_repeat_without_signalling_every_poll_test() {
  let calls = process.new_subject()
  let responses =
    list.append(list.repeat(Ok(one_update), times: 9), [Error(http_status(401))])
  let client = scripted_api(responses, calls, 1)
  let events = process.new_subject()
  let outcome = process.new_subject()
  let app =
    quiet_bot(client, composer.new())
    |> bot.on_poll_event(fn(event) { process.send(events, event) })
  let options =
    bot.PollingOptions(..polling_options(bot.SkipFailedUpdate), limit: 2)

  start_in_background(app, options, outcome)

  // The first partial batch opens the initial barrier immediately.
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollSucceeded)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollCaughtUp)

  // Later partial batches use the bounded cadence instead of waking recovery
  // for every individual update.
  assert_poll_succeeded(events, 7)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollSucceeded)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollCaughtUp)

  let assert Ok(bot.PollStopped(error.HttpStatusError(status: 401, ..))) =
    process.receive(events, receive_timeout_ms)
  let assert Ok(Error(bot.ApiFailure(error.HttpStatusError(status: 401, ..)))) =
    process.receive(outcome, receive_timeout_ms)
}

pub fn every_empty_poll_publishes_a_fresh_caught_up_event_test() {
  let calls = process.new_subject()
  let client =
    scripted_api(
      [Ok(no_updates), Ok(no_updates), Error(http_status(401))],
      calls,
      0,
    )
  let events = process.new_subject()
  let outcome = process.new_subject()
  let app =
    quiet_bot(client, composer.new())
    |> bot.on_poll_event(fn(event) { process.send(events, event) })

  start_in_background(app, polling_options(bot.SkipFailedUpdate), outcome)

  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollSucceeded)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollCaughtUp)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollSucceeded)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollCaughtUp)
  let assert Ok(bot.PollStopped(error.HttpStatusError(status: 401, ..))) =
    process.receive(events, receive_timeout_ms)
  let assert Ok(Error(bot.ApiFailure(error.HttpStatusError(status: 401, ..)))) =
    process.receive(outcome, receive_timeout_ms)
}

pub fn retry_events_keep_offset_and_callback_panic_cannot_change_outcome_test() {
  let calls = process.new_subject()
  let client =
    scripted_api(
      [
        Ok(one_update),
        Error(http_status(408)),
        Error(retry_after(1)),
        Error(http_status(401)),
      ],
      calls,
      1,
    )
  let events = process.new_subject()
  let outcome = process.new_subject()
  let app =
    quiet_bot(client, composer.new())
    |> bot.on_poll_event(fn(event) {
      process.send(events, event)
      panic as "poll observer panic"
    })

  start_in_background(app, polling_options(bot.SkipFailedUpdate), outcome)

  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollSucceeded)
  assert process.receive(events, receive_timeout_ms) == Ok(bot.PollCaughtUp)
  let assert Ok(bot.PollRetryScheduled(
    error: error.HttpStatusError(status: 408, ..),
    attempt: 1,
    backoff_ms: 1000,
  )) = process.receive(events, receive_timeout_ms)
  let assert Ok(bot.PollRetryScheduled(
    error: error.ApiError(error_code: 429, ..),
    attempt: 2,
    backoff_ms: 1000,
  )) = process.receive(events, receive_timeout_ms)
  let assert Ok(bot.PollStopped(error.HttpStatusError(status: 401, ..))) =
    process.receive(events, receive_timeout_ms)
  let assert Ok(Error(bot.ApiFailure(error.HttpStatusError(status: 401, ..)))) =
    process.receive(outcome, receive_timeout_ms)

  let assert Ok(Call(payload: initial_payload, ..)) =
    process.receive(calls, receive_timeout_ms)
  assert !string.contains(initial_payload, "\"offset\"")
  let assert Ok(Call(payload: retry_payload_1, ..)) =
    process.receive(calls, receive_timeout_ms)
  let assert Ok(Call(payload: retry_payload_2, ..)) =
    process.receive(calls, receive_timeout_ms)
  let assert Ok(Call(payload: terminal_payload, ..)) =
    process.receive(calls, receive_timeout_ms)
  assert string.contains(retry_payload_1, "\"offset\":8")
  assert string.contains(retry_payload_2, "\"offset\":8")
  assert string.contains(terminal_payload, "\"offset\":8")
}

pub fn checkpoint_failure_is_distinct_and_hung_callback_preserves_result_test() {
  let calls = process.new_subject()
  let client =
    scripted_api([Ok(two_updates), Error(http_status(503))], calls, 2)
  let events = process.new_subject()
  let outcome = process.new_subject()
  let pipeline =
    composer.new()
    |> composer.handle(fn(ctx) {
      let context.Context(update:, ..) = ctx
      case update.update_id {
        2 -> panic as "handler failed"
        _ -> Nil
      }
    })
  let configured =
    quiet_bot(client, pipeline)
    |> bot.on_poll_event(fn(event) {
      process.send(events, event)
      process.sleep_forever()
    })
    |> bot.with_callback_timeout(20)
  let assert Ok(app) = configured

  start_in_background(app, polling_options(bot.StopOnHandlerFailure), outcome)

  let assert Ok(bot.PollCheckpointFailed(error.HttpStatusError(status: 503, ..))) =
    process.receive(events, receive_timeout_ms)
  let assert Ok(Error(bot.UpdateCheckpointFailure(
    update_failure: bot.HandlerCrashed(update_id: 2, ..),
    checkpoint_failure: error.HttpStatusError(status: 503, ..),
  ))) = process.receive(outcome, receive_timeout_ms)

  let assert Ok(Call(payload: initial_payload, ..)) =
    process.receive(calls, receive_timeout_ms)
  let assert Ok(Call(payload: checkpoint_payload, ..)) =
    process.receive(calls, receive_timeout_ms)
  assert !string.contains(initial_payload, "\"offset\"")
  assert string.contains(checkpoint_payload, "\"offset\":2")
  assert string.contains(checkpoint_payload, "\"limit\":1")
  assert string.contains(checkpoint_payload, "\"timeout\":0")
}
