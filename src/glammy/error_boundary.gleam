//// `error_boundary` — a composer combinator that wraps a sub-chain in a
//// try/catch so that an Erlang error/exit/throw inside a handler does
//// NOT take down the whole bot process. Mirrors grammY's
//// `Composer#errorBoundary`.
////
//// The boundary catches:
////
//// - `panic as "..."` (Gleam-level panics)
//// - `let assert` failures
//// - Anything `erlang:throw` / `erlang:error` / `erlang:exit` from FFI
////
//// The boundary does NOT propagate the error further — once it's
//// caught, the next middleware in the *outer* chain runs as if the
//// boundaried sub-chain had returned normally.

import glammy/composer.{type Composer, type Middleware}
import glammy/context.{type Context}
import glammy/internal/ffi

/// The BEAM exception class captured by a boundary.
pub type BoundaryClass {
  ErrorClass
  ExitClass
  ThrowClass
}

/// A safely rendered BEAM failure captured by an error boundary.
pub type BoundaryError {
  /// Captured exception class plus safe textual representations of the
  /// reason and stacktrace. Foreign BEAM terms do not escape through the
  /// public Gleam API as `Dynamic` values.
  Caught(class: BoundaryClass, value: String, stacktrace: String)
}

/// Wrap a sub-composer in an error boundary. Errors raised by any
/// middleware in `inner` are passed to `on_error` rather than
/// propagated. Returns a single `Middleware` you can `use_middleware`
/// into the outer composer.
pub fn boundary(
  inner: Composer,
  on_error: fn(Context, BoundaryError) -> Nil,
) -> Middleware {
  fn(ctx: Context, next: fn() -> Nil) -> Nil {
    case ffi.try_run(fn() { composer.run(inner, ctx) }) {
      Ok(_) -> Nil
      Error(ffi.CaughtException(class:, value:, stacktrace:)) ->
        on_error(ctx, Caught(class: boundary_class(class), value:, stacktrace:))
    }
    next()
  }
}

fn boundary_class(class: ffi.ExceptionClass) -> BoundaryClass {
  case class {
    ffi.ErrorClass -> ErrorClass
    ffi.ExitClass -> ExitClass
    ffi.ThrowClass -> ThrowClass
  }
}
