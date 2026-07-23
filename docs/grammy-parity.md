# grammY parity

This document maps grammY modules and test areas to the corresponding glammy
artifacts. It is a navigation and traceability aid, not a promise of API parity
or a substitute for executable coverage.

## API surface mapping

### Core (`src/`)

| grammY                 | glammy                       | Notes                                  |
| ---------------------- | ---------------------------- | -------------------------------------- |
| `src/bot.ts`           | `glammy/bot.gleam`           | Blocking `start`; typed failures and bounded diagnostics |
| `src/composer.ts`      | `glammy/composer.gleam`      | Immutable; ~17 combinators             |
| `src/context.ts`       | `glammy/context.gleam`       | Concrete record, no generics           |
| `src/filter.ts`        | `glammy/filter.gleam`        | Typed enum + supported dotted-query DSL |
| `src/core/api.ts`      | `glammy/api.gleam`           | Typed wrappers + generic `call/4`      |
| `src/core/client.ts`   | `glammy/api.gleam`           | Merged into api                        |
| `src/core/error.ts`    | `glammy/error.gleam`         | Plus `describe/1`                      |
| `src/core/payload.ts`  | `glammy/multipart.gleam`     | Hand-rolled encoder                    |
| `src/types.ts` (1 line)| `glammy/types.gleam`         |                                        |
| `@grammyjs/types`      | `glammy/types.gleam`         | Hand-maintained supported subset       |

### Convenience (`src/convenience/`)

| grammY                                | glammy                                    | Notes                              |
| ------------------------------------- | ----------------------------------------- | ---------------------------------- |
| `convenience/keyboard.ts`             | `glammy/keyboard.gleam`                   | Plus transpose/flow/append         |
| `convenience/inline_query.ts`         | `glammy/inline_query_results.gleam`       | All major builders + cached_*      |
| `convenience/input_media.ts`          | `glammy/input_media.gleam`                | Photo/Video/Audio/Doc/Animation    |
| `convenience/session.ts`              | `glammy/session.gleam`                    | Pure-function `with_session`       |
| `convenience/webhook.ts`              | `glammy/webhook.gleam`                    | Framework-agnostic                 |
| `convenience/constants.ts`            | `glammy/constants.gleam`                  | Only values lacking typed APIs     |
| `convenience/frameworks.ts`           | (not ported)                              | Framework adapters — N/A           |

### glammy additions (no grammY equivalent)

| Module                          | Purpose                                                 |
| ------------------------------- | ------------------------------------------------------- |
| `glammy/error_boundary.gleam`   | Erlang try/catch around a sub-composer                  |
| `glammy/conversations.gleam`    | Actor-backed, non-persistent linear flows               |
| `glammy/keyed_executor.gleam`   | Bounded FIFO-per-key concurrency and backpressure       |
| `glammy/escape.gleam`           | HTML / Markdown / MarkdownV2 escapers                   |
| `glammy/input_file.gleam`       | Sum-type file descriptors (no auto-I/O)                 |
| `glammy/internal/ffi.gleam`     | Typed Erlang exception boundary (internal)              |
| `glammy/internal/json_utils.gleam` | Shared encoder/decoder helpers (internal)            |

## Test mapping

This table maps behavioural areas and intent only. Executable case counts are
intentionally omitted because they drift; `gleam test` is authoritative.
Different runtimes and assertion granularity also make a derived parity
percentage misleading.

| Area | glammy evidence | What is exercised |
| ---- | --------------- | ----------------- |
| Filters | `filter_test.gleam`, `filter_dsl_test.gleam` | Typed filters, dotted queries, shortcuts, defaults, invalid input |
| Telegram decoding | `types_test.gleam`, `more_types_test.gleam` | Update variants, raw fallback, open-enum fallbacks, representative nested types |
| API protocol | `client_test.gleam`, `api_contract_test.gleam`, `sans_io_test.gleam` | Envelope/status classification, prepared calls, standard HTTP boundary, multipart webhook certificates |
| Files and media | `input_file_test.gleam`, `input_media_test.gleam`, `multipart_test.gleam` | Sans-I/O descriptors, media encoding, multipart boundaries/uploads |
| UI builders | `keyboard_test.gleam`, `inline_query_results_test.gleam` | Keyboard actions, copy text, styles/icons, endpoint invariants, representative inline results |
| Composition | `context_test.gleam`, `composer_test.gleam`, `transformers_test.gleam` | Context access, middleware control flow, transformer order/short-circuit |
| State | `session_test.gleam`, `conversations_test.gleam` | CAS conflicts, post-commit effects, continuous conversation ownership, bounded routing, replacement, typed outcomes, cancellation |
| Runtime safety | `bot_test.gleam`, `keyed_executor_test.gleam`, `error_boundary_test.gleam` | Polling checkpoints, callback/job deadlines, handler ownership, bounded keyed concurrency, panic boundaries |
| Webhooks | `webhook_test.gleam` | Parsing, dispatch, secret verification |
| Helpers | `constants_test.gleam`, `escape_test.gleam`, `error_test.gleam` | Stable values, escaping, error descriptions |

