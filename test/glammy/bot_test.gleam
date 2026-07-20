//// Bot dispatch, polling classification, and handler isolation tests.

import glammy/api
import glammy/bot
import glammy/composer
import glammy/error.{type GlammyError}
import glammy/helpers.{dummy_api, no_event, receive_event}
import glammy/internal/http_response
import glammy/types.{type Update}
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string

const message_update_json = "{\"update_id\":1,\"message\":{\"message_id\":1,\"date\":0,\"chat\":{\"id\":123,\"type\":\"private\"},\"text\":\"x\"}}"

const get_me_response = "{\"ok\":true,\"result\":{\"id\":1,\"is_bot\":true,\"first_name\":\"Bot\",\"username\":\"bot\"}}"

const updates_response = "{\"ok\":true,\"result\":[{\"update_id\":1,\"message\":{\"message_id\":1,\"date\":0,\"chat\":{\"id\":123,\"type\":\"private\"},\"text\":\"x\"}}]}"

const update_two_response = "{\"ok\":true,\"result\":[{\"update_id\":2,\"message\":{\"message_id\":2,\"date\":0,\"chat\":{\"id\":123,\"type\":\"private\"},\"text\":\"two\"}}]}"

const two_updates_response = "{\"ok\":true,\"result\":[{\"update_id\":1,\"message\":{\"message_id\":1,\"date\":0,\"chat\":{\"id\":123,\"type\":\"private\"},\"text\":\"one\"}},{\"update_id\":2,\"message\":{\"message_id\":2,\"date\":0,\"chat\":{\"id\":123,\"type\":\"private\"},\"text\":\"two\"}}]}"

const callback_test_timeout_ms = 250

// Wide enough for loaded CI, but below a hard-coded 1000ms fallback.
const callback_test_completion_timeout_ms = 750

const lifecycle_test_timeout_ms = 3000

fn make_update() -> Update {
  helpers.update_from(message_update_json)
}

fn assert_monitored_process_down(
  monitor: process.Monitor,
  pid: process.Pid,
) -> Nil {
  assert_monitored_process_down_within(monitor, pid, lifecycle_test_timeout_ms)
}

fn assert_monitored_process_down_within(
  monitor: process.Monitor,
  pid: process.Pid,
  timeout_ms: Int,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
  let assert Ok(Nil) = process.selector_receive(selector, timeout_ms)
  process.demonitor_process(monitor)
  assert !process.is_alive(pid)
}

type StubApiRequest {
  StubApiRequest(
    method: String,
    payload: api.Payload,
    reply: process.Subject(Result(String, GlammyError)),
  )
}

fn api_from_requests(requests: process.Subject(StubApiRequest)) -> api.Api {
  dummy_api()
  |> api.with_transformer(fn(_next, method, payload) {
    let reply = process.new_subject()
    process.send(requests, StubApiRequest(method:, payload:, reply:))
    process.receive_forever(reply)
  })
}

fn payload_json(payload: api.Payload) -> String {
  let assert api.JsonPayload(fields) = payload
  fields |> json.object |> json.to_string
}

fn checkpointing_client(
  get_updates_count: process.Subject(Int),
  payloads: process.Subject(String),
  checkpoint_failure: Option(GlammyError),
) -> api.Api {
  dummy_api()
  |> api.with_transformer(fn(_next, method, payload) {
    case method {
      "getUpdates" -> {
        process.send(payloads, payload_json(payload))
        let assert Ok(count) = receive_event(get_updates_count)
        process.send(get_updates_count, count + 1)
        case count {
          0 -> Ok(two_updates_response)
          1 ->
            case checkpoint_failure {
              None -> Ok(update_two_response)
              Some(failure) -> Error(failure)
            }
          2 ->
            case checkpoint_failure {
              None -> Ok(update_two_response)
              Some(_) -> Ok(two_updates_response)
            }
          _ -> Error(error.DecodeError(method: method, message: "done"))
        }
      }
      _ -> Error(error.DecodeError(method: method, message: "unexpected"))
    }
  })
}

pub fn creates_bot_with_valid_token_test() {
  let _ = bot.new(api.new("any:token"), composer.new())
  Nil
}

// =====================================================================
//                          Direct dispatch
// =====================================================================

pub fn handle_update_processes_updates_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_) { process.send(recorder, "handled") })
  bot.handle_update(bot.new(dummy_api(), comp), make_update())
  assert receive_event(recorder) == Ok("handled")
}

pub fn handle_update_runs_each_middleware_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_) { process.send(recorder, "a") })
    |> composer.handle(fn(_) { process.send(recorder, "b") })
    |> composer.handle(fn(_) { process.send(recorder, "c") })
  bot.handle_update(bot.new(dummy_api(), comp), make_update())
  assert receive_event(recorder) == Ok("a")
  assert receive_event(recorder) == Ok("b")
  assert receive_event(recorder) == Ok("c")
}

pub fn handle_update_applies_transformers_to_api_test() {
  let captured: process.Subject(String) = process.new_subject()
  let client =
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
  bot.handle_update(bot.new(client, comp), make_update())
  assert receive_event(captured) == Ok("sendMessage")
}

pub fn update_gates_consume_continue_and_fail_typed_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_) { process.send(recorder, "handled") })

  let consumed =
    bot.new(dummy_api(), comp)
    |> bot.with_update_gate(fn(_) { Ok(bot.Consumed) })
  assert bot.handle_update_result(consumed, make_update()) == Ok(Nil)
  assert no_event(recorder)

  let continued =
    bot.new(dummy_api(), comp)
    |> bot.with_update_gate(fn(_) { Ok(bot.Continue) })
  assert bot.handle_update_result(continued, make_update()) == Ok(Nil)
  assert receive_event(recorder) == Ok("handled")

  let failed =
    bot.new(dummy_api(), comp)
    |> bot.with_update_gate(fn(_) {
      Error(bot.UpdateGateError("store_unavailable", "retry later"))
    })
  let expected =
    bot.UpdateGateFailed(
      update_id: 1,
      code: "store_unavailable",
      message: "retry later",
    )
  assert bot.handle_update_result(failed, make_update()) == Error(expected)
  assert bot.handle_update_isolated(failed, make_update(), 100)
    == Error(expected)
  assert no_event(recorder)
}

