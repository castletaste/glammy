//// Telegram Bot API types — ported from `@grammyjs/types` (the TypeScript
//// definitions used by grammY). Records here cover the bulk of the API
//// surface; truly exotic fields are passed through as `Dynamic` to keep
//// the type definitions manageable.
////
//// Supported inbound model records expose matching decoders. Outbound-only
//// protocol values instead use validated constructors and encoders. Decoders
//// are tolerant — unknown fields are ignored, and missing-but-required fields
//// produce a clean decode error.

import glammy/internal/json_utils
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// =====================================================================
//                          Forward-compatible raw data
// =====================================================================

/// The complete JSON object captured alongside a central typed record.
///
/// Telegram adds fields more quickly than a package can release. Keeping the
/// original dynamic value means known records never make new fields
/// unrecoverable while their commonly-used fields remain typed.
pub opaque type RawObject {
  RawObject(payload: Dynamic)
}

/// Decode application-owned data from a captured raw Telegram object.
pub fn decode_raw_object(
  raw: RawObject,
  decoder: Decoder(value),
) -> Result(value, List(decode.DecodeError)) {
  decode.run(raw.payload, decoder)
}

/// Re-encode a captured Telegram object as structured JSON.
///
/// This is useful for durable journals and forwarding. Conversion is fully
/// typed and fails if the dynamic payload contains a non-JSON runtime value.
pub fn raw_object_to_json(
  raw: RawObject,
) -> Result(json.Json, List(decode.DecodeError)) {
  decode.run(raw.payload, raw_json_decoder())
}

fn raw_json_decoder() -> Decoder(json.Json) {
  decode.recursive(fn() {
    decode.optional(
      decode.one_of(decode.string |> decode.map(json.string), [
        decode.bool |> decode.map(json.bool),
        decode.int |> decode.map(json.int),
        decode.float |> decode.map(json.float),
        decode.list(raw_json_decoder())
          |> decode.map(fn(values) { json.array(values, fn(value) { value }) }),
        decode.dict(decode.string, raw_json_decoder())
          |> decode.map(fn(fields) { fields |> dict.to_list |> json.object }),
      ]),
    )
    |> decode.map(fn(value) { option.unwrap(value, json.null()) })
  })
}

// =====================================================================
//                                User
// =====================================================================

/// A Telegram user or bot, plus recoverable raw fields for schema evolution.
pub type User {
  User(
    id: Int,
    is_bot: Bool,
    first_name: String,
    last_name: Option(String),
    username: Option(String),
    language_code: Option(String),
    is_premium: Option(Bool),
    added_to_attachment_menu: Option(Bool),
    can_join_groups: Option(Bool),
    can_read_all_group_messages: Option(Bool),
    supports_inline_queries: Option(Bool),
    can_connect_to_business: Option(Bool),
    has_main_web_app: Option(Bool),
    supports_guest_queries: Option(Bool),
    has_topics_enabled: Option(Bool),
    allows_users_to_create_topics: Option(Bool),
    can_manage_bots: Option(Bool),
    supports_join_request_queries: Option(Bool),
    raw: Option(RawObject),
  )
}

/// Decode a Telegram `User` value from JSON.
pub fn user_decoder() -> Decoder(User) {
  use raw_payload <- decode.then(decode.dynamic)
  use id <- decode.field("id", decode.int)
  use is_bot <- decode.field("is_bot", decode.bool)
  use first_name <- decode.field("first_name", decode.string)
  use last_name <- json_utils.opt_str("last_name")
  use username <- json_utils.opt_str("username")
  use language_code <- json_utils.opt_str("language_code")
  use is_premium <- json_utils.opt_bool("is_premium")
  use added_to_attachment_menu <- json_utils.opt_bool(
    "added_to_attachment_menu",
  )
  use can_join_groups <- json_utils.opt_bool("can_join_groups")
  use can_read_all_group_messages <- json_utils.opt_bool(
    "can_read_all_group_messages",
  )
  use supports_inline_queries <- json_utils.opt_bool("supports_inline_queries")
  use can_connect_to_business <- json_utils.opt_bool("can_connect_to_business")
  use has_main_web_app <- json_utils.opt_bool("has_main_web_app")
  use supports_guest_queries <- json_utils.opt_bool("supports_guest_queries")
  use has_topics_enabled <- json_utils.opt_bool("has_topics_enabled")
  use allows_users_to_create_topics <- json_utils.opt_bool(
    "allows_users_to_create_topics",
  )
  use can_manage_bots <- json_utils.opt_bool("can_manage_bots")
  use supports_join_request_queries <- json_utils.opt_bool(
    "supports_join_request_queries",
  )
  decode.success(User(
    id:,
    is_bot:,
    first_name:,
    last_name:,
    username:,
    language_code:,
    is_premium:,
    added_to_attachment_menu:,
    can_join_groups:,
    can_read_all_group_messages:,
    supports_inline_queries:,
    can_connect_to_business:,
    has_main_web_app:,
    supports_guest_queries:,
    has_topics_enabled:,
    allows_users_to_create_topics:,
    can_manage_bots:,
    supports_join_request_queries:,
    raw: Some(RawObject(raw_payload)),
  ))
}

// =====================================================================
//                                Chat
// =====================================================================

/// Telegram's chat-kind discriminator, retaining unknown future values.
pub type ChatType {
  Private
  Group
  Supergroup
  Channel
  UnknownChatType(String)
}

/// Decode a Telegram `ChatType` value from JSON.
pub fn chat_type_decoder() -> Decoder(ChatType) {
  use raw <- decode.then(decode.string)
  case raw {
    "private" -> decode.success(Private)
    "group" -> decode.success(Group)
    "supergroup" -> decode.success(Supergroup)
    "channel" -> decode.success(Channel)
    other -> decode.success(UnknownChatType(other))
  }
}

/// A Telegram chat, plus recoverable raw fields for schema evolution.
pub type Chat {
  Chat(
    id: Int,
    type_: ChatType,
    title: Option(String),
    username: Option(String),
    first_name: Option(String),
    last_name: Option(String),
    is_forum: Option(Bool),
    is_direct_messages: Option(Bool),
    raw: Option(RawObject),
  )
}

/// Decode a Telegram `Chat` value from JSON.
pub fn chat_decoder() -> Decoder(Chat) {
  use raw_payload <- decode.then(decode.dynamic)
  use id <- decode.field("id", decode.int)
  use type_ <- decode.field("type", chat_type_decoder())
  use title <- json_utils.opt_str("title")
  use username <- json_utils.opt_str("username")
  use first_name <- json_utils.opt_str("first_name")
  use last_name <- json_utils.opt_str("last_name")
  use is_forum <- json_utils.opt_bool("is_forum")
  use is_direct_messages <- json_utils.opt_bool("is_direct_messages")
  decode.success(Chat(
    id:,
    type_:,
    title:,
    username:,
    first_name:,
    last_name:,
    is_forum:,
    is_direct_messages:,
    raw: Some(RawObject(raw_payload)),
  ))
}

// =====================================================================
//                              ChatPhoto
// =====================================================================

/// File identifiers for a chat's small and large profile photos.
pub type ChatPhoto {
  ChatPhoto(
    small_file_id: String,
    small_file_unique_id: String,
    big_file_id: String,
    big_file_unique_id: String,
  )
}

/// Decode a Telegram `ChatPhoto` value from JSON.
pub fn chat_photo_decoder() -> Decoder(ChatPhoto) {
  use small_file_id <- decode.field("small_file_id", decode.string)
  use small_file_unique_id <- decode.field(
    "small_file_unique_id",
    decode.string,
  )
  use big_file_id <- decode.field("big_file_id", decode.string)
  use big_file_unique_id <- decode.field("big_file_unique_id", decode.string)
  decode.success(ChatPhoto(
    small_file_id:,
    small_file_unique_id:,
    big_file_id:,
    big_file_unique_id:,
  ))
}

// =====================================================================
//                           ChatPermissions
// =====================================================================

/// Optional permissions for a Telegram chat member or default chat policy.
pub type ChatPermissions {
  ChatPermissions(
    can_send_messages: Option(Bool),
    can_send_audios: Option(Bool),
    can_send_documents: Option(Bool),
    can_send_photos: Option(Bool),
    can_send_videos: Option(Bool),
    can_send_video_notes: Option(Bool),
    can_send_voice_notes: Option(Bool),
    can_send_polls: Option(Bool),
    can_send_other_messages: Option(Bool),
    can_add_web_page_previews: Option(Bool),
    can_change_info: Option(Bool),
    can_invite_users: Option(Bool),
    can_pin_messages: Option(Bool),
    can_manage_topics: Option(Bool),
    can_react_to_messages: Option(Bool),
    can_edit_tag: Option(Bool),
  )
}

/// Build an empty permission set for record-update configuration.
pub fn default_chat_permissions() -> ChatPermissions {
  ChatPermissions(
    can_send_messages: None,
    can_send_audios: None,
    can_send_documents: None,
    can_send_photos: None,
    can_send_videos: None,
    can_send_video_notes: None,
    can_send_voice_notes: None,
    can_send_polls: None,
    can_send_other_messages: None,
    can_add_web_page_previews: None,
    can_change_info: None,
    can_invite_users: None,
    can_pin_messages: None,
    can_manage_topics: None,
    can_react_to_messages: None,
    can_edit_tag: None,
  )
}

/// Decode a Telegram `ChatPermissions` value from JSON.
pub fn chat_permissions_decoder() -> Decoder(ChatPermissions) {
  use can_send_messages <- json_utils.opt_bool("can_send_messages")
  use can_send_audios <- json_utils.opt_bool("can_send_audios")
  use can_send_documents <- json_utils.opt_bool("can_send_documents")
  use can_send_photos <- json_utils.opt_bool("can_send_photos")
  use can_send_videos <- json_utils.opt_bool("can_send_videos")
  use can_send_video_notes <- json_utils.opt_bool("can_send_video_notes")
  use can_send_voice_notes <- json_utils.opt_bool("can_send_voice_notes")
  use can_send_polls <- json_utils.opt_bool("can_send_polls")
  use can_send_other_messages <- json_utils.opt_bool("can_send_other_messages")
  use can_add_web_page_previews <- json_utils.opt_bool(
    "can_add_web_page_previews",
  )
  use can_change_info <- json_utils.opt_bool("can_change_info")
  use can_invite_users <- json_utils.opt_bool("can_invite_users")
  use can_pin_messages <- json_utils.opt_bool("can_pin_messages")
  use can_manage_topics <- json_utils.opt_bool("can_manage_topics")
  use can_react_to_messages <- json_utils.opt_bool("can_react_to_messages")
  use can_edit_tag <- json_utils.opt_bool("can_edit_tag")
  decode.success(ChatPermissions(
    can_send_messages:,
    can_send_audios:,
    can_send_documents:,
    can_send_photos:,
    can_send_videos:,
    can_send_video_notes:,
    can_send_voice_notes:,
    can_send_polls:,
    can_send_other_messages:,
    can_add_web_page_previews:,
    can_change_info:,
    can_invite_users:,
    can_pin_messages:,
    can_manage_topics:,
    can_react_to_messages:,
    can_edit_tag:,
  ))
}

/// Encode outbound chat permissions for administration methods.
pub fn chat_permissions_to_json(permissions: ChatPermissions) -> json.Json {
  json.object(
    []
    |> json_utils.put_optional(
      "can_send_messages",
      permissions.can_send_messages,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_send_audios",
      permissions.can_send_audios,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_send_documents",
      permissions.can_send_documents,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_send_photos",
      permissions.can_send_photos,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_send_videos",
      permissions.can_send_videos,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_send_video_notes",
      permissions.can_send_video_notes,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_send_voice_notes",
      permissions.can_send_voice_notes,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_send_polls",
      permissions.can_send_polls,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_send_other_messages",
      permissions.can_send_other_messages,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_add_web_page_previews",
      permissions.can_add_web_page_previews,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_change_info",
      permissions.can_change_info,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_invite_users",
      permissions.can_invite_users,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_pin_messages",
      permissions.can_pin_messages,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_manage_topics",
      permissions.can_manage_topics,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_react_to_messages",
      permissions.can_react_to_messages,
      json.bool,
    )
    |> json_utils.put_optional(
      "can_edit_tag",
      permissions.can_edit_tag,
      json.bool,
    ),
  )
}

// =====================================================================
//                       Media — Photo / Document / …
// =====================================================================

