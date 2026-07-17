from __future__ import annotations

import copy
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import telegram_bot_api_schema as schema

FIXTURES = Path(__file__).resolve().parent / "fixtures"


class ParserTest(unittest.TestCase):
    def parse(self, name: str) -> dict:
        return schema.parse_html((FIXTURES / name).read_text(encoding="utf-8"))

    def test_extracts_release_methods_types_and_members(self) -> None:
        snapshot = self.parse("bot_api_10_2_minimal.html")

        self.assertEqual(
            snapshot["bot_api"], {"released": "2026-07-14", "version": "10.2"}
        )
        self.assertEqual(set(snapshot["methods"]), {"getMe", "getUpdates"})
        self.assertEqual(
            snapshot["methods"]["getUpdates"]["parameters"]["timeout"],
            {"required": True, "type": "Integer"},
        )
        self.assertEqual(
            snapshot["types"]["Update"]["fields"]["message"],
            {"required": False, "type": "Message"},
        )
        self.assertEqual(snapshot["types"]["MaybeInaccessibleMessage"]["fields"], {})
        self.assertNotIn("MarkdownV2 style", snapshot["types"])

    def test_output_is_canonical_and_deterministic(self) -> None:
        snapshot = self.parse("bot_api_10_2_minimal.html")
        first = schema.canonical_json(snapshot)
        second = schema.canonical_json(self.parse("bot_api_10_2_minimal.html"))

        self.assertEqual(first, second)
        self.assertEqual(json.loads(first), snapshot)
        self.assertTrue(first.endswith("\n"))

    def test_duplicate_member_fails_closed(self) -> None:
        document = (FIXTURES / "bot_api_10_2_minimal.html").read_text(
            encoding="utf-8"
        )
        duplicate = document.replace(
            "<tr><td>message_id</td><td>Integer</td><td>Unique message identifier.</td></tr>",
            "<tr><td>message_id</td><td>Integer</td><td>First.</td></tr>"
            "<tr><td>message_id</td><td>Integer</td><td>Second.</td></tr>",
        )

        with self.assertRaisesRegex(schema.SchemaError, "duplicate schema member"):
            schema.parse_html(duplicate)

    def test_duplicate_entity_fails_closed(self) -> None:
        document = (FIXTURES / "bot_api_10_2_minimal.html").read_text(
            encoding="utf-8"
        )
        duplicate = document.replace(
            "</body>", "<h4>Update</h4><p>Duplicate object.</p></body>"
        )

        with self.assertRaisesRegex(schema.SchemaError, "duplicate type section"):
            schema.parse_html(duplicate)

    def test_unknown_required_marker_fails_closed(self) -> None:
        document = (FIXTURES / "bot_api_10_2_minimal.html").read_text(
            encoding="utf-8"
        ).replace(
            "<td>timeout</td><td>Integer</td><td>Yes</td>",
            "<td>timeout</td><td>Integer</td><td>Sometimes</td>",
        )

        with self.assertRaisesRegex(schema.SchemaError, "unknown required marker"):
            schema.parse_html(document)

    def test_error_page_fails_instead_of_producing_empty_baseline(self) -> None:
        with self.assertRaisesRegex(schema.SchemaError, "version and release date"):
            schema.parse_html("<html><h1>Service unavailable</h1></html>")

    def test_live_guard_rejects_fixture_sized_inventory(self) -> None:
        snapshot = self.parse("bot_api_10_2_minimal.html")

        with self.assertRaisesRegex(schema.SchemaError, "methods; parser/layout failure"):
            schema.validate_snapshot(snapshot, live=True)


