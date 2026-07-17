//// Conversation actor, routing, race, and lifecycle tests.

import glammy/bot
import glammy/composer
import glammy/context
import glammy/conversations
import glammy/helpers.{dummy_api, receive_event}
import glammy/types.{type Update}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}

const successful_wait_timeout_ms = 2000

const expected_timeout_ms = 30

const stop_stress_count = 32

type WorkerExit {
  WorkerExit(process.Down)
}

type FlowProbe {
  Deliver(token: Int, generation: Int, update: Update)
}

fn registry() -> conversations.Registry {
  let assert Ok(registry) = conversations.new_registry()
  registry
}

fn update(text: String, chat_id: Int, user_id: Int) -> Update {
  let command_entity = case text {
    "/ask" ->
      ",\"entities\":[{\"type\":\"bot_command\",\"offset\":0,\"length\":4}]"
    _ -> ""
  }
  let body =
    "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":"
    <> int.to_string(chat_id)
    <> ",\"type\":\"private\"},\"date\":0,\"text\":\""
    <> text
    <> "\""
    <> command_entity
    <> ",\"from\":{\"id\":"
    <> int.to_string(user_id)
    <> ",\"is_bot\":false,\"first_name\":\"U\"}}}"
  let assert Ok(value) = json.parse(body, types.update_decoder())
  value
}

fn ctx(value: Update) -> context.Context {
  context.new(value, dummy_api())
}

fn business_connection_ctx() -> context.Context {
  let body =
    "{\"update_id\":2,\"business_connection\":{\"id\":\"conn\",\"user\":{\"id\":99,\"is_bot\":false,\"first_name\":\"U\"},\"user_chat_id\":700,\"date\":1,\"is_enabled\":true}}"
  let assert Ok(value) = json.parse(body, types.update_decoder())
  ctx(value)
}

