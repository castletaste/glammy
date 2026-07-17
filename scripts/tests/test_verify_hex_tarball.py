from __future__ import annotations

import copy
import gzip
import hashlib
import io
import os
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from typing import Callable, Optional


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "scripts" / "verify_hex_tarball.sh"
COMPARER = ROOT / "scripts" / "compare_hex_artifacts.sh"
ARCHIVE_ENV = "GLAMMY_HEX_ARCHIVE"
ARCHIVE = os.environ.get(ARCHIVE_ENV)
MAX_COMPRESSED_BYTES = 8 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 64 * 1024 * 1024


class ZeroReader:
    def __init__(self, size: int) -> None:
        self.remaining = size

    def read(self, size: int = -1) -> bytes:
        if self.remaining == 0:
            return b""
        if size < 0 or size > self.remaining:
            size = self.remaining
        self.remaining -= size
        return b"\0" * size


def read_archive(path: Path, mode: str = "r:*") -> list[tuple[tarfile.TarInfo, bytes]]:
    members: list[tuple[tarfile.TarInfo, bytes]] = []
    with tarfile.open(path, mode=mode) as archive:
        for member in archive.getmembers():
            stream = archive.extractfile(member)
            if stream is None:
                raise AssertionError(f"non-file fixture member: {member.name}")
            members.append((copy.copy(member), stream.read()))
    return members


def write_tar(path: Path, members: list[tuple[tarfile.TarInfo, bytes]]) -> None:
    with tarfile.open(path, mode="w") as archive:
        for original, data in members:
            member = copy.copy(original)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))


def rewrite_outer(
    source: Path,
    destination: Path,
    mutate: Callable[[dict[str, bytes]], None],
) -> None:
    members = read_archive(source)
    files = {member.name: data for member, data in members}
    mutate(files)
    files["CHECKSUM"] = hashlib.sha256(
        files["VERSION"] + files["metadata.config"] + files["contents.tar.gz"]
    ).hexdigest().upper().encode("ascii")
    write_tar(destination, [(member, files[member.name]) for member, _ in members])


def mutate_inner_file(files: dict[str, bytes], name: str, suffix: bytes) -> None:
    compressed = io.BytesIO(files["contents.tar.gz"])
    with tarfile.open(fileobj=compressed, mode="r:gz") as archive:
        members: list[tuple[tarfile.TarInfo, bytes]] = []
        for original in archive.getmembers():
            stream = archive.extractfile(original)
            if stream is None:
                raise AssertionError(f"non-file fixture member: {original.name}")
            data = stream.read()
            if original.name == name:
                data += suffix
            members.append((copy.copy(original), data))

    if not any(member.name == name for member, _ in members):
        raise AssertionError(f"fixture member not found: {name}")

    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", mtime=0) as gzip_file:
        with tarfile.open(fileobj=gzip_file, mode="w") as archive:
            for original, data in members:
                member = copy.copy(original)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
    files["contents.tar.gz"] = output.getvalue()


def append_oversized_inner_member(files: dict[str, bytes]) -> None:
    compressed = io.BytesIO(files["contents.tar.gz"])
    members = read_archive_from_stream(compressed)
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", mtime=0) as gzip_file:
        with tarfile.open(fileobj=gzip_file, mode="w") as archive:
            for original, data in members:
                member = copy.copy(original)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            oversized = tarfile.TarInfo("src/oversized.erl")
            oversized.mode = 0o644
            oversized.size = MAX_UNCOMPRESSED_BYTES + 1
            archive.addfile(oversized, ZeroReader(oversized.size))
    files["contents.tar.gz"] = output.getvalue()


def read_archive_from_stream(
    compressed: io.BytesIO,
) -> list[tuple[tarfile.TarInfo, bytes]]:
    members: list[tuple[tarfile.TarInfo, bytes]] = []
    with tarfile.open(fileobj=compressed, mode="r:gz") as archive:
        for original in archive.getmembers():
            stream = archive.extractfile(original)
            if stream is None:
                raise AssertionError(f"non-file fixture member: {original.name}")
            members.append((copy.copy(original), stream.read()))
    return members


