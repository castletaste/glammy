//// Actions shown in Telegram while a bot prepares a response.

/// A finite activity indicator accepted by `sendChatAction`.
pub type ChatAction {
  /// The bot is typing a message.
  Typing
  /// The bot is uploading a photo.
  UploadPhoto
  /// The bot is recording a video.
  RecordVideo
  /// The bot is uploading a video.
  UploadVideo
  /// The bot is recording a voice message.
  RecordVoice
  /// The bot is uploading a voice message.
  UploadVoice
  /// The bot is uploading a document.
  UploadDocument
  /// The bot is choosing a sticker.
  ChooseSticker
  /// The bot is finding a location.
  FindLocation
  /// The bot is recording a video note.
  RecordVideoNote
  /// The bot is uploading a video note.
  UploadVideoNote
}

/// Encode a chat action for `sendChatAction`.
pub fn to_string(action: ChatAction) -> String {
  case action {
    Typing -> "typing"
    UploadPhoto -> "upload_photo"
    RecordVideo -> "record_video"
    UploadVideo -> "upload_video"
    RecordVoice -> "record_voice"
    UploadVoice -> "upload_voice"
    UploadDocument -> "upload_document"
    ChooseSticker -> "choose_sticker"
    FindLocation -> "find_location"
    RecordVideoNote -> "record_video_note"
    UploadVideoNote -> "upload_video_note"
  }
}
