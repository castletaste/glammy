//// Tests mirroring grammY's `test/context.test.ts`. Covers update
//// shortcuts and value aggregators (msg, chat, from, msg_id, chat_id,
//// inline_message_id, business_connection_id).

import glammy/api
import glammy/context
import glammy/helpers.{ctx_from, receive_event, update_from}
import glammy/types.{Data}
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string

const message_update = "{\"update_id\":1,\"message\":{\"message_id\":42,\"date\":1700000000,\"chat\":{\"id\":100,\"type\":\"private\"},\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"X\"},\"text\":\"a\",\"sender_chat\":{\"id\":200,\"type\":\"channel\",\"title\":\"ch\"}}}"

const edited_message_update = "{\"update_id\":2,\"edited_message\":{\"message_id\":1,\"date\":0,\"chat\":{\"id\":1,\"type\":\"private\"},\"text\":\"a\"}}"

const channel_post_update = "{\"update_id\":3,\"channel_post\":{\"message_id\":1,\"date\":0,\"chat\":{\"id\":-100,\"type\":\"channel\",\"title\":\"ch\"},\"text\":\"a\"}}"

const guest_message_update = "{\"update_id\":11,\"guest_message\":{\"message_id\":2,\"date\":0,\"chat\":{\"id\":100,\"type\":\"private\"},\"from\":{\"id\":8,\"is_bot\":false,\"first_name\":\"Guest\"},\"guest_query_id\":\"guest-11\",\"text\":\"hi\"}}"

const callback_query_update = "{\"update_id\":4,\"callback_query\":{\"id\":\"cq\",\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"chat_instance\":\"i\",\"data\":\"cb\",\"inline_message_id\":\"y\"}}"

const callback_accessible_message_update = "{\"update_id\":18,\"callback_query\":{\"id\":\"accessible\",\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"message\":{\"message_id\":43,\"date\":1,\"chat\":{\"id\":101,\"type\":\"private\"},\"text\":\"button\"},\"chat_instance\":\"i\",\"data\":\"open\"}}"

const callback_inaccessible_message_update = "{\"update_id\":19,\"callback_query\":{\"id\":\"inaccessible\",\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"message\":{\"message_id\":44,\"date\":0,\"chat\":{\"id\":102,\"type\":\"private\"}},\"chat_instance\":\"i\",\"data\":\"open\"}}"

const inline_query_update = "{\"update_id\":5,\"inline_query\":{\"id\":\"iq\",\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"query\":\"q\",\"offset\":\"\"}}"

const chosen_inline_result_update = "{\"update_id\":6,\"chosen_inline_result\":{\"result_id\":\"p\",\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"inline_message_id\":\"x\",\"query\":\"q\"}}"

const business_connection_update = "{\"update_id\":7,\"business_connection\":{\"id\":\"conn\",\"user\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"user_chat_id\":700,\"date\":1112734,\"rights\":{\"can_reply\":true,\"can_read_messages\":true},\"is_enabled\":true}}"

const business_message_update = "{\"update_id\":17,\"business_message\":{\"message_id\":3,\"business_connection_id\":\"message-conn\",\"date\":0,\"chat\":{\"id\":701,\"type\":\"private\"},\"text\":\"hi\"}}"

const deleted_business_messages_update = "{\"update_id\":8,\"deleted_business_messages\":{\"business_connection_id\":\"conn\",\"chat\":{\"id\":100,\"type\":\"private\"},\"message_ids\":[1,2,3]}}"

const message_reaction_update = "{\"update_id\":9,\"message_reaction\":{\"chat\":{\"id\":100,\"type\":\"private\"},\"message_id\":2,\"date\":42,\"user\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"old_reaction\":[],\"new_reaction\":[{\"type\":\"emoji\",\"emoji\":\"👍\"}]}}"

const my_chat_member_update = "{\"update_id\":10,\"my_chat_member\":{\"chat\":{\"id\":100,\"type\":\"private\"},\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"date\":1,\"old_chat_member\":{\"status\":\"member\",\"user\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"}},\"new_chat_member\":{\"status\":\"left\",\"user\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"}}}}"

