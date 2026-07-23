//// Raw Telegram Bot API constants that do not have a typed outbound
//// representation elsewhere in glammy.

// =====================================================================
//                          Sticker types
// =====================================================================

/// Bot API discriminator for a regular sticker set.
pub const sticker_type_regular: String = "regular"

/// Bot API discriminator for a mask sticker set.
pub const sticker_type_mask: String = "mask"

/// Bot API discriminator for a custom-emoji sticker set.
pub const sticker_type_custom_emoji: String = "custom_emoji"

// =====================================================================
//                              Currencies
// =====================================================================

/// Telegram Stars currency code (no fraction).
pub const currency_stars: String = "XTR"
