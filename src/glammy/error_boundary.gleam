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
import gleam/dynamic.{type Dynamic}

pub type BoundaryError {
  /// Captured class (e.g. `error`, `throw`, `exit`), value, and the raw
  /// stacktrace term. Best inspected via `string.inspect`.
  Caught(class: Dynamic, value: Dynamic, stacktrace: Dynamic)
}

@external(erlang, "glammy_ffi", "try_run")
fn try_run(f: fn() -> Nil) -> Result(Nil, #(Dynamic, Dynamic, Dynamic))

/// Wrap a sub-composer in an error boundary. Errors raised by any
/// middleware in `inner` are passed to `on_error` rather than
/// propagated. Returns a single `Middleware` you can `use_middleware`
/// into the outer composer.
pub fn boundary(
  inner: Composer,
  on_error: fn(Context, BoundaryError) -> Nil,
) -> Middleware {
  fn(ctx: Context, next: fn() -> Nil) -> Nil {
    case try_run(fn() { composer.run(inner, ctx) }) {
      Ok(_) -> Nil
      Error(#(class, value, stack)) ->
        on_error(ctx, Caught(class:, value:, stacktrace: stack))
    }
    next()
  }
}
