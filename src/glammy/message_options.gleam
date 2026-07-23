//// Typed message-level options shared by Telegram send methods.

import glammy/internal/json_utils
import glammy/parse_mode.{type ParseMode}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}

/// A chat used by `ReplyParameters` when replying across chats.
pub type ReplyChatId {
  /// A numeric Telegram chat identifier.
  ReplyChatIntId(Int)
  /// A public channel or supergroup username such as `@channel`.
  ReplyChatUsername(String)
}

/// A quoted fragment attached to a regular reply.
pub type ReplyQuote {
  ReplyQuote(text: String, parse_mode: Option(ParseMode), position: Option(Int))
}

/// Typed subset of Telegram's `ReplyParameters`.
///
/// Separate same-chat and cross-chat variants prevent forbidden field
/// combinations. Ephemeral replies are represented by `MessageDelivery`,
/// which also carries their required receiver. Quote entity lists remain through
/// `api.prepare_json_call` until outbound message entities are modelled.
pub type ReplyParameters {
  /// Reply inside the target chat. Telegram may ignore a missing source when
  /// `allow_sending_without_reply` is true.
  SameChatReplyParameters(
    message_id: Int,
    allow_sending_without_reply: Option(Bool),
    quote: Option(ReplyQuote),
    checklist_task_id: Option(Int),
    poll_option_id: Option(String),
  )
  /// Reply across chats. Telegram requires the source message to exist, so
  /// this variant cannot carry `allow_sending_without_reply`.
  CrossChatReplyParameters(
    message_id: Int,
    chat_id: ReplyChatId,
    quote: Option(ReplyQuote),
    checklist_task_id: Option(Int),
    poll_option_id: Option(String),
  )
}

/// Mutually exclusive addressing for one outbound message.
///
/// Telegram requires `receiver_user_id` for ephemeral delivery and only
/// accepts `callback_query_id` and ephemeral reply ids in that mode. Keeping
/// the variants opaque makes those cross-field invariants structural.
pub opaque type MessageDelivery {
  StandardMessageDelivery(reply_parameters: Option(ReplyParameters))
  EphemeralMessageDelivery(
    receiver_user_id: Int,
    callback_query_id: Option(String),
    reply_to_ephemeral_message_id: Option(Int),
  )
}

/// Build default parameters for replying inside the target chat.
pub fn reply_to_message(message_id: Int) -> ReplyParameters {
  SameChatReplyParameters(
    message_id:,
    allow_sending_without_reply: None,
    quote: None,
    checklist_task_id: None,
    poll_option_id: None,
  )
}

/// Build default parameters for replying to a message in another chat.
pub fn reply_to_message_in_chat(
  message_id: Int,
  chat_id: ReplyChatId,
) -> ReplyParameters {
  CrossChatReplyParameters(
    message_id:,
    chat_id:,
    quote: None,
    checklist_task_id: None,
    poll_option_id: None,
  )
}

/// Deliver a regular message without replying.
pub fn standard_delivery() -> MessageDelivery {
  StandardMessageDelivery(reply_parameters: None)
}

/// Deliver a regular reply in the same chat or across chats.
pub fn reply_delivery(parameters: ReplyParameters) -> MessageDelivery {
  StandardMessageDelivery(reply_parameters: Some(parameters))
}

/// Deliver an ephemeral message to one required receiver.
///
/// Supply the callback query only when this send answers it, and the ephemeral
/// message id only when this send is itself a reply.
pub fn ephemeral_delivery(
  receiver_user_id: Int,
  callback_query_id: Option(String),
  reply_to_ephemeral_message_id: Option(Int),
) -> MessageDelivery {
  EphemeralMessageDelivery(
    receiver_user_id:,
    callback_query_id:,
    reply_to_ephemeral_message_id:,
  )
}

