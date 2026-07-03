//// Keyboard builders. Trimmed port of grammY's
//// `convenience/keyboard.ts`. Two flavours are exposed:
////
//// - `InlineKeyboard` — attached to a message, with callback / URL /
////   web-app / login / switch-inline / game / pay buttons. Renders into
////   Telegram's `InlineKeyboardMarkup` JSON.
//// - `ReplyKeyboard` — the custom keyboard that replaces the user's
////   normal one. Supports text / contact / location / poll / web-app /
////   request_users / request_chat buttons. Renders into
////   `ReplyKeyboardMarkup` JSON.
////
//// Both are built up row-by-row using a pipe-friendly builder pattern,
//// and both support `transpose`, `flow`, and `append` post-processors.

import glammy/internal/json_utils.{put_optional}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

// =====================================================================
//                           InlineKeyboard
// =====================================================================

pub type InlineKeyboardButton {
  InlineUrl(text: String, url: String)
  InlineCallback(text: String, callback_data: String)
  InlineWebApp(text: String, url: String)
  InlineLoginUrl(text: String, login_url: LoginUrl)
  InlineSwitchInline(text: String, query: String)
  InlineSwitchInlineCurrent(text: String, query: String)
  InlineSwitchInlineChosen(text: String, options: SwitchInlineChosenChat)
  InlineGame(text: String)
  InlinePay(text: String)
}

pub type LoginUrl {
  LoginUrl(
    url: String,
    forward_text: Option(String),
    bot_username: Option(String),
    request_write_access: Option(Bool),
  )
}

/// Create `LoginUrl` options for an inline login button.
pub fn login_url(url: String) -> LoginUrl {
  LoginUrl(
    url:,
    forward_text: None,
    bot_username: None,
    request_write_access: None,
  )
}

pub type SwitchInlineChosenChat {
  SwitchInlineChosenChat(
    query: Option(String),
    allow_user_chats: Option(Bool),
    allow_bot_chats: Option(Bool),
    allow_group_chats: Option(Bool),
    allow_channel_chats: Option(Bool),
  )
}

/// Create default `switch_inline_query_chosen_chat` options.
pub fn switch_inline_chosen_chat() -> SwitchInlineChosenChat {
  SwitchInlineChosenChat(
    query: None,
    allow_user_chats: None,
    allow_bot_chats: None,
    allow_group_chats: None,
    allow_channel_chats: None,
  )
}

pub opaque type InlineKeyboard {
  /// Rows are stored in reverse order — newest first — so appending is
  /// cheap. We reverse on render.
  InlineKeyboard(reversed_rows: List(List(InlineKeyboardButton)))
}

/// Create an empty `InlineKeyboard`.
pub fn inline() -> InlineKeyboard {
  InlineKeyboard(reversed_rows: [[]])
}

/// Build an `InlineKeyboard` from a list of rows of buttons.
pub fn inline_from(rows: List(List(InlineKeyboardButton))) -> InlineKeyboard {
  InlineKeyboard(reversed_rows: list.reverse(rows))
}

/// Append an inline callback button.
pub fn inline_text(
  keyboard: InlineKeyboard,
  text: String,
  callback_data: String,
) -> InlineKeyboard {
  add_inline_button(keyboard, InlineCallback(text:, callback_data:))
}

/// Append an inline URL button.
pub fn inline_url(
  keyboard: InlineKeyboard,
  text: String,
  url: String,
) -> InlineKeyboard {
  add_inline_button(keyboard, InlineUrl(text:, url:))
}

/// Append an inline web-app button.
pub fn inline_web_app(
  keyboard: InlineKeyboard,
  text: String,
  url: String,
) -> InlineKeyboard {
  add_inline_button(keyboard, InlineWebApp(text:, url:))
}

/// Append an inline login button.
pub fn inline_login(
  keyboard: InlineKeyboard,
  text: String,
  url: LoginUrl,
) -> InlineKeyboard {
  add_inline_button(keyboard, InlineLoginUrl(text:, login_url: url))
}

/// Append a button that opens inline mode in another chat.
pub fn inline_switch_inline(
  keyboard: InlineKeyboard,
  text: String,
  query: String,
) -> InlineKeyboard {
  add_inline_button(keyboard, InlineSwitchInline(text:, query:))
}

/// Append a button that opens inline mode in the current chat.
pub fn inline_switch_inline_current(
  keyboard: InlineKeyboard,
  text: String,
  query: String,
) -> InlineKeyboard {
  add_inline_button(keyboard, InlineSwitchInlineCurrent(text:, query:))
}

