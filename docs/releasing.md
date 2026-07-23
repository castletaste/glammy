# Releasing glammy

Hex releases are immutable public API commitments. Do not publish while a
known correctness or liveness blocker remains.

## Public API compatibility

When a previous Hex release exists, deprecate public surface with a concrete
migration path for at least one published release before removing it. A
pre-1.0 breaking removal increments the minor version; after 1.0 it increments
the major version.

Every removal release must list each symbol and replacement, include the
complete package-interface diff, and account for downstream
`--warnings-as-errors` users. For a first Hex publication, describe changes
from source candidates as historical context rather than claiming a published
deprecation window.

## Prepare

1. Audit against the latest Telegram Bot API release. Record the supported
   Bot API version and any intentional gaps in the changelog. Run the local
   parser tests and live comparison before changing the reviewed baseline:

   ```sh
   python3 -m unittest discover -s scripts/tests -p 'test_telegram_bot_api_schema.py'
   python3 scripts/telegram_bot_api_schema.py check
   ```

   The comparison detects upstream structure, not glammy implementation parity.
   If it reports drift, review every change and the release notes before using
   `snapshot --expect-version X.Y --expect-release-date YYYY-MM-DD`; never
   refresh the baseline merely to make the workflow green.
2. Choose the SemVer version from the actual public API diff. Move the relevant
   entries from `Unreleased` into a dated changelog section.
3. Replace the README pre-release installation note with `gleam add glammy`
   only when the package is ready to be published.
4. Check that every new public type and function has user-facing documentation
   and that the compiled consumer example uses the intended API.
5. Confirm the release-tested matrix in CI. The dependency-floor lane uses
   Gleam 1.16.0 / OTP 27; locked builds use Gleam 1.17.0 / OTP 28 and OTP 29,
   with the release artifact produced on OTP 29. Do not claim support for an
   untested runtime from BIF availability alone.
6. Run an intentional `gleam update`, review every `manifest.toml` change and
   upstream release note, then rerun the full matrix. Do not refresh the lock
   file as an unreviewed side effect of publishing.
7. Select one full 40-character release commit already at `origin/main`. For a
   later release, review the complete range from the previous annotated release
   tag, not only the last commit:

   ```sh
   git log --oneline --decorate PREVIOUS_TAG..RELEASE_SHA
   git diff --stat PREVIOUS_TAG..RELEASE_SHA
   ```

   For the first release, where no previous tag exists, review the complete
   history and compare the release tree with Git's empty tree:

   ```sh
   git log --oneline --decorate RELEASE_SHA
   git diff --stat "$(git hash-object -t tree /dev/null)" RELEASE_SHA
   ```

   In either case, require a fully clean non-ignored worktree at that exact
   remote commit:

   ```sh
   test "$(git rev-parse HEAD)" = "$RELEASE_SHA"
   test "$(git rev-parse origin/main)" = "$RELEASE_SHA"
   test -z "$(git status --porcelain=v1 --untracked-files=all)"
   ```

8. Use the release artifact produced by the pinned Ubuntu 24.04 / Gleam 1.17.0
   / OTP 29 CI lane for that exact commit. Keep its `SHA256SUMS` and
   `PROVENANCE.txt` beside the reviewed tarball. A green artifact from another
   commit, compiler, or ref is not a publish candidate.

## Validate

Run the same gates as CI from a clean checkout:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
python3 scripts/telegram_bot_api_schema.py check
gleam deps download
git ls-files --error-unmatch manifest.toml
test -z "$(git status --porcelain=v1 --untracked-files=all -- manifest.toml)"
gleam build --warnings-as-errors
gleam test
./scripts/check_keyed_executor_startup_barrier.sh
gleam docs build
gleam format --check src test examples/echo_bot/src
git diff --check
./scripts/check_min_deps.sh
gleam export hex-tarball
./scripts/verify_hex_tarball.sh
set -- build/glammy-*.tar
test "$#" -eq 1
GLAMMY_HEX_ARCHIVE=$1 python3 scripts/tests/test_verify_hex_tarball.py
cp build/glammy-*.tar /tmp/glammy-first-export.tar
gleam export hex-tarball
./scripts/compare_hex_artifacts.sh \
  /tmp/glammy-first-export.tar build/glammy-*.tar
