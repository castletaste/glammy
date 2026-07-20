# glammy

A Telegram Bot Framework for [Gleam](https://gleam.run) — a from-scratch
port of [grammY](https://github.com/grammyjs/grammY) (the TypeScript
framework) to the BEAM virtual machine.

When the initial Hex release is available, install glammy with:

```sh
gleam add glammy
```

```gleam
import glammy
import gleam/io
import gleam/string

fn reply(ctx, text) -> Nil {
  case glammy.reply(ctx, text) {
    Ok(_) -> Nil
    Error(reply_error) -> io.println_error(string.inspect(reply_error))
  }
}

pub fn main() -> Nil {
  let client = glammy.api("123456:ABC-DEF...")  // token from @BotFather

  let handlers =
    glammy.composer()
    |> glammy.command("start", fn(ctx) {
      reply(ctx, "Hi, I'm a glammy bot 👋")
    })
    |> glammy.hears("ping", fn(ctx) {
      reply(ctx, "pong")
    })

  case glammy.bot(client, handlers) |> glammy.start {
    Ok(_) -> Nil
    Error(start_error) -> io.println_error(string.inspect(start_error))
  }
}
```

The token above is a non-working placeholder. Load the real value from your
application's environment or secret manager; never commit a BotFather token.

The complete [`examples/echo_bot`](https://github.com/castletaste/glammy/tree/main/examples/echo_bot) project is compiled in
CI, so the quickstart stays aligned with the public API.

## What's in the box

### Core

| Module                  | Role                                                              |
| ----------------------- | ----------------------------------------------------------------- |
| `glammy/api`            | Prepared calls, sans-I/O HTTP seam, typed methods, `httpc` convenience. |
| `glammy/types`          | Supported Telegram updates, messages, media, and payments.        |
| `glammy/composer`       | Middleware pipeline — `command`, `hears`, `on`, `use_middleware`. |
| `glammy/context`        | `Context` wrapper passed to every handler.                        |
| `glammy/filter`         | Strongly-typed enum **and** grammY-style dotted string DSL.       |
| `glammy/keyboard`       | Typed inline/reply keyboards, button actions, styles, and icons.  |
| `glammy/bot`            | Long polling with backoff, isolated handlers, and typed failures. |
| `glammy/keyed_executor` | Bounded FIFO-per-key work with global concurrency and backpressure. |
| `glammy/error`          | `GlammyError` variants returned by the client.                    |

### Media

| Module               | Role                                                                 |
| -------------------- | -------------------------------------------------------------------- |
| `glammy/input_file`  | Typed Telegram file references and upload sources.                    |
| `glammy/multipart`   | Hand-rolled multipart/form-data encoder (no extra deps).             |
| `glammy/input_media` | `InputMediaPhoto`/`Video`/`Audio`/`Document`/`Animation` builders.   |

### Plugins & extensions

| Module                          | Role                                                                  |
| ------------------------------- | --------------------------------------------------------------------- |
| `glammy/session`                | Per-chat / per-user session storage. Default in-memory backend.       |
| `glammy/conversations`          | Non-blocking, actor-backed linear flows; in-memory, not replayable.     |
| `glammy/error_boundary`         | Catch panics / Erlang errors inside a sub-composer.                   |
| `glammy/webhook`                | Framework-agnostic webhook adapter with secret-token verification.    |
| `glammy/webhook_secret`         | Validated secret shared by registration and verification.            |
| `glammy/https_url`              | Absolute HTTPS URLs for TLS-only Bot API fields.                      |
| `glammy/inline_query_results`   | Opaque, typed builders for inline-query results.                      |
| `glammy/escape`                 | HTML / Markdown / MarkdownV2 escaping for user-provided text.         |
| `glammy/constants`              | Compatibility aliases plus currency and other stable constants.       |

## Typed outbound values

High-level API wrappers make invalid protocol states difficult to construct:
parse modes, chat actions, keyboards, reactions, poll kinds, replies, command
scopes, and media options are typed. `types.poll_question` and
`types.input_poll_option` accept plain text, reject blank values, and validate
Telegram's Unicode-codepoint bounds before construction; parsed/entity forms
use the explicit prepared-call seam. Poll collections then validate the 1–12
option boundary. `api.regular_poll(options)` and
`api.quiz_poll(options, first_id, other_ids, explanation)` bind those exact
options—and an optional bounded, quiz-only explanation—to the resulting opaque
`SendPoll`; descriptions are bounded opaque values too. Game sends,
inline game results, and invoice calls accept dedicated keyboard types that
always put the required launch or Pay button first. Inline answers validate
the 50-result limit. HTML inline videos require replacement content;
video notes accept only opaque sources built by `input_file.file_id_source` or
`input_file.upload_source`; webhook registration and verification share one
validated secret type. Self-signed webhook certificates have an upload-only
typed path, while keyboard copy actions, styles, and custom-emoji icons retain
exactly one button action. Message sends choose one opaque regular/reply/ephemeral
delivery state, ephemeral media edits accept reuse-only media, and command or
batch-message identifiers are validated before dispatch; forward batches also
prove Telegram's strictly increasing order. Command collections,
invite-link option combinations, and Bot API fields that require HTTPS are
validated before dispatch as well. For a newly released Telegram field that is
not modelled yet, use the explicit prepared-call family:
`api.prepare_json_call` for JSON and `api.prepare_multipart_call` for uploads.
The same seam covers the Local Bot API server's HTTP-webhook exception; the
high-level `set_webhook` and `set_webhook_with_certificate` follow the public
Bot API's HTTPS-only contract.

## Transformers — API middleware

```gleam
let logging =
  fn(next, method, payload) {
    io.println("→ " <> method)
    next(method, payload)
  }

api.new(token)
|> api.with_transformer(logging)
```

A transformer wraps the next call in the chain. It can:

- Modify the payload before delegating.
- Short-circuit (return a fake response without hitting the network).
- Observe results — useful for logging, rate-limiting, retry-on-429.

## Bring your own HTTP client

The built-in methods use `gleam_httpc`, but protocol handling is available
without dispatching any I/O. A prepared call keeps its result decoder opaque
and method-specific:

```gleam
import glammy/api
import glammy/types

let call = api.prepare_json_call("getMe", [], types.user_decoder())
let assert Ok(request) = api.to_http_request(client, call)

// Send `request` with your HTTP client, producing a
// gleam/http/response.Response(BitArray).
let result = api.from_http_response(call, http_response)
```

Telegram embeds the bot token in the request URL. Redact the request path from
logs. `PreparedCall` itself contains no token.

## Webhook integration

glammy does **not** ship its own HTTP server (that would mean pulling
`wisp` or `mist` as a transitive dependency). Instead, hook it up to
whichever Gleam HTTP framework you already use:

```gleam
import glammy/webhook
import glammy/webhook_secret

let assert Ok(secret) = webhook_secret.new(configured_secret)

// Inside your HTTP handler. The isolated path keeps middleware panics and
// timeouts from taking down the server's request process.
case webhook.handle_isolated_with_secret(
  bot,
  body,
  header_value: secret_header,
  expected_secret: secret,
  timeout_ms: 30_000,
) {
  Ok(_) -> response.new(200) |> response.set_body("")
  Error(webhook.ParseError(_)) -> response.new(400)
  Error(webhook.BadSecretToken) -> response.new(401)
  Error(webhook.HandlerFailed(_)) -> response.new(500)
}
```

## Sessions

State is threaded **explicitly** through a pure-function handler — no
process dictionary, no mutable globals:

```gleam
let assert Ok(storage) = session.memory_storage()

composer.new()
|> session.with_session(storage, session.by_chat_id, 0, fn(ctx, n) {
  let next = n + 1
  session.update_then(next, fn() {
    case context.reply(ctx, "count = " <> int.to_string(next)) {
      Ok(_) -> Nil
      Error(reply_error) ->
        io.println_error(string.inspect(reply_error))
    }
  })
}, on_error: fn(_, storage_error) {
  io.println_error(string.inspect(storage_error))
})
```

The pure transition may be retried after a compare-and-set conflict.
`update_then` runs its effect at most once after this process observes a
successful commit; a crash between commit and effect can omit it. For durable
delivery, use a transactional outbox. For a fallible persistent backend
(Redis, Postgres, …), use `session.custom_storage_result`. Atomicity is local
to one `Storage` handle; shared distributed backends still need their own
transaction or CAS. A mutation timeout is split into `CallTimeout` (known not
started) and `MutationOutcomeUnknown` (do not retry blindly). Once a custom
mutation callback starts, its `Error` or panic also means the external outcome
is unknown; glammy retires that `Storage` handle so stale local revision state
cannot be reused. Reconcile the backend before creating a fresh adapter.

## Bounded per-chat work

Long polling remains sequential by default. Slow LLM or tool calls can be
admitted through the bounded keyed executor without losing per-chat order:

```gleam
let assert Ok(executor) = keyed_executor.start(
  max_concurrency: 8,
  capacity: 256,
)

let slow_work_gate =
  keyed_executor.update_gate(
    executor,
    keyed_executor.by_chat_id,
    fn(ctx) { run_slow_assistant_turn(ctx) },
    outcome_actor_subject,
  )

let running_bot =
  bot.new(client, handlers_for_updates_not_owned_by_the_executor)
  |> bot.with_update_gate(conversations.update_gate(registry))
  |> bot.with_update_gate(slow_work_gate)
```

One key runs FIFO with at most one active job; different keys run up to the
global limit. Capacity counts active plus queued jobs. Every active job has a
finite runtime deadline: five minutes with `start`, or
`Options.job_timeout_ms` with `start_with_options`. Queueing time is excluded.
On expiry the operation is confirmed down before `TimedOut(timeout_ms)` is
published and its key, global slot, and capacity are released. External effects
performed before termination may still have happened. The outcome subject must
be owned and drained by an application actor. Admission failure is typed and
fails the update gate, so polling does not acknowledge work rejected under
backpressure. Admission success is only a volatile in-memory queue receipt:
accepted work can still be cancelled or lost with the executor/node, so durable
effects need an outbox, journal, or idempotency key. `composer.fork` remains an
unbounded low-level primitive.

`Some(key)` means the executor operation owns that entire update: after a
successful admission the bot's ordinary composer is not run. Use a selective
key function when only some updates are slow, or run the complete intended
assistant/sub-composer path inside the submitted operation. In the example,
the bot composer is deliberately only the fallback for updates no gate owns.

Update gates run in registration order and `Consumed` short-circuits later
gates. Register specialized owners such as conversations before the general
per-chat executor, as in the example; reversing them would enqueue conversation
replies as ordinary assistant work.

A conversation owns its key continuously from `start` until completion or
stop, including computation between two `wait` calls. One update can be held
across that gap and is acknowledged only after the next wait actually dequeues
it. A second update receives `RouteBufferFull`, suppresses downstream
middleware, and fails the polling gate so Telegram supplies backpressure. A
registry `CallTimeout` also fails routing closed: inability to inspect the
registry is not proof that this key has no live conversation owner. `Stopped`
does likewise because registry death can precede the worker shutdown barrier.

## Polling ownership and shutdown

`bot.start` is a blocking runner. Diagnostic callbacks registered with
`bot.on_error` and `bot.on_runtime_error` have a bounded deadline. Configure it
with `bot.with_callback_timeout(bot, timeout_ms)`, which returns
`Result(Bot, BotConfigError)` and accepts only BEAM-safe values from 1 through
4,294,967,295 milliseconds, otherwise returning `bot.InvalidCallbackTimeout`;
the default is 5 seconds. Handler deadlines use the same range. On timeout,
glammy kills the callback task and allows up to one additional second to
confirm termination. glammy reports callback crashes and timeouts with redacted
text; they never replace the typed result that the runner was already
returning. The custom callback still receives the original typed error, so the
application owns what that callback logs. The callback guard monitors its direct
caller and also tears down the actual callback task if that caller dies.

Isolated update dispatch has the same narrow ownership rule: its broker
monitors the direct caller, and the library-owned handler worker is linked to
that broker. When the caller dies, including during supervisor teardown, the
broker does not leave that handler worker orphaned.

This is cleanup, not a managed bot runtime. The application must supervise the
blocking call and ensure that only one poller uses a bot token. glammy currently
has no first-class stop handle, readiness signal, or double-start guard.
`composer.fork` tasks and arbitrary handler descendants are detached and are
not part of a shutdown barrier. Termination also cannot roll back Telegram,
database, or other external effects that already started; use idempotency keys,
a journal, or an outbox where once-only delivery matters.

## Filter queries

```gleam
// Strongly typed
composer.on(filter.CallbackQuery, on_callback)

// Or dotted-string DSL, à la grammY
let assert Ok(q) = filter.parse_many(["message:photo", "message:video"])
case filter.matches_query(q, ctx) {
  True -> handle_media(ctx)
  False -> Nil
}
```

## Documentation

The [`docs/`](https://github.com/castletaste/glammy/tree/main/docs) directory captures the **why** behind glammy's
design. Start with [`docs/README.md`](https://github.com/castletaste/glammy/blob/main/docs/README.md):

- [`docs/architecture.md`](https://github.com/castletaste/glammy/blob/main/docs/architecture.md) — module graph, layered
  model, data flow, file-by-file responsibilities
- [`docs/design-decisions.md`](https://github.com/castletaste/glammy/blob/main/docs/design-decisions.md) — load-bearing
  design decisions with the rejected alternatives and reasons
- [`docs/grammy-parity.md`](https://github.com/castletaste/glammy/blob/main/docs/grammy-parity.md) — capability and test
  mapping vs grammY, plus a translation cheatsheet
- [`docs/roadmap.md`](https://github.com/castletaste/glammy/blob/main/docs/roadmap.md) — known gaps and future-work
  ideas
- [`docs/releasing.md`](https://github.com/castletaste/glammy/blob/main/docs/releasing.md) — release gates and Hex checklist

## Differences from grammY

| Area              | grammY (TS)                          | glammy (Gleam)                                |
| ----------------- | ------------------------------------ | --------------------------------------------- |
| Concurrency       | `Promise`/`async`                    | Sequential intake; bounded keyed concurrency is opt-in |
| Errors            | Thrown `GrammyError`                 | Typed `Result` at fallible boundaries          |
| Filter queries    | Dotted strings + complex generics    | Typed `Filter` enum **plus** dotted strings   |
| Coverage          | Every Bot API method + plugins       | Most-used methods + an escape-hatch `call`    |
| Conversations     | Persistent, replayable               | Actor-backed, in-memory (lost on restart)     |
| HTTP server       | Built-in adapters for many runtimes  | Bring-your-own — `glammy/webhook` is enough   |
| Local file upload | Auto-reads paths                     | Caller passes `FileBytes` (no disk I/O in lib)|

## Dependencies

Runtime dependencies are published from projects in the official `gleam-lang`
GitHub organisation:

- `gleam_stdlib`
- `gleam_erlang`
- `gleam_http`
- `gleam_httpc`
- `gleam_json`
- `gleam_otp`

Tests use the dev-only [`gleeunit`](https://github.com/lpil/gleeunit) runner.

If you fork or contribute, please **do not add third-party hex packages**
without a security review — bot tokens are sensitive credentials.

## Development

```sh
gleam build
gleam build --warnings-as-errors
gleam test
./scripts/check_keyed_executor_startup_barrier.sh
gleam docs build
gleam format --check src test examples/echo_bot/src
./scripts/check_min_deps.sh
gleam export hex-tarball
./scripts/verify_hex_tarball.sh
./scripts/build_hex_consumer.sh
```

## License

MIT.
