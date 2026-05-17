//// Telegram Bot API types — ported from `@grammyjs/types` (the TypeScript
//// definitions used by grammY). Records here cover the bulk of the API
//// surface; truly exotic fields are passed through as `Dynamic` to keep
//// the type definitions manageable.
////
//// Every type has a matching `<type>_decoder()` function that returns a
//// `gleam/dynamic/decode.Decoder(t)`. Decoders are tolerant — unknown
//// fields are ignored, and missing-but-required fields produce a clean
//// decode error.

import glammy/internal/json_utils.{opt_bool, opt_float, opt_int, opt_str}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

// =====================================================================
//                                User
// =====================================================================

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
  )
}

pub fn user_decoder() -> Decoder(User) {
  use id <- decode.field("id", decode.int)
  use is_bot <- decode.field("is_bot", decode.bool)
  use first_name <- decode.field("first_name", decode.string)
  use last_name <- opt_str("last_name")
  use username <- opt_str("username")
  use language_code <- opt_str("language_code")
  use is_premium <- opt_bool("is_premium")
  use added_to_attachment_menu <- opt_bool("added_to_attachment_menu")
  use can_join_groups <- opt_bool("can_join_groups")
  use can_read_all_group_messages <- opt_bool("can_read_all_group_messages")
  use supports_inline_queries <- opt_bool("supports_inline_queries")
  use can_connect_to_business <- opt_bool("can_connect_to_business")
  use has_main_web_app <- opt_bool("has_main_web_app")
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
  ))
}

// =====================================================================
//                                Chat
// =====================================================================

pub type ChatType {
  Private
  Group
  Supergroup
  Channel
}

pub fn chat_type_decoder() -> Decoder(ChatType) {
  use raw <- decode.then(decode.string)
  case raw {
    "private" -> decode.success(Private)
    "group" -> decode.success(Group)
    "supergroup" -> decode.success(Supergroup)
    "channel" -> decode.success(Channel)
    other -> decode.failure(Private, "ChatType:" <> other)
  }
}

pub type Chat {
  Chat(
    id: Int,
    type_: ChatType,
    title: Option(String),
    username: Option(String),
    first_name: Option(String),
    last_name: Option(String),
    is_forum: Option(Bool),
  )
}

pub fn chat_decoder() -> Decoder(Chat) {
  use id <- decode.field("id", decode.int)
  use type_ <- decode.field("type", chat_type_decoder())
  use title <- opt_str("title")
  use username <- opt_str("username")
  use first_name <- opt_str("first_name")
  use last_name <- opt_str("last_name")
  use is_forum <- opt_bool("is_forum")
  decode.success(Chat(
    id:,
    type_:,
    title:,
    username:,
    first_name:,
    last_name:,
    is_forum:,
  ))
}

// =====================================================================
//                              ChatPhoto
// =====================================================================

pub type ChatPhoto {
  ChatPhoto(
    small_file_id: String,
    small_file_unique_id: String,
    big_file_id: String,
    big_file_unique_id: String,
  )
}

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
  )
}

pub fn chat_permissions_decoder() -> Decoder(ChatPermissions) {
  use can_send_messages <- opt_bool("can_send_messages")
  use can_send_audios <- opt_bool("can_send_audios")
  use can_send_documents <- opt_bool("can_send_documents")
  use can_send_photos <- opt_bool("can_send_photos")
  use can_send_videos <- opt_bool("can_send_videos")
  use can_send_video_notes <- opt_bool("can_send_video_notes")
  use can_send_voice_notes <- opt_bool("can_send_voice_notes")
  use can_send_polls <- opt_bool("can_send_polls")
  use can_send_other_messages <- opt_bool("can_send_other_messages")
  use can_add_web_page_previews <- opt_bool("can_add_web_page_previews")
  use can_change_info <- opt_bool("can_change_info")
  use can_invite_users <- opt_bool("can_invite_users")
  use can_pin_messages <- opt_bool("can_pin_messages")
  use can_manage_topics <- opt_bool("can_manage_topics")
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
  ))
}

// =====================================================================
//                       Media — Photo / Document / …
// =====================================================================

pub type PhotoSize {
  PhotoSize(
    file_id: String,
    file_unique_id: String,
    width: Int,
    height: Int,
    file_size: Option(Int),
  )
}

pub fn photo_size_decoder() -> Decoder(PhotoSize) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  use file_size <- opt_int("file_size")
  decode.success(PhotoSize(
    file_id:,
    file_unique_id:,
    width:,
    height:,
    file_size:,
  ))
}

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

pub fn document_decoder() -> Decoder(Document) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use thumbnail <- decode.optional_field(
    "thumbnail",
    None,
    decode.optional(photo_size_decoder()),
  )
  use file_name <- opt_str("file_name")
  use mime_type <- opt_str("mime_type")
  use file_size <- opt_int("file_size")
  decode.success(Document(
    file_id:,
    file_unique_id:,
    thumbnail:,
    file_name:,
    mime_type:,
    file_size:,
  ))
}

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

pub fn audio_decoder() -> Decoder(Audio) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use duration <- decode.field("duration", decode.int)
  use performer <- opt_str("performer")
  use title <- opt_str("title")
  use file_name <- opt_str("file_name")
  use mime_type <- opt_str("mime_type")
  use file_size <- opt_int("file_size")
  use thumbnail <- decode.optional_field(
    "thumbnail",
    None,
    decode.optional(photo_size_decoder()),
  )
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

pub type Voice {
  Voice(
    file_id: String,
    file_unique_id: String,
    duration: Int,
    mime_type: Option(String),
    file_size: Option(Int),
  )
}

