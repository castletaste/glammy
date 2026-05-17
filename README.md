# glammy

A Telegram Bot Framework for [Gleam](https://gleam.run) — a from-scratch
port of [grammY](https://github.com/grammyjs/grammY) (the TypeScript
framework) to the BEAM virtual machine.

```sh
gleam add glammy
```

```gleam
import glammy/api
import glammy/bot
import glammy/composer
import glammy/context

pub fn main() -> Nil {
  let api = api.new("123456:ABC-DEF...")  // token from @BotFather

  let comp =
    composer.new()
    |> composer.command("start", fn(ctx) {
      let _ = context.reply(ctx, "Hi, I'm a glammy bot 👋")
      Nil
    })
    |> composer.hears("ping", fn(ctx) {
      let _ = context.reply(ctx, "pong")
      Nil
    })

  bot.new(api, comp)
  |> bot.start(bot.default_polling_options())
}
```

## What's in the box

### Core

| Module                  | Role                                                              |
| ----------------------- | ----------------------------------------------------------------- |
| `glammy/api`            | HTTP + JSON Bot API client. ~50 typed methods + generic `call`.   |
| `glammy/types`          | Telegram types (Update, Message, Chat, all media, payments, …).   |
| `glammy/composer`       | Middleware pipeline — `command`, `hears`, `on`, `use_middleware`. |
| `glammy/context`        | `Context` wrapper passed to every handler.                        |
| `glammy/filter`         | Strongly-typed enum **and** grammY-style dotted string DSL.       |
| `glammy/keyboard`       | `InlineKeyboard` and `ReplyKeyboard` builders.                    |
| `glammy/bot`            | Long-polling runner with backoff + error handler.                 |
| `glammy/error`          | `GlammyError` variants returned by the client.                    |

### Media

| Module               | Role                                                                 |
| -------------------- | -------------------------------------------------------------------- |
| `glammy/input_file`  | `FileId` / `FileUrl` / `FileBytes` / `FilePath` source descriptors.  |
| `glammy/multipart`   | Hand-rolled multipart/form-data encoder (no extra deps).             |
| `glammy/input_media` | `InputMediaPhoto`/`Video`/`Audio`/`Document`/`Animation` builders.   |

### Plugins & extensions

| Module                          | Role                                                                  |
| ------------------------------- | --------------------------------------------------------------------- |
| `glammy/session`                | Per-chat / per-user session storage. Default in-memory backend.       |
| `glammy/conversations`          | Linear "ask, wait, branch" flows in a single process lifetime.        |
| `glammy/error_boundary`         | Catch panics / Erlang errors inside a sub-composer.                   |
| `glammy/webhook`                | Framework-agnostic webhook adapter with secret-token verification.    |
| `glammy/inline_query_results`   | Builders for `InlineQueryResult*` JSON.                               |
| `glammy/escape`                 | HTML / Markdown / MarkdownV2 escaping for user-provided text.         |
| `glammy/constants`              | Parse-mode / chat-action / currency / poll-type constants.            |

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

## Webhook integration

glammy does **not** ship its own HTTP server (that would mean pulling
`wisp` or `mist` as a transitive dependency). Instead, hook it up to
whichever Gleam HTTP framework you already use:

```gleam
import glammy/webhook

// Inside your HTTP handler:
case webhook.handle_with_secret(bot, body, secret_header, secret) {
  Ok(_) -> response.new(200) |> response.set_body("")
  Error(webhook.ParseError(_)) -> response.new(400)
  Error(webhook.BadSecretToken) -> response.new(401)
}
```

## Sessions

State is threaded **explicitly** through a pure-function handler — no
process dictionary, no mutable globals:

```gleam
let storage: session.Storage(Int) = session.memory_storage()

composer.new()
|> session.with_session(storage, session.by_chat_id, 0, fn(ctx, n) {
  let _ = context.reply(ctx, "count = " <> int.to_string(n + 1))
  n + 1  // returned value is persisted automatically
})
```

For persistent storage (Redis, Postgres, …) implement the
`session.Storage` interface yourself via `session.custom_storage`.

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

The [`docs/`](docs/) directory captures the **why** behind glammy's
design. Start with [`docs/README.md`](docs/README.md):

- [`docs/architecture.md`](docs/architecture.md) — module graph, layered
  model, data flow, file-by-file responsibilities
- [`docs/design-decisions.md`](docs/design-decisions.md) — 18 load-bearing
  design decisions with the rejected alternatives and reasons
- [`docs/grammy-parity.md`](docs/grammy-parity.md) — full API and test
  parity matrix vs grammY, plus a translation cheatsheet
- [`docs/roadmap.md`](docs/roadmap.md) — known gaps and future-work
  ideas

## Differences from grammY

| Area              | grammY (TS)                          | glammy (Gleam)                                |
| ----------------- | ------------------------------------ | --------------------------------------------- |
| Concurrency       | `Promise`/`async`                    | Synchronous-style on BEAM processes           |
| Errors            | Thrown `GrammyError`                 | `Result(_, GlammyError)` everywhere           |
| Filter queries    | Dotted strings + complex generics    | Typed `Filter` enum **plus** dotted strings   |
| Coverage          | Every Bot API method + plugins       | Most-used methods + an escape-hatch `call`    |
| Conversations     | Persistent, replayable               | One process lifetime (lost on restart)        |
| HTTP server       | Built-in adapters for many runtimes  | Bring-your-own — `glammy/webhook` is enough   |
| Local file upload | Auto-reads paths                     | Caller passes `FileBytes` (no disk I/O in lib)|

## Dependencies

Every dependency is from the official `gleam-lang` GitHub organisation on
hex.pm:

- `gleam_stdlib`
- `gleam_erlang`
- `gleam_http`
- `gleam_httpc`
- `gleam_json`
- `gleeunit` (dev)

If you fork or contribute, please **do not add third-party hex packages**
without a security review — bot tokens are sensitive credentials.

## Development

```sh
gleam build
gleam test
```

## License

MIT.
