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
      ├─ glammy/api                     — prepared calls + HTTP/JSON client
      │   ├─ glammy/multipart           — multipart/form-data encoder
      │   ├─ glammy/input_file          — File source descriptors
      │   ├─ glammy/https_url           — validated TLS-only URLs
      │   ├─ glammy/error               — Error variants + `describe`
      │   └─ glammy/internal/json_utils — shared put_optional / opt_str / opt_nested / opt_list
      ├─ glammy/webhook                 — framework-agnostic dispatch
      ├─ glammy/session                 — OTP storage actor + optimistic CAS
      ├─ glammy/conversations           — OTP registry + worker-per-flow
      ├─ glammy/keyed_executor          — bounded FIFO-per-key scheduler
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
│ Application layer    bot.start()  webhook.handle_isolated() │
├──────────────────────────────────────────────────────────┤
│ Pipeline layer       composer  +  context  +  filter      │
├──────────────────────────────────────────────────────────┤
│ Plugin layer         session  conversations  error_bd     │
├──────────────────────────────────────────────────────────┤
│ API layer            api  (prepared calls + transformers) │
├──────────────────────────────────────────────────────────┤
│ Encoding layer       multipart  input_file  json_utils    │
├──────────────────────────────────────────────────────────┤
│ Data layer           types (Update, Message, …)           │
└──────────────────────────────────────────────────────────┘
```

## Data flow for a single update

### Long-polling path

1. `bot.start` validates `PollingOptions`, optionally verifies the token, then
   calls `api.get_updates`.
2. A fetched batch is processed sequentially so offset advancement is
   deterministic.
3. Each update runs through `bot.handle_update_isolated` behind an isolation
   broker. The broker monitors its direct caller, owns a linked handler worker,
   and applies a bounded timeout. Polling waits for that result before starting
   the next update. If the caller dies, including during supervisor teardown,
   the broker cleans up its worker instead of leaving library-owned dispatch
   orphaned.
4. A panic or confirmed timeout becomes `BotRuntimeError`; the configured
   failure policy may skip a confirmed crash or stop polling. Gate/store
   failures and all timeout/outcome uncertainty always fail closed. If a fatal
   failure follows consumed updates in the same batch, a short
   `getUpdates(offset = failed_update_id)` checkpoints only that prefix before
   returning; a failed checkpoint is preserved as typed uncertainty.
5. Inside the worker, `handle_update` wraps the update in a `Context` and calls
   `composer.run`.
6. `composer.run` folds the middleware stack right-to-left into a
   nested closure, then invokes the outermost one.
7. Each middleware either calls `next()` (passing control on) or
   short-circuits.
8. If a handler invokes `api.send_message` (or another method), the call
   passes through every registered transformer before the built-in transport.
9. The built-in transport uses `gleam_httpc` to POST to Telegram, classifies
   the HTTP response, then decodes the Bot API envelope.

Handler isolation is not parallel batch processing. Diagnostic callbacks run
behind an owner-aware guard with a deadline configured by
`bot.with_callback_timeout` (5 seconds by default, constrained to BEAM's
positive receive-timeout range). A timeout kills the callback task and permits
up to one additional second for termination confirmation. A
callback crash or timeout is reported with redacted text and cannot replace the
runner's typed result. The guard also tears down the actual callback task if its
direct caller dies.

`composer.fork` remains a low-level unbounded, detached primitive, and arbitrary
handler descendants are not included in either ownership barrier. Use
`keyed_executor.update_gate` for bounded slow work with FIFO ordering per
chat/key and explicit backpressure.
Update gates short-circuit in registration order: install the specialized
`conversations.update_gate` before a broader keyed-executor gate.
For the executor gate, `Some(key)` transfers the whole update to its queued
operation; the normal composer runs only for `None` or an earlier `Continue`.
Termination cannot undo an external effect that already started.

`bot.start` itself is blocking, not a managed runtime. The application owns
supervision and the invariant of one poller per bot token. There is no
first-class stop handle, readiness signal, or double-start guarantee.

### Custom transport path

`api.PreparedCall(value)` keeps the method, payload, and result decoder
together without storing a bot token. Applications that use another HTTP
client split transport from protocol handling explicitly:

```text
prepare_json_call / prepare_multipart_call
                  │
                  ▼
          to_http_request          (no dispatch)
                  │
                  ▼
      application-owned transport
                  │
                  ▼
        from_http_response          (status + envelope + value decode)