grammY's framework-adapter, Deno dependency, and TypeScript compile-time tests
are intentionally not mirrored. Framework adapters are out of scope, and
Gleam's compiler checks its own static types.

## What is intentionally NOT ported

These behaviours of grammY are deliberately absent from glammy. If you
are working on a feature that touches one of them, this is the place
to read first.

### Concurrency model

grammY's behaviours that depend on JS `Promise` semantics:

- **Concurrent `handleUpdate` calls** — long polling processes a fetched batch
  sequentially. Each handler is isolated through a caller-monitoring broker
  that owns a linked worker and applies a bounded timeout, but polling waits for
  its result before starting the next update. `keyed_executor.update_gate` is
  the bounded opt-in path for slow per-chat/key work; `composer.fork` remains
  an unbounded, detached low-level primitive outside the ownership barrier.
- **Promise-based init caching** — grammY's `bot.init()` Promise is
  cached; concurrent inits wait on the same Promise. glammy has no
  internal caching; users call `api.get_me` themselves if they need
  the bot info, or rely on `verify_token=True` in PollingOptions.
- **`bot.isRunning()` / `bot.stop()` lifecycle** — grammY tracks
  global running state and prevents double-start. glammy's `bot.start` is a
  blocking call: the application must supervise it and enforce one poller per
  token. There is no first-class stop handle, readiness signal, or double-start
  guarantee. Owner-aware callback/handler cleanup covers only library-owned
  tasks, not arbitrary descendants, and cannot roll back in-flight effects.

### Framework adapters

grammY ships many webhook adapters (`webhookCallback(bot, "express")`,
`"hono"`, `"cloudflare-mod"`, etc.). glammy's
`webhook.handle_isolated/3` is framework-agnostic — wire it into whatever HTTP
server you already have. The synchronous `webhook.handle/2` remains available
when the application owns the isolation boundary.

### Web platform features

- **`InputFile` from `Blob`/`Response`/`URL`/`ReadableStream`** — JS
  platform types. glammy's `InputFile` accepts pre-loaded `BitArray`,
  a URL string, or a file_id.

### Plugin ecosystem features

- **`enhanceStorage` / `lazySession`** — grammy session decorators.
  glammy users compose `custom_storage` themselves.
- **`@grammyjs/conversations` persistent replay** — glammy's
  `conversations.gleam` does linear-flow only (lost on restart). See
  [design-decisions.md D-13](https://github.com/castletaste/glammy/blob/main/docs/design-decisions.md).

### TS type-level features

- **`Context.has.*` type guards** — glammy provides equivalent runtime
  checks (`context.has_callback_data`, `context.message`, etc.) but no
  TS-style narrowing.
- **`assertType<IsExact<…>>`** — Gleam's compiler types are already
  exhaustive over sum types, so these tests have no parallel.

## Backwards-compatibility with grammY API names

glammy uses Gleam snake_case throughout. Direct grammY → glammy
translation cheatsheet:

| grammY (TS)             | glammy (Gleam)              |
| ----------------------- | --------------------------- |
| `bot.on(...)`           | `composer.on(...)`          |
| `bot.command(...)`      | `composer.command(...)`     |
| `bot.hears(...)`        | `composer.hears(...)`       |
| `bot.callbackQuery(...)`| `composer.callback_query(...)` |
| `bot.handleUpdate(u)`   | `bot.handle_update(b, u)`   |
| `bot.start()`           | `bot.start(b, opts)`        |
| `ctx.message`           | `context.message(ctx)`      |
| `ctx.chat`              | `context.chat(ctx)`         |
| `ctx.from`              | `context.from(ctx)`         |
| `ctx.reply(...)`        | `context.reply(ctx, ...)`   |
| `ctx.api.sendMessage`   | `api.send_message(ctx.api, ...)` |
| `InlineKeyboard.text()` | `keyboard.inline_text(k, ...)` |
| `new InputFile(...)`    | `input_file.from_bytes` / `from_url` / `from_file_id` |
| `session(opts)`         | `session.with_session(c, storage, key_fn, default, handler, on_error:)`; handler returns `SessionUpdate` |
| `webhookCallback(bot, ...)` | `webhook.handle_isolated(bot, body, timeout_ms:)` |
