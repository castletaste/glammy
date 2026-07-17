//// Monotonic deadline helpers for bounded actor protocols.

type TimeUnit {
  Millisecond
}

/// Largest finite timeout accepted by BEAM receive and timer primitives.
pub const max_process_timeout_ms = 4_294_967_295

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: TimeUnit) -> Int

/// Current monotonic time in milliseconds.
pub fn now_ms() -> Int {
  monotonic_time(Millisecond)
}

/// A monotonic deadline relative to now.
pub fn deadline_after(timeout_ms: Int) -> Int {
  now_ms() + timeout_ms
}

/// Whether a strictly positive millisecond timeout is safe for BEAM.
pub fn is_valid_process_timeout(timeout_ms: Int) -> Bool {
  timeout_ms > 0 && timeout_ms <= max_process_timeout_ms
}

/// Whether a possibly immediate millisecond timeout is safe for BEAM.
pub fn is_valid_process_timeout_or_zero(timeout_ms: Int) -> Bool {
  timeout_ms >= 0 && timeout_ms <= max_process_timeout_ms
}

/// Milliseconds remaining before a deadline, clamped to zero.
pub fn remaining_ms(deadline_ms: Int) -> Int {
  let remaining = deadline_ms - now_ms()
  case remaining > 0 {
    True -> remaining
    False -> 0
  }
}

/// Whether a monotonic deadline has been reached.
pub fn expired(deadline_ms: Int) -> Bool {
  now_ms() >= deadline_ms
}