pub fn update_gates_are_ordered_and_consumed_short_circuits_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_) { process.send(recorder, "composer") })
  let ordered =
    bot.new(dummy_api(), comp)
    |> bot.with_update_gate(fn(_) {
      process.send(recorder, "specialized")
      Ok(bot.Continue)
    })
    |> bot.with_update_gate(fn(_) {
      process.send(recorder, "owner")
      Ok(bot.Consumed)
    })
    |> bot.with_update_gate(fn(_) {
      process.send(recorder, "too-late")
      Ok(bot.Consumed)
    })

  assert bot.handle_update_result(ordered, make_update()) == Ok(Nil)
  assert receive_event(recorder) == Ok("specialized")
  assert receive_event(recorder) == Ok("owner")
  assert no_event(recorder)
}

pub fn isolated_handler_reports_panic_test() {
  let comp = composer.new() |> composer.handle(fn(_) { panic as "boom" })
  case
    bot.handle_update_isolated(
      bot.new(dummy_api(), comp),
      make_update(),
      helpers.async_timeout_ms,
    )
  {
    Error(runtime_error) -> {
      assert string.contains(string.inspect(runtime_error), "HandlerCrashed")
    }
    _ -> panic as "expected HandlerCrashed"
  }
}

pub fn isolated_update_gate_panic_is_typed_fail_closed_test() {
  let bot_ =
    bot.new(dummy_api(), composer.new())
    |> bot.with_update_gate(fn(_) { panic as "gate secret" })

  assert bot.handle_update_isolated(
      bot_,
      make_update(),
      helpers.async_timeout_ms,
    )
    == Error(bot.UpdateGateCrashed(update_id: 1))
}

pub fn isolated_update_gate_self_termination_is_typed_fail_closed_test() {
  let bot_ =
    bot.new(dummy_api(), composer.new())
    |> bot.with_update_gate(fn(_) {
      process.kill(process.self())
      Ok(bot.Continue)
    })

  assert bot.handle_update_isolated(
      bot_,
      make_update(),
      helpers.async_timeout_ms,
    )
    == Error(bot.UpdateGateCrashed(update_id: 1))
}

pub fn isolated_handler_has_bounded_timeout_test() {
  let worker: process.Subject(process.Pid) = process.new_subject()
  let outcome: process.Subject(Result(Nil, bot.BotRuntimeError)) =
    process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_) {
      process.send(worker, process.self())
      process.sleep_forever()
    })
  let bot_ = bot.new(dummy_api(), comp)
  let _ =
    process.spawn_unlinked(fn() {
      process.send(outcome, bot.handle_update_isolated(bot_, make_update(), 5))
    })
  let assert Ok(worker_pid) = receive_event(worker)
  let monitor = process.monitor(worker_pid)
  assert receive_event(outcome)
    == Ok(Error(bot.HandlerTimedOut(update_id: 1, timeout_ms: 5)))
  assert !process.is_alive(worker_pid)
  assert_monitored_process_down(monitor, worker_pid)
}

pub fn isolated_handler_rejects_beam_timeout_overflow_test() {
  let bot_ = bot.new(dummy_api(), composer.new())
  assert bot.handle_update_isolated(bot_, make_update(), 4_294_967_296)
    == Error(bot.HandlerTimedOut(update_id: 1, timeout_ms: 4_294_967_296))
}

pub fn killing_isolated_handler_caller_stops_handler_worker_test() {
  let worker_started: process.Subject(process.Pid) = process.new_subject()
  let outcome: process.Subject(Result(Nil, bot.BotRuntimeError)) =
    process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_) {
      process.send(worker_started, process.self())
      process.sleep_forever()
    })
  let bot_ = bot.new(dummy_api(), comp)
  let caller =
    process.spawn_unlinked(fn() {
      process.send(
        outcome,
        bot.handle_update_isolated(bot_, make_update(), 60_000),
      )
    })
  let assert Ok(worker_pid) = receive_event(worker_started)
  let caller_monitor = process.monitor(caller)
  let worker_monitor = process.monitor(worker_pid)

  process.kill(caller)

  assert_monitored_process_down(caller_monitor, caller)
  assert_monitored_process_down(worker_monitor, worker_pid)
  assert no_event(outcome)
  assert no_event(worker_started)
}

// =====================================================================
//                         Polling options
// =====================================================================

pub fn polling_options_defaults_test() {
  let options = bot.default_polling_options()
  assert options.limit == 100
  assert options.timeout_seconds == 30
  assert options.handler_timeout_ms == 60_000
  assert options.handler_failure_policy == bot.SkipFailedUpdate
  assert options.allowed_updates == None
  assert options.drop_pending_updates == False
  assert options.verify_token == True
}

pub fn polling_options_can_be_overridden_test() {
  let options =
    bot.PollingOptions(
      limit: 10,
      timeout_seconds: 5,
      handler_timeout_ms: 250,
      handler_failure_policy: bot.StopOnHandlerFailure,
      allowed_updates: Some(["message", "callback_query"]),
      drop_pending_updates: True,
      verify_token: False,
    )
  assert options.limit == 10
  assert options.handler_timeout_ms == 250
  assert options.handler_failure_policy == bot.StopOnHandlerFailure
}

pub fn runtime_error_description_redacts_application_details_test() {
  assert bot.describe_runtime_error(bot.HandlerCrashed(
      update_id: 7,
      reason: "token secret stack",
    ))
    == "handler crashed for update 7"
  assert bot.describe_runtime_error(bot.UpdateGateFailed(
      8,
      "credential-secret",
      "database password",
    ))
    == "update gate failed for update 8"
  assert bot.describe_runtime_error(bot.UpdateGateCrashed(update_id: 9))
    == "update gate crashed for update 9"
  assert !string.contains(
    bot.describe_runtime_error(bot.HandlerCrashed(
      update_id: 7,
      reason: "token secret stack",
    )),
    "secret",
  )
}

