import glammy/types.{
  type Update, CallbackQueryUpdate, MessageUpdate, OtherUpdate,
}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string

const message_update_json = "{
    \"update_id\": 100,
    \"message\": {
      \"message_id\": 1,
      \"from\": {
        \"id\": 42,
        \"is_bot\": false,
        \"first_name\": \"Ada\",
        \"username\": \"adalovelace\",
        \"language_code\": \"en\"
      },
      \"chat\": {
        \"id\": 42,
        \"type\": \"private\",
        \"username\": \"adalovelace\",
        \"first_name\": \"Ada\"
      },
      \"date\": 1700000000,
      \"text\": \"/start hello\",
      \"entities\": [
        { \"type\": \"bot_command\", \"offset\": 0, \"length\": 6 }
      ]
    }
  }"

const callback_query_update_json = "{
    \"update_id\": 200,
    \"callback_query\": {
      \"id\": \"cq-1\",
      \"from\": {
        \"id\": 7,
        \"is_bot\": false,
        \"first_name\": \"Bob\"
      },
      \"chat_instance\": \"abc\",
      \"data\": \"yes\"
    }
  }"

const unknown_update_json = "{
    \"update_id\": 300,
    \"new_telegram_feature_2099\": { \"id\": 1 }
  }"

const empty_update_json = "{\"update_id\":301}"

const invalid_multiple_update_json = "{
    \"update_id\": 302,
    \"new_feature_a\": { \"id\": 1 },
    \"new_feature_b\": { \"id\": 2 }
  }"

fn parse(input: String) -> Update {
  let assert Ok(update) = json.parse(input, types.update_decoder())
  update
}

pub fn decodes_message_update_test() {
  let update = parse(message_update_json)
  assert update.update_id == 100
  let assert Some(raw) = update.raw
  let assert Ok(raw_json) = types.raw_object_to_json(raw)
  assert raw_json
    |> json.to_string
    |> string.contains("\"update_id\":100")
  case update.kind {
    MessageUpdate(m) -> {
      assert m.message_id == 1
      assert m.text == Some("/start hello")
      assert m.chat.id == 42
      let assert Some(user) = m.from
      assert user.first_name == "Ada"
      assert user.username == Some("adalovelace")
    }
    _ -> panic as "expected MessageUpdate"
  }
}

pub fn decodes_callback_query_update_test() {
  let update = parse(callback_query_update_json)
  assert update.update_id == 200
  case update.kind {
    CallbackQueryUpdate(cq) -> {
      assert cq.id == "cq-1"
      assert cq.payload == types.Data("yes")
      assert cq.from.first_name == "Bob"
      assert cq.message == None
    }
    _ -> panic as "expected CallbackQueryUpdate"
  }
}

pub fn decodes_date_time_message_entity_fields_test() {
  let body =
    "{\"type\":\"date_time\",\"offset\":0,\"length\":20,\"unix_time\":1700000000,\"date_time_format\":\"relative\"}"
  let assert Ok(entity) = json.parse(body, types.message_entity_decoder())
  assert entity.type_ == "date_time"
  assert entity.unix_time == Some(1_700_000_000)
  assert entity.date_time_format == Some("relative")
}

pub fn callback_payload_decodes_data_or_game_test() {
  let from = "{\"id\":7,\"is_bot\":false,\"first_name\":\"Bob\"}"
  let data_body =
    "{\"id\":\"data\",\"from\":"
    <> from
    <> ",\"chat_instance\":\"chat\",\"data\":\"next\"}"
  let game_body =
    "{\"id\":\"game\",\"from\":"
    <> from
    <> ",\"chat_instance\":\"chat\",\"game_short_name\":\"chess\"}"

  let assert Ok(data_query) =
    json.parse(data_body, types.callback_query_decoder())
  let assert Ok(game_query) =
    json.parse(game_body, types.callback_query_decoder())
  assert data_query.payload == types.Data("next")
  assert game_query.payload == types.Game("chess")
}

