#!/bin/sh

set -eu

fail() {
  printf '%s\n' "Hex reproducibility check failed: $*" >&2
  exit 1
}

if [ "$#" -ne 2 ]; then
  fail "usage: $0 first-package.tar second-package.tar"
fi

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
first=$1
second=$2

case "$first" in
  /*) ;;
  *) first=$(CDPATH= cd "$(dirname "$first")" && pwd)/$(basename "$first") ;;
esac
case "$second" in
  /*) ;;
  *) second=$(CDPATH= cd "$(dirname "$second")" && pwd)/$(basename "$second") ;;
esac

cd "$repo_dir"
./scripts/verify_hex_tarball.sh "$first"
./scripts/verify_hex_tarball.sh "$second"

if cmp -s "$first" "$second"; then
  printf '%s\n' "Hex artifacts are byte-identical"
  exit 0
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/glammy-hex-repro.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
mkdir "$tmp_dir/first" "$tmp_dir/second"
tar -xf "$first" -C "$tmp_dir/first"
tar -xf "$second" -C "$tmp_dir/second"

cmp -s "$tmp_dir/first/VERSION" "$tmp_dir/second/VERSION" ||
  fail "Hex format VERSION differs"
python3 scripts/compare_hex_archives.py "$first" "$second" ||
  fail "archive structure or package file bytes differ"

# Gleam 1.17.0 emits requirements by iterating a hash map, so their order can
# vary between otherwise identical exports. Parse the Erlang terms and permit
# only that semantically irrelevant permutation; every other metadata change
# remains fatal.
erl -noshell -eval '
  [First, Second] = init:get_plain_arguments(),
  {ok, FirstTerms} = file:consult(First),
  {ok, SecondTerms} = file:consult(Second),
  Normalize = fun(Terms) ->
    lists:map(
      fun
        ({<<"requirements">>, Requirements}) ->
          {<<"requirements">>, lists:sort(Requirements)};
        (Term) -> Term
      end,
      Terms
    )
  end,
  case Normalize(FirstTerms) =:= Normalize(SecondTerms) of
    true -> halt(0);
    false -> halt(1)
  end.
' -extra \
  "$tmp_dir/first/metadata.config" \
  "$tmp_dir/second/metadata.config" ||
  fail "metadata differs beyond dependency ordering"

printf '%s\n' \
  "Hex artifacts are semantically identical; only mtimes/requirement order may differ"
