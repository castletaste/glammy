# Architecture

## Module graph

Top-down dependencies (read top imports bottom):

```
glammy (entry)
  └─ glammy/bot                        — long-polling driver
      └─ glammy/composer                — middleware chain
      │   └─ glammy/context             — Context wrapper
      │   │   └─ glammy/types           — Telegram types + decoders
      │   ├─ glammy/filter              — Filter enum + query DSL
      │   └─ gleam/erlang/process       — Subject / spawn (for `fork`)
      ├─ glammy/api                     — HTTP+JSON Bot API client
      │   ├─ glammy/multipart           — multipart/form-data encoder
      │   ├─ glammy/input_file          — File source descriptors
      │   ├─ glammy/error               — Error variants + `describe`
      │   └─ glammy/internal/json_utils — shared put_optional / opt_str / opt_nested / opt_list
      ├─ glammy/webhook                 — framework-agnostic dispatch
      ├─ glammy/session                 — per-key state with pluggable storage
      ├─ glammy/conversations           — single-process linear flows
      ├─ glammy/error_boundary          — catches Erlang try/catch
      │   └─ glammy_ffi.erl             — small Erlang FFI for try_run/1
      ├─ glammy/keyboard                — Inline / Reply keyboard builders
      ├─ glammy/inline_query_results    — InlineQueryResult* builders
      ├─ glammy/input_media             — InputMedia* builders
      ├─ glammy/constants               — parse modes, chat actions, etc.
      └─ glammy/escape                  — HTML / Markdown escaping
```

No circular deps. `glammy/types` is the foundation; everything that
talks to the Telegram API depends on it.

## Layered model

```
┌──────────────────────────────────────────────────────────┐
│ Application layer    bot.start()      webhook.handle()   │
├──────────────────────────────────────────────────────────┤
│ Pipeline layer       composer  +  context  +  filter      │
├──────────────────────────────────────────────────────────┤
│ Plugin layer         session  conversations  error_bd     │
├──────────────────────────────────────────────────────────┤
│ API layer            api  (with transformers)             │
├──────────────────────────────────────────────────────────┤
│ Encoding layer       multipart  input_file  json_utils    │
├──────────────────────────────────────────────────────────┤
│ Data layer           types (Update, Message, …)           │
└──────────────────────────────────────────────────────────┘
```

## Data flow for a single update

### Long-polling path

1. `bot.start` (in `bot.gleam`) calls `api.get_updates`.
2. Each returned `Update` is fed to `bot.handle_update`.
3. `handle_update` wraps the update in a `Context` and calls
   `composer.run`.
4. `composer.run` folds the middleware stack right-to-left into a
   nested closure, then invokes the outermost one.
5. Each middleware either calls `next()` (passing control on) or
   short-circuits.
6. If a handler invokes `api.send_message` (or another method), the
   call passes through every registered transformer before the HTTP
   layer.
7. The HTTP layer uses `gleam_httpc` to POST to Telegram, then decodes
   the envelope.

### Webhook path

1. Caller's HTTP server hands a POST body to `webhook.handle`.
2. `webhook.handle` parses it as an `Update`.
3. Dispatch from step 3 above — identical thereafter.

## Core types map

| Telegram concept            | glammy type                                               |
| --------------------------- | --------------------------------------------------------- |
| Bot API method call         | `api.call` / `api.call_multipart`                         |
| Bot API response envelope   | `error.GlammyError` (`ApiError` / `HttpError` / `Decode`) |
| Update                      | `types.Update { update_id, kind: types.UpdateKind }`      |
| All 23 Update sub-shapes    | `types.UpdateKind` variants (+ `OtherUpdate` fallback)    |
| File reference              | `input_file.InputFile`                                    |
| Multipart payload           | `multipart.Encoded { body, content_type }`                |
| Filter query                | `filter.Query` (opaque, from `filter.parse`)              |

## Key design invariants

1. **Composers are immutable.** Every `composer.use_middleware/on/…`
   returns a *new* composer. The `Composer` opaque type wraps an
   ordered list of middleware functions. The fold in
   `composer.run` rebuilds the chain on every invocation — this is
   cheap; closures over the ctx are not allocated until needed.

2. **The transformer chain is composed right-to-left.** First
   registered transformer is the outermost wrapper. `api.with_transformer`
   *appends* to an internal list; `compose_chain` walks it with
   `list.fold_right`.

3. **Context is concrete, not generic.** Unlike grammY's
   `Context<T extends BaseContext>`, glammy's Context is a fixed shape.
   To attach extra per-update state, plugins thread it explicitly (see
   `session.with_session`) or via separate side-channels (see
   `conversations`).

4. **No global mutable state.** Every "stateful" component
   (memory storage, conversations registry) is a BEAM process accessed
   via `Subject`. State lives in the process's mailbox loop.

5. **HTTP layer can be bypassed by transformers.** A transformer that
   never calls `next` returns a synthetic body — useful for tests
   (see `client_test`).

## Subject-actor pattern

Two modules spawn BEAM processes that hold state:

- `session.memory_storage()`
- `conversations.new_registry()`

Both use the same setup dance:

```gleam
let setup_subject = process.new_subject()
let _ = process.spawn(fn() {
  let work_subject = process.new_subject()
  process.send(setup_subject, work_subject)
  state_loop(work_subject, initial_state)
})
let work_subject = process.receive_forever(setup_subject)
// `work_subject` is owned by the spawned process — sending to it
// reaches the loop's `receive_forever`.
```

Why the dance: `process.new_subject()` creates a Subject owned by the
*caller's* process. If the caller (parent) makes a subject and the
spawned (child) does `receive_forever(subject)`, the child receives
from its OWN mailbox, never seeing messages sent to the parent. The
two-step setup gives the child a Subject *it owns*, which the parent
then captures.

## File-by-file responsibilities

- **`glammy.gleam`** — top-level entry; just a banner `main` and module
  re-export documentation.
- **`glammy/types.gleam`** — every Telegram type used by glammy, with a
  matching `*_decoder()` function. ~2400 lines, single-file by choice
  (see [design-decisions.md](design-decisions.md)).
- **`glammy/error.gleam`** — `GlammyError` sum type + `describe/1`.
- **`glammy/api.gleam`** — `Api` opaque client, transformer chain, `call`
  / `call_multipart` dispatch, ~50 typed Bot API method wrappers.
- **`glammy/composer.gleam`** — `Composer` opaque type, middleware
  primitives (`use_middleware`, `handle`), filtering combinators
  (`on`, `on_query`, `filter`, `drop`, `branch`, `route`,
  `chat_type`, `callback_query`), control flow (`fork`, `lazy`,
  `append`), command/hears matchers.
- **`glammy/context.gleam`** — `Context` record + aggregators
  (`message`, `chat`, `from`, `message_id`, `chat_id`,
  `inline_message_id`, `business_connection_id`, `sender_chat`,
  `has_callback_data`) and `reply`/`reply_with` shortcuts.
- **`glammy/filter.gleam`** — typed `Filter` enum AND grammY-style
  string-DSL parser (`parse`, `parse_many`, `matches`, `matches_query`).
  Implements L1/L2 shortcuts (`msg`, `edit`), default expansion
  (`:text`, `::url`), structural validation against the update tree.
- **`glammy/keyboard.gleam`** — `InlineKeyboard` / `ReplyKeyboard`
  builders with `transpose` / `flow` / `append` post-processors.
- **`glammy/bot.gleam`** — `Bot` opaque type, `start`, `handle_update`,
  `on_error`, polling options.
- **`glammy/webhook.gleam`** — `handle` / `handle_with_secret` /
  `verify_secret`. Framework-agnostic.
- **`glammy/session.gleam`** — `Storage(value)` opaque, `memory_storage`,
  `custom_storage`, `with_session` composer integration,
  `by_chat_id`/`by_user_id`/`by_chat_and_user` key fns.
- **`glammy/conversations.gleam`** — `Registry` + `middleware` + `start`
  + `wait` for linear flows. User-keyed.
- **`glammy/error_boundary.gleam`** — wraps a sub-composer in Erlang
  `try` (via `glammy_ffi.erl`) so panics don't propagate out.
- **`glammy/multipart.gleam`** — hand-rolled multipart/form-data encoder
  (`Part`, `Encoded`, `encode/1`) using `crypto:strong_rand_bytes` for
  the boundary.
- **`glammy/input_file.gleam`** — `InputFile` sum type
  (`FileId`/`FileUrl`/`FileBytes`/`FilePath`) +
  `from_path`/`from_url`/`from_bytes`/`from_file_id` constructors +
  `infer_filename`/`requires_upload`/`to_payload_value`.
- **`glammy/input_media.gleam`** — `InputMedia*` variants +
  `to_json/2` (with caller-supplied attach resolver).
- **`glammy/inline_query_results.gleam`** — `InlineQueryResult*` and
  `InputMessageContent` builders.
- **`glammy/constants.gleam`** — every Telegram string constant
  (parse modes, chat actions, sticker types, currencies, scope names).
- **`glammy/escape.gleam`** — HTML / Markdown / MarkdownV2 escapers.
- **`glammy/internal/json_utils.gleam`** — INTERNAL. Shared
  `put_optional` / `opt_str` / `opt_int` / `opt_bool` / `opt_float` /
  `opt_with_default` / `opt_nested` / `opt_list` for the JSON
  build/decode boilerplate. `opt_nested` covers an optional nested
  object field, `opt_list` an optional list field defaulting to `[]`.
- **`glammy_ffi.erl`** — FFI: `try_run/1` for `error_boundary`.

## Conventions

- **Naming:** snake_case for fns / types. Variants use PascalCase.
- **Labelled args** are used wherever a function takes multiple args of
  the same primitive type (e.g.
  `api.get_updates(api, offset: …, limit: …, timeout: …, allowed_updates: …)`).
- **Opaque types** for everything stateful (`Api`, `Composer`, `Bot`,
  `Storage`, `Registry`). Construction via `new`/`memory_storage`/etc.
- **Result returns** for fallible operations. No exceptions in the
  public API surface.
- **`Option(T)`** for nullable Telegram fields.
- **`@external`** only when truly necessary (Erlang try/catch,
  `crypto:hash_equals`, `crypto:strong_rand_bytes`).
- **`use` syntax** for decoders and shared helpers
  (`use x <- decode.field(…)`).
- **Tests live in `test/glammy/*_test.gleam`,** mirroring `src/glammy/*.gleam`.
