# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial pre-release implementation: typed API client plus generic `call`,
  composer middleware, filter DSL, sessions, conversations, keyboards, inline
  query results, webhook adapter, transformers, and long-polling runner.
- Opaque `api.PreparedCall(value)` with standard `gleam/http` request building
  and response parsing for application-owned HTTP transports.
- Compact top-level `glammy` facade for the common client, composer, reply, and
  polling flow.
- Isolated webhook dispatch APIs that turn middleware crashes and timeouts into
  typed `WebhookError.HandlerFailed` values.
- Bot API 10.2 outbound model: finite `ParseMode`, `ChatAction`, poll kind and
  reaction values; typed reply markup, reply/link-preview parameters, command
  scopes, permissions, and endpoint-specific media options.
- Upload-only `Thumbnail`, validated opaque poll questions/options and option
  collections, opaque inline-query results, and sum types for
  shipping/pre-checkout answers.
- Endpoint-specific game and invoice keyboards whose required launch/pay
  button is structurally first in the first row; `sendGame` also exposes its
  complete Bot API 10.2 option set through `send_game_with_options`.
- Recoverable `RawObject` payloads on `User`, `Chat`, `Message`, `Poll`,
  `PollOption`, and `PollAnswer`, including typed 10.2 fields.
- Current inbound business rights, member tags/permissions, recurring-payment,
  paid-invite, join-request, and forum-topic fields, with business-aware
  `context.reply` routing.
- Typed Bot API 10.2 guest-query, join-request-query, and ephemeral-message
  flows, including proof-carrying ephemeral targets and `SentGuestMessage`.
- Proof-carrying `MessageDelivery` choices for regular, reply, and ephemeral
  sends; reuse-only media for ephemeral edits; and validated `BotCommand` and
  1–100-element `MessageIds` values.
- Bounded `BotCommands`, invite-link options, plain poll explanations and
  descriptions, plus absolute credential-free `HttpsUrl` values for webhook,
  Mini App, and login-button fields that require TLS.
- Finite outbound dice emoji, structurally valid anonymous/public regular and
  quiz polls, mutually exclusive poll schedules, and bounded country codes.
- A validated `InlineQueryResultsButton` sum type and optional button support
  for `answerInlineQuery`.
- Typed keyboard copy actions, finite button styles, custom-emoji icons, and an
  upload-only certificate path for `setWebhook`.
- Full raw `Update` envelopes, ordered fail-closed bot update gates, and an
  outermost API-transformer hook as honest foundations for a future durable
  replay engine.
- Gate panic/self-termination classification that remains fail-closed under
  both handler policies and omits potentially sensitive exception details.
- Redacted default runtime diagnostics; application panic reasons, stacks, and
  gate details remain available only to an explicit `on_runtime_error` policy.
- Both synchronous and isolated webhook dispatch preserve update-gate failures
  as `WebhookError.HandlerFailed`, allowing the HTTP layer to request retry.
- A bounded keyed executor for slow work: FIFO per key, a global concurrency
  ceiling, active-plus-queued capacity, typed admission/backpressure, monitored
  jobs, a finite configurable active-job deadline, observable terminal
  outcomes, and a fail-closed bot update gate.
- A checked-in Bot API structural snapshot, fail-closed stdlib-only drift
  parser, offline fixture tests, and a scheduled/manual upstream drift job.

### Changed

- Replaced private list, option, and hexadecimal helpers with equivalent
  standard-library operations and direct function composition.
- Conversation middleware now treats every registry error as fail-closed,
  keeping future error variants from leaking updates into ordinary middleware.
- Made finite `parse_mode`, `chat_action`, poll/dice, and `BotCommandScope`
  values the canonical outbound representation. Their raw compatibility
  constants remain available as deprecated aliases throughout 0.1.x.
- Made `keyed_executor.submit` the canonical admission path; the convenience
  `submit_with_key` wrapper remains available as deprecated 0.1.x surface.
- Centralized Erlang exception handling behind a typed internal FFI module,
  preserving polymorphic success values without self-mailbox adapters and
  redacting callback failures before formatting. `BoundaryClass.OtherClass`
  remains only as a deprecated compatibility variant and is never produced.
