# Roadmap

This document records known gaps in glammy and the future-work ideas
that surfaced during development. Items here are NOT commitments —
they're material for the next maintainer to evaluate.

## Known gaps (could be filled but were skipped)

### G-1. Bot API methods beyond the typed surface

glammy exposes ~50 typed wrappers (sendMessage, sendPhoto, banChatMember,
…). The Telegram Bot API has ~120 methods total. The rest are reachable
via `api.call(api, "methodName", fields, decoder)` — the generic
escape hatch — but they don't get the same ergonomic helpers.

**Specifically missing typed wrappers for:** sendMediaGroup,
editMessageMedia, copyMessages, setStickerSet, getStickerSet,
uploadStickerFile, createNewStickerSet, addStickerToSet,
setCustomEmojiStickerSetThumbnail, setStickerPositionInSet,
deleteStickerFromSet, setStickerSetTitle, deleteStickerSet,
setStickerEmojiList, setStickerKeywords, setStickerMaskPosition,
sendPaidMedia, savePreparedInlineMessage, createInvoiceLink,
getStarTransactions, editUserStarSubscription, editForumTopic,
hideGeneralForumTopic, unhideGeneralForumTopic,
unpinAllGeneralForumTopicMessages, getBusinessConnection,
readBusinessMessage, deleteBusinessMessages, setBusinessAccountName,
setBusinessAccountUsername, setBusinessAccountBio,
setBusinessAccountProfilePhoto, removeBusinessAccountProfilePhoto,
setBusinessAccountGiftSettings, getBusinessAccountStarBalance,
transferBusinessAccountStars, getBusinessAccountGifts,
convertGiftToStars, upgradeGift, transferGift, sendGift,
giftPremiumSubscription, verifyUser, verifyChat, removeUserVerification,
removeChatVerification, getMyName, getMyShortDescription, getMyName,
setUserEmojiStatus, getAvailableGifts, getCustomEmojiStickers,
getMyDefaultAdministratorRights, sendPaidMessageTip, etc.

**Why skipped:** Diminishing returns. Adding 70 more typed wrappers
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
message kinds aren't decoded. Tests pass for current shapes; if Telegram
adds more fields, the `OtherUpdate` fallback handles unknown updates
gracefully.

### G-5. Inline query result button + sticker keyboards

`InlineQueryResultsButton` (the "switch to web app" button shown above
inline results) isn't exposed. Only inline result items are.

### G-6. ChatBoostSource Premium gift / paid subtypes

`ChatBoostSourcePaid` and refined premium boost source fields aren't
modelled. Current `ChatBoostSource` decodes the common case.

### G-7. `LinkPreviewOptions` send-side encoding

We decode `LinkPreviewOptions` on incoming messages but don't expose a
builder for outgoing send-message `link_preview_options` argument. The
caller can construct the JSON manually.

### G-8. `MessageReactionUpdated.is_big`, `actor_chat`

Message reactions are partially modelled; some fine-grained fields
(`is_big`, type-of-actor) are not surfaced as record fields. The raw
JSON is accessible via the inherited `forward_origin: Option(Dynamic)`
pattern — but only on Message, not on reactions.

## Future-work ideas

### F-1. Conversations: persistent / replayable

The current `glammy/conversations.gleam` is single-process. A
persistent version would:

1. Log every API call inside the conversation
2. On bot restart, replay the log against new API responses to
   reconstruct conversation state
3. Persist intermediate state to a `session.Storage`-style backend

This is the approach of `@grammyjs/conversations`. It's a non-trivial
module (~2k lines in TS), would need its own subdirectory in glammy.

Suggested design: separate `glammy/conversations_persistent.gleam`,
keep the simple one as `glammy/conversations.gleam`.

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

A drop-in `session.ets_storage()` that uses Erlang's ETS instead of
the Subject-based actor. Faster for high-traffic bots.

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

- **Telegram Bot API releases** typically happen ~monthly. Audit
  `types.gleam`'s Update variants and Message fields against the latest
  bot API changelog every few months.
- **gleam-lang package versions** in `gleam.toml` use minor-version
  ranges (`>= X.Y.0 and < X+1.0.0`). Periodically bump the lower bound
  to pick up new features.
- **Erlang/OTP compatibility** — we use `crypto:hash_equals/2`,
  `crypto:strong_rand_bytes/1`, `lists:sort/1`, `erlang:div/2`.
  All present in OTP 24+.

## Out of scope (will not be added)

- **Schema generation from Telegram docs** — grammY's `@grammyjs/types`
  is generated from a JSON schema. We deliberately don't do this; the
  manual port is one-time and produces more idiomatic Gleam.
- **Multi-bot orchestration** — running N bots from one process is
  achievable by spawning N supervised processes; doesn't need a
  glammy-level abstraction.
- **Webhook-reply optimisation** — grammY supports sending the bot's
  HTTP response back through the same webhook POST connection.
  Saves an HTTP round-trip but couples the response to the framework.
  Out of scope given D-1's framework-agnostic stance.