pub fn voice_decoder() -> Decoder(Voice) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use duration <- decode.field("duration", decode.int)
  use mime_type <- opt_str("mime_type")
  use file_size <- opt_int("file_size")
  decode.success(Voice(
    file_id:,
    file_unique_id:,
    duration:,
    mime_type:,
    file_size:,
  ))
}

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

pub fn video_decoder() -> Decoder(Video) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  use duration <- decode.field("duration", decode.int)
  use thumbnail <- decode.optional_field(
    "thumbnail",
    None,
    decode.optional(photo_size_decoder()),
  )
  use file_name <- opt_str("file_name")
  use mime_type <- opt_str("mime_type")
  use file_size <- opt_int("file_size")
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

pub fn video_note_decoder() -> Decoder(VideoNote) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use length <- decode.field("length", decode.int)
  use duration <- decode.field("duration", decode.int)
  use thumbnail <- decode.optional_field(
    "thumbnail",
    None,
    decode.optional(photo_size_decoder()),
  )
  use file_size <- opt_int("file_size")
  decode.success(VideoNote(
    file_id:,
    file_unique_id:,
    length:,
    duration:,
    thumbnail:,
    file_size:,
  ))
}

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

pub fn animation_decoder() -> Decoder(Animation) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  use duration <- decode.field("duration", decode.int)
  use thumbnail <- decode.optional_field(
    "thumbnail",
    None,
    decode.optional(photo_size_decoder()),
  )
  use file_name <- opt_str("file_name")
  use mime_type <- opt_str("mime_type")
  use file_size <- opt_int("file_size")
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

pub type StickerType {
  RegularSticker
  MaskSticker
  CustomEmojiSticker
}

pub fn sticker_type_decoder() -> Decoder(StickerType) {
  use raw <- decode.then(decode.string)
  case raw {
    "regular" -> decode.success(RegularSticker)
    "mask" -> decode.success(MaskSticker)
    "custom_emoji" -> decode.success(CustomEmojiSticker)
    other -> decode.failure(RegularSticker, "StickerType:" <> other)
  }
}

pub type MaskPosition {
  MaskPosition(point: String, x_shift: Float, y_shift: Float, scale: Float)
}

pub fn mask_position_decoder() -> Decoder(MaskPosition) {
  use point <- decode.field("point", decode.string)
  use x_shift <- decode.field("x_shift", decode.float)
  use y_shift <- decode.field("y_shift", decode.float)
  use scale <- decode.field("scale", decode.float)
  decode.success(MaskPosition(point:, x_shift:, y_shift:, scale:))
}

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
    premium_animation: Option(String),
    mask_position: Option(MaskPosition),
    custom_emoji_id: Option(String),
    needs_repainting: Option(Bool),
    file_size: Option(Int),
  )
}

pub fn sticker_decoder() -> Decoder(Sticker) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use type_ <- decode.field("type", sticker_type_decoder())
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  use is_animated <- decode.field("is_animated", decode.bool)
  use is_video <- decode.field("is_video", decode.bool)
  use thumbnail <- decode.optional_field(
    "thumbnail",
    None,
    decode.optional(photo_size_decoder()),
  )
  use emoji <- opt_str("emoji")
  use set_name <- opt_str("set_name")
  use premium_animation_raw <- decode.optional_field(
    "premium_animation",
    None,
    decode.optional(decode.dynamic),
  )
  // premium_animation is actually a File object — but we only care about its
  // file_id here for forwarding purposes.
  let premium_animation = case premium_animation_raw {
    Some(_) -> Some("present")
    None -> None
  }
  use mask_position <- decode.optional_field(
    "mask_position",
    None,
    decode.optional(mask_position_decoder()),
  )
  use custom_emoji_id <- opt_str("custom_emoji_id")
  use needs_repainting <- opt_bool("needs_repainting")
  use file_size <- opt_int("file_size")
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

pub fn location_decoder() -> Decoder(Location) {
  use longitude <- decode.field("longitude", decode.float)
  use latitude <- decode.field("latitude", decode.float)
  use horizontal_accuracy <- opt_float("horizontal_accuracy")
  use live_period <- opt_int("live_period")
  use heading <- opt_int("heading")
  use proximity_alert_radius <- opt_int("proximity_alert_radius")
  decode.success(Location(
    longitude:,
    latitude:,
    horizontal_accuracy:,
    live_period:,
    heading:,
    proximity_alert_radius:,
  ))
}

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

