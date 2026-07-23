//// Typed wrappers for the package's audited Erlang exception boundary.

/// The closed set of exception classes produced by Erlang `catch`.
pub type ExceptionClass {
  ErrorClass
  ExitClass
  ThrowClass
}

/// A safely rendered exception crossing the Erlang FFI boundary.
pub type CaughtException {
  CaughtException(class: ExceptionClass, value: String, stacktrace: String)
}

/// Render an exception class for existing public diagnostic records.
pub fn exception_class_name(class: ExceptionClass) -> String {
  case class {
    ErrorClass -> "error"
    ExitClass -> "exit"
    ThrowClass -> "throw"
  }
}

/// Run a thunk and preserve either its polymorphic value or a typed exception.
@external(erlang, "glammy_ffi", "try_run")
pub fn try_run(operation: fn() -> value) -> Result(value, CaughtException)

/// Run a `Nil` thunk without rendering exception values or stacktraces.
@external(erlang, "glammy_ffi", "try_run_redacted")
pub fn try_run_redacted(operation: fn() -> Nil) -> Result(Nil, Nil)
