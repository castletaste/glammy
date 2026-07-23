# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Simplified internal filtering, keyboard, multipart, JSON, and exception
  handling by using existing Gleam standard-library operations and one typed
  Erlang FFI boundary; the exported package interface is unchanged.
- Conversation middleware now fails closed for every registry error while a
  confirmed missing owner continues downstream as before.

## [0.1.0] - 2026-07-17

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

### Breaking

- `ChatMemberAdministrator.can_post_stories`, `can_edit_stories`, and
  `can_delete_stories` are required `Bool` fields, matching Bot API 10.2;
  administrator payloads missing any of them now fail decoding.
- The misnamed `inline_query_results.sticker` builder, which represented no Bot
  API type and duplicated `cached_sticker`, was removed.
  `cached_sticker` is now the single Bot API-aligned builder and accepts the
  official optional `input_message_content` field.
- `composer.chat_type` now takes `types.ChatType` instead of `String`.
- `api.with_timeout` validates positive BEAM-safe values and returns
  `Result(Api, ApiConfigError)`, including `TimeoutTooLarge` above the finite
  timer ceiling.
- Webhook/update JSON parsing returns typed `JsonParseError`; HTTP status and
  transport failures retain their typed error variants.
- Raw `String`/`json.Json` parameters in typed send, poll, command, keyboard,
  reaction, inline, shipping, and media APIs were replaced by finite types,
  records, opaque validated values, or explicit sum types. Use the
  `prepare_json_call` / `prepare_multipart_call` family for intentional
  low-level extensions.
- Poll sending now requires a plain, non-blank, at-most-300-codepoint
  `types.PollQuestion` and one opaque `SendPoll` built with
  `regular_poll(options)` or
  `quiz_poll(options, first_id, other_ids, explanation)`. Plain poll options
  are validated to be non-blank and contain at most 100 codepoints; quiz
  identifiers are non-negative, increasing, and bounded by those exact 1–12
  options. Quiz-only explanation and general description limits are carried by
  opaque values. Parsed/entity poll text uses the prepared-call escape hatch.
  Reactions accept only clear or one typed reaction.
- `set_my_commands` accepts an at-most-100 `types.BotCommands` collection;
  invite-link create/edit accept only validated `ChatInviteLinkOptions`; and
  webhook/Mini App/login-button HTTPS fields accept `https_url.HttpsUrl`.
- `forward_messages` accepts only a strictly increasing
  `api.ForwardMessageIds`; unordered positive batches remain valid for
  `delete_messages` through `api.MessageIds`.
- `answer_inline_query` accepts an at-most-50 opaque result collection, inline
  video/document MIME states are finite, and `send_video_note` accepts only a
  URL-free opaque `FileIdOrUpload` built by `input_file.file_id_source` or
  `input_file.upload_source`.
- Game and Pay buttons no longer exist in the general `InlineKeyboard` type.
  Use `game_inline_keyboard*` only with `send_game_with_options` or
  `inline_query_results.game`, and `invoice_inline_keyboard*` only in
  `SendInvoiceOptions.reply_markup`.
- Webhook registration and verification share one validated, inspection-safe
  `WebhookSecret` value.
- `keyed_executor.Options` now requires `job_timeout_ms`, and accepted jobs can
  finish with `JobOutcome.TimedOut`. The default deadline is five minutes.
- Abrupt keyed-executor death now waits through the pre-task attachment window
  and confirms the real user-operation process is down before publishing
  `ExecutorTerminated`.
- Keyboard button unions gained copy/decorator variants. Exhaustive downstream
  matches must handle them; use the decorator helpers to preserve one action.
- `InputFile` no longer has a local-path variant, and media thumbnails accept
  only the upload-backed `Thumbnail` type.
- `Message.pinned_message` and `CallbackQuery.message` now use
  `MaybeInaccessibleMessage`. Match `AccessibleMessage(message)` before reading
  message content, or `InaccessibleMessage(chat:, message_id:)` for the minimal
  deleted-message shape. Context chat/id aggregators support both variants.
- `CallbackQuery.data` and `game_short_name` were replaced by the required
  `payload: CallbackPayload`; match `Data(value)` or `Game(short_name)` instead
  of handling two independent optional fields.
- `Update` now carries `raw: Option(RawObject)`; use `types.new_update` for
  application-owned updates without an original Telegram envelope.

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