pub fn invalid_polling_options_are_rejected_before_io_test() {
  let bot_ = bot.new(dummy_api(), composer.new())
  let defaults = bot.default_polling_options()
  assert bot.start(bot_, bot.PollingOptions(..defaults, limit: 0))
    == Error(bot.InvalidPollingLimit(0))
  assert bot.start(bot_, bot.PollingOptions(..defaults, timeout_seconds: 51))
    == Error(bot.InvalidPollingTimeout(51))
  assert bot.start(bot_, bot.PollingOptions(..defaults, handler_timeout_ms: 0))
    == Error(bot.InvalidHandlerTimeout(0))
  assert bot.start(
      bot_,
      bot.PollingOptions(..defaults, handler_timeout_ms: 4_294_967_296),
    )
    == Error(bot.InvalidHandlerTimeout(4_294_967_296))
}

pub fn invalid_callback_timeout_is_rejected_typed_test() {
  let bot_ = bot.new(dummy_api(), composer.new())
  let assert Ok(_) = bot.with_callback_timeout(bot_, 4_294_967_295)
  assert bot.with_callback_timeout(bot_, 0)
    == Error(bot.InvalidCallbackTimeout(0))
  assert bot.with_callback_timeout(bot_, -1)
    == Error(bot.InvalidCallbackTimeout(-1))
  assert bot.with_callback_timeout(bot_, 4_294_967_296)
    == Error(bot.InvalidCallbackTimeout(4_294_967_296))
}

// =====================================================================
//                       Polling error behaviour
// =====================================================================

pub fn transient_get_me_failure_retries_before_polling_test() {
  let get_me_attempts: process.Subject(Int) = process.new_subject()
  let calls: process.Subject(String) = process.new_subject()
  process.send(get_me_attempts, 0)
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      process.send(calls, method)
      case method {
        "getMe" -> {
          let assert Ok(attempt) = receive_event(get_me_attempts)
          process.send(get_me_attempts, attempt + 1)
          case attempt {
            0 ->
              Error(error.ApiError(
                method: method,
                error_code: 408,
                description: "request timeout",
                parameters: types.ResponseParameters(
                  migrate_to_chat_id: None,
                  retry_after: None,
                ),
              ))
            _ -> Ok(get_me_response)
          }
        }
        "getUpdates" ->
          Error(error.DecodeError(method: method, message: "stop"))
        _ -> Error(error.DecodeError(method: method, message: "unexpected"))
      }
    })
  let bot_ = bot.new(client, composer.new()) |> bot.on_error(fn(_) { Nil })

  let assert Error(bot.ApiFailure(error.DecodeError(method: "getUpdates", ..))) =
    bot.start(bot_, bot.default_polling_options())
  assert receive_event(calls) == Ok("getMe")
  assert receive_event(calls) == Ok("getMe")
  assert receive_event(calls) == Ok("getUpdates")
  assert no_event(calls)
  assert receive_event(get_me_attempts) == Ok(2)
}

pub fn transient_initial_drain_failure_retries_and_preserves_offset_test() {
  let get_updates_attempts: process.Subject(Int) = process.new_subject()
  let payloads: process.Subject(String) = process.new_subject()
  process.send(get_updates_attempts, 0)
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, payload) {
      case method {
        "getUpdates" -> {
          process.send(payloads, payload_json(payload))
          let assert Ok(attempt) = receive_event(get_updates_attempts)
          process.send(get_updates_attempts, attempt + 1)
          case attempt {
            0 ->
              Error(error.HttpStatusError(
                method: method,
                status: 503,
                body: "try again",
              ))
            1 -> Ok(updates_response)
            _ -> Error(error.DecodeError(method: method, message: "stop"))
          }
        }
        _ -> Error(error.DecodeError(method: method, message: "unexpected"))
      }
    })
  let defaults = bot.default_polling_options()
  let options =
    bot.PollingOptions(
      ..defaults,
      verify_token: False,
      drop_pending_updates: True,
    )
  let bot_ = bot.new(client, composer.new()) |> bot.on_error(fn(_) { Nil })

  let assert Error(bot.ApiFailure(error.DecodeError(method: "getUpdates", ..))) =
    bot.start(bot_, options)
  let assert Ok(first_drain) = receive_event(payloads)
  let assert Ok(retried_drain) = receive_event(payloads)
  let assert Ok(first_poll) = receive_event(payloads)
  assert string.contains(first_drain, "\"offset\":-1")
  assert string.contains(retried_drain, "\"offset\":-1")
  assert string.contains(first_poll, "\"offset\":2")
  assert no_event(payloads)
  assert receive_event(get_updates_attempts) == Ok(3)
}

pub fn permanent_get_me_failure_is_typed_and_not_retried_test() {
  let caught: process.Subject(String) = process.new_subject()
  let calls: process.Subject(String) = process.new_subject()
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      process.send(calls, method)
      Error(error.HttpStatusError(
        method: method,
        status: 401,
        body: "bad token",
      ))
    })
  let bot_ =
    bot.new(client, composer.new())
    |> bot.on_error(fn(value) { process.send(caught, error.describe(value)) })

  assert bot.start(bot_, bot.default_polling_options())
    == Error(
      bot.ApiFailure(error.HttpStatusError(
        method: "getMe",
        status: 401,
        body: "bad token",
      )),
    )
  assert receive_event(caught) == Ok("HTTP 401 returned for 'getMe'")
  assert receive_event(calls) == Ok("getMe")
  assert no_event(calls)
}

pub fn panicking_error_callback_cannot_escape_bot_start_test() {
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      Error(error.HttpStatusError(
        method: method,
        status: 401,
        body: "bad token",
      ))
    })
  let bot_ =
    bot.new(client, composer.new())
    |> bot.on_error(fn(_) { panic as "diagnostic callback boom" })

  let assert Error(bot.ApiFailure(error.HttpStatusError(status: 401, ..))) =
    bot.start(bot_, bot.default_polling_options())
}

pub fn self_terminating_error_callback_cannot_escape_bot_start_test() {
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      Error(error.HttpStatusError(
        method: method,
        status: 401,
        body: "bad token",
      ))
    })
  let bot_ =
    bot.new(client, composer.new())
    |> bot.on_error(fn(_) { process.kill(process.self()) })

  let assert Error(bot.ApiFailure(error.HttpStatusError(status: 401, ..))) =
    bot.start(bot_, bot.default_polling_options())
}

