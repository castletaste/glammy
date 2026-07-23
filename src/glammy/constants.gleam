//// Telegram Bot API constants.
////
//// Deprecated compatibility aliases remain available throughout 0.1.x and
//// will be removed in 0.2.0. New code should use Glammy's finite typed values.

import glammy/chat_action.{
  type ChatAction, ChooseSticker, FindLocation, RecordVideo, RecordVideoNote,
  RecordVoice, Typing, UploadDocument, UploadPhoto, UploadVideo, UploadVideoNote,
  UploadVoice,
}
import glammy/parse_mode.{type ParseMode, Html, Markdown, MarkdownV2}

// =====================================================================
//                            Parse modes
// =====================================================================

/// Legacy Telegram Markdown formatting.
@deprecated("Use glammy/parse_mode.Markdown")
pub const parse_mode_markdown: ParseMode = Markdown

/// Telegram MarkdownV2 formatting.
@deprecated("Use glammy/parse_mode.MarkdownV2")
pub const parse_mode_markdown_v2: ParseMode = MarkdownV2

/// Telegram HTML formatting.
@deprecated("Use glammy/parse_mode.Html")
pub const parse_mode_html: ParseMode = Html

// =====================================================================
//                            Chat actions
// =====================================================================

/// Indicates that the bot is typing a text message.
@deprecated("Use glammy/chat_action.Typing")
pub const chat_action_typing: ChatAction = Typing

/// Indicates that the bot is uploading a photo.
@deprecated("Use glammy/chat_action.UploadPhoto")
pub const chat_action_upload_photo: ChatAction = UploadPhoto

/// Indicates that the bot is recording a video.
@deprecated("Use glammy/chat_action.RecordVideo")
pub const chat_action_record_video: ChatAction = RecordVideo

/// Indicates that the bot is uploading a video.
@deprecated("Use glammy/chat_action.UploadVideo")
pub const chat_action_upload_video: ChatAction = UploadVideo

/// Indicates that the bot is recording a voice message.
@deprecated("Use glammy/chat_action.RecordVoice")
pub const chat_action_record_voice: ChatAction = RecordVoice

/// Indicates that the bot is uploading a voice message.
@deprecated("Use glammy/chat_action.UploadVoice")
pub const chat_action_upload_voice: ChatAction = UploadVoice

/// Indicates that the bot is uploading a document.
@deprecated("Use glammy/chat_action.UploadDocument")
pub const chat_action_upload_document: ChatAction = UploadDocument

/// Indicates that the bot is choosing a sticker.
@deprecated("Use glammy/chat_action.ChooseSticker")
pub const chat_action_choose_sticker: ChatAction = ChooseSticker

/// Indicates that the bot is selecting a location.
@deprecated("Use glammy/chat_action.FindLocation")
pub const chat_action_find_location: ChatAction = FindLocation

/// Indicates that the bot is recording a video note.
@deprecated("Use glammy/chat_action.RecordVideoNote")
pub const chat_action_record_video_note: ChatAction = RecordVideoNote

/// Indicates that the bot is uploading a video note.
@deprecated("Use glammy/chat_action.UploadVideoNote")
pub const chat_action_upload_video_note: ChatAction = UploadVideoNote

// =====================================================================
//                          Sticker types
// =====================================================================

/// Bot API discriminator for a regular sticker set.
pub const sticker_type_regular: String = "regular"

/// Bot API discriminator for a mask sticker set.
pub const sticker_type_mask: String = "mask"

/// Bot API discriminator for a custom-emoji sticker set.
pub const sticker_type_custom_emoji: String = "custom_emoji"

// =====================================================================
//                              Currencies
// =====================================================================

/// Telegram Stars currency code (no fraction).
pub const currency_stars: String = "XTR"

// =====================================================================
//                          Poll types
// =====================================================================

/// Bot API discriminator for a regular poll.
@deprecated("Use api.regular_poll for send_poll, types.RegularInputPoll for reply keyboards, or \"regular\" in raw payloads")
pub const poll_type_regular: String = "regular"

/// Bot API discriminator for a quiz poll.
@deprecated("Use api.quiz_poll for send_poll, types.QuizInputPoll for reply keyboards, or \"quiz\" in raw payloads")
pub const poll_type_quiz: String = "quiz"

// =====================================================================
//                          Dice emojis
// =====================================================================

/// Emoji selecting Telegram's die animation.
@deprecated("Use api.Dice with send_dice; for raw payloads use \"🎲\"")
pub const dice_emoji_die: String = "🎲"

/// Emoji selecting Telegram's darts animation.
@deprecated("Use api.Darts with send_dice; for raw payloads use \"🎯\"")
pub const dice_emoji_darts: String = "🎯"

/// Emoji selecting Telegram's basketball animation.
@deprecated("Use api.Basketball with send_dice; for raw payloads use \"🏀\"")
pub const dice_emoji_basketball: String = "🏀"

/// Emoji selecting Telegram's football animation.
@deprecated("Use api.Football with send_dice; for raw payloads use \"⚽\"")
pub const dice_emoji_football: String = "⚽"

/// Emoji selecting Telegram's slot-machine animation.
@deprecated("Use api.SlotMachine with send_dice; for raw payloads use \"🎰\"")
pub const dice_emoji_slot_machine: String = "🎰"

/// Emoji selecting Telegram's bowling animation.
@deprecated("Use api.Bowling with send_dice; for raw payloads use \"🎳\"")
pub const dice_emoji_bowling: String = "🎳"

// =====================================================================
//                       Bot command scope kinds
// =====================================================================

/// Bot-command scope covering all chats by default.
@deprecated("Use types.BotCommandScopeDefault; for raw payloads use \"default\"")
pub const scope_default: String = "default"

/// Bot-command scope covering every private chat.
@deprecated("Use types.BotCommandScopeAllPrivateChats; for raw payloads use \"all_private_chats\"")
pub const scope_all_private_chats: String = "all_private_chats"

/// Bot-command scope covering every group and supergroup.
@deprecated("Use types.BotCommandScopeAllGroupChats; for raw payloads use \"all_group_chats\"")
pub const scope_all_group_chats: String = "all_group_chats"

/// Bot-command scope covering administrators in all groups.
@deprecated("Use types.BotCommandScopeAllChatAdministrators; for raw payloads use \"all_chat_administrators\"")
pub const scope_all_chat_administrators: String = "all_chat_administrators"

/// Bot-command scope covering one chat.
@deprecated("Use types.BotCommandScopeChat; for raw payloads use \"chat\"")
pub const scope_chat: String = "chat"

/// Bot-command scope covering administrators in one chat.
@deprecated("Use types.BotCommandScopeChatAdministrators; for raw payloads use \"chat_administrators\"")
pub const scope_chat_administrators: String = "chat_administrators"

/// Bot-command scope covering one member of one chat.
@deprecated("Use types.BotCommandScopeChatMember; for raw payloads use \"chat_member\"")
pub const scope_chat_member: String = "chat_member"