pub fn venue_decoder() -> Decoder(Venue) {
  use location <- decode.field("location", location_decoder())
  use title <- decode.field("title", decode.string)
  use address <- decode.field("address", decode.string)
  use foursquare_id <- opt_str("foursquare_id")
  use foursquare_type <- opt_str("foursquare_type")
  use google_place_id <- opt_str("google_place_id")
  use google_place_type <- opt_str("google_place_type")
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

pub type Contact {
  Contact(
    phone_number: String,
    first_name: String,
    last_name: Option(String),
    user_id: Option(Int),
    vcard: Option(String),
  )
}

pub fn contact_decoder() -> Decoder(Contact) {
  use phone_number <- decode.field("phone_number", decode.string)
  use first_name <- decode.field("first_name", decode.string)
  use last_name <- opt_str("last_name")
  use user_id <- opt_int("user_id")
  use vcard <- opt_str("vcard")
  decode.success(Contact(
    phone_number:,
    first_name:,
    last_name:,
    user_id:,
    vcard:,
  ))
}

pub type Dice {
  Dice(emoji: String, value: Int)
}

pub fn dice_decoder() -> Decoder(Dice) {
  use emoji <- decode.field("emoji", decode.string)
  use value <- decode.field("value", decode.int)
  decode.success(Dice(emoji:, value:))
}

// =====================================================================
//                         Poll / PollAnswer
// =====================================================================

pub type PollOption {
  PollOption(text: String, voter_count: Int)
}

pub fn poll_option_decoder() -> Decoder(PollOption) {
  use text <- decode.field("text", decode.string)
  use voter_count <- decode.field("voter_count", decode.int)
  decode.success(PollOption(text:, voter_count:))
}

pub type Poll {
  Poll(
    id: String,
    question: String,
    options: List(PollOption),
    total_voter_count: Int,
    is_closed: Bool,
    is_anonymous: Bool,
    type_: String,
    allows_multiple_answers: Bool,
    correct_option_id: Option(Int),
    explanation: Option(String),
    open_period: Option(Int),
    close_date: Option(Int),
  )
}

pub fn poll_decoder() -> Decoder(Poll) {
  use id <- decode.field("id", decode.string)
  use question <- decode.field("question", decode.string)
  use options <- decode.field("options", decode.list(poll_option_decoder()))
  use total_voter_count <- decode.field("total_voter_count", decode.int)
  use is_closed <- decode.field("is_closed", decode.bool)
  use is_anonymous <- decode.field("is_anonymous", decode.bool)
  use type_ <- decode.field("type", decode.string)
  use allows_multiple_answers <- decode.field(
    "allows_multiple_answers",
    decode.bool,
  )
  use correct_option_id <- opt_int("correct_option_id")
  use explanation <- opt_str("explanation")
  use open_period <- opt_int("open_period")
  use close_date <- opt_int("close_date")
  decode.success(Poll(
    id:,
    question:,
    options:,
    total_voter_count:,
    is_closed:,
    is_anonymous:,
    type_:,
    allows_multiple_answers:,
    correct_option_id:,
    explanation:,
    open_period:,
    close_date:,
  ))
}

pub type PollAnswer {
  PollAnswer(
    poll_id: String,
    voter_chat: Option(Chat),
    user: Option(User),
    option_ids: List(Int),
  )
}

pub fn poll_answer_decoder() -> Decoder(PollAnswer) {
  use poll_id <- decode.field("poll_id", decode.string)
  use voter_chat <- decode.optional_field(
    "voter_chat",
    None,
    decode.optional(chat_decoder()),
  )
  use user <- decode.optional_field(
    "user",
    None,
    decode.optional(user_decoder()),
  )
  use option_ids <- decode.field("option_ids", decode.list(decode.int))
  decode.success(PollAnswer(poll_id:, voter_chat:, user:, option_ids:))
}

// =====================================================================
//                       MessageEntity
// =====================================================================

pub type MessageEntity {
  MessageEntity(
    type_: String,
    offset: Int,
    length: Int,
    url: Option(String),
    user: Option(User),
    language: Option(String),
    custom_emoji_id: Option(String),
  )
}

pub fn message_entity_decoder() -> Decoder(MessageEntity) {
  use type_ <- decode.field("type", decode.string)
  use offset <- decode.field("offset", decode.int)
  use length <- decode.field("length", decode.int)
  use url <- opt_str("url")
  use user <- decode.optional_field(
    "user",
    None,
    decode.optional(user_decoder()),
  )
  use language <- opt_str("language")
  use custom_emoji_id <- opt_str("custom_emoji_id")
  decode.success(MessageEntity(
    type_:,
    offset:,
    length:,
    url:,
    user:,
    language:,
    custom_emoji_id:,
  ))
}

// =====================================================================
//                       ReactionType / Reactions
// =====================================================================

pub type ReactionType {
  ReactionEmoji(emoji: String)
  ReactionCustomEmoji(custom_emoji_id: String)
  ReactionPaid
}

pub fn reaction_type_decoder() -> Decoder(ReactionType) {
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
    other -> decode.failure(ReactionPaid, "ReactionType:" <> other)
  }
}

pub type ReactionCount {
  ReactionCount(type_: ReactionType, total_count: Int)
}

pub fn reaction_count_decoder() -> Decoder(ReactionCount) {
  use type_ <- decode.field("type", reaction_type_decoder())
  use total_count <- decode.field("total_count", decode.int)
  decode.success(ReactionCount(type_:, total_count:))
}

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

pub fn message_reaction_updated_decoder() -> Decoder(MessageReactionUpdated) {
  use chat <- decode.field("chat", chat_decoder())
  use message_id <- decode.field("message_id", decode.int)
  use user <- decode.optional_field(
    "user",
    None,
    decode.optional(user_decoder()),
  )
  use actor_chat <- decode.optional_field(
    "actor_chat",
    None,
    decode.optional(chat_decoder()),
  )
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

pub type MessageReactionCountUpdated {
  MessageReactionCountUpdated(
    chat: Chat,
    message_id: Int,
    date: Int,
    reactions: List(ReactionCount),
  )
}

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

pub type Invoice {
  Invoice(
    title: String,
    description: String,
    start_parameter: String,
    currency: String,
    total_amount: Int,
  )
}

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

pub type OrderInfo {
  OrderInfo(
    name: Option(String),
    phone_number: Option(String),
    email: Option(String),
    shipping_address: Option(ShippingAddress),
  )
}

pub fn order_info_decoder() -> Decoder(OrderInfo) {
  use name <- opt_str("name")
  use phone_number <- opt_str("phone_number")
  use email <- opt_str("email")
  use shipping_address <- decode.optional_field(
    "shipping_address",
    None,
    decode.optional(shipping_address_decoder()),
  )
  decode.success(OrderInfo(name:, phone_number:, email:, shipping_address:))
}

pub type SuccessfulPayment {
  SuccessfulPayment(
    currency: String,
    total_amount: Int,
    invoice_payload: String,
    shipping_option_id: Option(String),
    order_info: Option(OrderInfo),
    telegram_payment_charge_id: String,
    provider_payment_charge_id: String,
  )
}

pub fn successful_payment_decoder() -> Decoder(SuccessfulPayment) {
  use currency <- decode.field("currency", decode.string)
  use total_amount <- decode.field("total_amount", decode.int)
  use invoice_payload <- decode.field("invoice_payload", decode.string)
  use shipping_option_id <- opt_str("shipping_option_id")
  use order_info <- decode.optional_field(
    "order_info",
    None,
    decode.optional(order_info_decoder()),
  )
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
    shipping_option_id:,
    order_info:,
    telegram_payment_charge_id:,
    provider_payment_charge_id:,
  ))
}