/// Append a button with chosen-chat inline-mode options.
pub fn inline_switch_inline_chosen(
  keyboard: InlineKeyboard,
  text: String,
  options: SwitchInlineChosenChat,
) -> InlineKeyboard {
  add_inline_button(keyboard, InlineSwitchInlineChosen(text:, options:))
}

/// Append an inline game button.
pub fn inline_game(keyboard: InlineKeyboard, text: String) -> InlineKeyboard {
  add_inline_button(keyboard, InlineGame(text:))
}

/// Append an inline pay button.
pub fn inline_pay(keyboard: InlineKeyboard, text: String) -> InlineKeyboard {
  add_inline_button(keyboard, InlinePay(text:))
}

/// Start a new row. The next `inline_*` call adds a button to the new row.
pub fn inline_row(keyboard: InlineKeyboard) -> InlineKeyboard {
  InlineKeyboard(reversed_rows: [[], ..keyboard.reversed_rows])
}

fn add_inline_button(
  keyboard: InlineKeyboard,
  button: InlineKeyboardButton,
) -> InlineKeyboard {
  case keyboard.reversed_rows {
    [current, ..rest] ->
      InlineKeyboard(reversed_rows: [list.append(current, [button]), ..rest])
    [] -> InlineKeyboard(reversed_rows: [[button]])
  }
}

/// Return the rows of the keyboard in display order. Useful for tests.
pub fn inline_rows(
  keyboard: InlineKeyboard,
) -> List(List(InlineKeyboardButton)) {
  materialise_rows(keyboard.reversed_rows)
}

/// Transpose the keyboard — flip rows and columns. Idempotent under
/// double application iff the shape is rectangular.
pub fn inline_transpose(keyboard: InlineKeyboard) -> InlineKeyboard {
  inline_from(transpose(inline_rows(keyboard)))
}

/// Wrap all buttons into rows of at most `cols` columns. If
/// `fill_last_row` is `True` the first row absorbs the remainder; if
/// `False` the last row may be shorter. A non-positive `cols` leaves
/// all buttons in a single row.
pub fn inline_flow(
  keyboard: InlineKeyboard,
  cols: Int,
  fill_last_row fill_last_row: Bool,
) -> InlineKeyboard {
  let flat = list.flatten(inline_rows(keyboard))
  inline_from(chunk_for_flow(flat, cols, fill_last_row))
}

/// Append another keyboard's rows to this one.
pub fn inline_append(
  keyboard: InlineKeyboard,
  other: InlineKeyboard,
) -> InlineKeyboard {
  inline_from(list.append(inline_rows(keyboard), inline_rows(other)))
}

/// Render an `InlineKeyboard` as Telegram markup JSON.
pub fn inline_to_json(keyboard: InlineKeyboard) -> json.Json {
  json.object([
    #(
      "inline_keyboard",
      json.array(inline_rows(keyboard), fn(row) {
        json.array(row, inline_button_to_json)
      }),
    ),
  ])
}