pub fn hung_error_callback_times_out_and_preserves_exact_api_failure_test() {
  let failure =
    error.HttpStatusError(
      method: "getMe",
      status: 401,
      body: "exact original failure",
    )
  let callback_started: process.Subject(#(process.Pid, process.Subject(Nil))) =
    process.new_subject()
  let outcome: process.Subject(Result(Nil, bot.BotError)) =
    process.new_subject()
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, _method, _payload) { Error(failure) })
  let configured =
    bot.new(client, composer.new())
    |> bot.on_error(fn(_) {
      let release = process.new_subject()
      process.send(callback_started, #(process.self(), release))
      let Nil = process.receive_forever(release)
      process.sleep_forever()
    })
  let assert Ok(bot_) =
    bot.with_callback_timeout(configured, callback_test_timeout_ms)
  let caller =
    process.spawn_unlinked(fn() {
      process.send(outcome, bot.start(bot_, bot.default_polling_options()))
    })
  let caller_monitor = process.monitor(caller)
  let assert Ok(#(callback_pid, release)) = receive_event(callback_started)
  let callback_monitor = process.monitor(callback_pid)
  process.send(release, Nil)

  assert process.receive(outcome, callback_test_completion_timeout_ms)
    == Ok(Error(bot.ApiFailure(failure)))
  assert !process.is_alive(callback_pid)
  assert_monitored_process_down(callback_monitor, callback_pid)
  assert_monitored_process_down(caller_monitor, caller)
  assert no_event(callback_started)
  assert no_event(outcome)
}

pub fn configured_callback_deadline_distinguishes_short_and_long_test() {
  let failure =
    error.HttpStatusError(method: "getMe", status: 401, body: "deadline")
  let completed: process.Subject(Nil) = process.new_subject()
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, _method, _payload) { Error(failure) })
  let callback = fn(_) {
    process.sleep(200)
    process.send(completed, Nil)
  }

  let short = bot.new(client, composer.new()) |> bot.on_error(callback)
  let assert Ok(short) = bot.with_callback_timeout(short, 50)
  assert bot.start(short, bot.default_polling_options())
    == Error(bot.ApiFailure(failure))
  assert no_event(completed)

  let long = bot.new(client, composer.new()) |> bot.on_error(callback)
  let assert Ok(long) = bot.with_callback_timeout(long, 2000)
  assert bot.start(long, bot.default_polling_options())
    == Error(bot.ApiFailure(failure))
  assert receive_event(completed) == Ok(Nil)
  assert no_event(completed)
}

pub fn transient_error_callback_timeout_does_not_block_retry_test() {
  let calls: process.Subject(String) = process.new_subject()
  let callback_started: process.Subject(#(process.Pid, process.Subject(Nil))) =
    process.new_subject()
  let outcome: process.Subject(Result(Nil, bot.BotError)) =
    process.new_subject()
  let server_ready: process.Subject(process.Subject(StubApiRequest)) =
    process.new_subject()
  let final_failure =
    error.DecodeError(method: "getUpdates", message: "exact final failure")
  let server =
    process.spawn_unlinked(fn() {
      let requests = process.new_subject()
      process.send(server_ready, requests)

      let StubApiRequest(method: first_method, reply: first_reply, ..) =
        process.receive_forever(requests)
      process.send(calls, first_method)
      process.send(
        first_reply,
        Error(error.HttpStatusError(
          method: first_method,
          status: 503,
          body: "retry",
        )),
      )

      let StubApiRequest(method: second_method, reply: second_reply, ..) =
        process.receive_forever(requests)
      process.send(calls, second_method)
      process.send(second_reply, Ok(get_me_response))

      let StubApiRequest(method: final_method, reply: final_reply, ..) =
        process.receive_forever(requests)
      process.send(calls, final_method)
      process.send(final_reply, Error(final_failure))
    })
  let assert Ok(requests) = receive_event(server_ready)
  let server_monitor = process.monitor(server)
  let client = api_from_requests(requests)
  let configured =
    bot.new(client, composer.new())
    |> bot.on_error(fn(_) {
      let release = process.new_subject()
      process.send(callback_started, #(process.self(), release))
      let Nil = process.receive_forever(release)
      process.sleep_forever()
    })
  let assert Ok(bot_) =
    bot.with_callback_timeout(configured, callback_test_timeout_ms)
  let caller =
    process.spawn_unlinked(fn() {
      process.send(outcome, bot.start(bot_, bot.default_polling_options()))
    })
  let caller_monitor = process.monitor(caller)

  let assert Ok(#(first_callback_pid, first_release)) =
    receive_event(callback_started)
  let first_callback_monitor = process.monitor(first_callback_pid)
  process.send(first_release, Nil)
  let assert Ok(#(second_callback_pid, second_release)) =
    process.receive(callback_started, helpers.async_timeout_ms * 5)
  assert !process.is_alive(first_callback_pid)
  assert_monitored_process_down_within(
    first_callback_monitor,
    first_callback_pid,
    callback_test_completion_timeout_ms,
  )
  let second_callback_monitor = process.monitor(second_callback_pid)
  process.send(second_release, Nil)

  assert process.receive(outcome, callback_test_completion_timeout_ms)
    == Ok(Error(bot.ApiFailure(final_failure)))
  assert !process.is_alive(second_callback_pid)
  assert_monitored_process_down_within(
    second_callback_monitor,
    second_callback_pid,
    callback_test_completion_timeout_ms,
  )
  assert_monitored_process_down(caller_monitor, caller)
  assert receive_event(calls) == Ok("getMe")
  assert receive_event(calls) == Ok("getMe")
  assert receive_event(calls) == Ok("getUpdates")
  assert_monitored_process_down(server_monitor, server)
  assert no_event(server_ready)
  assert no_event(callback_started)
  assert no_event(calls)
  assert no_event(outcome)
}

pub fn killing_callback_caller_stops_callback_task_test() {
  let callback_started: process.Subject(process.Pid) = process.new_subject()
  let outcome: process.Subject(Result(Nil, bot.BotError)) =
    process.new_subject()
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      Error(error.HttpStatusError(method: method, status: 401, body: "stop"))
    })
  let configured =
    bot.new(client, composer.new())
    |> bot.on_error(fn(_) {
      process.send(callback_started, process.self())
      process.sleep_forever()
    })
  let assert Ok(bot_) = bot.with_callback_timeout(configured, 60_000)
  let caller =
    process.spawn_unlinked(fn() {
      process.send(outcome, bot.start(bot_, bot.default_polling_options()))
    })
  let assert Ok(callback_pid) = receive_event(callback_started)
  let caller_monitor = process.monitor(caller)
  let callback_monitor = process.monitor(callback_pid)

  process.kill(caller)

  assert_monitored_process_down(caller_monitor, caller)
  assert_monitored_process_down_within(
    callback_monitor,
    callback_pid,
    callback_test_completion_timeout_ms,
  )
  assert no_event(outcome)
  assert no_event(callback_started)
}

pub fn panicking_runtime_callback_cannot_escape_bot_start_test() {
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      case method {
        "getUpdates" -> Ok(updates_response)
        _ -> Error(error.DecodeError(method: method, message: "unexpected"))
      }
    })
  let bot_ =
    bot.new(client, composer.new())
    |> bot.with_update_gate(fn(_) {
      Error(bot.UpdateGateError("journal", "unavailable"))
    })
    |> bot.on_runtime_error(fn(_) { panic as "runtime callback boom" })
  let defaults = bot.default_polling_options()
  let options = bot.PollingOptions(..defaults, verify_token: False)

  let assert Error(bot.UpdateHandlerFailure(bot.UpdateGateFailed(
    update_id: 1,
    code: "journal",
    message: "unavailable",
  ))) = bot.start(bot_, options)
}

