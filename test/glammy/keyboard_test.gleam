//// Tests mirroring grammY's `test/convenience/keyboard.test.ts`. The
//// grammY tests use mutable builder objects; we test equivalent
//// behaviour via the JSON-output round-trip.

import glammy/https_url
import glammy/keyboard
import glammy/types
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string

fn render_inline(k: keyboard.InlineKeyboard) -> String {
  json.to_string(keyboard.inline_to_json(k))
}

fn render_reply(k: keyboard.ReplyKeyboard) -> String {
  json.to_string(keyboard.reply_to_json(k))
}

// =====================================================================
//                     ReplyKeyboard (Keyboard)
// =====================================================================

pub fn keyboard_takes_initial_buttons_test() {
  let k = keyboard.reply_from([[keyboard.ReplyText(text: "button")]])
  assert render_reply(k) == "{\"keyboard\":[[{\"text\":\"button\"}]]}"
}

pub fn keyboard_creates_rows_and_columns_test() {
  let k =
    keyboard.reply()
    |> keyboard.reply_text("0")
    |> keyboard.reply_text("1")
    |> keyboard.reply_text("2")
    |> keyboard.reply_row
    |> keyboard.reply_text("3")
    |> keyboard.reply_text("4")
    |> keyboard.reply_text("5")
  assert render_reply(k)
    == "{\"keyboard\":[[{\"text\":\"0\"},{\"text\":\"1\"},{\"text\":\"2\"}],[{\"text\":\"3\"},{\"text\":\"4\"},{\"text\":\"5\"}]]}"
}

pub fn keyboard_supports_different_buttons_test() {
  let assert Ok(web_app_url) = https_url.new("https://grammy.dev")
  let k =
    keyboard.reply()
    |> keyboard.reply_text("button")
    |> keyboard.reply_request_contact("contact")
    |> keyboard.reply_request_location("location")
    |> keyboard.reply_request_poll("poll", type_: Some(types.QuizInputPoll))
    |> keyboard.reply_web_app("web app", web_app_url)
    |> keyboard.reply_request_users(
      "user",
      request_id: 12,
      user_is_bot: Some(True),
    )
    |> keyboard.reply_request_chat(
      "chat",
      request_id: 42,
      chat_is_channel: False,
    )
    |> keyboard.reply_request_managed_bot("bot", request_id: 96)
  let expected =
    "{\"keyboard\":[["
    <> "{\"text\":\"button\"},"
    <> "{\"text\":\"contact\",\"request_contact\":true},"
    <> "{\"text\":\"location\",\"request_location\":true},"
    <> "{\"text\":\"poll\",\"request_poll\":{\"type\":\"quiz\"}},"
    <> "{\"text\":\"web app\",\"web_app\":{\"url\":\"https://grammy.dev\"}},"
    <> "{\"text\":\"user\",\"request_users\":{\"request_id\":12,\"user_is_bot\":true}},"
    <> "{\"text\":\"chat\",\"request_chat\":{\"request_id\":42,\"chat_is_channel\":false}},"
    <> "{\"text\":\"bot\",\"request_managed_bot\":{\"request_id\":96}}"
    <> "]]}"
  assert render_reply(k) == expected
}

pub fn keyboard_supports_reply_markup_options_test() {
  let k =
    keyboard.reply()
    |> keyboard.reply_text("ok")
    |> keyboard.reply_persistent(True)
    |> keyboard.reply_selective(False)
    |> keyboard.reply_one_time(True)
    |> keyboard.reply_resize(False)
    |> keyboard.reply_placeholder("placeholder")
  let rendered = render_reply(k)
  // We don't assert exact ordering — just verify each option appears.
  let assert True = string_contains(rendered, "\"is_persistent\":true")
  let assert True = string_contains(rendered, "\"selective\":false")
  let assert True = string_contains(rendered, "\"one_time_keyboard\":true")
  let assert True = string_contains(rendered, "\"resize_keyboard\":false")
  let assert True =
    string_contains(rendered, "\"input_field_placeholder\":\"placeholder\"")
  let assert False = string_contains(rendered, "\"pay\":true")
}

pub fn keyboard_can_be_transposed_test() {
  let mk = fn(rows: List(List(String))) {
    keyboard.reply_from(
      list.map(rows, fn(r) {
        list.map(r, fn(s) { keyboard.ReplyText(text: s) })
      }),
    )
  }
  assert keyboard.reply_rows(keyboard.reply_transpose(mk([["a"]])))
    == [[keyboard.ReplyText(text: "a")]]
  assert keyboard.reply_rows(keyboard.reply_transpose(mk([["a", "b", "c"]])))
    == [
      [keyboard.ReplyText(text: "a")],
      [keyboard.ReplyText(text: "b")],
      [keyboard.ReplyText(text: "c")],
    ]
  assert keyboard.reply_rows(
      keyboard.reply_transpose(mk([["a", "b"], ["c", "d"], ["e"]])),
    )
    == [
      [
        keyboard.ReplyText(text: "a"),
        keyboard.ReplyText(text: "c"),
        keyboard.ReplyText(text: "e"),
      ],
      [keyboard.ReplyText(text: "b"), keyboard.ReplyText(text: "d")],
    ]
}

