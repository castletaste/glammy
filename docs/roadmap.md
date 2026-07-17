# Roadmap

This document records known gaps in glammy and the future-work ideas
that surfaced during development. Items here are NOT commitments —
they're material for the next maintainer to evaluate.

## Upstream baseline

This audit is pinned to Telegram Bot API **10.2 (14 July 2026)**. The version is
a maintenance baseline, not a claim that every method and nested field is
modelled. glammy deliberately exposes a curated typed surface; intentional and
known gaps belong in this document and in release notes.

## Known gaps (could be filled but were skipped)

### G-1. Bot API methods beyond the typed surface

glammy exposes a curated set of typed wrappers (sendMessage, sendPhoto,
banChatMember, …). Other Telegram methods are reachable via
`api.call(api, "methodName", fields, decoder)` — the generic escape hatch —
but they don't get the same ergonomic helpers.

**Representative typed-wrapper gaps:** the Rich Message family;
`editMessageMedia` and `copyMessages`; most sticker-set lifecycle
methods such as `getStickerSet`, `createNewStickerSet`, and
`setStickerSetThumbnail`; paid-media, Stars, gift, and business-account
management families; and several profile/verification helpers. This is a
maintained description of the gap categories, not an exhaustive method
inventory. Recheck the pinned Bot API schema before implementing one of them.

**Why skipped:** Diminishing returns. Adding many more typed wrappers
mostly duplicates the pattern. Users who need them either:
1. Call `api.call/4` directly with a custom decoder, or
2. Send a PR with a typed wrapper

### G-2. Telegram Passport types

The Telegram Passport system (`PassportData`, `EncryptedCredentials`,
`PassportFile`, …) is not modelled. grammY ports all of it in
`@grammyjs/types/passport.ts` (~230 lines).

**Why skipped:** Passport is rarely used in modern bots and would add
a non-trivial number of types/decoders. Users who need it can:
1. Use `api.call/4` with their own decoder, or
2. Send a PR adding `glammy/types/passport.gleam`

### G-3. Stories API

Telegram's bot-story features (`storyArea`, `inputStoryContent`,
`postStory`, `editStory`, `deleteStory`) aren't modelled. Same
rationale as G-2.

### G-4. Checklist (recent Telegram feature)

`Checklist`, `ChecklistTask`, `ChecklistTasksDone`, `ChecklistTasksAdded`
message kinds aren't decoded. Unknown top-level update kinds are preserved as
`OtherUpdate(RawUpdate)`, and currently modelled open discriminators have
`Unknown*` fallbacks with fixtures. The complete raw objects for `User`, `Chat`,
`Message`, `Poll`, `PollOption`, and `PollAnswer` are recoverable through
`RawObject`; other known nested records can still lose omitted fields.

### G-5. Sticker-keyboard coverage

`InlineQueryResultsButton` is now a validated sum type and is supported by
`answer_inline_query_with_options`. Sticker-specific keyboard and sticker-set
lifecycle ergonomics remain intentionally curated rather than exhaustive.

### G-6. Business account schema beyond the connection envelope

`BusinessConnection` and its current `BusinessBotRights` are decoded, but the
larger business-account method and object graph is not modelled. The missing
typed wrappers are listed in G-1. `ChatBoostSource`, by contrast, currently
covers all three documented 10.2 variants: Premium, GiftCode, and Giveaway.

### G-7. Intentional Bot API 10.2 schema and rich-media gaps

`LinkPreviewOptions` is now typed in both directions. Still intentionally
unmodelled are the Rich Messages / `InputRichMessage*` graph, Community types
and message service fields, parsed/entity poll text and poll media,
`InputMediaLivePhoto`, video cover/start timestamps, rich suggested-post
parameters, and several newer media/entity subgraphs. Guest identifiers,
ephemeral delivery fields, and join-request query responses are now
first-class. For outbound gaps, applications can use
`api.prepare_json_call` or upload-capable `api.prepare_multipart_call` with an
application-owned response decoder; raw JSON is not accepted by the high-level
wrappers.

### G-8. Nested schema parity

Raw fallback protects unknown top-level updates and open enum discriminators.
It also preserves the complete object for the six central records listed in
G-4. Other known records still ignore unmodelled fields, so every Bot API
baseline bump must audit them and add fixtures for newly supported fields.

### G-9. Minimal location, venue, contact, and dice wrappers

