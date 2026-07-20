import glammy/escape

pub fn html_escapes_angle_brackets_test() {
  assert escape.html("<b>x</b> & y") == "&lt;b&gt;x&lt;/b&gt; &amp; y"
}

pub fn markdown_v2_escapes_reserved_chars_test() {
  assert escape.markdown_v2("hello (world).") == "hello \\(world\\)\\."
  assert escape.markdown_v2("a*b_c") == "a\\*b\\_c"
  assert escape.markdown_v2("path\\name*") == "path\\\\name\\*"
}

pub fn markdown_legacy_escapes_subset_test() {
  // Legacy mode doesn't escape `.`, `(`, etc.
  assert escape.markdown("a.b") == "a.b"
  assert escape.markdown("a_b*c") == "a\\_b\\*c"
  assert escape.markdown("path\\name") == "path\\\\name"
}
