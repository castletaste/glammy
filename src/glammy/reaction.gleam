//// Reaction values accepted by Telegram's outbound `setMessageReaction`.
////
//// Paid reactions and unknown inbound variants are intentionally absent: the
//// method does not permit bots to set them.

import gleam/json

/// A reaction bots are allowed to set.
pub type Reaction {
  /// A standard Unicode emoji reaction.
  Emoji(String)
  /// A custom emoji reaction by Telegram identifier.
  CustomEmoji(custom_emoji_id: String)
}

/// A legal bot reaction update: clear all reactions or set exactly one.
pub type ReactionChange {
  /// Clear the bot's current reaction.
  ClearReaction
  /// Set exactly one non-paid reaction.
  SetReaction(Reaction)
}

/// Encode an outbound reaction for the Bot API.
pub fn to_json(reaction: Reaction) -> json.Json {
  case reaction {
    Emoji(emoji) ->
      json.object([
        #("type", json.string("emoji")),
        #("emoji", json.string(emoji)),
      ])
    CustomEmoji(custom_emoji_id:) ->
      json.object([
        #("type", json.string("custom_emoji")),
        #("custom_emoji_id", json.string(custom_emoji_id)),
      ])
  }
}

/// Encode the zero-or-one reaction array required by `setMessageReaction`.
pub fn change_to_json(change: ReactionChange) -> json.Json {
  case change {
    ClearReaction -> json.array([], to_json)
    SetReaction(reaction) -> json.array([reaction], to_json)
  }
}
