//// Tests mirroring grammY's `test/convenience/inline_query.test.ts`.
//// The grammY suite has ~98 cases enumerating every builder × content
//// type × cached/uncached pair; here we cover one of each major
//// variant, since they share the same put_optional / opt_json
//// machinery.

import glammy/https_url
import glammy/inline_query_results as iqr
import glammy/keyboard
import glammy/parse_mode
import glammy/types
import gleam/json
import gleam/option.{None, Some}
import gleam/string

fn render(result: iqr.InlineQueryResult) -> String {
  result |> iqr.to_json |> json.to_string
}

pub fn results_button_models_exactly_one_action_test() {
  let assert Ok(web_app_url) = https_url.new("https://example.com/app")
  let web =
    iqr.results_web_app_button("Open", web_app_url)
    |> iqr.results_button_to_json
    |> json.to_string
  assert string.contains(web, "\"web_app\":")
  assert !string.contains(web, "start_parameter")

  let assert Ok(start) = iqr.results_start_button("Start", "ref_42-ok")
  let start_json = start |> iqr.results_button_to_json |> json.to_string
  assert string.contains(start_json, "\"start_parameter\":\"ref_42-ok\"")
  assert !string.contains(start_json, "web_app")
  assert iqr.results_start_button("Bad", "")
    == Error(iqr.InvalidStartParameterLength(0))
  assert iqr.results_start_button("Bad", "not allowed")
    == Error(iqr.InvalidStartParameterCharacter(" "))
}

fn render_json(value: json.Json) -> String {
  json.to_string(value)
}

// =====================================================================
//                             article
// =====================================================================

pub fn article_with_text_content_test() {
  let result =
    iqr.article(
      "id",
      "title",
      iqr.InputTextMessageContent(
        message_text: "text",
        parse_mode: None,
        link_preview_options: None,
      ),
      Some("description"),
      None,
      None,
      None,
    )
  let r = render(result)
  let assert True = contains(r, "\"type\":\"article\"")
  let assert True = contains(r, "\"id\":\"id\"")
  let assert True = contains(r, "\"title\":\"title\"")
  let assert True = contains(r, "\"description\":\"description\"")
  let assert True = contains(r, "\"message_text\":\"text\"")
  let assert False = contains(r, "\"url\":")
}

pub fn article_with_url_test() {
  let result =
    iqr.article(
      "id",
      "title",
      iqr.InputTextMessageContent(
        message_text: "t",
        parse_mode: None,
        link_preview_options: None,
      ),
      None,
      Some("https://example.com"),
      None,
      None,
    )
  assert contains(render(result), "\"url\":\"https://example.com\"")
}

// =====================================================================
//                             audio
// =====================================================================

pub fn audio_from_string_url_test() {
  let result =
    iqr.audio(
      "id",
      "https://grammy.dev/",
      "title",
      None,
      None,
      Some("cap"),
      None,
      None,
      Some(parse_mode.Html),
    )
  let r = render(result)
  let assert True = contains(r, "\"type\":\"audio\"")
  let assert True = contains(r, "\"audio_url\":\"https://grammy.dev/\"")
  let assert True = contains(r, "\"caption\":\"cap\"")
  let assert True = contains(r, "\"parse_mode\":\"HTML\"")
}

pub fn audio_with_text_message_content_test() {
  let result =
    iqr.audio(
      "id",
      "https://grammy.dev/",
      "title",
      None,
      None,
      Some("cap"),
      None,
      Some(iqr.InputTextMessageContent(
        message_text: "#Text",
        parse_mode: Some(parse_mode.Markdown),
        link_preview_options: None,
      )),
      None,
    )
  let r = render(result)
  let assert True = contains(r, "\"message_text\":\"#Text\"")
  let assert True = contains(r, "\"parse_mode\":\"Markdown\"")
}

pub fn audio_with_location_message_content_test() {
  let result =
    iqr.audio(
      "id",
      "https://grammy.dev/",
      "title",
      None,
      None,
      Some("cap"),
      None,
      Some(iqr.InputLocationMessageContent(
        latitude: 83.0,
        longitude: 136.0,
        horizontal_accuracy: None,
        live_period: None,
      )),
      None,
    )
  let r = render(result)
  let assert True = contains(r, "\"latitude\":83.0")
  let assert True = contains(r, "\"longitude\":136.0")
}

