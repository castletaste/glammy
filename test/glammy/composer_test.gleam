//// Tests mirroring grammY's `test/composer.test.ts`. The grammY suite
//// is built around mutable composers and JS-flavoured async middleware;
//// glammy composers are immutable so the tests are rewritten to thread
//// the composer value through reassignments. All behavioural
//// assertions carry over.

import glammy/api
import glammy/composer
import glammy/context
import glammy/filter
import glammy/types.{type Update}
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

fn dummy_api() -> api.Api {
  api.new("0:test")
}

fn ctx_from(body: String) -> context.Context {
  let assert Ok(u) = json.parse(body, types.update_decoder())
  context.new(u, dummy_api())
}

const message_test_body = "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"test\"}}"

const channel_post_body = "{\"update_id\":2,\"channel_post\":{\"message_id\":1,\"chat\":{\"id\":-100,\"type\":\"channel\",\"title\":\"c\"},\"date\":0,\"text\":\"\"}}"

const callback_body = "{\"update_id\":3,\"callback_query\":{\"id\":\"x\",\"from\":{\"id\":1,\"is_bot\":false,\"first_name\":\"X\"},\"chat_instance\":\"i\",\"data\":\"cb\"}}"

fn message_with_command(text: String, length: Int) -> Update {
  let body =
    "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\""
    <> text
    <> "\",\"entities\":[{\"type\":\"bot_command\",\"offset\":0,\"length\":"
    <> int.to_string(length)
    <> "}]}}"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  u
}

// =====================================================================
//                       Core composer behaviour
// =====================================================================

pub fn calls_handlers_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_) { process.send(s, "handled") })
  composer.run(comp, ctx_from(message_test_body))
  assert process.receive(s, 50) == Ok("handled")
}

pub fn next_short_circuits_when_not_called_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(fn(_, _) { process.send(s, "first") })
    |> composer.handle(fn(_) { process.send(s, "second") })
  composer.run(comp, ctx_from(message_test_body))
  assert process.receive(s, 50) == Ok("first")
  assert process.receive(s, 50) == Error(Nil)
}

pub fn next_propagates_when_called_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(fn(_, next) {
      process.send(s, "first")
      next()
    })
    |> composer.handle(fn(_) { process.send(s, "second") })
  composer.run(comp, ctx_from(message_test_body))
  assert collect_all(s) == ["first", "second"]
}

// =====================================================================
//                              .use
// =====================================================================

pub fn use_works_with_multiple_handlers_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.use_middleware(fn(_, next) {
      process.send(s, "a")
      next()
    })
    |> composer.use_middleware(fn(_, next) {
      process.send(s, "b")
      next()
    })
    |> composer.handle(fn(_) { process.send(s, "c") })
  composer.run(comp, ctx_from(message_test_body))
  assert collect_all(s) == ["a", "b", "c"]
}

pub fn use_can_append_other_composer_test() {
  let s: process.Subject(String) = process.new_subject()
  let sub =
    composer.new()
    |> composer.handle(fn(_) { process.send(s, "sub-a") })
    |> composer.handle(fn(_) { process.send(s, "sub-b") })
  let comp =
    composer.new()
    |> composer.handle(fn(_) { process.send(s, "parent") })
    |> composer.append(sub)
  composer.run(comp, ctx_from(message_test_body))
  assert collect_all(s) == ["parent", "sub-a", "sub-b"]
}

// =====================================================================
//                              .on
// =====================================================================

pub fn on_runs_filter_queries_test() {
  let s: process.Subject(String) = process.new_subject()
  let assert Ok(q) = filter.parse_many(["::code", "message:text"])
  let comp =
    composer.new()
    |> composer.on_query(q, fn(_) { process.send(s, "match") })
  composer.run(comp, ctx_from(message_test_body))
  composer.run(comp, ctx_from(channel_post_body))
  assert process.receive(s, 50) == Ok("match")
  assert process.receive(s, 50) == Error(Nil)
}