pub fn callback_payload_rejects_missing_or_ambiguous_values_test() {
  let prefix =
    "{\"id\":\"bad\",\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"Bob\"},\"chat_instance\":\"chat\""
  let missing = prefix <> "}"
  let both = prefix <> ",\"data\":\"next\",\"game_short_name\":\"chess\"}"

  let assert Error(_) = json.parse(missing, types.callback_query_decoder())
  let assert Error(_) = json.parse(both, types.callback_query_decoder())
}

pub fn decodes_inaccessible_callback_and_pinned_messages_test() {
  let callback_body =
    "{\"update_id\":201,\"callback_query\":{\"id\":\"cq\",\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"Bob\"},\"message\":{\"message_id\":8,\"chat\":{\"id\":99,\"type\":\"private\"},\"date\":0},\"chat_instance\":\"chat\",\"data\":\"next\"}}"
  let pinned_body =
    "{\"update_id\":202,\"message\":{\"message_id\":1,\"chat\":{\"id\":99,\"type\":\"private\"},\"date\":1,\"pinned_message\":{\"message_id\":2,\"chat\":{\"id\":99,\"type\":\"private\"},\"date\":0}}}"

  case parse(callback_body).kind {
    CallbackQueryUpdate(query) -> {
      let assert Some(types.InaccessibleMessage(chat:, message_id:)) =
        query.message
      assert chat.id == 99
      assert message_id == 8
    }
    _ -> panic as "expected CallbackQueryUpdate"
  }
  case parse(pinned_body).kind {
    MessageUpdate(message) -> {
      let assert Some(types.InaccessibleMessage(chat:, message_id:)) =
        message.pinned_message
      assert chat.id == 99
      assert message_id == 2
    }
    _ -> panic as "expected MessageUpdate"
  }
}

pub fn decodes_accessible_callback_message_test() {
  let body =
    "{\"update_id\":203,\"callback_query\":{\"id\":\"cq\",\"from\":{\"id\":7,\"is_bot\":false,\"first_name\":\"Bob\"},\"message\":{\"message_id\":8,\"chat\":{\"id\":99,\"type\":\"private\"},\"date\":1,\"text\":\"open\"},\"chat_instance\":\"chat\",\"data\":\"next\"}}"
  case parse(body).kind {
    CallbackQueryUpdate(query) -> {
      let assert Some(types.AccessibleMessage(message)) = query.message
      assert message.message_id == 8
      assert message.text == Some("open")
    }
    _ -> panic as "expected CallbackQueryUpdate"
  }
}

pub fn unknown_update_falls_back_to_other_test() {
  let update = parse(unknown_update_json)
  assert update.update_id == 300
  case update.kind {
    OtherUpdate(raw) -> {
      assert types.raw_update_name(raw) == Some("new_telegram_feature_2099")
      let id_decoder = {
        use id <- decode.field("id", decode.int)
        decode.success(id)
      }
      assert types.decode_raw_update(raw, id_decoder) == Ok(1)
    }
    _ -> panic as "expected OtherUpdate"
  }
}

pub fn empty_update_preserves_explicit_raw_fallback_test() {
  let update = parse(empty_update_json)
  case update.kind {
    OtherUpdate(raw) -> {
      assert types.raw_update_name(raw) == None
    }
    _ -> panic as "expected OtherUpdate"
  }
}

pub fn update_rejects_multiple_payload_fields_test() {
  let assert Error(_) =
    json.parse(invalid_multiple_update_json, types.update_decoder())
}

