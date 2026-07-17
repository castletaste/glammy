#!/bin/sh

set -eu

fail() {
  printf '%s\n' "hex tarball check failed: $*" >&2
  exit 1
}

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$repo_dir"

for tool in awk cmp find grep python3 sort tar tr uniq wc; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

max_compressed_bytes=8388608
max_uncompressed_bytes=67108864

file_size_bytes() {
  count=$(wc -c < "$1") || fail "could not measure archive size"
  count=$(printf '%s' "$count" | tr -d '[:space:]')
  case "$count" in
    ""|*[!0-9]*) fail "archive size was not numeric" ;;
  esac
  printf '%s' "$count"
}

sha256_file() {
  file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum "$file") || fail "sha256sum failed"
  elif command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 "$file") || fail "shasum failed"
  else
    fail "sha256sum or shasum is required"
  fi
  digest=${output%% *}
  printf '%s' "$digest" | tr '[:upper:]' '[:lower:]'
}

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
archive_size=$(file_size_bytes "$archive")
[ "$archive_size" -le "$max_compressed_bytes" ] ||
  fail "outer archive exceeds the 8 MiB envelope limit"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/glammy-hex.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

tar -tf "$archive" > "$tmp_dir/outer.list"
tar -tvf "$archive" > "$tmp_dir/outer.verbose"
LC_ALL=C sort "$tmp_dir/outer.list" > "$tmp_dir/outer.sorted"
cat > "$tmp_dir/outer.expected" <<'EOF'
CHECKSUM
VERSION
contents.tar.gz
metadata.config
EOF

if ! cmp -s "$tmp_dir/outer.expected" "$tmp_dir/outer.sorted"; then
  printf '%s\n' "unexpected Hex envelope:" >&2
  cat "$tmp_dir/outer.list" >&2
  fail "outer archive must contain only VERSION, metadata.config, contents.tar.gz, and CHECKSUM"
fi

if awk 'substr($1, 1, 1) != "-" { exit 1 }' "$tmp_dir/outer.verbose"; then
  :
else
  fail "outer archive must contain regular files only"
fi

mkdir "$tmp_dir/outer"
tar -xf "$archive" -C "$tmp_dir/outer"

contents_size=$(file_size_bytes "$tmp_dir/outer/contents.tar.gz")
[ "$contents_size" -le "$max_compressed_bytes" ] ||
  fail "contents.tar.gz exceeds the 8 MiB compressed limit"

if ! python3 - "$tmp_dir/outer/contents.tar.gz" "$max_uncompressed_bytes" \
  > /dev/null 2>&1 <<'PY'
import sys
import tarfile

archive_path = sys.argv[1]
limit = int(sys.argv[2])
total = 0
with tarfile.open(archive_path, mode="r:gz") as archive:
    for member in archive:
        if member.size < 0:
            raise ValueError("negative member size")
        total += member.size
        if total > limit:
            raise ValueError("uncompressed limit exceeded")
PY
then
  fail "contents.tar.gz is invalid or exceeds the 64 MiB uncompressed limit"
fi

printf '3' > "$tmp_dir/VERSION.expected"
cmp -s "$tmp_dir/VERSION.expected" "$tmp_dir/outer/VERSION" ||
  fail "VERSION must be the supported Hex package format 3"

tr -d '\r\n' < "$tmp_dir/outer/CHECKSUM" > "$tmp_dir/checksum.compact"
tr '[:upper:]' '[:lower:]' \
  < "$tmp_dir/checksum.compact" > "$tmp_dir/checksum.normalized"
expected_checksum=$(cat "$tmp_dir/checksum.normalized")
case "$expected_checksum" in
  ""|*[!0-9a-f]*) fail "CHECKSUM must contain exactly one SHA-256 digest" ;;
esac
[ "${#expected_checksum}" -eq 64 ] ||
  fail "CHECKSUM must contain exactly one SHA-256 digest"
cat \
  "$tmp_dir/outer/VERSION" \
  "$tmp_dir/outer/metadata.config" \
  "$tmp_dir/outer/contents.tar.gz" > "$tmp_dir/checksum.input"
actual_checksum=$(sha256_file "$tmp_dir/checksum.input")
[ "$actual_checksum" = "$expected_checksum" ] ||
  fail "CHECKSUM does not match VERSION, metadata.config, and contents.tar.gz"

tar -tzf "$tmp_dir/outer/contents.tar.gz" > "$tmp_dir/contents.list"
tar -tvzf "$tmp_dir/outer/contents.tar.gz" > "$tmp_dir/contents.verbose"

if awk 'substr($1, 1, 1) != "-" { exit 1 }' "$tmp_dir/contents.verbose"; then
  :
else
  fail "package contents must be regular files only"
fi

LC_ALL=C sort "$tmp_dir/contents.list" > "$tmp_dir/contents.sorted"
uniq -d "$tmp_dir/contents.sorted" > "$tmp_dir/contents.duplicates"
if [ -s "$tmp_dir/contents.duplicates" ]; then
  printf '%s\n' "duplicate package members:" >&2
  cat "$tmp_dir/contents.duplicates" >&2
  fail "package members must be unique"
fi