/// Encode `ReplyParameters` for a Bot API payload.
pub fn reply_parameters_to_json(parameters: ReplyParameters) -> json.Json {
  case parameters {
    SameChatReplyParameters(
      message_id:,
      allow_sending_without_reply:,
      quote:,
      checklist_task_id:,
      poll_option_id:,
    ) ->
      message_reply_fields(message_id, quote, checklist_task_id, poll_option_id)
      |> json_utils.put_optional(
        "allow_sending_without_reply",
        allow_sending_without_reply,
        json.bool,
      )
      |> json.object
    CrossChatReplyParameters(
      message_id:,
      chat_id:,
      quote:,
      checklist_task_id:,
      poll_option_id:,
    ) ->
      message_reply_fields(message_id, quote, checklist_task_id, poll_option_id)
      |> list_prepend_chat_id(chat_id)
      |> json.object
  }
}

/// Encode delivery-only fields for a JSON Bot API request.
pub fn delivery_json_fields(
  delivery: MessageDelivery,
) -> List(#(String, json.Json)) {
  case delivery {
    StandardMessageDelivery(reply_parameters: None) -> []
    StandardMessageDelivery(reply_parameters: Some(parameters)) -> [
      #("reply_parameters", reply_parameters_to_json(parameters)),
    ]
    EphemeralMessageDelivery(
      receiver_user_id:,
      callback_query_id:,
      reply_to_ephemeral_message_id:,
    ) ->
      [#("receiver_user_id", json.int(receiver_user_id))]
      |> json_utils.put_optional(
        "callback_query_id",
        callback_query_id,
        json.string,
      )
      |> json_utils.put_optional(
        "reply_parameters",
        reply_to_ephemeral_message_id,
        fn(ephemeral_message_id) {
          json.object([
            #("ephemeral_message_id", json.int(ephemeral_message_id)),
          ])
        },
      )
  }
}

/// Encode delivery-only fields for a multipart Bot API request.
pub fn delivery_text_fields(
  delivery: MessageDelivery,
) -> List(#(String, String)) {
  case delivery {
    StandardMessageDelivery(reply_parameters: None) -> []
    StandardMessageDelivery(reply_parameters: Some(parameters)) -> [
      #(
        "reply_parameters",
        parameters |> reply_parameters_to_json |> json.to_string,
      ),
    ]
    EphemeralMessageDelivery(
      receiver_user_id:,
      callback_query_id:,
      reply_to_ephemeral_message_id:,
    ) -> {
      let fields = [#("receiver_user_id", int.to_string(receiver_user_id))]
      let fields = case callback_query_id {
        Some(value) -> [#("callback_query_id", value), ..fields]
        None -> fields
      }
      case reply_to_ephemeral_message_id {
        Some(ephemeral_message_id) -> [
          #(
            "reply_parameters",
            json.object([
              #("ephemeral_message_id", json.int(ephemeral_message_id)),
            ])
              |> json.to_string,
          ),
          ..fields
        ]
        None -> fields
      }
    }
  }
}

fn message_reply_fields(
  message_id: Int,
  quote: Option(ReplyQuote),
  checklist_task_id: Option(Int),
  poll_option_id: Option(String),
) -> List(#(String, json.Json)) {
  let fields = [#("message_id", json.int(message_id))]
  let fields = case quote {
    None -> fields
    Some(ReplyQuote(text:, parse_mode: quote_parse_mode, position:)) -> {
      let fields = [#("quote", json.string(text)), ..fields]
      fields
      |> json_utils.put_optional("quote_parse_mode", quote_parse_mode, fn(mode) {
        json.string(parse_mode.to_string(mode))
      })
      |> json_utils.put_optional("quote_position", position, json.int)
    }
  }
  fields
  |> json_utils.put_optional("checklist_task_id", checklist_task_id, json.int)
  |> json_utils.put_optional("poll_option_id", poll_option_id, json.string)
}

fn list_prepend_chat_id(
  fields: List(#(String, json.Json)),
  chat_id: ReplyChatId,
) -> List(#(String, json.Json)) {
  let encoded = case chat_id {
    ReplyChatIntId(value) -> json.int(value)
    ReplyChatUsername(value) -> json.string(value)
  }
  [#("chat_id", encoded), ..fields]
}
