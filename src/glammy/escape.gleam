//// Escaping helpers for the various Telegram parse modes. Lifted from
//// the Telegram Bot API documentation
//// (https://core.telegram.org/bots/api#formatting-options).

import gleam/list
import gleam/string

const markdown_v2_reserved = [
  "_", "*", "[", "]", "(", ")", "~", "`", ">", "#", "+", "-", "=", "|", "{", "}",
  ".", "!",
]

const markdown_legacy_reserved = ["_", "*", "`", "["]

/// Escape user-provided text for `parse_mode: "MarkdownV2"`.
pub fn markdown_v2(text: String) -> String {
  escape_each(text, markdown_v2_reserved)
}

/// Escape user-provided text for the legacy `parse_mode: "Markdown"` mode.
pub fn markdown(text: String) -> String {
  escape_each(text, markdown_legacy_reserved)
}

/// Escape user-provided text for `parse_mode: "HTML"`.
pub fn html(text: String) -> String {
  text
  |> string.replace(each: "&", with: "&amp;")
  |> string.replace(each: "<", with: "&lt;")
  |> string.replace(each: ">", with: "&gt;")
}

fn escape_each(input: String, chars: List(String)) -> String {
  let escapes = list.map(chars, fn(c) { #(c, "\\" <> c) })
  list.fold(escapes, input, fn(acc, pair) {
    string.replace(acc, each: pair.0, with: pair.1)
  })
}