// =====================================================================
//                             photo
// =====================================================================

pub fn photo_test() {
  let result =
    iqr.photo(
      "p",
      "https://grammy.dev/photo.jpg",
      "https://grammy.dev/thumb.jpg",
      Some("cap"),
      None,
      None,
      None,
      None,
      None,
    )
  let r = render(result)
  let assert True = contains(r, "\"type\":\"photo\"")
  let assert True =
    contains(r, "\"photo_url\":\"https://grammy.dev/photo.jpg\"")
  let assert True = contains(r, "\"caption\":\"cap\"")
}

// =====================================================================
//                             video
// =====================================================================

pub fn video_test() {
  let result =
    iqr.video(
      "v",
      "https://grammy.dev/v.mp4",
      iqr.Mp4Video(None),
      "https://grammy.dev/v.jpg",
      "Title",
      Some("cap"),
      None,
      None,
      None,
    )
  let r = render(result)
  let assert True = contains(r, "\"type\":\"video\"")
  let assert True = contains(r, "\"mime_type\":\"video/mp4\"")
  let assert True = contains(r, "\"video_url\":\"https://grammy.dev/v.mp4\"")
}

pub fn html_video_carries_required_replacement_content_test() {
  let content =
    iqr.InputTextMessageContent(
      message_text: "Watch",
      parse_mode: None,
      link_preview_options: None,
    )
  let result =
    iqr.video(
      "html",
      "https://example.com/player",
      iqr.HtmlVideo(content),
      "https://example.com/thumb.jpg",
      "Player",
      caption: None,
      description: None,
      reply_markup: None,
      parse_mode: None,
    )
  let rendered = render(result)
  assert contains(rendered, "\"mime_type\":\"text/html\"")
  assert contains(rendered, "\"input_message_content\":")
  assert contains(rendered, "\"message_text\":\"Watch\"")
}

// =====================================================================
//                             voice
// =====================================================================

pub fn voice_test() {
  let result =
    iqr.voice(
      "v",
      "https://grammy.dev/voice.ogg",
      "Title",
      Some(30),
      None,
      None,
      None,
      None,
    )
  let r = render(result)
  let assert True = contains(r, "\"type\":\"voice\"")
  let assert True =
    contains(r, "\"voice_url\":\"https://grammy.dev/voice.ogg\"")
  let assert True = contains(r, "\"voice_duration\":30")
}

// =====================================================================
//                             document
// =====================================================================

pub fn document_test() {
  let result =
    iqr.document(
      "d",
      "Title",
      "https://grammy.dev/file.pdf",
      iqr.PdfDocument,
      None,
      Some("description"),
      None,
      None,
      None,
    )
  let r = render(result)
  let assert True = contains(r, "\"type\":\"document\"")
  let assert True = contains(r, "\"mime_type\":\"application/pdf\"")
}

pub fn zip_document_uses_finite_mime_type_test() {
  let result =
    iqr.document(
      "z",
      "Archive",
      "https://grammy.dev/file.zip",
      iqr.ZipDocument,
      caption: None,
      description: None,
      reply_markup: None,
      input_message_content: None,
      parse_mode: None,
    )
  assert contains(render(result), "\"mime_type\":\"application/zip\"")
}

// =====================================================================
//                             location
// =====================================================================

pub fn location_test() {
  let result = iqr.location("l", 83.0, 136.0, "Home", Some(1.0), None, None)
  let r = render(result)
  let assert True = contains(r, "\"type\":\"location\"")
  let assert True = contains(r, "\"latitude\":83.0")
  let assert True = contains(r, "\"longitude\":136.0")
  let assert True = contains(r, "\"horizontal_accuracy\":1.0")
}

// =====================================================================
//                             venue
// =====================================================================

pub fn venue_test() {
  let result = iqr.venue("v", 83.0, 136.0, "Title", "Address", None, None)
  let r = render(result)
  let assert True = contains(r, "\"type\":\"venue\"")
  let assert True = contains(r, "\"title\":\"Title\"")
  let assert True = contains(r, "\"address\":\"Address\"")
}

// =====================================================================
//                             contact
// =====================================================================