pub type RefundedPayment {
  RefundedPayment(
    currency: String,
    total_amount: Int,
    invoice_payload: String,
    telegram_payment_charge_id: String,
    provider_payment_charge_id: Option(String),
  )
}

pub fn refunded_payment_decoder() -> Decoder(RefundedPayment) {
  use currency <- decode.field("currency", decode.string)
  use total_amount <- decode.field("total_amount", decode.int)
  use invoice_payload <- decode.field("invoice_payload", decode.string)
  use telegram_payment_charge_id <- decode.field(
    "telegram_payment_charge_id",
    decode.string,
  )
  use provider_payment_charge_id <- opt_str("provider_payment_charge_id")
  decode.success(RefundedPayment(
    currency:,
    total_amount:,
    invoice_payload:,
    telegram_payment_charge_id:,
    provider_payment_charge_id:,
  ))
}

pub type ShippingQuery {
  ShippingQuery(
    id: String,
    from: User,
    invoice_payload: String,
    shipping_address: ShippingAddress,
  )
}

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

pub fn pre_checkout_query_decoder() -> Decoder(PreCheckoutQuery) {
  use id <- decode.field("id", decode.string)
  use from <- decode.field("from", user_decoder())
  use currency <- decode.field("currency", decode.string)
  use total_amount <- decode.field("total_amount", decode.int)
  use invoice_payload <- decode.field("invoice_payload", decode.string)
  use shipping_option_id <- opt_str("shipping_option_id")
  use order_info <- decode.optional_field(
    "order_info",
    None,
    decode.optional(order_info_decoder()),
  )
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

pub type PaidMediaPurchased {
  PaidMediaPurchased(from: User, paid_media_payload: String)
}

pub fn paid_media_purchased_decoder() -> Decoder(PaidMediaPurchased) {
  use from <- decode.field("from", user_decoder())
  use paid_media_payload <- decode.field("paid_media_payload", decode.string)
  decode.success(PaidMediaPurchased(from:, paid_media_payload:))
}

// =====================================================================
//                  Chat members / invite links / joins
// =====================================================================

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
    can_post_stories: Option(Bool),
    can_edit_stories: Option(Bool),
    can_delete_stories: Option(Bool),
    can_manage_topics: Option(Bool),
    custom_title: Option(String),
  )
  ChatMemberMember(user: User, until_date: Option(Int))
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
    can_change_info: Bool,
    can_invite_users: Bool,
    can_pin_messages: Bool,
    can_manage_topics: Bool,
    until_date: Int,
  )
  ChatMemberLeft(user: User)
  ChatMemberBanned(user: User, until_date: Int)
}

pub fn chat_member_decoder() -> Decoder(ChatMember) {
  use status <- decode.field("status", decode.string)
  case status {
    "creator" -> {
      use user <- decode.field("user", user_decoder())
      use is_anonymous <- decode.field("is_anonymous", decode.bool)
      use custom_title <- opt_str("custom_title")
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
      use can_post_messages <- opt_bool("can_post_messages")
      use can_edit_messages <- opt_bool("can_edit_messages")
      use can_pin_messages <- opt_bool("can_pin_messages")
      use can_post_stories <- opt_bool("can_post_stories")
      use can_edit_stories <- opt_bool("can_edit_stories")
      use can_delete_stories <- opt_bool("can_delete_stories")
      use can_manage_topics <- opt_bool("can_manage_topics")
      use custom_title <- opt_str("custom_title")
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
        custom_title:,
      ))
    }
    "member" -> {
      use user <- decode.field("user", user_decoder())
      use until_date <- opt_int("until_date")
      decode.success(ChatMemberMember(user:, until_date:))
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
      use can_change_info <- decode.field("can_change_info", decode.bool)
      use can_invite_users <- decode.field("can_invite_users", decode.bool)
      use can_pin_messages <- decode.field("can_pin_messages", decode.bool)
      use can_manage_topics <- decode.field("can_manage_topics", decode.bool)
      use until_date <- decode.field("until_date", decode.int)
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
        can_change_info:,
        can_invite_users:,
        can_pin_messages:,
        can_manage_topics:,
        until_date:,
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
    other ->
      decode.failure(
        ChatMemberLeft(user: placeholder_user),
        "ChatMember:" <> other,
      )
  }
}

/// Type-witness placeholder used by `decode.failure`. The decoder layer
/// guarantees this value is never observed by callers — only the error
/// list is, and `json.parse` surfaces an `UnableToDecode` error when the
/// list is non-empty.
const placeholder_user: User = User(
  id: 0,
  is_bot: False,
  first_name: "",
  last_name: None,
  username: None,
  language_code: None,
  is_premium: None,
  added_to_attachment_menu: None,
  can_join_groups: None,
  can_read_all_group_messages: None,
  supports_inline_queries: None,
  can_connect_to_business: None,
  has_main_web_app: None,
)

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
  )
}

