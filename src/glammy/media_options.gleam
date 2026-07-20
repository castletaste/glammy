//// Endpoint-specific options for Telegram media send methods.
////
//// The Bot API accepts a different field set for each media kind. Separate
//// records keep options such as spoilers, captions, thumbnails, or performers
//// from leaking into methods that reject them.

import glammy/keyboard.{type ReplyMarkup}
import glammy/message_options.{type MessageDelivery}
import glammy/parse_mode.{type ParseMode}
import glammy/thumbnail.{type Thumbnail}
import gleam/option.{type Option, None}

/// Caption, spoiler, and delivery options accepted by `sendPhoto`.
pub type SendPhotoOptions {
  SendPhotoOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
    direct_messages_topic_id: Option(Int),
    delivery: MessageDelivery,
    caption: Option(String),
    parse_mode: Option(ParseMode),
    show_caption_above_media: Option(Bool),
    has_spoiler: Option(Bool),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_markup: Option(ReplyMarkup),
  )
}

/// Empty `sendPhoto` options.
pub fn default_send_photo_options() -> SendPhotoOptions {
  SendPhotoOptions(
    business_connection_id: None,
    message_thread_id: None,
    direct_messages_topic_id: None,
    delivery: message_options.standard_delivery(),
    caption: None,
    parse_mode: None,
    show_caption_above_media: None,
    has_spoiler: None,
    disable_notification: None,
    protect_content: None,
    allow_paid_broadcast: None,
    message_effect_id: None,
    reply_markup: None,
  )
}

/// Document-only metadata plus an upload-only thumbnail.
pub type SendDocumentOptions {
  SendDocumentOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
    direct_messages_topic_id: Option(Int),
    delivery: MessageDelivery,
    thumbnail: Option(Thumbnail),
    caption: Option(String),
    parse_mode: Option(ParseMode),
    disable_content_type_detection: Option(Bool),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_markup: Option(ReplyMarkup),
  )
}

/// Empty `sendDocument` options.
pub fn default_send_document_options() -> SendDocumentOptions {
  SendDocumentOptions(
    business_connection_id: None,
    message_thread_id: None,
    direct_messages_topic_id: None,
    delivery: message_options.standard_delivery(),
    thumbnail: None,
    caption: None,
    parse_mode: None,
    disable_content_type_detection: None,
    disable_notification: None,
    protect_content: None,
    allow_paid_broadcast: None,
    message_effect_id: None,
    reply_markup: None,
  )
}

/// Video dimensions, streaming, caption, spoiler, and delivery options.
pub type SendVideoOptions {
  SendVideoOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
    direct_messages_topic_id: Option(Int),
    delivery: MessageDelivery,
    thumbnail: Option(Thumbnail),
    caption: Option(String),
    parse_mode: Option(ParseMode),
    duration: Option(Int),
    width: Option(Int),
    height: Option(Int),
    supports_streaming: Option(Bool),
    show_caption_above_media: Option(Bool),
    has_spoiler: Option(Bool),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_markup: Option(ReplyMarkup),
  )
}

/// Empty `sendVideo` options.
pub fn default_send_video_options() -> SendVideoOptions {
  SendVideoOptions(
    business_connection_id: None,
    message_thread_id: None,
    direct_messages_topic_id: None,
    delivery: message_options.standard_delivery(),
    thumbnail: None,
    caption: None,
    parse_mode: None,
    duration: None,
    width: None,
    height: None,
    supports_streaming: None,
    show_caption_above_media: None,
    has_spoiler: None,
    disable_notification: None,
    protect_content: None,
    allow_paid_broadcast: None,
    message_effect_id: None,
    reply_markup: None,
  )
}

/// Audio metadata, caption, delivery, and upload-only thumbnail options.
pub type SendAudioOptions {
  SendAudioOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
    direct_messages_topic_id: Option(Int),
    delivery: MessageDelivery,
    thumbnail: Option(Thumbnail),
    caption: Option(String),
    parse_mode: Option(ParseMode),
    duration: Option(Int),
    performer: Option(String),
    title: Option(String),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_markup: Option(ReplyMarkup),
  )
}