fn inline_button_to_json(button: InlineKeyboardButton) -> json.Json {
  case button {
    InlineUrl(text:, url:) ->
      json.object([#("text", json.string(text)), #("url", json.string(url))])
    InlineCallback(text:, callback_data:) ->
      json.object([
        #("text", json.string(text)),
        #("callback_data", json.string(callback_data)),
      ])
    InlineWebApp(text:, url:) ->
      json.object([
        #("text", json.string(text)),
        #("web_app", json.object([#("url", json.string(url))])),
      ])
    InlineLoginUrl(text:, login_url:) ->
      json.object([
        #("text", json.string(text)),
        #("login_url", login_url_to_json(login_url)),
      ])
    InlineSwitchInline(text:, query:) ->
      json.object([
        #("text", json.string(text)),
        #("switch_inline_query", json.string(query)),
      ])
    InlineSwitchInlineCurrent(text:, query:) ->
      json.object([
        #("text", json.string(text)),
        #("switch_inline_query_current_chat", json.string(query)),
      ])
    InlineSwitchInlineChosen(text:, options:) ->
      json.object([
        #("text", json.string(text)),
        #(
          "switch_inline_query_chosen_chat",
          switch_inline_chosen_chat_to_json(options),
        ),
      ])
    InlineGame(text:) ->
      json.object([
        #("text", json.string(text)),
        #("callback_game", json.object([])),
      ])
    InlinePay(text:) ->
      json.object([#("text", json.string(text)), #("pay", json.bool(True))])
  }
}

fn login_url_to_json(url: LoginUrl) -> json.Json {
  json.object(
    [#("url", json.string(url.url))]
    |> put_optional("forward_text", url.forward_text, json.string)
    |> put_optional("bot_username", url.bot_username, json.string)
    |> put_optional("request_write_access", url.request_write_access, json.bool),
  )
}

fn switch_inline_chosen_chat_to_json(o: SwitchInlineChosenChat) -> json.Json {
  json.object(
    []
    |> put_optional("query", o.query, json.string)
    |> put_optional("allow_user_chats", o.allow_user_chats, json.bool)
    |> put_optional("allow_bot_chats", o.allow_bot_chats, json.bool)
    |> put_optional("allow_group_chats", o.allow_group_chats, json.bool)
    |> put_optional("allow_channel_chats", o.allow_channel_chats, json.bool),
  )
}

// =====================================================================
//                           ReplyKeyboard
// =====================================================================

pub type ReplyKeyboardButton {
  ReplyText(text: String)
  ReplyRequestContact(text: String)
  ReplyRequestLocation(text: String)
  ReplyRequestPoll(text: String, type_: Option(String))
  ReplyWebApp(text: String, url: String)
  ReplyRequestUsers(text: String, request_id: Int, user_is_bot: Option(Bool))
  ReplyRequestChat(text: String, request_id: Int, chat_is_channel: Bool)
  ReplyRequestManagedBot(text: String, request_id: Int)
}

pub opaque type ReplyKeyboard {
  ReplyKeyboard(
    reversed_rows: List(List(ReplyKeyboardButton)),
    resize: Option(Bool),
    one_time: Option(Bool),
    selective: Option(Bool),
    is_persistent: Option(Bool),
    input_field_placeholder: Option(String),
  )
}

/// Create an empty `ReplyKeyboard`.
pub fn reply() -> ReplyKeyboard {
  ReplyKeyboard(
    reversed_rows: [[]],
    resize: None,
    one_time: None,
    selective: None,
    is_persistent: None,
    input_field_placeholder: None,
  )
}

/// Build a `ReplyKeyboard` from a list of rows of buttons.
pub fn reply_from(rows: List(List(ReplyKeyboardButton))) -> ReplyKeyboard {
  ReplyKeyboard(
    reversed_rows: list.reverse(rows),
    resize: None,
    one_time: None,
    selective: None,
    is_persistent: None,
    input_field_placeholder: None,
  )
}

/// Append a plain reply-keyboard text button.
pub fn reply_text(keyboard: ReplyKeyboard, text: String) -> ReplyKeyboard {
  add_reply_button(keyboard, ReplyText(text:))
}

/// Append a reply button that requests the user's contact.
pub fn reply_request_contact(
  keyboard: ReplyKeyboard,
  text: String,
) -> ReplyKeyboard {
  add_reply_button(keyboard, ReplyRequestContact(text:))
}

/// Append a reply button that requests the user's location.
pub fn reply_request_location(
  keyboard: ReplyKeyboard,
  text: String,
) -> ReplyKeyboard {
  add_reply_button(keyboard, ReplyRequestLocation(text:))
}

/// Append a reply button that requests poll creation.
pub fn reply_request_poll(
  keyboard: ReplyKeyboard,
  text: String,
  type_ type_: Option(String),
) -> ReplyKeyboard {
  add_reply_button(keyboard, ReplyRequestPoll(text:, type_:))
}

/// Append a reply web-app button.
pub fn reply_web_app(
  keyboard: ReplyKeyboard,
  text: String,
  url: String,
) -> ReplyKeyboard {
  add_reply_button(keyboard, ReplyWebApp(text:, url:))
}

/// Append a reply button that requests users.
pub fn reply_request_users(
  keyboard: ReplyKeyboard,
  text: String,
  request_id request_id: Int,
  user_is_bot user_is_bot: Option(Bool),
) -> ReplyKeyboard {
  add_reply_button(
    keyboard,
    ReplyRequestUsers(text:, request_id:, user_is_bot:),
  )
}

/// Append a reply button that requests a chat.
pub fn reply_request_chat(
  keyboard: ReplyKeyboard,
  text: String,
  request_id request_id: Int,
  chat_is_channel chat_is_channel: Bool,
) -> ReplyKeyboard {
  add_reply_button(
    keyboard,
    ReplyRequestChat(text:, request_id:, chat_is_channel:),
  )
}

/// Append a reply button that requests a managed bot.
pub fn reply_request_managed_bot(
  keyboard: ReplyKeyboard,
  text: String,
  request_id request_id: Int,
) -> ReplyKeyboard {
  add_reply_button(keyboard, ReplyRequestManagedBot(text:, request_id:))
}

/// Start a new reply-keyboard row.
pub fn reply_row(keyboard: ReplyKeyboard) -> ReplyKeyboard {
  ReplyKeyboard(..keyboard, reversed_rows: [[], ..keyboard.reversed_rows])
}

/// Set Telegram's `resize_keyboard` option.
pub fn reply_resize(keyboard: ReplyKeyboard, value: Bool) -> ReplyKeyboard {
  ReplyKeyboard(..keyboard, resize: Some(value))
}

/// Set Telegram's `one_time_keyboard` option.
pub fn reply_one_time(keyboard: ReplyKeyboard, value: Bool) -> ReplyKeyboard {
  ReplyKeyboard(..keyboard, one_time: Some(value))
}

/// Set Telegram's `selective` option.
pub fn reply_selective(keyboard: ReplyKeyboard, value: Bool) -> ReplyKeyboard {
  ReplyKeyboard(..keyboard, selective: Some(value))
}

/// Set Telegram's `is_persistent` option.
pub fn reply_persistent(keyboard: ReplyKeyboard, value: Bool) -> ReplyKeyboard {
  ReplyKeyboard(..keyboard, is_persistent: Some(value))
}

/// Set the input-field placeholder shown with the reply keyboard.
pub fn reply_placeholder(
  keyboard: ReplyKeyboard,
  text: String,
) -> ReplyKeyboard {
  ReplyKeyboard(..keyboard, input_field_placeholder: Some(text))
}

fn add_reply_button(
  keyboard: ReplyKeyboard,
  button: ReplyKeyboardButton,
) -> ReplyKeyboard {
  case keyboard.reversed_rows {
    [current, ..rest] ->
      ReplyKeyboard(..keyboard, reversed_rows: [
        list.append(current, [button]),
        ..rest
      ])
    [] -> ReplyKeyboard(..keyboard, reversed_rows: [[button]])
  }
}

/// Return the reply keyboard rows in display order. Useful for tests.
pub fn reply_rows(keyboard: ReplyKeyboard) -> List(List(ReplyKeyboardButton)) {
  materialise_rows(keyboard.reversed_rows)
}

/// Transpose the reply keyboard rows.
pub fn reply_transpose(keyboard: ReplyKeyboard) -> ReplyKeyboard {
  let rows = transpose(reply_rows(keyboard))
  ReplyKeyboard(..keyboard, reversed_rows: list.reverse(rows))
}

/// Wrap reply-keyboard buttons into rows of at most `cols` columns.
/// A non-positive `cols` leaves all buttons in a single row.
pub fn reply_flow(
  keyboard: ReplyKeyboard,
  cols: Int,
  fill_last_row fill_last_row: Bool,
) -> ReplyKeyboard {
  let flat = list.flatten(reply_rows(keyboard))
  let rows = chunk_for_flow(flat, cols, fill_last_row)
  ReplyKeyboard(..keyboard, reversed_rows: list.reverse(rows))
}

/// Append another reply keyboard's rows to this one.
pub fn reply_append(
  keyboard: ReplyKeyboard,
  other: ReplyKeyboard,
) -> ReplyKeyboard {
  let rows = list.append(reply_rows(keyboard), reply_rows(other))
  ReplyKeyboard(..keyboard, reversed_rows: list.reverse(rows))
}

/// Render a `ReplyKeyboard` as Telegram markup JSON.
pub fn reply_to_json(keyboard: ReplyKeyboard) -> json.Json {
  let base = [
    #(
      "keyboard",
      json.array(reply_rows(keyboard), fn(row) {
        json.array(row, reply_button_to_json)
      }),
    ),
  ]
  let with_extras =
    base
    |> put_optional("resize_keyboard", keyboard.resize, json.bool)
    |> put_optional("one_time_keyboard", keyboard.one_time, json.bool)
    |> put_optional("selective", keyboard.selective, json.bool)
    |> put_optional("is_persistent", keyboard.is_persistent, json.bool)
    |> put_optional(
      "input_field_placeholder",
      keyboard.input_field_placeholder,
      json.string,
    )
  json.object(with_extras)
}

fn reply_button_to_json(button: ReplyKeyboardButton) -> json.Json {
  case button {
    ReplyText(text:) -> json.object([#("text", json.string(text))])
    ReplyRequestContact(text:) ->
      json.object([
        #("text", json.string(text)),
        #("request_contact", json.bool(True)),
      ])
    ReplyRequestLocation(text:) ->
      json.object([
        #("text", json.string(text)),
        #("request_location", json.bool(True)),
      ])
    ReplyRequestPoll(text:, type_:) ->
      json.object([
        #("text", json.string(text)),
        #(
          "request_poll",
          json.object(case type_ {
            Some(t) -> [#("type", json.string(t))]
            None -> []
          }),
        ),
      ])
    ReplyWebApp(text:, url:) ->
      json.object([
        #("text", json.string(text)),
        #("web_app", json.object([#("url", json.string(url))])),
      ])
    ReplyRequestUsers(text:, request_id:, user_is_bot:) ->
      json.object([
        #("text", json.string(text)),
        #(
          "request_users",
          json.object(
            [#("request_id", json.int(request_id))]
            |> put_optional("user_is_bot", user_is_bot, json.bool),
          ),
        ),
      ])
    ReplyRequestChat(text:, request_id:, chat_is_channel:) ->
      json.object([
        #("text", json.string(text)),
        #(
          "request_chat",
          json.object([
            #("request_id", json.int(request_id)),
            #("chat_is_channel", json.bool(chat_is_channel)),
          ]),
        ),
      ])
    ReplyRequestManagedBot(text:, request_id:) ->
      json.object([
        #("text", json.string(text)),
        #(
          "request_managed_bot",
          json.object([#("request_id", json.int(request_id))]),
        ),
      ])
  }
}

// =====================================================================
//                        Markup helpers
// =====================================================================

/// Build Telegram `ReplyKeyboardRemove` JSON.
pub fn remove_keyboard() -> json.Json {
  json.object([#("remove_keyboard", json.bool(True))])
}

/// Build Telegram `ForceReply` JSON.
pub fn force_reply() -> json.Json {
  json.object([#("force_reply", json.bool(True))])
}

// =====================================================================
//                          internal helpers
// =====================================================================

fn materialise_rows(reversed_rows: List(List(a))) -> List(List(a)) {
  reversed_rows
  |> list.reverse
  |> list.filter(fn(row) { row != [] })
}

fn transpose(matrix: List(List(a))) -> List(List(a)) {
  case matrix {
    [] -> []
    [[], ..] -> []
    _ -> {
      let heads =
        list.filter_map(matrix, fn(row) {
          case row {
            [h, ..] -> Ok(h)
            [] -> Error(Nil)
          }
        })
      let tails =
        list.filter_map(matrix, fn(row) {
          case row {
            [_, ..rest] ->
              case rest {
                [] -> Error(Nil)
                _ -> Ok(rest)
              }
            [] -> Error(Nil)
          }
        })
      case heads {
        [] -> []
        _ -> [heads, ..transpose(tails)]
      }
    }
  }
}

fn chunk_for_flow(
  items: List(a),
  cols: Int,
  fill_last_row: Bool,
) -> List(List(a)) {
  case cols < 1 {
    True -> [items]
    False ->
      case fill_last_row {
        // "Bottom" flow: first row may be short, remaining rows have
        // `cols` columns.
        True -> chunk_bottom(items, cols)
        False -> chunk_top(items, cols)
      }
  }
}

fn chunk_top(items: List(a), cols: Int) -> List(List(a)) {
  case items {
    [] -> []
    _ -> {
      let #(head, rest) = take_n(items, cols)
      [head, ..chunk_top(rest, cols)]
    }
  }
}

fn chunk_bottom(items: List(a), cols: Int) -> List(List(a)) {
  let n = list.length(items)
  let remainder = case n % cols {
    0 -> cols
    r -> r
  }
  case n {
    0 -> []
    _ -> {
      let #(head, rest) = take_n(items, remainder)
      [head, ..chunk_top(rest, cols)]
    }
  }
}

fn take_n(items: List(a), n: Int) -> #(List(a), List(a)) {
  case n <= 0, items {
    True, _ -> #([], items)
    _, [] -> #([], [])
    _, [head, ..rest] -> {
      let #(taken, remainder) = take_n(rest, n - 1)
      #([head, ..taken], remainder)
    }
  }
}