class ComparisonTest(unittest.TestCase):
    def parse(self, name: str) -> dict:
        return schema.parse_html((FIXTURES / name).read_text(encoding="utf-8"))

    def test_reports_release_entity_and_member_drift(self) -> None:
        baseline = self.parse("bot_api_10_2_minimal.html")
        current = self.parse("bot_api_10_3_drift.html")
        changes = schema.compare_snapshots(baseline, current)
        report = schema.render_report(baseline, current, changes)

        self.assertTrue(schema.has_drift(changes))
        self.assertEqual(changes["added_methods"], ["sendNovelThing"])
        self.assertEqual(changes["removed_methods"], ["getMe"])
        self.assertEqual(changes["added_types"], ["NewType"])
        self.assertEqual(changes["removed_types"], ["MaybeInaccessibleMessage"])
        self.assertIn("Changed `getUpdates.offset`", report)
        self.assertIn("Added `Update.new_update`", report)
        self.assertIn("Changed `Update.update_id`", report)
        self.assertIn("Bot API 10.3", report)

    def test_description_only_change_is_not_drift(self) -> None:
        document = (FIXTURES / "bot_api_10_2_minimal.html").read_text(
            encoding="utf-8"
        )
        changed_description = document.replace(
            "New incoming message.", "Editorially rewritten description."
        )
        baseline = schema.parse_html(document)
        current = schema.parse_html(changed_description)

        self.assertFalse(schema.has_drift(schema.compare_snapshots(baseline, current)))

    def test_required_marker_change_is_drift(self) -> None:
        baseline = self.parse("bot_api_10_2_minimal.html")
        current = copy.deepcopy(baseline)
        current["methods"]["getUpdates"]["parameters"]["offset"]["required"] = True

        changes = schema.compare_snapshots(baseline, current)

        self.assertTrue(schema.has_drift(changes))
        self.assertEqual(changes["changed_parameters"][0]["change"], "changed")

    def test_check_command_accepts_matching_local_fixture(self) -> None:
        baseline = self.parse("bot_api_10_2_minimal.html")
        with tempfile.TemporaryDirectory() as directory:
            baseline_path = Path(directory) / "baseline.json"
            report_path = Path(directory) / "report.md"
            baseline_path.write_text(schema.canonical_json(baseline), encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                result = schema.main(
                    [
                        "check",
                        "--baseline",
                        str(baseline_path),
                        "--html",
                        str(FIXTURES / "bot_api_10_2_minimal.html"),
                        "--report",
                        str(report_path),
                    ]
                )

            self.assertEqual(result, 0)
            self.assertIn("Result: PASS", report_path.read_text(encoding="utf-8"))

    def test_check_command_returns_one_for_structural_drift(self) -> None:
        baseline = self.parse("bot_api_10_2_minimal.html")
        with tempfile.TemporaryDirectory() as directory:
            baseline_path = Path(directory) / "baseline.json"
            report_path = Path(directory) / "report.md"
            baseline_path.write_text(schema.canonical_json(baseline), encoding="utf-8")

            with contextlib.redirect_stdout(io.StringIO()):
                result = schema.main(
                    [
                        "check",
                        "--baseline",
                        str(baseline_path),
                        "--html",
                        str(FIXTURES / "bot_api_10_3_drift.html"),
                        "--report",
                        str(report_path),
                    ]
                )

            self.assertEqual(result, 1)
            self.assertIn("Result: FAIL", report_path.read_text(encoding="utf-8"))

    def test_check_command_returns_two_and_writes_operational_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.md"
            with contextlib.redirect_stderr(io.StringIO()):
                result = schema.main(
                    [
                        "check",
                        "--baseline",
                        str(Path(directory) / "missing.json"),
                        "--html",
                        str(FIXTURES / "bot_api_10_2_minimal.html"),
                        "--report",
                        str(report_path),
                    ]
                )

            self.assertEqual(result, 2)
            self.assertIn("Result: ERROR", report_path.read_text(encoding="utf-8"))

    def test_baseline_loader_rejects_duplicate_json_keys(self) -> None:
        snapshot = self.parse("bot_api_10_2_minimal.html")
        duplicate = schema.canonical_json(snapshot).replace(
            '  "source": "https://core.telegram.org/bots/api",',
            '  "source": "https://core.telegram.org/bots/api",\n'
            '  "source": "https://core.telegram.org/bots/api",',
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text(duplicate, encoding="utf-8")

            with self.assertRaisesRegex(schema.SchemaError, "duplicate JSON key"):
                schema.load_snapshot(path, live=False)

    def test_snapshot_requires_explicit_matching_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "snapshot.json"

            with self.assertRaisesRegex(schema.SchemaError, "expected Bot API 10.3"):
                schema.command_snapshot(
                    type(
                        "Args",
                        (),
                        {
                            "expect_release_date": "2026-07-14",
                            "expect_version": "10.3",
                            "html": FIXTURES / "bot_api_10_2_minimal.html",
                            "output": output,
                        },
                    )()
                )
            self.assertFalse(output.exists())

    def test_snapshot_writes_a_canonical_matching_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "snapshot.json"
            args = type(
                "Args",
                (),
                {
                    "expect_release_date": "2026-07-14",
                    "expect_version": "10.2",
                    "html": FIXTURES / "bot_api_10_2_minimal.html",
                    "output": output,
                },
            )()

            with contextlib.redirect_stdout(io.StringIO()):
                result = schema.command_snapshot(args)

            self.assertEqual(result, 0)
            self.assertEqual(
                schema.load_snapshot(output, live=False),
                self.parse("bot_api_10_2_minimal.html"),
            )


if __name__ == "__main__":
    unittest.main()