pub fn central_records_preserve_raw_and_decode_current_fields_test() {
  let body =
    "{
    \"update_id\":400,
    \"message\":{
      \"message_id\":1,
      \"from\":{
        \"id\":2,
        \"is_bot\":true,
        \"first_name\":\"Bot\",
        \"supports_guest_queries\":true,
        \"has_topics_enabled\":true,
        \"allows_users_to_create_topics\":true,
        \"can_manage_bots\":true,
        \"supports_join_request_queries\":true,
        \"future_user\":\"user-raw\"
      },
      \"chat\":{
        \"id\":1,
        \"type\":\"private\",
        \"is_direct_messages\":true,
        \"future_chat\":\"chat-raw\"
      },
      \"date\":0,
      \"poll\":{
        \"id\":\"poll-1\",
        \"question\":\"Question?\",
        \"options\":[{
          \"persistent_id\":\"a\",
          \"text\":\"A\",
          \"voter_count\":0,
          \"future_option\":\"option-raw\"
        }],
        \"total_voter_count\":0,
        \"is_closed\":false,
        \"is_anonymous\":true,
        \"type\":\"regular\",
        \"allows_multiple_answers\":false,
        \"allows_revoting\":true,
        \"members_only\":false,
        \"future_poll\":\"poll-raw\"
      },
      \"future_message\":\"message-raw\"
    }
  }"
  let assert Ok(update) = json.parse(body, types.update_decoder())
  case update.kind {
    MessageUpdate(message) -> {
      let assert Some(message_raw) = message.raw
      let message_decoder = {
        use value <- decode.field("future_message", decode.string)
        decode.success(value)
      }
      assert types.decode_raw_object(message_raw, message_decoder)
        == Ok("message-raw")

      let assert Some(user) = message.from
      assert user.supports_guest_queries == Some(True)
      assert user.has_topics_enabled == Some(True)
      assert user.allows_users_to_create_topics == Some(True)
      assert user.can_manage_bots == Some(True)
      assert user.supports_join_request_queries == Some(True)
      let assert Some(user_raw) = user.raw
      let user_decoder = {
        use value <- decode.field("future_user", decode.string)
        decode.success(value)
      }
      assert types.decode_raw_object(user_raw, user_decoder) == Ok("user-raw")

      assert message.chat.is_direct_messages == Some(True)
      let assert Some(chat_raw) = message.chat.raw
      let chat_decoder = {
        use value <- decode.field("future_chat", decode.string)
        decode.success(value)
      }
      assert types.decode_raw_object(chat_raw, chat_decoder) == Ok("chat-raw")

      let assert Some(poll) = message.poll
      assert poll.correct_option_ids == None
      let assert Some(poll_raw) = poll.raw
      let poll_decoder = {
        use value <- decode.field("future_poll", decode.string)
        decode.success(value)
      }
      assert types.decode_raw_object(poll_raw, poll_decoder) == Ok("poll-raw")
      let assert [poll_option] = poll.options
      let assert Some(option_raw) = poll_option.raw
      let option_decoder = {
        use value <- decode.field("future_option", decode.string)
        decode.success(value)
      }
      assert types.decode_raw_object(option_raw, option_decoder)
        == Ok("option-raw")
    }
    _ -> panic as "expected MessageUpdate"
  }
}

pub fn poll_answer_preserves_raw_object_test() {
  let body =
    "{
    \"update_id\":401,
    \"poll_answer\":{
      \"poll_id\":\"poll-1\",
      \"user\":{\"id\":3,\"is_bot\":false,\"first_name\":\"Ada\"},
      \"option_ids\":[0],
      \"option_persistent_ids\":[\"a\"],
      \"future_answer\":\"answer-raw\"
    }
  }"
  let assert Ok(update) = json.parse(body, types.update_decoder())
  case update.kind {
    types.PollAnswerUpdate(answer) -> {
      let assert Some(raw) = answer.raw
      let decoder = {
        use value <- decode.field("future_answer", decode.string)
        decode.success(value)
      }
      assert types.decode_raw_object(raw, decoder) == Ok("answer-raw")
    }
    _ -> panic as "expected PollAnswerUpdate"
  }
}