pub fn conversation_does_not_block_dispatch_test() {
  let registry = registry()
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
    |> composer.command("ask", fn(ctx) {
      let _ =
        conversations.start(registry, ctx, fn(wait) {
          process.send(recorder, "asked")
          case wait(successful_wait_timeout_ms) {
            Ok(reply_ctx) -> {
              let assert Some(text) = context.message_text(reply_ctx)
              process.send(recorder, "answer:" <> text)
            }
            Error(_) -> process.send(recorder, "timeout")
          }
        })
      Nil
    })

  // This call returns while the conversation worker waits. The old
  // synchronous implementation deadlocked long polling here.
  composer.run(comp, ctx(update("/ask", 1, 1)))
  assert receive_event(recorder) == Ok("asked")
  composer.run(comp, ctx(update("Ada", 1, 1)))
  assert receive_event(recorder) == Ok("answer:Ada")
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn registration_is_active_before_start_returns_test() {
  let registry = registry()
  let recorder: process.Subject(String) = process.new_subject()
  let worker_ready: process.Subject(#(process.Pid, process.Subject(Nil))) =
    process.new_subject()
  let route_done: process.Subject(Nil) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
    |> composer.command("ask", fn(ctx) {
      let _ =
        conversations.start(registry, ctx, fn(wait) {
          // Hold the worker before `wait`, proving that the registered route
          // buffers a reply without relying on scheduler timing.
          let release: process.Subject(Nil) = process.new_subject()
          process.send(worker_ready, #(process.self(), release))
          process.receive_forever(release)
          case wait(successful_wait_timeout_ms) {
            Ok(reply_ctx) -> {
              let assert Some(text) = context.message_text(reply_ctx)
              process.send(recorder, text)
            }
            Error(_) -> process.send(recorder, "error")
          }
        })
      Nil
    })

  composer.run(comp, ctx(update("/ask", 1, 1)))
  let assert Ok(#(worker_pid, release)) = receive_event(worker_ready)
  let queue_length = message_queue_length(worker_pid)
  run_composer_async(comp, ctx(update("immediate", 1, 1)), route_done)
  assert wait_for_message_queue_growth(worker_pid, queue_length, 1000)
  // Route success now waits for the matching wait to dequeue and receipt-ACK
  // the delivery; mailbox enqueue alone is not enough.
  assert process.receive(route_done, 20) == Error(Nil)
  process.send(release, Nil)
  assert receive_event(recorder) == Ok("immediate")
  assert receive_event(route_done) == Ok(Nil)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn suspended_worker_routes_only_after_matching_receipt_test() {
  let registry = registry()
  let worker_ready: process.Subject(process.Pid) = process.new_subject()
  let wait_result: process.Subject(String) = process.new_subject()
  let passed: process.Subject(Nil) = process.new_subject()
  let errors: process.Subject(conversations.RegistryError) =
    process.new_subject()
  let route_done: process.Subject(Nil) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("start", 1, 1)), fn(wait) {
      process.send(worker_ready, process.self())
      process.send(wait_result, text_or_error(wait(successful_wait_timeout_ms)))
    })
  let assert Ok(worker_pid) = receive_event(worker_ready)
  assert suspend_process(worker_pid)
  let queue_length = message_queue_length(worker_pid)
  let router =
    composer.new()
    |> composer.use_middleware(
      conversations.middleware_with_error(registry, fn(error) {
        process.send(errors, error)
      }),
    )
    |> composer.handle(fn(_) { process.send(passed, Nil) })
  let queued_ctx = ctx(update("queued", 1, 1))

  run_composer_async(router, queued_ctx, route_done)
  assert wait_for_message_queue_growth(worker_pid, queue_length, 1000)
  assert process.receive(route_done, 20) == Error(Nil)
  assert process.receive(passed, 0) == Error(Nil)
  assert process.receive(errors, 0) == Error(Nil)
  let retry_gate = conversations.update_gate(registry)
  assert retry_gate(queued_ctx)
    == Error(bot.UpdateGateError(
      "conversation_route_outcome_unknown",
      "conversation route receipt outcome is unknown",
    ))

  assert resume_process(worker_pid)
  assert receive_event(wait_result) == Ok("queued")
  assert receive_event(route_done) == Ok(Nil)
  assert process.receive(passed, 0) == Error(Nil)
  assert process.receive(errors, 0) == Error(Nil)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn crash_before_delivery_receipt_makes_update_gate_fail_test() {
  let registry = registry()
  let worker_ready: process.Subject(#(process.Pid, process.Subject(Nil))) =
    process.new_subject()
  let gate_done: process.Subject(Result(bot.UpdateAction, bot.UpdateGateError)) =
    process.new_subject()
  let outcome: process.Subject(conversations.ConversationOutcome) =
    process.new_subject()
  let assert Ok(_) =
    conversations.start_with_outcome(
      registry,
      ctx(update("start", 1, 1)),
      fn(_) {
        let crash: process.Subject(Nil) = process.new_subject()
        process.send(worker_ready, #(process.self(), crash))
        process.receive_forever(crash)
        panic as "crash before delivery receipt"
      },
      fn(value) { process.send(outcome, value) },
    )
  let assert Ok(#(worker_pid, crash)) = receive_event(worker_ready)
  let queue_length = message_queue_length(worker_pid)
  let gate = conversations.update_gate(registry)

  let _ =
    process.spawn_unlinked(fn() {
      process.send(gate_done, gate(ctx(update("uncertain", 1, 1))))
    })
  assert wait_for_message_queue_growth(worker_pid, queue_length, 1000)
  assert process.receive(gate_done, 20) == Error(Nil)
  process.send(crash, Nil)

  assert receive_event(gate_done)
    == Ok(
      Error(bot.UpdateGateError(
        "conversation_route_outcome_unknown",
        "conversation route receipt outcome is unknown",
      )),
    )
  let assert Ok(conversations.ConversationCrashed(_)) = receive_event(outcome)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn replacement_before_delivery_receipt_fails_route_closed_test() {
  let registry = registry()
  let old_worker_ready: process.Subject(process.Pid) = process.new_subject()
  let passed: process.Subject(Nil) = process.new_subject()
  let errors: process.Subject(conversations.RegistryError) =
    process.new_subject()
  let route_done: process.Subject(Nil) = process.new_subject()
  let start_ctx = ctx(update("start", 1, 1))
  let assert Ok(_) =
    conversations.start(registry, start_ctx, fn(_) {
      process.send(old_worker_ready, process.self())
      process.sleep_forever()
    })
  let assert Ok(old_worker_pid) = receive_event(old_worker_ready)
  let old_worker_monitor = process.monitor(old_worker_pid)
  let queue_length = message_queue_length(old_worker_pid)
  let router =
    composer.new()
    |> composer.use_middleware(
      conversations.middleware_with_error(registry, fn(error) {
        process.send(errors, error)
      }),
    )
    |> composer.handle(fn(_) { process.send(passed, Nil) })

  run_composer_async(router, ctx(update("uncertain", 1, 1)), route_done)
  assert wait_for_message_queue_growth(old_worker_pid, queue_length, 1000)
  assert process.receive(route_done, 20) == Error(Nil)
  let assert Ok(_) =
    conversations.start(registry, start_ctx, fn(_) { process.sleep_forever() })

  assert receive_event(errors) == Ok(conversations.RouteOutcomeUnknown)
  assert receive_event(route_done) == Ok(Nil)
  assert process.receive(passed, 20) == Error(Nil)
  assert monitor_went_down(old_worker_monitor)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn successive_waits_use_fresh_generations_test() {
  let registry = registry()
  let recorder: process.Subject(String) = process.new_subject()
  let passed: process.Subject(Nil) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
    |> composer.command("ask", fn(ctx) {
      let _ =
        conversations.start(registry, ctx, fn(wait) {
          let first = wait(successful_wait_timeout_ms)
          process.send(recorder, text_or_error(first))
          let second = wait(successful_wait_timeout_ms)
          process.send(recorder, text_or_error(second))
        })
      Nil
    })
    |> composer.handle(fn(_) { process.send(passed, Nil) })

  composer.run(comp, ctx(update("/ask", 1, 1)))
  // `command` continues through later middleware after starting the flow.
  // Discard that correlated pass before probing ordinary routed updates.
  let _ = process.receive(passed, 0)
  composer.run(comp, ctx(update("one", 1, 1)))
  assert receive_event(recorder) == Ok("one")
  route_until_claimed_by_wait(comp, passed, 100)
  assert receive_event(recorder) == Ok("two")
  assert conversations.stop_registry(registry) == Ok(Nil)
}

fn route_until_claimed_by_wait(
  comp: composer.Composer,
  passed: process.Subject(Nil),
  attempts_left: Int,
) -> Nil {
  case attempts_left <= 0 {
    True -> panic as "second wait never registered"
    False -> {
      composer.run(comp, ctx(update("two", 1, 1)))
      case process.receive(passed, 0) {
        Ok(Nil) -> {
          process.sleep(1)
          route_until_claimed_by_wait(comp, passed, attempts_left - 1)
        }
        Error(_) -> Nil
      }
    }
  }
}

pub fn conversation_times_out_test() {
  let registry = registry()
  let recorder: process.Subject(String) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("hi", 1, 1)), fn(wait) {
      case wait(expected_timeout_ms) {
        Error(conversations.Timeout) -> process.send(recorder, "timeout")
        _ -> process.send(recorder, "unexpected")
      }
    })
  assert receive_event(recorder) == Ok("timeout")
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn conversation_outcome_reports_completion_test() {
  let registry = registry()
  let outcome: process.Subject(conversations.ConversationOutcome) =
    process.new_subject()
  let assert Ok(_) =
    conversations.start_with_outcome(
      registry,
      ctx(update("hi", 1, 1)),
      fn(_) { Nil },
      fn(value) { process.send(outcome, value) },
    )

  assert receive_event(outcome) == Ok(conversations.ConversationCompleted)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn conversation_outcome_reports_crash_test() {
  let registry = registry()
  let outcome: process.Subject(conversations.ConversationOutcome) =
    process.new_subject()
  let assert Ok(_) =
    conversations.start_with_outcome(
      registry,
      ctx(update("hi", 1, 1)),
      fn(_) { panic as "conversation boom" },
      fn(value) { process.send(outcome, value) },
    )

  let assert Ok(conversations.ConversationCrashed(_)) = receive_event(outcome)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn ambiguous_pause_fail_stops_with_typed_outcome_test() {
  let assert Ok(registry) =
    conversations.new_registry_with_options(conversations.by_chat_and_user, 30)
  let ready: process.Subject(process.Subject(Nil)) = process.new_subject()
  let continued: process.Subject(Nil) = process.new_subject()
  let outcome: process.Subject(conversations.ConversationOutcome) =
    process.new_subject()
  let assert Ok(_) =
    conversations.start_with_outcome(
      registry,
      ctx(update("start", 1, 1)),
      fn(wait) {
        let release = process.new_subject()
        process.send(ready, release)
        process.receive_forever(release)
        let _ = wait(0)
        process.send(continued, Nil)
      },
      fn(value) { process.send(outcome, value) },
    )
  let assert Ok(release) = receive_event(ready)
  let registry_process = registry_pid(3, registry)
  assert suspend_process(registry_process)
  process.send(release, Nil)
  let observed = receive_event(outcome)
  assert resume_process(registry_process)
  assert observed
    == Ok(conversations.ConversationFailed(
      conversations.WaitStateOutcomeUnknown,
    ))
  assert process.receive(continued, 20) == Error(Nil)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn ambiguous_delivery_receipt_fail_stops_with_typed_outcome_test() {
  let assert Ok(registry) =
    conversations.new_registry_with_options(conversations.by_chat_and_user, 100)
  let worker_ready: process.Subject(process.Pid) = process.new_subject()
  let continued: process.Subject(Nil) = process.new_subject()
  let gate_done: process.Subject(Result(bot.UpdateAction, bot.UpdateGateError)) =
    process.new_subject()
  let outcome: process.Subject(conversations.ConversationOutcome) =
    process.new_subject()
  let assert Ok(_) =
    conversations.start_with_outcome(
      registry,
      ctx(update("start", 1, 1)),
      fn(wait) {
        process.send(worker_ready, process.self())
        let _ = wait(successful_wait_timeout_ms)
        process.send(continued, Nil)
      },
      fn(value) { process.send(outcome, value) },
    )
  let assert Ok(worker_pid) = receive_event(worker_ready)
  assert suspend_process(worker_pid)
  let queue_length = message_queue_length(worker_pid)
  let gate = conversations.update_gate(registry)
  let _ =
    process.spawn_unlinked(fn() {
      process.send(gate_done, gate(ctx(update("queued", 1, 1))))
    })
  assert wait_for_message_queue_growth(worker_pid, queue_length, 1000)

  let registry_process = registry_pid(3, registry)
  assert suspend_process(registry_process)
  assert resume_process(worker_pid)
  assert receive_event(outcome)
    == Ok(conversations.ConversationFailed(
      conversations.WaitStateOutcomeUnknown,
    ))
  assert receive_event(gate_done)
    == Ok(
      Error(bot.UpdateGateError(
        "conversation_route_outcome_unknown",
        "conversation route receipt outcome is unknown",
      )),
    )
  assert process.receive(continued, 20) == Error(Nil)

  assert resume_process(registry_process)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn cooperative_stop_reaches_cancelled_wait_and_reports_stop_test() {
  let registry = registry()
  let ready: process.Subject(Nil) = process.new_subject()
  let wait_result: process.Subject(
    Result(context.Context, conversations.WaitError),
  ) = process.new_subject()
  let outcome: process.Subject(conversations.ConversationOutcome) =
    process.new_subject()
  let assert Ok(conversation) =
    conversations.start_with_outcome(
      registry,
      ctx(update("hi", 1, 1)),
      fn(wait) {
        process.send(ready, Nil)
        process.send(wait_result, wait(successful_wait_timeout_ms))
      },
      fn(value) { process.send(outcome, value) },
    )
  assert receive_event(ready) == Ok(Nil)

  assert conversations.stop_conversation(conversation) == Ok(Nil)
  assert receive_event(wait_result) == Ok(Error(conversations.Cancelled))
  assert receive_event(outcome) == Ok(conversations.ConversationStopped)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn stale_deliveries_do_not_reset_wait_deadline_test() {
  let registry = registry()
  let ready: process.Subject(process.Subject(Nil)) = process.new_subject()
  let outcome: process.Subject(String) = process.new_subject()
  let assert Ok(conversation) =
    conversations.start(registry, ctx(update("start", 1, 1)), fn(wait) {
      let release: process.Subject(Nil) = process.new_subject()
      process.send(ready, release)
      process.receive_forever(release)
      process.send(outcome, text_or_error(wait(200)))
    })
  let assert Ok(release) = receive_event(ready)

  // White-box injection proves a stale generation cannot restart the full
  // timeout. A matching delivery arrives after the original deadline but
  // before the old recursive implementation's extended deadline.
  let subject = conversation_subject(5, conversation)
  let token = conversation_token(4, conversation)
  process.send(release, Nil)
  let _ =
    process.send_after(subject, 150, Deliver(-1, -1, update("stale", 1, 1)))
  let _ =
    process.send_after(subject, 300, Deliver(token, 0, update("late", 1, 1)))

  assert receive_event(outcome) == Ok("timeout")
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn negative_wait_timeout_is_typed_error_test() {
  let registry = registry()
  let recorder: process.Subject(String) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("hi", 1, 1)), fn(wait) {
      case wait(-1) {
        Error(conversations.InvalidWaitTimeout(-1)) ->
          process.send(recorder, "invalid")
        _ -> process.send(recorder, "unexpected")
      }
    })
  assert receive_event(recorder) == Ok("invalid")
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn oversized_wait_timeout_is_typed_error_test() {
  let registry = registry()
  let recorder: process.Subject(String) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("hi", 1, 1)), fn(wait) {
      case wait(4_294_967_296) {
        Error(conversations.InvalidWaitTimeout(4_294_967_296)) ->
          process.send(recorder, "invalid")
        _ -> process.send(recorder, "unexpected")
      }
    })
  assert receive_event(recorder) == Ok("invalid")
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn maximum_wait_timeout_is_accepted_by_beam_test() {
  let registry = registry()
  let ready: process.Subject(Nil) = process.new_subject()
  let wait_result: process.Subject(
    Result(context.Context, conversations.WaitError),
  ) = process.new_subject()
  let assert Ok(conversation) =
    conversations.start(registry, ctx(update("hi", 1, 1)), fn(wait) {
      process.send(ready, Nil)
      process.send(wait_result, wait(4_294_967_295))
    })
  assert receive_event(ready) == Ok(Nil)
  assert conversations.stop_conversation(conversation) == Ok(Nil)
  assert receive_event(wait_result) == Ok(Error(conversations.Cancelled))
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn replacement_cannot_be_unregistered_by_old_worker_test() {
  let registry = registry()
  let recorder: process.Subject(String) = process.new_subject()
  let old_worker: process.Subject(process.Pid) = process.new_subject()
  let start_ctx = ctx(update("hi", 1, 1))

  let assert Ok(_) =
    conversations.start(registry, start_ctx, fn(_) {
      process.send(old_worker, process.self())
      process.sleep_forever()
    })
  let assert Ok(old_pid) = receive_event(old_worker)
  let old_monitor = process.monitor(old_pid)

  let assert Ok(_) =
    conversations.start(registry, start_ctx, fn(wait) {
      process.send(recorder, "new-ready")
      process.send(
        recorder,
        "new:" <> text_or_error(wait(successful_wait_timeout_ms)),
      )
    })
  assert monitor_went_down(old_monitor)
  assert receive_event(recorder) == Ok("new-ready")

  let router =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
  composer.run(router, ctx(update("winner", 1, 1)))
  assert receive_event(recorder) == Ok("new:winner")
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn default_key_is_chat_and_user_test() {
  let registry = registry()
  let recorder: process.Subject(String) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("start", 1, 9)), fn(wait) {
      process.send(recorder, text_or_error(wait(successful_wait_timeout_ms)))
    })
  let router =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
    |> composer.handle(fn(_) { process.send(recorder, "passed") })

  // Same user in another chat must not satisfy the conversation.
  composer.run(router, ctx(update("wrong-chat", 2, 9)))
  assert receive_event(recorder) == Ok("passed")
  composer.run(router, ctx(update("right-chat", 1, 9)))
  assert receive_event(recorder) == Ok("right-chat")
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn key_helpers_use_business_connection_destination_test() {
  let business_ctx = business_connection_ctx()
  assert conversations.by_chat_id(business_ctx) == Some("700")
  assert conversations.by_user_id(business_ctx) == Some("99")
  assert conversations.by_chat_and_user(business_ctx) == Some("700:99")
}

pub fn registry_key_is_configurable_test() {
  let assert Ok(registry) =
    conversations.new_registry_with_key(conversations.by_user_id)
  let recorder: process.Subject(String) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("start", 1, 9)), fn(wait) {
      process.send(recorder, text_or_error(wait(successful_wait_timeout_ms)))
    })
  let router =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
  composer.run(router, ctx(update("other-chat", 2, 9)))
  assert receive_event(recorder) == Ok("other-chat")
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn stop_conversation_kills_worker_hung_before_wait_test() {
  let registry = registry()
  let worker: process.Subject(process.Pid) = process.new_subject()
  let passed: process.Subject(Nil) = process.new_subject()
  let errors: process.Subject(conversations.RegistryError) =
    process.new_subject()
  let route_done: process.Subject(Nil) = process.new_subject()
  let assert Ok(conversation) =
    conversations.start(registry, ctx(update("start", 1, 1)), fn(_) {
      process.send(worker, process.self())
      process.sleep_forever()
    })
  let assert Ok(worker_pid) = receive_event(worker)
  let monitor = process.monitor(worker_pid)
  let queue_length = message_queue_length(worker_pid)
  let router =
    composer.new()
    |> composer.use_middleware(
      conversations.middleware_with_error(registry, fn(error) {
        process.send(errors, error)
      }),
    )
    |> composer.handle(fn(_) { process.send(passed, Nil) })
  run_composer_async(router, ctx(update("pending", 1, 1)), route_done)
  assert wait_for_message_queue_growth(worker_pid, queue_length, 1000)
  assert process.receive(route_done, 20) == Error(Nil)

  assert conversations.stop_conversation(conversation) == Ok(Nil)
  assert receive_event(errors) == Ok(conversations.RouteOutcomeUnknown)
  assert receive_event(route_done) == Ok(Nil)
  assert process.receive(passed, 20) == Error(Nil)
  assert monitor_went_down(monitor)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn stop_registry_kills_worker_hung_before_wait_and_is_idempotent_test() {
  let registry = registry()
  let worker: process.Subject(process.Pid) = process.new_subject()
  let passed: process.Subject(Nil) = process.new_subject()
  let errors: process.Subject(conversations.RegistryError) =
    process.new_subject()
  let route_done: process.Subject(Nil) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("start", 1, 1)), fn(_) {
      process.send(worker, process.self())
      process.sleep_forever()
    })
  let assert Ok(worker_pid) = receive_event(worker)
  let monitor = process.monitor(worker_pid)
  let queue_length = message_queue_length(worker_pid)
  let router =
    composer.new()
    |> composer.use_middleware(
      conversations.middleware_with_error(registry, fn(error) {
        process.send(errors, error)
      }),
    )
    |> composer.handle(fn(_) { process.send(passed, Nil) })
  run_composer_async(router, ctx(update("pending", 1, 1)), route_done)
  assert wait_for_message_queue_growth(worker_pid, queue_length, 1000)
  assert process.receive(route_done, 20) == Error(Nil)

  assert conversations.stop_registry(registry) == Ok(Nil)
  assert receive_event(errors) == Ok(conversations.RouteOutcomeUnknown)
  assert receive_event(route_done) == Ok(Nil)
  assert process.receive(passed, 20) == Error(Nil)
  assert conversations.stop_registry(registry) == Ok(Nil)
  assert monitor_went_down(monitor)
}

pub fn abnormal_registry_death_kills_worker_hung_before_wait_test() {
  let registry = registry()
  let worker: process.Subject(process.Pid) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("start", 1, 1)), fn(_) {
      process.send(worker, process.self())
      process.sleep_forever()
    })
  let assert Ok(worker_pid) = receive_event(worker)
  let worker_monitor = process.monitor(worker_pid)
  let registry_pid = registry_pid(3, registry)

  process.unlink(registry_pid)
  process.kill(registry_pid)

  assert monitor_went_down(worker_monitor)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn concurrent_registry_stop_is_idempotent_and_waits_for_down_test() {
  let registry = registry()
  let worker: process.Subject(process.Pid) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("start", 1, 1)), fn(_) {
      process.send(worker, process.self())
      process.sleep_forever()
    })
  let assert Ok(worker_pid) = receive_event(worker)
  let worker_monitor = process.monitor(worker_pid)
  let ready: process.Subject(process.Subject(Nil)) = process.new_subject()
  let outcomes: process.Subject(Result(Nil, conversations.RegistryError)) =
    process.new_subject()

  spawn_registry_stoppers(registry, ready, outcomes, stop_stress_count)
  collect_release_subjects(ready, stop_stress_count)
  |> list.each(fn(release) { process.send(release, Nil) })

  assert receive_ok_nil_results(outcomes, stop_stress_count)
  assert conversations.stop_registry(registry) == Ok(Nil)
  assert conversations.stop_registry(registry) == Ok(Nil)
  assert monitor_went_down(worker_monitor)
  case conversations.start(registry, ctx(update("late", 1, 1)), fn(_) { Nil }) {
    Error(conversations.RegistryUnavailable(conversations.Stopped)) -> Nil
    _ -> panic as "registry was still callable after stop returned"
  }
}

pub fn middleware_reports_stopped_registry_and_passes_test() {
  let registry = registry()
  assert conversations.stop_registry(registry) == Ok(Nil)
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(
      conversations.middleware_with_error(registry, fn(error) {
        case error {
          conversations.Stopped -> process.send(recorder, "stopped")
          _ -> process.send(recorder, "other")
        }
      }),
    )
    |> composer.handle(fn(_) { process.send(recorder, "passed") })
  composer.run(comp, ctx(update("hi", 1, 1)))
  assert receive_event(recorder) == Ok("stopped")
  assert receive_event(recorder) == Ok("passed")
}

pub fn start_rejects_update_without_default_key_test() {
  let registry = registry()
  let assert Ok(channel_post) =
    json.parse(
      "{\"update_id\":1,\"channel_post\":{\"message_id\":1,\"chat\":{\"id\":-100,\"type\":\"channel\",\"title\":\"ch\"},\"date\":0,\"text\":\"hi\"}}",
      types.update_decoder(),
    )
  assert conversations.start(registry, ctx(channel_post), fn(_) { Nil })
    == Error(conversations.MissingKey)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn invalid_registry_timeout_is_rejected_test() {
  assert conversations.new_registry_with_options(
      conversations.by_chat_and_user,
      0,
    )
    == Error(conversations.InvalidCallTimeout(0))

  assert conversations.new_registry_with_options(
      conversations.by_chat_and_user,
      4_294_967_296,
    )
    == Error(conversations.InvalidCallTimeout(4_294_967_296))

  let assert Ok(maximum) =
    conversations.new_registry_with_options(
      conversations.by_chat_and_user,
      4_294_967_295,
    )
  assert conversations.stop_registry(maximum) == Ok(Nil)
}

fn run_composer_async(
  comp: composer.Composer,
  ctx: context.Context,
  done: process.Subject(Nil),
) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      composer.run(comp, ctx)
      process.send(done, Nil)
    })
  Nil
}

fn message_queue_length(pid: process.Pid) -> Int {
  let #(_, length) = process_info(pid, atom.create("message_queue_len"))
  length
}

fn wait_for_message_queue_growth(
  pid: process.Pid,
  baseline: Int,
  attempts_left: Int,
) -> Bool {
  case message_queue_length(pid) > baseline {
    True -> True
    False ->
      case attempts_left <= 0 {
        True -> False
        False -> {
          process.sleep(1)
          wait_for_message_queue_growth(pid, baseline, attempts_left - 1)
        }
      }
  }
}

fn text_or_error(
  result: Result(context.Context, conversations.WaitError),
) -> String {
  case result {
    Ok(ctx) -> context.message_text(ctx) |> option.unwrap("none")
    Error(conversations.Timeout) -> "timeout"
    Error(conversations.InvalidWaitTimeout(_)) -> "invalid-timeout"
    Error(conversations.Cancelled) -> "cancelled"
    Error(conversations.RegistryUnavailableWhileWaiting(_)) -> "registry-error"
  }
}

fn monitor_went_down(monitor: process.Monitor) -> Bool {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, WorkerExit)
  case process.selector_receive(selector, helpers.async_timeout_ms) {
    Ok(WorkerExit(_)) -> True
    Error(_) -> False
  }
}

fn spawn_registry_stoppers(
  registry: conversations.Registry,
  ready: process.Subject(process.Subject(Nil)),
  outcomes: process.Subject(Result(Nil, conversations.RegistryError)),
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let _ =
        process.spawn_unlinked(fn() {
          let release: process.Subject(Nil) = process.new_subject()
          process.send(ready, release)
          process.receive_forever(release)
          process.send(outcomes, conversations.stop_registry(registry))
        })
      spawn_registry_stoppers(registry, ready, outcomes, remaining - 1)
    }
  }
}

fn collect_release_subjects(
  ready: process.Subject(process.Subject(Nil)),
  remaining: Int,
) -> List(process.Subject(Nil)) {
  case remaining <= 0 {
    True -> []
    False -> {
      let assert Ok(release) = receive_event(ready)
      [release, ..collect_release_subjects(ready, remaining - 1)]
    }
  }
}

fn receive_ok_nil_results(
  outcomes: process.Subject(Result(Nil, error)),
  remaining: Int,
) -> Bool {
  case remaining <= 0 {
    True -> True
    False ->
      case receive_event(outcomes) {
        Ok(Ok(Nil)) -> receive_ok_nil_results(outcomes, remaining - 1)
        _ -> False
      }
  }
}

@external(erlang, "erlang", "element")
fn conversation_subject(
  index: Int,
  conversation: conversations.Conversation,
) -> process.Subject(FlowProbe)

@external(erlang, "erlang", "suspend_process")
fn suspend_process(pid: process.Pid) -> Bool

@external(erlang, "erlang", "resume_process")
fn resume_process(pid: process.Pid) -> Bool

@external(erlang, "erlang", "element")
fn conversation_token(
  index: Int,
  conversation: conversations.Conversation,
) -> Int

@external(erlang, "erlang", "element")
fn registry_pid(index: Int, registry: conversations.Registry) -> process.Pid

@external(erlang, "erlang", "process_info")
fn process_info(pid: process.Pid, key: Atom) -> #(Atom, Int)
