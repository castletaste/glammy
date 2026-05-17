# Design decisions

This document records the **why** behind the non-obvious choices in
glammy. Every decision listed here was reached by working through an
alternative and rejecting it for a specific reason.

## D-1. Dependencies are vetted gleam-lang official packages only

**Decision:** Every transitive dependency is published by the official
`gleam-lang` GitHub organisation on hex.pm. No third-party deps.

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
- Side-channel actors (process Subjects, ETS tables)

## D-3. Multipart encoder is hand-rolled

**Decision:** `glammy/multipart.gleam` implements RFC 7578
`multipart/form-data` encoding from scratch (~120 LOC).

**Why:** D-1 (no third-party deps). The encoder needs:
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

**Decision:** `input_file.InputFile` is a *description* of a file
source:
- `FileId(id)` — Telegram file_id (no upload, no I/O)
- `FileUrl(url)` — let Telegram fetch the URL (no I/O on our side)
- `FileBytes(bytes, filename, mime_type)` — pre-loaded bytes
- `FilePath(path, filename, mime_type)` — descriptive only

`FilePath` does **not** auto-read from disk. The caller is responsible
for reading bytes and constructing `FileBytes` if they want to upload.

**Why:**
- Library purity: keep `InputFile` deterministic in tests.
- Failure modes: file-system errors should propagate at the caller's
  boundary, not buried inside the API client.
- Symmetry with `FileUrl`: we don't fetch URLs either.

**Trade-off:** Less ergonomic than grammY's `new InputFile("/tmp/x")`
which auto-reads. Users explicitly call
`input_file.from_path("/tmp/x")` then read bytes themselves.

## D-5. `session.with_session` is a pure-function API

**Decision:** Session handlers have signature
`fn(Context, value) -> value`. The returned value is persisted to
storage automatically.

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

**Chosen:** Pure function. State flow is visible. Type-safe end to end.
Multiple plugins thread their own state independently.

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
2. **`Query` from string** — `parse("::url OR message:text")`

**Why:** Different ergonomics for different cases.
- Typed enum: exhaustive, compiler-checked, no string typos
- String DSL: matches grammY's filter strings 1:1, terser for advanced
  filters (entities, defaults, shortcuts)

Both are first-class — neither wraps the other.

## D-8. Update kind decoder uses `list.find_map`, not nested `case`

**Decision:** `update_kind_decoder` collects all 23 Update
sub-variants into a list of `Option(UpdateKind)`, then uses
`list.find_map(candidates, option.to_result(_, Nil)) |>
result.unwrap(OtherUpdate)`.

**Rejected alternative:** 30-deep nested `case` (which was the
original, and is genuinely awful to read).

**Why the alternative was wrong:** Maintenance hazard. Adding a new
Update variant required threading it through the nesting. The
flat-list version is read top-to-bottom in canonical order.

## D-9. `decode.failure` placeholder is a top-level `const`, not a fn

**Decision:** `placeholder_user: User` is a top-level constant used
where `decode.failure(value, name)` requires a type-defining value
the decoder will never observably return.

**Why:** Cleaner than `dummy_user()` returning a fresh fake every time
the failure path is hit. Constants are evaluated once. The placeholder
is provably unobservable — gleam_json's `decode.failure` returns the
placeholder *only when also recording a decode error*, and `json.parse`
surfaces the error before the placeholder is ever seen.

## D-10. `bot.start` returns `Result`, never panics

**Decision:** Even when the initial `getMe` verification fails,
`bot.start` returns `Error(GlammyError)` instead of `panic`-ing.

**Why:** No panic in public API surface — library principle. Callers
that *want* to crash on bad credentials can `let assert Ok(_) =
bot.start(...)`. Callers that want to recover (e.g. notify on Slack,
retry) get a clean Result.

**Related:** `verify_token: Bool` in `PollingOptions` lets users skip
the initial check entirely if they want bot startup to be cheap.

## D-11. Webhook secret comparison uses `crypto:hash_equals`

**Decision:** `webhook.verify_secret` calls Erlang's
`crypto:hash_equals/2` after a length check, instead of using
Gleam's `==` or a hand-rolled XOR loop.

**Why:** `crypto:hash_equals/2` is documented constant-time. Hand-rolled
loops are easy to get wrong (short-circuit operators, branch
prediction). Length mismatch short-circuits to `False` — that does not
leak useful timing info (the wire-level length is already visible).

## D-12. `error_boundary` uses Erlang FFI for try/catch

**Decision:** `glammy_ffi.erl::try_run/1` wraps a Gleam thunk in
Erlang's `try Class:Reason:Stack`. Gleam itself has no try/catch.

**Why:** Without FFI, we can't catch:
- `panic as "..."`
- `let assert` failures
- Erlang `error:badarith`, `throw`, `exit`

… all of which can happen inside user-supplied middleware. Without an
error boundary, a single buggy handler would crash the entire poll
loop.

**Surface area:** one Erlang function with one clause. Audited.

## D-13. Conversations are user-scoped, single-process

**Decision:** `conversations.start` registers a wait subject keyed by
the user's `from.id`. Only that user's next update wakes the wait. The
state lives in a registry actor — when the bot restarts, in-flight
conversations are lost.

**Why:** grammY's `@grammyjs/conversations` is persistent and
replayable (it logs every API call, deterministically replays on
restart). Implementing that correctly requires:
- A virtual time / replay engine
- Persisted call logs
- Deterministic capture of all side-effects
- Plus extensive testing

That's a large module. glammy ships the **80% useful** version: linear
flows that survive within a single bot lifetime. Users who need
replayable conversations bring their own (or contribute one).

## D-14. `types.gleam` is one large file

**Decision:** ~2400 lines of types + decoders live in a single module,
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

## D-15. Memory storage uses a Subject-actor, not ETS

**Decision:** `session.memory_storage()` spawns a BEAM process whose
mailbox loop holds the storage `Dict`. Reads are calls; writes are
casts.

**Why:** Pure Gleam, no FFI. ETS would be faster but requires
`@external` for `ets:new`/`ets:lookup`/`ets:insert`. The Subject path
is plenty for development and low-traffic bots.

**Performance escape hatch:** users who need ETS or Redis use
`session.custom_storage(get:, set:, delete:)` and bring their own
backend.

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

## D-17. `pub const` over `pub fn` for placeholder values

**Decision:** `placeholder_user: User = User(...)` is `pub const`, not
a `pub fn placeholder_user() -> User`.

**Why:** Constants are evaluated once at module load. Functions are
called fresh every time. For values that exist purely as type-witnesses
(never observably used), evaluating once is cheaper and clearer.

## D-18. JSON helpers live in `internal/json_utils`

**Decision:** `put_optional` / `opt_str` / `opt_int` / `opt_bool` /
`opt_float` / `opt_with_default` are in
`glammy/internal/json_utils.gleam`. Used by `api`, `types`,
`inline_query_results`, `input_media`.

**Why:** They were originally duplicated across each module (a clear
DRY violation discovered during the idiomatic refactor). The
`internal/` directory marks them as non-public-API — users importing
glammy should never need them.
