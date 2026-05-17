//// Tests mirroring grammY's `test/core/error.test.ts` — the error
//// formatting helpers.

import glammy/error
import glammy/types.{ResponseParameters}
import gleam/option.{None, Some}

pub fn describes_api_error_test() {
  let err =
    error.ApiError(
      method: "sendMessage",
      error_code: 400,
      description: "Bad Request: chat not found",
      parameters: ResponseParameters(
        migrate_to_chat_id: None,
        retry_after: None,
      ),
    )
  assert error.describe(err)
    == "Call to 'sendMessage' failed! (400: Bad Request: chat not found)"
}

pub fn describes_decode_error_test() {
  let err = error.DecodeError(method: "getUpdates", message: "bad json")
  assert error.describe(err) == "Decode error in 'getUpdates': bad json"
}

pub fn describes_api_error_with_retry_after_test() {
  let err =
    error.ApiError(
      method: "sendMessage",
      error_code: 429,
      description: "Too Many Requests",
      parameters: ResponseParameters(
        migrate_to_chat_id: None,
        retry_after: Some(5),
      ),
    )
  assert error.describe(err)
    == "Call to 'sendMessage' failed! (429: Too Many Requests)"
}

pub fn describes_api_error_with_migration_test() {
  let err =
    error.ApiError(
      method: "sendMessage",
      error_code: 400,
      description: "group migrated",
      parameters: ResponseParameters(
        migrate_to_chat_id: Some(-100_123),
        retry_after: None,
      ),
    )
  assert error.describe(err)
    == "Call to 'sendMessage' failed! (400: group migrated)"
}
