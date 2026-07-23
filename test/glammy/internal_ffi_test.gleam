import glammy/helpers.{no_event, receive_event}
import glammy/internal/ffi
import gleam/erlang/process
import gleam/int

pub fn try_run_preserves_polymorphic_value_and_runs_once_test() {
  let calls: process.Subject(Nil) = process.new_subject()
  let outcome =
    ffi.try_run(fn() {
      process.send(calls, Nil)
      #(42, "value")
    })

  assert outcome == Ok(#(42, "value"))
  assert receive_event(calls) == Ok(Nil)
  assert no_event(calls)
}

pub fn try_run_captures_closed_exception_classes_test() {
  let assert Ok(zero) = int.parse("0")
  let error = ffi.try_run(fn() { unsafe_div(1, zero) })
  case error {
    Error(ffi.CaughtException(ffi.ErrorClass, value, stacktrace))
      if value != "" && stacktrace != ""
    -> Nil
    _ -> panic as "expected a rendered error exception"
  }

  assert caught_class(fn() { erlang_exit("exit") }) == ffi.ExitClass
  assert caught_class(fn() { erlang_throw("throw") }) == ffi.ThrowClass
}

pub fn try_run_redacted_discards_exception_details_test() {
  assert ffi.try_run_redacted(fn() { Nil }) == Ok(Nil)
  assert ffi.try_run_redacted(fn() { panic as "secret detail" }) == Error(Nil)
}

fn caught_class(raise: fn() -> Nil) -> ffi.ExceptionClass {
  let assert Error(ffi.CaughtException(class:, ..)) = ffi.try_run(raise)
  class
}

@external(erlang, "erlang", "div")
fn unsafe_div(a: Int, b: Int) -> Int

@external(erlang, "erlang", "exit")
fn erlang_exit(reason: String) -> Nil

@external(erlang, "erlang", "throw")
fn erlang_throw(reason: String) -> Nil