const poll_answer_user_update = "{\"update_id\":12,\"poll_answer\":{\"poll_id\":\"p\",\"user\":{\"id\":9,\"is_bot\":false,\"first_name\":\"Voter\"},\"option_ids\":[0],\"option_persistent_ids\":[]}}"

const poll_answer_chat_update = "{\"update_id\":13,\"poll_answer\":{\"poll_id\":\"p\",\"voter_chat\":{\"id\":300,\"type\":\"channel\",\"title\":\"Anonymous\"},\"option_ids\":[0],\"option_persistent_ids\":[]}}"

const premium_chat_boost_update = "{\"update_id\":14,\"chat_boost\":{\"chat\":{\"id\":400,\"type\":\"supergroup\",\"title\":\"Boosted\"},\"boost\":{\"boost_id\":\"premium\",\"add_date\":1,\"expiration_date\":2,\"source\":{\"source\":\"premium\",\"user\":{\"id\":14,\"is_bot\":false,\"first_name\":\"Premium\"}}}}}"

const gift_code_removed_chat_boost_update = "{\"update_id\":15,\"removed_chat_boost\":{\"chat\":{\"id\":400,\"type\":\"supergroup\",\"title\":\"Boosted\"},\"boost_id\":\"gift\",\"remove_date\":3,\"source\":{\"source\":\"gift_code\",\"user\":{\"id\":15,\"is_bot\":false,\"first_name\":\"Gift\"}}}}"

const giveaway_removed_chat_boost_update = "{\"update_id\":16,\"removed_chat_boost\":{\"chat\":{\"id\":400,\"type\":\"supergroup\",\"title\":\"Boosted\"},\"boost_id\":\"giveaway\",\"remove_date\":3,\"source\":{\"source\":\"giveaway\",\"giveaway_message_id\":9,\"user\":{\"id\":16,\"is_bot\":false,\"first_name\":\"Winner\"}}}}"

// =====================================================================
//                          Basic properties
// =====================================================================

pub fn provides_basic_properties_test() {
  let ctx = ctx_from(message_update)
  assert ctx.update.update_id == 1
}

// =====================================================================
//                          .msg aggregator
// =====================================================================

pub fn message_aggregates_messages_test() {
  case context.message(ctx_from(message_update)) {
    Some(m) -> {
      assert m.message_id == 42
    }
    None -> panic as "expected message"
  }
  case context.message(ctx_from(edited_message_update)) {
    Some(_) -> Nil
    None -> panic as "expected edited message"
  }
  case context.message(ctx_from(channel_post_update)) {
    Some(_) -> Nil
    None -> panic as "expected channel post"
  }
  case context.message(ctx_from(callback_query_update)) {
    None -> Nil
    _ -> panic as "callback_query without nested message shouldn't surface one"
  }
  case context.message(ctx_from(callback_accessible_message_update)) {
    Some(message) -> {
      assert message.message_id == 43
    }
    None -> panic as "expected accessible callback message"
  }
  assert context.message(ctx_from(callback_inaccessible_message_update)) == None
}

// =====================================================================
//                          .chat aggregator
// =====================================================================

pub fn chat_aggregates_chats_test() {
  case context.chat(ctx_from(message_update)) {
    Some(c) -> {
      assert c.id == 100
    }
    None -> panic as "expected chat"
  }
  case context.chat(ctx_from(deleted_business_messages_update)) {
    Some(c) -> {
      assert c.id == 100
    }
    None -> panic as "expected chat from deleted_business_messages"
  }
  case context.chat(ctx_from(message_reaction_update)) {
    Some(c) -> {
      assert c.id == 100
    }
    None -> panic as "expected chat from message_reaction"
  }
  case context.chat(ctx_from(my_chat_member_update)) {
    Some(c) -> {
      assert c.id == 100
    }
    None -> panic as "expected chat from my_chat_member"
  }
  case context.chat(ctx_from(poll_answer_chat_update)) {
    Some(chat) -> {
      assert chat.id == 300
    }
    None -> panic as "expected voter_chat from poll_answer"
  }
  let assert Some(accessible_chat) =
    context.chat(ctx_from(callback_accessible_message_update))
  assert accessible_chat.id == 101
  let assert Some(inaccessible_chat) =
    context.chat(ctx_from(callback_inaccessible_message_update))
  assert inaccessible_chat.id == 102
}