pub fn self_terminating_runtime_callback_cannot_escape_bot_start_test() {
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      case method {
        "getUpdates" -> Ok(updates_response)
        _ -> Error(error.DecodeError(method: method, message: "unexpected"))
      }
    })
  let bot_ =
    bot.new(client, composer.new())
    |> bot.with_update_gate(fn(_) {
      Error(bot.UpdateGateError("journal", "unavailable"))
    })
    |> bot.on_runtime_error(fn(_) { process.kill(process.self()) })
  let defaults = bot.default_polling_options()
  let options = bot.PollingOptions(..defaults, verify_token: False)

  let assert Error(bot.UpdateHandlerFailure(bot.UpdateGateFailed(
    update_id: 1,
    code: "journal",
    message: "unavailable",
  ))) = bot.start(bot_, options)
}

pub fn hung_runtime_callback_times_out_and_skip_policy_continues_test() {
  let payloads: process.Subject(String) = process.new_subject()
  let handled: process.Subject(Int) = process.new_subject()
  let callback_started: process.Subject(
    #(process.Pid, bot.BotRuntimeError, process.Subject(Nil)),
  ) = process.new_subject()
  let outcome: process.Subject(Result(Nil, bot.BotError)) =
    process.new_subject()
  let server_ready: process.Subject(process.Subject(StubApiRequest)) =
    process.new_subject()
  let final_failure =
    error.DecodeError(method: "getUpdates", message: "exact final failure")
  let server =
    process.spawn_unlinked(fn() {
      let requests = process.new_subject()
      process.send(server_ready, requests)

      let StubApiRequest(
        method: initial_method,
        payload: initial_payload,
        reply: initial_reply,
      ) = process.receive_forever(requests)
      process.send(payloads, payload_json(initial_payload))
      case initial_method {
        "getUpdates" -> process.send(initial_reply, Ok(two_updates_response))
        _ ->
          process.send(
            initial_reply,
            Error(error.DecodeError(
              method: initial_method,
              message: "unexpected",
            )),
          )
      }

      let StubApiRequest(payload: final_payload, reply: final_reply, ..) =
        process.receive_forever(requests)
      process.send(payloads, payload_json(final_payload))
      process.send(final_reply, Error(final_failure))
    })
  let assert Ok(requests) = receive_event(server_ready)
  let server_monitor = process.monitor(server)
  let client = api_from_requests(requests)
  let comp =
    composer.new()
    |> composer.handle(fn(ctx) {
      case ctx.update.update_id {
        1 -> panic as "first update fails"
        _ -> process.send(handled, ctx.update.update_id)
      }
    })
  let configured =
    bot.new(client, comp)
    |> bot.on_error(fn(_) { Nil })
    |> bot.on_runtime_error(fn(runtime_error) {
      let release = process.new_subject()
      process.send(callback_started, #(process.self(), runtime_error, release))
      let Nil = process.receive_forever(release)
      process.sleep_forever()
    })
  let assert Ok(bot_) =
    bot.with_callback_timeout(configured, callback_test_timeout_ms)
  let defaults = bot.default_polling_options()
  let options = bot.PollingOptions(..defaults, verify_token: False)
  let caller =
    process.spawn_unlinked(fn() {
      process.send(outcome, bot.start(bot_, options))
    })
  let caller_monitor = process.monitor(caller)

  let assert Ok(#(callback_pid, runtime_error, release)) =
    receive_event(callback_started)
  let assert bot.HandlerCrashed(update_id: 1, ..) = runtime_error
  let callback_monitor = process.monitor(callback_pid)
  process.send(release, Nil)
  assert receive_event(handled) == Ok(2)
  assert !process.is_alive(callback_pid)
  assert_monitored_process_down_within(
    callback_monitor,
    callback_pid,
    callback_test_completion_timeout_ms,
  )

  assert process.receive(outcome, lifecycle_test_timeout_ms)
    == Ok(Error(bot.ApiFailure(final_failure)))
  assert_monitored_process_down(caller_monitor, caller)
  let assert Ok(initial_payload) = receive_event(payloads)
  let assert Ok(next_payload) = receive_event(payloads)
  assert !string.contains(initial_payload, "\"offset\"")
  assert string.contains(next_payload, "\"offset\":3")
  assert_monitored_process_down(server_monitor, server)
  assert no_event(server_ready)
  assert no_event(callback_started)
  assert no_event(handled)
  assert no_event(payloads)
  assert no_event(outcome)
}

pub fn drop_pending_failure_is_not_silently_ignored_test() {
  let caught: process.Subject(String) = process.new_subject()
  let calls: process.Subject(String) = process.new_subject()
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      process.send(calls, method)
      Error(error.DecodeError(method: method, message: "drain failed"))
    })
  let bot_ =
    bot.new(client, composer.new())
    |> bot.on_error(fn(value) { process.send(caught, error.describe(value)) })
  let defaults = bot.default_polling_options()
  let options =
    bot.PollingOptions(
      ..defaults,
      verify_token: False,
      drop_pending_updates: True,
    )

  case bot.start(bot_, options) {
    Error(bot.ApiFailure(_)) -> Nil
    _ -> panic as "expected drain ApiFailure"
  }
  assert receive_event(caught)
    == Ok("Decode error in 'getUpdates': drain failed")
  assert receive_event(calls) == Ok("getUpdates")
  assert no_event(calls)
}

