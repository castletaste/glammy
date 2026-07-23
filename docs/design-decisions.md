# Design decisions

This document records the **why** behind the non-obvious choices in
glammy. Every decision listed here was reached by working through an
alternative and rejecting it for a specific reason.

## D-1. Runtime dependencies are vetted gleam-lang packages

**Decision:** Every runtime Hex dependency is published from a project in the
official `gleam-lang` GitHub organisation. The test runner `gleeunit` is a
dev-only dependency maintained at `lpil/gleeunit`; it is not part of the
published package's runtime dependency graph.

**Why:** Bot tokens are sensitive credentials — a malicious transitive
dependency in a Telegram bot framework could exfiltrate every token its
users embed. The constraint is on the **library**: applications can
add their own.

**Trade-offs accepted:**
- Hand-rolled multipart encoder (see D-3) instead of pulling
  `wisp_form`/`gleam_multipart_form`.
- No built-in HTTP server (no `wisp`/`mist` dependency). Users wire
  webhook handling into whichever framework they already use.

## D-2. `Context` is concrete, not generic

**Decision:** `glammy/context.Context` is a fixed record shape with
two fields (`update`, `api`). It is NOT parameterised by a per-app
extension type the way `grammY`'s `Context<T>` is.

**Why:** Gleam's row polymorphism / extensible records aren't
expressive enough to replicate grammY's `Context & SessionFlavor<T> &
ConversationFlavor & ...` intersection pattern without forcing every
plugin author to thread the extension type through their composer.
Concrete `Context` keeps composer / api / filter call sites simple.

**Trade-off:** Plugins can't attach typed extra state to ctx. They
work around this by:
- `session.with_session(...)` — handler receives ctx + value as
  separate args
- `conversations.start(...)` — handler captures a `wait` closure
- Explicit actor-backed handles or application-owned side channels

## D-3. Multipart encoder is hand-rolled

**Decision:** `glammy/multipart.gleam` implements RFC 7578
`multipart/form-data` encoding in a compact, audited module.

**Why:** D-1 (no extra runtime dependency). The encoder needs:
- Random boundary token per call
- `--<boundary>\r\n…parts…\r\n--<boundary>--\r\n` envelope
- Per-part `content-disposition: form-data; name="…"` (+ optional
  `filename` + `content-type`)

All of which is straightforward and the API surface is tiny (two
constructors, one encode function).

**Boundary generation:** `crypto:strong_rand_bytes(16)` →
hex-encode. Boundaries don't need cryptographic randomness for
correctness (collisions only produce malformed uploads, never security
issues), but using a strong source is simpler than reasoning about
uniqueness elsewhere.

## D-4. `InputFile` does no disk or network I/O

**Decision:** `input_file.InputFile` contains everything the API layer needs
to reference or upload a file:
- `FileId(id)` — Telegram file_id (no upload, no I/O)
- `FileUrl(url)` — let Telegram fetch the URL (no I/O on our side)
- `FileBytes(bytes, filename, mime_type)` — pre-loaded bytes

Local paths are deliberately not represented. The caller reads the file at the
application boundary and constructs `FileBytes`.

**Why:**
- Library purity: keep `InputFile` deterministic in tests.
- Failure modes: file-system errors should propagate at the caller's
  boundary, not buried inside the API client.
- Symmetry with `FileUrl`: we don't fetch URLs either.

**Trade-off:** Less ergonomic than grammY's `new InputFile("/tmp/x")`, which
auto-reads. In return, an accepted `InputFile` can never reach a hidden
filesystem operation or a library panic.

## D-5. `session.with_session` is a pure-function API

**Decision:** Session handlers have signature
`fn(Context, value) -> SessionUpdate(value)`. The update separates a pure next
value from an optional one-shot effect.

**Rejected alternative 1:** "Mutable" feel via Erlang process
dictionary — `session.read(ctx)` / `session.write(ctx, v)` — the
middleware stashes values in `erlang:put/2` and reads on demand. Was
implemented and then **removed** during the idiomatic refactor because:

1. Process-dict state isn't visible across spawned processes (silent
   bugs)
2. Requires `unsafe_cast(Dynamic)` for type-erasure
3. Hides state flow — the function signature lies about its inputs
4. Not idiomatic Gleam (mutable side-channel)

**Rejected alternative 2:** Make `Context` generic in session type
(`Context(s)`). Forces composer / api / filter to be generic too.
Caused major API churn and didn't compose well with multiple plugins.

**Chosen:** Pure transition plus post-commit effect. State flow is visible and
type-safe end to end. A versioned read and compare-and-set commit make updates
atomic within one `Storage` handle; the transition runs outside the actor and
may be retried after a conflict. `session.update_then` delays replies and other
effects until the commit succeeds, then runs the effect at most once after the
caller observes that commit. A crash in between can omit the effect; durable
delivery requires a transactional outbox. `run` returns `Result`, and
`with_session` requires an `on_error` handler instead of hiding backend,
timeout, conflict, or lifecycle failures.

## D-6. `composer` is immutable (every method returns a new value)

**Decision:** `composer.use_middleware(c, mw)` returns a new
`Composer`. The original is unchanged.

**Why:** Standard Gleam idiom (no mutable record updates). Lets users
keep references to "partially-built" composers and continue
from any point. Also makes testing easier — no setUp/tearDown.

**Trade-off:** The grammY pattern
`composer.on(":text").on("message").use(mw)` mutates `composer`. In
glammy you must reassign:

```gleam
let comp =
  composer.new()
  |> composer.on_query(text_query, handler1)
  |> composer.on_query(message_query, handler2)
