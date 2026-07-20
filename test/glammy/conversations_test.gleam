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

pub fn successive_waits_buffer_one_update_during_work_test() {
  let registry = registry()
  let recorder: process.Subject(String) = process.new_subject()
  let between_waits: process.Subject(process.Subject(Nil)) =
    process.new_subject()
  let passed: process.Subject(Nil) = process.new_subject()
  let route_done: process.Subject(Nil) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
    |> composer.command("ask", fn(ctx) {
      let _ =
        conversations.start(registry, ctx, fn(wait) {
          let first = wait(successful_wait_timeout_ms)
          process.send(recorder, text_or_error(first))
          let resume: process.Subject(Nil) = process.new_subject()
          process.send(between_waits, resume)
          process.receive_forever(resume)
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
  let assert Ok(resume) = receive_event(between_waits)

  // Route exactly once while the flow is doing work and has not registered
  // its next wait. Ownership must remain with the conversation, while success
  // remains blocked until the next wait dequeues and receipt-ACKs the update.
  run_composer_async(comp, ctx(update("two", 1, 1)), route_done)
  assert process.receive(route_done, 50) == Error(Nil)
  assert process.receive(passed, 0) == Error(Nil)
  process.send(resume, Nil)

  assert receive_event(recorder) == Ok("two")
  assert receive_event(route_done) == Ok(Nil)
  assert process.receive(passed, 0) == Error(Nil)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn finishing_between_waits_releases_undelivered_buffer_test() {
  let registry = registry()
  let between_waits: process.Subject(process.Subject(Nil)) =
    process.new_subject()
  let first_result: process.Subject(String) = process.new_subject()
  let passed: process.Subject(String) = process.new_subject()
  let route_done: process.Subject(Nil) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("start", 1, 1)), fn(wait) {
      process.send(
        first_result,
        text_or_error(wait(successful_wait_timeout_ms)),
      )
      let finish: process.Subject(Nil) = process.new_subject()
      process.send(between_waits, finish)
      process.receive_forever(finish)
    })
  let router =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
    |> composer.handle(fn(ctx) {
      process.send(passed, context.message_text(ctx) |> option.unwrap("none"))
    })

  composer.run(router, ctx(update("first", 1, 1)))
  assert receive_event(first_result) == Ok("first")
  let assert Ok(finish) = receive_event(between_waits)
  run_composer_async(router, ctx(update("after-finish", 1, 1)), route_done)
  assert process.receive(route_done, 50) == Error(Nil)
  assert process.receive(passed, 0) == Error(Nil)

  // The buffer was never delivered, so normal completion can reject it
  // safely. Only then may ordinary middleware receive the update.
  process.send(finish, Nil)
  assert receive_event(passed) == Ok("after-finish")
  assert receive_event(route_done) == Ok(Nil)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn between_waits_buffer_overflow_fails_closed_test() {
  let registry = registry()
  let between_waits: process.Subject(process.Subject(Nil)) =
    process.new_subject()
  let results: process.Subject(String) = process.new_subject()
  let passed: process.Subject(Nil) = process.new_subject()
  let errors: process.Subject(conversations.RegistryError) =
    process.new_subject()
  let route_done: process.Subject(Nil) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("start", 1, 1)), fn(wait) {
      process.send(results, text_or_error(wait(successful_wait_timeout_ms)))
      let resume: process.Subject(Nil) = process.new_subject()
      process.send(between_waits, resume)
      process.receive_forever(resume)
      process.send(results, text_or_error(wait(successful_wait_timeout_ms)))
    })
  let router =
    composer.new()
    |> composer.use_middleware(
      conversations.middleware_with_error(registry, fn(error) {
        process.send(errors, error)
      }),
    )
    |> composer.handle(fn(_) { process.send(passed, Nil) })

  composer.run(router, ctx(update("first", 1, 1)))
  assert receive_event(results) == Ok("first")
  let assert Ok(resume) = receive_event(between_waits)
  run_composer_async(router, ctx(update("buffered", 1, 1)), route_done)
  assert process.receive(route_done, 50) == Error(Nil)

  // One buffered route is the hard bound. A concurrent second route is not
  // claimed, but it also cannot leak to ordinary composer middleware.
  composer.run(router, ctx(update("middleware-overflow", 1, 1)))
  assert receive_event(errors) == Ok(conversations.RouteBufferFull)
  assert process.receive(passed, 0) == Error(Nil)

  let gate = conversations.update_gate(registry)
  assert gate(ctx(update("overflow", 1, 1)))
    == Error(bot.UpdateGateError(
      "conversation_route_buffer_full",
      "conversation route buffer is full",
    ))
  process.send(resume, Nil)
  assert receive_event(results) == Ok("buffered")
  assert receive_event(route_done) == Ok(Nil)
  assert process.receive(passed, 0) == Error(Nil)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn registry_timeout_between_waits_fails_middleware_closed_test() {
  let assert Ok(registry) =
    conversations.new_registry_with_options(conversations.by_chat_and_user, 30)
  let between_waits: process.Subject(process.Subject(Nil)) =
    process.new_subject()
  let first_result: process.Subject(String) = process.new_subject()
  let errors: process.Subject(conversations.RegistryError) =
    process.new_subject()
  let passed: process.Subject(Nil) = process.new_subject()
  let route_done: process.Subject(Nil) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("start", 1, 1)), fn(wait) {
      process.send(
        first_result,
        text_or_error(wait(successful_wait_timeout_ms)),
      )
      let finish: process.Subject(Nil) = process.new_subject()
      process.send(between_waits, finish)
      process.receive_forever(finish)
    })
  let router =
    composer.new()
    |> composer.use_middleware(
      conversations.middleware_with_error(registry, fn(error) {
        process.send(errors, error)
      }),
    )
    |> composer.handle(fn(_) { process.send(passed, Nil) })

  composer.run(router, ctx(update("first", 1, 1)))
  assert receive_event(first_result) == Ok("first")
  let assert Ok(finish) = receive_event(between_waits)
  let registry_process = registry_pid(3, registry)
  assert suspend_process(registry_process)

  // The registry cannot answer before its deadline, but the live owner may
  // still own this key. Generic middleware must therefore fail closed too.
  run_composer_async(router, ctx(update("uncertain", 1, 1)), route_done)
  assert receive_event(errors) == Ok(conversations.CallTimeout)
  assert receive_event(route_done) == Ok(Nil)
  assert process.receive(passed, 20) == Error(Nil)

  assert resume_process(registry_process)
  process.send(finish, Nil)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn register_wait_prestart_timeout_can_retry_without_late_state_test() {
  let assert Ok(registry) =
    conversations.new_registry_with_options(conversations.by_chat_and_user, 30)
  let controls: process.Subject(process.Subject(Nil)) = process.new_subject()
  let results: process.Subject(String) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("start", 1, 1)), fn(wait) {
      process.send(results, text_or_error(wait(successful_wait_timeout_ms)))

      let try_timed_out_wait: process.Subject(Nil) = process.new_subject()
      process.send(controls, try_timed_out_wait)
      process.receive_forever(try_timed_out_wait)
      case wait(successful_wait_timeout_ms) {
        Error(conversations.RegistryUnavailableWhileWaiting(
          conversations.CallTimeout,
        )) -> process.send(results, "register-timeout")
        _ -> process.send(results, "unexpected-register-result")
      }

      let retry: process.Subject(Nil) = process.new_subject()
      process.send(controls, retry)
      process.receive_forever(retry)
      process.send(results, text_or_error(wait(successful_wait_timeout_ms)))
    })
  let router =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))

  composer.run(router, ctx(update("first", 1, 1)))
  assert receive_event(results) == Ok("first")
  let assert Ok(try_timed_out_wait) = receive_event(controls)
  let registry_process = registry_pid(3, registry)
  assert suspend_process(registry_process)
  process.send(try_timed_out_wait, Nil)
  assert receive_event(results) == Ok("register-timeout")
  let assert Ok(retry) = receive_event(controls)

  // The queued expired registration must not turn BetweenWaits into Waiting
  // after the caller has observed a known-not-started timeout.
  assert resume_process(registry_process)
  process.send(retry, Nil)
  composer.run(router, ctx(update("second", 1, 1)))
  assert receive_event(results) == Ok("second")
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn registry_mutation_marker_precedes_authoritative_deadline_check_test() {
  let began: process.Subject(Nil) = process.new_subject()
  let checks: process.Subject(Bool) = process.new_subject()
  process.send(checks, False)
  process.send(checks, True)

  // The fake clock widens the exact pre-marker race without a production
  // delay: the second check may report expiry only after observing the marker.
  assert conversations.begin_registry_mutation_with(1, began, fn(_) {
      let expired = process.receive_forever(checks)
      case expired {
        False -> False
        True -> {
          assert process.receive(began, 0) == Ok(Nil)
          True
        }
      }
    })
    == False
  assert process.receive(checks, 0) == Error(Nil)
}