./scripts/build_hex_consumer.sh
```

Then build `examples/echo_bot` as an external consumer:

```sh
cd examples/echo_bot
gleam deps download
git ls-files --error-unmatch manifest.toml
test -z "$(git status --porcelain=v1 --untracked-files=all -- manifest.toml)"
gleam build --warnings-as-errors
```

The floor gate resolves every advertised lower bound without the repository
manifest, then builds and tests that isolated project. The tarball verifier
requires Hex package format `VERSION` 3 and validates the envelope SHA-256
`CHECKSUM`. It decodes `metadata.config` with Erlang, then compares package
name, version, the complete runtime requirement set, and the metadata file list
against the reviewed `gleam.toml` and `contents.tar.gz`; another export is not
the source of truth. Even byte-identical archives pass through this validation
before the reproducibility fast path. Unexpected top-level metadata keys,
duplicate keys, or unknown requirement-property shapes also fail until the
pinned exporter change is reviewed. The outer Hex envelope is an uncompressed
POSIX tar; only its nested `contents.tar.gz` member is gzip-compressed. CI runs
these operations on Ubuntu 24.04 with GNU tar so BSD-only auto-detection cannot
hide a wrong `-z` flag.

The package must contain `LICENSE`, `README.md`, `gleam.toml`, the intended
Gleam/Erlang sources, and exporter-generated Erlang/include files. The verifier
rejects an outer envelope or compressed contents above 8 MiB, or package
contents above 64 MiB uncompressed, before inner extraction. It also rejects
tests, examples, build directories, unrelated files,
non-canonical or unsafe paths, non-regular entries, and credential patterns.
That scan includes 32-hex keys in literal `HEXPM_API_KEY` / `HEX_API_KEY`
assignments, including `gleam publish`, `export`, and `env` command forms,
plus current opaque/fine-grained/stateless-JWT GitHub token prefixes, without
treating every unrelated MD5-shaped value as a credential. Scanner and parser
errors fail closed; they are not treated as a clean scan. The mutation suite
proves these negative cases. The final consumer gate compiles
`examples/echo_bot` against the unpacked artifact rather than the working tree.

Gleam 1.17.0 writes Hex requirements by iterating its dependency map, so two
exports can order the same requirements differently. The reproducibility gate
accounts for exactly that upstream ordering variance: both archives must be
individually valid, their package members and file bytes must match, and parsed
metadata may differ only by the order of the requirements list. Gleam also
preserves source checkout mtimes in the inner tar, so that timestamp alone is
ignored while modes, owners, uncompressed sizes, paths, ordering, and bytes
remain exact. The resulting compressed size may consequently differ.
Any other metadata, archive-header, or content difference fails closed.

`gleam export hex-tarball` does not currently put `CHANGELOG.md` or the
`docs/` Markdown sources in `contents.tar.gz`. They remain repository and
HexDocs inputs: validate them with `gleam docs build`, review the changelog in
the release commit, and verify the rendered HexDocs after publishing. Never
place a Hex API key in the repository or command line.

## Publish

Do not publish from a mutable local checkout. The only normal path is the
manual **Publish Hex package** GitHub workflow, dispatched from `main`. It never
runs for a pull request, push, ordinary merge, or tag event, and it does not
create a tag or GitHub release.

Before dispatch, obtain separate authorization for both the tag and the Hex
publication. Create an **annotated** `vX.Y.Z` tag that resolves to the exact
reviewed `origin/main` commit and push that tag. Configure the protected
`hex-publish` GitHub environment with required reviewers and its
`HEXPM_API_KEY`; the workflow exposes that secret only to the publish step.
Then dispatch from `main` with:

- the full lowercase 40-character commit SHA;
- the stable `X.Y.Z` version matching `gleam.toml` and `vX.Y.Z`;
- the exact confirmation text `PUBLISH glammy X.Y.Z`.

The workflow rejects a branch-selected dispatch, a moving/stale main SHA, a
lightweight or mismatched tag, a dirty tree, a different manifest version, or a
different Gleam/OTP release. It reruns the full release gates, exports twice,
verifies the archive and mutation suite, records SHA-256 and provenance, and
uploads that immutable pre-publish evidence before the secret-bearing step.
Only then does it run `gleam publish --yes` behind the protected environment
gate. Post-publish evidence is a separate artifact, because GitHub artifact v4
does not append to an existing upload.

Gleam 1.17 has no option to publish an already-reviewed tarball: `gleam
publish` builds the package and documentation again before upload. Therefore
the handoff cannot honestly promise raw-byte identity with the CI tarball.
Source mtimes and requirement ordering can change bytes even for the same
commit. The binding is instead the strongest supported semantic chain: exact
commit/tag/toolchain, independently verified pre-publish archive and digest,
then download of Hex's published tarball and fail-closed semantic comparison
against that archive. The workflow also checks the Hex release API and rendered
versioned HexDocs, and uploads pre/post artifacts, hashes, and provenance even
when post-publish verification fails.

After the workflow succeeds, independently confirm installation from an empty
consumer project:

```sh
consumer_root=$(mktemp -d)
cd "$consumer_root"
gleam new smoke
cd smoke
gleam add glammy@X.Y.Z
gleam build --warnings-as-errors
```

Record the workflow URL, reviewed commit/tree, annotated tag, pinned compiler,
pre-publish SHA-256, published SHA-256, Hex API response, HexDocs URL, and smoke
result in the release record. If publication succeeds but a later verification
step fails, inspect the uploaded evidence and the public Hex package; do not
blindly rerun or use `gleam publish --replace`. Replacement remains an explicit
incident-recovery action governed by Hex policy, never the normal release flow.