while IFS= read -r member; do
  case "$member" in
    ""|/*|.|..|../*|*/../*|*/..)
      fail "unsafe package member path: $member"
      ;;
  esac

  case "$member" in
    ./*|*/./*|*/.|*//* )
      fail "non-canonical package member path: $member"
      ;;
  esac

  case "$member" in
    build/*|test/*|tests/*|example/*|examples/*|docs/*|scripts/*|.git/*|.github/*)
      fail "development-only path was packaged: $member"
      ;;
  esac

  lower_member=$(printf '%s' "$member" | tr '[:upper:]' '[:lower:]')
  case "$lower_member" in
    .env|.env.*|*/.env|*/.env.*|*credentials*|*id_rsa*|*.pem|*.key|*.p12|*.pfx)
      fail "secret-like file was packaged: $member"
      ;;
  esac

  case "$member" in
    README.md|LICENSE|gleam.toml|src/*.gleam|src/*.erl|src/*.app.src|include/*.hrl)
      ;;
    *)
      fail "unexpected package member: $member"
      ;;
  esac
done < "$tmp_dir/contents.list"

for required in \
  README.md \
  LICENSE \
  gleam.toml \
  src/glammy.gleam \
  src/glammy_ffi.erl \
  src/glammy.app.src \
  src/glammy.erl \
  include/glammy@api_Api.hrl
do
  grep -Fqx "$required" "$tmp_dir/contents.list" ||
    fail "required package member is missing: $required"
done

./scripts/verify_hex_metadata.sh \
  "$tmp_dir/outer/metadata.config" \
  "$tmp_dir/contents.list" \
  gleam.toml

mkdir "$tmp_dir/contents"
tar -xzf "$tmp_dir/outer/contents.tar.gz" -C "$tmp_dir/contents"

if ! find "$tmp_dir/contents" -type l -print > "$tmp_dir/symlinks.list"; then
  fail "could not inspect package symbolic links"
fi
if [ -s "$tmp_dir/symlinks.list" ]; then
  fail "symbolic links are not allowed in the package"
fi

grep -Fq '{applications, [crypto,' "$tmp_dir/contents/src/glammy.app.src" ||
  fail "generated OTP application metadata must declare crypto"
if grep -Fq 'gleeunit' \
  "$tmp_dir/outer/metadata.config" \
  "$tmp_dir/contents/src/glammy.app.src"; then
  fail "dev-only gleeunit leaked into runtime package metadata"
else
  status=$?
  [ "$status" -eq 1 ] || fail "could not scan runtime package metadata"
fi

if ! find src -type f -name '*.gleam' -print > "$tmp_dir/repository.gleam.unsorted"; then
  fail "could not enumerate repository Gleam sources"
fi
LC_ALL=C sort "$tmp_dir/repository.gleam.unsorted" > "$tmp_dir/repository.gleam"
awk '/^src\/.*\.gleam$/ { print }' \
  "$tmp_dir/contents.list" > "$tmp_dir/package.gleam.unsorted"
LC_ALL=C sort "$tmp_dir/package.gleam.unsorted" > "$tmp_dir/package.gleam"

if ! cmp -s "$tmp_dir/repository.gleam" "$tmp_dir/package.gleam"; then
  diff -u "$tmp_dir/repository.gleam" "$tmp_dir/package.gleam" >&2 || true
  fail "packaged Gleam source set differs from repository"
fi

for source in README.md LICENSE gleam.toml; do
  cmp -s "$source" "$tmp_dir/contents/$source" ||
    fail "packaged file differs from repository: $source"
done

if ! find src -type f \
  \( -name '*.gleam' -o -name '*.erl' -o -name '*.hrl' -o -name '*.app.src' \) \
  -print > "$tmp_dir/repository.sources"; then
  fail "could not enumerate repository sources"
fi

while IFS= read -r source; do
  [ -f "$tmp_dir/contents/$source" ] ||
    fail "repository source is missing from package: $source"
  cmp -s "$source" "$tmp_dir/contents/$source" ||
    fail "packaged source differs from repository: $source"
done < "$tmp_dir/repository.sources"

secret_pattern="-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|[0-9]{6,}:[A-Za-z0-9_-]{30,}|AKIA[0-9A-Z]{16}|github_pat_[A-Za-z0-9_]{20,}|ghs_[A-Za-z0-9._-]{36,}|gh[pour]_[A-Za-z0-9_]{20,}|(^|[^A-Za-z0-9_])(HEXPM_API_KEY|HEX_API_KEY|hexpm_api_key|hex_api_key|--hexpm-api-key|--hex-api-key)[[:space:]\"'=:]{1,16}[0-9A-Fa-f]{32}([^0-9A-Fa-f]|$)"

scan_secret_file() {
  candidate=$1
  display_name=$2
  if LC_ALL=C grep -E -l -- "$secret_pattern" "$candidate" >/dev/null; then
    printf '%s\n' "$display_name" >> "$tmp_dir/secrets.list"
  else
    status=$?
    [ "$status" -eq 1 ] || fail "secret scanner failed for $display_name"
  fi
}

: > "$tmp_dir/secrets.list"
scan_secret_file "$tmp_dir/outer/metadata.config" metadata.config
if ! find "$tmp_dir/contents" -type f -print > "$tmp_dir/secret-scan-files.list"; then
  fail "could not enumerate files for the secret scan"
fi
while IFS= read -r candidate; do
  display_name=${candidate#"$tmp_dir/contents/"}
  scan_secret_file "$candidate" "$display_name"
done < "$tmp_dir/secret-scan-files.list"

if [ -s "$tmp_dir/secrets.list" ]; then
  printf '%s\n' "files containing secret-like material:" >&2
  cat "$tmp_dir/secrets.list" >&2
  fail "remove credentials before publishing"
fi

member_count=$(awk 'END { print NR }' "$tmp_dir/contents.list")
printf '%s\n' "Hex tarball OK: $archive ($member_count package files)"