```

For the composed-filter pattern, expose explicit helpers or use
`composer.append`.

## D-7. Filter has two layers (typed enum + string DSL)

**Decision:** `glammy/filter` exposes:

1. **`Filter` enum** — `Message`/`EditedMessage`/`CallbackQuery`/…
2. **`Query` from strings** — `parse_many(["::url", "message:text"])`

**Why:** Different ergonomics for different cases.
- Typed enum: exhaustive, compiler-checked, no string typos
- String DSL: a validated subset of grammY's filter strings, terser for the
  supported entity, default, and shortcut filters. Unsupported shapes return
  explicit parse errors instead of pretending to match.

Both are first-class — neither wraps the other.

## D-8. Update kind decoding uses a flat candidate list

**Decision:** `update_kind_decoder` collects the supported Update
sub-variants into a list of `Option(UpdateKind)`, filters the present known
variants, and accepts exactly zero or one. Zero becomes
`OtherUpdate(raw_update)`; multiple recognised variants are rejected.

**Rejected alternative:** 30-deep nested `case` (which was the
original, and is genuinely awful to read).

**Why the alternative was wrong:** Maintenance hazard. Adding a new
Update variant required threading it through the nesting. The
flat-list version is read top-to-bottom in canonical order. Unknown sibling
fields do not invalidate a recognised update, so additive Telegram fields are
forward-compatible.
Constructors are applied at the decode site via the private
`opt_update` helper, so the candidates list only preserves ordering.

## D-9. Unknown discriminators are retained, not rejected

**Decision:** Open Telegram unions carry explicit `Unknown*` variants.
Where the surrounding payload matters, the variant also retains an opaque
`Dynamic` value that callers can decode with an application-owned decoder.

**Why:** Telegram can add enum variants before glammy ships an update. A strict
decoder would reject the whole polling batch and retry the same offset forever.

## D-10. `bot.start` returns typed failures and bounds diagnostic callbacks

**Decision:** `bot.start` returns `Result(Nil, BotError)` instead of panicking.
Credential verification, the optional pending-update drain, and steady-state
polling share one transient-error classification and exponential backoff.
Permanent API/decode failures become `ApiFailure`; invalid options and
configured handler-stop failures have their own variants.
The runner waits synchronously for configured diagnostic callbacks, but
`bot.with_callback_timeout` gives that work a configurable deadline from 1
through BEAM's maximum receive timeout of 4,294,967,295 milliseconds and
defaults to 5 seconds. Handler deadlines use the same validated range. An
owner-aware guard monitors the direct caller and owns the actual callback task;
it kills that task on timeout or caller death.
After the callback deadline, termination confirmation has its own bounded
1-second wait. Panic/throw/exit exceptions, self-termination, and timeout are
contained and reported without exception values or stacks. Callback failure
therefore cannot replace the runner's typed result or accidentally print
application secrets.

**Why:** Library-owned failures do not panic — library principle. Callers
that *want* to crash on bad credentials can `let assert Ok(_) =
bot.start(...)`. Callers that want to recover (e.g. notify on Slack,
retry) get a clean Result.

**Related:** `verify_token: Bool` in `PollingOptions` lets users skip
the initial check entirely if they want bot startup to be cheap. This callback
guard is narrow task cleanup, not a stop/readiness lifecycle for `bot.start`.

## D-11. Webhook secret comparison uses `crypto:hash_equals`

**Decision:** `webhook.verify_secret` calls Erlang's
`crypto:hash_equals/2` on fixed-size SHA-256 digests, instead of comparing the
variable-length secrets directly. Values outside Telegram's 1–256-character
ASCII token grammar (`[A-Za-z0-9_-]`) are rejected before comparison.

**Why:** `crypto:hash_equals/2` is documented constant-time. Hand-rolled
loops are easy to get wrong (short-circuit operators, branch
prediction). Hashing produces the fixed-size inputs that `hash_equals/2`
requires without directly comparing the secret values.

## D-12. `error_boundary` uses Erlang FFI for try/catch

**Decision:** `glammy/internal/ffi.gleam` exposes one typed exception boundary
backed by `glammy_ffi.erl`. `try_run` preserves a thunk's polymorphic success
value and maps Erlang's closed `error | exit | throw` classes into a Gleam sum
type. `try_run_redacted` catches callback failures without rendering potentially
sensitive reasons or stacktraces. Gleam itself has no try/catch.

**Why:** Without FFI, we can't catch:
- `panic as "..."`
- `let assert` failures
- Erlang `error:badarith`, `throw`, `exit`

… all of which can happen inside user-supplied middleware. `error_boundary`
catches failures at a chosen point so the application can recover locally.
Uncaught long-polling handler failures are additionally contained by the outer
per-update isolation worker. Webhooks have recommended isolated helpers with
typed timeout/failure results; the synchronous helpers are an explicit opt-in
for hosts that deliberately own the process boundary.

**Surface area:** two small Erlang functions plus one closed class mapper.
Audited and covered by direct FFI tests.

## D-13. Conversations use chat:user keys and non-blocking workers

**Decision:** The default registry key is `<chat.id>:<from.id>`; applications
can supply a custom key function. `conversations.start` creates a dedicated
worker, registers it with the OTP registry, waits for acknowledgement, and
then returns. The worker runs the blocking linear flow while the polling
handler is free to finish. A new conversation with the same key cancels the
old registration.

Conversation tokens and per-wait generations prevent stale timeouts and
replaced workers from deleting or consuming a newer waiter. Local wait receives
and registry calls are bounded separately. A two-phase lifecycle coordinator
cancels orphan starts and becomes a registry-plus-workers shutdown barrier.
Route timeouts distinguish known-not-started from outcome-unknown, but neither
proves that the key lacks a live owner; both fail closed instead of invoking
downstream middleware. A successful route is
acknowledged only after the matching worker dequeues `Deliver` and the registry
accepts its receipt; enqueue alone is not success. While that ownership is
unresolved, retries are also outcome-unknown. The worker owns its key
continuously while computing between waits. The registry may hold one update
until the next wait is registered; a second update returns `RouteBufferFull`
and remains fail-closed. If the flow completes normally without another wait,
the never-delivered buffered route is rejected so downstream middleware may
resume. Long-polling applications install `conversations.update_gate` so the
bot retains an uncertain or backpressured update instead of advancing its
Telegram offset. `start_with_outcome`
reports completed, stopped, typed infrastructure-failed, or crashed workers
from an unlinked observer. Explicit stop first wakes an active wait with
`Cancelled`, then hard-stops a thunk that does not cooperate within the bounded
grace period. The state remains in-memory: an application restart loses
in-flight conversations. `RouteOutcomeUnknown` can also mean that a late
receipt was accepted after the caller lost its acknowledgement; it is a stop-
and-reconcile result, not permission to retry effects blindly.

`CallTimeout` and `Stopped` also suppress downstream routing: registry silence
or death cannot prove that a previously registered worker has completed its
shutdown barrier. Applications must remove a stopped registry middleware only
after coordinating the surrounding bot lifecycle.

Open and wait-registration mutations use a begin marker followed by an
authoritative deadline check. A pre-marker timeout is therefore guaranteed not
to replace an owner or register a waiter later; a lost post-marker decision is
typed outcome uncertainty and fail-stops the affected worker.

**Why:** grammY's `@grammyjs/conversations` is persistent and
replayable (it logs every API call, deterministically replays on
restart). Implementing that correctly requires:
- A virtual time / replay engine
- Persisted call logs
- Deterministic capture of all side-effects
- Plus extensive testing

That's a separate persistence model. glammy ships bounded, actor-backed linear
flows for one application lifetime. Users who need deterministic replay bring
their own persistent layer or a separate package.

## D-14. `types.gleam` is one large file

**Decision:** Telegram types + decoders live in a single module,
not split into `types/user.gleam`, `types/chat.gleam`, etc.

**Why:** The split was considered (see commit history). The cost of
splitting is high:
- Every other module imports many types
- Splitting forces N import statements per module
- Cross-references (Message contains User, Chat, Sticker, …)
  produce circular concerns if done naively

The benefit was mostly aesthetic. The single file is well-sectioned
with clear `// ====` dividers. Compilation is fast (gleam handles it
in ~0.3s).

