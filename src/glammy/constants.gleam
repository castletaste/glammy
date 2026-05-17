//// Convenient string constants for the Telegram Bot API. Mirrors
//// grammY's `convenience/constants.ts`.

// =====================================================================
//                            Parse modes
// =====================================================================

pub const parse_mode_markdown: String = "Markdown"

pub const parse_mode_markdown_v2: String = "MarkdownV2"

pub const parse_mode_html: String = "HTML"

// =====================================================================
//                            Chat actions
// =====================================================================

pub const chat_action_typing: String = "typing"

pub const chat_action_upload_photo: String = "upload_photo"

pub const chat_action_record_video: String = "record_video"

pub const chat_action_upload_video: String = "upload_video"

pub const chat_action_record_voice: String = "record_voice"

pub const chat_action_upload_voice: String = "upload_voice"

pub const chat_action_upload_document: String = "upload_document"

pub const chat_action_choose_sticker: String = "choose_sticker"

pub const chat_action_find_location: String = "find_location"

pub const chat_action_record_video_note: String = "record_video_note"

pub const chat_action_upload_video_note: String = "upload_video_note"

// =====================================================================
//                          Sticker types
// =====================================================================

pub const sticker_type_regular: String = "regular"

pub const sticker_type_mask: String = "mask"

pub const sticker_type_custom_emoji: String = "custom_emoji"

// =====================================================================
//                              Currencies
// =====================================================================

/// Telegram Stars currency code (no fraction).
pub const currency_stars: String = "XTR"

// =====================================================================
//                          Poll types
// =====================================================================

pub const poll_type_regular: String = "regular"

pub const poll_type_quiz: String = "quiz"

// =====================================================================
//                          Dice emojis
// =====================================================================

pub const dice_emoji_die: String = "🎲"

pub const dice_emoji_darts: String = "🎯"

pub const dice_emoji_basketball: String = "🏀"

pub const dice_emoji_football: String = "⚽"

pub const dice_emoji_slot_machine: String = "🎰"

pub const dice_emoji_bowling: String = "🎳"

// =====================================================================
//                       Bot command scope kinds
// =====================================================================

pub const scope_default: String = "default"

pub const scope_all_private_chats: String = "all_private_chats"

pub const scope_all_group_chats: String = "all_group_chats"

pub const scope_all_chat_administrators: String = "all_chat_administrators"

pub const scope_chat: String = "chat"

pub const scope_chat_administrators: String = "chat_administrators"

pub const scope_chat_member: String = "chat_member"
