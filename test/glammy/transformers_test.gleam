import glammy/api
import glammy/error
import glammy/helpers.{dummy_api}
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
  assert process.receive(recorder, 50) == Ok("getMe")
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
  assert process.receive(recorder, 50) == Ok("short-circuited:getMe")
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
  assert collect_all(recorder)
    == ["before-a", "before-b", "stub-getMe", "after-b", "after-a"]
}

fn collect_all(s: process.Subject(String)) -> List(String) {
  case process.receive(s, 50) {
    Ok(v) -> [v, ..collect_all(s)]
    Error(_) -> []
  }
}