pub fn contact_test() {
  let result =
    iqr.contact("c", "+12345", "Bob", Some("Builder"), None, None, None)
  let r = render(result)
  let assert True = contains(r, "\"type\":\"contact\"")
  let assert True = contains(r, "\"phone_number\":\"+12345\"")
  let assert True = contains(r, "\"first_name\":\"Bob\"")
  let assert True = contains(r, "\"last_name\":\"Builder\"")
}

// =====================================================================
//                             game
// =====================================================================

pub fn game_test() {
  let automatic_button = iqr.game("g", "myGame", None) |> render
  let assert True = contains(automatic_button, "\"type\":\"game\"")
  let assert True = contains(automatic_button, "\"game_short_name\":\"myGame\"")
  let assert False = contains(automatic_button, "\"reply_markup\"")

  let trailing =
    keyboard.inline()
    |> keyboard.inline_text("scores", "scores")
  let custom_button =
    iqr.game(
      "g2",
      "myGame",
      Some(keyboard.game_inline_keyboard_with("play", trailing)),
    )
    |> render
  let assert True =
    contains(
      custom_button,
      "\"reply_markup\":{\"inline_keyboard\":[[{\"text\":\"play\",\"callback_game\":{}}],[{\"text\":\"scores\",\"callback_data\":\"scores\"}]]}",
    )
}

// =====================================================================
//                             gif / mpeg4_gif
// =====================================================================

pub fn gif_test() {
  let result =
    iqr.gif(
      "g",
      "https://grammy.dev/a.gif",
      "https://grammy.dev/t.gif",
      Some("Title"),
      None,
      None,
      None,
      None,
    )
  let r = render(result)
  let assert True = contains(r, "\"type\":\"gif\"")
  let assert True = contains(r, "\"gif_url\":\"https://grammy.dev/a.gif\"")
}

pub fn mpeg4_gif_test() {
  let result =
    iqr.mpeg4_gif(
      "m",
      "https://grammy.dev/a.mp4",
      "https://grammy.dev/t.mp4",
      None,
      None,
      None,
      None,
      None,
    )
  let r = render(result)
  let assert True = contains(r, "\"type\":\"mpeg4_gif\"")
  let assert True = contains(r, "\"mpeg4_url\":\"https://grammy.dev/a.mp4\"")
}

// =====================================================================
//                             cached_* variants
// =====================================================================

pub fn cached_photo_test() {
  let result = iqr.cached_photo("p", "PHOTO_ID", Some("cap"), None, None)
  let r = render(result)
  let assert True = contains(r, "\"photo_file_id\":\"PHOTO_ID\"")
  let assert True = contains(r, "\"caption\":\"cap\"")
}

pub fn cached_audio_test() {
  let result = iqr.cached_audio("a", "AUDIO_ID", None, None, None)
  let r = render(result)
  let assert True = contains(r, "\"audio_file_id\":\"AUDIO_ID\"")
}

pub fn cached_document_test() {
  let result = iqr.cached_document("d", "Title", "DOC_ID", None, None, None)
  let r = render(result)
  let assert True = contains(r, "\"document_file_id\":\"DOC_ID\"")
  let assert True = contains(r, "\"title\":\"Title\"")
}

pub fn cached_video_test() {
  let result = iqr.cached_video("v", "Title", "VIDEO_ID", None, None, None)
  let r = render(result)
  let assert True = contains(r, "\"video_file_id\":\"VIDEO_ID\"")
}

pub fn cached_voice_test() {
  let result = iqr.cached_voice("v", "Title", "VOICE_ID", None, None, None)
  let r = render(result)
  let assert True = contains(r, "\"voice_file_id\":\"VOICE_ID\"")
}

pub fn cached_gif_test() {
  let result = iqr.cached_gif("g", "GIF_ID", None, None, None)
  let r = render(result)
  let assert True = contains(r, "\"gif_file_id\":\"GIF_ID\"")
}

pub fn cached_mpeg4_gif_test() {
  let result = iqr.cached_mpeg4_gif("m", "MPEG_ID", None, None, None)
  let r = render(result)
  let assert True = contains(r, "\"mpeg4_file_id\":\"MPEG_ID\"")
}