pub fn sender_chat_aggregates_test() {
  case context.sender_chat(ctx_from(message_update)) {
    Some(c) -> {
      assert c.id == 200
    }
    None -> panic as "expected sender_chat"
  }
  assert context.sender_chat(ctx_from(callback_query_update)) == None
}

// =====================================================================
//                          .from aggregator
// =====================================================================

pub fn from_aggregates_user_objects_test() {
  case context.from(ctx_from(business_connection_update)) {
    Some(u) -> {
      assert u.id == 7
    }
    None -> panic as "expected user from business_connection"
  }
  case context.from(ctx_from(message_reaction_update)) {
    Some(u) -> {
      assert u.id == 7
    }
    None -> panic as "expected user from message_reaction"
  }
  case context.from(ctx_from(callback_query_update)) {
    Some(u) -> {
      assert u.id == 7
    }
    None -> panic as "expected user from callback_query"
  }
  case context.from(ctx_from(message_update)) {
    Some(u) -> {
      assert u.id == 7
    }
    None -> panic as "expected user from message"
  }
  case context.from(ctx_from(guest_message_update)) {
    Some(u) -> {
      assert u.id == 8
    }
    None -> panic as "expected user from guest_message"
  }
  case context.from(ctx_from(inline_query_update)) {
    Some(u) -> {
      assert u.id == 7
    }
    None -> panic as "expected user from inline_query"
  }
  case context.from(ctx_from(chosen_inline_result_update)) {
    Some(u) -> {
      assert u.id == 7
    }
    None -> panic as "expected user from chosen_inline_result"
  }
  case context.from(ctx_from(my_chat_member_update)) {
    Some(u) -> {
      assert u.id == 7
    }
    None -> panic as "expected user from my_chat_member"
  }
  case context.from(ctx_from(poll_answer_user_update)) {
    Some(user) -> {
      assert user.id == 9
    }
    None -> panic as "expected user from poll_answer"
  }
  case context.from(ctx_from(premium_chat_boost_update)) {
    Some(user) -> {
      assert user.id == 14
    }
    None -> panic as "expected user from premium chat_boost"
  }
  case context.from(ctx_from(gift_code_removed_chat_boost_update)) {
    Some(user) -> {
      assert user.id == 15
    }
    None -> panic as "expected user from gift-code removed_chat_boost"
  }
  case context.from(ctx_from(giveaway_removed_chat_boost_update)) {
    Some(user) -> {
      assert user.id == 16
    }
    None -> panic as "expected user from giveaway removed_chat_boost"
  }
}

// =====================================================================
//                          .msgId / .chatId
// =====================================================================

pub fn message_id_aggregates_test() {
  assert context.message_id(ctx_from(message_update)) == Some(42)
  assert context.message_id(ctx_from(message_reaction_update)) == Some(2)
  assert context.message_id(ctx_from(callback_query_update)) == None
  assert context.message_id(ctx_from(callback_accessible_message_update))
    == Some(43)
  assert context.message_id(ctx_from(callback_inaccessible_message_update))
    == Some(44)
}

pub fn chat_id_aggregates_test() {
  assert context.chat_id(ctx_from(message_update)) == Some(100)
  assert context.chat_id(ctx_from(business_connection_update)) == Some(700)
  assert context.chat(ctx_from(business_connection_update)) == None
  assert context.chat_id(ctx_from(callback_query_update)) == None
  assert context.chat_id(ctx_from(callback_accessible_message_update))
    == Some(101)
  assert context.chat_id(ctx_from(callback_inaccessible_message_update))
    == Some(102)
}

// =====================================================================
//                       .inlineMessageId
// =====================================================================

pub fn inline_message_id_aggregates_test() {
  assert context.inline_message_id(ctx_from(callback_query_update)) == Some("y")
  assert context.inline_message_id(ctx_from(chosen_inline_result_update))
    == Some("x")
  assert context.inline_message_id(ctx_from(message_update)) == None
}

