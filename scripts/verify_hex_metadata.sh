#!/bin/sh

set -eu

fail() {
  printf '%s\n' "Hex metadata check failed: $*" >&2
  exit 1
}

if [ "$#" -ne 3 ]; then
  fail "usage: $0 metadata.config contents.list gleam.toml"
fi

metadata=$1
contents_list=$2
manifest=$3

for file in "$metadata" "$contents_list" "$manifest"; do
  [ -f "$file" ] || fail "required input is missing"
done

for tool in awk cmp erl sort uniq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/glammy-hex-metadata.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

# Parse only the reviewed package identity and runtime dependency table. These
# fields use simple TOML strings in gleam.toml; fail closed if that deliberately
# narrow grammar changes instead of guessing at a new manifest representation.
if ! awk '
  function die(message) {
    print "gleam.toml: " message > "/dev/stderr"
    failed = 1
    exit 2
  }

  function trim(value) {
    sub(/^[ \t]+/, "", value)
    sub(/[ \t]+$/, "", value)
    return value
  }

  function key_of(line, separator, key) {
    separator = index(line, "=")
    if (separator == 0) die("expected key = simple-string")
    key = trim(substr(line, 1, separator - 1))
    if (key !~ /^[A-Za-z0-9_-]+$/) die("unsupported key syntax")
    return key
  }

  function value_of(line, separator, value) {
    separator = index(line, "=")
    if (separator == 0) die("expected key = simple-string")
    value = trim(substr(line, separator + 1))
    if (value !~ /^"[^"]*"$/) die("expected a simple quoted string")
    value = substr(value, 2, length(value) - 2)
    if (value ~ /[\\\t\r]/) die("unsupported escape or control character")
    return value
  }

  BEGIN { section = "" }

  /^[ \t]*($|#)/ { next }

  /^[ \t]*\[/ {
    section = trim($0)
    next
  }

  {
    line = trim($0)
    if (section == "" && line ~ /^(name|version)[ \t]*=/) {
      key = key_of(line)
      value = value_of(line)
      if (key == "name") {
        if (++name_count != 1) die("duplicate package name")
        package_name = value
      } else {
        if (++version_count != 1) die("duplicate package version")
        package_version = value
      }
      next
    }

    if (section == "[dependencies]") {
      dependency = key_of(line)
      requirement = value_of(line)
      if (dependency in dependencies) die("duplicate runtime dependency")
      dependencies[dependency] = requirement
    }
  }

  END {
    if (failed) exit 2
    if (name_count != 1 || package_name == "") die("missing package name")
    if (version_count != 1 || package_version == "") die("missing package version")
    print "name\t" package_name
    print "version\t" package_version
    for (dependency in dependencies) {
      print "requirement\t" dependency "\t" dependencies[dependency]
    }
  }
' "$manifest" > "$tmp_dir/expected-project"; then
  fail "could not read reviewed package metadata from gleam.toml"
fi

# Erlang's parser is the authority for metadata.config. Validate the decoded
# term shapes and emit only sanitized fields; parser failures are intentionally
# hidden so hostile metadata cannot be reflected into CI logs.
if ! erl -noshell -eval '
  Result = try
    [MetadataPath, ProjectPath, FilesPath] = init:get_plain_arguments(),
    {ok, Terms} = file:consult(MetadataPath),
    true = is_list(Terms),
    Pairs = lists:map(
      fun
        ({Key, Value}) when is_binary(Key) -> {Key, Value};
        (_) -> throw(invalid_top_level_term)
      end,
      Terms
    ),
    Keys = [Key || {Key, _} <- Pairs],
    true = length(Keys) =:= length(lists:usort(Keys)),
    ExpectedKeys = [
      <<"app">>,
      <<"build_tools">>,
      <<"description">>,
      <<"files">>,
      <<"licenses">>,
      <<"links">>,
      <<"name">>,
      <<"requirements">>,
      <<"version">>
    ],
    true = lists:sort(Keys) =:= ExpectedKeys,
    Metadata = maps:from_list(Pairs),
    Safe = fun(Value) ->
      is_binary(Value)
      andalso binary:match(Value, <<"\t">>) =:= nomatch
      andalso binary:match(Value, <<"\n">>) =:= nomatch
      andalso binary:match(Value, <<"\r">>) =:= nomatch
    end,
    Name = maps:get(<<"name">>, Metadata),
    App = maps:get(<<"app">>, Metadata),
    Version = maps:get(<<"version">>, Metadata),
    Description = maps:get(<<"description">>, Metadata),
    Licenses = maps:get(<<"licenses">>, Metadata),
    Links = maps:get(<<"links">>, Metadata),
    true = Safe(Name),
    true = Safe(App),
    true = Safe(Version),
    true = Safe(Description),
    true = is_list(Licenses),
    true = lists:all(Safe, Licenses),
    true = is_list(Links),
    true = lists:all(
      fun
        ({Title, Url}) -> Safe(Title) andalso Safe(Url);
        (_) -> false
      end,
      Links
    ),
    true = App =:= Name,
    [<<"gleam">>] = maps:get(<<"build_tools">>, Metadata),
    Requirements = maps:get(<<"requirements">>, Metadata),
    true = is_list(Requirements),
    RequirementLines = lists:map(
      fun
        ({Dependency, Properties}) when is_binary(Dependency), is_list(Properties) ->
          true = Safe(Dependency),
          PropertyPairs = lists:map(
            fun
              ({Key, Value}) when is_binary(Key) -> {Key, Value};
              (_) -> throw(invalid_requirement_property)
            end,
            Properties
          ),
          PropertyKeys = [Key || {Key, _} <- PropertyPairs],
          true = length(PropertyKeys) =:= length(lists:usort(PropertyKeys)),
          [<<"app">>, <<"optional">>, <<"requirement">>] =
            lists:sort(PropertyKeys),
          PropertyMap = maps:from_list(PropertyPairs),
          Dependency = maps:get(<<"app">>, PropertyMap),
          false = maps:get(<<"optional">>, PropertyMap),
          Requirement = maps:get(<<"requirement">>, PropertyMap),
          true = Safe(Requirement),
          [<<"requirement\t">>, Dependency, <<"\t">>, Requirement, <<"\n">>];
        (_) -> throw(invalid_requirement)
      end,
      Requirements
    ),
    RequirementNames = [Dependency || {Dependency, _} <- Requirements],
    true = length(RequirementNames) =:= length(lists:usort(RequirementNames)),
    Files = maps:get(<<"files">>, Metadata),
    true = is_list(Files),
    true = lists:all(Safe, Files),
    true = length(Files) =:= length(lists:usort(Files)),
    ok = file:write_file(
      ProjectPath,
      [[<<"name\t">>, Name, <<"\nversion\t">>, Version, <<"\n">>], RequirementLines]
    ),
    ok = file:write_file(FilesPath, [[File, <<"\n">>] || File <- Files]),
    ok
  catch
    _:_ -> invalid
  end,
  case Result of
    ok -> halt(0);
    invalid -> halt(1)
  end.
' -extra "$metadata" "$tmp_dir/actual-project" "$tmp_dir/metadata-files" \
  > /dev/null 2>&1; then
  fail "metadata.config is malformed or uses an unsupported structure"
fi

LC_ALL=C sort "$tmp_dir/expected-project" > "$tmp_dir/expected-project.sorted"
LC_ALL=C sort "$tmp_dir/actual-project" > "$tmp_dir/actual-project.sorted"
cmp -s "$tmp_dir/expected-project.sorted" "$tmp_dir/actual-project.sorted" ||
  fail "decoded name, version, or requirements differ from gleam.toml"

LC_ALL=C sort "$tmp_dir/metadata-files" > "$tmp_dir/metadata-files.sorted"
uniq -d "$tmp_dir/metadata-files.sorted" > "$tmp_dir/metadata-files.duplicates"
[ ! -s "$tmp_dir/metadata-files.duplicates" ] ||
  fail "metadata.config contains duplicate package files"
LC_ALL=C sort "$contents_list" > "$tmp_dir/contents.sorted"
cmp -s "$tmp_dir/contents.sorted" "$tmp_dir/metadata-files.sorted" ||
  fail "decoded metadata file list differs from contents.tar.gz"

printf '%s\n' "Hex metadata OK"
