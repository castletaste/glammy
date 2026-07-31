# Migrating to 0.2.0

Version 0.2.0 is intended to be Glammy's first Hex publication. This guide
records breaking changes from the historical 0.1.0 source candidate; there is
no published 0.1.x Hex release to upgrade from.

## Removed public API

The removed surface duplicated finite Gleam types or canonical helpers. The
replacement API is already used by Glammy's own sources, tests, and example.

### Constants

In the table, `api` and `types` refer to `glammy/api` and `glammy/types`.

| Removed from `glammy/constants` | Replacement |
| --- | --- |
| `parse_mode_markdown` | `glammy/parse_mode.Markdown` |
| `parse_mode_markdown_v2` | `glammy/parse_mode.MarkdownV2` |
| `parse_mode_html` | `glammy/parse_mode.Html` |
| `chat_action_typing` | `glammy/chat_action.Typing` |
| `chat_action_upload_photo` | `glammy/chat_action.UploadPhoto` |
| `chat_action_record_video` | `glammy/chat_action.RecordVideo` |
| `chat_action_upload_video` | `glammy/chat_action.UploadVideo` |
| `chat_action_record_voice` | `glammy/chat_action.RecordVoice` |
| `chat_action_upload_voice` | `glammy/chat_action.UploadVoice` |
| `chat_action_upload_document` | `glammy/chat_action.UploadDocument` |
| `chat_action_choose_sticker` | `glammy/chat_action.ChooseSticker` |
| `chat_action_find_location` | `glammy/chat_action.FindLocation` |
| `chat_action_record_video_note` | `glammy/chat_action.RecordVideoNote` |
| `chat_action_upload_video_note` | `glammy/chat_action.UploadVideoNote` |
| `poll_type_regular` | `api.regular_poll`, `types.RegularInputPoll`, or `"regular"` in a raw payload |
| `poll_type_quiz` | `api.quiz_poll`, `types.QuizInputPoll`, or `"quiz"` in a raw payload |
| `dice_emoji_die` | `api.Dice`, or `"🎲"` in a raw payload |
| `dice_emoji_darts` | `api.Darts`, or `"🎯"` in a raw payload |
| `dice_emoji_basketball` | `api.Basketball`, or `"🏀"` in a raw payload |
| `dice_emoji_football` | `api.Football`, or `"⚽"` in a raw payload |
| `dice_emoji_slot_machine` | `api.SlotMachine`, or `"🎰"` in a raw payload |
| `dice_emoji_bowling` | `api.Bowling`, or `"🎳"` in a raw payload |
| `scope_default` | `types.BotCommandScopeDefault`, or `"default"` in a raw payload |
| `scope_all_private_chats` | `types.BotCommandScopeAllPrivateChats`, or `"all_private_chats"` in a raw payload |
| `scope_all_group_chats` | `types.BotCommandScopeAllGroupChats`, or `"all_group_chats"` in a raw payload |
| `scope_all_chat_administrators` | `types.BotCommandScopeAllChatAdministrators`, or `"all_chat_administrators"` in a raw payload |
| `scope_chat` | `types.BotCommandScopeChat`, or `"chat"` in a raw payload |
| `scope_chat_administrators` | `types.BotCommandScopeChatAdministrators`, or `"chat_administrators"` in a raw payload |
| `scope_chat_member` | `types.BotCommandScopeChatMember`, or `"chat_member"` in a raw payload |

The four raw constants without typed outbound equivalents remain:
`sticker_type_regular`, `sticker_type_mask`, `sticker_type_custom_emoji`, and
`currency_stars`.

### Media option defaults

The following helpers moved from `glammy/api` to `glammy/media_options` without
changing their names or return types:

- `default_send_photo_options`
- `default_send_document_options`
- `default_send_video_options`
- `default_send_audio_options`
- `default_send_voice_options`
- `default_send_animation_options`
- `default_send_video_note_options`
- `default_send_sticker_options`

### Keyed executor

`glammy/keyed_executor.submit_with_key` was removed. Derive the key and call
`keyed_executor.submit`, or use `keyed_executor.update_gate` for bot update
admission.

### Error boundary

`glammy/error_boundary.OtherClass(String)` was removed. Runtime boundaries
produce only `ErrorClass`, `ExitClass`, or `ThrowClass`; remove the obsolete
match arm or wildcard fallback.