/// One available size of a Telegram photo or thumbnail.
pub type PhotoSize {
  PhotoSize(
    file_id: String,
    file_unique_id: String,
    width: Int,
    height: Int,
    file_size: Option(Int),
  )
}

/// Decode a Telegram `PhotoSize` value from JSON.
pub fn photo_size_decoder() -> Decoder(PhotoSize) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  use file_size <- json_utils.opt_int("file_size")
  decode.success(PhotoSize(
    file_id:,
    file_unique_id:,
    width:,
    height:,
    file_size:,
  ))
}

/// A general file sent through Telegram.
pub type Document {
  Document(
    file_id: String,
    file_unique_id: String,
    thumbnail: Option(PhotoSize),
    file_name: Option(String),
    mime_type: Option(String),
    file_size: Option(Int),
  )
}

/// Decode a Telegram `Document` value from JSON.
pub fn document_decoder() -> Decoder(Document) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use thumbnail <- json_utils.opt_nested("thumbnail", photo_size_decoder())
  use file_name <- json_utils.opt_str("file_name")
  use mime_type <- json_utils.opt_str("mime_type")
  use file_size <- json_utils.opt_int("file_size")
  decode.success(Document(
    file_id:,
    file_unique_id:,
    thumbnail:,
    file_name:,
    mime_type:,
    file_size:,
  ))
}

/// An audio file Telegram treats as music.
pub type Audio {
  Audio(
    file_id: String,
    file_unique_id: String,
    duration: Int,
    performer: Option(String),
    title: Option(String),
    file_name: Option(String),
    mime_type: Option(String),
    file_size: Option(Int),
    thumbnail: Option(PhotoSize),
  )
}

/// Decode a Telegram `Audio` value from JSON.
pub fn audio_decoder() -> Decoder(Audio) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use duration <- decode.field("duration", decode.int)
  use performer <- json_utils.opt_str("performer")
  use title <- json_utils.opt_str("title")
  use file_name <- json_utils.opt_str("file_name")
  use mime_type <- json_utils.opt_str("mime_type")
  use file_size <- json_utils.opt_int("file_size")
  use thumbnail <- json_utils.opt_nested("thumbnail", photo_size_decoder())
  decode.success(Audio(
    file_id:,
    file_unique_id:,
    duration:,
    performer:,
    title:,
    file_name:,
    mime_type:,
    file_size:,
    thumbnail:,
  ))
}

/// A Telegram voice message.
pub type Voice {
  Voice(
    file_id: String,
    file_unique_id: String,
    duration: Int,
    mime_type: Option(String),
    file_size: Option(Int),
  )
}

/// Decode a Telegram `Voice` value from JSON.
pub fn voice_decoder() -> Decoder(Voice) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use duration <- decode.field("duration", decode.int)
  use mime_type <- json_utils.opt_str("mime_type")
  use file_size <- json_utils.opt_int("file_size")
  decode.success(Voice(
    file_id:,
    file_unique_id:,
    duration:,
    mime_type:,
    file_size:,
  ))
}

/// A Telegram video file and its display metadata.
pub type Video {
  Video(
    file_id: String,
    file_unique_id: String,
    width: Int,
    height: Int,
    duration: Int,
    thumbnail: Option(PhotoSize),
    file_name: Option(String),
    mime_type: Option(String),
    file_size: Option(Int),
  )
}

/// Decode a Telegram `Video` value from JSON.
pub fn video_decoder() -> Decoder(Video) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  use duration <- decode.field("duration", decode.int)
  use thumbnail <- json_utils.opt_nested("thumbnail", photo_size_decoder())
  use file_name <- json_utils.opt_str("file_name")
  use mime_type <- json_utils.opt_str("mime_type")
  use file_size <- json_utils.opt_int("file_size")
  decode.success(Video(
    file_id:,
    file_unique_id:,
    width:,
    height:,
    duration:,
    thumbnail:,
    file_name:,
    mime_type:,
    file_size:,
  ))
}

/// A rounded-square Telegram video note.
pub type VideoNote {
  VideoNote(
    file_id: String,
    file_unique_id: String,
    length: Int,
    duration: Int,
    thumbnail: Option(PhotoSize),
    file_size: Option(Int),
  )
}

/// Decode a Telegram `VideoNote` value from JSON.
pub fn video_note_decoder() -> Decoder(VideoNote) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use length <- decode.field("length", decode.int)
  use duration <- decode.field("duration", decode.int)
  use thumbnail <- json_utils.opt_nested("thumbnail", photo_size_decoder())
  use file_size <- json_utils.opt_int("file_size")
  decode.success(VideoNote(
    file_id:,
    file_unique_id:,
    length:,
    duration:,
    thumbnail:,
    file_size:,
  ))
}

/// A GIF or silent H.264/MPEG-4 animation.
pub type Animation {
  Animation(
    file_id: String,
    file_unique_id: String,
    width: Int,
    height: Int,
    duration: Int,
    thumbnail: Option(PhotoSize),
    file_name: Option(String),
    mime_type: Option(String),
    file_size: Option(Int),
  )
}

/// Decode a Telegram `Animation` value from JSON.
pub fn animation_decoder() -> Decoder(Animation) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  use duration <- decode.field("duration", decode.int)
  use thumbnail <- json_utils.opt_nested("thumbnail", photo_size_decoder())
  use file_name <- json_utils.opt_str("file_name")
  use mime_type <- json_utils.opt_str("mime_type")
  use file_size <- json_utils.opt_int("file_size")
  decode.success(Animation(
    file_id:,
    file_unique_id:,
    width:,
    height:,
    duration:,
    thumbnail:,
    file_name:,
    mime_type:,
    file_size:,
  ))
}

// =====================================================================
//                           Sticker
// =====================================================================

/// Telegram's sticker-kind discriminator, retaining unknown future values.
pub type StickerType {
  RegularSticker
  MaskSticker
  CustomEmojiSticker
  UnknownStickerType(String)
}

/// Decode a Telegram `StickerType` value from JSON.
pub fn sticker_type_decoder() -> Decoder(StickerType) {
  use raw <- decode.then(decode.string)
  case raw {
    "regular" -> decode.success(RegularSticker)
    "mask" -> decode.success(MaskSticker)
    "custom_emoji" -> decode.success(CustomEmojiSticker)
    other -> decode.success(UnknownStickerType(other))
  }
}

/// Placement and scale of a mask sticker on a face.
pub type MaskPosition {
  MaskPosition(point: String, x_shift: Float, y_shift: Float, scale: Float)
}

/// Decode a Telegram `MaskPosition` value from JSON.
pub fn mask_position_decoder() -> Decoder(MaskPosition) {
  use point <- decode.field("point", decode.string)
  use x_shift <- decode.field("x_shift", decode.float)
  use y_shift <- decode.field("y_shift", decode.float)
  use scale <- decode.field("scale", decode.float)
  decode.success(MaskPosition(point:, x_shift:, y_shift:, scale:))
}

/// A Telegram sticker and its format-specific metadata.
pub type Sticker {
  Sticker(
    file_id: String,
    file_unique_id: String,
    type_: StickerType,
    width: Int,
    height: Int,
    is_animated: Bool,
    is_video: Bool,
    thumbnail: Option(PhotoSize),
    emoji: Option(String),
    set_name: Option(String),
    premium_animation: Option(File),
    mask_position: Option(MaskPosition),
    custom_emoji_id: Option(String),
    needs_repainting: Option(Bool),
    file_size: Option(Int),
  )
}

/// Decode a Telegram `Sticker` value from JSON.
pub fn sticker_decoder() -> Decoder(Sticker) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use type_ <- decode.field("type", sticker_type_decoder())
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  use is_animated <- decode.field("is_animated", decode.bool)
  use is_video <- decode.field("is_video", decode.bool)
  use thumbnail <- json_utils.opt_nested("thumbnail", photo_size_decoder())
  use emoji <- json_utils.opt_str("emoji")
  use set_name <- json_utils.opt_str("set_name")
  use premium_animation <- json_utils.opt_nested(
    "premium_animation",
    file_decoder(),
  )
  use mask_position <- json_utils.opt_nested(
    "mask_position",
    mask_position_decoder(),
  )
  use custom_emoji_id <- json_utils.opt_str("custom_emoji_id")
  use needs_repainting <- json_utils.opt_bool("needs_repainting")
  use file_size <- json_utils.opt_int("file_size")
  decode.success(Sticker(
    file_id:,
    file_unique_id:,
    type_:,
    width:,
    height:,
    is_animated:,
    is_video:,
    thumbnail:,
    emoji:,
    set_name:,
    premium_animation:,
    mask_position:,
    custom_emoji_id:,
    needs_repainting:,
    file_size:,
  ))
}

// =====================================================================
//                  Location / Venue / Contact / Dice
// =====================================================================

/// A geographic point and optional live-location metadata.
pub type Location {
  Location(
    longitude: Float,
    latitude: Float,
    horizontal_accuracy: Option(Float),
    live_period: Option(Int),
    heading: Option(Int),
    proximity_alert_radius: Option(Int),
  )
}

/// Decode a Telegram `Location` value from JSON.
pub fn location_decoder() -> Decoder(Location) {
  use longitude <- decode.field("longitude", decode.float)
  use latitude <- decode.field("latitude", decode.float)
  use horizontal_accuracy <- json_utils.opt_float("horizontal_accuracy")
  use live_period <- json_utils.opt_int("live_period")
  use heading <- json_utils.opt_int("heading")
  use proximity_alert_radius <- json_utils.opt_int("proximity_alert_radius")
  decode.success(Location(
    longitude:,
    latitude:,
    horizontal_accuracy:,
    live_period:,
    heading:,
    proximity_alert_radius:,
  ))
}

/// A named place at a geographic location.
pub type Venue {
  Venue(
    location: Location,
    title: String,
    address: String,
    foursquare_id: Option(String),
    foursquare_type: Option(String),
    google_place_id: Option(String),
    google_place_type: Option(String),
  )
}

/// Decode a Telegram `Venue` value from JSON.
pub fn venue_decoder() -> Decoder(Venue) {
  use location <- decode.field("location", location_decoder())
  use title <- decode.field("title", decode.string)
  use address <- decode.field("address", decode.string)
  use foursquare_id <- json_utils.opt_str("foursquare_id")
  use foursquare_type <- json_utils.opt_str("foursquare_type")
  use google_place_id <- json_utils.opt_str("google_place_id")
  use google_place_type <- json_utils.opt_str("google_place_type")
  decode.success(Venue(
    location:,
    title:,
    address:,
    foursquare_id:,
    foursquare_type:,
    google_place_id:,
    google_place_type:,
  ))
}

/// A phone contact shared in a Telegram message.
pub type Contact {
  Contact(
    phone_number: String,
    first_name: String,
    last_name: Option(String),
    user_id: Option(Int),
    vcard: Option(String),
  )
}

/// Decode a Telegram `Contact` value from JSON.
pub fn contact_decoder() -> Decoder(Contact) {
  use phone_number <- decode.field("phone_number", decode.string)
  use first_name <- decode.field("first_name", decode.string)
  use last_name <- json_utils.opt_str("last_name")
  use user_id <- json_utils.opt_int("user_id")
  use vcard <- json_utils.opt_str("vcard")
  decode.success(Contact(
    phone_number:,
    first_name:,
    last_name:,
    user_id:,
    vcard:,
  ))
}

/// The emoji and generated value of an animated Telegram dice.
pub type Dice {
  Dice(emoji: String, value: Int)
}

/// Decode a Telegram `Dice` value from JSON.
pub fn dice_decoder() -> Decoder(Dice) {
  use emoji <- decode.field("emoji", decode.string)
  use value <- decode.field("value", decode.int)
  decode.success(Dice(emoji:, value:))
}

// =====================================================================
//                         Poll / PollAnswer
// =====================================================================

/// A poll kind decoded from Telegram, including future unknown values.
pub type PollKind {
  /// A regular non-quiz poll.
  RegularPoll
  /// A quiz with correct answers.
  QuizPoll
  /// A newer Telegram value not known to this package version.
  UnknownPollKind(String)
}

/// Render a decoded poll kind. Outbound endpoints use their own finite types.
pub fn poll_kind_to_string(kind: PollKind) -> String {
  case kind {
    RegularPoll -> "regular"
    QuizPoll -> "quiz"
    UnknownPollKind(value) -> value
  }
}