pub fn keyboard_can_be_wrapped_top_test() {
  let mk = fn(rows: List(List(String))) {
    keyboard.reply_from(
      list.map(rows, fn(r) {
        list.map(r, fn(s) { keyboard.ReplyText(text: s) })
      }),
    )
  }
  assert keyboard.reply_rows(keyboard.reply_flow(
      mk([["a"]]),
      4,
      fill_last_row: False,
    ))
    == [[keyboard.ReplyText(text: "a")]]
  assert keyboard.reply_rows(keyboard.reply_flow(
      mk([["a", "b", "c"]]),
      1,
      fill_last_row: False,
    ))
    == [
      [keyboard.ReplyText(text: "a")],
      [keyboard.ReplyText(text: "b")],
      [keyboard.ReplyText(text: "c")],
    ]
  assert keyboard.reply_rows(keyboard.reply_flow(
      mk([["a", "b"], ["c", "d"], ["e"]]),
      3,
      fill_last_row: False,
    ))
    == [
      [
        keyboard.ReplyText(text: "a"),
        keyboard.ReplyText(text: "b"),
        keyboard.ReplyText(text: "c"),
      ],
      [keyboard.ReplyText(text: "d"), keyboard.ReplyText(text: "e")],
    ]
}

pub fn keyboard_can_be_wrapped_bottom_test() {
  // bottom: 10 items into rows of 3, with the first row absorbing the
  // remainder (10 mod 3 = 1).
  let items = [
    keyboard.ReplyText(text: "a"),
    keyboard.ReplyText(text: "b"),
    keyboard.ReplyText(text: "c"),
    keyboard.ReplyText(text: "d"),
    keyboard.ReplyText(text: "e"),
    keyboard.ReplyText(text: "f"),
    keyboard.ReplyText(text: "g"),
    keyboard.ReplyText(text: "h"),
    keyboard.ReplyText(text: "i"),
    keyboard.ReplyText(text: "j"),
  ]
  let k = keyboard.reply_from([items])
  let flowed = keyboard.reply_flow(k, 3, fill_last_row: True)
  assert keyboard.reply_rows(flowed)
    == [
      [keyboard.ReplyText(text: "a")],
      [
        keyboard.ReplyText(text: "b"),
        keyboard.ReplyText(text: "c"),
        keyboard.ReplyText(text: "d"),
      ],
      [
        keyboard.ReplyText(text: "e"),
        keyboard.ReplyText(text: "f"),
        keyboard.ReplyText(text: "g"),
      ],
      [
        keyboard.ReplyText(text: "h"),
        keyboard.ReplyText(text: "i"),
        keyboard.ReplyText(text: "j"),
      ],
    ]
}

pub fn keyboard_can_be_appended_test() {
  let a =
    keyboard.reply()
    |> keyboard.reply_text("a")
    |> keyboard.reply_text("b")
    |> keyboard.reply_row
    |> keyboard.reply_text("c")
  let combined = keyboard.reply_append(a, a)
  assert list.length(keyboard.reply_rows(combined)) == 4
}

// =====================================================================
//                      InlineKeyboard
// =====================================================================

pub fn inline_takes_initial_buttons_test() {
  let btn = keyboard.InlineCallback(text: "text", callback_data: "data")
  let k = keyboard.inline_from([[btn], [btn, btn]])
  assert keyboard.inline_rows(k) == [[btn], [btn, btn]]
}

pub fn inline_creates_rows_and_columns_test() {
  let k =
    keyboard.inline()
    |> keyboard.inline_text("a", "a")
    |> keyboard.inline_text("b", "b")
    |> keyboard.inline_text("c", "c")
    |> keyboard.inline_row
    |> keyboard.inline_text("d", "d")
    |> keyboard.inline_text("e", "e")
    |> keyboard.inline_text("f", "f")
  assert list.length(keyboard.inline_rows(k)) == 2
}

