# glammy knowledge base

This directory captures the **why** behind glammy's design. The code
itself answers most *what* and *how* questions; these documents answer
*why* certain choices were made — the kind of context that disappears
when you only read the diff.

## Index

| Document                                  | Read it when …                                                  |
| ----------------------------------------- | --------------------------------------------------------------- |
| [`architecture.md`](https://github.com/castletaste/glammy/blob/main/docs/architecture.md) | Onboarding, mapping a feature back to a module |
| [`design-decisions.md`](https://github.com/castletaste/glammy/blob/main/docs/design-decisions.md) | Touching a load-bearing primitive or planning an API change |
| [`grammy-parity.md`](https://github.com/castletaste/glammy/blob/main/docs/grammy-parity.md) | Adding tests, checking what's covered vs grammY |
| [`roadmap.md`](https://github.com/castletaste/glammy/blob/main/docs/roadmap.md) | Picking up future work, evaluating "is X possible here?" |
| [`releasing.md`](https://github.com/castletaste/glammy/blob/main/docs/releasing.md) | Preparing, validating, and publishing a Hex release |

## TL;DR

glammy is a from-scratch port of [grammY](https://github.com/grammyjs/grammY)
(TypeScript Telegram Bot framework) to [Gleam](https://gleam.run) on the
BEAM. The implementation is Gleam plus a small, audited Erlang FFI boundary.

**Status:** pre-release 0.2.0 candidate. The authoritative quality gates are
`gleam build --warnings-as-errors`, `gleam test`, the deterministic
keyed-executor startup-barrier check, `gleam docs build`, the compiled consumer
project in `examples/echo_bot`, the isolated dependency-floor build in
`scripts/check_min_deps.sh`, and `gleam export hex-tarball` followed by the
structural/source-parity verifier and unpacked consumer build. The grammY
mapping is traceability material, not a claim of line-for-line parity or
exhaustive behavioural coverage.

**Telegram baseline:** maintenance is currently pinned to Bot API 10.2
(14 July 2026). This identifies the audited upstream version, not exhaustive
method or field parity; known gaps live in
[`roadmap.md`](https://github.com/castletaste/glammy/blob/main/docs/roadmap.md).

**Dependencies:** runtime packages are limited to the official `gleam-lang`
organisation (`gleam_stdlib`, `gleam_erlang`, `gleam_json`, `gleam_http`,
`gleam_httpc`, and `gleam_otp`). See `gleam.toml` for the exact constraints.

**Public modules:**

- Facade and core: `glammy`, `glammy/api`, `glammy/types`,
  `glammy/composer`, `glammy/context`, `glammy/filter`, `glammy/keyboard`,
  `glammy/bot`, `glammy/keyed_executor`, `glammy/error`
- Protocol values: `glammy/chat_action`, `glammy/message_options`,
  `glammy/parse_mode`, `glammy/reaction`, `glammy/webhook_secret`,
  `glammy/https_url`
- Media: `glammy/input_file`, `glammy/thumbnail`, `glammy/multipart`,
  `glammy/input_media`, `glammy/media_options`
- Plugins: `glammy/session`, `glammy/conversations`,
  `glammy/error_boundary`, `glammy/webhook`
- Helpers: `glammy/constants`, `glammy/escape`,
  `glammy/inline_query_results`

**Internal:** `glammy/internal/json_utils`, `glammy/internal/http_response`,
and `glammy/internal/ffi` are implementation helpers, not public API.
