#!/usr/bin/env python3
"""Deterministic Telegram Bot API schema snapshot and drift checker.

The parser intentionally records only structural API facts: the latest Bot API
version and release date, method names and parameters, and type names and
fields. Descriptions are excluded because editorial changes are not schema
drift.
"""

from __future__ import annotations

import argparse
import json
import re
import ssl
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import date
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Mapping, Sequence


FORMAT_VERSION = 1
OFFICIAL_URL = "https://core.telegram.org/bots/api"
DEFAULT_BASELINE = (
    Path(__file__).resolve().parents[1] / "schema" / "telegram-bot-api.json"
)
MAX_DOCUMENT_BYTES = 5 * 1024 * 1024
FETCH_TIMEOUT_SECONDS = 30
MIN_LIVE_METHODS = 100
MIN_LIVE_TYPES = 200
MIN_LIVE_FIELDS = 1_000
LIVE_SENTINELS = {
    "methods": {
        "getUpdates": ("offset", "allowed_updates"),
        "sendMessage": ("chat_id", "text"),
        "setWebhook": ("url", "secret_token"),
    },
    "types": {
        "Message": ("message_id", "date", "chat"),
        "Update": ("update_id", "message"),
        "User": ("id", "is_bot"),
    },
}

METHOD_NAME = re.compile(r"^[a-z][A-Za-z0-9]*$")
TYPE_NAME = re.compile(r"^[A-Z][A-Za-z0-9]*$")
VERSION = re.compile(r"^\d+\.\d+$")
ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
LATEST_VERSION = re.compile(r"\bBot API\s+(\d+\.\d+)\b")
RELEASE_HEADING = re.compile(
    r"^(January|February|March|April|May|June|July|August|September|"
    r"October|November|December)\s+(\d{1,2}),\s+(\d{4})$"
)
MONTHS = {
    "January": 1,
    "February": 2,
    "March": 3,
    "April": 4,
    "May": 5,
    "June": 6,
    "July": 7,
    "August": 8,
    "September": 9,
    "October": 10,
    "November": 11,
    "December": 12,
}


class SchemaError(Exception):
    """Raised when a document or snapshot cannot prove its schema."""


@dataclass
class Section:
    heading: str
    body_parts: list[str] = field(default_factory=list)
    tables: list[list[list[str]]] = field(default_factory=list)

    @property
    def body(self) -> str:
        return normalize_text(" ".join(self.body_parts))