pub fn inline_supports_different_buttons_test() {
  let assert Ok(web_app_url) = https_url.new("https://grammy.dev")
  let login =
    keyboard.LoginUrl(
      url: web_app_url,
      forward_text: Some("forward"),
      bot_username: Some("bot"),
      request_write_access: Some(True),
    )
  let chosen = keyboard.switch_inline_chosen_chat()
  let chosen_with_bots =
    keyboard.SwitchInlineChosenChat(
      ..keyboard.switch_inline_chosen_chat(),
      allow_bot_chats: Some(True),
    )
  let k =
    keyboard.inline()
    |> keyboard.inline_url("url", "https://grammy.dev")
    |> keyboard.inline_text("button", "button")
    |> keyboard.inline_text("button", "data")
    |> keyboard.inline_web_app("web app", web_app_url)
    |> keyboard.inline_login("login", keyboard.login_url(web_app_url))
    |> keyboard.inline_login("login", login)
    |> keyboard.inline_switch_inline("inline", "")
    |> keyboard.inline_switch_inline("inline", "query")
    |> keyboard.inline_switch_inline_current("inline current", "")
    |> keyboard.inline_switch_inline_current("inline current", "query")
    |> keyboard.inline_switch_inline_chosen("inline chosen chat", chosen)
    |> keyboard.inline_switch_inline_chosen(
      "inline chosen chat",
      chosen_with_bots,
    )

  let rendered = render_inline(k)
  let assert True = string_contains(rendered, "\"url\":\"https://grammy.dev\"")
  let assert True = string_contains(rendered, "\"web_app\":")
  let assert True = string_contains(rendered, "\"login_url\":")
  let assert True =
    string_contains(rendered, "\"switch_inline_query\":\"query\"")
  let assert True =
    string_contains(rendered, "\"switch_inline_query_current_chat\":\"query\"")
  let assert True =
    string_contains(rendered, "\"switch_inline_query_chosen_chat\":")
  let assert False = string_contains(rendered, "\"callback_game\":{}")
  let assert False = string_contains(rendered, "\"pay\":true")
}

pub fn game_inline_keyboard_keeps_special_button_first_test() {
  let trailing =
    keyboard.inline()
    |> keyboard.inline_text("callback", "data")
    |> keyboard.inline_row
    |> keyboard.inline_url("docs", "https://core.telegram.org/bots/api")
  let rendered =
    keyboard.game_inline_keyboard_with("play", trailing)
    |> keyboard.game_inline_keyboard_to_json
    |> json.to_string
  assert rendered
    == "{\"inline_keyboard\":[[{\"text\":\"play\",\"callback_game\":{}}],[{\"text\":\"callback\",\"callback_data\":\"data\"}],[{\"text\":\"docs\",\"url\":\"https://core.telegram.org/bots/api\"}]]}"
}

pub fn invoice_inline_keyboard_keeps_special_button_first_test() {
  let trailing =
    keyboard.inline()
    |> keyboard.inline_text("receipt", "receipt")
  let rendered =
    keyboard.invoice_inline_keyboard_with("pay", trailing)
    |> keyboard.invoice_inline_keyboard_to_json
    |> json.to_string
  assert rendered
    == "{\"inline_keyboard\":[[{\"text\":\"pay\",\"pay\":true}],[{\"text\":\"receipt\",\"callback_data\":\"receipt\"}]]}"
}

pub fn endpoint_inline_keyboards_can_contain_only_special_button_test() {
  assert keyboard.game_inline_keyboard("play")
    |> keyboard.game_inline_keyboard_to_json
    |> json.to_string
    == "{\"inline_keyboard\":[[{\"text\":\"play\",\"callback_game\":{}}]]}"
  assert keyboard.invoice_inline_keyboard("pay")
    |> keyboard.invoice_inline_keyboard_to_json
    |> json.to_string
    == "{\"inline_keyboard\":[[{\"text\":\"pay\",\"pay\":true}]]}"
}

pub fn inline_can_be_transposed_test() {
  let mk = fn(rows: List(List(String))) {
    keyboard.inline_from(
      list.map(rows, fn(r) {
        list.map(r, fn(s) { keyboard.InlineCallback(text: s, callback_data: s) })
      }),
    )
  }
  let single = mk([["a", "b", "c"]])
  let transposed = keyboard.inline_transpose(single)
  assert list.length(keyboard.inline_rows(transposed)) == 3
  assert list.length(
      keyboard.inline_rows(keyboard.inline_transpose(transposed)),
    )
    == 1
}

pub fn inline_can_be_wrapped_test() {
  let buttons = [
    keyboard.InlineCallback(text: "a", callback_data: "a"),
    keyboard.InlineCallback(text: "b", callback_data: "b"),
    keyboard.InlineCallback(text: "c", callback_data: "c"),
    keyboard.InlineCallback(text: "d", callback_data: "d"),
    keyboard.InlineCallback(text: "e", callback_data: "e"),
    keyboard.InlineCallback(text: "f", callback_data: "f"),
  ]
  let k = keyboard.inline_from([buttons])
  let flowed = keyboard.inline_flow(k, 3, fill_last_row: False)
  assert list.length(keyboard.inline_rows(flowed)) == 2
}

pub fn inline_can_be_appended_test() {
  let a =
    keyboard.inline()
    |> keyboard.inline_text("a", "a")
    |> keyboard.inline_text("b", "b")
  let combined = keyboard.inline_append(a, a)
  let rows = keyboard.inline_rows(combined)
  assert list.length(rows) == 2
}

// =====================================================================
//                         Markup helpers
// =====================================================================

pub fn remove_keyboard_test() {
  assert json.to_string(
      keyboard.remove_keyboard() |> keyboard.reply_markup_to_json,
    )
    == "{\"remove_keyboard\":true}"
}

pub fn force_reply_test() {
  assert json.to_string(keyboard.force_reply() |> keyboard.reply_markup_to_json)
    == "{\"force_reply\":true}"
}

// =====================================================================
//                          helpers
// =====================================================================

fn string_contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}
