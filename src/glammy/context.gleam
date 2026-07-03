//// The `Context` value passed to every middleware. Wraps the incoming
//// `Update` together with the `Api` client, and exposes convenience
//// accessors and a few `reply` shortcuts — same pattern as grammY's
//// `src/context.ts`, just trimmed down.

import glammy/api.{type Api, type SendMessageOptions, ChatIntId}
import glammy/error.{type GlammyError}
import glammy/types.{
  type CallbackQuery, type Chat, type ChatJoinRequest, type ChatMemberUpdated,
  type ChosenInlineResult, type InlineQuery, type Message, type PreCheckoutQuery,
  type ShippingQuery, type Update, type UpdateKind, type User,
  BusinessConnectionUpdate, BusinessMessageUpdate, CallbackQueryUpdate,
  ChannelPostUpdate, ChatBoostUpdate, ChatJoinRequestUpdate, ChatMemberUpdate,
  ChosenInlineResultUpdate, DeletedBusinessMessagesUpdate,
  EditedBusinessMessageUpdate, EditedChannelPostUpdate, EditedMessageUpdate,
  InlineQueryUpdate, MessageReactionCountUpdate, MessageReactionUpdate,
  MessageUpdate, MyChatMemberUpdate, OtherUpdate, PollAnswerUpdate, PollUpdate,
  PreCheckoutQueryUpdate, PurchasedPaidMediaUpdate, RemovedChatBoostUpdate,
  ShippingQueryUpdate,
}
import gleam/option.{type Option, None, Some}

pub type Context {
  Context(update: Update, api: Api)
}

/// Wrap an incoming `Update` and `Api` client into a `Context`.
pub fn new(update: Update, api: Api) -> Context {
  Context(update:, api:)
}

/// The message attached to whichever update variant carries one. For
/// `callback_query` we surface the message that the inline keyboard was
/// attached to (same as `ctx.msg` in grammY).
pub fn message(ctx: Context) -> Option(Message) {
  case ctx.update.kind {
    MessageUpdate(m) -> Some(m)
    EditedMessageUpdate(m) -> Some(m)
    ChannelPostUpdate(m) -> Some(m)
    EditedChannelPostUpdate(m) -> Some(m)
    BusinessMessageUpdate(m) -> Some(m)
    EditedBusinessMessageUpdate(m) -> Some(m)
    CallbackQueryUpdate(cq) -> cq.message
    _ -> None
  }
}

/// The chat associated with this update, when Telegram provides one.
pub fn chat(ctx: Context) -> Option(Chat) {
  case message(ctx) {
    Some(m) -> Some(m.chat)
    None ->
      case ctx.update.kind {
        MessageReactionUpdate(r) -> Some(r.chat)
        MessageReactionCountUpdate(r) -> Some(r.chat)
        MyChatMemberUpdate(c) -> Some(c.chat)
        ChatMemberUpdate(c) -> Some(c.chat)
        ChatJoinRequestUpdate(c) -> Some(c.chat)
        ChatBoostUpdate(b) -> Some(b.chat)
        RemovedChatBoostUpdate(b) -> Some(b.chat)
        DeletedBusinessMessagesUpdate(b) -> Some(b.chat)
        _ -> None
      }
  }
}

/// The user who triggered this update, when Telegram provides one.
pub fn from(ctx: Context) -> Option(User) {
  case ctx.update.kind {
    MessageUpdate(m) -> m.from
    EditedMessageUpdate(m) -> m.from
    ChannelPostUpdate(m) -> m.from
    EditedChannelPostUpdate(m) -> m.from
    BusinessConnectionUpdate(b) -> Some(b.user)
    BusinessMessageUpdate(m) -> m.from
    EditedBusinessMessageUpdate(m) -> m.from
    CallbackQueryUpdate(cq) -> Some(cq.from)
    InlineQueryUpdate(iq) -> Some(iq.from)
    ChosenInlineResultUpdate(c) -> Some(c.from)
    ShippingQueryUpdate(s) -> Some(s.from)
    PreCheckoutQueryUpdate(p) -> Some(p.from)
    MyChatMemberUpdate(c) -> Some(c.from)
    ChatMemberUpdate(c) -> Some(c.from)
    ChatJoinRequestUpdate(c) -> Some(c.from)
    MessageReactionUpdate(r) -> r.user
    PurchasedPaidMediaUpdate(p) -> Some(p.from)
    _ -> None
  }
}

/// Return the callback query carried by this update, if any.
pub fn callback_query(ctx: Context) -> Option(CallbackQuery) {
  case ctx.update.kind {
    CallbackQueryUpdate(cq) -> Some(cq)
    _ -> None
  }
}

/// Return the inline query carried by this update, if any.
pub fn inline_query(ctx: Context) -> Option(InlineQuery) {
  case ctx.update.kind {
    InlineQueryUpdate(q) -> Some(q)
    _ -> None
  }
}

/// Return the chosen inline result carried by this update, if any.
pub fn chosen_inline_result(ctx: Context) -> Option(ChosenInlineResult) {
  case ctx.update.kind {
    ChosenInlineResultUpdate(r) -> Some(r)
    _ -> None
  }
}

