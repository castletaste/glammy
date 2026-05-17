# glammy knowledge base

This directory captures the **why** behind glammy's design. The code
itself answers most *what* and *how* questions; these documents answer
*why* certain choices were made — the kind of context that disappears
when you only read the diff.

## Index

| Document                                  | Read it when …                                                  |
| ----------------------------------------- | --------------------------------------------------------------- |
| [`architecture.md`](architecture.md)      | Onboarding, mapping a feature back to a module                   |
| [`design-decisions.md`](design-decisions.md) | Touching a load-bearing primitive or planning an API change |
| [`grammy-parity.md`](grammy-parity.md)    | Adding tests, checking what's covered vs grammY                  |
| [`roadmap.md`](roadmap.md)                | Picking up future work, evaluating "is X possible here?"         |

## TL;DR

glammy is a from-scratch port of [grammY](https://github.com/grammyjs/grammY)
(TypeScript Telegram Bot framework) to [Gleam](https://gleam.run) on the
BEAM. ~7k LOC of Gleam + 1 small Erlang FFI file (`glammy_ffi.erl`).

**Status:** 201 tests passing, clean build (no warnings). Most of
grammY's behavioural tests are ported (filter, composer, context, bot,
session, webhook, keyboard, input_media, constants, error, client,
payload, inline query results). JS-async-specific tests (Promise
concurrency, framework adapters, init caching) are intentionally
omitted.

**Dependencies:** five hex packages, all from the official `gleam-lang`
GitHub org. Zero third-party deps. See `gleam.toml`.

**Public modules:**

- Core: `glammy/api`, `glammy/types`, `glammy/composer`, `glammy/context`,
  `glammy/filter`, `glammy/keyboard`, `glammy/bot`, `glammy/error`
- Media: `glammy/input_file`, `glammy/multipart`, `glammy/input_media`
- Plugins: `glammy/session`, `glammy/conversations`,
  `glammy/error_boundary`, `glammy/webhook`
- Helpers: `glammy/constants`, `glammy/escape`,
  `glammy/inline_query_results`

**Internal:** `glammy/internal/json_utils` (shared encoder/decoder
helpers — not part of the public API).
