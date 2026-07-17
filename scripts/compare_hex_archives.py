#!/usr/bin/env python3
"""Compare two verified Hex archives while normalizing Gleam 1.17 variance."""

from __future__ import annotations

import io
import sys
import tarfile
from pathlib import Path


class ComparisonError(Exception):
    """The archives differ beyond the explicitly accepted variance."""


def _member_attributes(
    member: tarfile.TarInfo, *, ignore_mtime: bool, ignore_size: bool
) -> tuple[object, ...]:
    pax_headers = tuple(
        sorted(
            (key, value)
            for key, value in member.pax_headers.items()
            if not (ignore_mtime and key == "mtime")
        )
    )
    return (
        member.name,
        member.mode,
        member.uid,
        member.gid,
        None if ignore_size else member.size,
        None if ignore_mtime else member.mtime,
        member.type,
        member.linkname,
        member.uname,
        member.gname,
        member.devmajor,
        member.devminor,
        pax_headers,
        member.sparse,
    )


def _regular_file_bytes(
    archive: tarfile.TarFile, member: tarfile.TarInfo
) -> bytes:
    if not member.isfile():
        raise ComparisonError(f"non-regular archive member: {member.name}")
    stream = archive.extractfile(member)
    if stream is None:
        raise ComparisonError(f"cannot read archive member: {member.name}")
    return stream.read()


def _outer_files(path: Path) -> tuple[list[tarfile.TarInfo], dict[str, bytes]]:
    with tarfile.open(path, mode="r:*") as archive:
        members = archive.getmembers()
        files = {
            member.name: _regular_file_bytes(archive, member) for member in members
        }
    return members, files


def _compare_inner(first: bytes, second: bytes) -> None:
    with (
        tarfile.open(fileobj=io.BytesIO(first), mode="r:gz") as first_archive,
        tarfile.open(fileobj=io.BytesIO(second), mode="r:gz") as second_archive,
    ):
        first_members = first_archive.getmembers()
        second_members = second_archive.getmembers()
        first_names = [member.name for member in first_members]
        second_names = [member.name for member in second_members]
        if first_names != second_names:
            raise ComparisonError("package member ordering differs")

        for first_member, second_member in zip(first_members, second_members):
            if _member_attributes(
                first_member, ignore_mtime=True, ignore_size=False
            ) != _member_attributes(
                second_member, ignore_mtime=True, ignore_size=False
            ):
                raise ComparisonError(
                    f"package header differs beyond mtime: {first_member.name}"
                )
            if _regular_file_bytes(
                first_archive, first_member
            ) != _regular_file_bytes(second_archive, second_member):
                raise ComparisonError(f"package file bytes differ: {first_member.name}")


def compare_archives(first_path: Path, second_path: Path) -> None:
    first_members, first_files = _outer_files(first_path)
    second_members, second_files = _outer_files(second_path)
    first_names = [member.name for member in first_members]
    second_names = [member.name for member in second_members]
    if first_names != second_names:
        raise ComparisonError("outer archive member ordering differs")

    for first_member, second_member in zip(first_members, second_members):
        ignore_size = first_member.name == "contents.tar.gz"
        if _member_attributes(
            first_member, ignore_mtime=False, ignore_size=ignore_size
        ) != _member_attributes(
            second_member, ignore_mtime=False, ignore_size=ignore_size
        ):
            raise ComparisonError(f"outer archive header differs: {first_member.name}")

    if first_files.get("VERSION") != second_files.get("VERSION"):
        raise ComparisonError("Hex format VERSION differs")
    try:
        first_contents = first_files["contents.tar.gz"]
        second_contents = second_files["contents.tar.gz"]
    except KeyError as error:
        raise ComparisonError(f"missing outer archive member: {error.args[0]}") from error
    _compare_inner(first_contents, second_contents)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: compare_hex_archives.py first-package.tar second-package.tar",
            file=sys.stderr,
        )
        return 2
    try:
        compare_archives(Path(argv[1]), Path(argv[2]))
    except (ComparisonError, OSError, tarfile.TarError) as error:
        print(f"Hex archive comparison failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