/// Return the shipping query carried by this update, if any.
pub fn shipping_query(ctx: Context) -> Option(ShippingQuery) {
  case ctx.update.kind {
    ShippingQueryUpdate(q) -> Some(q)
    _ -> None
  }
}

/// Return the pre-checkout query carried by this update, if any.
pub fn pre_checkout_query(ctx: Context) -> Option(PreCheckoutQuery) {
  case ctx.update.kind {
    PreCheckoutQueryUpdate(q) -> Some(q)
    _ -> None
  }
}

/// Return the bot's own chat-member update, if present.
pub fn my_chat_member(ctx: Context) -> Option(ChatMemberUpdated) {
  case ctx.update.kind {
    MyChatMemberUpdate(c) -> Some(c)
    _ -> None
  }
}

/// Return a chat-member update, if present.
pub fn chat_member(ctx: Context) -> Option(ChatMemberUpdated) {
  case ctx.update.kind {
    ChatMemberUpdate(c) -> Some(c)
    _ -> None
  }
}

/// Return a chat join request, if present.
pub fn chat_join_request(ctx: Context) -> Option(ChatJoinRequest) {
  case ctx.update.kind {
    ChatJoinRequestUpdate(c) -> Some(c)
    _ -> None
  }
}

/// The text of the current message, when this update carries one.
pub fn message_text(ctx: Context) -> Option(String) {
  option.then(message(ctx), fn(m) { m.text })
}

/// The `message_id` of whichever update carries one — message,
/// reaction, channel post, business message, …
pub fn message_id(ctx: Context) -> Option(Int) {
  case message(ctx) {
    Some(m) -> Some(m.message_id)
    None ->
      case ctx.update.kind {
        MessageReactionUpdate(r) -> Some(r.message_id)
        MessageReactionCountUpdate(r) -> Some(r.message_id)
        _ -> None
      }
  }
}

/// The chat id of whichever update carries a chat.
pub fn chat_id(ctx: Context) -> Option(Int) {
  option.map(chat(ctx), fn(c) { c.id })
}

/// The `inline_message_id` carried by callback queries on inline-mode
/// keyboards and chosen-inline-result updates.
pub fn inline_message_id(ctx: Context) -> Option(String) {
  case ctx.update.kind {
    CallbackQueryUpdate(cq) -> cq.inline_message_id
    ChosenInlineResultUpdate(r) -> r.inline_message_id
    _ -> None
  }
}

/// The `business_connection_id` of whichever update carries one.
pub fn business_connection_id(ctx: Context) -> Option(String) {
  case ctx.update.kind {
    BusinessConnectionUpdate(b) -> Some(b.id)
    DeletedBusinessMessagesUpdate(d) -> Some(d.business_connection_id)
    _ ->
      case message(ctx) {
        Some(m) -> m.business_connection_id
        None -> None
      }
  }
}

/// Convenience: does this update carry a callback query with exactly
/// the given `data` payload?
pub fn has_callback_data(ctx: Context, data: String) -> Bool {
  case callback_query(ctx) {
    Some(cq) -> cq.data == Some(data)
    None -> False
  }
}

/// The sender chat of a message-bearing update, if any. Distinct from
/// `chat` — useful for channel posts forwarded as anonymous group
/// admin messages.
pub fn sender_chat(ctx: Context) -> Option(Chat) {
  option.then(message(ctx), fn(m) { m.sender_chat })
}

/// Expose the raw `UpdateKind` for lower-level branching.
pub fn update_kind(ctx: Context) -> UpdateKind {
  ctx.update.kind
}

/// Check whether this update is the `OtherUpdate` fallback.
pub fn is_other_update(ctx: Context) -> Bool {
  case ctx.update.kind {
    OtherUpdate -> True
    _ -> False
  }
}

/// Return the poll id from `poll` or `poll_answer` updates.
pub fn poll_answer_or_poll_id(ctx: Context) -> Option(String) {
  case ctx.update.kind {
    PollUpdate(p) -> Some(p.id)
    PollAnswerUpdate(p) -> Some(p.poll_id)
    _ -> None
  }
}

// ---------- reply shortcuts ----------

/// Send a text message back to the chat the current update belongs to.
/// If there's no associated chat (e.g. inline-query updates), returns
/// `Error(NoChatInContext)` without making any HTTP call.
pub type ReplyError {
  NoChatInContext
  ReplyApiError(GlammyError)
}

/// Send a plain text reply using default `SendMessageOptions`.
pub fn reply(ctx: Context, text: String) -> Result(Message, ReplyError) {
  reply_with(ctx, text, api.default_send_message_options())
}

/// Send a text reply with explicit `SendMessageOptions`.
pub fn reply_with(
  ctx: Context,
  text: String,
  options: SendMessageOptions,
) -> Result(Message, ReplyError) {
  case chat(ctx) {
    None -> Error(NoChatInContext)
    Some(c) ->
      case api.send_message(ctx.api, ChatIntId(c.id), text, options) {
        Ok(m) -> Ok(m)
        Error(e) -> Error(ReplyApiError(e))
      }
  }
}
