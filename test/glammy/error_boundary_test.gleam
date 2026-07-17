//// Tests for the glammy-specific `error_boundary` primitive — catches
//// Erlang errors/exits/throws raised by middleware so the bot's poll
//// loop survives panicking handlers.

import glammy/composer
import glammy/context
import glammy/error_boundary
import glammy/helpers.{dummy_api, no_event, receive_event}
import glammy/types.{type Update}
import gleam/erlang/process

fn make_update() -> Update {
  helpers.update_from(
    "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"hi\"}}",
  )
}

fn run_with(boundary: composer.Middleware, post: fn(context.Context) -> Nil) {
  let comp =
    composer.new()
    |> composer.use_middleware(boundary)
    |> composer.handle(post)
  composer.run(comp, context.new(make_update(), dummy_api()))
}

pub fn boundary_catches_panic_test() {
  let caught: process.Subject(String) = process.new_subject()
  let post: process.Subject(String) = process.new_subject()

  let inner =
    composer.new()
    |> composer.handle(fn(_) { panic as "intentional test failure" })
  let mw =
    error_boundary.boundary(inner, fn(_ctx, _err) {
      process.send(caught, "caught")
    })
  run_with(mw, fn(_) { process.send(post, "post") })

  assert receive_event(caught) == Ok("caught")
  assert receive_event(post) == Ok("post")
}

pub fn boundary_lets_normal_returns_through_test() {
  let recorder: process.Subject(String) = process.new_subject()

  let inner =
    composer.new()
    |> composer.handle(fn(_) {
      process.send(recorder, "ran")
      Nil
    })
  let mw =
    error_boundary.boundary(inner, fn(_ctx, _err) {
      process.send(recorder, "should-not-catch")
    })
  run_with(mw, fn(_) { process.send(recorder, "post") })

  assert receive_event(recorder) == Ok("ran")
  assert receive_event(recorder) == Ok("post")
}

pub fn boundary_catches_let_assert_failure_test() {
  let caught: process.Subject(String) = process.new_subject()
  let post: process.Subject(String) = process.new_subject()

  let inner =
    composer.new()
    |> composer.handle(fn(_) {
      // `let assert` failure raises an Erlang error at runtime. We
      // hide the value behind a function so the compiler cannot prove
      // the pattern always fails statically.
      let assert Ok(_) = always_err()
      Nil
    })
  let mw =
    error_boundary.boundary(inner, fn(_ctx, _err) {
      process.send(caught, "caught-let-assert")
    })
  run_with(mw, fn(_) { process.send(post, "post") })

  assert receive_event(caught) == Ok("caught-let-assert")
  assert receive_event(post) == Ok("post")
}

pub fn boundary_catches_division_by_zero_test() {
  let caught: process.Subject(String) = process.new_subject()
  let post: process.Subject(String) = process.new_subject()

  let inner =
    composer.new()
    |> composer.handle(fn(_) {
      // `int.divide` returns Result, but using `/` on raw integers in
      // Erlang via FFI raises `badarith`. Use that for a non-panic
      // exception path.
      let _ = unsafe_div(10, 0)
      Nil
    })
  let mw =
    error_boundary.boundary(inner, fn(_ctx, _err) {
      process.send(caught, "caught-badarith")
    })
  run_with(mw, fn(_) { process.send(post, "post") })

  assert receive_event(caught) == Ok("caught-badarith")
  assert receive_event(post) == Ok("post")
}

pub fn boundary_passes_caught_error_to_handler_test() {
  // The handler receives a `BoundaryError` value it can inspect.
  let inspected: process.Subject(String) = process.new_subject()

  let inner =
    composer.new()
    |> composer.handle(fn(_) { panic as "boom" })
  let mw =
    error_boundary.boundary(inner, fn(_ctx, err) {
      case err {
        error_boundary.Caught(error_boundary.ErrorClass, value, stack)
          if value != "" && stack != ""
        -> process.send(inspected, "ok-shape")
        _ -> process.send(inspected, "bad-shape")
      }
    })
  let comp =
    composer.new()
    |> composer.use_middleware(mw)
  composer.run(comp, context.new(make_update(), dummy_api()))
  assert receive_event(inspected) == Ok("ok-shape")
}

pub fn boundary_maps_exit_and_throw_classes_test() {
  assert caught_class(fn() { erlang_exit("intentional exit") })
    == error_boundary.ExitClass
  assert caught_class(fn() { erlang_throw("intentional throw") })
    == error_boundary.ThrowClass
}

fn caught_class(raise: fn() -> Nil) -> error_boundary.BoundaryClass {
  let caught: process.Subject(error_boundary.BoundaryClass) =
    process.new_subject()
  let inner = composer.new() |> composer.handle(fn(_) { raise() })
  let middleware =
    error_boundary.boundary(inner, fn(_ctx, error) {
      let error_boundary.Caught(class, _, _) = error
      process.send(caught, class)
    })
  run_with(middleware, fn(_) { Nil })
  let assert Ok(class) = receive_event(caught)
  class
}

pub fn nested_boundary_only_catches_inner_failure_test() {
  // Outer boundary wraps an inner-boundaried sub-composer. When the
  // INNER one panics, only the inner handler should fire.
  let inner_caught: process.Subject(String) = process.new_subject()
  let outer_caught: process.Subject(String) = process.new_subject()
  let post: process.Subject(String) = process.new_subject()

  let leaf =
    composer.new()
    |> composer.handle(fn(_) { panic as "inner failure" })
  let inner_mw =
    error_boundary.boundary(leaf, fn(_ctx, _err) {
      process.send(inner_caught, "inner")
    })
  let outer =
    composer.new()
    |> composer.use_middleware(inner_mw)
  let outer_mw =
    error_boundary.boundary(outer, fn(_ctx, _err) {
      process.send(outer_caught, "outer-should-not-fire")
    })

  let comp =
    composer.new()
    |> composer.use_middleware(outer_mw)
    |> composer.handle(fn(_) { process.send(post, "post") })
  composer.run(comp, context.new(make_update(), dummy_api()))

  assert receive_event(inner_caught) == Ok("inner")
  assert no_event(outer_caught)
  assert receive_event(post) == Ok("post")
}

// =====================================================================
//                         FFI used in tests
// =====================================================================

@external(erlang, "erlang", "div")
fn unsafe_div(a: Int, b: Int) -> Int

@external(erlang, "erlang", "exit")
fn erlang_exit(reason: String) -> Nil

@external(erlang, "erlang", "throw")
fn erlang_throw(reason: String) -> Nil

fn always_err() -> Result(Nil, Nil) {
  Error(Nil)
}