pub fn decode_poison_is_fatal_instead_of_retried_test() {
  let calls: process.Subject(String) = process.new_subject()
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      process.send(calls, method)
      Error(error.DecodeError(method: method, message: "poison"))
    })
  let defaults = bot.default_polling_options()
  let options = bot.PollingOptions(..defaults, verify_token: False)

  let bot_ =
    bot.new(client, composer.new())
    |> bot.on_error(fn(_) { Nil })
  case bot.start(bot_, options) {
    Error(bot.ApiFailure(_)) -> Nil
    _ -> panic as "expected poison ApiFailure"
  }
  assert receive_event(calls) == Ok("getUpdates")
  assert no_event(calls)
}

pub fn permanent_http_400_is_not_retried_test() {
  let calls: process.Subject(String) = process.new_subject()
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      process.send(calls, method)
      Error(error.HttpStatusError(method: method, status: 400, body: "bad"))
    })
  let defaults = bot.default_polling_options()
  let options = bot.PollingOptions(..defaults, verify_token: False)
  let bot_ =
    bot.new(client, composer.new())
    |> bot.on_error(fn(_) { Nil })
  case bot.start(bot_, options) {
    Error(bot.ApiFailure(_)) -> Nil
    _ -> panic as "expected permanent ApiFailure"
  }
  assert receive_event(calls) == Ok("getUpdates")
  assert no_event(calls)
}

pub fn non_utf8_http_503_is_classified_and_retried_test() {
  let attempts: process.Subject(Int) = process.new_subject()
  process.send(attempts, 0)
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      let assert Ok(attempt) = receive_event(attempts)
      process.send(attempts, attempt + 1)
      case attempt {
        0 -> {
          let assert Error(classified) =
            http_response.classify(method, 503, <<255>>)
          Error(classified)
        }
        _ ->
          Error(error.HttpStatusError(method: method, status: 400, body: "stop"))
      }
    })
  let defaults = bot.default_polling_options()
  let options = bot.PollingOptions(..defaults, verify_token: False)
  let bot_ = bot.new(client, composer.new()) |> bot.on_error(fn(_) { Nil })
  case bot.start(bot_, options) {
    Error(bot.ApiFailure(_)) -> Nil
    _ -> panic as "expected the second permanent failure to stop polling"
  }
  assert receive_event(attempts) == Ok(2)
}

// =====================================================================
//                     Handler failure policies
// =====================================================================

pub fn skip_policy_isolates_panic_and_continues_polling_test() {
  let get_updates_count: process.Subject(Int) = process.new_subject()
  process.send(get_updates_count, 0)
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      case method {
        "getMe" -> Ok(get_me_response)
        "getUpdates" -> {
          let assert Ok(count) = receive_event(get_updates_count)
          process.send(get_updates_count, count + 1)
          case count {
            0 -> Ok(updates_response)
            _ -> Error(error.DecodeError(method: method, message: "done"))
          }
        }
        _ -> Error(error.DecodeError(method: method, message: "unexpected"))
      }
    })
  let runtime_errors: process.Subject(bot.BotRuntimeError) =
    process.new_subject()
  let comp = composer.new() |> composer.handle(fn(_) { panic as "handler" })
  let bot_ =
    bot.new(client, comp)
    |> bot.on_runtime_error(fn(value) { process.send(runtime_errors, value) })
    |> bot.on_error(fn(_) { Nil })

  case bot.start(bot_, bot.default_polling_options()) {
    Error(bot.ApiFailure(_)) -> Nil
    _ -> panic as "expected final decoder failure"
  }
  case receive_event(runtime_errors) {
    Ok(runtime_error) -> {
      assert string.contains(string.inspect(runtime_error), "HandlerCrashed")
    }
    _ -> panic as "expected isolated runtime error"
  }
  assert receive_event(get_updates_count) == Ok(2)
}

pub fn gate_failure_is_fatal_even_with_default_skip_policy_test() {
  let get_updates_count: process.Subject(Int) = process.new_subject()
  process.send(get_updates_count, 0)
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      case method {
        "getMe" -> Ok(get_me_response)
        "getUpdates" -> {
          let assert Ok(count) = receive_event(get_updates_count)
          process.send(get_updates_count, count + 1)
          Ok(updates_response)
        }
        _ -> Error(error.DecodeError(method: method, message: "unexpected"))
      }
    })
  let bot_ =
    bot.new(client, composer.new())
    |> bot.with_update_gate(fn(_) {
      Error(bot.UpdateGateError("journal", "store unavailable"))
    })
    |> bot.on_runtime_error(fn(_) { Nil })

  assert bot.start(bot_, bot.default_polling_options())
    == Error(
      bot.UpdateHandlerFailure(bot.UpdateGateFailed(
        update_id: 1,
        code: "journal",
        message: "store unavailable",
      )),
    )
  assert receive_event(get_updates_count) == Ok(1)
}

pub fn gate_panic_is_fatal_even_with_default_skip_policy_test() {
  let get_updates_count: process.Subject(Int) = process.new_subject()
  process.send(get_updates_count, 0)
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      case method {
        "getMe" -> Ok(get_me_response)
        "getUpdates" -> {
          let assert Ok(count) = receive_event(get_updates_count)
          process.send(get_updates_count, count + 1)
          Ok(updates_response)
        }
        _ -> Error(error.DecodeError(method: method, message: "unexpected"))
      }
    })
  let bot_ =
    bot.new(client, composer.new())
    |> bot.with_update_gate(fn(_) { panic as "gate secret" })
    |> bot.on_runtime_error(fn(_) { Nil })

  assert bot.start(bot_, bot.default_polling_options())
    == Error(bot.UpdateHandlerFailure(bot.UpdateGateCrashed(update_id: 1)))
  assert receive_event(get_updates_count) == Ok(1)
}