We will revisit if it grows past ~4000 lines or if a clear non-circular
split emerges (e.g. all "L1" update types stay together).

## D-15. Storage uses a `gleam_otp` actor, not ad-hoc mailbox loops

**Decision:** every `Storage` is fronted by a `gleam_otp` actor. Calls have a
bounded timeout and monitor the actor; reads, writes, deletes, and versioned
commits return `Result(_, StorageError)`. The handle also exposes an explicit
`storage_stop` lifecycle operation.

**Why:** a raw `send` + `receive_forever` pair can hang forever after its owner
dies and makes a read/modify/write session update racy. The OTP actor gives one
serialization point, observable failure, and intentional lifetime management.
`storage_update` performs a versioned read, runs the pure transition in the
caller, and retries compare-and-set conflicts up to a bounded limit. A
transition may therefore execute more than once; `SessionUpdate.after_commit`
executes at most once after an observed successful commit. A crash can omit
it. Mutating calls report whether a timeout happened before start or after the
outcome became unknown, so callers never infer rollback from a timeout. A
custom mutation callback's `Error` or panic after invocation is equally unable
to prove rollback: the actor returns `MutationOutcomeUnknown` and retires
itself. Reads retain their definite `BackendError` / `BackendFailed` values.

**Trade-offs:** the local version belongs to one `Storage` handle. Multiple
handles or BEAM nodes sharing Redis/Postgres still need a backend-native
transaction or compare-and-swap primitive. Backend callbacks are serialized
within their handle, but user transitions do not block the actor. Present keys
carry globally unique revisions; deletion removes their per-key metadata and
advances one shared absence epoch. This prevents set/delete/recreate ABA while
bounding revision metadata by live keys. The trade-off is a safe false conflict:
a delete can make an unrelated missing-key transition retry.