pub fn chat_invite_link_decoder() -> Decoder(ChatInviteLink) {
  use invite_link <- decode.field("invite_link", decode.string)
  use creator <- decode.field("creator", user_decoder())
  use creates_join_request <- decode.field("creates_join_request", decode.bool)
  use is_primary <- decode.field("is_primary", decode.bool)
  use is_revoked <- decode.field("is_revoked", decode.bool)
  use name <- opt_str("name")
  use expire_date <- opt_int("expire_date")
  use member_limit <- opt_int("member_limit")
  use pending_join_request_count <- opt_int("pending_join_request_count")
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
  ))
}

pub type ChatMemberUpdated {
  ChatMemberUpdated(
    chat: Chat,
    from: User,
    date: Int,
    old_chat_member: ChatMember,
    new_chat_member: ChatMember,
    invite_link: Option(ChatInviteLink),
    via_chat_folder_invite_link: Option(Bool),
  )
}

pub fn chat_member_updated_decoder() -> Decoder(ChatMemberUpdated) {
  use chat <- decode.field("chat", chat_decoder())
  use from <- decode.field("from", user_decoder())
  use date <- decode.field("date", decode.int)
  use old_chat_member <- decode.field("old_chat_member", chat_member_decoder())
  use new_chat_member <- decode.field("new_chat_member", chat_member_decoder())
  use invite_link <- decode.optional_field(
    "invite_link",
    None,
    decode.optional(chat_invite_link_decoder()),
  )
  use via_chat_folder_invite_link <- opt_bool("via_chat_folder_invite_link")
  decode.success(ChatMemberUpdated(
    chat:,
    from:,
    date:,
    old_chat_member:,
    new_chat_member:,
    invite_link:,
    via_chat_folder_invite_link:,
  ))
}

pub type ChatJoinRequest {
  ChatJoinRequest(
    chat: Chat,
    from: User,
    user_chat_id: Int,
    date: Int,
    bio: Option(String),
    invite_link: Option(ChatInviteLink),
  )
}

pub fn chat_join_request_decoder() -> Decoder(ChatJoinRequest) {
  use chat <- decode.field("chat", chat_decoder())
  use from <- decode.field("from", user_decoder())
  use user_chat_id <- decode.field("user_chat_id", decode.int)
  use date <- decode.field("date", decode.int)
  use bio <- opt_str("bio")
  use invite_link <- decode.optional_field(
    "invite_link",
    None,
    decode.optional(chat_invite_link_decoder()),
  )
  decode.success(ChatJoinRequest(
    chat:,
    from:,
    user_chat_id:,
    date:,
    bio:,
    invite_link:,
  ))
}

// =====================================================================
//                       Chat boosts
// =====================================================================

pub type ChatBoostSource {
  ChatBoostSourcePremium(user: User)
  ChatBoostSourceGiftCode(user: User)
  ChatBoostSourceGiveaway(
    giveaway_message_id: Int,
    user: Option(User),
    prize_star_count: Option(Int),
    is_unclaimed: Option(Bool),
  )
}

pub fn chat_boost_source_decoder() -> Decoder(ChatBoostSource) {
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
      use user <- decode.optional_field(
        "user",
        None,
        decode.optional(user_decoder()),
      )
      use prize_star_count <- opt_int("prize_star_count")
      use is_unclaimed <- opt_bool("is_unclaimed")
      decode.success(ChatBoostSourceGiveaway(
        giveaway_message_id:,
        user:,
        prize_star_count:,
        is_unclaimed:,
      ))
    }
    other ->
      decode.failure(
        ChatBoostSourcePremium(user: placeholder_user),
        "ChatBoostSource:" <> other,
      )
  }
}

pub type ChatBoost {
  ChatBoost(
    boost_id: String,
    add_date: Int,
    expiration_date: Int,
    source: ChatBoostSource,
  )
}

pub fn chat_boost_decoder() -> Decoder(ChatBoost) {
  use boost_id <- decode.field("boost_id", decode.string)
  use add_date <- decode.field("add_date", decode.int)
  use expiration_date <- decode.field("expiration_date", decode.int)
  use source <- decode.field("source", chat_boost_source_decoder())
  decode.success(ChatBoost(boost_id:, add_date:, expiration_date:, source:))
}

pub type ChatBoostUpdated {
  ChatBoostUpdated(chat: Chat, boost: ChatBoost)
}

pub fn chat_boost_updated_decoder() -> Decoder(ChatBoostUpdated) {
  use chat <- decode.field("chat", chat_decoder())
  use boost <- decode.field("boost", chat_boost_decoder())
  decode.success(ChatBoostUpdated(chat:, boost:))
}

pub type ChatBoostRemoved {
  ChatBoostRemoved(
    chat: Chat,
    boost_id: String,
    remove_date: Int,
    source: ChatBoostSource,
  )
}

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

pub type BusinessConnection {
  BusinessConnection(
    id: String,
    user: User,
    user_chat_id: Int,
    date: Int,
    can_reply: Option(Bool),
    is_enabled: Bool,
  )
}

pub fn business_connection_decoder() -> Decoder(BusinessConnection) {
  use id <- decode.field("id", decode.string)
  use user <- decode.field("user", user_decoder())
  use user_chat_id <- decode.field("user_chat_id", decode.int)
  use date <- decode.field("date", decode.int)
  use can_reply <- opt_bool("can_reply")
  use is_enabled <- decode.field("is_enabled", decode.bool)
  decode.success(BusinessConnection(
    id:,
    user:,
    user_chat_id:,
    date:,
    can_reply:,
    is_enabled:,
  ))
}