pub fn stop_policy_returns_handler_failure_test() {
  let get_updates_count: process.Subject(Int) = process.new_subject()
  process.send(get_updates_count, 0)
  let client =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      case method {
        "getMe" -> Ok(get_me_response)
        "getUpdates" -> {
          let assert Ok(count) = receive_event(get_updates_count)
          process.send(get_updates_count, count + 1)
          Ok(updates_response)
        }
        _ -> Error(error.DecodeError(method: method, message: "unexpected"))
      }
    })
  let comp = composer.new() |> composer.handle(fn(_) { panic as "handler" })
  let defaults = bot.default_polling_options()
  let options =
    bot.PollingOptions(
      ..defaults,
      handler_failure_policy: bot.StopOnHandlerFailure,
    )

  let bot_ =
    bot.new(client, comp)
    |> bot.on_runtime_error(fn(_) { Nil })
  case bot.start(bot_, options) {
    Error(bot.UpdateHandlerFailure(_)) -> Nil
    _ -> panic as "expected UpdateHandlerFailure"
  }
  // A failure on the first update has no successful prefix to checkpoint.
  assert receive_event(get_updates_count) == Ok(1)
}

pub fn stop_policy_checkpoints_successful_batch_prefix_before_return_test() {
  let get_updates_count: process.Subject(Int) = process.new_subject()
  process.send(get_updates_count, 0)
  let payloads: process.Subject(String) = process.new_subject()
  let handled: process.Subject(Int) = process.new_subject()
  let client = checkpointing_client(get_updates_count, payloads, None)
  let failing_composer =
    composer.new()
    |> composer.handle(fn(ctx) {
      process.send(handled, ctx.update.update_id)
      case ctx.update.update_id {
        2 -> panic as "second update fails"
        _ -> Nil
      }
    })
  let succeeding_composer =
    composer.new()
    |> composer.handle(fn(ctx) {
      process.send(handled, ctx.update.update_id)
      Nil
    })
  let defaults = bot.default_polling_options()
  let options =
    bot.PollingOptions(
      ..defaults,
      verify_token: False,
      handler_failure_policy: bot.StopOnHandlerFailure,
    )
  let failing_bot =
    bot.new(client, failing_composer)
    |> bot.on_error(fn(_) { Nil })
    |> bot.on_runtime_error(fn(_) { Nil })
  let succeeding_bot =
    bot.new(client, succeeding_composer)
    |> bot.on_error(fn(_) { Nil })
    |> bot.on_runtime_error(fn(_) { Nil })

  let assert Error(bot.UpdateHandlerFailure(bot.HandlerCrashed(update_id: 2, ..))) =
    bot.start(failing_bot, options)
  let assert Error(bot.ApiFailure(_)) = bot.start(succeeding_bot, options)

  assert receive_event(handled) == Ok(1)
  assert receive_event(handled) == Ok(2)
  assert receive_event(handled) == Ok(2)
  assert no_event(handled)

  let assert Ok(initial_payload) = receive_event(payloads)
  let assert Ok(checkpoint_payload) = receive_event(payloads)
  let assert Ok(restart_payload) = receive_event(payloads)
  let assert Ok(final_payload) = receive_event(payloads)
  assert !string.contains(initial_payload, "\"offset\"")
  assert string.contains(initial_payload, "\"limit\":100")
  assert string.contains(checkpoint_payload, "\"offset\":2")
  assert string.contains(checkpoint_payload, "\"limit\":1")
  assert string.contains(checkpoint_payload, "\"timeout\":0")
  assert !string.contains(restart_payload, "\"offset\"")
  assert string.contains(final_payload, "\"offset\":3")
  assert receive_event(get_updates_count) == Ok(4)
}

pub fn checkpoint_failure_is_typed_and_never_skips_failed_update_test() {
  let get_updates_count: process.Subject(Int) = process.new_subject()
  process.send(get_updates_count, 0)
  let payloads: process.Subject(String) = process.new_subject()
  let handled: process.Subject(Int) = process.new_subject()
  let checkpoint_failure =
    error.HttpStatusError(
      method: "getUpdates",
      status: 400,
      body: "checkpoint rejected",
    )
  let client =
    checkpointing_client(get_updates_count, payloads, Some(checkpoint_failure))
  let failing_composer =
    composer.new()
    |> composer.handle(fn(ctx) {
      process.send(handled, ctx.update.update_id)
      case ctx.update.update_id {
        2 -> panic as "second update fails"
        _ -> Nil
      }
    })
  let succeeding_composer =
    composer.new()
    |> composer.handle(fn(ctx) {
      process.send(handled, ctx.update.update_id)
      Nil
    })
  let defaults = bot.default_polling_options()
  let options =
    bot.PollingOptions(
      ..defaults,
      verify_token: False,
      handler_failure_policy: bot.StopOnHandlerFailure,
    )
  let failing_bot =
    bot.new(client, failing_composer)
    |> bot.on_error(fn(_) { Nil })
    |> bot.on_runtime_error(fn(_) { Nil })
  let succeeding_bot =
    bot.new(client, succeeding_composer)
    |> bot.on_error(fn(_) { Nil })
    |> bot.on_runtime_error(fn(_) { Nil })

  let assert Error(bot.UpdateCheckpointFailure(
    update_failure: bot.HandlerCrashed(update_id: 2, ..),
    checkpoint_failure: error.HttpStatusError(status: 400, ..),
  )) = bot.start(failing_bot, options)
  let assert Error(bot.ApiFailure(_)) = bot.start(succeeding_bot, options)

  assert receive_event(handled) == Ok(1)
  assert receive_event(handled) == Ok(2)
  // The rejected checkpoint leaves the whole batch eligible for replay.
  assert receive_event(handled) == Ok(1)
  assert receive_event(handled) == Ok(2)
  assert no_event(handled)

  let assert Ok(_) = receive_event(payloads)
  let assert Ok(checkpoint_payload) = receive_event(payloads)
  let assert Ok(restart_payload) = receive_event(payloads)
  let assert Ok(final_payload) = receive_event(payloads)
  assert string.contains(checkpoint_payload, "\"offset\":2")
  assert !string.contains(restart_payload, "\"offset\"")
  assert string.contains(final_payload, "\"offset\":3")
  assert receive_event(get_updates_count) == Ok(4)
}

