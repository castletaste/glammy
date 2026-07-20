#!/bin/sh

set -eu

fail() {
  printf '%s\n' "minimum dependency check failed: $*" >&2
  exit 1
}

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$repo_dir"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/glammy-min-deps.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

project_dir="$tmp_dir/project"
mkdir "$project_dir"
cp gleam.toml README.md LICENSE "$project_dir/"
cp -R docs src test "$project_dir/"
mkdir "$project_dir/scripts"
cp scripts/check_keyed_executor_startup_barrier.sh "$project_dir/scripts/"

# Gleam package requirements have no equality operator. Pin each declared floor
# to a single patch by making the upper bound the next patch release. Do not
# copy manifest.toml: resolution must prove the advertised lower bounds rather
# than silently reusing the repository lock file.
sed \
  -e 's/>= 1\.0\.3 and < 2\.0\.0/>= 1.0.3 and < 1.0.4/' \
  -e 's/>= 1\.3\.0 and < 2\.0\.0/>= 1.3.0 and < 1.3.1/' \
  -e 's/>= 3\.1\.0 and < 4\.0\.0/>= 3.1.0 and < 3.1.1/' \
  -e 's/>= 4\.3\.0 and < 5\.0\.0/>= 4.3.0 and < 4.3.1/' \
  -e 's/>= 5\.0\.0 and < 6\.0\.0/>= 5.0.0 and < 5.0.1/' \
  -e 's/>= 1\.2\.0 and < 2\.0\.0/>= 1.2.0 and < 1.2.1/' \
  -e 's/>= 1\.11\.0 and < 2\.0\.0/>= 1.11.0 and < 1.11.1/' \
  "$project_dir/gleam.toml" > "$project_dir/gleam.toml.minimum"
mv "$project_dir/gleam.toml.minimum" "$project_dir/gleam.toml"

for requirement in \
  'gleam_stdlib = ">= 1.0.3 and < 1.0.4"' \
  'gleam_erlang = ">= 1.3.0 and < 1.3.1"' \
  'gleam_json = ">= 3.1.0 and < 3.1.1"' \
  'gleam_http = ">= 4.3.0 and < 4.3.1"' \
  'gleam_httpc = ">= 5.0.0 and < 5.0.1"' \
  'gleam_otp = ">= 1.2.0 and < 1.2.1"' \
  'gleeunit = ">= 1.11.0 and < 1.11.1"'
do
  grep -Fqx "$requirement" "$project_dir/gleam.toml" ||
    fail "dependency floor drifted; update this gate: $requirement"
done

awk '
  /^\[dependencies\]$/ { section = "runtime"; next }
  /^\[dev_dependencies\]$/ { section = "dev"; next }
  /^\[/ { section = ""; next }
  section != "" && /^[A-Za-z0-9_]+[[:space:]]*=/ {
    print section ":" $1
  }
' "$project_dir/gleam.toml" | LC_ALL=C sort > "$tmp_dir/actual-dependencies"

cat > "$tmp_dir/expected-dependencies" <<'EOF'
dev:gleeunit
runtime:gleam_erlang
runtime:gleam_http
runtime:gleam_httpc
runtime:gleam_json
runtime:gleam_otp
runtime:gleam_stdlib
EOF

if ! cmp -s "$tmp_dir/expected-dependencies" "$tmp_dir/actual-dependencies"; then
  diff -u "$tmp_dir/expected-dependencies" "$tmp_dir/actual-dependencies" >&2 || true
  fail "dependency set drifted; add every new floor to this fail-closed gate"
fi

cd "$project_dir"
gleam deps download
gleam build --warnings-as-errors
gleam test
./scripts/check_keyed_executor_startup_barrier.sh

printf '%s\n' "Minimum dependency set OK"