pub fn on_filter_enum_works_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.on(filter.Message, fn(_) { process.send(s, "msg") })
    |> composer.on(filter.CallbackQuery, fn(_) { process.send(s, "cbq") })
  composer.run(comp, ctx_from(message_test_body))
  composer.run(comp, ctx_from(callback_body))
  assert process.receive(s, 50) == Ok("msg")
  assert process.receive(s, 50) == Ok("cbq")
}

// =====================================================================
//                             .hears
// =====================================================================

pub fn hears_checks_for_text_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.hears("test", fn(_) { process.send(s, "matched") })
  composer.run(comp, ctx_from(message_test_body))
  assert process.receive(s, 50) == Ok("matched")
}

pub fn hears_when_regex_via_pred_test() {
  // Substitute for grammY's regex chaining: use `hears_when` with a
  // predicate that contains all required substrings.
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.hears_when(
      fn(text) {
        string.starts_with(text, "te") && string.ends_with(text, "st")
      },
      fn(_) { process.send(s, "matched") },
    )
  composer.run(comp, ctx_from(message_test_body))
  assert process.receive(s, 50) == Ok("matched")
}

// =====================================================================
//                              .command
// =====================================================================

pub fn command_fires_only_for_matching_command_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.command("start", fn(_) { process.send(s, "start") })
    |> composer.command("help", fn(_) { process.send(s, "help") })
  composer.run(
    comp,
    context.new(message_with_command("/start", 6), dummy_api()),
  )
  composer.run(comp, context.new(message_with_command("/help", 5), dummy_api()))
  composer.run(
    comp,
    context.new(message_with_command("/quack", 6), dummy_api()),
  )
  assert collect_all(s) == ["start", "help"]
}

pub fn command_strips_bot_username_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.command("start", fn(_) { process.send(s, "fired") })
  composer.run(
    comp,
    context.new(message_with_command("/start@my_bot", 13), dummy_api()),
  )
  assert process.receive(s, 50) == Ok("fired")
}

pub fn command_any_accepts_alternates_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.command_any(["start", "begin"], fn(_) {
      process.send(s, "matched")
    })
  composer.run(
    comp,
    context.new(message_with_command("/start", 6), dummy_api()),
  )
  composer.run(
    comp,
    context.new(message_with_command("/begin", 6), dummy_api()),
  )
  composer.run(
    comp,
    context.new(message_with_command("/quack", 6), dummy_api()),
  )
  assert collect_all(s) == ["matched", "matched"]
}

// =====================================================================
//                       .callback_query / .chat_type
// =====================================================================

pub fn callback_query_matches_exact_data_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.callback_query("cb", fn(_) { process.send(s, "match") })
    |> composer.callback_query("xxx", fn(_) { process.send(s, "miss") })
  composer.run(comp, ctx_from(callback_body))
  assert process.receive(s, 50) == Ok("match")
  assert process.receive(s, 50) == Error(Nil)
}

pub fn chat_type_filters_correctly_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.chat_type(types.Private, fn(_) { process.send(s, "private") })
    |> composer.chat_type(types.Channel, fn(_) { process.send(s, "channel") })
  composer.run(comp, ctx_from(message_test_body))
  composer.run(comp, ctx_from(channel_post_body))
  assert collect_all(s) == ["private", "channel"]
}

// =====================================================================
//                       .filter / .drop / .branch
// =====================================================================

pub fn filter_runs_only_when_pred_true_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.filter(
      fn(ctx) {
        case context.message_text(ctx) {
          Some(t) -> string.contains(t, "test")
          None -> False
        }
      },
      fn(_) { process.send(s, "matched") },
    )
  composer.run(comp, ctx_from(message_test_body))
  composer.run(comp, ctx_from(callback_body))
  assert process.receive(s, 50) == Ok("matched")
  assert process.receive(s, 50) == Error(Nil)
}

