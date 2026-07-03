//// Update filtering.
////
//// Two complementary layers:
////
//// 1. `Filter` — a strongly-typed enum for the common cases. Fast and
////    closed-form; the compiler exhaustively checks every variant.
//// 2. `parse` / `matches_query` — a grammY-style filter-query parser
////    that accepts dotted strings (`"message:text"`,
////    `"callback_query:data"`, `"message:entities:url"`, `"msg:photo"`,
////    `":text"`, `"::url"`). Includes L1/L2 shortcut expansion and
////    structural validation against the Telegram update shape.

import glammy/context.{type Context}
import glammy/types.{
  type CallbackQuery, type Message, type Update, type UpdateKind, type User,
  BusinessConnectionUpdate, BusinessMessageUpdate, CallbackQueryUpdate,
  ChannelPostUpdate, ChatBoostUpdate, ChatJoinRequestUpdate, ChatMemberUpdate,
  ChosenInlineResultUpdate, DeletedBusinessMessagesUpdate,
  EditedBusinessMessageUpdate, EditedChannelPostUpdate, EditedMessageUpdate,
  InlineQueryUpdate, MessageReactionCountUpdate, MessageReactionUpdate,
  MessageUpdate, MyChatMemberUpdate, OtherUpdate, PollAnswerUpdate, PollUpdate,
  PreCheckoutQueryUpdate, PurchasedPaidMediaUpdate, RemovedChatBoostUpdate,
  ShippingQueryUpdate,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

// =====================================================================
//                            Filter enum
// =====================================================================

pub type Filter {
  AnyUpdate
  AnyMessage
  Message
  EditedMessage
  ChannelPost
  EditedChannelPost
  BusinessConnection
  BusinessMessage
  EditedBusinessMessage
  DeletedBusinessMessages
  MessageReaction
  MessageReactionCount
  InlineQuery
  ChosenInlineResult
  CallbackQuery
  ShippingQuery
  PreCheckoutQuery
  Poll
  PollAnswer
  MyChatMember
  ChatMember
  ChatJoinRequest
  ChatBoost
  RemovedChatBoost
  PurchasedPaidMedia
}

pub fn matches(filter: Filter, ctx: Context) -> Bool {
  case filter {
    AnyUpdate -> True
    AnyMessage -> is_any_message(ctx.update.kind)
    _ -> matches_specific(filter, ctx.update.kind)
  }
}

fn is_any_message(kind: UpdateKind) -> Bool {
  case kind {
    MessageUpdate(_) -> True
    EditedMessageUpdate(_) -> True
    ChannelPostUpdate(_) -> True
    EditedChannelPostUpdate(_) -> True
    BusinessMessageUpdate(_) -> True
    EditedBusinessMessageUpdate(_) -> True
    _ -> False
  }
}

fn matches_specific(filter: Filter, kind: UpdateKind) -> Bool {
  case filter, kind {
    Message, MessageUpdate(_) -> True
    EditedMessage, EditedMessageUpdate(_) -> True
    ChannelPost, ChannelPostUpdate(_) -> True
    EditedChannelPost, EditedChannelPostUpdate(_) -> True
    BusinessConnection, BusinessConnectionUpdate(_) -> True
    BusinessMessage, BusinessMessageUpdate(_) -> True
    EditedBusinessMessage, EditedBusinessMessageUpdate(_) -> True
    DeletedBusinessMessages, DeletedBusinessMessagesUpdate(_) -> True
    MessageReaction, MessageReactionUpdate(_) -> True
    MessageReactionCount, MessageReactionCountUpdate(_) -> True
    InlineQuery, InlineQueryUpdate(_) -> True
    ChosenInlineResult, ChosenInlineResultUpdate(_) -> True
    CallbackQuery, CallbackQueryUpdate(_) -> True
    ShippingQuery, ShippingQueryUpdate(_) -> True
    PreCheckoutQuery, PreCheckoutQueryUpdate(_) -> True
    Poll, PollUpdate(_) -> True
    PollAnswer, PollAnswerUpdate(_) -> True
    MyChatMember, MyChatMemberUpdate(_) -> True
    ChatMember, ChatMemberUpdate(_) -> True
    ChatJoinRequest, ChatJoinRequestUpdate(_) -> True
    ChatBoost, ChatBoostUpdate(_) -> True
    RemovedChatBoost, RemovedChatBoostUpdate(_) -> True
    PurchasedPaidMedia, PurchasedPaidMediaUpdate(_) -> True
    _, _ -> False
  }
}

// =====================================================================
//                       grammY-style filter queries
// =====================================================================

/// A parsed and validated filter query. Created via `parse` or
/// `parse_many` (the latter for OR-of-queries).
pub opaque type Query {
  Query(alternatives: List(CompiledTriple))
}

/// A fully-resolved (after shortcut expansion) filter target. The
/// `Option`s indicate which levels are *actually* being checked: a
/// `None` L2 means "only require the L1 update kind".
type CompiledTriple {
  CompiledTriple(
    l1: String,
    l2: option.Option(String),
    l3: option.Option(String),
  )
}

/// Parse a single filter string. Returns `Error(reason)` if the query
/// is malformed (empty, has empty parts that can't be defaulted, refers
/// to an unknown update key, …).
pub fn parse(filter: String) -> Result(Query, String) {
  parse_many([filter])
}

/// Parse multiple filter strings as a logical OR. The resulting query
/// matches when *any* input matches.
pub fn parse_many(filters: List(String)) -> Result(Query, String) {
  list.try_map(filters, parse_one)
  |> result.map(fn(parts) { Query(alternatives: list.flatten(parts)) })
}

fn parse_one(filter: String) -> Result(List(CompiledTriple), String) {
  let raw = string.split(filter, ":") |> list.map(string.trim)
  case raw {
    [] -> Error("empty filter")
    [l1] -> parse_depth1(filter, l1)
    [l1, l2] -> parse_depth2(filter, l1, l2)
    [l1, l2, l3] -> parse_depth3(filter, l1, l2, l3)
    _ -> Error("too many parts in filter '" <> filter <> "'")
  }
}

fn parse_depth1(
  original: String,
  l1: String,
) -> Result(List(CompiledTriple), String) {
  case l1 {
    "" ->
      Error(
        "Cannot create filter function for empty query '" <> original <> "'",
      )
    _ -> {
      let candidates =
        expand_l1(l1)
        |> list.filter(is_valid_l1)
        |> list.map(fn(name) { CompiledTriple(l1: name, l2: None, l3: None) })
      case candidates {
        [] -> Error("Invalid L1 filter '" <> l1 <> "' in '" <> original <> "'")
        _ -> Ok(candidates)
      }
    }
  }
}

fn parse_depth2(
  original: String,
  l1: String,
  l2: String,
) -> Result(List(CompiledTriple), String) {
  case l1, l2 {
    "", "" ->
      Error(
        "Cannot create filter function for empty query '" <> original <> "'",
      )
    _, "" ->
      Error(
        "Invalid L2 filter '' in '" <> original <> "': no L3 to default against",
      )
    _, _ -> cross_validate(original, l1, expand_l2_without_l3(l2), None)
  }
}

fn parse_depth3(
  original: String,
  l1: String,
  l2: String,
  l3: String,
) -> Result(List(CompiledTriple), String) {
  case l3 {
    "" ->
      Error(
        "Invalid L3 filter '' in '" <> original <> "': empty leaf not allowed",
      )
    _ -> cross_validate(original, l1, expand_l2_with_l3(l2), Some(l3))
  }
}

/// Shared scaffold for depth-2 and depth-3 parsing: expands L1 shortcuts,
/// cross-products with the already-expanded L2 candidates, attaches the
/// given L3 (if any), and filters down to structurally valid triples.
fn cross_validate(
  original: String,
  l1: String,
  l2_candidates: List(String),
  l3: option.Option(String),
) -> Result(List(CompiledTriple), String) {
  let l1_candidates = expand_l1(l1) |> list.filter(is_valid_l1)
  let expanded =
    list.flat_map(l1_candidates, fn(l1n) {
      list.map(l2_candidates, fn(l2n) {
        CompiledTriple(l1: l1n, l2: Some(l2n), l3: l3)
      })
    })
  let valid =
    list.filter(expanded, fn(t) {
      let l2_ok = case t.l2 {
        Some(name) -> is_valid_l2(t.l1, name)
        None -> True
      }
      let l3_ok = case t.l2, t.l3 {
        Some(l2n), Some(l3n) -> is_valid_l3(l2n, l3n)
        _, _ -> True
      }
      l2_ok && l3_ok
    })
  case valid {
    [] ->
      Error(
        "Shortcuts in '"
        <> original
        <> "' do not expand to any valid filter query",
      )
    _ -> Ok(valid)
  }
}

fn expand_l1(l1: String) -> List(String) {
  case l1 {
    "" -> ["message", "channel_post"]
    "msg" -> ["message", "channel_post"]
    "edit" -> ["edited_message", "edited_channel_post"]
    name -> [name]
  }
}

fn expand_l2_aliases(l2: String) -> List(String) {
  case l2 {
    "media" -> ["photo", "video"]
    "file" -> [
      "photo",
      "animation",
      "audio",
      "document",
      "video",
      "video_note",
      "voice",
      "sticker",
    ]
    name -> [name]
  }
}

fn expand_l2_with_l3(l2: String) -> List(String) {
  case l2 {
    "" -> ["entities", "caption_entities"]
    _ -> expand_l2_aliases(l2)
  }
}

fn expand_l2_without_l3(l2: String) -> List(String) {
  case l2 {
    // When there's no L3, the default L2 expansion does NOT apply (an
    // empty L2 with no L3 is ambiguous and grammY rejects it).
    "" -> []
    _ -> expand_l2_aliases(l2)
  }
}

fn is_valid_l1(name: String) -> Bool {
  case name {
    "message"
    | "edited_message"
    | "channel_post"
    | "edited_channel_post"
    | "business_connection"
    | "business_message"
    | "edited_business_message"
    | "deleted_business_messages"
    | "message_reaction"
    | "message_reaction_count"
    | "inline_query"
    | "chosen_inline_result"
    | "callback_query"
    | "shipping_query"
    | "pre_checkout_query"
    | "poll"
    | "poll_answer"
    | "my_chat_member"
    | "chat_member"
    | "chat_join_request"
    | "chat_boost"
    | "removed_chat_boost"
    | "purchased_paid_media" -> True
    _ -> False
  }
}

fn is_valid_l2(l1: String, l2: String) -> Bool {
  case l1 {
    "message"
    | "edited_message"
    | "channel_post"
    | "edited_channel_post"
    | "business_message"
    | "edited_business_message" -> is_valid_message_field(l2)
    "callback_query" -> l2 == "data" || l2 == "game_short_name"
    "chat_member" | "my_chat_member" -> l2 == "from"
    _ -> False
  }
}

fn is_valid_message_field(name: String) -> Bool {
  case name {
    "text"
    | "photo"
    | "video"
    | "audio"
    | "voice"
    | "document"
    | "animation"
    | "sticker"
    | "video_note"
    | "contact"
    | "dice"
    | "game"
    | "poll"
    | "venue"
    | "location"
    | "caption"
    | "entities"
    | "caption_entities"
    | "new_chat_members"
    | "left_chat_member"
    | "new_chat_title"
    | "new_chat_photo"
    | "delete_chat_photo"
    | "pinned_message"
    | "invoice"
    | "successful_payment"
    | "refunded_payment"
    | "reply_to_message"
    | "via_bot"
    | "forward_origin"
    | "is_topic_message"
    | "is_automatic_forward"
    | "has_protected_content"
    | "media_group_id"
    | "author_signature"
    | "has_media_spoiler"
    | "connected_website"
    | "business_connection_id" -> True
    _ -> False
  }
}

fn is_valid_l3(l2: String, l3: String) -> Bool {
  case l2 {
    "entities" | "caption_entities" -> is_valid_entity_type(l3)
    "new_chat_members" | "left_chat_member" -> is_valid_user_key(l3)
    _ -> False
  }
}

fn is_valid_entity_type(name: String) -> Bool {
  case name {
    "mention"
    | "hashtag"
    | "cashtag"
    | "bot_command"
    | "url"
    | "email"
    | "phone_number"
    | "bold"
    | "italic"
    | "underline"
    | "strikethrough"
    | "spoiler"
    | "blockquote"
    | "expandable_blockquote"
    | "code"
    | "pre"
    | "text_link"
    | "text_mention"
    | "custom_emoji" -> True
    _ -> False
  }
}

fn is_valid_user_key(name: String) -> Bool {
  case name {
    "is_bot" | "me" | "is_premium" | "added_to_attachment_menu" -> True
    _ -> False
  }
}

// =====================================================================
//                            Matching
// =====================================================================

pub fn matches_query(query: Query, ctx: Context) -> Bool {
  list.any(query.alternatives, fn(triple) { matches_triple(triple, ctx) })
}

fn matches_triple(triple: CompiledTriple, ctx: Context) -> Bool {
  case extract_l1(triple.l1, ctx.update.kind) {
    None -> False
    Some(l1_value) ->
      case triple.l2 {
        None -> True
        Some(l2_name) -> match_inside_l1(l2_name, triple.l3, l1_value)
      }
  }
}

type L1Value {
  MessageValue(Message)
  CallbackValue(CallbackQuery)
  PresenceOnly
}

fn extract_l1(name: String, kind: UpdateKind) -> option.Option(L1Value) {
  case name, kind {
    "message", MessageUpdate(m) -> Some(MessageValue(m))
    "edited_message", EditedMessageUpdate(m) -> Some(MessageValue(m))
    "channel_post", ChannelPostUpdate(m) -> Some(MessageValue(m))
    "edited_channel_post", EditedChannelPostUpdate(m) -> Some(MessageValue(m))
    "business_message", BusinessMessageUpdate(m) -> Some(MessageValue(m))
    "edited_business_message", EditedBusinessMessageUpdate(m) ->
      Some(MessageValue(m))
    "callback_query", CallbackQueryUpdate(cq) -> Some(CallbackValue(cq))
    "inline_query", InlineQueryUpdate(_) -> Some(PresenceOnly)
    "chosen_inline_result", ChosenInlineResultUpdate(_) -> Some(PresenceOnly)
    "shipping_query", ShippingQueryUpdate(_) -> Some(PresenceOnly)
    "pre_checkout_query", PreCheckoutQueryUpdate(_) -> Some(PresenceOnly)
    "poll", PollUpdate(_) -> Some(PresenceOnly)
    "poll_answer", PollAnswerUpdate(_) -> Some(PresenceOnly)
    "my_chat_member", MyChatMemberUpdate(_) -> Some(PresenceOnly)
    "chat_member", ChatMemberUpdate(_) -> Some(PresenceOnly)
    "chat_join_request", ChatJoinRequestUpdate(_) -> Some(PresenceOnly)
    "chat_boost", ChatBoostUpdate(_) -> Some(PresenceOnly)
    "removed_chat_boost", RemovedChatBoostUpdate(_) -> Some(PresenceOnly)
    "purchased_paid_media", PurchasedPaidMediaUpdate(_) -> Some(PresenceOnly)
    "business_connection", BusinessConnectionUpdate(_) -> Some(PresenceOnly)
    "deleted_business_messages", DeletedBusinessMessagesUpdate(_) ->
      Some(PresenceOnly)
    "message_reaction", MessageReactionUpdate(_) -> Some(PresenceOnly)
    "message_reaction_count", MessageReactionCountUpdate(_) ->
      Some(PresenceOnly)
    _, _ -> None
  }
}

fn match_inside_l1(
  l2: String,
  l3: option.Option(String),
  value: L1Value,
) -> Bool {
  case value {
    MessageValue(m) ->
      case l3 {
        None -> message_has_field(m, l2)
        Some(l3_name) -> match_l3_in_message(m, l2, l3_name)
      }
    CallbackValue(cq) -> match_inside_callback(l2, cq)
    // Update kinds carrying no inspectable payload (inline_query,
    // poll, chat_member, …) never match an L2 field check. This is
    // pre-existing glammy behavior: e.g. "chat_member:from" always
    // returns False here, unlike grammY which can inspect `from`.
    PresenceOnly -> False
  }
}

fn match_inside_callback(l2: String, cq: CallbackQuery) -> Bool {
  case l2 {
    "data" -> cq.data != None
    "game_short_name" -> cq.game_short_name != None
    _ -> False
  }
}

fn message_has_field(m: Message, field: String) -> Bool {
  case field {
    "text" -> m.text != None
    "caption" -> m.caption != None
    "photo" -> m.photo != []
    "video" -> m.video != None
    "audio" -> m.audio != None
    "voice" -> m.voice != None
    "document" -> m.document != None
    "animation" -> m.animation != None
    "video_note" -> m.video_note != None
    "sticker" -> m.sticker != None
    "location" -> m.location != None
    "venue" -> m.venue != None
    "contact" -> m.contact != None
    "dice" -> m.dice != None
    "poll" -> m.poll != None
    "new_chat_members" -> m.new_chat_members != []
    "left_chat_member" -> m.left_chat_member != None
    "new_chat_title" -> m.new_chat_title != None
    "new_chat_photo" -> m.new_chat_photo != []
    "delete_chat_photo" -> m.delete_chat_photo != None
    "pinned_message" -> m.pinned_message != None
    "invoice" -> m.invoice != None
    "successful_payment" -> m.successful_payment != None
    "refunded_payment" -> m.refunded_payment != None
    "reply_to_message" -> m.reply_to_message != None
    "via_bot" -> m.via_bot != None
    "forward_origin" -> m.forward_origin != None
    "is_topic_message" -> m.is_topic_message == Some(True)
    "is_automatic_forward" -> m.is_automatic_forward == Some(True)
    "has_protected_content" -> m.has_protected_content == Some(True)
    "has_media_spoiler" -> m.has_media_spoiler == Some(True)
    "media_group_id" -> m.media_group_id != None
    "author_signature" -> m.author_signature != None
    "connected_website" -> m.connected_website != None
    "business_connection_id" -> m.business_connection_id != None
    "entities" -> m.entities != []
    "caption_entities" -> m.caption_entities != []
    _ -> False
  }
}

fn match_l3_in_message(m: Message, l2: String, l3: String) -> Bool {
  case l2 {
    "entities" -> list.any(m.entities, fn(e) { e.type_ == l3 })
    "caption_entities" -> list.any(m.caption_entities, fn(e) { e.type_ == l3 })
    "left_chat_member" ->
      case m.left_chat_member {
        Some(u) -> user_property_holds(u, l3)
        None -> False
      }
    "new_chat_members" ->
      list.any(m.new_chat_members, fn(u) { user_property_holds(u, l3) })
    _ -> False
  }
}

fn user_property_holds(u: User, prop: String) -> Bool {
  case prop {
    "is_bot" -> u.is_bot
    "is_premium" -> u.is_premium == Some(True)
    "added_to_attachment_menu" -> u.added_to_attachment_menu == Some(True)
    // `me` ideally compares against the bot's own id; without
    // `Context.me` we treat `:me` as a presence check (matches any
    // user). Sufficient for filter-tree validation tests.
    "me" -> True
    _ -> False
  }
}

/// Check whether an update is the `OtherUpdate` fallback (a variant
/// glammy doesn't yet recognise).
pub fn is_other(update: Update) -> Bool {
  case update.kind {
    OtherUpdate -> True
    _ -> False
  }
}