/// Decode a forward-compatible Telegram poll kind.
pub fn poll_kind_decoder() -> Decoder(PollKind) {
  use value <- decode.then(decode.string)
  case value {
    "regular" -> decode.success(RegularPoll)
    "quiz" -> decode.success(QuizPoll)
    other -> decode.success(UnknownPollKind(other))
  }
}

/// A finite poll kind for request-poll reply-keyboard buttons.
///
/// Sending a poll uses `api.SendPoll`, which owns both its validated options
/// and the required correct option identifiers for quizzes.
pub type InputPollKind {
  /// Ask the user to create a regular non-quiz poll.
  RegularInputPoll
  /// Ask the user to create a quiz poll.
  QuizInputPoll
}

/// Render a reply-keyboard poll request kind for Telegram.
pub fn input_poll_kind_to_string(kind: InputPollKind) -> String {
  case kind {
    RegularInputPoll -> "regular"
    QuizInputPoll -> "quiz"
  }
}

/// A Telegram-compatible plain-text outbound poll question.
///
/// Keeping the constructor private prevents empty or overlong questions from
/// reaching `api.send_poll`. Parsed text and explicit entity lists remain
/// available through `api.prepare_json_call` until outbound poll entities are
/// modelled; validating source markup would not prove Telegram's post-parse
/// length and non-blank constraints.
pub opaque type PollQuestion {
  PollQuestion(text: String)
}

/// Why a string could not be used as a Telegram poll question.
pub type PollQuestionError {
  EmptyPollQuestion
  PollQuestionTooLong(length: Int)
}

/// Build a non-blank plain poll question of at most 300 Unicode codepoints.
pub fn poll_question(text: String) -> Result(PollQuestion, PollQuestionError) {
  validated_poll_question(text)
}

fn validated_poll_question(
  text: String,
) -> Result(PollQuestion, PollQuestionError) {
  case telegram_plain_text_is_blank(text) {
    True -> Error(EmptyPollQuestion)
    False ->
      case unicode_codepoint_length(text) {
        length if length > 300 -> Error(PollQuestionTooLong(length))
        _ -> Ok(PollQuestion(text:))
      }
  }
}

/// Reveal a validated poll question for Bot API transport.
pub fn poll_question_text(question: PollQuestion) -> String {
  question.text
}

/// One validated plain-text outbound poll option. Parsed text, optional media,
/// and explicit entity lists remain available through `api.prepare_json_call`
/// until their full typed graph is represented.
pub opaque type InputPollOption {
  InputPollOption(text: String)
}

/// Why a string could not be used as a Telegram poll option.
pub type InputPollOptionError {
  EmptyPollOptionText
  PollOptionTextTooLong(length: Int)
}

/// Create a non-blank plain poll option of at most 100 Unicode codepoints.
pub fn input_poll_option(
  text: String,
) -> Result(InputPollOption, InputPollOptionError) {
  validated_input_poll_option(text)
}

fn validated_input_poll_option(
  text: String,
) -> Result(InputPollOption, InputPollOptionError) {
  case telegram_plain_text_is_blank(text) {
    True -> Error(EmptyPollOptionText)
    False ->
      case unicode_codepoint_length(text) {
        length if length > 100 -> Error(PollOptionTextTooLong(length))
        _ -> Ok(InputPollOption(text:))
      }
  }
}

// TDLib's `clean_input_string` and final `is_empty_string` check jointly treat
// this exact set as empty. Using `string.trim` would both miss Telegram-empty
// characters and reject some Unicode whitespace that Telegram accepts.
fn telegram_plain_text_is_blank(text: String) -> Bool {
  text
  |> string.to_utf_codepoints
  |> list.all(fn(codepoint) {
    let value = string.utf_codepoint_to_int(codepoint)
    let is_unicode_space_or_zero_width = value >= 0x2000 && value <= 0x200F
    let is_line_or_narrow_space = value >= 0x2028 && value <= 0x202F
    let is_tag_character = value >= 0xE0000 && value <= 0xE007F
    value <= 0x20
    || value == 0x00A0
    || value == 0x030A
    || value == 0x0333
    || value == 0x033F
    || value == 0x1680
    || value == 0x180E
    || is_unicode_space_or_zero_width
    || is_line_or_narrow_space
    || value == 0x205F
    || value == 0x2800
    || value == 0x3000
    || value == 0xFEFF
    || value == 0xFFFC
    || is_tag_character
  })
}

fn unicode_codepoint_length(text: String) -> Int {
  text |> string.to_utf_codepoints |> list.length
}