@unittest.skipUnless(
    ARCHIVE,
    f"set {ARCHIVE_ENV} to a freshly exported, valid Hex archive",
)
class HexTarballVerifierTest(unittest.TestCase):
    archive = Path(ARCHIVE or "")

    def run_command(
        self, command: list[str], *, env: Optional[dict[str, str]] = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            command,
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def assert_rejected(
        self,
        mutate: Callable[[dict[str, bytes]], None],
        expected: str,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            mutant = Path(directory) / "mutant.tar"
            rewrite_outer(self.archive, mutant, mutate)
            result = self.run_command([str(VERIFIER), str(mutant)])
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(expected, result.stderr)

    def test_accepts_fresh_export(self) -> None:
        self.assertNotEqual(self.archive.read_bytes()[:2], b"\x1f\x8b")
        result = self.run_command([str(VERIFIER), str(self.archive)])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_oversized_outer_archive_before_parsing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            oversized = Path(directory) / "oversized.tar"
            with oversized.open("wb") as stream:
                stream.truncate(MAX_COMPRESSED_BYTES + 1)
            result = self.run_command([str(VERIFIER), str(oversized)])
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("8 MiB envelope limit", result.stderr)

    def test_rejects_oversized_inner_archive_before_extraction(self) -> None:
        self.assert_rejected(
            append_oversized_inner_member,
            "64 MiB uncompressed limit",
        )

    def test_rejects_unsupported_hex_format_version(self) -> None:
        self.assert_rejected(
            lambda files: files.__setitem__("VERSION", b"4"),
            "supported Hex package format 3",
        )

    def test_rejects_metadata_name_version_and_requirement_drift(self) -> None:
        replacements = (
            (b'{<<"name">>, <<"glammy"/utf8>>}.', b'{<<"name">>, <<"other"/utf8>>}.'),
            (b'{<<"version">>, <<"0.1.0"/utf8>>}.', b'{<<"version">>, <<"9.9.9"/utf8>>}.'),
            (b">= 1.0.3 and < 2.0.0", b">= 1.1.0 and < 2.0.0"),
        )
        for original, replacement in replacements:
            with self.subTest(original=original):
                def mutate(files: dict[str, bytes]) -> None:
                    metadata = files["metadata.config"]
                    self.assertEqual(metadata.count(original), 1)
                    metadata = metadata.replace(original, replacement)
                    if b'<<"name">>' in original:
                        metadata = metadata.replace(
                            b'{<<"app">>, <<"glammy"/utf8>>}.',
                            b'{<<"app">>, <<"other"/utf8>>}.',
                        )
                    files["metadata.config"] = metadata

                self.assert_rejected(
                    mutate,
                    "decoded name, version, or requirements differ from gleam.toml",
                )

    def test_rejects_metadata_file_list_drift(self) -> None:
        def mutate(files: dict[str, bytes]) -> None:
            original = b'  <<"README.md"/utf8>>,\n'
            metadata = files["metadata.config"]
            self.assertEqual(metadata.count(original), 1)
            files["metadata.config"] = metadata.replace(original, b"")

        self.assert_rejected(
            mutate,
            "decoded metadata file list differs from contents.tar.gz",
        )

    def test_rejects_unknown_metadata_schema_key(self) -> None:
        self.assert_rejected(
            lambda files: files.__setitem__(
                "metadata.config",
                files["metadata.config"] + b'{<<"unexpected">>, true}.\n',
            ),
            "malformed or uses an unsupported structure",
        )

    def test_identical_archive_fast_path_still_verifies_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            mutant = Path(directory) / "mutant.tar"

            def mutate(files: dict[str, bytes]) -> None:
                metadata = files["metadata.config"].replace(
                    b'{<<"name">>, <<"glammy"/utf8>>}.',
                    b'{<<"name">>, <<"other"/utf8>>}.',
                )
                files["metadata.config"] = metadata.replace(
                    b'{<<"app">>, <<"glammy"/utf8>>}.',
                    b'{<<"app">>, <<"other"/utf8>>}.',
                )

            rewrite_outer(self.archive, mutant, mutate)
            result = self.run_command([str(COMPARER), str(mutant), str(mutant)])
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("differ from gleam.toml", result.stderr)

    def test_rejects_hex_api_key_in_command_and_environment_forms(self) -> None:
        key = b"0123456789abcdef0123456789abcdef"
        leaks = (
            b"\n%% HEXPM_API_KEY=" + key + b" gleam publish --yes\n",
            b"\n%% export HEXPM_API_KEY='" + key + b"'\n",
            b"\n%% env HEXPM_API_KEY=" + key + b" gleam publish\n",
        )
        for leak in leaks:
            with self.subTest(leak=leak):
                self.assert_rejected(
                    lambda files, leak=leak: mutate_inner_file(
                        files, "src/glammy.erl", leak
                    ),
                    "remove credentials before publishing",
                )

    def test_allows_unrelated_md5_shaped_value(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            mutant = Path(directory) / "md5.tar"
            rewrite_outer(
                self.archive,
                mutant,
                lambda files: mutate_inner_file(
                    files,
                    "src/glammy.erl",
                    b"\n%% content_digest=0123456789abcdef0123456789abcdef\n",
                ),
            )
            result = self.run_command([str(VERIFIER), str(mutant)])
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_current_github_token_formats(self) -> None:
        tokens = (
            b"github_pat_11AA22bb33CC44dd55EE66ff77GG88hh99II00jj11KK22ll33MM44nn55OO66pp77QQ88rr",
            b"ghp_AA11_bb22_CC33_dd44_EE55_ff66",
            b"ghs_APP-ID_1234567890."
            + (b"Aa0_-" * 48)
            + b"."
            + (b"Bb1_-" * 48),
        )
        for token in tokens:
            with self.subTest(prefix=token.split(b"_", 1)[0]):
                self.assert_rejected(
                    lambda files, token=token: mutate_inner_file(
                        files,
                        "src/glammy.erl",
                        b"\n%% token=" + token + b"\n",
                    ),
                    "remove credentials before publishing",
                )

    def test_secret_scanner_tool_error_fails_closed(self) -> None:
        real_grep = shutil.which("grep")
        self.assertIsNotNone(real_grep)
        with tempfile.TemporaryDirectory() as directory:
            fake_bin = Path(directory)
            wrapper = fake_bin / "grep"
            wrapper.write_text(
                "#!/bin/sh\n"
                "for argument in \"$@\"; do\n"
                "  [ \"$argument\" = \"-E\" ] && exit 2\n"
                "done\n"
                f"exec {shlex.quote(real_grep or 'grep')} \"$@\"\n",
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
            result = self.run_command(
                [str(VERIFIER), str(self.archive)], env=environment
            )
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("secret scanner failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