- DRY/KISS refactor across the public framework surface before Hex publication.
- Bot tokens are redacted from generic inspection of `api.Api`; the explicit
  `to_http_request` boundary still places the token in Telegram's required URL.
- `composer.fork` workers are unlinked so fire-and-forget failures cannot take
  down the update dispatcher.
- File uploads are sans-I/O: callers provide `FileBytes`; local paths are no
  longer represented or read inside the package.
- Sessions and conversations now use bounded OTP actors, typed lifecycle
  failures, session CAS commits, post-commit effects, and acknowledged
  non-blocking conversation workers.
- Actor mutation and route timeouts distinguish guaranteed-not-started from
  outcome-unknown operations. Unknown routes fail closed, unknown CAS commits
  never trigger `after_commit`, stop operations wait for process death, and a
  two-phase registry-lifecycle coordinator prevents orphan conversation
  workers and provides a registry-plus-workers shutdown barrier.
- Conversations support `start_with_outcome` for typed completed, stopped,
  infrastructure-failed, and crashed observation. Explicit stop first delivers
  cooperative `Cancelled` to a waiting flow, then uses a bounded hard-stop
  fallback for hung thunks.
- Long polling checkpoints an already-consumed batch prefix before returning a
  fatal mid-batch failure. Checkpoint uncertainty preserves both the update
  failure and the API failure without ever confirming the failed update.
  Credential verification and the optional initial pending-update drain now
  share steady-state polling's transient-error retry and backoff policy.
- Diagnostic callbacks now use `bot.with_callback_timeout` for a configurable
  bounded, BEAM-range-validated timeout (5 seconds by default) and owner-aware
  cleanup. Their crashes and timeouts stay redacted, never replace the runner's
  typed result, and cannot orphan the library-owned callback task; handler
  brokers likewise clean up linked workers on caller death.
- Every public millisecond timeout that reaches a BEAM receive or timer now
  rejects values above `4_294_967_295` before starting a process or request.
- Release CI exports the Hex package twice and proves equivalent members,
  file bytes, headers, and parsed metadata, allowing only Gleam 1.17.0's source
  mtime preservation and nondeterministic dependency-requirement ordering.
- Conversation routing is acknowledged only after the matching worker dequeues
  the delivery and the registry accepts its receipt. Polling integrations can
  install `conversations.update_gate` so an unknown receipt never advances the
  Telegram offset. Ownership remains continuous between waits with one buffered
  update; overflow, registry timeout/death, and unresolved routes reject
  concurrent work fail-closed rather than leaking it into ordinary middleware.
  Open and wait-registration deadline markers prevent a known-not-started
  timeout from replacing an owner or registering a waiter after the caller
  has already continued.
- `MessageEntity` decodes Bot API 10.2 `date_time` metadata and the filter DSL
  accepts `message:entities:date_time` and `::date_time`.

### Deprecated

- Twenty-nine `glammy/constants` aliases for parse modes, chat actions, poll
  kinds, dice emoji, and command scopes. Use their finite typed counterparts.
- Eight `glammy/api.default_send_*_options` forwarding helpers. Import the
  matching default from `glammy/media_options`.
- `keyed_executor.submit_with_key`. Derive the key explicitly and call
  `keyed_executor.submit`, or use `keyed_executor.update_gate`.
- `error_boundary.BoundaryClass.OtherClass`. The typed runtime boundary can
  produce only `ErrorClass`, `ExitClass`, or `ThrowClass`.

These compatibility symbols remain available throughout 0.1.x and are
scheduled for removal in 0.2.0.

### Known limitations

- `bot.start` is blocking and application-supervised; it has no stop/readiness
  API or one-poller-per-token guard. Ownership cleanup excludes detached
  `composer.fork` tasks and arbitrary descendants, and cannot roll back
  already-started external effects.
- The package targets the Bot API 10.2 schema but intentionally exposes a
  curated typed surface, not full method parity. Unsupported outbound methods,
  uploads, and option fields remain reachable through the JSON/multipart
  prepared-call family. Selected unmodelled inbound fields are recoverable from
  documented `RawObject` values; other nested schema gaps still require a
  decoder update. See `docs/roadmap.md` for maintained gap categories and the
  pinned upstream baseline.
