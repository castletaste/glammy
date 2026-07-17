//// Telegram's closed set of supported text parse modes.

/// Telegram's supported outbound text formatting modes.
pub type ParseMode {
  /// Legacy Markdown formatting.
  Markdown
  /// Telegram's escaped MarkdownV2 formatting.
  MarkdownV2
  /// Telegram's HTML subset.
  Html
}

/// Encode a parse mode for the Bot API.
pub fn to_string(mode: ParseMode) -> String {
  case mode {
    Markdown -> "Markdown"
    MarkdownV2 -> "MarkdownV2"
    Html -> "HTML"
  }
}
