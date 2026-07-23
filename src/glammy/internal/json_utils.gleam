//// Shared JSON-building helpers. Internal to glammy — not part of the
//// public API.

import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

// =====================================================================
//                       Encoder helpers (pipe-friendly)
// =====================================================================

/// Append `(key, encode(value))` to an existing field list, but only if
/// `value` is `Some`. Designed for the pipe-builder pattern.
pub fn put_optional(
  fields: List(#(String, json.Json)),
  key: String,
  value: Option(a),
  encode: fn(a) -> json.Json,
) -> List(#(String, json.Json)) {
  case value {
    None -> fields
    Some(v) -> list.append(fields, [#(key, encode(v))])
  }
}

// =====================================================================
//                       Decoder helpers (use-friendly)
// =====================================================================

/// Decoder helper for `optional_field(key, None, decode.optional(decode.string))`
/// — the most common shape when modelling Telegram types. Use with `<-`:
/// `use name <- opt_str("name")`.
pub fn opt_str(
  key: String,
  next: fn(Option(String)) -> Decoder(t),
) -> Decoder(t) {
  decode.optional_field(key, None, decode.optional(decode.string), next)
}

pub fn opt_int(key: String, next: fn(Option(Int)) -> Decoder(t)) -> Decoder(t) {
  decode.optional_field(key, None, decode.optional(decode.int), next)
}

pub fn opt_bool(
  key: String,
  next: fn(Option(Bool)) -> Decoder(t),
) -> Decoder(t) {
  decode.optional_field(key, None, decode.optional(decode.bool), next)
}

pub fn opt_float(
  key: String,
  next: fn(Option(Float)) -> Decoder(t),
) -> Decoder(t) {
  decode.optional_field(key, None, decode.optional(decode.float), next)
}

/// Decoder helper for `optional_field(key, None, decode.optional(decoder))`
/// — the common shape for an optional nested object. Use with `<-`:
/// `use thumbnail <- opt_nested("thumbnail", photo_size_decoder())`.
pub fn opt_nested(
  key: String,
  decoder: Decoder(a),
  next: fn(Option(a)) -> Decoder(t),
) -> Decoder(t) {
  decode.optional_field(key, None, decode.optional(decoder), next)
}

/// Decoder helper for `optional_field(key, [], decode.list(decoder))` — the
/// common shape for an optional list field. Use with `<-`:
/// `use entities <- opt_list("entities", message_entity_decoder())`.
pub fn opt_list(
  key: String,
  decoder: Decoder(a),
  next: fn(List(a)) -> Decoder(t),
) -> Decoder(t) {
  decode.optional_field(key, [], decode.list(decoder), next)
}