pub fn gate_failure_checkpoints_prefix_under_default_skip_policy_test() {
  let get_updates_count: process.Subject(Int) = process.new_subject()
  process.send(get_updates_count, 0)
  let payloads: process.Subject(String) = process.new_subject()
  let gate_seen: process.Subject(Int) = process.new_subject()
  let handled: process.Subject(Int) = process.new_subject()
  let client = checkpointing_client(get_updates_count, payloads, None)
  let first_composer =
    composer.new()
    |> composer.handle(fn(ctx) {
      process.send(handled, ctx.update.update_id)
      Nil
    })
  let first_bot =
    bot.new(client, first_composer)
    |> bot.with_update_gate(fn(ctx) {
      process.send(gate_seen, ctx.update.update_id)
      case ctx.update.update_id {
        2 -> Error(bot.UpdateGateError("journal", "store unavailable"))
        _ -> Ok(bot.Continue)
      }
    })
    |> bot.on_error(fn(_) { Nil })
    |> bot.on_runtime_error(fn(_) { Nil })
  let restart_bot =
    bot.new(
      client,
      composer.new()
        |> composer.handle(fn(ctx) {
          process.send(handled, ctx.update.update_id)
          Nil
        }),
    )
    |> bot.on_error(fn(_) { Nil })
    |> bot.on_runtime_error(fn(_) { Nil })
  let defaults = bot.default_polling_options()
  let options = bot.PollingOptions(..defaults, verify_token: False)

  assert bot.start(first_bot, options)
    == Error(
      bot.UpdateHandlerFailure(bot.UpdateGateFailed(
        update_id: 2,
        code: "journal",
        message: "store unavailable",
      )),
    )
  let assert Error(bot.ApiFailure(_)) = bot.start(restart_bot, options)

  assert receive_event(gate_seen) == Ok(1)
  assert receive_event(gate_seen) == Ok(2)
  assert receive_event(handled) == Ok(1)
  assert receive_event(handled) == Ok(2)
  assert no_event(handled)
  let assert Ok(_) = receive_event(payloads)
  let assert Ok(checkpoint_payload) = receive_event(payloads)
  assert string.contains(checkpoint_payload, "\"offset\":2")
  assert receive_event(get_updates_count) == Ok(4)
}

pub fn gate_panic_checkpoints_only_prefix_under_default_skip_policy_test() {
  let get_updates_count: process.Subject(Int) = process.new_subject()
  process.send(get_updates_count, 0)
  let payloads: process.Subject(String) = process.new_subject()
  let gate_seen: process.Subject(Int) = process.new_subject()
  let handled: process.Subject(Int) = process.new_subject()
  let client = checkpointing_client(get_updates_count, payloads, None)
  let bot_ =
    bot.new(
      client,
      composer.new()
        |> composer.handle(fn(ctx) {
          process.send(handled, ctx.update.update_id)
          Nil
        }),
    )
    |> bot.with_update_gate(fn(ctx) {
      process.send(gate_seen, ctx.update.update_id)
      case ctx.update.update_id {
        2 -> panic as "gate secret"
        _ -> Ok(bot.Continue)
      }
    })
    |> bot.on_error(fn(_) { Nil })
    |> bot.on_runtime_error(fn(_) { Nil })
  let defaults = bot.default_polling_options()
  let options = bot.PollingOptions(..defaults, verify_token: False)

  assert bot.start(bot_, options)
    == Error(bot.UpdateHandlerFailure(bot.UpdateGateCrashed(update_id: 2)))
  assert receive_event(gate_seen) == Ok(1)
  assert receive_event(gate_seen) == Ok(2)
  assert receive_event(handled) == Ok(1)
  assert no_event(handled)
  let assert Ok(_) = receive_event(payloads)
  let assert Ok(checkpoint_payload) = receive_event(payloads)
  assert string.contains(checkpoint_payload, "\"offset\":2")
  assert receive_event(get_updates_count) == Ok(2)
}

pub fn timeout_is_fatal_under_default_skip_and_checkpoints_prefix_test() {
  let get_updates_count: process.Subject(Int) = process.new_subject()
  process.send(get_updates_count, 0)
  let payloads: process.Subject(String) = process.new_subject()
  let handled: process.Subject(Int) = process.new_subject()
  let client = checkpointing_client(get_updates_count, payloads, None)
  let timing_out_composer =
    composer.new()
    |> composer.handle(fn(ctx) {
      process.send(handled, ctx.update.update_id)
      case ctx.update.update_id {
        2 -> process.sleep_forever()
        _ -> Nil
      }
    })
  let succeeding_composer =
    composer.new()
    |> composer.handle(fn(ctx) {
      process.send(handled, ctx.update.update_id)
      Nil
    })
  let defaults = bot.default_polling_options()
  let options =
    bot.PollingOptions(..defaults, verify_token: False, handler_timeout_ms: 50)
  let timing_out_bot =
    bot.new(client, timing_out_composer)
    |> bot.on_error(fn(_) { Nil })
    |> bot.on_runtime_error(fn(_) { Nil })
  let succeeding_bot =
    bot.new(client, succeeding_composer)
    |> bot.on_error(fn(_) { Nil })
    |> bot.on_runtime_error(fn(_) { Nil })

  assert bot.start(timing_out_bot, options)
    == Error(
      bot.UpdateHandlerFailure(bot.HandlerTimedOut(update_id: 2, timeout_ms: 50)),
    )
  let assert Error(bot.ApiFailure(_)) = bot.start(succeeding_bot, options)

  assert receive_event(handled) == Ok(1)
  assert receive_event(handled) == Ok(2)
  assert receive_event(handled) == Ok(2)
  assert no_event(handled)
  let assert Ok(_) = receive_event(payloads)
  let assert Ok(checkpoint_payload) = receive_event(payloads)
  assert string.contains(checkpoint_payload, "\"offset\":2")
  assert receive_event(get_updates_count) == Ok(4)
}