/// Empty `sendAudio` options.
pub fn default_send_audio_options() -> SendAudioOptions {
  SendAudioOptions(
    business_connection_id: None,
    message_thread_id: None,
    direct_messages_topic_id: None,
    delivery: message_options.standard_delivery(),
    thumbnail: None,
    caption: None,
    parse_mode: None,
    duration: None,
    performer: None,
    title: None,
    disable_notification: None,
    protect_content: None,
    allow_paid_broadcast: None,
    message_effect_id: None,
    reply_markup: None,
  )
}

/// Voice caption, duration, and delivery options.
pub type SendVoiceOptions {
  SendVoiceOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
    direct_messages_topic_id: Option(Int),
    delivery: MessageDelivery,
    caption: Option(String),
    parse_mode: Option(ParseMode),
    duration: Option(Int),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_markup: Option(ReplyMarkup),
  )
}

/// Empty `sendVoice` options.
pub fn default_send_voice_options() -> SendVoiceOptions {
  SendVoiceOptions(
    business_connection_id: None,
    message_thread_id: None,
    direct_messages_topic_id: None,
    delivery: message_options.standard_delivery(),
    caption: None,
    parse_mode: None,
    duration: None,
    disable_notification: None,
    protect_content: None,
    allow_paid_broadcast: None,
    message_effect_id: None,
    reply_markup: None,
  )
}

/// Animation dimensions, caption, spoiler, and upload-only thumbnail options.
pub type SendAnimationOptions {
  SendAnimationOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
    direct_messages_topic_id: Option(Int),
    delivery: MessageDelivery,
    thumbnail: Option(Thumbnail),
    caption: Option(String),
    parse_mode: Option(ParseMode),
    duration: Option(Int),
    width: Option(Int),
    height: Option(Int),
    show_caption_above_media: Option(Bool),
    has_spoiler: Option(Bool),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_markup: Option(ReplyMarkup),
  )
}

/// Empty `sendAnimation` options.
pub fn default_send_animation_options() -> SendAnimationOptions {
  SendAnimationOptions(
    business_connection_id: None,
    message_thread_id: None,
    direct_messages_topic_id: None,
    delivery: message_options.standard_delivery(),
    thumbnail: None,
    caption: None,
    parse_mode: None,
    duration: None,
    width: None,
    height: None,
    show_caption_above_media: None,
    has_spoiler: None,
    disable_notification: None,
    protect_content: None,
    allow_paid_broadcast: None,
    message_effect_id: None,
    reply_markup: None,
  )
}

/// Circular video-note dimensions, delivery, and upload-only thumbnail options.
pub type SendVideoNoteOptions {
  SendVideoNoteOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
    direct_messages_topic_id: Option(Int),
    delivery: MessageDelivery,
    thumbnail: Option(Thumbnail),
    duration: Option(Int),
    length: Option(Int),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_markup: Option(ReplyMarkup),
  )
}

/// Empty `sendVideoNote` options.
pub fn default_send_video_note_options() -> SendVideoNoteOptions {
  SendVideoNoteOptions(
    business_connection_id: None,
    message_thread_id: None,
    direct_messages_topic_id: None,
    delivery: message_options.standard_delivery(),
    thumbnail: None,
    duration: None,
    length: None,
    disable_notification: None,
    protect_content: None,
    allow_paid_broadcast: None,
    message_effect_id: None,
    reply_markup: None,
  )
}

/// Sticker emoji and delivery options. Captions are intentionally unavailable.
pub type SendStickerOptions {
  SendStickerOptions(
    business_connection_id: Option(String),
    message_thread_id: Option(Int),
    direct_messages_topic_id: Option(Int),
    delivery: MessageDelivery,
    emoji: Option(String),
    disable_notification: Option(Bool),
    protect_content: Option(Bool),
    allow_paid_broadcast: Option(Bool),
    message_effect_id: Option(String),
    reply_markup: Option(ReplyMarkup),
  )
}

/// Empty `sendSticker` options.
pub fn default_send_sticker_options() -> SendStickerOptions {
  SendStickerOptions(
    business_connection_id: None,
    message_thread_id: None,
    direct_messages_topic_id: None,
    delivery: message_options.standard_delivery(),
    emoji: None,
    disable_notification: None,
    protect_content: None,
    allow_paid_broadcast: None,
    message_effect_id: None,
    reply_markup: None,
  )
}