/// Encode an outbound poll option.
pub fn input_poll_option_to_json(option: InputPollOption) -> json.Json {
  json.object([#("text", json.string(option.text))])
}

/// A validated non-empty collection for `sendPoll` (one to twelve options).
pub opaque type InputPollOptions {
  InputPollOptions(List(InputPollOption))
}

/// Why a collection cannot be sent as Telegram poll options.
pub type InputPollOptionsError {
  /// Telegram requires at least one option.
  NoPollOptions
  /// Telegram accepts no more than twelve options.
  TooManyPollOptions(Int)
}

/// Validate the one-to-twelve option boundary required by Bot API 10.2.
pub fn input_poll_options(
  options: List(InputPollOption),
) -> Result(InputPollOptions, InputPollOptionsError) {
  case list.length(options) {
    0 -> Error(NoPollOptions)
    count if count > 12 -> Error(TooManyPollOptions(count))
    _ -> Ok(InputPollOptions(options))
  }
}

/// Read validated poll options without exposing their constructor.
pub fn input_poll_options_to_list(
  options: InputPollOptions,
) -> List(InputPollOption) {
  let InputPollOptions(items) = options
  items
}

/// One decoded poll option with its forward-compatible raw payload.
pub type PollOption {
  PollOption(
    persistent_id: String,
    text: String,
    voter_count: Int,
    raw: Option(RawObject),
  )
}

/// Decode a Telegram `PollOption` value from JSON.
pub fn poll_option_decoder() -> Decoder(PollOption) {
  use raw_payload <- decode.then(decode.dynamic)
  use persistent_id <- decode.field("persistent_id", decode.string)
  use text <- decode.field("text", decode.string)
  use voter_count <- decode.field("voter_count", decode.int)
  decode.success(PollOption(
    persistent_id:,
    text:,
    voter_count:,
    raw: Some(RawObject(raw_payload)),
  ))
}

/// A decoded Telegram poll.
pub type Poll {
  Poll(
    id: String,
    question: String,
    options: List(PollOption),
    total_voter_count: Int,
    is_closed: Bool,
    is_anonymous: Bool,
    kind: PollKind,
    allows_multiple_answers: Bool,
    allows_revoting: Bool,
    members_only: Bool,
    country_codes: Option(List(String)),
    correct_option_ids: Option(List(Int)),
    explanation: Option(String),
    open_period: Option(Int),
    close_date: Option(Int),
    raw: Option(RawObject),
  )
}

/// Decode a Telegram `Poll` value from JSON.
pub fn poll_decoder() -> Decoder(Poll) {
  use raw_payload <- decode.then(decode.dynamic)
  use id <- decode.field("id", decode.string)
  use question <- decode.field("question", decode.string)
  use options <- decode.field("options", decode.list(poll_option_decoder()))
  use total_voter_count <- decode.field("total_voter_count", decode.int)
  use is_closed <- decode.field("is_closed", decode.bool)
  use is_anonymous <- decode.field("is_anonymous", decode.bool)
  use kind <- decode.field("type", poll_kind_decoder())
  use allows_multiple_answers <- decode.field(
    "allows_multiple_answers",
    decode.bool,
  )
  use allows_revoting <- decode.field("allows_revoting", decode.bool)
  use members_only <- decode.field("members_only", decode.bool)
  use country_codes <- decode.optional_field(
    "country_codes",
    None,
    decode.map(decode.list(decode.string), Some),
  )
  use correct_option_ids <- decode.optional_field(
    "correct_option_ids",
    None,
    decode.map(decode.list(decode.int), Some),
  )
  use explanation <- json_utils.opt_str("explanation")
  use open_period <- json_utils.opt_int("open_period")
  use close_date <- json_utils.opt_int("close_date")
  decode.success(Poll(
    id:,
    question:,
    options:,
    total_voter_count:,
    is_closed:,
    is_anonymous:,
    kind:,
    allows_multiple_answers:,
    allows_revoting:,
    members_only:,
    country_codes:,
    correct_option_ids:,
    explanation:,
    open_period:,
    close_date:,
    raw: Some(RawObject(raw_payload)),
  ))
}

/// A decoded poll answer with stable and persistent option identifiers.
pub type PollAnswer {
  PollAnswer(
    poll_id: String,
    voter_chat: Option(Chat),
    user: Option(User),
    option_ids: List(Int),
    option_persistent_ids: List(String),
    raw: Option(RawObject),
  )
}

/// Decode a Telegram `PollAnswer` value from JSON.
pub fn poll_answer_decoder() -> Decoder(PollAnswer) {
  use raw_payload <- decode.then(decode.dynamic)
  use poll_id <- decode.field("poll_id", decode.string)
  use voter_chat <- json_utils.opt_nested("voter_chat", chat_decoder())
  use user <- json_utils.opt_nested("user", user_decoder())
  use option_ids <- decode.field("option_ids", decode.list(decode.int))
  use option_persistent_ids <- decode.field(
    "option_persistent_ids",
    decode.list(decode.string),
  )
  decode.success(PollAnswer(
    poll_id:,
    voter_chat:,
    user:,
    option_ids:,
    option_persistent_ids:,
    raw: Some(RawObject(raw_payload)),
  ))
}

// =====================================================================
//                       MessageEntity
// =====================================================================

/// A formatted or semantic UTF-16 range inside message text.
///
/// `unix_time` and `date_time_format` are populated for `date_time` entities.
pub type MessageEntity {
  MessageEntity(
    type_: String,
    offset: Int,
    length: Int,
    url: Option(String),
    user: Option(User),
    language: Option(String),
    custom_emoji_id: Option(String),
    unix_time: Option(Int),
    date_time_format: Option(String),
  )
}

/// Decode a Telegram `MessageEntity` value from JSON.
pub fn message_entity_decoder() -> Decoder(MessageEntity) {
  use type_ <- decode.field("type", decode.string)
  use offset <- decode.field("offset", decode.int)
  use length <- decode.field("length", decode.int)
  use url <- json_utils.opt_str("url")
  use user <- json_utils.opt_nested("user", user_decoder())
  use language <- json_utils.opt_str("language")
  use custom_emoji_id <- json_utils.opt_str("custom_emoji_id")
  use unix_time <- json_utils.opt_int("unix_time")
  use date_time_format <- json_utils.opt_str("date_time_format")
  decode.success(MessageEntity(
    type_:,
    offset:,
    length:,
    url:,
    user:,
    language:,
    custom_emoji_id:,
    unix_time:,
    date_time_format:,
  ))
}

// =====================================================================
//                       ReactionType / Reactions
// =====================================================================

/// A message reaction, retaining unknown future Telegram reaction kinds.
pub type ReactionType {
  ReactionEmoji(emoji: String)
  ReactionCustomEmoji(custom_emoji_id: String)
  ReactionPaid
  UnknownReactionType(type_: String, payload: Dynamic)
}

/// Decode a Telegram `ReactionType` value from JSON.
pub fn reaction_type_decoder() -> Decoder(ReactionType) {
  use payload <- decode.then(decode.dynamic)
  use type_ <- decode.field("type", decode.string)
  case type_ {
    "emoji" -> {
      use emoji <- decode.field("emoji", decode.string)
      decode.success(ReactionEmoji(emoji:))
    }
    "custom_emoji" -> {
      use custom_emoji_id <- decode.field("custom_emoji_id", decode.string)
      decode.success(ReactionCustomEmoji(custom_emoji_id:))
    }
    "paid" -> decode.success(ReactionPaid)
    other -> decode.success(UnknownReactionType(type_: other, payload:))
  }
}

/// Aggregate count for one reaction kind on a message.
pub type ReactionCount {
  ReactionCount(type_: ReactionType, total_count: Int)
}

/// Decode a Telegram `ReactionCount` value from JSON.
pub fn reaction_count_decoder() -> Decoder(ReactionCount) {
  use type_ <- decode.field("type", reaction_type_decoder())
  use total_count <- decode.field("total_count", decode.int)
  decode.success(ReactionCount(type_:, total_count:))
}

/// A user's or chat's reaction change on one message.
pub type MessageReactionUpdated {
  MessageReactionUpdated(
    chat: Chat,
    message_id: Int,
    user: Option(User),
    actor_chat: Option(Chat),
    date: Int,
    old_reaction: List(ReactionType),
    new_reaction: List(ReactionType),
  )
}

/// Decode a Telegram `MessageReactionUpdated` value from JSON.
pub fn message_reaction_updated_decoder() -> Decoder(MessageReactionUpdated) {
  use chat <- decode.field("chat", chat_decoder())
  use message_id <- decode.field("message_id", decode.int)
  use user <- json_utils.opt_nested("user", user_decoder())
  use actor_chat <- json_utils.opt_nested("actor_chat", chat_decoder())
  use date <- decode.field("date", decode.int)
  use old_reaction <- decode.field(
    "old_reaction",
    decode.list(reaction_type_decoder()),
  )
  use new_reaction <- decode.field(
    "new_reaction",
    decode.list(reaction_type_decoder()),
  )
  decode.success(MessageReactionUpdated(
    chat:,
    message_id:,
    user:,
    actor_chat:,
    date:,
    old_reaction:,
    new_reaction:,
  ))
}

/// Updated anonymous reaction totals for one message.
pub type MessageReactionCountUpdated {
  MessageReactionCountUpdated(
    chat: Chat,
    message_id: Int,
    date: Int,
    reactions: List(ReactionCount),
  )
}

/// Decode a Telegram `MessageReactionCountUpdated` value from JSON.
pub fn message_reaction_count_updated_decoder() -> Decoder(
  MessageReactionCountUpdated,
) {
  use chat <- decode.field("chat", chat_decoder())
  use message_id <- decode.field("message_id", decode.int)
  use date <- decode.field("date", decode.int)
  use reactions <- decode.field(
    "reactions",
    decode.list(reaction_count_decoder()),
  )
  decode.success(MessageReactionCountUpdated(
    chat:,
    message_id:,
    date:,
    reactions:,
  ))
}

// =====================================================================
//                    Payments — Invoice / SuccessfulPayment / …
// =====================================================================

/// Invoice summary attached to a Telegram message.
pub type Invoice {
  Invoice(
    title: String,
    description: String,
    start_parameter: String,
    currency: String,
    total_amount: Int,
  )
}

/// Decode a Telegram `Invoice` value from JSON.
pub fn invoice_decoder() -> Decoder(Invoice) {
  use title <- decode.field("title", decode.string)
  use description <- decode.field("description", decode.string)
  use start_parameter <- decode.field("start_parameter", decode.string)
  use currency <- decode.field("currency", decode.string)
  use total_amount <- decode.field("total_amount", decode.int)
  decode.success(Invoice(
    title:,
    description:,
    start_parameter:,
    currency:,
    total_amount:,
  ))
}

/// Delivery address supplied by a Telegram user.
pub type ShippingAddress {
  ShippingAddress(
    country_code: String,
    state: String,
    city: String,
    street_line1: String,
    street_line2: String,
    post_code: String,
  )
}

/// Decode a Telegram `ShippingAddress` value from JSON.
pub fn shipping_address_decoder() -> Decoder(ShippingAddress) {
  use country_code <- decode.field("country_code", decode.string)
  use state <- decode.field("state", decode.string)
  use city <- decode.field("city", decode.string)
  use street_line1 <- decode.field("street_line1", decode.string)
  use street_line2 <- decode.field("street_line2", decode.string)
  use post_code <- decode.field("post_code", decode.string)
  decode.success(ShippingAddress(
    country_code:,
    state:,
    city:,
    street_line1:,
    street_line2:,
    post_code:,
  ))
}

/// Optional customer and delivery details collected for an order.
pub type OrderInfo {
  OrderInfo(
    name: Option(String),
    phone_number: Option(String),
    email: Option(String),
    shipping_address: Option(ShippingAddress),
  )
}

/// Decode a Telegram `OrderInfo` value from JSON.
pub fn order_info_decoder() -> Decoder(OrderInfo) {
  use name <- json_utils.opt_str("name")
  use phone_number <- json_utils.opt_str("phone_number")
  use email <- json_utils.opt_str("email")
  use shipping_address <- json_utils.opt_nested(
    "shipping_address",
    shipping_address_decoder(),
  )
  decode.success(OrderInfo(name:, phone_number:, email:, shipping_address:))
}

/// Payment details Telegram sends after a successful checkout.
pub type SuccessfulPayment {
  SuccessfulPayment(
    currency: String,
    total_amount: Int,
    invoice_payload: String,
    subscription_expiration_date: Option(Int),
    is_recurring: Option(Bool),
    is_first_recurring: Option(Bool),
    shipping_option_id: Option(String),
    order_info: Option(OrderInfo),
    telegram_payment_charge_id: String,
    provider_payment_charge_id: String,
  )
}

/// Decode a Telegram `SuccessfulPayment` value from JSON.
pub fn successful_payment_decoder() -> Decoder(SuccessfulPayment) {
  use currency <- decode.field("currency", decode.string)
  use total_amount <- decode.field("total_amount", decode.int)
  use invoice_payload <- decode.field("invoice_payload", decode.string)
  use subscription_expiration_date <- json_utils.opt_int(
    "subscription_expiration_date",
  )
  use is_recurring <- json_utils.opt_bool("is_recurring")
  use is_first_recurring <- json_utils.opt_bool("is_first_recurring")
  use shipping_option_id <- json_utils.opt_str("shipping_option_id")
  use order_info <- json_utils.opt_nested("order_info", order_info_decoder())
  use telegram_payment_charge_id <- decode.field(
    "telegram_payment_charge_id",
    decode.string,
  )
  use provider_payment_charge_id <- decode.field(
    "provider_payment_charge_id",
    decode.string,
  )
  decode.success(SuccessfulPayment(
    currency:,
    total_amount:,
    invoice_payload:,
    subscription_expiration_date:,
    is_recurring:,
    is_first_recurring:,
    shipping_option_id:,
    order_info:,
    telegram_payment_charge_id:,
    provider_payment_charge_id:,
  ))
}

/// Details of a payment refunded through Telegram.
pub type RefundedPayment {
  RefundedPayment(
    currency: String,
    total_amount: Int,
    invoice_payload: String,
    telegram_payment_charge_id: String,
    provider_payment_charge_id: Option(String),
  )
}

/// Decode a Telegram `RefundedPayment` value from JSON.
pub fn refunded_payment_decoder() -> Decoder(RefundedPayment) {
  use currency <- decode.field("currency", decode.string)
  use total_amount <- decode.field("total_amount", decode.int)
  use invoice_payload <- decode.field("invoice_payload", decode.string)
  use telegram_payment_charge_id <- decode.field(
    "telegram_payment_charge_id",
    decode.string,
  )
  use provider_payment_charge_id <- json_utils.opt_str(
    "provider_payment_charge_id",
  )
  decode.success(RefundedPayment(
    currency:,
    total_amount:,
    invoice_payload:,
    telegram_payment_charge_id:,
    provider_payment_charge_id:,
  ))
}

/// A request to choose delivery options for an invoice.
pub type ShippingQuery {
  ShippingQuery(
    id: String,
    from: User,
    invoice_payload: String,
    shipping_address: ShippingAddress,
  )
}

/// Decode a Telegram `ShippingQuery` value from JSON.
pub fn shipping_query_decoder() -> Decoder(ShippingQuery) {
  use id <- decode.field("id", decode.string)
  use from <- decode.field("from", user_decoder())
  use invoice_payload <- decode.field("invoice_payload", decode.string)
  use shipping_address <- decode.field(
    "shipping_address",
    shipping_address_decoder(),
  )
  decode.success(ShippingQuery(id:, from:, invoice_payload:, shipping_address:))
}

/// Telegram's final validation request before completing a payment.
pub type PreCheckoutQuery {
  PreCheckoutQuery(
    id: String,
    from: User,
    currency: String,
    total_amount: Int,
    invoice_payload: String,
    shipping_option_id: Option(String),
    order_info: Option(OrderInfo),
  )
}

/// Decode a Telegram `PreCheckoutQuery` value from JSON.
pub fn pre_checkout_query_decoder() -> Decoder(PreCheckoutQuery) {
  use id <- decode.field("id", decode.string)
  use from <- decode.field("from", user_decoder())
  use currency <- decode.field("currency", decode.string)
  use total_amount <- decode.field("total_amount", decode.int)
  use invoice_payload <- decode.field("invoice_payload", decode.string)
  use shipping_option_id <- json_utils.opt_str("shipping_option_id")
  use order_info <- json_utils.opt_nested("order_info", order_info_decoder())
  decode.success(PreCheckoutQuery(
    id:,
    from:,
    currency:,
    total_amount:,
    invoice_payload:,
    shipping_option_id:,
    order_info:,
  ))
}

/// Notification that a user purchased paid media from the bot.
pub type PaidMediaPurchased {
  PaidMediaPurchased(from: User, paid_media_payload: String)
}

/// Decode a Telegram `PaidMediaPurchased` value from JSON.
pub fn paid_media_purchased_decoder() -> Decoder(PaidMediaPurchased) {
  use from <- decode.field("from", user_decoder())
  use paid_media_payload <- decode.field("paid_media_payload", decode.string)
  decode.success(PaidMediaPurchased(from:, paid_media_payload:))
}

// =====================================================================
//                  Chat members / invite links / joins
// =====================================================================

/// A member's status and permissions, retaining unknown future statuses.
pub type ChatMember {
  ChatMemberOwner(user: User, is_anonymous: Bool, custom_title: Option(String))
  ChatMemberAdministrator(
    user: User,
    can_be_edited: Bool,
    is_anonymous: Bool,
    can_manage_chat: Bool,
    can_delete_messages: Bool,
    can_manage_video_chats: Bool,
    can_restrict_members: Bool,
    can_promote_members: Bool,
    can_change_info: Bool,
    can_invite_users: Bool,
    can_post_messages: Option(Bool),
    can_edit_messages: Option(Bool),
    can_pin_messages: Option(Bool),
    can_post_stories: Bool,
    can_edit_stories: Bool,
    can_delete_stories: Bool,
    can_manage_topics: Option(Bool),
    can_manage_direct_messages: Option(Bool),
    can_manage_tags: Option(Bool),
    custom_title: Option(String),
  )
  ChatMemberMember(user: User, until_date: Option(Int), tag: Option(String))
  ChatMemberRestricted(
    user: User,
    is_member: Bool,
    can_send_messages: Bool,
    can_send_audios: Bool,
    can_send_documents: Bool,
    can_send_photos: Bool,
    can_send_videos: Bool,
    can_send_video_notes: Bool,
    can_send_voice_notes: Bool,
    can_send_polls: Bool,
    can_send_other_messages: Bool,
    can_add_web_page_previews: Bool,
    can_react_to_messages: Bool,
    can_edit_tag: Bool,
    can_change_info: Bool,
    can_invite_users: Bool,
    can_pin_messages: Bool,
    can_manage_topics: Bool,
    until_date: Int,
    tag: Option(String),
  )
  ChatMemberLeft(user: User)
  ChatMemberBanned(user: User, until_date: Int)
  UnknownChatMember(status: String, payload: Dynamic)
}

/// Decode a Telegram `ChatMember` value from JSON.
pub fn chat_member_decoder() -> Decoder(ChatMember) {
  use payload <- decode.then(decode.dynamic)
  use status <- decode.field("status", decode.string)
  case status {
    "creator" -> {
      use user <- decode.field("user", user_decoder())
      use is_anonymous <- decode.field("is_anonymous", decode.bool)
      use custom_title <- json_utils.opt_str("custom_title")
      decode.success(ChatMemberOwner(user:, is_anonymous:, custom_title:))
    }
    "administrator" -> {
      use user <- decode.field("user", user_decoder())
      use can_be_edited <- decode.field("can_be_edited", decode.bool)
      use is_anonymous <- decode.field("is_anonymous", decode.bool)
      use can_manage_chat <- decode.field("can_manage_chat", decode.bool)
      use can_delete_messages <- decode.field(
        "can_delete_messages",
        decode.bool,
      )
      use can_manage_video_chats <- decode.field(
        "can_manage_video_chats",
        decode.bool,
      )
      use can_restrict_members <- decode.field(
        "can_restrict_members",
        decode.bool,
      )
      use can_promote_members <- decode.field(
        "can_promote_members",
        decode.bool,
      )
      use can_change_info <- decode.field("can_change_info", decode.bool)
      use can_invite_users <- decode.field("can_invite_users", decode.bool)
      use can_post_messages <- json_utils.opt_bool("can_post_messages")
      use can_edit_messages <- json_utils.opt_bool("can_edit_messages")
      use can_pin_messages <- json_utils.opt_bool("can_pin_messages")
      use can_post_stories <- decode.field("can_post_stories", decode.bool)
      use can_edit_stories <- decode.field("can_edit_stories", decode.bool)
      use can_delete_stories <- decode.field("can_delete_stories", decode.bool)
      use can_manage_topics <- json_utils.opt_bool("can_manage_topics")
      use can_manage_direct_messages <- json_utils.opt_bool(
        "can_manage_direct_messages",
      )
      use can_manage_tags <- json_utils.opt_bool("can_manage_tags")
      use custom_title <- json_utils.opt_str("custom_title")
      decode.success(ChatMemberAdministrator(
        user:,
        can_be_edited:,
        is_anonymous:,
        can_manage_chat:,
        can_delete_messages:,
        can_manage_video_chats:,
        can_restrict_members:,
        can_promote_members:,
        can_change_info:,
        can_invite_users:,
        can_post_messages:,
        can_edit_messages:,
        can_pin_messages:,
        can_post_stories:,
        can_edit_stories:,
        can_delete_stories:,
        can_manage_topics:,
        can_manage_direct_messages:,
        can_manage_tags:,
        custom_title:,
      ))
    }
    "member" -> {
      use user <- decode.field("user", user_decoder())
      use until_date <- json_utils.opt_int("until_date")
      use tag <- json_utils.opt_str("tag")
      decode.success(ChatMemberMember(user:, until_date:, tag:))
    }
    "restricted" -> {
      use user <- decode.field("user", user_decoder())
      use is_member <- decode.field("is_member", decode.bool)
      use can_send_messages <- decode.field("can_send_messages", decode.bool)
      use can_send_audios <- decode.field("can_send_audios", decode.bool)
      use can_send_documents <- decode.field("can_send_documents", decode.bool)
      use can_send_photos <- decode.field("can_send_photos", decode.bool)
      use can_send_videos <- decode.field("can_send_videos", decode.bool)
      use can_send_video_notes <- decode.field(
        "can_send_video_notes",
        decode.bool,
      )
      use can_send_voice_notes <- decode.field(
        "can_send_voice_notes",
        decode.bool,
      )
      use can_send_polls <- decode.field("can_send_polls", decode.bool)
      use can_send_other_messages <- decode.field(
        "can_send_other_messages",
        decode.bool,
      )
      use can_add_web_page_previews <- decode.field(
        "can_add_web_page_previews",
        decode.bool,
      )
      use can_react_to_messages <- decode.field(
        "can_react_to_messages",
        decode.bool,
      )
      use can_edit_tag <- decode.field("can_edit_tag", decode.bool)
      use can_change_info <- decode.field("can_change_info", decode.bool)
      use can_invite_users <- decode.field("can_invite_users", decode.bool)
      use can_pin_messages <- decode.field("can_pin_messages", decode.bool)
      use can_manage_topics <- decode.field("can_manage_topics", decode.bool)
      use until_date <- decode.field("until_date", decode.int)
      use tag <- json_utils.opt_str("tag")
      decode.success(ChatMemberRestricted(
        user:,
        is_member:,
        can_send_messages:,
        can_send_audios:,
        can_send_documents:,
        can_send_photos:,
        can_send_videos:,
        can_send_video_notes:,
        can_send_voice_notes:,
        can_send_polls:,
        can_send_other_messages:,
        can_add_web_page_previews:,
        can_react_to_messages:,
        can_edit_tag:,
        can_change_info:,
        can_invite_users:,
        can_pin_messages:,
        can_manage_topics:,
        until_date:,
        tag:,
      ))
    }
    "left" -> {
      use user <- decode.field("user", user_decoder())
      decode.success(ChatMemberLeft(user:))
    }
    "kicked" -> {
      use user <- decode.field("user", user_decoder())
      use until_date <- decode.field("until_date", decode.int)
      decode.success(ChatMemberBanned(user:, until_date:))
    }
    other -> decode.success(UnknownChatMember(status: other, payload:))
  }
}

/// A Telegram chat invite link and its admission constraints.
pub type ChatInviteLink {
  ChatInviteLink(
    invite_link: String,
    creator: User,
    creates_join_request: Bool,
    is_primary: Bool,
    is_revoked: Bool,
    name: Option(String),
    expire_date: Option(Int),
    member_limit: Option(Int),
    pending_join_request_count: Option(Int),
    subscription_period: Option(Int),
    subscription_price: Option(Int),
  )
}

/// Decode a Telegram `ChatInviteLink` value from JSON.
pub fn chat_invite_link_decoder() -> Decoder(ChatInviteLink) {
  use invite_link <- decode.field("invite_link", decode.string)
  use creator <- decode.field("creator", user_decoder())
  use creates_join_request <- decode.field("creates_join_request", decode.bool)
  use is_primary <- decode.field("is_primary", decode.bool)
  use is_revoked <- decode.field("is_revoked", decode.bool)
  use name <- json_utils.opt_str("name")
  use expire_date <- json_utils.opt_int("expire_date")
  use member_limit <- json_utils.opt_int("member_limit")
  use pending_join_request_count <- json_utils.opt_int(
    "pending_join_request_count",
  )
  use subscription_period <- json_utils.opt_int("subscription_period")
  use subscription_price <- json_utils.opt_int("subscription_price")
  decode.success(ChatInviteLink(
    invite_link:,
    creator:,
    creates_join_request:,
    is_primary:,
    is_revoked:,
    name:,
    expire_date:,
    member_limit:,
    pending_join_request_count:,
    subscription_period:,
    subscription_price:,
  ))
}

/// A transition between old and new chat-member states.
pub type ChatMemberUpdated {
  ChatMemberUpdated(
    chat: Chat,
    from: User,
    date: Int,
    old_chat_member: ChatMember,
    new_chat_member: ChatMember,
    invite_link: Option(ChatInviteLink),
    via_join_request: Option(Bool),
    via_chat_folder_invite_link: Option(Bool),
  )
}

/// Decode a Telegram `ChatMemberUpdated` value from JSON.
pub fn chat_member_updated_decoder() -> Decoder(ChatMemberUpdated) {
  use chat <- decode.field("chat", chat_decoder())
  use from <- decode.field("from", user_decoder())
  use date <- decode.field("date", decode.int)
  use old_chat_member <- decode.field("old_chat_member", chat_member_decoder())
  use new_chat_member <- decode.field("new_chat_member", chat_member_decoder())
  use invite_link <- json_utils.opt_nested(
    "invite_link",
    chat_invite_link_decoder(),
  )
  use via_join_request <- json_utils.opt_bool("via_join_request")
  use via_chat_folder_invite_link <- json_utils.opt_bool(
    "via_chat_folder_invite_link",
  )
  decode.success(ChatMemberUpdated(
    chat:,
    from:,
    date:,
    old_chat_member:,
    new_chat_member:,
    invite_link:,
    via_join_request:,
    via_chat_folder_invite_link:,
  ))
}

/// A user's pending request to join a chat.
pub type ChatJoinRequest {
  ChatJoinRequest(
    chat: Chat,
    from: User,
    user_chat_id: Int,
    date: Int,
    bio: Option(String),
    invite_link: Option(ChatInviteLink),
    query_id: Option(String),
  )
}

/// Decode a Telegram `ChatJoinRequest` value from JSON.
pub fn chat_join_request_decoder() -> Decoder(ChatJoinRequest) {
  use chat <- decode.field("chat", chat_decoder())
  use from <- decode.field("from", user_decoder())
  use user_chat_id <- decode.field("user_chat_id", decode.int)
  use date <- decode.field("date", decode.int)
  use bio <- json_utils.opt_str("bio")
  use invite_link <- json_utils.opt_nested(
    "invite_link",
    chat_invite_link_decoder(),
  )
  use query_id <- json_utils.opt_str("query_id")
  decode.success(ChatJoinRequest(
    chat:,
    from:,
    user_chat_id:,
    date:,
    bio:,
    invite_link:,
    query_id:,
  ))
}

// =====================================================================
//                       Chat boosts
// =====================================================================

/// The origin of a chat boost, retaining unknown future source kinds.
pub type ChatBoostSource {
  ChatBoostSourcePremium(user: User)
  ChatBoostSourceGiftCode(user: User)
  ChatBoostSourceGiveaway(
    giveaway_message_id: Int,
    user: Option(User),
    prize_star_count: Option(Int),
    is_unclaimed: Option(Bool),
  )
  UnknownChatBoostSource(source: String, payload: Dynamic)
}

/// Decode a Telegram `ChatBoostSource` value from JSON.
pub fn chat_boost_source_decoder() -> Decoder(ChatBoostSource) {
  use payload <- decode.then(decode.dynamic)
  use source <- decode.field("source", decode.string)
  case source {
    "premium" -> {
      use user <- decode.field("user", user_decoder())
      decode.success(ChatBoostSourcePremium(user:))
    }
    "gift_code" -> {
      use user <- decode.field("user", user_decoder())
      decode.success(ChatBoostSourceGiftCode(user:))
    }
    "giveaway" -> {
      use giveaway_message_id <- decode.field("giveaway_message_id", decode.int)
      use user <- json_utils.opt_nested("user", user_decoder())
      use prize_star_count <- json_utils.opt_int("prize_star_count")
      use is_unclaimed <- json_utils.opt_bool("is_unclaimed")
      decode.success(ChatBoostSourceGiveaway(
        giveaway_message_id:,
        user:,
        prize_star_count:,
        is_unclaimed:,
      ))
    }
    other -> decode.success(UnknownChatBoostSource(source: other, payload:))
  }
}

/// One active or historical boost and its validity interval.
pub type ChatBoost {
  ChatBoost(
    boost_id: String,
    add_date: Int,
    expiration_date: Int,
    source: ChatBoostSource,
  )
}

/// Decode a Telegram `ChatBoost` value from JSON.
pub fn chat_boost_decoder() -> Decoder(ChatBoost) {
  use boost_id <- decode.field("boost_id", decode.string)
  use add_date <- decode.field("add_date", decode.int)
  use expiration_date <- decode.field("expiration_date", decode.int)
  use source <- decode.field("source", chat_boost_source_decoder())
  decode.success(ChatBoost(boost_id:, add_date:, expiration_date:, source:))
}

/// Notification that a chat boost was added or changed.
pub type ChatBoostUpdated {
  ChatBoostUpdated(chat: Chat, boost: ChatBoost)
}

/// Decode a Telegram `ChatBoostUpdated` value from JSON.
pub fn chat_boost_updated_decoder() -> Decoder(ChatBoostUpdated) {
  use chat <- decode.field("chat", chat_decoder())
  use boost <- decode.field("boost", chat_boost_decoder())
  decode.success(ChatBoostUpdated(chat:, boost:))
}

/// Notification that a boost was removed from a chat.
pub type ChatBoostRemoved {
  ChatBoostRemoved(
    chat: Chat,
    boost_id: String,
    remove_date: Int,
    source: ChatBoostSource,
  )
}

/// Decode a Telegram `ChatBoostRemoved` value from JSON.
pub fn chat_boost_removed_decoder() -> Decoder(ChatBoostRemoved) {
  use chat <- decode.field("chat", chat_decoder())
  use boost_id <- decode.field("boost_id", decode.string)
  use remove_date <- decode.field("remove_date", decode.int)
  use source <- decode.field("source", chat_boost_source_decoder())
  decode.success(ChatBoostRemoved(chat:, boost_id:, remove_date:, source:))
}

// =====================================================================
//                     Business connection / deletion
// =====================================================================

/// Rights granted to a bot connected to a Telegram Business account.
pub type BusinessBotRights {
  BusinessBotRights(
    can_reply: Option(Bool),
    can_read_messages: Option(Bool),
    can_delete_sent_messages: Option(Bool),
    can_delete_all_messages: Option(Bool),
    can_edit_name: Option(Bool),
    can_edit_bio: Option(Bool),
    can_edit_profile_photo: Option(Bool),
    can_edit_username: Option(Bool),
    can_change_gift_settings: Option(Bool),
    can_view_gifts_and_stars: Option(Bool),
    can_convert_gifts_to_stars: Option(Bool),
    can_transfer_and_upgrade_gifts: Option(Bool),
    can_transfer_stars: Option(Bool),
    can_manage_stories: Option(Bool),
  )
}

/// Decode Telegram `BusinessBotRights` from JSON.
pub fn business_bot_rights_decoder() -> Decoder(BusinessBotRights) {
  use can_reply <- json_utils.opt_bool("can_reply")
  use can_read_messages <- json_utils.opt_bool("can_read_messages")
  use can_delete_sent_messages <- json_utils.opt_bool(
    "can_delete_sent_messages",
  )
  use can_delete_all_messages <- json_utils.opt_bool("can_delete_all_messages")
  use can_edit_name <- json_utils.opt_bool("can_edit_name")
  use can_edit_bio <- json_utils.opt_bool("can_edit_bio")
  use can_edit_profile_photo <- json_utils.opt_bool("can_edit_profile_photo")
  use can_edit_username <- json_utils.opt_bool("can_edit_username")
  use can_change_gift_settings <- json_utils.opt_bool(
    "can_change_gift_settings",
  )
  use can_view_gifts_and_stars <- json_utils.opt_bool(
    "can_view_gifts_and_stars",
  )
  use can_convert_gifts_to_stars <- json_utils.opt_bool(
    "can_convert_gifts_to_stars",
  )
  use can_transfer_and_upgrade_gifts <- json_utils.opt_bool(
    "can_transfer_and_upgrade_gifts",
  )
  use can_transfer_stars <- json_utils.opt_bool("can_transfer_stars")
  use can_manage_stories <- json_utils.opt_bool("can_manage_stories")
  decode.success(BusinessBotRights(
    can_reply:,
    can_read_messages:,
    can_delete_sent_messages:,
    can_delete_all_messages:,
    can_edit_name:,
    can_edit_bio:,
    can_edit_profile_photo:,
    can_edit_username:,
    can_change_gift_settings:,
    can_view_gifts_and_stars:,
    can_convert_gifts_to_stars:,
    can_transfer_and_upgrade_gifts:,
    can_transfer_stars:,
    can_manage_stories:,
  ))
}

/// A connection between a bot and a Telegram Business account.
pub type BusinessConnection {
  BusinessConnection(
    id: String,
    user: User,
    user_chat_id: Int,
    date: Int,
    rights: Option(BusinessBotRights),
    is_enabled: Bool,
  )
}

/// Decode a Telegram `BusinessConnection` value from JSON.
pub fn business_connection_decoder() -> Decoder(BusinessConnection) {
  use id <- decode.field("id", decode.string)
  use user <- decode.field("user", user_decoder())
  use user_chat_id <- decode.field("user_chat_id", decode.int)
  use date <- decode.field("date", decode.int)
  use rights <- json_utils.opt_nested("rights", business_bot_rights_decoder())
  use is_enabled <- decode.field("is_enabled", decode.bool)
  decode.success(BusinessConnection(
    id:,
    user:,
    user_chat_id:,
    date:,
    rights:,
    is_enabled:,
  ))
}

/// Message identifiers deleted from a connected business chat.
pub type BusinessMessagesDeleted {
  BusinessMessagesDeleted(
    business_connection_id: String,
    chat: Chat,
    message_ids: List(Int),
  )
}

/// Decode a Telegram `BusinessMessagesDeleted` value from JSON.
pub fn business_messages_deleted_decoder() -> Decoder(BusinessMessagesDeleted) {
  use business_connection_id <- decode.field(
    "business_connection_id",
    decode.string,
  )
  use chat <- decode.field("chat", chat_decoder())
  use message_ids <- decode.field("message_ids", decode.list(decode.int))
  decode.success(BusinessMessagesDeleted(
    business_connection_id:,
    chat:,
    message_ids:,
  ))
}

// =====================================================================
//                       File / LinkPreviewOptions
// =====================================================================

/// A downloadable Telegram file reference.
pub type File {
  File(
    file_id: String,
    file_unique_id: String,
    file_size: Option(Int),
    file_path: Option(String),
  )
}

/// Decode a Telegram `File` value from JSON.
pub fn file_decoder() -> Decoder(File) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use file_size <- json_utils.opt_int("file_size")
  use file_path <- json_utils.opt_str("file_path")
  decode.success(File(file_id:, file_unique_id:, file_size:, file_path:))
}

/// Fine-grained link preview policy for outbound and decoded messages.
pub type LinkPreviewOptions {
  LinkPreviewOptions(
    is_disabled: Option(Bool),
    url: Option(String),
    prefer_small_media: Option(Bool),
    prefer_large_media: Option(Bool),
    show_above_text: Option(Bool),
  )
}

/// Decode a Telegram `LinkPreviewOptions` value from JSON.
pub fn link_preview_options_decoder() -> Decoder(LinkPreviewOptions) {
  use is_disabled <- json_utils.opt_bool("is_disabled")
  use url <- json_utils.opt_str("url")
  use prefer_small_media <- json_utils.opt_bool("prefer_small_media")
  use prefer_large_media <- json_utils.opt_bool("prefer_large_media")
  use show_above_text <- json_utils.opt_bool("show_above_text")
  decode.success(LinkPreviewOptions(
    is_disabled:,
    url:,
    prefer_small_media:,
    prefer_large_media:,
    show_above_text:,
  ))
}

/// Encode outbound link preview options for message payloads.
pub fn link_preview_options_to_json(options: LinkPreviewOptions) -> json.Json {
  json.object(
    []
    |> json_utils.put_optional("is_disabled", options.is_disabled, json.bool)
    |> json_utils.put_optional("url", options.url, json.string)
    |> json_utils.put_optional(
      "prefer_small_media",
      options.prefer_small_media,
      json.bool,
    )
    |> json_utils.put_optional(
      "prefer_large_media",
      options.prefer_large_media,
      json.bool,
    )
    |> json_utils.put_optional(
      "show_above_text",
      options.show_above_text,
      json.bool,
    ),
  )
}

// =====================================================================
//                                Message
// =====================================================================

/// A Telegram message that may no longer be accessible to the bot.
///
/// Telegram identifies inaccessible messages with `date == 0`. The date is
/// intentionally absent from that constructor because its only valid value is
/// the discriminator itself.
pub type MaybeInaccessibleMessage {
  AccessibleMessage(Message)
  InaccessibleMessage(chat: Chat, message_id: Int)
}

/// `Message` is intentionally a *wide* record with most common fields
/// surfaced. We keep recursive references (`reply_to_message`) via
/// `decode.recursive` and pass through truly exotic fields (passport data,
/// game updates, etc.) through the captured `raw` object at the bottom.
pub type Message {
  Message(
    message_id: Int,
    message_thread_id: Option(Int),
    from: Option(User),
    sender_chat: Option(Chat),
    receiver_user: Option(User),
    ephemeral_message_id: Option(Int),
    guest_query_id: Option(String),
    guest_bot_caller_user: Option(User),
    guest_bot_caller_chat: Option(Chat),
    date: Int,
    edit_date: Option(Int),
    chat: Chat,
    forward_origin: Option(Dynamic),
    is_topic_message: Option(Bool),
    is_automatic_forward: Option(Bool),
    reply_to_message: Option(Message),
    via_bot: Option(User),
    has_protected_content: Option(Bool),
    media_group_id: Option(String),
    author_signature: Option(String),
    text: Option(String),
    entities: List(MessageEntity),
    link_preview_options: Option(LinkPreviewOptions),
    caption: Option(String),
    caption_entities: List(MessageEntity),
    show_caption_above_media: Option(Bool),
    has_media_spoiler: Option(Bool),
    photo: List(PhotoSize),
    document: Option(Document),
    audio: Option(Audio),
    voice: Option(Voice),
    video: Option(Video),
    video_note: Option(VideoNote),
    animation: Option(Animation),
    sticker: Option(Sticker),
    location: Option(Location),
    venue: Option(Venue),
    contact: Option(Contact),
    dice: Option(Dice),
    poll: Option(Poll),
    new_chat_members: List(User),
    left_chat_member: Option(User),
    new_chat_title: Option(String),
    new_chat_photo: List(PhotoSize),
    delete_chat_photo: Option(Bool),
    group_chat_created: Option(Bool),
    supergroup_chat_created: Option(Bool),
    channel_chat_created: Option(Bool),
    migrate_to_chat_id: Option(Int),
    migrate_from_chat_id: Option(Int),
    pinned_message: Option(MaybeInaccessibleMessage),
    invoice: Option(Invoice),
    successful_payment: Option(SuccessfulPayment),
    refunded_payment: Option(RefundedPayment),
    connected_website: Option(String),
    business_connection_id: Option(String),
    raw: Option(RawObject),
  )
}

/// Decode a Telegram `Message` value from JSON.
pub fn message_decoder() -> Decoder(Message) {
  use raw_payload <- decode.then(decode.dynamic)
  use message_id <- decode.field("message_id", decode.int)
  use message_thread_id <- json_utils.opt_int("message_thread_id")
  use from <- json_utils.opt_nested("from", user_decoder())
  use sender_chat <- json_utils.opt_nested("sender_chat", chat_decoder())
  use receiver_user <- json_utils.opt_nested("receiver_user", user_decoder())
  use ephemeral_message_id <- json_utils.opt_int("ephemeral_message_id")
  use guest_query_id <- json_utils.opt_str("guest_query_id")
  use guest_bot_caller_user <- json_utils.opt_nested(
    "guest_bot_caller_user",
    user_decoder(),
  )
  use guest_bot_caller_chat <- json_utils.opt_nested(
    "guest_bot_caller_chat",
    chat_decoder(),
  )
  use date <- decode.field("date", decode.int)
  use edit_date <- json_utils.opt_int("edit_date")
  use chat <- decode.field("chat", chat_decoder())
  use forward_origin <- json_utils.opt_nested("forward_origin", decode.dynamic)
  use is_topic_message <- json_utils.opt_bool("is_topic_message")
  use is_automatic_forward <- json_utils.opt_bool("is_automatic_forward")
  use reply_to_message <- json_utils.opt_nested(
    "reply_to_message",
    decode.recursive(message_decoder),
  )
  use via_bot <- json_utils.opt_nested("via_bot", user_decoder())
  use has_protected_content <- json_utils.opt_bool("has_protected_content")
  use media_group_id <- json_utils.opt_str("media_group_id")
  use author_signature <- json_utils.opt_str("author_signature")
  use text <- json_utils.opt_str("text")
  use entities <- json_utils.opt_list("entities", message_entity_decoder())
  use link_preview_options <- json_utils.opt_nested(
    "link_preview_options",
    link_preview_options_decoder(),
  )
  use caption <- json_utils.opt_str("caption")
  use caption_entities <- json_utils.opt_list(
    "caption_entities",
    message_entity_decoder(),
  )
  use show_caption_above_media <- json_utils.opt_bool(
    "show_caption_above_media",
  )
  use has_media_spoiler <- json_utils.opt_bool("has_media_spoiler")
  use photo <- json_utils.opt_list("photo", photo_size_decoder())
  use document <- json_utils.opt_nested("document", document_decoder())
  use audio <- json_utils.opt_nested("audio", audio_decoder())
  use voice <- json_utils.opt_nested("voice", voice_decoder())
  use video <- json_utils.opt_nested("video", video_decoder())
  use video_note <- json_utils.opt_nested("video_note", video_note_decoder())
  use animation <- json_utils.opt_nested("animation", animation_decoder())
  use sticker <- json_utils.opt_nested("sticker", sticker_decoder())
  use location <- json_utils.opt_nested("location", location_decoder())
  use venue <- json_utils.opt_nested("venue", venue_decoder())
  use contact <- json_utils.opt_nested("contact", contact_decoder())
  use dice <- json_utils.opt_nested("dice", dice_decoder())
  use poll <- json_utils.opt_nested("poll", poll_decoder())
  use new_chat_members <- json_utils.opt_list(
    "new_chat_members",
    user_decoder(),
  )
  use left_chat_member <- json_utils.opt_nested(
    "left_chat_member",
    user_decoder(),
  )
  use new_chat_title <- json_utils.opt_str("new_chat_title")
  use new_chat_photo <- json_utils.opt_list(
    "new_chat_photo",
    photo_size_decoder(),
  )
  use delete_chat_photo <- json_utils.opt_bool("delete_chat_photo")
  use group_chat_created <- json_utils.opt_bool("group_chat_created")
  use supergroup_chat_created <- json_utils.opt_bool("supergroup_chat_created")
  use channel_chat_created <- json_utils.opt_bool("channel_chat_created")
  use migrate_to_chat_id <- json_utils.opt_int("migrate_to_chat_id")
  use migrate_from_chat_id <- json_utils.opt_int("migrate_from_chat_id")
  use pinned_message <- json_utils.opt_nested(
    "pinned_message",
    maybe_inaccessible_message_decoder(),
  )
  use invoice <- json_utils.opt_nested("invoice", invoice_decoder())
  use successful_payment <- json_utils.opt_nested(
    "successful_payment",
    successful_payment_decoder(),
  )
  use refunded_payment <- json_utils.opt_nested(
    "refunded_payment",
    refunded_payment_decoder(),
  )
  use connected_website <- json_utils.opt_str("connected_website")
  use business_connection_id <- json_utils.opt_str("business_connection_id")
  decode.success(Message(
    message_id:,
    message_thread_id:,
    from:,
    sender_chat:,
    receiver_user:,
    ephemeral_message_id:,
    guest_query_id:,
    guest_bot_caller_user:,
    guest_bot_caller_chat:,
    date:,
    edit_date:,
    chat:,
    forward_origin:,
    is_topic_message:,
    is_automatic_forward:,
    reply_to_message:,
    via_bot:,
    has_protected_content:,
    media_group_id:,
    author_signature:,
    text:,
    entities:,
    link_preview_options:,
    caption:,
    caption_entities:,
    show_caption_above_media:,
    has_media_spoiler:,
    photo:,
    document:,
    audio:,
    voice:,
    video:,
    video_note:,
    animation:,
    sticker:,
    location:,
    venue:,
    contact:,
    dice:,
    poll:,
    new_chat_members:,
    left_chat_member:,
    new_chat_title:,
    new_chat_photo:,
    delete_chat_photo:,
    group_chat_created:,
    supergroup_chat_created:,
    channel_chat_created:,
    migrate_to_chat_id:,
    migrate_from_chat_id:,
    pinned_message:,
    invoice:,
    successful_payment:,
    refunded_payment:,
    connected_website:,
    business_connection_id:,
    raw: Some(RawObject(raw_payload)),
  ))
}

/// The durable identifier of a message sent in response to a guest query.
pub type SentGuestMessage {
  SentGuestMessage(inline_message_id: String)
}

/// Decode Telegram's `SentGuestMessage` response.
pub fn sent_guest_message_decoder() -> Decoder(SentGuestMessage) {
  use inline_message_id <- decode.field("inline_message_id", decode.string)
  decode.success(SentGuestMessage(inline_message_id:))
}

/// Decode either a regular `Message` or Telegram's minimal inaccessible shape.
pub fn maybe_inaccessible_message_decoder() -> Decoder(MaybeInaccessibleMessage) {
  use date <- decode.field("date", decode.int)
  case date {
    0 -> {
      use chat <- decode.field("chat", chat_decoder())
      use message_id <- decode.field("message_id", decode.int)
      decode.success(InaccessibleMessage(chat:, message_id:))
    }
    _ ->
      decode.map(decode.recursive(message_decoder), fn(message) {
        AccessibleMessage(message)
      })
  }
}

// =====================================================================
//                          CallbackQuery
// =====================================================================

/// The mutually-exclusive payload carried by a callback query.
pub type CallbackPayload {
  Data(String)
  Game(String)
}

/// An interaction with an inline-keyboard callback or game button.
///
/// The mandatory `payload` makes Telegram's exactly-one-of rule explicit.
pub type CallbackQuery {
  CallbackQuery(
    id: String,
    from: User,
    message: Option(MaybeInaccessibleMessage),
    chat_instance: String,
    payload: CallbackPayload,
    inline_message_id: Option(String),
  )
}

/// Decode the exactly-one-of callback payload invariant.
pub fn callback_payload_decoder() -> Decoder(CallbackPayload) {
  use data <- json_utils.opt_str("data")
  use game_short_name <- json_utils.opt_str("game_short_name")
  case data, game_short_name {
    Some(data), None -> decode.success(Data(data))
    None, Some(game_short_name) -> decode.success(Game(game_short_name))
    _, _ ->
      decode.failure(
        Data(""),
        "CallbackQuery with exactly one of data or game_short_name",
      )
  }
}

/// Decode a Telegram `CallbackQuery` value from JSON.
pub fn callback_query_decoder() -> Decoder(CallbackQuery) {
  use id <- decode.field("id", decode.string)
  use from <- decode.field("from", user_decoder())
  use message <- json_utils.opt_nested(
    "message",
    maybe_inaccessible_message_decoder(),
  )
  use chat_instance <- decode.field("chat_instance", decode.string)
  use payload <- decode.then(callback_payload_decoder())
  use inline_message_id <- json_utils.opt_str("inline_message_id")
  decode.success(CallbackQuery(
    id:,
    from:,
    message:,
    chat_instance:,
    payload:,
    inline_message_id:,
  ))
}

// =====================================================================
//                          InlineQuery
// =====================================================================

/// A user's inline-mode query addressed to the bot.
pub type InlineQuery {
  InlineQuery(
    id: String,
    from: User,
    query: String,
    offset: String,
    chat_type: Option(String),
    location: Option(Location),
  )
}

/// Decode a Telegram `InlineQuery` value from JSON.
pub fn inline_query_decoder() -> Decoder(InlineQuery) {
  use id <- decode.field("id", decode.string)
  use from <- decode.field("from", user_decoder())
  use query <- decode.field("query", decode.string)
  use offset <- decode.field("offset", decode.string)
  use chat_type <- json_utils.opt_str("chat_type")
  use location <- json_utils.opt_nested("location", location_decoder())
  decode.success(InlineQuery(id:, from:, query:, offset:, chat_type:, location:))
}

/// Notification that a user selected one of the bot's inline results.
pub type ChosenInlineResult {
  ChosenInlineResult(
    result_id: String,
    from: User,
    location: Option(Location),
    inline_message_id: Option(String),
    query: String,
  )
}

/// Decode a Telegram `ChosenInlineResult` value from JSON.
pub fn chosen_inline_result_decoder() -> Decoder(ChosenInlineResult) {
  use result_id <- decode.field("result_id", decode.string)
  use from <- decode.field("from", user_decoder())
  use location <- json_utils.opt_nested("location", location_decoder())
  use inline_message_id <- json_utils.opt_str("inline_message_id")
  use query <- decode.field("query", decode.string)
  decode.success(ChosenInlineResult(
    result_id:,
    from:,
    location:,
    inline_message_id:,
    query:,
  ))
}

// =====================================================================
//                                Update
// =====================================================================

/// A managed bot whose ownership or token state changed.
pub type ManagedBotUpdated {
  ManagedBotUpdated(user: User, bot: User)
}

/// Decode a Telegram `ManagedBotUpdated` value from JSON.
pub fn managed_bot_updated_decoder() -> Decoder(ManagedBotUpdated) {
  use user <- decode.field("user", user_decoder())
  use bot <- decode.field("bot", user_decoder())
  decode.success(ManagedBotUpdated(user:, bot:))
}

/// The documented lifecycle states of a bot payment subscription.
/// Unknown values are retained so a Telegram addition cannot poison polling.
pub type BotSubscriptionState {
  SubscriptionActive
  SubscriptionCanceled
  SubscriptionFailed
  UnknownSubscriptionState(String)
}

/// Decode a Telegram bot subscription state without rejecting future values.
pub fn bot_subscription_state_decoder() -> Decoder(BotSubscriptionState) {
  use state <- decode.then(decode.string)
  decode.success(case state {
    "active" -> SubscriptionActive
    "canceled" -> SubscriptionCanceled
    "failed" -> SubscriptionFailed
    unknown -> UnknownSubscriptionState(unknown)
  })
}

/// A change to a user's payment subscription toward the bot.
pub type BotSubscriptionUpdated {
  BotSubscriptionUpdated(
    user: User,
    invoice_payload: String,
    state: BotSubscriptionState,
  )
}

/// Decode a Telegram `BotSubscriptionUpdated` value from JSON.
pub fn bot_subscription_updated_decoder() -> Decoder(BotSubscriptionUpdated) {
  use user <- decode.field("user", user_decoder())
  use invoice_payload <- decode.field("invoice_payload", decode.string)
  use state <- decode.field("state", bot_subscription_state_decoder())
  decode.success(BotSubscriptionUpdated(user:, invoice_payload:, state:))
}

/// Raw payload for an update kind unknown to this glammy version.
///
/// The dynamic value stays opaque: callers can inspect it only by supplying a
/// typed decoder via `decode_raw_update`.
pub opaque type RawUpdate {
  RawUpdate(name: Option(String), payload: Dynamic, field_count: Int)
}

/// Telegram field name that carried this unknown update, when present.
pub fn raw_update_name(update: RawUpdate) -> Option(String) {
  update.name
}

/// Decode an unknown update payload into an application-owned type.
pub fn decode_raw_update(
  update: RawUpdate,
  decoder: Decoder(a),
) -> Result(a, List(decode.DecodeError)) {
  decode.run(update.payload, decoder)
}

/// All known top-level Update variants. We model every one Telegram
/// currently documents; unknown shapes fall through to `OtherUpdate` so
/// that the bot keeps polling even if Telegram introduces something new.
pub type UpdateKind {
  MessageUpdate(Message)
  EditedMessageUpdate(Message)
  ChannelPostUpdate(Message)
  EditedChannelPostUpdate(Message)
  BusinessConnectionUpdate(BusinessConnection)
  BusinessMessageUpdate(Message)
  EditedBusinessMessageUpdate(Message)
  DeletedBusinessMessagesUpdate(BusinessMessagesDeleted)
  GuestMessageUpdate(Message)
  MessageReactionUpdate(MessageReactionUpdated)
  MessageReactionCountUpdate(MessageReactionCountUpdated)
  InlineQueryUpdate(InlineQuery)
  ChosenInlineResultUpdate(ChosenInlineResult)
  CallbackQueryUpdate(CallbackQuery)
  ShippingQueryUpdate(ShippingQuery)
  PreCheckoutQueryUpdate(PreCheckoutQuery)
  PollUpdate(Poll)
  PollAnswerUpdate(PollAnswer)
  MyChatMemberUpdate(ChatMemberUpdated)
  ChatMemberUpdate(ChatMemberUpdated)
  ChatJoinRequestUpdate(ChatJoinRequest)
  ChatBoostUpdate(ChatBoostUpdated)
  RemovedChatBoostUpdate(ChatBoostRemoved)
  PurchasedPaidMediaUpdate(PaidMediaPurchased)
  ManagedBotUpdate(ManagedBotUpdated)
  SubscriptionUpdate(BotSubscriptionUpdated)
  OtherUpdate(RawUpdate)
}

/// One Telegram update with a monotonically increasing identifier.
pub type Update {
  Update(update_id: Int, kind: UpdateKind, raw: Option(RawObject))
}

/// Construct an application-owned update without an original JSON envelope.
pub fn new_update(update_id: Int, kind: UpdateKind) -> Update {
  Update(update_id:, kind:, raw: None)
}

/// Decode a Telegram `Update` value from JSON.
pub fn update_decoder() -> Decoder(Update) {
  use raw_payload <- decode.then(decode.dynamic)
  use update_id <- decode.field("update_id", decode.int)
  use kind <- decode.then(update_kind_decoder())
  decode.success(Update(update_id:, kind:, raw: Some(RawObject(raw_payload))))
}

/// Decoder helper for `update_kind_decoder`'s ~20 mutually-exclusive
/// optional envelope fields. Like `opt_nested`, but also wraps the decoded
/// value in its `UpdateKind` constructor right at the decode site, so the
/// constructor can't drift out of sync with the field it belongs to.
fn opt_update(
  key: String,
  decoder: Decoder(a),
  wrap: fn(a) -> UpdateKind,
  next: fn(Option(UpdateKind)) -> Decoder(t),
) -> Decoder(t) {
  decode.optional_field(
    key,
    None,
    decode.optional(decode.map(decoder, wrap)),
    next,
  )
}

fn update_kind_decoder() -> Decoder(UpdateKind) {
  use message <- opt_update("message", message_decoder(), MessageUpdate)
  use edited_message <- opt_update(
    "edited_message",
    message_decoder(),
    EditedMessageUpdate,
  )
  use channel_post <- opt_update(
    "channel_post",
    message_decoder(),
    ChannelPostUpdate,
  )
  use edited_channel_post <- opt_update(
    "edited_channel_post",
    message_decoder(),
    EditedChannelPostUpdate,
  )
  use business_connection <- opt_update(
    "business_connection",
    business_connection_decoder(),
    BusinessConnectionUpdate,
  )
  use business_message <- opt_update(
    "business_message",
    message_decoder(),
    BusinessMessageUpdate,
  )
  use edited_business_message <- opt_update(
    "edited_business_message",
    message_decoder(),
    EditedBusinessMessageUpdate,
  )
  use deleted_business_messages <- opt_update(
    "deleted_business_messages",
    business_messages_deleted_decoder(),
    DeletedBusinessMessagesUpdate,
  )
  use guest_message <- opt_update(
    "guest_message",
    message_decoder(),
    GuestMessageUpdate,
  )
  use message_reaction <- opt_update(
    "message_reaction",
    message_reaction_updated_decoder(),
    MessageReactionUpdate,
  )
  use message_reaction_count <- opt_update(
    "message_reaction_count",
    message_reaction_count_updated_decoder(),
    MessageReactionCountUpdate,
  )
  use inline_query <- opt_update(
    "inline_query",
    inline_query_decoder(),
    InlineQueryUpdate,
  )
  use chosen_inline_result <- opt_update(
    "chosen_inline_result",
    chosen_inline_result_decoder(),
    ChosenInlineResultUpdate,
  )
  use callback_query <- opt_update(
    "callback_query",
    callback_query_decoder(),
    CallbackQueryUpdate,
  )
  use shipping_query <- opt_update(
    "shipping_query",
    shipping_query_decoder(),
    ShippingQueryUpdate,
  )
  use pre_checkout_query <- opt_update(
    "pre_checkout_query",
    pre_checkout_query_decoder(),
    PreCheckoutQueryUpdate,
  )
  use poll <- opt_update("poll", poll_decoder(), PollUpdate)
  use poll_answer <- opt_update(
    "poll_answer",
    poll_answer_decoder(),
    PollAnswerUpdate,
  )
  use my_chat_member <- opt_update(
    "my_chat_member",
    chat_member_updated_decoder(),
    MyChatMemberUpdate,
  )
  use chat_member <- opt_update(
    "chat_member",
    chat_member_updated_decoder(),
    ChatMemberUpdate,
  )
  use chat_join_request <- opt_update(
    "chat_join_request",
    chat_join_request_decoder(),
    ChatJoinRequestUpdate,
  )
  use chat_boost <- opt_update(
    "chat_boost",
    chat_boost_updated_decoder(),
    ChatBoostUpdate,
  )
  use removed_chat_boost <- opt_update(
    "removed_chat_boost",
    chat_boost_removed_decoder(),
    RemovedChatBoostUpdate,
  )
  use purchased_paid_media <- opt_update(
    "purchased_paid_media",
    paid_media_purchased_decoder(),
    PurchasedPaidMediaUpdate,
  )
  use managed_bot <- opt_update(
    "managed_bot",
    managed_bot_updated_decoder(),
    ManagedBotUpdate,
  )
  use subscription <- opt_update(
    "subscription",
    bot_subscription_updated_decoder(),
    SubscriptionUpdate,
  )
  use raw_update <- decode.then(raw_update_decoder())

  // The Telegram envelope is "all variants optional, exactly one
  // present" — list each candidate in canonical order and pick the
  // first present one. `OtherUpdate` is the catch-all so the bot stays
  // robust against future Telegram additions. Constructors are now
  // applied at the decode site via `opt_update`, so this list only needs
  // to preserve ordering.
  let candidates = [
    message,
    edited_message,
    channel_post,
    edited_channel_post,
    business_connection,
    business_message,
    edited_business_message,
    deleted_business_messages,
    guest_message,
    message_reaction,
    message_reaction_count,
    inline_query,
    chosen_inline_result,
    callback_query,
    shipping_query,
    pre_checkout_query,
    poll,
    poll_answer,
    my_chat_member,
    chat_member,
    chat_join_request,
    chat_boost,
    removed_chat_boost,
    purchased_paid_media,
    managed_bot,
    subscription,
  ]
  let present =
    list.filter_map(candidates, fn(candidate) {
      option.to_result(candidate, Nil)
    })
  case present {
    [kind] -> decode.success(kind)
    [_, _, ..] ->
      decode.failure(
        OtherUpdate(raw_update),
        "Update with at most one recognised payload field",
      )
    [] if raw_update.field_count > 1 ->
      decode.failure(
        OtherUpdate(raw_update),
        "Update with at most one unknown payload field",
      )
    [] -> decode.success(OtherUpdate(raw_update))
  }
}

fn raw_update_decoder() -> Decoder(RawUpdate) {
  use fields <- decode.then(decode.dict(decode.string, decode.dynamic))
  let payload_fields = dict.delete(fields, "update_id")
  let unknown = payload_fields |> dict.to_list |> list.first
  case unknown {
    Ok(#(name, payload)) ->
      decode.success(RawUpdate(
        name: Some(name),
        payload:,
        field_count: dict.size(payload_fields),
      ))
    Error(Nil) ->
      decode.success(RawUpdate(
        name: None,
        payload: dynamic.nil(),
        field_count: 0,
      ))
  }
}

// =====================================================================
//                        ResponseParameters / ApiError
// =====================================================================

/// Optional recovery guidance attached to a Telegram API error.
pub type ResponseParameters {
  ResponseParameters(migrate_to_chat_id: Option(Int), retry_after: Option(Int))
}

/// Decode a Telegram `ResponseParameters` value from JSON.
pub fn response_parameters_decoder() -> Decoder(ResponseParameters) {
  use migrate_to_chat_id <- json_utils.opt_int("migrate_to_chat_id")
  use retry_after <- json_utils.opt_int("retry_after")
  decode.success(ResponseParameters(migrate_to_chat_id:, retry_after:))
}

// =====================================================================
//                          BotCommand / BotCommandScope
// =====================================================================

/// A validated command shown by Telegram's bot command menu.
pub opaque type BotCommand {
  BotCommand(command: String, description: String, is_ephemeral: Option(Bool))
}

/// Why an outbound bot command cannot be accepted by Telegram.
pub type BotCommandError {
  InvalidBotCommandLength(length: Int)
  InvalidBotCommandCharacter
  InvalidBotCommandDescriptionLength(length: Int)
}

/// Build a Bot API command with its 1–32 character alphabet and 1–256
/// codepoint description enforced locally.
pub fn bot_command(
  command: String,
  description: String,
  is_ephemeral: Option(Bool),
) -> Result(BotCommand, BotCommandError) {
  let command_length = unicode_codepoint_length(command)
  let description_length = unicode_codepoint_length(description)
  case command_length >= 1 && command_length <= 32 {
    False -> Error(InvalidBotCommandLength(command_length))
    True ->
      case
        command
        |> string.to_graphemes
        |> list.all(fn(character) {
          string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", character)
        })
      {
        False -> Error(InvalidBotCommandCharacter)
        True ->
          case description_length >= 1 && description_length <= 256 {
            False ->
              Error(InvalidBotCommandDescriptionLength(description_length))
            True -> Ok(BotCommand(command:, description:, is_ephemeral:))
          }
      }
  }
}

/// Decode a Telegram `BotCommand` value from JSON.
pub fn bot_command_decoder() -> Decoder(BotCommand) {
  use command <- decode.field("command", decode.string)
  use description <- decode.field("description", decode.string)
  use is_ephemeral <- json_utils.opt_bool("is_ephemeral")
  decode.success(BotCommand(command:, description:, is_ephemeral:))
}

/// Encode a command for `setMyCommands`.
pub fn bot_command_to_json(command: BotCommand) -> json.Json {
  json.object(
    [
      #("command", json.string(command.command)),
      #("description", json.string(command.description)),
    ]
    |> json_utils.put_optional("is_ephemeral", command.is_ephemeral, json.bool),
  )
}

/// A Bot API command list whose 100-command maximum is already proven.
pub opaque type BotCommands {
  BotCommands(values: List(BotCommand))
}

/// Why a command list cannot be sent to `setMyCommands`.
pub type BotCommandsError {
  TooManyBotCommands(count: Int)
}

/// Validate the zero-to-one-hundred command boundary used by Telegram.
///
/// An empty list is valid and clears the command list for the selected scope.
pub fn bot_commands(
  commands: List(BotCommand),
) -> Result(BotCommands, BotCommandsError) {
  case list.length(commands) <= 100 {
    True -> Ok(BotCommands(commands))
    False -> Error(TooManyBotCommands(list.length(commands)))
  }
}

/// Reveal a validated command list for Bot API transport.
pub fn bot_commands_to_list(commands: BotCommands) -> List(BotCommand) {
  let BotCommands(values) = commands
  values
}

/// A chat identifier accepted by command scopes.
pub type BotCommandScopeChatId {
  /// A numeric chat identifier.
  BotCommandScopeChatIntId(Int)
  /// A public supergroup or channel username such as `@channel`.
  BotCommandScopeChatUsername(String)
}

/// The audience whose command list is being configured.
pub type BotCommandScope {
  /// Commands used when no narrower scope matches.
  BotCommandScopeDefault
  /// Commands for all private chats.
  BotCommandScopeAllPrivateChats
  /// Commands for all group and supergroup chats.
  BotCommandScopeAllGroupChats
  /// Commands for administrators in all group chats.
  BotCommandScopeAllChatAdministrators
  /// Commands for every user in one chat.
  BotCommandScopeChat(chat_id: BotCommandScopeChatId)
  /// Commands for administrators in one chat.
  BotCommandScopeChatAdministrators(chat_id: BotCommandScopeChatId)
  /// Commands for one member of one chat.
  BotCommandScopeChatMember(chat_id: BotCommandScopeChatId, user_id: Int)
}

fn bot_command_scope_chat_id_to_json(
  chat_id: BotCommandScopeChatId,
) -> json.Json {
  case chat_id {
    BotCommandScopeChatIntId(value) -> json.int(value)
    BotCommandScopeChatUsername(value) -> json.string(value)
  }
}

/// Encode a command scope for Bot API command methods.
pub fn bot_command_scope_to_json(scope: BotCommandScope) -> json.Json {
  case scope {
    BotCommandScopeDefault -> json.object([#("type", json.string("default"))])
    BotCommandScopeAllPrivateChats ->
      json.object([#("type", json.string("all_private_chats"))])
    BotCommandScopeAllGroupChats ->
      json.object([#("type", json.string("all_group_chats"))])
    BotCommandScopeAllChatAdministrators ->
      json.object([#("type", json.string("all_chat_administrators"))])
    BotCommandScopeChat(chat_id:) ->
      json.object([
        #("type", json.string("chat")),
        #("chat_id", bot_command_scope_chat_id_to_json(chat_id)),
      ])
    BotCommandScopeChatAdministrators(chat_id:) ->
      json.object([
        #("type", json.string("chat_administrators")),
        #("chat_id", bot_command_scope_chat_id_to_json(chat_id)),
      ])
    BotCommandScopeChatMember(chat_id:, user_id:) ->
      json.object([
        #("type", json.string("chat_member")),
        #("chat_id", bot_command_scope_chat_id_to_json(chat_id)),
        #("user_id", json.int(user_id)),
      ])
  }
}

// =====================================================================
//                       BotInfo / WebhookInfo
// =====================================================================

/// Current webhook configuration and delivery health reported by Telegram.
pub type WebhookInfo {
  WebhookInfo(
    url: String,
    has_custom_certificate: Bool,
    pending_update_count: Int,
    ip_address: Option(String),
    last_error_date: Option(Int),
    last_error_message: Option(String),
    last_synchronization_error_date: Option(Int),
    max_connections: Option(Int),
    allowed_updates: List(String),
  )
}

/// Decode a Telegram `WebhookInfo` value from JSON.
pub fn webhook_info_decoder() -> Decoder(WebhookInfo) {
  use url <- decode.field("url", decode.string)
  use has_custom_certificate <- decode.field(
    "has_custom_certificate",
    decode.bool,
  )
  use pending_update_count <- decode.field("pending_update_count", decode.int)
  use ip_address <- json_utils.opt_str("ip_address")
  use last_error_date <- json_utils.opt_int("last_error_date")
  use last_error_message <- json_utils.opt_str("last_error_message")
  use last_synchronization_error_date <- json_utils.opt_int(
    "last_synchronization_error_date",
  )
  use max_connections <- json_utils.opt_int("max_connections")
  use allowed_updates <- json_utils.opt_list("allowed_updates", decode.string)
  decode.success(WebhookInfo(
    url:,
    has_custom_certificate:,
    pending_update_count:,
    ip_address:,
    last_error_date:,
    last_error_message:,
    last_synchronization_error_date:,
    max_connections:,
    allowed_updates:,
  ))
}
