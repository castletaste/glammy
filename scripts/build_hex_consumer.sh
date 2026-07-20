#!/bin/sh

set -eu

fail() {
  printf '%s\n' "Hex consumer build failed: $*" >&2
  exit 1
}

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$repo_dir"

if [ "$#" -gt 1 ]; then
  fail "usage: $0 [path/to/package.tar]"
fi

if [ "$#" -eq 1 ]; then
  archive=$1
else
  set -- build/glammy-*.tar
  [ "$#" -eq 1 ] && [ -f "$1" ] ||
    fail "expected exactly one build/glammy-*.tar; pass the archive path explicitly"
  archive=$1
fi

[ -f "$archive" ] || fail "archive not found: $archive"

# Validate before extracting an archive that could otherwise contain unsafe
# member paths. The verifier also proves byte parity with this checkout.
"$repo_dir/scripts/verify_hex_tarball.sh" "$archive"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/glammy-hex-consumer.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

tar -xOf "$archive" contents.tar.gz > "$tmp_dir/contents.tar.gz"
mkdir "$tmp_dir/package"
tar -xzf "$tmp_dir/contents.tar.gz" -C "$tmp_dir/package"

# Reuse the checked-in consumer source but deliberately omit its manifest and
# build directory. From this location `../..` resolves to the unpacked package,
# so this cannot accidentally compile against the working tree.
consumer_dir="$tmp_dir/package/examples/echo_bot"
mkdir -p "$consumer_dir"
cp examples/echo_bot/gleam.toml "$consumer_dir/"
cp -R examples/echo_bot/src "$consumer_dir/"

cd "$consumer_dir"
gleam deps download
gleam build --warnings-as-errors

printf '%s\n' "Unpacked Hex consumer OK: $archive"
