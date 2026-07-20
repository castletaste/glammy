//// Convenient string constants for the Telegram Bot API. Mirrors
//// grammY's `convenience/constants.ts`.

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
pub const parse_mode_markdown: ParseMode = Markdown

/// Telegram MarkdownV2 formatting.
pub const parse_mode_markdown_v2: ParseMode = MarkdownV2

/// Telegram HTML formatting.
pub const parse_mode_html: ParseMode = Html

// =====================================================================
//                            Chat actions
// =====================================================================

/// Indicates that the bot is typing a text message.
pub const chat_action_typing: ChatAction = Typing

/// Indicates that the bot is uploading a photo.
pub const chat_action_upload_photo: ChatAction = UploadPhoto

/// Indicates that the bot is recording a video.
pub const chat_action_record_video: ChatAction = RecordVideo

/// Indicates that the bot is uploading a video.
pub const chat_action_upload_video: ChatAction = UploadVideo

/// Indicates that the bot is recording a voice message.
pub const chat_action_record_voice: ChatAction = RecordVoice

/// Indicates that the bot is uploading a voice message.
pub const chat_action_upload_voice: ChatAction = UploadVoice

/// Indicates that the bot is uploading a document.
pub const chat_action_upload_document: ChatAction = UploadDocument

/// Indicates that the bot is choosing a sticker.
pub const chat_action_choose_sticker: ChatAction = ChooseSticker

/// Indicates that the bot is selecting a location.
pub const chat_action_find_location: ChatAction = FindLocation

/// Indicates that the bot is recording a video note.
pub const chat_action_record_video_note: ChatAction = RecordVideoNote

/// Indicates that the bot is uploading a video note.
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
pub const poll_type_regular: String = "regular"

/// Bot API discriminator for a quiz poll.
pub const poll_type_quiz: String = "quiz"

// =====================================================================
//                          Dice emojis
// =====================================================================

/// Emoji selecting Telegram's die animation.
pub const dice_emoji_die: String = "🎲"

/// Emoji selecting Telegram's darts animation.
pub const dice_emoji_darts: String = "🎯"

/// Emoji selecting Telegram's basketball animation.
pub const dice_emoji_basketball: String = "🏀"

/// Emoji selecting Telegram's football animation.
pub const dice_emoji_football: String = "⚽"

/// Emoji selecting Telegram's slot-machine animation.
pub const dice_emoji_slot_machine: String = "🎰"

/// Emoji selecting Telegram's bowling animation.
pub const dice_emoji_bowling: String = "🎳"

// =====================================================================
//                       Bot command scope kinds
// =====================================================================

/// Bot-command scope covering all chats by default.
pub const scope_default: String = "default"

/// Bot-command scope covering every private chat.
pub const scope_all_private_chats: String = "all_private_chats"

/// Bot-command scope covering every group and supergroup.
pub const scope_all_group_chats: String = "all_group_chats"

/// Bot-command scope covering administrators in all groups.
pub const scope_all_chat_administrators: String = "all_chat_administrators"

/// Bot-command scope covering one chat.
pub const scope_chat: String = "chat"

/// Bot-command scope covering administrators in one chat.
pub const scope_chat_administrators: String = "chat_administrators"

/// Bot-command scope covering one member of one chat.
pub const scope_chat_member: String = "chat_member"