pub fn drop_runs_only_when_pred_false_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.drop(
      fn(ctx) {
        case context.message_text(ctx) {
          Some(t) -> string.contains(t, "test")
          None -> False
        }
      },
      fn(_) { process.send(s, "not-test") },
    )
  composer.run(comp, ctx_from(message_test_body))
  composer.run(comp, ctx_from(callback_body))
  assert process.receive(s, 50) == Ok("not-test")
  assert process.receive(s, 50) == Error(Nil)
}

pub fn branch_picks_correct_arm_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.branch(
      fn(ctx) {
        case context.message_text(ctx) {
          Some(_) -> True
          None -> False
        }
      },
      fn(_) { process.send(s, "yes-message") },
      fn(_) { process.send(s, "no-message") },
    )
  composer.run(comp, ctx_from(message_test_body))
  composer.run(comp, ctx_from(callback_body))
  assert collect_all(s) == ["yes-message", "no-message"]
}

// =====================================================================
//                              .route
// =====================================================================

pub fn route_dispatches_on_key_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.route(
      fn(ctx) {
        case context.message_text(ctx) {
          Some(t) -> t
          None -> "default"
        }
      },
      [
        #("test", fn(_) { process.send(s, "route-test") }),
        #("hello", fn(_) { process.send(s, "route-hello") }),
      ],
    )
  composer.run(comp, ctx_from(message_test_body))
  // Unknown routes are silently ignored.
  composer.run(comp, ctx_from(callback_body))
  assert process.receive(s, 50) == Ok("route-test")
  assert process.receive(s, 50) == Error(Nil)
}

// =====================================================================
//                              .fork
// =====================================================================

pub fn fork_spawns_handler_in_background_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.fork(fn(_) { process.send(s, "forked") })
    |> composer.handle(fn(_) { process.send(s, "main") })
  composer.run(comp, ctx_from(message_test_body))
  // The main handler runs immediately; the fork may arrive before or
  // after — we just verify both eventually arrive.
  let messages = collect_all_eventually(s, 50)
  assert list.contains(messages, "main")
  assert list.contains(messages, "forked")
}

// =====================================================================
//                              .lazy
// =====================================================================

pub fn lazy_calls_factory_on_each_invocation_test() {
  let s: process.Subject(String) = process.new_subject()
  let counter: process.Subject(Int) = process.new_subject()
  let comp =
    composer.new()
    |> composer.lazy(fn(_ctx) {
      let n = case process.receive(counter, 0) {
        Ok(v) -> v
        Error(_) -> 0
      }
      process.send(counter, n + 1)
      fn(_ctx2) { process.send(s, "n=" <> int.to_string(n)) }
    })
  composer.run(comp, ctx_from(message_test_body))
  composer.run(comp, ctx_from(message_test_body))
  composer.run(comp, ctx_from(message_test_body))
  assert collect_all(s) == ["n=0", "n=1", "n=2"]
}

// =====================================================================
//                              Chain runs in order
// =====================================================================

pub fn chain_runs_handlers_in_order_test() {
  let s: process.Subject(String) = process.new_subject()
  let comp =
    composer.new()
    |> composer.handle(fn(_) { process.send(s, "one") })
    |> composer.handle(fn(_) { process.send(s, "two") })
    |> composer.handle(fn(_) { process.send(s, "three") })
  composer.run(comp, ctx_from(message_test_body))
  assert collect_all(s) == ["one", "two", "three"]
}

// =====================================================================
//                              helpers
// =====================================================================

fn collect_all(s: process.Subject(String)) -> List(String) {
  case process.receive(s, 50) |> result.map_error(fn(_) { Nil }) {
    Ok(v) -> [v, ..collect_all(s)]
    Error(_) -> []
  }
}

fn collect_all_eventually(s: process.Subject(String), ms: Int) -> List(String) {
  case process.receive(s, ms) {
    Ok(v) -> [v, ..collect_all_eventually(s, ms)]
    Error(_) -> []
  }
}