pub type BusinessMessagesDeleted {
  BusinessMessagesDeleted(
    business_connection_id: String,
    chat: Chat,
    message_ids: List(Int),
  )
}

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

pub type File {
  File(
    file_id: String,
    file_unique_id: String,
    file_size: Option(Int),
    file_path: Option(String),
  )
}

pub fn file_decoder() -> Decoder(File) {
  use file_id <- decode.field("file_id", decode.string)
  use file_unique_id <- decode.field("file_unique_id", decode.string)
  use file_size <- opt_int("file_size")
  use file_path <- opt_str("file_path")
  decode.success(File(file_id:, file_unique_id:, file_size:, file_path:))
}

pub type LinkPreviewOptions {
  LinkPreviewOptions(
    is_disabled: Option(Bool),
    url: Option(String),
    prefer_small_media: Option(Bool),
    prefer_large_media: Option(Bool),
    show_above_text: Option(Bool),
  )
}

pub fn link_preview_options_decoder() -> Decoder(LinkPreviewOptions) {
  use is_disabled <- opt_bool("is_disabled")
  use url <- opt_str("url")
  use prefer_small_media <- opt_bool("prefer_small_media")
  use prefer_large_media <- opt_bool("prefer_large_media")
  use show_above_text <- opt_bool("show_above_text")
  decode.success(LinkPreviewOptions(
    is_disabled:,
    url:,
    prefer_small_media:,
    prefer_large_media:,
    show_above_text:,
  ))
}

// =====================================================================
//                                Message
// =====================================================================

/// `Message` is intentionally a *wide* record with most common fields
/// surfaced. We keep recursive references (`reply_to_message`) via
/// `decode.recursive` and pass through truly exotic fields (passport data,
/// game updates, etc.) as `Dynamic` via the `extra` field at the bottom.
pub type Message {
  Message(
    message_id: Int,
    message_thread_id: Option(Int),
    from: Option(User),
    sender_chat: Option(Chat),
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
    pinned_message: Option(Message),
    invoice: Option(Invoice),
    successful_payment: Option(SuccessfulPayment),
    refunded_payment: Option(RefundedPayment),
    connected_website: Option(String),
    business_connection_id: Option(String),
  )
}

pub fn message_decoder() -> Decoder(Message) {
  use message_id <- decode.field("message_id", decode.int)
  use message_thread_id <- opt_int("message_thread_id")
  use from <- decode.optional_field(
    "from",
    None,
    decode.optional(user_decoder()),
  )
  use sender_chat <- decode.optional_field(
    "sender_chat",
    None,
    decode.optional(chat_decoder()),
  )
  use date <- decode.field("date", decode.int)
  use edit_date <- opt_int("edit_date")
  use chat <- decode.field("chat", chat_decoder())
  use forward_origin <- decode.optional_field(
    "forward_origin",
    None,
    decode.optional(decode.dynamic),
  )
  use is_topic_message <- opt_bool("is_topic_message")
  use is_automatic_forward <- opt_bool("is_automatic_forward")
  use reply_to_message <- decode.optional_field(
    "reply_to_message",
    None,
    decode.optional(decode.recursive(message_decoder)),
  )
  use via_bot <- decode.optional_field(
    "via_bot",
    None,
    decode.optional(user_decoder()),
  )
  use has_protected_content <- opt_bool("has_protected_content")
  use media_group_id <- opt_str("media_group_id")
  use author_signature <- opt_str("author_signature")
  use text <- opt_str("text")
  use entities <- decode.optional_field(
    "entities",
    [],
    decode.list(message_entity_decoder()),
  )
  use link_preview_options <- decode.optional_field(
    "link_preview_options",
    None,
    decode.optional(link_preview_options_decoder()),
  )
  use caption <- opt_str("caption")
  use caption_entities <- decode.optional_field(
    "caption_entities",
    [],
    decode.list(message_entity_decoder()),
  )
  use show_caption_above_media <- opt_bool("show_caption_above_media")
  use has_media_spoiler <- opt_bool("has_media_spoiler")
  use photo <- decode.optional_field(
    "photo",
    [],
    decode.list(photo_size_decoder()),
  )
  use document <- decode.optional_field(
    "document",
    None,
    decode.optional(document_decoder()),
  )
  use audio <- decode.optional_field(
    "audio",
    None,
    decode.optional(audio_decoder()),
  )
  use voice <- decode.optional_field(
    "voice",
    None,
    decode.optional(voice_decoder()),
  )
  use video <- decode.optional_field(
    "video",
    None,
    decode.optional(video_decoder()),
  )
  use video_note <- decode.optional_field(
    "video_note",
    None,
    decode.optional(video_note_decoder()),
  )
  use animation <- decode.optional_field(
    "animation",
    None,
    decode.optional(animation_decoder()),
  )
  use sticker <- decode.optional_field(
    "sticker",
    None,
    decode.optional(sticker_decoder()),
  )
  use location <- decode.optional_field(
    "location",
    None,
    decode.optional(location_decoder()),
  )
  use venue <- decode.optional_field(
    "venue",
    None,
    decode.optional(venue_decoder()),
  )
  use contact <- decode.optional_field(
    "contact",
    None,
    decode.optional(contact_decoder()),
  )
  use dice <- decode.optional_field(
    "dice",
    None,
    decode.optional(dice_decoder()),
  )
  use poll <- decode.optional_field(
    "poll",
    None,
    decode.optional(poll_decoder()),
  )
  use new_chat_members <- decode.optional_field(
    "new_chat_members",
    [],
    decode.list(user_decoder()),
  )
  use left_chat_member <- decode.optional_field(
    "left_chat_member",
    None,
    decode.optional(user_decoder()),
  )
  use new_chat_title <- opt_str("new_chat_title")
  use new_chat_photo <- decode.optional_field(
    "new_chat_photo",
    [],
    decode.list(photo_size_decoder()),
  )
  use delete_chat_photo <- opt_bool("delete_chat_photo")
  use group_chat_created <- opt_bool("group_chat_created")
  use supergroup_chat_created <- opt_bool("supergroup_chat_created")
  use channel_chat_created <- opt_bool("channel_chat_created")
  use migrate_to_chat_id <- opt_int("migrate_to_chat_id")
  use migrate_from_chat_id <- opt_int("migrate_from_chat_id")
  use pinned_message <- decode.optional_field(
    "pinned_message",
    None,
    decode.optional(decode.recursive(message_decoder)),
  )
  use invoice <- decode.optional_field(
    "invoice",
    None,
    decode.optional(invoice_decoder()),
  )
  use successful_payment <- decode.optional_field(
    "successful_payment",
    None,
    decode.optional(successful_payment_decoder()),
  )
  use refunded_payment <- decode.optional_field(
    "refunded_payment",
    None,
    decode.optional(refunded_payment_decoder()),
  )
  use connected_website <- opt_str("connected_website")
  use business_connection_id <- opt_str("business_connection_id")
  decode.success(Message(
    message_id:,
    message_thread_id:,
    from:,
    sender_chat:,
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
  ))
}

