//// Validated absolute HTTPS URLs for Bot API fields that require TLS.

import gleam/option.{None, Some}
import gleam/uri

/// An absolute HTTPS URL with a non-empty host and no embedded credentials.
pub opaque type HttpsUrl {
  HttpsUrl(value: String)
}

/// Why a string cannot be used where Telegram requires an HTTPS URL.
pub type HttpsUrlError {
  InvalidHttpsUrl
}

/// Parse and validate an absolute HTTPS URL.
///
/// User-info is rejected so credentials cannot be hidden in a URL accepted by
/// the high-level API. Endpoint-specific server policy remains Telegram-owned.
pub fn new(value: String) -> Result(HttpsUrl, HttpsUrlError) {
  case uri.parse(value) {
    Ok(uri.Uri(scheme: Some("https"), userinfo: None, host: Some(host), ..))
      if host != ""
    -> Ok(HttpsUrl(value))
    _ -> Error(InvalidHttpsUrl)
  }
}

/// Reveal a validated URL for transport encoding.
pub fn to_string(url: HttpsUrl) -> String {
  url.value
}