The typed wrappers for `sendLocation`, `sendVenue`, `sendContact`, and
`sendDice` cover their core values but not the complete 10.2 option sets.
`sendDice` now accepts only Telegram's finite outbound emoji set.
Notably, location/venue/contact do not yet expose ephemeral
`receiver_user_id` / `callback_query_id`, and the four wrappers omit several
delivery, reply, and endpoint-specific options. Use the JSON or multipart
prepared-call constructor when those fields are required. Full endpoint-specific
option records belong in a future minor release rather than silently accepting
raw JSON in these helpers.

### G-10. Long-polling lifecycle surface

`bot.start` remains a blocking call. Applications must supervise it and ensure
that only one poller uses a bot token; glammy has no first-class stop handle,
readiness signal, or double-start guard. Owner-aware diagnostic guards and
handler brokers clean up their immediate library-owned tasks when the direct
caller dies, but they are not a managed runtime: detached `composer.fork`
tasks, arbitrary descendants, and already-started external effects are outside
their barriers. Any proposed lifecycle API would need to define those boundaries
explicitly rather than imply rollback or descendant ownership.

## Closed foundations

These are current capabilities, not future work:

- Unknown top-level update kinds survive as opaque `RawUpdate` values;
  `ChatType`, `StickerType`, `ReactionType`, `ChatMember`, and
  `ChatBoostSource` retain unknown discriminators.
- `PreparedCall(value)`, `to_http_request`, and `from_http_response` provide a
  sans-I/O protocol boundary while `api.execute` remains the HTTP convenience.
- Outbound high-level calls use finite parse/action/poll/reaction types, typed
  reply markup, validated plain poll text/collections/quiz-only explanation,
  bounded descriptions, command collections, invite-link options, HTTPS-only
  URL values, and endpoint-specific media options. Generic prepared calls are
  the explicit escape hatch.
- Long polling classifies transient/permanent failures and isolates every
  handler behind a monitor and timeout with an explicit failure policy. Fatal
  mid-batch failures checkpoint only the already-consumed update prefix.
  Credential verification and the optional initial drain use the same
  transient retry/backoff policy as steady-state polling. A caller-monitoring
  broker owns each linked handler worker, while `bot.with_callback_timeout`
  configures diagnostic callbacks' bounded deadline (5 seconds by default),
  redacted failures, and owner-aware task cleanup. Callback failure cannot
  replace the runner's typed result, and caller death cannot orphan those
  immediate library-owned tasks.
- Slow assistant/LLM work has an opt-in bounded keyed executor with FIFO
  per-chat ordering, global concurrency, active-plus-queued capacity, typed
  backpressure, monitored outcomes, and a fail-closed polling gate.
- Sessions and conversations use bounded `gleam_otp` actors with typed
  lifecycle errors. Sessions commit with optimistic CAS and at-most-once
  post-commit effects after an observed commit; conversations use
  receipt-acknowledged, non-blocking workers tracked by a two-phase lifecycle
  coordinator and registry-plus-workers shutdown barrier.
- Mutation and routing calls distinguish a guaranteed pre-start timeout from
  an outcome-unknown timeout. Unknown mutations are not blindly retried and an
  unknown conversation route suppresses downstream and fails the polling gate;
  callers must reconcile before retrying because a late receipt may execute.
- Conversation completion, explicit/replacement stop, typed infrastructure
  failure, and worker crashes have outcome callbacks; explicit stop cooperates
  with an active wait before falling back to a bounded kill for a hung thunk.
- Decoded `Update` values preserve the full raw envelope. Ordered bot update
  gates can report consumed after application-owned persistence, pass, or fail,
  and infrastructure can prepend an outermost API transformer. Synchronous and
  isolated webhook paths preserve gate failures for retriable HTTP responses.
  These are replay foundations, not a claim that persistent conversations
  already exist.
- Guest replies, join-request-query decisions, all Bot API 10.2 ephemeral
  edit/delete operations (including reuse-only media), finite dice emoji,
  validated poll schedules/country codes, and inline-query result buttons have
  typed high-level paths.
- The stdlib-only `scripts/telegram_bot_api_schema.py` parser compares the
  checked-in Bot API 10.2 structural snapshot with Telegram's official page. A
  fixture-only suite runs in normal CI, while a separate scheduled/manual
  workflow reports upstream structural drift without putting a network
  dependency in PRs. This detects upstream changes; it does not prove full
  glammy API parity.