## D-16. The composer middleware signature is `(Context, Next) -> Nil`

**Decision:** Middleware is `fn(Context, fn() -> Nil) -> Nil`.

**Considered alternatives:**

| Signature                                | Why rejected                                       |
| ---------------------------------------- | -------------------------------------------------- |
| `fn(Context) -> Decision`                | Can't reason about post-`next` behaviour           |
| `fn(Context) -> Result(Nil, Error)`      | Forces every mw to acknowledge a never-error path  |
| `fn(Context, fn() -> Result(_,_)) -> _`  | Result threading without a real error contract     |

The chosen signature matches `wisp`'s middleware (Gleam HTTP framework)
and `koa`/`express`'s middleware (JS). Middleware returning `Nil`
matches Gleam's "do something for the side effect" idiom.

**Errors:** explicitly NOT propagated through the chain. Middleware
that wants to react to an API error pattern-matches on the `Result`
itself. For panics, `error_boundary` catches them at a chosen point.

## D-17. JSON helpers live in `internal/json_utils`

**Decision:** `put_optional` / `opt_str` / `opt_int` / `opt_bool` /
`opt_float` / `opt_nested` / `opt_list` are in
`glammy/internal/json_utils.gleam`. Used by `api`, `types`,
`keyboard`, `inline_query_results`, `input_media`.

