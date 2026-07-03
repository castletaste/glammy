//// Tests for the glammy-specific `conversations` primitive. grammY's
//// `@grammyjs/conversations` is persistent / replayable; ours is a
//// single-process linear flow. These tests pin down the contract.

import glammy/composer
import glammy/context
import glammy/conversations
import glammy/helpers.{dummy_api, message_update_from as make_message}
import glammy/types.{type Update}
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option.{Some}

fn ask_command_update() -> Update {
  let assert Ok(u) =
    json.parse(
      "{\"update_id\":10,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"/ask\",\"entities\":[{\"type\":\"bot_command\",\"offset\":0,\"length\":4}],\"from\":{\"id\":1,\"is_bot\":false,\"first_name\":\"X\"}}}",
      types.update_decoder(),
    )
  u
}

pub fn conversation_routes_next_message_test() {
  let registry = conversations.new_registry()
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
    |> composer.command("ask", fn(ctx) {
      conversations.start(registry, ctx, fn(wait) {
        process.send(recorder, "asked")
        case wait(500) {
          Ok(reply_ctx) ->
            case context.message_text(reply_ctx) {
              Some(text) -> process.send(recorder, "answer:" <> text)
              _ -> process.send(recorder, "answer:none")
            }
          Error(_) -> process.send(recorder, "timeout")
        }
      })
    })

  let _ =
    process.spawn(fn() {
      composer.run(comp, context.new(ask_command_update(), dummy_api()))
    })
  assert process.receive(recorder, 200) == Ok("asked")

  composer.run(comp, context.new(make_message("Ada Lovelace", 1), dummy_api()))
  assert process.receive(recorder, 500) == Ok("answer:Ada Lovelace")
}

pub fn conversation_times_out_test() {
  let registry = conversations.new_registry()
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
    |> composer.handle(fn(ctx) {
      conversations.start(registry, ctx, fn(wait) {
        case wait(50) {
          Ok(_) -> process.send(recorder, "ok")
          Error(_) -> process.send(recorder, "timeout")
        }
      })
    })
  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  assert process.receive(recorder, 500) == Ok("timeout")
}

pub fn conversations_are_user_scoped_test() {
  // Two different users start /ask concurrently. The reply from user 1
  // should route to user 1's conversation, not user 2's.
  let registry = conversations.new_registry()
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
    |> composer.command("ask", fn(ctx) {
      conversations.start(registry, ctx, fn(wait) {
        let assert Some(u) = context.from(ctx)
        process.send(recorder, "asked:" <> int.to_string(u.id))
        case wait(1000) {
          Ok(reply_ctx) -> {
            let assert Some(text) = context.message_text(reply_ctx)
            process.send(
              recorder,
              "answered:" <> int.to_string(u.id) <> ":" <> text,
            )
          }
          Error(_) -> process.send(recorder, "timeout:" <> int.to_string(u.id))
        }
      })
    })

  let ask_for = fn(user_id: Int) -> Update {
    let body =
      "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":"
      <> int.to_string(user_id)
      <> ",\"type\":\"private\"},\"date\":0,\"text\":\"/ask\",\"entities\":[{\"type\":\"bot_command\",\"offset\":0,\"length\":4}],\"from\":{\"id\":"
      <> int.to_string(user_id)
      <> ",\"is_bot\":false,\"first_name\":\"U\"}}}"
    let assert Ok(u) = json.parse(body, types.update_decoder())
    u
  }

  let _ =
    process.spawn(fn() {
      composer.run(comp, context.new(ask_for(1), dummy_api()))
    })
  let _ =
    process.spawn(fn() {
      composer.run(comp, context.new(ask_for(2), dummy_api()))
    })
  // Both conversations should be running and registered.
  assert collect_n(recorder, 2, 200)
    |> sorted
    == ["asked:1", "asked:2"]

  // Now route a reply from user 2 only.
  composer.run(comp, context.new(make_message("two", 2), dummy_api()))
  assert process.receive(recorder, 500) == Ok("answered:2:two")

  // User 1 is still waiting; its conversation hasn't been touched.
  composer.run(comp, context.new(make_message("one", 1), dummy_api()))
  assert process.receive(recorder, 500) == Ok("answered:1:one")
}

pub fn conversation_skips_when_no_user_in_update_test() {
  // An update without a `from` user (e.g. channel_post) can't be keyed.
  // `start` is invoked but the wait callback returns Timeout immediately
  // because there is no key to register under.
  let registry = conversations.new_registry()
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
    |> composer.handle(fn(ctx) {
      conversations.start(registry, ctx, fn(wait) {
        case wait(50) {
          Ok(_) -> process.send(recorder, "ok")
          Error(_) -> process.send(recorder, "no-user")
        }
      })
    })
  // channel_post has no `from` user.
  let assert Ok(u) =
    json.parse(
      "{\"update_id\":1,\"channel_post\":{\"message_id\":1,\"chat\":{\"id\":-100,\"type\":\"channel\",\"title\":\"ch\"},\"date\":0,\"text\":\"hi\"}}",
      types.update_decoder(),
    )
  composer.run(comp, context.new(u, dummy_api()))
  assert process.receive(recorder, 200) == Ok("no-user")
}

pub fn middleware_passes_through_when_no_active_conversation_test() {
  // If no conversation is registered for this user, the middleware
  // should NOT swallow the update — it must call `next()`.
  let registry = conversations.new_registry()
  let recorder: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(conversations.middleware(registry))
    |> composer.handle(fn(_) { process.send(recorder, "downstream-ran") })

  composer.run(comp, context.new(make_message("hi", 1), dummy_api()))
  assert process.receive(recorder, 100) == Ok("downstream-ran")
}

// =====================================================================
//                            helpers
// =====================================================================

fn collect_n(s: process.Subject(String), n: Int, ms: Int) -> List(String) {
  case n {
    0 -> []
    _ ->
      case process.receive(s, ms) {
        Ok(v) -> [v, ..collect_n(s, n - 1, ms)]
        Error(_) -> []
      }
  }
}

@external(erlang, "lists", "sort")
fn sorted(items: List(a)) -> List(a)