pub fn registry_mutation_preexpired_path_never_emits_begin_marker_test() {
  let began: process.Subject(Nil) = process.new_subject()
  let checks: process.Subject(Bool) = process.new_subject()
  process.send(checks, True)
  process.send(checks, False)

  assert conversations.begin_registry_mutation_with(1, began, fn(_) {
      process.receive_forever(checks)
    })
    == False
  assert process.receive(began, 0) == Error(Nil)
  // The second value proves the authoritative recheck was short-circuited.
  assert process.receive(checks, 0) == Ok(False)
}

pub fn open_prestart_timeout_does_not_replace_existing_owner_test() {
  let assert Ok(registry) =
    conversations.new_registry_with_options(conversations.by_chat_and_user, 30)
  let old_result: process.Subject(String) = process.new_subject()
  let replacement_ran: process.Subject(Nil) = process.new_subject()
  let assert Ok(_) =
    conversations.start(registry, ctx(update("old-start", 1, 1)), fn(wait) {
      process.send(old_result, text_or_error(wait(successful_wait_timeout_ms)))
    })
  let registry_process = registry_pid(3, registry)
  assert suspend_process(registry_process)

  assert conversations.start(
      registry,
      ctx(update("replacement-start", 1, 1)),
      fn(_) { process.send(replacement_ran, Nil) },
    )
    == Error(conversations.RegistryUnavailable(conversations.CallTimeout))
  assert process.receive(replacement_ran, 0) == Error(Nil)
  assert resume_process(registry_process)

  // The expired Open was queued before this route. It must be rejected without
  // cancelling or replacing the old owner when the registry resumes.
  let router =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
  composer.run(router, ctx(update("still-old", 1, 1)))
  assert receive_event(old_result) == Ok("still-old")
  assert process.receive(replacement_ran, 0) == Error(Nil)
  assert conversations.stop_registry(registry) == Ok(Nil)
}