**Why:** They were originally duplicated across each module (a clear
DRY violation discovered during the idiomatic refactor). The
`internal/` directory marks them as non-public-API — users importing
glammy should never need them.

## D-18. Bot API protocol handling is separate from HTTP dispatch

**Decision:** `api.PreparedCall(value)` is opaque and carries a method,
encoded payload description, and the decoder for that method's result. The
public `to_http_request` and `from_http_response` functions bridge it to
standard `gleam/http` request and response values without dispatching them.
`api.execute` remains the optional `gleam_httpc` convenience path.

**Rejected alternative:** treating an injected
`fn(String, Payload) -> Result(String, GlammyError)` as the custom transport
API. That callback still couples transport code to glammy-specific payloads,
cannot represent an HTTP status, and makes callers reproduce status and UTF-8
classification themselves.

**Why:** Gleam libraries compose at typed data boundaries. A standard
`Request(BitArray)` can be sent by any HTTP client, while the matching opaque
prepared call keeps response decoding method-specific. Tests can exercise both
halves with no network access.

**Compatibility:** `call`, `call_multipart`, typed method wrappers, and the
transformer chain still execute through `gleam_httpc`. Transformers apply only
to that convenience path; applications owning the transport also own its
middleware.

**Secret boundary:** a prepared call does not contain the bot token. Telegram
requires the token in the request URL, so `to_http_request` is the first point
where it becomes visible. Returned requests must be redacted rather than
printed or inspected in production logs.

## D-19. Long polling isolates handlers but preserves batch order

**Decision:** updates returned by one `getUpdates` call are handled
sequentially. Each isolated dispatch uses a broker that monitors the direct
caller and owns a linked handler worker. The broker applies a bounded timeout,
polling waits for its result before moving to the next update, and caller death
cleans up the library-owned worker.

**Why:** isolation prevents a panic or hang from killing the polling process;
sequential handling keeps offset advancement and per-chat middleware ordering
predictable. `SkipFailedUpdate` may report and advance past a confirmed crash;
`StopOnHandlerFailure` stops at that failed update. If earlier updates in that
batch were consumed, a short `getUpdates` with `offset = failed_update_id`
confirms only that prefix; the failed update remains eligible for retry. A
checkpoint failure returns `UpdateCheckpointFailure` with both causes because
the prefix may replay, while the failed update is still never skipped.
Gate/store failure, an unknown broker outcome, or unconfirmed termination fail
closed under both policies. A gate panic or self-termination is classified as
`UpdateGateCrashed` without exposing its exception value, and is equally
fail-closed. Handler timeouts also stop under both policies. Broker ownership
covers the linked handler worker, not detached `composer.fork` tasks or
arbitrary descendants; those may survive. A timeout or caller death cannot undo
an external effect started before termination, so once-only effects need an
idempotent gate or durable journal.
The default runtime logger emits only a stable error kind and update id;
application-controlled panic reasons, stacks, gate codes, and messages remain
available to an explicit `on_runtime_error` callback but are not logged by
default.
Applications that need bounded slow-work concurrency opt in
with `keyed_executor.update_gate`; `composer.fork` is the low-level unbounded
primitive.