// =====================================================================
//                       .businessConnectionId
// =====================================================================

pub fn business_connection_id_aggregates_test() {
  assert context.business_connection_id(ctx_from(business_connection_update))
    == Some("conn")
  assert context.business_connection_id(ctx_from(
      deleted_business_messages_update,
    ))
    == Some("conn")
}

pub fn guest_query_id_aggregates_test() {
  assert context.guest_query_id(ctx_from(guest_message_update))
    == Some("guest-11")
  assert context.guest_query_id(ctx_from(message_update)) == None
}

fn reply_context(
  body: String,
  calls: process.Subject(api.Payload),
) -> context.Context {
  let client =
    api.new("token")
    |> api.with_transformer(fn(_next, _method, payload) {
      process.send(calls, payload)
      Ok(
        "{\"ok\":true,\"result\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0}}",
      )
    })
  context.new(update_from(body), client)
}

fn json_payload_text(payload: api.Payload) -> String {
  let assert api.JsonPayload(fields) = payload
  json.object(fields) |> json.to_string
}

pub fn reply_routes_business_connection_update_test() {
  let calls: process.Subject(api.Payload) = process.new_subject()
  let ctx = reply_context(business_connection_update, calls)
  let assert Ok(_) = context.reply(ctx, "reply")
  let assert Ok(payload) = receive_event(calls)
  let text = json_payload_text(payload)
  assert string.contains(text, "\"chat_id\":700")
  assert string.contains(text, "\"business_connection_id\":\"conn\"")
}

pub fn reply_routes_business_message_and_preserves_explicit_connection_test() {
  let calls: process.Subject(api.Payload) = process.new_subject()
  let ctx = reply_context(business_message_update, calls)
  let assert Ok(_) = context.reply(ctx, "default")
  let assert Ok(default_payload) = receive_event(calls)
  let default_text = json_payload_text(default_payload)
  assert string.contains(default_text, "\"chat_id\":701")
  assert string.contains(
    default_text,
    "\"business_connection_id\":\"message-conn\"",
  )

  let options =
    api.SendMessageOptions(
      ..api.default_send_message_options(),
      business_connection_id: Some("explicit-conn"),
    )
  let assert Ok(_) = context.reply_with(ctx, "explicit", options)
  let assert Ok(explicit_payload) = receive_event(calls)
  let explicit_text = json_payload_text(explicit_payload)
  assert string.contains(
    explicit_text,
    "\"business_connection_id\":\"explicit-conn\"",
  )
  assert !string.contains(explicit_text, "message-conn")
}

// =====================================================================
//                       hasCallbackQuery
// =====================================================================

pub fn checks_callback_data_test() {
  let ctx = ctx_from(callback_query_update)
  assert context.has_callback_data(ctx, "cb") == True
  assert context.has_callback_data(ctx, "bb") == False
  // Non-callback update never matches
  assert context.has_callback_data(ctx_from(message_update), "cb") == False
}

// =====================================================================
//                       Update kind shortcuts
// =====================================================================

pub fn inline_query_shortcut_test() {
  case context.inline_query(ctx_from(inline_query_update)) {
    Some(q) -> {
      assert q.id == "iq"
    }
    None -> panic as "expected inline_query"
  }
  assert context.inline_query(ctx_from(message_update)) == None
}

pub fn callback_query_shortcut_test() {
  case context.callback_query(ctx_from(callback_query_update)) {
    Some(q) -> {
      assert q.id == "cq"
      assert q.payload == Data("cb")
    }
    None -> panic as "expected callback_query"
  }
  assert context.callback_query(ctx_from(message_update)) == None
}

pub fn chosen_inline_result_shortcut_test() {
  case context.chosen_inline_result(ctx_from(chosen_inline_result_update)) {
    Some(r) -> {
      assert r.result_id == "p"
    }
    None -> panic as "expected chosen_inline_result"
  }
}

pub fn my_chat_member_shortcut_test() {
  case context.my_chat_member(ctx_from(my_chat_member_update)) {
    Some(c) -> {
      assert c.chat.id == 100
    }
    None -> panic as "expected my_chat_member"
  }
}