## Future-work ideas

### F-1. Conversations: persistent / replayable

The current `glammy/conversations.gleam` uses an OTP registry plus one worker
per active flow, but all state remains in memory. The prerequisites now in the
core are full raw update envelopes, fail-closed update gates, and an outermost
API transformer. A persistent version would still need to:

1. Persist a versioned journal before delivering waits or external effects
2. Replay recorded outcomes while checking step fingerprints for divergence
3. Quarantine an `EffectStarted` without `EffectFinished` as ambiguous
4. Use backend-native compare-and-swap across processes/nodes

This is the approach of `@grammyjs/conversations`. It is a separate persistence
model, not a safe extension of the current in-memory worker.

Suggested design: a separate `glammy/durable_conversations.gleam` with a
bytes-oriented store and backend-native CAS. Do not reuse `session.Storage`:
its atomicity belongs to one actor handle and cannot coordinate nodes.

### F-2. WebApp data validation

Telegram's WebApp `initData` payloads carry a HMAC signature signed
with the bot token. A `glammy/webapp.gleam` module that:

1. Parses `initData` querystring → typed record
2. Validates the HMAC against a bot token
3. Returns `Result(WebAppInitData, ValidationError)`

… would be ~150 lines, useful for bot authors building Web Apps.

### F-3. Rate limiting transformer

A built-in transformer that throttles outgoing API calls per chat/global,
backing off on 429 responses. Would integrate cleanly with the existing
transformer chain.

### F-4. Auto-retry transformer

Similar to F-3 but for transient errors (network blips, 5xx). Could
be a separate transformer or share infrastructure.

### F-5. ETS-backed session storage

A drop-in `session.ets_storage()` that uses Erlang's ETS instead of the
current OTP storage actor. This may be faster for high-traffic bots, but needs
benchmarks and must retain the same typed timeout/lifecycle contract.

```gleam
let storage: session.Storage(MyState) = session.ets_storage("my_table")
```

Would need ~20 LOC of Erlang FFI for ETS primitives.

### F-6. Type-safe filter narrowing

Right now `filter.matches(filter.Message, ctx)` returns `Bool`. After
narrowing, the user still has `Option(Message)` and needs to
pattern-match. Could we expose:

```gleam
pub fn unwrap_message(ctx: Context) -> Result(Message, Nil)
```

… or per-Filter unwrappers? Worth evaluating ergonomics vs adding API
surface.

### F-7. Wisp / Mist integration adapters as a SEPARATE package

We deliberately don't depend on `wisp` or `mist` (D-1). But a separate
optional companion package `glammy_wisp` providing `glammy_wisp.adapter(bot)`
would make webhook integration one-line for the common case.

This would be a separate `gleam.toml` project that depends on glammy +
wisp.

### F-8. Better introspection helpers

A `glammy/debug.gleam` module with:

- `debug.update_summary(update) -> String` — one-line summary
- `debug.dump_composer(composer) -> String` — middleware count, sizes
- `debug.trace(composer) -> Composer` — wraps every mw with logging

… would help users debug their pipelines.

## Maintenance reminders

- **Telegram Bot API releases:** run
  `python3 scripts/telegram_bot_api_schema.py check` for every upstream release
  and before every glammy release. Update the pinned baseline only after review,
  and record intentional gaps in release notes.
- **gleam-lang package versions** in `gleam.toml` use bounded major-version
  ranges. Periodically review lower bounds and the resolved manifest.
- **Compiler/runtime compatibility:** the package constraint accepts Gleam
  `>= 1.16.0`. CI resolves the dependency floors on Gleam 1.16.0 / OTP 27 and
  verifies locked builds on Gleam 1.17.0 / OTP 28 and OTP 29. Other pairings,
  including OTP 24–26, are not currently verified and must not be advertised
  as supported without a green matrix lane.

## Out of scope (will not be added)

- **Multi-bot orchestration** — running N bots from one process is
  achievable by spawning N supervised processes; doesn't need a
  glammy-level abstraction.
- **Webhook-reply optimisation** — grammY supports sending the bot's
  HTTP response back through the same webhook POST connection.
  Saves an HTTP round-trip but couples the response to the framework.
  Out of scope given D-1's framework-agnostic stance.
