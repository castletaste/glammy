//// Concurrency, backpressure, crash, and lifecycle tests for the keyed executor.

import glammy/bot
import glammy/context
import glammy/helpers
import glammy/keyed_executor
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/system
import gleam/string

const update_json = "{\"update_id\":1,\"message\":{\"message_id\":1,\"date\":0,\"chat\":{\"id\":123,\"type\":\"private\"},\"text\":\"x\"}}"

fn start_executor(
  max_concurrency: Int,
  capacity: Int,
) -> keyed_executor.Executor(String, String) {
  let assert Ok(executor) = keyed_executor.start(max_concurrency, capacity)
  executor
}

fn blocking_operation(
  label: String,
  started: process.Subject(#(String, process.Subject(Nil))),
) -> fn() -> String {
  fn() {
    let release = process.new_subject()
    process.send(started, #(label, release))
    process.receive_forever(release)
    label
  }
}

fn emit_forever(effects: process.Subject(Nil)) -> String {
  process.send(effects, Nil)
  process.sleep(1)
  emit_forever(effects)
}

fn drain(subject: process.Subject(value)) -> Nil {
  case process.receive(subject, 0) {
    Ok(_) -> drain(subject)
    Error(Nil) -> Nil
  }
}

pub fn process_timeout_boundaries_are_validated_before_start_test() {
  let maximum =
    keyed_executor.Options(
      max_concurrency: 1,
      capacity: 1,
      admission_timeout_ms: 4_294_967_295,
      stop_timeout_ms: 4_294_967_295,
    )
  let assert Ok(executor): Result(
    keyed_executor.Executor(String, Nil),
    keyed_executor.StartError,
  ) = keyed_executor.start_with_options(maximum)
  assert keyed_executor.stop(executor) == Ok(Nil)

  let admission_too_large: Result(
    keyed_executor.Executor(String, Nil),
    keyed_executor.StartError,
  ) =
    keyed_executor.start_with_options(
      keyed_executor.Options(..maximum, admission_timeout_ms: 4_294_967_296),
    )
  assert admission_too_large
    == Error(keyed_executor.InvalidAdmissionTimeout(4_294_967_296))

  let stop_too_large: Result(
    keyed_executor.Executor(String, Nil),
    keyed_executor.StartError,
  ) =
    keyed_executor.start_with_options(
      keyed_executor.Options(..maximum, stop_timeout_ms: 4_294_967_296),
    )
  assert stop_too_large
    == Error(keyed_executor.InvalidStopTimeout(4_294_967_296))
}

pub fn different_keys_run_in_parallel_test() {
  let executor = start_executor(2, 4)
  let started = process.new_subject()
  let outcome_a = process.new_subject()
  let outcome_b = process.new_subject()

  assert keyed_executor.submit(
      executor,
      "a",
      blocking_operation("a", started),
      outcome_a,
    )
    == Ok(Nil)
  assert keyed_executor.submit(
      executor,
      "b",
      blocking_operation("b", started),
      outcome_b,
    )
    == Ok(Nil)

  let assert Ok(first) = helpers.receive_event(started)
  let assert Ok(second) = helpers.receive_event(started)
  assert first.0 != second.0
  process.send(first.1, Nil)
  process.send(second.1, Nil)
  assert helpers.receive_event(outcome_a) == Ok(keyed_executor.Completed("a"))
  assert helpers.receive_event(outcome_b) == Ok(keyed_executor.Completed("b"))
  assert keyed_executor.stop(executor) == Ok(Nil)
}

pub fn same_key_is_strict_fifo_and_never_overlaps_test() {
  let executor = start_executor(3, 6)
  let started = process.new_subject()
  let first_outcome = process.new_subject()
  let second_outcome = process.new_subject()
  let third_outcome = process.new_subject()

  assert keyed_executor.submit(
      executor,
      "chat",
      blocking_operation("first", started),
      first_outcome,
    )
    == Ok(Nil)
  assert keyed_executor.submit(
      executor,
      "chat",
      blocking_operation("second", started),
      second_outcome,
    )
    == Ok(Nil)
  assert keyed_executor.submit(
      executor,
      "chat",
      blocking_operation("third", started),
      third_outcome,
    )
    == Ok(Nil)

  let assert Ok(#("first", release_first)) = helpers.receive_event(started)
  assert helpers.no_event(started)
  process.send(release_first, Nil)
  assert helpers.receive_event(first_outcome)
    == Ok(keyed_executor.Completed("first"))

  let assert Ok(#("second", release_second)) = helpers.receive_event(started)
  assert helpers.no_event(started)
  process.send(release_second, Nil)
  assert helpers.receive_event(second_outcome)
    == Ok(keyed_executor.Completed("second"))

  let assert Ok(#("third", release_third)) = helpers.receive_event(started)
  process.send(release_third, Nil)
  assert helpers.receive_event(third_outcome)
    == Ok(keyed_executor.Completed("third"))
  assert keyed_executor.stop(executor) == Ok(Nil)
}

pub fn global_concurrency_cap_is_enforced_test() {
  let executor = start_executor(2, 3)
  let started = process.new_subject()
  let outcome_a = process.new_subject()
  let outcome_b = process.new_subject()
  let outcome_c = process.new_subject()

  assert keyed_executor.submit(
      executor,
      "a",
      blocking_operation("a", started),
      outcome_a,
    )
    == Ok(Nil)
  assert keyed_executor.submit(
      executor,
      "b",
      blocking_operation("b", started),
      outcome_b,
    )
    == Ok(Nil)
  assert keyed_executor.submit(
      executor,
      "c",
      blocking_operation("c", started),
      outcome_c,
    )
    == Ok(Nil)

  let assert Ok(first) = helpers.receive_event(started)
  let assert Ok(second) = helpers.receive_event(started)
  assert helpers.no_event(started)
  process.send(first.1, Nil)
  let assert Ok(third) = helpers.receive_event(started)
  assert third.0 == "c"
  process.send(second.1, Nil)
  process.send(third.1, Nil)

  let assert Ok(keyed_executor.Completed(_)) = helpers.receive_event(outcome_a)
  let assert Ok(keyed_executor.Completed(_)) = helpers.receive_event(outcome_b)
  assert helpers.receive_event(outcome_c) == Ok(keyed_executor.Completed("c"))
  assert keyed_executor.stop(executor) == Ok(Nil)
}

pub fn ready_keys_are_fair_across_hot_and_cold_keys_test() {
  let executor = start_executor(1, 3)
  let started = process.new_subject()
  let a1 = process.new_subject()
  let a2 = process.new_subject()
  let b1 = process.new_subject()

  assert keyed_executor.submit(
      executor,
      "a",
      blocking_operation("a1", started),
      a1,
    )
    == Ok(Nil)
  assert keyed_executor.submit(
      executor,
      "a",
      blocking_operation("a2", started),
      a2,
    )
    == Ok(Nil)
  assert keyed_executor.submit(
      executor,
      "b",
      blocking_operation("b1", started),
      b1,
    )
    == Ok(Nil)

  let assert Ok(#("a1", release_a1)) = helpers.receive_event(started)
  process.send(release_a1, Nil)
  assert helpers.receive_event(a1) == Ok(keyed_executor.Completed("a1"))
  let assert Ok(#("b1", release_b1)) = helpers.receive_event(started)
  process.send(release_b1, Nil)
  assert helpers.receive_event(b1) == Ok(keyed_executor.Completed("b1"))
  let assert Ok(#("a2", release_a2)) = helpers.receive_event(started)
  process.send(release_a2, Nil)
  assert helpers.receive_event(a2) == Ok(keyed_executor.Completed("a2"))
  assert keyed_executor.stop(executor) == Ok(Nil)
}

pub fn capacity_counts_active_plus_queued_and_rejects_full_test() {
  let executor = start_executor(1, 2)
  let started = process.new_subject()
  let active_outcome = process.new_subject()
  let queued_outcome = process.new_subject()
  let rejected_outcome = process.new_subject()

  assert keyed_executor.submit(
      executor,
      "a",
      blocking_operation("active", started),
      active_outcome,
    )
    == Ok(Nil)
  let assert Ok(#("active", _)) = helpers.receive_event(started)
  assert keyed_executor.submit(executor, "b", fn() { "queued" }, queued_outcome)
    == Ok(Nil)
  assert keyed_executor.submit(
      executor,
      "c",
      fn() { "rejected" },
      rejected_outcome,
    )
    == Error(keyed_executor.AtCapacity(2))
  assert helpers.no_event(rejected_outcome)

  assert keyed_executor.stop(executor) == Ok(Nil)
  assert helpers.receive_event(active_outcome) == Ok(keyed_executor.Cancelled)
  assert helpers.receive_event(queued_outcome) == Ok(keyed_executor.Cancelled)
}

pub fn crashed_job_releases_key_and_next_job_recovers_test() {
  let executor = start_executor(1, 2)
  let crashed = process.new_subject()
  let recovered = process.new_subject()

  assert keyed_executor.submit(
      executor,
      "chat",
      fn() { panic as "boom" },
      crashed,
    )
    == Ok(Nil)
  assert keyed_executor.submit(
      executor,
      "chat",
      fn() { "recovered" },
      recovered,
    )
    == Ok(Nil)

  let assert Ok(keyed_executor.Crashed(value:, ..)) =
    helpers.receive_event(crashed)
  assert string.contains(value, "boom")
  assert helpers.receive_event(recovered)
    == Ok(keyed_executor.Completed("recovered"))
  assert keyed_executor.stop(executor) == Ok(Nil)
}

pub fn stop_cancels_active_and_queued_jobs_and_is_idempotent_test() {
  let executor = start_executor(1, 2)
  let started = process.new_subject()
  let active_outcome = process.new_subject()
  let queued_outcome = process.new_subject()
  let stop_results = process.new_subject()

  assert keyed_executor.submit(
      executor,
      "a",
      fn() {
        process.send(started, Nil)
        process.sleep_forever()
        "unreachable"
      },
      active_outcome,
    )
    == Ok(Nil)
  let assert Ok(Nil) = helpers.receive_event(started)
  assert keyed_executor.submit(executor, "b", fn() { "queued" }, queued_outcome)
    == Ok(Nil)

  let _ =
    process.spawn_unlinked(fn() {
      process.send(stop_results, keyed_executor.stop(executor))
    })
  let _ =
    process.spawn_unlinked(fn() {
      process.send(stop_results, keyed_executor.stop(executor))
    })
  assert helpers.receive_event(stop_results) == Ok(Ok(Nil))
  assert helpers.receive_event(stop_results) == Ok(Ok(Nil))
  assert helpers.receive_event(active_outcome) == Ok(keyed_executor.Cancelled)
  assert helpers.receive_event(queued_outcome) == Ok(keyed_executor.Cancelled)
  assert helpers.no_event(active_outcome)
  assert helpers.no_event(queued_outcome)

  let unused = process.new_subject()
  assert keyed_executor.submit(executor, "later", fn() { "later" }, unused)
    == Error(keyed_executor.ExecutorNotRunning)
  assert keyed_executor.stop(executor) == Ok(Nil)
}

pub fn completion_vs_stop_has_exactly_one_terminal_outcome_test() {
  run_completion_stop_race(20)
}

fn run_completion_stop_race(remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let executor = start_executor(1, 1)
      let started = process.new_subject()
      let outcome = process.new_subject()
      let stop_result = process.new_subject()
      assert keyed_executor.submit(
          executor,
          "chat",
          fn() {
            let release = process.new_subject()
            process.send(started, release)
            process.receive_forever(release)
            "done"
          },
          outcome,
        )
        == Ok(Nil)
      let assert Ok(release) = helpers.receive_event(started)
      let _ =
        process.spawn_unlinked(fn() {
          process.send(stop_result, keyed_executor.stop(executor))
        })
      process.send(release, Nil)
      case helpers.receive_event(outcome) {
        Ok(keyed_executor.Completed("done")) | Ok(keyed_executor.Cancelled) ->
          Nil
        _ -> panic as "expected one completion-or-cancellation outcome"
      }
      assert helpers.receive_event(stop_result) == Ok(Ok(Nil))
      assert helpers.no_event(outcome)
      run_completion_stop_race(remaining - 1)
    }
  }
}

pub fn external_scheduler_death_resolves_every_job_and_kills_task_test() {
  let executor = start_executor(1, 2)
  let started = process.new_subject()
  let active_outcome = process.new_subject()
  let queued_outcome = process.new_subject()

  assert keyed_executor.submit(
      executor,
      "chat",
      fn() {
        let release = process.new_subject()
        process.send(started, #(process.self(), release))
        process.receive_forever(release)
        "active"
      },
      active_outcome,
    )
    == Ok(Nil)
  let assert Ok(#(task_pid, _)) = helpers.receive_event(started)
  let task_monitor = process.monitor(task_pid)
  assert keyed_executor.submit(
      executor,
      "chat",
      fn() { "queued" },
      queued_outcome,
    )
    == Ok(Nil)

  process.kill(keyed_executor.process_id(executor))
  assert helpers.receive_event(active_outcome)
    == Ok(keyed_executor.ExecutorTerminated)
  assert helpers.receive_event(queued_outcome)
    == Ok(keyed_executor.ExecutorTerminated)
  let task_down =
    process.new_selector()
    |> process.select_specific_monitor(task_monitor, fn(_) { Nil })
  assert process.selector_receive(task_down, helpers.async_timeout_ms)
    == Ok(Nil)
  process.demonitor_process(task_monitor)
  assert helpers.no_event(active_outcome)
  assert helpers.no_event(queued_outcome)
}

pub fn abrupt_scheduler_death_has_no_post_terminal_user_effects_test() {
  let executor = start_executor(1, 1)
  let started = process.new_subject()
  let effects = process.new_subject()
  let outcome = process.new_subject()

  assert keyed_executor.submit(
      executor,
      "chat",
      fn() {
        process.trap_exits(True)
        process.send(started, process.self())
        emit_forever(effects)
      },
      outcome,
    )
    == Ok(Nil)
  let assert Ok(task_pid) = helpers.receive_event(started)
  let task_monitor = process.monitor(task_pid)
  let assert Ok(Nil) = helpers.receive_event(effects)

  process.kill(keyed_executor.process_id(executor))
  assert helpers.receive_event(outcome) == Ok(keyed_executor.ExecutorTerminated)
  assert !process.is_alive(task_pid)
  let task_down =
    process.new_selector()
    |> process.select_specific_monitor(task_monitor, fn(_) { Nil })
  assert process.selector_receive(task_down, helpers.async_timeout_ms)
    == Ok(Nil)
  process.demonitor_process(task_monitor)
  drain(effects)
  process.sleep(20)
  assert helpers.no_event(effects)
  assert helpers.no_event(outcome)
}

pub fn lost_admission_ack_is_never_reported_as_definite_rejection_test() {
  let executor = start_executor(1, 1)
  let admission = process.new_subject()
  let outcome = process.new_subject()
  let scheduler_pid = keyed_executor.process_id(executor)

  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        admission,
        keyed_executor.submit(
          executor,
          "chat",
          fn() {
            process.kill(scheduler_pid)
            "unreachable"
          },
          outcome,
        ),
      )
    })

  case helpers.receive_event(admission) {
    Ok(Ok(Nil)) | Ok(Error(keyed_executor.AdmissionOutcomeUnknown)) -> Nil
    _ -> panic as "accepted work must not become a definite not-running error"
  }
  assert helpers.receive_event(outcome) == Ok(keyed_executor.ExecutorTerminated)
  assert helpers.no_event(outcome)
}

pub fn expired_suspended_submission_is_not_admitted_after_resume_test() {
  let options =
    keyed_executor.Options(
      max_concurrency: 1,
      capacity: 1,
      admission_timeout_ms: 30,
      stop_timeout_ms: 1000,
    )
  let assert Ok(executor): Result(
    keyed_executor.Executor(String, String),
    keyed_executor.StartError,
  ) = keyed_executor.start_with_options(options)
  let started = process.new_subject()
  let outcome = process.new_subject()

  system.suspend(keyed_executor.process_id(executor))
  assert keyed_executor.submit(
      executor,
      "chat",
      fn() {
        process.send(started, Nil)
        "late"
      },
      outcome,
    )
    == Error(keyed_executor.AdmissionDeadlineExceeded)
  system.resume(keyed_executor.process_id(executor))
  process.sleep(50)
  assert helpers.no_event(started)
  assert helpers.no_event(outcome)
  assert keyed_executor.stop(executor) == Ok(Nil)
}

pub fn dead_submit_caller_cannot_be_admitted_later_test() {
  let options =
    keyed_executor.Options(
      max_concurrency: 1,
      capacity: 1,
      admission_timeout_ms: 200,
      stop_timeout_ms: 1000,
    )
  let assert Ok(executor): Result(
    keyed_executor.Executor(String, String),
    keyed_executor.StartError,
  ) = keyed_executor.start_with_options(options)
  let caller_entered = process.new_subject()
  let operation_started = process.new_subject()
  let outcome = process.new_subject()

  system.suspend(keyed_executor.process_id(executor))
  let caller =
    process.spawn_unlinked(fn() {
      process.send(caller_entered, Nil)
      let _ =
        keyed_executor.submit(
          executor,
          "chat",
          fn() {
            process.send(operation_started, Nil)
            "late"
          },
          outcome,
        )
      Nil
    })
  let assert Ok(Nil) = helpers.receive_event(caller_entered)
  process.sleep(10)
  let caller_monitor = process.monitor(caller)
  process.kill(caller)
  let caller_down =
    process.new_selector()
    |> process.select_specific_monitor(caller_monitor, fn(_) { Nil })
  assert process.selector_receive(caller_down, helpers.async_timeout_ms)
    == Ok(Nil)
  process.demonitor_process(caller_monitor)

  system.resume(keyed_executor.process_id(executor))
  process.sleep(50)
  assert helpers.no_event(operation_started)
  assert helpers.no_event(outcome)
  assert keyed_executor.stop(executor) == Ok(Nil)
}

pub fn stop_waits_for_trap_exits_task_and_blocks_post_cancel_effects_test() {
  let executor = start_executor(1, 1)
  let started = process.new_subject()
  let effects = process.new_subject()
  let outcome = process.new_subject()

  assert keyed_executor.submit(
      executor,
      "chat",
      fn() {
        process.trap_exits(True)
        process.send(started, process.self())
        emit_forever(effects)
      },
      outcome,
    )
    == Ok(Nil)
  let assert Ok(task_pid) = helpers.receive_event(started)
  let task_monitor = process.monitor(task_pid)
  let assert Ok(Nil) = helpers.receive_event(effects)

  assert keyed_executor.stop(executor) == Ok(Nil)
  assert helpers.receive_event(outcome) == Ok(keyed_executor.Cancelled)
  assert !process.is_alive(task_pid)
  let task_down =
    process.new_selector()
    |> process.select_specific_monitor(task_monitor, fn(_) { Nil })
  assert process.selector_receive(task_down, helpers.async_timeout_ms)
    == Ok(Nil)
  process.demonitor_process(task_monitor)
  drain(effects)
  process.sleep(20)
  assert helpers.no_event(effects)
  assert helpers.no_event(outcome)
}

pub fn stop_timeout_forces_termination_and_resolves_the_active_job_test() {
  let options =
    keyed_executor.Options(
      max_concurrency: 1,
      capacity: 1,
      admission_timeout_ms: 1000,
      stop_timeout_ms: 30,
    )
  let assert Ok(executor): Result(
    keyed_executor.Executor(String, String),
    keyed_executor.StartError,
  ) = keyed_executor.start_with_options(options)
  let started = process.new_subject()
  let outcome = process.new_subject()

  assert keyed_executor.submit(
      executor,
      "chat",
      fn() {
        process.send(started, Nil)
        process.sleep_forever()
        "unreachable"
      },
      outcome,
    )
    == Ok(Nil)
  let assert Ok(Nil) = helpers.receive_event(started)
  system.suspend(keyed_executor.process_id(executor))

  assert keyed_executor.stop(executor) == Error(keyed_executor.StopTimedOut)
  assert helpers.receive_event(outcome) == Ok(keyed_executor.ExecutorTerminated)
  assert helpers.no_event(outcome)
  assert !process.is_alive(keyed_executor.process_id(executor))
}

pub fn concurrent_forced_stop_callers_converge_on_timeout_test() {
  let options =
    keyed_executor.Options(
      max_concurrency: 1,
      capacity: 1,
      admission_timeout_ms: 1000,
      stop_timeout_ms: 40,
    )
  let assert Ok(executor): Result(
    keyed_executor.Executor(String, String),
    keyed_executor.StartError,
  ) = keyed_executor.start_with_options(options)
  let results = process.new_subject()

  system.suspend(keyed_executor.process_id(executor))
  let _ =
    process.spawn_unlinked(fn() {
      process.send(results, keyed_executor.stop(executor))
    })
  process.sleep(10)
  let _ =
    process.spawn_unlinked(fn() {
      process.send(results, keyed_executor.stop(executor))
    })

  assert helpers.receive_event(results)
    == Ok(Error(keyed_executor.StopTimedOut))
  assert helpers.receive_event(results)
    == Ok(Error(keyed_executor.StopTimedOut))
  assert !process.is_alive(keyed_executor.process_id(executor))
}

pub fn external_kill_during_stop_is_not_misreported_as_timeout_test() {
  let options =
    keyed_executor.Options(
      max_concurrency: 1,
      capacity: 1,
      admission_timeout_ms: 1000,
      stop_timeout_ms: 1000,
    )
  let assert Ok(executor): Result(
    keyed_executor.Executor(String, String),
    keyed_executor.StartError,
  ) = keyed_executor.start_with_options(options)
  let scheduler_pid = keyed_executor.process_id(executor)

  system.suspend(scheduler_pid)
  let _ =
    process.spawn_unlinked(fn() {
      // Give `stop` time to install its monitor and enter the bounded wait.
      process.sleep(50)
      process.kill(scheduler_pid)
    })

  assert keyed_executor.stop(executor)
    == Error(keyed_executor.StopFailed("killed"))
  assert !process.is_alive(scheduler_pid)
}

pub fn update_gate_consumes_only_admitted_work_and_fails_closed_on_full_test() {
  let executor = start_executor(1, 1)
  let started = process.new_subject()
  let outcomes = process.new_subject()
  let ctx = context.new(helpers.update_from(update_json), helpers.dummy_api())
  let bypass =
    keyed_executor.update_gate(
      executor,
      fn(_) { None },
      fn(_) { "unused" },
      outcomes,
    )
  assert bypass(ctx) == Ok(bot.Continue)

  let gate =
    keyed_executor.update_gate(
      executor,
      fn(_) { Some("chat") },
      fn(_) {
        process.send(started, Nil)
        process.sleep_forever()
        "unreachable"
      },
      outcomes,
    )
  assert gate(ctx) == Ok(bot.Consumed)
  let assert Ok(Nil) = helpers.receive_event(started)
  let assert Error(bot.UpdateGateError(code:, ..)) = gate(ctx)
  assert code == "keyed_executor_capacity"

  assert keyed_executor.stop(executor) == Ok(Nil)
  assert helpers.receive_event(outcomes) == Ok(keyed_executor.Cancelled)
  assert helpers.no_event(outcomes)
}

pub fn by_chat_id_uses_context_chat_id_as_the_canonical_string_key_test() {
  let ctx = context.new(helpers.update_from(update_json), helpers.dummy_api())
  assert keyed_executor.by_chat_id(ctx) == Some("123")
}
