//// Tests mirroring grammY's `test/context.test.ts`. Covers update
//// shortcuts and value aggregators (msg, chat, from, msg_id, chat_id,
//// inline_message_id, business_connection_id).

import glammy/api
import glammy/context
import glammy/types
import gleam/json
import gleam/option.{None, Some}

fn ctx_from(body: String) -> context.Context {
  let assert Ok(u) = json.parse(body, types.update_decoder())
  context.new(u, api.new("0:test"))
}

const message_update = "{\"update_id\":1,\"message\":{\"message_id\":42,\"date\":1700000000,\"chat\":{\"id\":100,\"type\":\"private\"},\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"X\"},\"text\":\"a\",\"sender_chat\":{\"id\":200,\"type\":\"channel\",\"title\":\"ch\"}}}"

const edited_message_update = "{\"update_id\":2,\"edited_message\":{\"message_id\":1,\"date\":0,\"chat\":{\"id\":1,\"type\":\"private\"},\"text\":\"a\"}}"

const channel_post_update = "{\"update_id\":3,\"channel_post\":{\"message_id\":1,\"date\":0,\"chat\":{\"id\":-100,\"type\":\"channel\",\"title\":\"ch\"},\"text\":\"a\"}}"

const callback_query_update = "{\"update_id\":4,\"callback_query\":{\"id\":\"cq\",\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"chat_instance\":\"i\",\"data\":\"cb\",\"inline_message_id\":\"y\"}}"

const inline_query_update = "{\"update_id\":5,\"inline_query\":{\"id\":\"iq\",\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"query\":\"q\",\"offset\":\"\"}}"

const chosen_inline_result_update = "{\"update_id\":6,\"chosen_inline_result\":{\"result_id\":\"p\",\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"inline_message_id\":\"x\",\"query\":\"q\"}}"

const business_connection_update = "{\"update_id\":7,\"business_connection\":{\"id\":\"conn\",\"user\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"user_chat_id\":7,\"date\":1112734,\"is_enabled\":true,\"can_reply\":true}}"

const deleted_business_messages_update = "{\"update_id\":8,\"deleted_business_messages\":{\"business_connection_id\":\"conn\",\"chat\":{\"id\":100,\"type\":\"private\"},\"message_ids\":[1,2,3]}}"

const message_reaction_update = "{\"update_id\":9,\"message_reaction\":{\"chat\":{\"id\":100,\"type\":\"private\"},\"message_id\":2,\"date\":42,\"user\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"old_reaction\":[],\"new_reaction\":[{\"type\":\"emoji\",\"emoji\":\"👍\"}]}}"

const my_chat_member_update = "{\"update_id\":10,\"my_chat_member\":{\"chat\":{\"id\":100,\"type\":\"private\"},\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"},\"date\":1,\"old_chat_member\":{\"status\":\"member\",\"user\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"}},\"new_chat_member\":{\"status\":\"left\",\"user\":{\"id\":7,\"is_bot\":false,\"first_name\":\"U\"}}}}"

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
}

// =====================================================================
//                          .msgId / .chatId
// =====================================================================

pub fn message_id_aggregates_test() {
  assert context.message_id(ctx_from(message_update)) == Some(42)
  assert context.message_id(ctx_from(message_reaction_update)) == Some(2)
  assert context.message_id(ctx_from(callback_query_update)) == None
}

pub fn chat_id_aggregates_test() {
  assert context.chat_id(ctx_from(message_update)) == Some(100)
  assert context.chat_id(ctx_from(callback_query_update)) == None
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
      assert q.data == Some("cb")
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