pub fn replacement_of_between_waits_owner_fails_buffer_closed_test() {
  let registry = registry()
  let between_waits: process.Subject(Nil) = process.new_subject()
  let results: process.Subject(String) = process.new_subject()
  let passed: process.Subject(Nil) = process.new_subject()
  let errors: process.Subject(conversations.RegistryError) =
    process.new_subject()
  let route_done: process.Subject(Nil) = process.new_subject()
  let start_ctx = ctx(update("start", 1, 1))
  let assert Ok(old_conversation) =
    conversations.start(registry, start_ctx, fn(wait) {
      process.send(results, text_or_error(wait(successful_wait_timeout_ms)))
      process.send(between_waits, Nil)
      process.sleep_forever()
    })
  let old_monitor = process.monitor(conversation_pid(6, old_conversation))
  let router =
    composer.new()
    |> composer.use_middleware(
      conversations.middleware_with_error(registry, fn(error) {
        process.send(errors, error)
      }),
    )
    |> composer.handle(fn(_) { process.send(passed, Nil) })

  composer.run(router, ctx(update("first", 1, 1)))
  assert receive_event(results) == Ok("first")
  assert receive_event(between_waits) == Ok(Nil)
  run_composer_async(router, ctx(update("old-buffer", 1, 1)), route_done)
  assert process.receive(route_done, 50) == Error(Nil)

  let assert Ok(_) =
    conversations.start(registry, start_ctx, fn(wait) {
      process.send(
        results,
        "replacement:" <> text_or_error(wait(successful_wait_timeout_ms)),
      )
    })
  assert receive_event(errors) == Ok(conversations.RouteOutcomeUnknown)
  assert receive_event(route_done) == Ok(Nil)
  assert process.receive(passed, 0) == Error(Nil)
  assert monitor_went_down(old_monitor)

  composer.run(router, ctx(update("winner", 1, 1)))
  assert receive_event(results) == Ok("replacement:winner")
  assert process.receive(passed, 0) == Error(Nil)
  assert conversations.stop_registry(registry) == Ok(Nil)
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

pub fn abnormal_registry_death_fails_middleware_closed_until_worker_down_test() {
  let registry = registry()
  let assert Ok(conversation) =
    conversations.start(registry, ctx(update("start", 1, 1)), fn(_) {
      process.sleep_forever()
    })
  let worker_pid = conversation_pid(6, conversation)
  let worker_monitor = process.monitor(worker_pid)
  let lifecycle_pid = registry_lifecycle_pid(5, registry)
  let guard_pid =
    subject_owner_pid(2, conversation_lifecycle_subject(7, conversation))
  let registry_process = registry_pid(3, registry)
  let registry_monitor = process.monitor(registry_process)
  assert suspend_process(lifecycle_pid)
  assert suspend_process(guard_pid)

  // Freeze both cleanup paths to expose the interval where the registry is
  // gone but its previously registered owner is still executing.
  process.unlink(registry_process)
  process.kill(registry_process)
  assert monitor_went_down(registry_monitor)
  assert process.is_alive(worker_pid)

  let errors: process.Subject(conversations.RegistryError) =
    process.new_subject()
  let passed: process.Subject(Nil) = process.new_subject()
  let router =
    composer.new()
    |> composer.use_middleware(
      conversations.middleware_with_error(registry, fn(error) {
        process.send(errors, error)
      }),
    )
    |> composer.handle(fn(_) { process.send(passed, Nil) })
  composer.run(router, ctx(update("during-shutdown", 1, 1)))
  assert receive_event(errors) == Ok(conversations.Stopped)
  assert process.receive(passed, 20) == Error(Nil)

  assert resume_process(guard_pid)
  assert resume_process(lifecycle_pid)
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

pub fn middleware_reports_stopped_registry_and_fails_closed_test() {
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
  assert process.receive(recorder, 20) == Error(Nil)
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
fn conversation_pid(
  index: Int,
  conversation: conversations.Conversation,
) -> process.Pid

@external(erlang, "erlang", "element")
fn conversation_lifecycle_subject(
  index: Int,
  conversation: conversations.Conversation,
) -> process.Subject(Nil)

@external(erlang, "erlang", "element")
fn subject_owner_pid(index: Int, subject: process.Subject(Nil)) -> process.Pid

@external(erlang, "erlang", "element")
fn registry_pid(index: Int, registry: conversations.Registry) -> process.Pid

@external(erlang, "erlang", "element")
fn registry_lifecycle_pid(
  index: Int,
  registry: conversations.Registry,
) -> process.Pid

@external(erlang, "erlang", "process_info")
fn process_info(pid: process.Pid, key: Atom) -> #(Atom, Int)