```

Both sides use standard `gleam/http` values: `Request(BitArray)` and
`Response(BitArray)`. The prepared call is opaque, so the response cannot be
decoded without the method-specific decoder that created it. `api.execute`
uses the same prepared-call model with `gleam_httpc` as a convenience.

### Webhook path

1. Caller's HTTP server hands a POST body to `webhook.handle_isolated` (or the
   secret-validating `webhook.handle_isolated_with_secret`).
2. The adapter parses it as an `Update`.
3. Dispatch runs through `bot.handle_update_isolated` behind the same
   caller-monitoring broker and linked library-owned handler worker. A panic or
   hang becomes `WebhookError.HandlerFailed` instead of taking down the HTTP
   process, and caller death cleans up that worker.

`webhook.handle` and `handle_with_secret` remain synchronous for callers that
deliberately manage their own isolation boundary.

## Core types map

| Telegram concept            | glammy type                                               |
| --------------------------- | --------------------------------------------------------- |
| Bot API method call         | `api.PreparedCall(value)`                                 |
| Custom HTTP boundary        | `api.to_http_request` / `api.from_http_response`           |
| Bot API response envelope   | `error.GlammyError` (`ApiError` / transport / status / decode) |
| Update                      | `types.Update { update_id, kind: types.UpdateKind }`      |
| Supported Update sub-shapes | `types.UpdateKind` variants (+ unknown-update fallback)   |
| File reference              | `input_file.InputFile`                                    |
| URL-free file source        | opaque `input_file.FileIdOrUpload`                        |
| Outbound poll text/options  | opaque `types.PollQuestion` / `types.InputPollOption` / `types.InputPollOptions` |
| Complete outbound poll      | opaque `api.SendPoll`                                     |
| Poll explanation/description | opaque `api.PollExplanation` / `api.PollDescription`     |
| Send/reply target state     | opaque `message_options.MessageDelivery`                  |
| Ephemeral media edit        | opaque `input_media.ReuseOnlyInputMedia`                  |
| Delete batch identifiers   | opaque `api.MessageIds`                                    |
| Forward batch identifiers  | opaque ordered `api.ForwardMessageIds`                     |
| Bot commands                | opaque `types.BotCommand` / `types.BotCommands`            |
| Invite-link options         | opaque `api.ChatInviteLinkOptions`                         |
| Required HTTPS URL          | opaque `https_url.HttpsUrl`                                |
| Webhook secret              | `webhook_secret.WebhookSecret`                            |
| Inline answer collection    | `inline_query_results.InlineQueryResults`                 |
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

4. **No global mutable state.** Session storage and the conversation registry
   are `gleam_otp` actors exposed through opaque handles. Calls are monitored
   and bounded; explicit stop operations define their lifecycle.

5. **Transport is an application boundary.** A caller can turn an opaque
   prepared call into a standard request, dispatch it with any client, and
   parse the standard response separately. The convenience `httpc` path still
   supports the existing transformer chain; a transformer that never calls
   `next` returns a synthetic envelope (see `client_test`).

## OTP actor and worker model

`session` and `conversations` use `gleam_otp/actor`; callers receive opaque
handles rather than owning mailbox loops.

The storage actor serializes versioned reads, writes, deletes, and
compare-and-set commits. A session transition runs in the caller after a
versioned read, so slow application code does not block unrelated storage
keys. A conflicting commit retries the pure transition up to a bounded limit.
`SessionUpdate` separates the value from its `after_commit` effect; the effect
runs at most once after this process observes a successful commit. A crash can
omit it, so durable delivery requires an outbox. Globally unique revisions
protect live keys from ABA; deleted keys share an absence epoch so their
per-key revision entries can be discarded. A delete may therefore trigger a
safe retry for an unrelated transition that also read a missing key.

The conversation registry is keyed by `<chat.id>:<from.id>` by default, with a
custom key function available. `start` creates a dedicated worker and uses a
two-phase lifecycle handshake before unlinking and registering it, then the
worker executes the blocking `wait` flow while polling continues. Tokens and
wait generations prevent a stale timeout or replaced conversation from
removing the current waiter. The local `wait` receive and its registry calls
are bounded separately. Ownership remains continuous while the flow computes
between two waits: the registry holds one update until the next wait is
registered, and a second update returns typed `RouteBufferFull` backpressure.
If the flow finishes normally before another wait, the undelivered route is
rejected so ordinary middleware may resume. Route success follows matching
worker dequeue plus a registry-accepted receipt, not mailbox enqueue. Mutation
and route calls distinguish pre-start timeouts from outcome-unknown operations;
unknown, unresolved, and buffer-full routes fail closed. A routing `CallTimeout`
also fails closed because an unresponsive registry cannot prove that the key
has no live owner. Registry death fails closed for the same reason until the
separate registry-plus-workers shutdown barrier completes. Polling uses
`conversations.update_gate` so that uncertainty or backpressure also prevents
Telegram offset advancement. The lifecycle coordinator cancels orphan starts
and exits only after the registry and every tracked worker are down, making it
the shutdown barrier. An optional typed outcome callback observes completion,
stop, typed infrastructure failure, or crash; explicit stop first offers a
short cooperative `Cancelled` path and then kills a hung thunk.

Open and wait-registration calls put a begin marker before their authoritative
deadline check. If the actor is preempted between its preliminary check and the
marker, it cannot mutate on a late resume; if the marker was observed but the
decision was lost, the worker fails closed instead of continuing under an
unknown registration state.

These guarantees are process-local. Session atomicity across multiple
`Storage` handles or BEAM nodes requires backend-native transactions/CAS, and
an unacknowledged custom mutation retires its handle until the backend is
reconciled. Conversation state is lost when its actors or the application
restart.

Decoded updates retain their original raw envelope, bot update gates can fail
closed before middleware, and infrastructure transformers can be prepended.
Those boundaries support a future journaled replay engine without pretending
the current linear conversations are durable.

The keyed executor is also process-local. Its scheduler stores FIFO queues per
key, enforces one active job per key plus a global active limit, and counts both
running and queued jobs against capacity. Monitored wrappers isolate user
operations; a per-job arbiter emits one completion, crash, timeout,
cancellation, or executor-termination outcome. Every active job has a finite
runtime deadline, measured only after its actual `Begin`; queued time is not
charged. Timeout, cancellation, and executor-termination outcomes are held
behind the actual user-process `DOWN` barrier, even when that process traps
exits or the scheduler dies abruptly. A startup worker must register with the
terminal arbiter before it may create the user task, closing the pre-attachment
executor-death window. The terminal outcome is published before the scheduler
releases the key, global slot, and capacity. Admission deadlines
prevent a suspended scheduler from accepting stale work after the caller has
timed out. An unknown admission still requires reconciliation before retry,
and accepted jobs do not survive process or node loss without
application-owned persistence.

## File-by-file responsibilities

- **`glammy.gleam`** — compact facade for the common API client, composer,
  context reply, bot construction, and polling flow.
- **`glammy/types.gleam`** — supported Telegram types and their decoders;
  kept in one module by choice
  (see [design-decisions.md](https://github.com/castletaste/glammy/blob/main/docs/design-decisions.md)).
- **`glammy/error.gleam`** — `GlammyError` sum type + `describe/1`.
- **`glammy/api.gleam`** — opaque `Api` and `PreparedCall(value)`, transport-free
  request construction and response parsing, the backwards-compatible transformer
  chain, built-in `httpc` execution, and typed Bot API wrappers.
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
  builders with `transpose` / `flow` / `append` post-processors, plus
  endpoint-specific game/invoice keyboards whose launch/Pay button is first by
  construction.
- **`glammy/bot.gleam`** — `Bot` opaque type, validated polling options,
  sequential offset handling, owner-aware isolated handler workers, bounded
  diagnostic callbacks, runtime failure policy, `start`, `handle_update`, and
  `handle_update_isolated`.
- **`glammy/webhook.gleam`** — `handle` / `handle_with_secret` /
  `verify_secret`. Framework-agnostic.
- **`glammy/webhook_secret.gleam`** — shared opaque, validated
  `WebhookSecret` used by both `setWebhook` registration and request
  verification.
- **`glammy/https_url.gleam`** — absolute, host-bearing HTTPS URLs without
  embedded credentials for webhook, Mini App, and login-button fields.
- **`glammy/session.gleam`** — OTP-backed `Storage(value)`, versioned CAS,
  typed backend failures, `SessionUpdate`, `update_then`, `with_session`,
  lifecycle operations, and chat/user key functions.
- **`glammy/conversations.gleam`** — OTP registry + monitored workers for
  non-blocking linear flows, default chat-and-user keys, bounded waits, custom
  keys, worker receipt acknowledgements, a polling update gate, cooperative
  cancellation, typed terminal outcomes, and explicit lifecycle operations.
- **`glammy/keyed_executor.gleam`** — bounded active-plus-queued capacity,
  FIFO execution per key, a global concurrency ceiling, typed admission
  ambiguity/backpressure, monitored job outcomes, and bounded shutdown.
- **`glammy/error_boundary.gleam`** — wraps a sub-composer in Erlang
  `try` (via `glammy_ffi.erl`) so panics don't propagate out.
- **`glammy/multipart.gleam`** — hand-rolled multipart/form-data encoder
  (`Part`, `Encoded`, `encode/1`) using `crypto:strong_rand_bytes` for
  the boundary.
- **`glammy/input_file.gleam`** — sans-I/O `InputFile` sum type
  (`FileId`/`FileUrl`/`FileBytes`) +
  opaque URL-free `FileIdOrUpload` with `file_id_source`/`upload_source`
  smart constructors for endpoints such as `sendVideoNote` +
  `from_url`/`from_bytes`/`from_file_id` constructors +
  `infer_filename`/`requires_upload`/`to_payload_value`.
- **`glammy/thumbnail.gleam`** — upload-only thumbnail value that prevents
  file IDs and URLs where Telegram requires a fresh multipart attachment.
- **`glammy/input_media.gleam`** — `InputMedia*` variants +
  `to_json/2` (with caller-supplied attach resolver).
- **`glammy/inline_query_results.gleam`** — opaque `InlineQueryResult`,
  max-50 `InlineQueryResults`, finite video/document source types, and typed
  `InputMessageContent` builders.
- **`glammy/parse_mode.gleam` / `chat_action.gleam` / `reaction.gleam`** —
  finite outbound protocol values; inbound unknown-enum fallbacks stay in
  `types`.
- **`glammy/media_options.gleam` / `message_options.gleam`** — endpoint-specific
  media delivery records plus invariant-safe reply parameters.
- **`glammy/constants.gleam`** — compatibility constants and remaining stable
  Telegram values (sticker types, currencies, scope names).
- **`glammy/escape.gleam`** — HTML / Markdown / MarkdownV2 escapers.
- **`glammy/internal/json_utils.gleam`** — INTERNAL. Shared
  `put_optional` / `opt_str` / `opt_int` / `opt_bool` / `opt_float` /
  `opt_with_default` / `opt_nested` / `opt_list` for the JSON
  build/decode boilerplate. `opt_nested` covers an optional nested
  object field, `opt_list` an optional list field defaulting to `[]`.
- **`glammy/internal/http_response.gleam`** — INTERNAL. Shared HTTP response
  status/content-type classification for JSON API and webhook boundaries.
- **`glammy_ffi.erl`** — audited `try_run/1` boundary used to classify panics
  in error boundaries, polling handlers, session transitions, and callbacks.

## Conventions

- **Naming:** snake_case for fns / types. Variants use PascalCase.
- **Labelled args** are preferred for ambiguous same-typed public parameters
  (for example `api.get_updates`). Remaining legacy wrappers are tracked for
  API cleanup.
- **Opaque types** for everything stateful (`Api`, `Composer`, `Bot`,
  `Storage`, `Registry`). Construction via `new`/`memory_storage`/etc.
- **Result returns** for fallible operations. No exceptions in the
  public API surface.
- **`Option(T)`** for nullable Telegram fields.
- **`@external`** only when truly necessary (`glammy_ffi:try_run`,
  `crypto:hash` / `hash_equals` / `strong_rand_bytes`, and
  `erlang:monotonic_time`).
- **`use` syntax** for decoders and shared helpers
  (`use x <- decode.field(…)`).
- **Tests live in `test/glammy/*_test.gleam`,** mirroring `src/glammy/*.gleam`.