// =====================================================================
//                          CallbackQuery
// =====================================================================

pub type CallbackQuery {
  CallbackQuery(
    id: String,
    from: User,
    message: Option(Message),
    chat_instance: String,
    data: Option(String),
    inline_message_id: Option(String),
    game_short_name: Option(String),
  )
}

pub fn callback_query_decoder() -> Decoder(CallbackQuery) {
  use id <- decode.field("id", decode.string)
  use from <- decode.field("from", user_decoder())
  use message <- decode.optional_field(
    "message",
    None,
    decode.optional(message_decoder()),
  )
  use chat_instance <- decode.field("chat_instance", decode.string)
  use data <- opt_str("data")
  use inline_message_id <- opt_str("inline_message_id")
  use game_short_name <- opt_str("game_short_name")
  decode.success(CallbackQuery(
    id:,
    from:,
    message:,
    chat_instance:,
    data:,
    inline_message_id:,
    game_short_name:,
  ))
}

// =====================================================================
//                          InlineQuery
// =====================================================================

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

pub fn inline_query_decoder() -> Decoder(InlineQuery) {
  use id <- decode.field("id", decode.string)
  use from <- decode.field("from", user_decoder())
  use query <- decode.field("query", decode.string)
  use offset <- decode.field("offset", decode.string)
  use chat_type <- opt_str("chat_type")
  use location <- decode.optional_field(
    "location",
    None,
    decode.optional(location_decoder()),
  )
  decode.success(InlineQuery(id:, from:, query:, offset:, chat_type:, location:))
}

pub type ChosenInlineResult {
  ChosenInlineResult(
    result_id: String,
    from: User,
    location: Option(Location),
    inline_message_id: Option(String),
    query: String,
  )
}

pub fn chosen_inline_result_decoder() -> Decoder(ChosenInlineResult) {
  use result_id <- decode.field("result_id", decode.string)
  use from <- decode.field("from", user_decoder())
  use location <- decode.optional_field(
    "location",
    None,
    decode.optional(location_decoder()),
  )
  use inline_message_id <- opt_str("inline_message_id")
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
  OtherUpdate
}

pub type Update {
  Update(update_id: Int, kind: UpdateKind)
}

pub fn update_decoder() -> Decoder(Update) {
  use update_id <- decode.field("update_id", decode.int)
  use kind <- decode.then(update_kind_decoder())
  decode.success(Update(update_id:, kind:))
}