**Not covered:** `bot.start` is still a blocking runner. The application must
supervise it and enforce one poller per token. There is no first-class stop
handle, readiness signal, double-start guard, supervisor child specification,
descendant join barrier, or rollback of in-flight external effects.

## D-20. High-level outbound APIs make invalid states unrepresentable

**Decision:** High-level send methods use finite sum types, endpoint-specific
records, and opaque validated collections. Parse modes, chat actions, poll
kinds, reply markup, reactions, delivery states, commands, command scopes,
inline results, batch message identifiers, HTTPS-only URLs, invite-link
options, and media fields are not arbitrary strings or JSON. Inbound open
enums retain
`Unknown*` variants for forward compatibility, but those variants are never
accepted by the corresponding outbound API.

**Why:** A compiler error is earlier and clearer than a Telegram 400 response.
The design also prevents cross-field bugs such as two bot reactions, an empty
or overlong plain poll question/option, an overlong/multiline quiz explanation,
quiz-only text attached to a regular poll, quiz identifiers checked against
different options, more than 100 commands, contradictory invite-link options,
a reusable thumbnail, a game/Pay button in the wrong position, an error message
paired with a successful payment answer, or cross-chat reply flags Telegram
forbids. Ephemeral media edits additionally reject uploads at the type boundary
because Telegram accepts only reusable file identifiers or URLs there.

`CopyTextButton`, finite button styles, and custom-emoji icons preserve one
action per keyboard button. `set_webhook_with_certificate` uses an upload-only
certificate type, so the Bot API's forbidden file-id and URL forms cannot be
constructed.

**Escape hatch:** Bot API 10.2 still has intentional rich-media gaps (parsed
poll text/entities/media, live photos, suggested-post structures). The
prepared-call family is the low-level extension seam: use `prepare_json_call`
for JSON-only requests and `prepare_multipart_call` when a gap requires
uploads. Typed wrappers do not sprinkle `json.Json` fields through otherwise
safe records. This also keeps the Local Bot API server's HTTP-webhook exception
explicit: high-level webhook registration models the public HTTPS-only
endpoint, while local deployments can prepare that transport-specific call
themselves.

## D-21. Slow work uses a bounded keyed executor

**Decision:** `keyed_executor` admits at most a configured active-plus-queued
capacity, runs no more than the global concurrency limit, and executes jobs for
one key strictly FIFO with at most one active job per key. User operations run
outside the scheduler in monitored isolation. Every accepted job has one
terminal outcome arbiter, and shutdown is a bounded monitor barrier.
Every active job also has a finite runtime deadline, measured from its actual
start rather than queue admission. `TimedOut`, `Cancelled`, and
`ExecutorTerminated` are not observable until the actual user operation is
confirmed down, including operations that trap exit signals and abrupt
scheduler death. A startup worker is monitored and acknowledged by the arbiter
before it may create that operation, so executor death cannot overtake task
attachment. The arbiter publishes that one terminal outcome before the
scheduler releases the key, global slot, and capacity.

Admission returns typed full/stopping/stopped/deadline/unknown states. `Ok` is
only a volatile in-memory queue receipt, not job completion or durable effect
delivery. The bot update-gate adapter consumes an update only after that
receipt and turns every admission failure into a typed gate error, so polling
does not silently advance under backpressure.

**Why:** global sequential polling makes one slow LLM call block unrelated
chats, while raw `composer.fork` has neither a capacity bound nor per-chat
ordering. A keyed actor scheduler makes the concurrency contract explicit and
testable without pretending to be a durable queue. Applications still need an
outbox, journal, or idempotency keys when accepted work must survive executor or
node loss, must treat pre-timeout external effects as potentially committed,
and must reconcile `AdmissionOutcomeUnknown` before retrying.
