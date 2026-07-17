import glammy/api
import glammy/error
import glammy/helpers.{dummy_api, receive_event}
import gleam/erlang/process

pub fn transformer_sees_method_name_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let api_ =
    dummy_api()
    |> api.with_transformer(fn(_next, method, _payload) {
      process.send(recorder, method)
      Error(error.DecodeError(method:, message: "intercepted"))
    })
  let _ = api.get_me(api_)
  assert receive_event(recorder) == Ok("getMe")
}

pub fn transformer_short_circuits_test() {
  // A short-circuiting transformer never calls `next`, so the real HTTP
  // call never happens. Verified here by *intentionally* using an
  // unroutable base URL — if the transformer hit the network this test
  // would hang or time-out.
  let recorder: process.Subject(String) = process.new_subject()
  let api_ =
    dummy_api()
    |> api.with_base_url("https://this-host-does-not-exist.invalid")
    |> api.with_transformer(fn(_next, method, _payload) {
      process.send(recorder, "short-circuited:" <> method)
      Error(error.DecodeError(method:, message: "stub"))
    })

  let _ = api.get_me(api_)
  assert receive_event(recorder) == Ok("short-circuited:getMe")
}

pub fn transformer_chain_runs_in_order_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let make_recording = fn(name: String) {
    fn(next: api.ApiCallFn, method: String, payload: api.Payload) {
      process.send(recorder, "before-" <> name)
      let result = next(method, payload)
      process.send(recorder, "after-" <> name)
      result
    }
  }
  let api_ =
    dummy_api()
    |> api.with_base_url("https://this-host-does-not-exist.invalid")
    |> api.with_transformer(make_recording("a"))
    |> api.with_transformer(make_recording("b"))
    // Final transformer short-circuits so no network call.
    |> api.with_transformer(fn(_next, method, _payload) {
      process.send(recorder, "stub-" <> method)
      Error(error.DecodeError(method:, message: "stub"))
    })

  let _ = api.get_me(api_)
  assert collect_exact(recorder, 5)
    == ["before-a", "before-b", "stub-getMe", "after-b", "after-a"]
}

pub fn outermost_transformer_precedes_existing_chain_test() {
  let recorder: process.Subject(String) = process.new_subject()
  let recording = fn(name: String) {
    fn(next: api.ApiCallFn, method: String, payload: api.Payload) {
      process.send(recorder, name)
      next(method, payload)
    }
  }
  let api_ =
    dummy_api()
    |> api.with_transformer(recording("user-a"))
    |> api.with_transformer(fn(_next, method, _payload) {
      process.send(recorder, "stub")
      Error(error.DecodeError(method:, message: "stub"))
    })
    |> api.with_outermost_transformer(recording("infrastructure"))

  let _ = api.get_me(api_)
  assert collect_exact(recorder, 3) == ["infrastructure", "user-a", "stub"]
}

fn collect_exact(s: process.Subject(String), remaining: Int) -> List(String) {
  case remaining <= 0 {
    True -> []
    False -> {
      let assert Ok(value) = receive_event(s)
      [value, ..collect_exact(s, remaining - 1)]
    }
  }
}
