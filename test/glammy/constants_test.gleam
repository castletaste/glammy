//// Tests mirroring grammY's `test/convenience/constants.test.ts`. The
//// TypeScript original uses type-level exhaustiveness assertions; here
//// we sanity-check the value-level constants instead.

import glammy/constants

pub fn parse_modes_have_expected_values_test() {
  assert constants.parse_mode_markdown == "Markdown"
  assert constants.parse_mode_markdown_v2 == "MarkdownV2"
  assert constants.parse_mode_html == "HTML"
}

pub fn chat_actions_have_expected_values_test() {
  assert constants.chat_action_typing == "typing"
  assert constants.chat_action_upload_photo == "upload_photo"
  assert constants.chat_action_record_video == "record_video"
  assert constants.chat_action_upload_video == "upload_video"
  assert constants.chat_action_record_voice == "record_voice"
  assert constants.chat_action_upload_voice == "upload_voice"
  assert constants.chat_action_upload_document == "upload_document"
  assert constants.chat_action_choose_sticker == "choose_sticker"
  assert constants.chat_action_find_location == "find_location"
  assert constants.chat_action_record_video_note == "record_video_note"
  assert constants.chat_action_upload_video_note == "upload_video_note"
}

pub fn sticker_types_have_expected_values_test() {
  assert constants.sticker_type_regular == "regular"
  assert constants.sticker_type_mask == "mask"
  assert constants.sticker_type_custom_emoji == "custom_emoji"
}

pub fn poll_types_have_expected_values_test() {
  assert constants.poll_type_regular == "regular"
  assert constants.poll_type_quiz == "quiz"
}

pub fn dice_emojis_have_expected_values_test() {
  assert constants.dice_emoji_die == "🎲"
  assert constants.dice_emoji_darts == "🎯"
  assert constants.dice_emoji_basketball == "🏀"
  assert constants.dice_emoji_football == "⚽"
  assert constants.dice_emoji_slot_machine == "🎰"
  assert constants.dice_emoji_bowling == "🎳"
}

pub fn currency_stars_is_xtr_test() {
  assert constants.currency_stars == "XTR"
}

pub fn bot_command_scopes_have_expected_values_test() {
  assert constants.scope_default == "default"
  assert constants.scope_all_private_chats == "all_private_chats"
  assert constants.scope_all_group_chats == "all_group_chats"
  assert constants.scope_all_chat_administrators == "all_chat_administrators"
  assert constants.scope_chat == "chat"
  assert constants.scope_chat_administrators == "chat_administrators"
  assert constants.scope_chat_member == "chat_member"
}
