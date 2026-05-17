import glammy/api
import glammy/context
import glammy/filter
import glammy/types.{type Update}
import gleam/json

fn make(body: String) -> Update {
  let assert Ok(u) = json.parse(body, types.update_decoder())
  u
}

fn ctx(u: Update) -> context.Context {
  context.new(u, api.new("0:test"))
}

const message_body = "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"hi\"}}"

const callback_body = "{\"update_id\":2,\"callback_query\":{\"id\":\"x\",\"from\":{\"id\":1,\"is_bot\":false,\"first_name\":\"Y\"},\"chat_instance\":\"i\",\"data\":\"d\"}}"

const inline_body = "{\"update_id\":3,\"inline_query\":{\"id\":\"q\",\"from\":{\"id\":1,\"is_bot\":false,\"first_name\":\"Z\"},\"query\":\"hi\",\"offset\":\"\"}}"

pub fn message_filter_matches_message_test() {
  assert filter.matches(filter.Message, ctx(make(message_body))) == True
  assert filter.matches(filter.Message, ctx(make(callback_body))) == False
}

pub fn any_message_filter_test() {
  assert filter.matches(filter.AnyMessage, ctx(make(message_body))) == True
  assert filter.matches(filter.AnyMessage, ctx(make(callback_body))) == False
}

pub fn callback_query_filter_test() {
  assert filter.matches(filter.CallbackQuery, ctx(make(callback_body))) == True
  assert filter.matches(filter.CallbackQuery, ctx(make(message_body))) == False
}

pub fn inline_query_filter_test() {
  assert filter.matches(filter.InlineQuery, ctx(make(inline_body))) == True
}

pub fn any_update_filter_test() {
  assert filter.matches(filter.AnyUpdate, ctx(make(callback_body))) == True
  assert filter.matches(filter.AnyUpdate, ctx(make(inline_body))) == True
}
