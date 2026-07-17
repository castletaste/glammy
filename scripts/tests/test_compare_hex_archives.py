from __future__ import annotations

import gzip
import io
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import compare_hex_archives as archives


def inner_tar(
    files: list[tuple[str, bytes]], *, mtime: int = 0, mode: int = 0o644
) -> bytes:
    compressed = io.BytesIO()
    with gzip.GzipFile(fileobj=compressed, mode="wb", mtime=0) as gzip_file:
        with tarfile.open(fileobj=gzip_file, mode="w") as archive:
            for name, contents in files:
                member = tarfile.TarInfo(name)
                member.size = len(contents)
                member.mode = mode
                member.mtime = mtime
                archive.addfile(member, io.BytesIO(contents))
    return compressed.getvalue()


def outer_tar(
    path: Path, contents: bytes, *, metadata: bytes = b"metadata", mode: int = 0o600
) -> None:
    members = [
        ("VERSION", b"3"),
        ("metadata.config", metadata),
        ("contents.tar.gz", contents),
        ("CHECKSUM", b"0" * 64),
    ]
    with tarfile.open(path, mode="w") as archive:
        for name, data in members:
            member = tarfile.TarInfo(name)
            member.size = len(data)
            member.mode = mode
            member.mtime = 0
            archive.addfile(member, io.BytesIO(data))


class ArchiveComparisonTest(unittest.TestCase):
    def compare(
        self,
        first_contents: bytes,
        second_contents: bytes,
        *,
        first_metadata: bytes = b"first",
        second_metadata: bytes = b"other",
        second_mode: int = 0o600,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.tar"
            second = Path(directory) / "second.tar"
            outer_tar(first, first_contents, metadata=first_metadata)
            outer_tar(
                second,
                second_contents,
                metadata=second_metadata,
                mode=second_mode,
            )
            archives.compare_archives(first, second)

    def test_allows_only_inner_mtime_and_outer_metadata_bytes(self) -> None:
        self.compare(
            inner_tar([("src/a.gleam", b"pub fn a() { Nil }")], mtime=1),
            inner_tar([("src/a.gleam", b"pub fn a() { Nil }")], mtime=2),
        )

    def test_rejects_changed_file_bytes(self) -> None:
        with self.assertRaisesRegex(archives.ComparisonError, "file bytes differ"):
            self.compare(
                inner_tar([("src/a.gleam", b"first")]),
                inner_tar([("src/a.gleam", b"other")]),
            )

    def test_rejects_changed_inner_mode(self) -> None:
        with self.assertRaisesRegex(archives.ComparisonError, "package header differs"):
            self.compare(
                inner_tar([("src/a.gleam", b"same")], mode=0o644),
                inner_tar([("src/a.gleam", b"same")], mode=0o600),
            )

    def test_rejects_changed_member_order(self) -> None:
        with self.assertRaisesRegex(archives.ComparisonError, "member ordering differs"):
            self.compare(
                inner_tar([("src/a", b"a"), ("src/b", b"b")]),
                inner_tar([("src/b", b"b"), ("src/a", b"a")]),
            )

    def test_rejects_changed_outer_mode(self) -> None:
        with self.assertRaisesRegex(archives.ComparisonError, "outer archive header"):
            self.compare(
                inner_tar([("src/a", b"same")]),
                inner_tar([("src/a", b"same")]),
                second_mode=0o644,
            )


if __name__ == "__main__":
    unittest.main()
