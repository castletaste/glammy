import glammy/types
import gleam/json
import gleam/option.{None, Some}

pub fn decodes_poll_update_test() {
  let body =
    "{
      \"update_id\":10,
      \"poll\":{
        \"id\":\"p1\",
        \"question\":\"Yes?\",
        \"options\":[{\"text\":\"y\",\"voter_count\":1},{\"text\":\"n\",\"voter_count\":0}],
        \"total_voter_count\":1,
        \"is_closed\":false,
        \"is_anonymous\":true,
        \"type\":\"regular\",
        \"allows_multiple_answers\":false
      }
    }"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  case u.kind {
    types.PollUpdate(p) -> {
      assert p.question == "Yes?"
      assert p.total_voter_count == 1
    }
    _ -> panic as "expected PollUpdate"
  }
}

pub fn decodes_chat_member_update_test() {
  let body =
    "{
      \"update_id\":11,
      \"chat_member\":{
        \"chat\":{\"id\":1,\"type\":\"supergroup\",\"title\":\"G\"},
        \"from\":{\"id\":2,\"is_bot\":false,\"first_name\":\"A\"},
        \"date\":1700000000,
        \"old_chat_member\":{\"status\":\"member\",\"user\":{\"id\":3,\"is_bot\":false,\"first_name\":\"B\"}},
        \"new_chat_member\":{\"status\":\"left\",\"user\":{\"id\":3,\"is_bot\":false,\"first_name\":\"B\"}}
      }
    }"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  case u.kind {
    types.ChatMemberUpdate(c) -> {
      assert c.chat.id == 1
      case c.old_chat_member {
        types.ChatMemberMember(u, _) -> {
          assert u.first_name == "B"
        }
        _ -> panic as "expected ChatMemberMember"
      }
      case c.new_chat_member {
        types.ChatMemberLeft(u) -> {
          assert u.first_name == "B"
        }
        _ -> panic as "expected ChatMemberLeft"
      }
    }
    _ -> panic as "expected ChatMemberUpdate"
  }
}

pub fn decodes_chat_join_request_test() {
  let body =
    "{
      \"update_id\":12,
      \"chat_join_request\":{
        \"chat\":{\"id\":-100,\"type\":\"channel\",\"title\":\"Ch\"},
        \"from\":{\"id\":99,\"is_bot\":false,\"first_name\":\"User\"},
        \"user_chat_id\":99,
        \"date\":1700000000
      }
    }"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  case u.kind {
    types.ChatJoinRequestUpdate(r) -> {
      assert r.user_chat_id == 99
      assert r.from.first_name == "User"
    }
    _ -> panic as "expected ChatJoinRequestUpdate"
  }
}

pub fn decodes_pre_checkout_query_test() {
  let body =
    "{
      \"update_id\":13,
      \"pre_checkout_query\":{
        \"id\":\"pc1\",
        \"from\":{\"id\":1,\"is_bot\":false,\"first_name\":\"Buyer\"},
        \"currency\":\"USD\",
        \"total_amount\":1000,
        \"invoice_payload\":\"order-42\"
      }
    }"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  case u.kind {
    types.PreCheckoutQueryUpdate(p) -> {
      assert p.currency == "USD"
      assert p.total_amount == 1000
      assert p.invoice_payload == "order-42"
    }
    _ -> panic as "expected PreCheckoutQueryUpdate"
  }
}

pub fn decodes_reaction_update_test() {
  let body =
    "{
      \"update_id\":14,
      \"message_reaction\":{
        \"chat\":{\"id\":1,\"type\":\"group\",\"title\":\"G\"},
        \"message_id\":42,
        \"user\":{\"id\":2,\"is_bot\":false,\"first_name\":\"R\"},
        \"date\":1700000000,
        \"old_reaction\":[],
        \"new_reaction\":[{\"type\":\"emoji\",\"emoji\":\"🔥\"}]
      }
    }"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  case u.kind {
    types.MessageReactionUpdate(r) -> {
      assert r.message_id == 42
      case r.new_reaction {
        [types.ReactionEmoji(e)] -> {
          assert e == "🔥"
        }
        _ -> panic as "expected single ReactionEmoji"
      }
    }
    _ -> panic as "expected MessageReactionUpdate"
  }
}

pub fn decodes_message_with_photo_test() {
  let body =
    "{
      \"update_id\":15,
      \"message\":{
        \"message_id\":1,
        \"chat\":{\"id\":1,\"type\":\"private\"},
        \"date\":0,
        \"photo\":[
          {\"file_id\":\"a\",\"file_unique_id\":\"ua\",\"width\":90,\"height\":90,\"file_size\":1000},
          {\"file_id\":\"b\",\"file_unique_id\":\"ub\",\"width\":320,\"height\":320,\"file_size\":2000}
        ],
        \"caption\":\"a kitten\"
      }
    }"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  case u.kind {
    types.MessageUpdate(m) -> {
      assert m.caption == Some("a kitten")
      case m.photo {
        [first, _] -> {
          assert first.width == 90
          assert first.file_size == Some(1000)
        }
        _ -> panic as "expected two photo sizes"
      }
    }
    _ -> panic as "expected MessageUpdate"
  }
}

pub fn webhook_info_decoder_test() {
  let body =
    "{
      \"url\":\"https://example.com/wh\",
      \"has_custom_certificate\":false,
      \"pending_update_count\":0,
      \"allowed_updates\":[\"message\",\"callback_query\"]
    }"
  let assert Ok(w) = json.parse(body, types.webhook_info_decoder())
  assert w.url == "https://example.com/wh"
  assert w.has_custom_certificate == False
  assert w.allowed_updates == ["message", "callback_query"]
  assert w.ip_address == None
}
