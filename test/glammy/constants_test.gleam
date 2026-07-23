//// Tests for canonical finite protocol values and the few remaining raw
//// constants that do not have typed outbound equivalents.

import glammy/chat_action
import glammy/constants
import glammy/parse_mode

pub fn parse_modes_have_expected_values_test() {
  assert parse_mode.to_string(parse_mode.Markdown) == "Markdown"
  assert parse_mode.to_string(parse_mode.MarkdownV2) == "MarkdownV2"
  assert parse_mode.to_string(parse_mode.Html) == "HTML"
}

pub fn chat_actions_have_expected_values_test() {
  assert chat_action.to_string(chat_action.Typing) == "typing"
  assert chat_action.to_string(chat_action.UploadPhoto) == "upload_photo"
  assert chat_action.to_string(chat_action.RecordVideo) == "record_video"
  assert chat_action.to_string(chat_action.UploadVideo) == "upload_video"
  assert chat_action.to_string(chat_action.RecordVoice) == "record_voice"
  assert chat_action.to_string(chat_action.UploadVoice) == "upload_voice"
  assert chat_action.to_string(chat_action.UploadDocument) == "upload_document"
  assert chat_action.to_string(chat_action.ChooseSticker) == "choose_sticker"
  assert chat_action.to_string(chat_action.FindLocation) == "find_location"
  assert chat_action.to_string(chat_action.RecordVideoNote)
    == "record_video_note"
  assert chat_action.to_string(chat_action.UploadVideoNote)
    == "upload_video_note"
}

pub fn sticker_types_have_expected_values_test() {
  assert constants.sticker_type_regular == "regular"
  assert constants.sticker_type_mask == "mask"
  assert constants.sticker_type_custom_emoji == "custom_emoji"
}

pub fn currency_stars_is_xtr_test() {
  assert constants.currency_stars == "XTR"
}