class BotApiHTMLParser(HTMLParser):
    """Small purpose-built parser for h4-scoped Bot API sections and tables."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.sections: list[Section] = []
        self._section: Section | None = None
        self._heading_tag: str | None = None
        self._heading_parts: list[str] = []
        self._table: list[list[str]] | None = None
        self._row: list[str] | None = None
        self._cell_tag: str | None = None
        self._cell_parts: list[str] = []

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        del attrs
        if tag in {"h3", "h4"}:
            self._finish_section()
            self._heading_tag = tag
            self._heading_parts = []
        elif tag == "table" and self._section is not None:
            if self._table is not None:
                raise SchemaError("nested tables are not supported")
            self._table = []
        elif tag == "tr" and self._table is not None:
            self._row = []
        elif tag in {"th", "td"} and self._row is not None:
            self._cell_tag = tag
            self._cell_parts = []

    def handle_endtag(self, tag: str) -> None:
        if tag == self._heading_tag:
            heading = normalize_text(" ".join(self._heading_parts))
            if self._heading_tag == "h4" and heading:
                self._section = Section(heading=heading)
            self._heading_tag = None
            self._heading_parts = []
        elif tag == self._cell_tag:
            assert self._row is not None
            self._row.append(normalize_text(" ".join(self._cell_parts)))
            self._cell_tag = None
            self._cell_parts = []
        elif tag == "tr" and self._row is not None:
            if any(self._row):
                assert self._table is not None
                self._table.append(self._row)
            self._row = None
        elif tag == "table" and self._table is not None:
            assert self._section is not None
            self._section.tables.append(self._table)
            self._table = None

    def handle_data(self, data: str) -> None:
        if self._heading_tag is not None:
            self._heading_parts.append(data)
        elif self._cell_tag is not None:
            self._cell_parts.append(data)
        elif self._section is not None:
            self._section.body_parts.append(data)

    def finish(self) -> None:
        self.close()
        self._finish_section()

    def _finish_section(self) -> None:
        if self._section is not None:
            self.sections.append(self._section)
            self._section = None


def normalize_text(value: str) -> str:
    return " ".join(value.split())


def parse_html(document: str) -> dict[str, Any]:
    parser = BotApiHTMLParser()
    try:
        parser.feed(document)
        parser.finish()
    except (AssertionError, ValueError) as error:
        raise SchemaError(f"malformed HTML structure: {error}") from error

    version, release_date = _latest_release(parser.sections)
    methods: dict[str, Any] = {}
    types: dict[str, Any] = {}

    for section in parser.sections:
        name = section.heading
        if METHOD_NAME.fullmatch(name):
            _insert_entity(
                methods,
                name,
                {"parameters": _method_parameters(section)},
                "method",
            )
        elif TYPE_NAME.fullmatch(name):
            _insert_entity(
                types,
                name,
                {"fields": _type_fields(section)},
                "type",
            )

    snapshot = {
        "bot_api": {"released": release_date, "version": version},
        "format_version": FORMAT_VERSION,
        "methods": methods,
        "source": OFFICIAL_URL,
        "types": types,
    }
    validate_snapshot(snapshot)
    return snapshot


def _latest_release(sections: Sequence[Section]) -> tuple[str, str]:
    for section in sections:
        match = RELEASE_HEADING.fullmatch(section.heading)
        if match is None:
            continue
        version_match = LATEST_VERSION.search(section.body)
        if version_match is None:
            continue
        month_name, day, year = match.groups()
        release_date = f"{int(year):04d}-{MONTHS[month_name]:02d}-{int(day):02d}"
        return version_match.group(1), release_date
    raise SchemaError("latest Bot API version and release date were not found")


def _insert_entity(
    entities: dict[str, Any], name: str, value: dict[str, Any], kind: str
) -> None:
    if name in entities:
        raise SchemaError(f"duplicate {kind} section: {name}")
    entities[name] = value


def _schema_table(
    section: Section, expected_header: tuple[str, ...]
) -> list[list[str]] | None:
    candidates = [
        table
        for table in section.tables
        if table and tuple(cell.lower() for cell in table[0]) == expected_header
    ]
    if len(candidates) > 1:
        raise SchemaError(f"multiple schema tables in section {section.heading}")
    return candidates[0] if candidates else None


def _method_parameters(section: Section) -> dict[str, dict[str, Any]]:
    table = _schema_table(
        section, ("parameter", "type", "required", "description")
    )
    if table is None:
        return {}
    parameters: dict[str, dict[str, Any]] = {}
    for index, row in enumerate(table[1:], start=2):
        if len(row) != 4:
            raise SchemaError(
                f"{section.heading} parameter table row {index} has {len(row)} cells"
            )
        name, type_name, required_text, _description = row
        _validate_member_name(section.heading, name, "parameter")
        if required_text.lower() == "yes":
            required = True
        elif required_text.lower() == "optional":
            required = False
        else:
            raise SchemaError(
                f"{section.heading}.{name} has unknown required marker: "
                f"{required_text!r}"
            )
        _insert_member(parameters, section.heading, name, type_name, required)
    return parameters


def _type_fields(section: Section) -> dict[str, dict[str, Any]]:
    table = _schema_table(section, ("field", "type", "description"))
    if table is None:
        return {}
    fields: dict[str, dict[str, Any]] = {}
    for index, row in enumerate(table[1:], start=2):
        if len(row) != 3:
            raise SchemaError(
                f"{section.heading} field table row {index} has {len(row)} cells"
            )
        name, type_name, description = row
        _validate_member_name(section.heading, name, "field")
        required = re.match(r"^Optional\b", description, re.IGNORECASE) is None
        _insert_member(fields, section.heading, name, type_name, required)
    return fields


def _validate_member_name(entity: str, name: str, kind: str) -> None:
    if re.fullmatch(r"^[a-z][a-z0-9_]*$", name) is None:
        raise SchemaError(f"invalid {kind} name in {entity}: {name!r}")


def _insert_member(
    members: dict[str, dict[str, Any]],
    entity: str,
    name: str,
    type_name: str,
    required: bool,
) -> None:
    if name in members:
        raise SchemaError(f"duplicate schema member: {entity}.{name}")
    if not type_name:
        raise SchemaError(f"empty type for schema member: {entity}.{name}")
    members[name] = {"required": required, "type": type_name}


def validate_snapshot(snapshot: Mapping[str, Any], *, live: bool = False) -> None:
    expected_top_level = {"bot_api", "format_version", "methods", "source", "types"}
    if set(snapshot) != expected_top_level:
        raise SchemaError(
            "snapshot keys differ from the supported format: "
            f"{sorted(snapshot)}"
        )
    if snapshot["format_version"] != FORMAT_VERSION:
        raise SchemaError(
            f"unsupported snapshot format: {snapshot['format_version']!r}"
        )
    if snapshot["source"] != OFFICIAL_URL:
        raise SchemaError(f"unexpected schema source: {snapshot['source']!r}")

    bot_api = snapshot["bot_api"]
    if not isinstance(bot_api, dict) or set(bot_api) != {"released", "version"}:
        raise SchemaError("bot_api must contain exactly released and version")
    if not isinstance(bot_api["version"], str) or VERSION.fullmatch(
        bot_api["version"]
    ) is None:
        raise SchemaError(f"invalid Bot API version: {bot_api['version']!r}")
    if not isinstance(bot_api["released"], str) or ISO_DATE.fullmatch(
        bot_api["released"]
    ) is None:
        raise SchemaError(f"invalid Bot API release date: {bot_api['released']!r}")
    try:
        date.fromisoformat(bot_api["released"])
    except ValueError as error:
        raise SchemaError(
            f"invalid Bot API release date: {bot_api['released']!r}"
        ) from error

    _validate_entities(snapshot["methods"], "parameters", METHOD_NAME, "method")
    _validate_entities(snapshot["types"], "fields", TYPE_NAME, "type")

    if live:
        counts = snapshot_counts(snapshot)
        if counts["methods"] < MIN_LIVE_METHODS:
            raise SchemaError(
                f"live document exposes only {counts['methods']} methods; parser/layout failure likely"
            )
        if counts["types"] < MIN_LIVE_TYPES:
            raise SchemaError(
                f"live document exposes only {counts['types']} types; parser/layout failure likely"
            )
        if counts["members"] < MIN_LIVE_FIELDS:
            raise SchemaError(
                f"live document exposes only {counts['members']} fields/parameters; "
                "parser/layout failure likely"
            )
        _validate_live_sentinels(snapshot)


def _validate_live_sentinels(snapshot: Mapping[str, Any]) -> None:
    for inventory_name, entities in LIVE_SENTINELS.items():
        member_key = "parameters" if inventory_name == "methods" else "fields"
        inventory = snapshot[inventory_name]
        for entity_name, member_names in entities.items():
            if entity_name not in inventory:
                raise SchemaError(
                    f"live document is missing sentinel {inventory_name[:-1]} {entity_name}"
                )
            members = inventory[entity_name][member_key]
            for member_name in member_names:
                if member_name not in members:
                    raise SchemaError(
                        "live document is missing sentinel member "
                        f"{entity_name}.{member_name}"
                    )


def _validate_entities(
    entities: Any, member_key: str, name_pattern: re.Pattern[str], kind: str
) -> None:
    if not isinstance(entities, dict):
        raise SchemaError(f"{kind} inventory must be an object")
    for name, entity in entities.items():
        if not isinstance(name, str) or name_pattern.fullmatch(name) is None:
            raise SchemaError(f"invalid {kind} name: {name!r}")
        if not isinstance(entity, dict) or set(entity) != {member_key}:
            raise SchemaError(f"invalid {kind} entry: {name}")
        members = entity[member_key]
        if not isinstance(members, dict):
            raise SchemaError(f"invalid member inventory for {kind}: {name}")
        for member_name, member in members.items():
            if not isinstance(member_name, str) or re.fullmatch(
                r"^[a-z][a-z0-9_]*$", member_name
            ) is None:
                raise SchemaError(f"invalid member name in {name}: {member_name!r}")
            if not isinstance(member, dict) or set(member) != {"required", "type"}:
                raise SchemaError(f"invalid member entry: {name}.{member_name}")
            if not isinstance(member["required"], bool):
                raise SchemaError(f"required must be Boolean: {name}.{member_name}")
            if not isinstance(member["type"], str) or not member["type"]:
                raise SchemaError(f"type must be a non-empty string: {name}.{member_name}")


def snapshot_counts(snapshot: Mapping[str, Any]) -> dict[str, int]:
    methods = snapshot["methods"]
    types = snapshot["types"]
    parameters = sum(len(method["parameters"]) for method in methods.values())
    fields = sum(len(type_info["fields"]) for type_info in types.values())
    return {
        "fields": fields,
        "members": fields + parameters,
        "methods": len(methods),
        "parameters": parameters,
        "types": len(types),
    }


def fetch_official_html() -> str:
    request = urllib.request.Request(
        OFFICIAL_URL,
        headers={
            "Accept": "text/html",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "User-Agent": "glammy-schema-drift-guard/1",
        },
    )
    context = ssl.create_default_context()
    try:
        with urllib.request.urlopen(
            request, timeout=FETCH_TIMEOUT_SECONDS, context=context
        ) as response:
            final_url = response.geturl().rstrip("/")
            if final_url != OFFICIAL_URL:
                raise SchemaError(f"official endpoint redirected to {final_url!r}")
            content_type = response.headers.get_content_type()
            if content_type != "text/html":
                raise SchemaError(f"unexpected content type: {content_type!r}")
            payload = response.read(MAX_DOCUMENT_BYTES + 1)
    except (OSError, urllib.error.URLError) as error:
        raise SchemaError(f"could not fetch {OFFICIAL_URL}: {error}") from error
    if len(payload) > MAX_DOCUMENT_BYTES:
        raise SchemaError("official Bot API document exceeds the 5 MiB safety limit")
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SchemaError("official Bot API document is not valid UTF-8") from error


def canonical_json(snapshot: Mapping[str, Any]) -> str:
    return json.dumps(snapshot, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def load_snapshot(path: Path, *, live: bool = True) -> dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as error:
        raise SchemaError(f"could not read baseline {path}: {error}") from error

    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise SchemaError(f"duplicate JSON key in baseline: {key}")
            result[key] = value
        return result

    try:
        snapshot = json.loads(raw, object_pairs_hook=reject_duplicate_keys)
    except json.JSONDecodeError as error:
        raise SchemaError(f"invalid baseline JSON at {path}: {error}") from error
    if not isinstance(snapshot, dict):
        raise SchemaError("baseline root must be a JSON object")
    validate_snapshot(snapshot, live=live)
    if raw != canonical_json(snapshot):
        raise SchemaError(
            f"baseline {path} is not canonical; regenerate it with the snapshot command"
        )
    return snapshot


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=path.parent, delete=False
        ) as handle:
            handle.write(content)
            temporary = Path(handle.name)
        temporary.replace(path)
    except OSError as error:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
        raise SchemaError(f"could not write {path}: {error}") from error


def compare_snapshots(
    baseline: Mapping[str, Any], current: Mapping[str, Any]
) -> dict[str, Any]:
    changes: dict[str, Any] = {
        "added_methods": [],
        "added_types": [],
        "changed_fields": [],
        "changed_parameters": [],
        "release_changed": baseline["bot_api"] != current["bot_api"],
        "removed_methods": [],
        "removed_types": [],
    }
    for inventory_name, added_key, removed_key, member_key, changed_key in (
        ("methods", "added_methods", "removed_methods", "parameters", "changed_parameters"),
        ("types", "added_types", "removed_types", "fields", "changed_fields"),
    ):
        old_inventory = baseline[inventory_name]
        new_inventory = current[inventory_name]
        old_names = set(old_inventory)
        new_names = set(new_inventory)
        changes[added_key] = sorted(new_names - old_names)
        changes[removed_key] = sorted(old_names - new_names)
        for entity_name in sorted(old_names & new_names):
            old_members = old_inventory[entity_name][member_key]
            new_members = new_inventory[entity_name][member_key]
            old_member_names = set(old_members)
            new_member_names = set(new_members)
            for member_name in sorted(new_member_names - old_member_names):
                changes[changed_key].append(
                    {
                        "change": "added",
                        "entity": entity_name,
                        "member": member_name,
                        "new": new_members[member_name],
                    }
                )
            for member_name in sorted(old_member_names - new_member_names):
                changes[changed_key].append(
                    {
                        "change": "removed",
                        "entity": entity_name,
                        "member": member_name,
                        "old": old_members[member_name],
                    }
                )
            for member_name in sorted(old_member_names & new_member_names):
                if old_members[member_name] != new_members[member_name]:
                    changes[changed_key].append(
                        {
                            "change": "changed",
                            "entity": entity_name,
                            "member": member_name,
                            "old": old_members[member_name],
                            "new": new_members[member_name],
                        }
                    )
    return changes


def has_drift(changes: Mapping[str, Any]) -> bool:
    return bool(
        changes["release_changed"]
        or any(
            changes[key]
            for key in (
                "added_methods",
                "removed_methods",
                "added_types",
                "removed_types",
                "changed_parameters",
                "changed_fields",
            )
        )
    )


def render_report(
    baseline: Mapping[str, Any], current: Mapping[str, Any], changes: Mapping[str, Any]
) -> str:
    drift = has_drift(changes)
    old_api = baseline["bot_api"]
    new_api = current["bot_api"]
    old_counts = snapshot_counts(baseline)
    new_counts = snapshot_counts(current)
    lines = [
        "# Telegram Bot API schema drift report",
        "",
        (
            "**Result: FAIL — structural drift requires maintainer review.**"
            if drift
            else "**Result: PASS — live schema matches the checked-in baseline.**"
        ),
        "",
        f"- Baseline: Bot API {old_api['version']} ({old_api['released']})",
        f"- Live: Bot API {new_api['version']} ({new_api['released']})",
        (
            "- Baseline inventory: "
            f"{old_counts['methods']} methods / {old_counts['parameters']} parameters / "
            f"{old_counts['types']} types / {old_counts['fields']} fields"
        ),
        (
            "- Live inventory: "
            f"{new_counts['methods']} methods / {new_counts['parameters']} parameters / "
            f"{new_counts['types']} types / {new_counts['fields']} fields"
        ),
        "",
    ]
    if not drift:
        lines.append("Descriptions are intentionally excluded from this structural check.")
        return "\n".join(lines) + "\n"

    for title, key in (
        ("Added methods", "added_methods"),
        ("Removed methods", "removed_methods"),
        ("Added types", "added_types"),
        ("Removed types", "removed_types"),
    ):
        values = changes[key]
        if values:
            lines.extend([f"## {title} ({len(values)})", ""])
            lines.extend(f"- `{markdown_code(value)}`" for value in values)
            lines.append("")
    _append_member_changes(lines, "Method parameter changes", changes["changed_parameters"])
    _append_member_changes(lines, "Type field changes", changes["changed_fields"])
    lines.extend(
        [
            "Review the upstream release notes, map intentional glammy gaps, and only then",
            "regenerate the baseline with an explicit expected version and release date.",
        ]
    )
    return "\n".join(lines) + "\n"


def markdown_code(value: str) -> str:
    return value.replace("`", "\\`").replace("|", "\\|")


def _append_member_changes(
    lines: list[str], title: str, changes: Sequence[Mapping[str, Any]]
) -> None:
    if not changes:
        return
    lines.extend([f"## {title} ({len(changes)})", ""])
    for change in changes:
        name = markdown_code(f"{change['entity']}.{change['member']}")
        if change["change"] == "added":
            lines.append(f"- Added `{name}`: {_render_member(change['new'])}")
        elif change["change"] == "removed":
            lines.append(f"- Removed `{name}`: {_render_member(change['old'])}")
        else:
            lines.append(
                f"- Changed `{name}`: {_render_member(change['old'])} → "
                f"{_render_member(change['new'])}"
            )
    lines.append("")


def _render_member(member: Mapping[str, Any]) -> str:
    requirement = "required" if member["required"] else "optional"
    return f"`{markdown_code(member['type'])}` ({requirement})"


def read_current(html_path: Path | None) -> tuple[dict[str, Any], bool]:
    if html_path is None:
        document = fetch_official_html()
        live = True
    else:
        try:
            document = html_path.read_text(encoding="utf-8")
        except OSError as error:
            raise SchemaError(f"could not read HTML fixture {html_path}: {error}") from error
        live = False
    snapshot = parse_html(document)
    validate_snapshot(snapshot, live=live)
    return snapshot, live


def command_check(args: argparse.Namespace) -> int:
    baseline = load_snapshot(args.baseline, live=args.html is None)
    current, _live = read_current(args.html)
    changes = compare_snapshots(baseline, current)
    report = render_report(baseline, current, changes)
    if args.report is not None:
        atomic_write(args.report, report)
    sys.stdout.write(report)
    return 1 if has_drift(changes) else 0


def command_snapshot(args: argparse.Namespace) -> int:
    snapshot, _live = read_current(args.html)
    bot_api = snapshot["bot_api"]
    if bot_api["version"] != args.expect_version:
        raise SchemaError(
            f"refusing baseline update: expected Bot API {args.expect_version}, "
            f"found {bot_api['version']}"
        )
    if bot_api["released"] != args.expect_release_date:
        raise SchemaError(
            "refusing baseline update: expected release date "
            f"{args.expect_release_date}, found {bot_api['released']}"
        )
    atomic_write(args.output, canonical_json(snapshot))
    counts = snapshot_counts(snapshot)
    print(
        f"Wrote Bot API {bot_api['version']} snapshot to {args.output}: "
        f"{counts['methods']} methods, {counts['types']} types, "
        f"{counts['members']} fields/parameters"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Snapshot and compare the official Telegram Bot API schema."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser(
        "check", help="compare the checked-in baseline with the current schema"
    )
    check.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    check.add_argument(
        "--html", type=Path, help="parse a local HTML fixture instead of the live page"
    )
    check.add_argument("--report", type=Path, help="also write the Markdown report")
    check.set_defaults(handler=command_check)

    snapshot = subparsers.add_parser(
        "snapshot", help="write a reviewed canonical schema baseline"
    )
    snapshot.add_argument("--output", type=Path, default=DEFAULT_BASELINE)
    snapshot.add_argument(
        "--html", type=Path, help="parse a local HTML fixture instead of the live page"
    )
    snapshot.add_argument("--expect-version", required=True)
    snapshot.add_argument("--expect-release-date", required=True)
    snapshot.set_defaults(handler=command_snapshot)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.handler(args))
    except SchemaError as error:
        message = f"Schema check could not produce trustworthy evidence: {error}"
        report_path = getattr(args, "report", None)
        if report_path is not None:
            atomic_write(
                report_path,
                "# Telegram Bot API schema drift report\n\n"
                f"**Result: ERROR — {message}**\n",
            )
        print(message, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