fn update_kind_decoder() -> Decoder(UpdateKind) {
  use message <- decode.optional_field(
    "message",
    None,
    decode.optional(message_decoder()),
  )
  use edited_message <- decode.optional_field(
    "edited_message",
    None,
    decode.optional(message_decoder()),
  )
  use channel_post <- decode.optional_field(
    "channel_post",
    None,
    decode.optional(message_decoder()),
  )
  use edited_channel_post <- decode.optional_field(
    "edited_channel_post",
    None,
    decode.optional(message_decoder()),
  )
  use business_connection <- decode.optional_field(
    "business_connection",
    None,
    decode.optional(business_connection_decoder()),
  )
  use business_message <- decode.optional_field(
    "business_message",
    None,
    decode.optional(message_decoder()),
  )
  use edited_business_message <- decode.optional_field(
    "edited_business_message",
    None,
    decode.optional(message_decoder()),
  )
  use deleted_business_messages <- decode.optional_field(
    "deleted_business_messages",
    None,
    decode.optional(business_messages_deleted_decoder()),
  )
  use message_reaction <- decode.optional_field(
    "message_reaction",
    None,
    decode.optional(message_reaction_updated_decoder()),
  )
  use message_reaction_count <- decode.optional_field(
    "message_reaction_count",
    None,
    decode.optional(message_reaction_count_updated_decoder()),
  )
  use inline_query <- decode.optional_field(
    "inline_query",
    None,
    decode.optional(inline_query_decoder()),
  )
  use chosen_inline_result <- decode.optional_field(
    "chosen_inline_result",
    None,
    decode.optional(chosen_inline_result_decoder()),
  )
  use callback_query <- decode.optional_field(
    "callback_query",
    None,
    decode.optional(callback_query_decoder()),
  )
  use shipping_query <- decode.optional_field(
    "shipping_query",
    None,
    decode.optional(shipping_query_decoder()),
  )
  use pre_checkout_query <- decode.optional_field(
    "pre_checkout_query",
    None,
    decode.optional(pre_checkout_query_decoder()),
  )
  use poll <- decode.optional_field(
    "poll",
    None,
    decode.optional(poll_decoder()),
  )
  use poll_answer <- decode.optional_field(
    "poll_answer",
    None,
    decode.optional(poll_answer_decoder()),
  )
  use my_chat_member <- decode.optional_field(
    "my_chat_member",
    None,
    decode.optional(chat_member_updated_decoder()),
  )
  use chat_member <- decode.optional_field(
    "chat_member",
    None,
    decode.optional(chat_member_updated_decoder()),
  )
  use chat_join_request <- decode.optional_field(
    "chat_join_request",
    None,
    decode.optional(chat_join_request_decoder()),
  )
  use chat_boost <- decode.optional_field(
    "chat_boost",
    None,
    decode.optional(chat_boost_updated_decoder()),
  )
  use removed_chat_boost <- decode.optional_field(
    "removed_chat_boost",
    None,
    decode.optional(chat_boost_removed_decoder()),
  )
  use purchased_paid_media <- decode.optional_field(
    "purchased_paid_media",
    None,
    decode.optional(paid_media_purchased_decoder()),
  )

  // The Telegram envelope is "all variants optional, exactly one
  // present" — list each candidate in canonical order and pick the
  // first present one. `OtherUpdate` is the catch-all so the bot stays
  // robust against future Telegram additions.
  let candidates = [
    option.map(message, MessageUpdate),
    option.map(edited_message, EditedMessageUpdate),
    option.map(channel_post, ChannelPostUpdate),
    option.map(edited_channel_post, EditedChannelPostUpdate),
    option.map(business_connection, BusinessConnectionUpdate),
    option.map(business_message, BusinessMessageUpdate),
    option.map(edited_business_message, EditedBusinessMessageUpdate),
    option.map(deleted_business_messages, DeletedBusinessMessagesUpdate),
    option.map(message_reaction, MessageReactionUpdate),
    option.map(message_reaction_count, MessageReactionCountUpdate),
    option.map(inline_query, InlineQueryUpdate),
    option.map(chosen_inline_result, ChosenInlineResultUpdate),
    option.map(callback_query, CallbackQueryUpdate),
    option.map(shipping_query, ShippingQueryUpdate),
    option.map(pre_checkout_query, PreCheckoutQueryUpdate),
    option.map(poll, PollUpdate),
    option.map(poll_answer, PollAnswerUpdate),
    option.map(my_chat_member, MyChatMemberUpdate),
    option.map(chat_member, ChatMemberUpdate),
    option.map(chat_join_request, ChatJoinRequestUpdate),
    option.map(chat_boost, ChatBoostUpdate),
    option.map(removed_chat_boost, RemovedChatBoostUpdate),
    option.map(purchased_paid_media, PurchasedPaidMediaUpdate),
  ]
  let kind =
    list.find_map(candidates, option.to_result(_, Nil))
    |> result.unwrap(OtherUpdate)
  decode.success(kind)
}

// =====================================================================
//                        ResponseParameters / ApiError
// =====================================================================

pub type ResponseParameters {
  ResponseParameters(migrate_to_chat_id: Option(Int), retry_after: Option(Int))
}

pub fn response_parameters_decoder() -> Decoder(ResponseParameters) {
  use migrate_to_chat_id <- opt_int("migrate_to_chat_id")
  use retry_after <- opt_int("retry_after")
  decode.success(ResponseParameters(migrate_to_chat_id:, retry_after:))
}

// =====================================================================
//                          BotCommand / BotCommandScope
// =====================================================================

pub type BotCommand {
  BotCommand(command: String, description: String)
}

pub fn bot_command_decoder() -> Decoder(BotCommand) {
  use command <- decode.field("command", decode.string)
  use description <- decode.field("description", decode.string)
  decode.success(BotCommand(command:, description:))
}

pub type BotCommandScope {
  BotCommandScopeDefault
  BotCommandScopeAllPrivateChats
  BotCommandScopeAllGroupChats
  BotCommandScopeAllChatAdministrators
  BotCommandScopeChat(chat_id: Int)
  BotCommandScopeChatAdministrators(chat_id: Int)
  BotCommandScopeChatMember(chat_id: Int, user_id: Int)
}

// =====================================================================
//                       BotInfo / WebhookInfo
// =====================================================================

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

pub fn webhook_info_decoder() -> Decoder(WebhookInfo) {
  use url <- decode.field("url", decode.string)
  use has_custom_certificate <- decode.field(
    "has_custom_certificate",
    decode.bool,
  )
  use pending_update_count <- decode.field("pending_update_count", decode.int)
  use ip_address <- opt_str("ip_address")
  use last_error_date <- opt_int("last_error_date")
  use last_error_message <- opt_str("last_error_message")
  use last_synchronization_error_date <- opt_int(
    "last_synchronization_error_date",
  )
  use max_connections <- opt_int("max_connections")
  use allowed_updates <- decode.optional_field(
    "allowed_updates",
    [],
    decode.list(decode.string),
  )
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
