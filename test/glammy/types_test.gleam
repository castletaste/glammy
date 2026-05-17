import glammy/types.{
  type Update, CallbackQueryUpdate, MessageUpdate, OtherUpdate,
}
import gleam/json
import gleam/option.{None, Some}

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

fn parse(input: String) -> Update {
  let assert Ok(update) = json.parse(input, types.update_decoder())
  update
}

pub fn decodes_message_update_test() {
  let update = parse(message_update_json)
  assert update.update_id == 100
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
      assert cq.data == Some("yes")
      assert cq.from.first_name == "Bob"
      assert cq.message == None
    }
    _ -> panic as "expected CallbackQueryUpdate"
  }
}

pub fn unknown_update_falls_back_to_other_test() {
  let update = parse(unknown_update_json)
  assert update.update_id == 300
  case update.kind {
    OtherUpdate -> Nil
    _ -> panic as "expected OtherUpdate"
  }
}