pub fn cached_sticker_test() {
  let replacement =
    iqr.InputTextMessageContent(
      message_text: "replacement",
      parse_mode: None,
      link_preview_options: None,
    )
  let result = iqr.cached_sticker("s", "STICKER_ID", None, Some(replacement))
  let r = render(result)
  let assert True = contains(r, "\"type\":\"sticker\"")
  let assert True = contains(r, "\"sticker_file_id\":\"STICKER_ID\"")
  let assert True = contains(r, "\"input_message_content\":")

  let without_replacement =
    iqr.cached_sticker("plain", "PLAIN_STICKER_ID", None, None)
    |> render
  let assert False = contains(without_replacement, "input_message_content")
}

// =====================================================================
//                       Input message contents
// =====================================================================

pub fn input_text_message_content_test() {
  let j =
    iqr.input_message_content_to_json(iqr.InputTextMessageContent(
      message_text: "hello",
      parse_mode: Some(parse_mode.Html),
      link_preview_options: Some(types.LinkPreviewOptions(
        is_disabled: Some(True),
        url: None,
        prefer_small_media: None,
        prefer_large_media: None,
        show_above_text: None,
      )),
    ))
  let r = render_json(j)
  let assert True = contains(r, "\"message_text\":\"hello\"")
  let assert True = contains(r, "\"parse_mode\":\"HTML\"")
  let assert True =
    contains(r, "\"link_preview_options\":{\"is_disabled\":true}")
}

pub fn input_location_message_content_test() {
  let j =
    iqr.input_message_content_to_json(iqr.InputLocationMessageContent(
      latitude: 1.0,
      longitude: 2.0,
      horizontal_accuracy: Some(3.0),
      live_period: Some(60),
    ))
  let r = render_json(j)
  let assert True = contains(r, "\"latitude\":1.0")
  let assert True = contains(r, "\"horizontal_accuracy\":3.0")
  let assert True = contains(r, "\"live_period\":60")
}

pub fn input_venue_message_content_test() {
  let j =
    iqr.input_message_content_to_json(iqr.InputVenueMessageContent(
      latitude: 1.0,
      longitude: 2.0,
      title: "T",
      address: "A",
    ))
  let r = render_json(j)
  let assert True = contains(r, "\"title\":\"T\"")
  let assert True = contains(r, "\"address\":\"A\"")
}

pub fn input_contact_message_content_test() {
  let j =
    iqr.input_message_content_to_json(iqr.InputContactMessageContent(
      phone_number: "+1",
      first_name: "Alice",
      last_name: Some("Smith"),
    ))
  let r = render_json(j)
  let assert True = contains(r, "\"phone_number\":\"+1\"")
  let assert True = contains(r, "\"first_name\":\"Alice\"")
  let assert True = contains(r, "\"last_name\":\"Smith\"")
}

pub fn input_invoice_message_content_test() {
  let j =
    iqr.input_message_content_to_json(
      iqr.InputInvoiceMessageContent(
        title: "Product",
        description: "Desc",
        payload: "PAYLOAD",
        provider_token: Some("PROVIDER"),
        currency: "USD",
        prices: [#("Cost", 100)],
      ),
    )
  let r = render_json(j)
  let assert True = contains(r, "\"title\":\"Product\"")
  let assert True = contains(r, "\"currency\":\"USD\"")
  let assert True = contains(r, "\"provider_token\":\"PROVIDER\"")
}

// =====================================================================
//                    answerInlineQuery collection
// =====================================================================

pub fn result_collection_accepts_at_most_fifty_items_test() {
  let result =
    iqr.article(
      "id",
      "title",
      iqr.InputTextMessageContent("body", None, None),
      description: None,
      url: None,
      thumbnail_url: None,
      reply_markup: None,
    )
  case iqr.results(repeat(result, 50)) {
    Ok(_) -> Nil
    _ -> panic as "expected 50 inline results to be valid"
  }
  assert iqr.results(repeat(result, 51))
    == Error(iqr.TooManyInlineQueryResults(51))
}

// =====================================================================
//                          helper
// =====================================================================

fn contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}

fn repeat(value: value, count: Int) -> List(value) {
  case count <= 0 {
    True -> []
    False -> [value, ..repeat(value, count - 1)]
  }
}
