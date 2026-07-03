//// Tests for the glammy filter-query DSL. Mirror the grammY suite
//// (`test/filter.test.ts`) one-for-one where the behaviour applies.

import glammy/filter
import glammy/helpers.{ctx_from}

const message_text_body = "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"hi\"}}"

const message_photo_body = "{\"update_id\":2,\"message\":{\"message_id\":2,\"chat\":{\"id\":2,\"type\":\"private\"},\"date\":0,\"photo\":[{\"file_id\":\"x\",\"file_unique_id\":\"u\",\"width\":1,\"height\":1}]}}"

const callback_body = "{\"update_id\":3,\"callback_query\":{\"id\":\"x\",\"from\":{\"id\":1,\"is_bot\":false,\"first_name\":\"Y\"},\"chat_instance\":\"i\",\"data\":\"d\"}}"

const edited_message_body = "{\"update_id\":4,\"edited_message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"hi\"}}"

const message_with_url_body = "{\"update_id\":5,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"u\",\"entities\":[{\"type\":\"url\",\"offset\":0,\"length\":1}]}}"

const edited_message_photo_caption_body = "{\"update_id\":6,\"edited_message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"photo\":[{\"file_id\":\"x\",\"file_unique_id\":\"u\",\"width\":1,\"height\":1}],\"caption\":\"c\"}}"

const message_left_chat_bot_body = "{\"update_id\":7,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"left_chat_member\":{\"id\":42,\"is_bot\":true,\"first_name\":\"bot\"}}}"

const message_italic_url_body = "{\"update_id\":8,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"x\",\"entities\":[{\"type\":\"italic\",\"offset\":0,\"length\":1},{\"type\":\"url\",\"offset\":0,\"length\":1}]}}"

fn matches_str(query: String, body: String) -> Bool {
  let assert Ok(q) = filter.parse(query)
  filter.matches_query(q, ctx_from(body))
}

fn matches_many(queries: List(String), body: String) -> Bool {
  let assert Ok(q) = filter.parse_many(queries)
  filter.matches_query(q, ctx_from(body))
}

// =====================================================================
//                       grammY filter.test.ts ports
// =====================================================================

pub fn rejects_empty_filter_test() {
  assert_error(filter.parse(""), "empty filter")
  assert_error(filter.parse(":"), "':'")
  assert_error(filter.parse("::"), "'::'")
  assert_error(filter.parse("  "), "whitespace-only filter")
}

pub fn rejects_invalid_default_omissions_test() {
  assert_error(filter.parse("message:"), "'message:'")
  assert_error(filter.parse("::me"), "'::me'")
}

fn assert_error(result: Result(a, b), what: String) -> Nil {
  case result {
    Error(_) -> Nil
    Ok(_) -> panic as { "expected Error for " <> what }
  }
}

pub fn performs_l1_filtering_test() {
  assert matches_str("message", message_text_body) == True
  assert matches_str("edited_message", message_text_body) == False
}

pub fn performs_l2_filtering_test() {
  assert matches_str("message:text", message_text_body) == True
  assert matches_str("edited_message", message_text_body) == False
  assert matches_str("edited_message:text", message_text_body) == False
}

pub fn fills_in_l1_defaults_test() {
  assert matches_str(":text", message_text_body) == True
  assert matches_str(":entities", message_text_body) == False
  assert matches_str(":caption", message_text_body) == False
  assert matches_str("edited_message", message_text_body) == False
}

pub fn fills_in_l2_defaults_test() {
  assert matches_str("message::url", message_with_url_body) == True
  assert matches_str("::url", message_with_url_body) == True
  assert matches_str("edited_message", message_with_url_body) == False
}

pub fn expands_l1_shortcuts_test() {
  // ctxNew = update.message.text = ""
  assert matches_str("msg", message_text_body) == True
  assert matches_str("msg:text", message_text_body) == True
  assert matches_str("msg:entities", message_text_body) == False
  assert matches_str("message", message_text_body) == True
  assert matches_str(":text", message_text_body) == True
  assert matches_str(":audio", message_text_body) == False

  // ctxEdited = update.edited_message.text = ""
  assert matches_str(":text", edited_message_body) == False
  assert matches_str("edit", edited_message_body) == True
  assert matches_str("edit:text", edited_message_body) == True
  assert matches_str("edit:entities", edited_message_body) == False
  assert matches_str("edited_message", edited_message_body) == True
}

pub fn expands_l2_shortcuts_test() {
  // ctx = update.edited_message.photo + caption
  assert matches_str("edit", edited_message_photo_caption_body) == True
  assert matches_str("edit:photo", edited_message_photo_caption_body) == True
  assert matches_str(":photo", edited_message_photo_caption_body) == False
  assert matches_str("edited_message:media", edited_message_photo_caption_body)
    == True
  assert matches_str("edit:caption", edited_message_photo_caption_body) == True
  assert matches_str("edited_message:file", edited_message_photo_caption_body)
    == True
  assert matches_str("edit:file", edited_message_photo_caption_body) == True
  assert matches_str(":media", edited_message_photo_caption_body) == False
  assert matches_str(":file", edited_message_photo_caption_body) == False
}

pub fn performs_l3_filtering_test() {
  // entities:url
  assert matches_str("message:entities:url", message_with_url_body) == True

  // left_chat_member with is_bot=true
  assert matches_str(":left_chat_member:is_bot", message_left_chat_bot_body)
    == True
}

pub fn matches_multiple_filters_test() {
  // Message has italic + url entities; "::url" or "::italic" both match.
  assert matches_many(
      ["::url", "::bold", "::bot_command", "::cashtag", "::code"],
      message_italic_url_body,
    )
    == True
  // Even without url, italic alone makes "::italic" match
  let italic_only_body =
    "{\"update_id\":1,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"x\",\"entities\":[{\"type\":\"italic\",\"offset\":0,\"length\":1}]}}"
  assert matches_many(["::url", "::bold", "::italic"], italic_only_body) == True
  // None match
  assert matches_many(["::url", "::bold"], message_text_body) == False
}

// =====================================================================
//                          extra behaviour
// =====================================================================

pub fn parses_simple_query_test() {
  assert matches_str("message", message_text_body) == True
  assert matches_str("message", callback_body) == False
}

pub fn parses_callback_query_data_test() {
  assert matches_str("callback_query:data", callback_body) == True
  assert matches_str("callback_query:data", message_text_body) == False
}

pub fn parses_message_photo_query_test() {
  assert matches_str("message:photo", message_photo_body) == True
  assert matches_str("message:photo", message_text_body) == False
}
