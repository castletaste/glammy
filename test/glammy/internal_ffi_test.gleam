import glammy/internal/ffi
import gleam/int

pub fn try_run_preserves_polymorphic_value_test() {
  assert ffi.try_run(fn() { #(42, "value") }) == Ok(#(42, "value"))
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
