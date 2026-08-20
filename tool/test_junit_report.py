#!/usr/bin/env python3
"""Self-test for junit_report.py — the flutter-test-JSON -> JUnit XML converter.

Stdlib only. Run from the repo root:

    python3 -m unittest discover -s tool -p 'test_*.py' -v

Every case here is a way a build could report FEWER problems than it had. The
converter feeds a CI test-result page, so under-reporting is worse than
crashing: a truncated run, a suite that never compiled, or a byte the JUnit
reader rejects would each turn a broken build into a small green one.
"""

import json
import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import junit_report  # noqa: E402

SUITE = "/repo/integration_test/pin_and_lock_test.dart"


def _events(*events):
    return [{"protocolVersion": "0.1.1", "type": "start", "time": 0}] + list(events)


def _suite(suite_id=0, path=SUITE):
    return {"type": "suite", "suite": {"id": suite_id, "platform": "vm", "path": path}}


def _start(test_id, name, time=0, suite_id=0):
    return {
        "type": "testStart",
        "time": time,
        "test": {"id": test_id, "name": name, "suiteID": suite_id, "groupIDs": []},
    }


def _done(test_id, result="success", skipped=False, hidden=False, time=1000):
    return {
        "type": "testDone",
        "testID": test_id,
        "result": result,
        "skipped": skipped,
        "hidden": hidden,
        "time": time,
    }


class JunitReportTest(unittest.TestCase):
    def _convert(self, events):
        with tempfile.TemporaryDirectory() as tmp:
            events_path = os.path.join(tmp, "report.json")
            xml_path = os.path.join(tmp, "junit.xml")
            with open(events_path, "w", encoding="utf-8") as handle:
                for event in events:
                    handle.write(json.dumps(event) + "\n")
            totals = junit_report.convert(events_path, xml_path)
            return ET.parse(xml_path).getroot(), totals

    def _write_raw(self, text):
        tmp = tempfile.mkdtemp()
        events_path = os.path.join(tmp, "report.json")
        with open(events_path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return events_path, os.path.join(tmp, "junit.xml")

    # ── the ordinary run ────────────────────────────────────────────────
    def test_pass_fail_skip_are_counted_and_attributed(self):
        """The whole point: a build page that names the flow that broke."""
        root, totals = self._convert(
            _events(
                _suite(),
                _start(1, "loading " + SUITE),
                _done(1, hidden=True, time=30000),
                _start(2, "locks after the threshold", time=30000),
                _done(2, time=32000),
                _start(3, "wrong PIN is rejected", time=32000),
                {
                    "type": "error",
                    "testID": 3,
                    "error": "Expected: exactly one matching node\n  Actual: zero",
                    "stackTrace": "package:flutter_test ...",
                    "isFailure": True,
                },
                _done(3, result="failure", time=33500),
                _start(4, "biometric unlock", time=33500),
                {
                    "type": "print",
                    "testID": 4,
                    "messageType": "skip",
                    "message": "Skip: needs Patrol",
                },
                _done(4, skipped=True, time=33500),
                {"type": "done", "success": False},
            )
        )

        self.assertEqual(
            totals,
            {"tests": 3, "failures": 1, "errors": 0, "skipped": 1, "time": 3.5},
        )

        suite = root.find("testsuite")
        self.assertEqual(suite.get("name"), SUITE)
        cases = suite.findall("testcase")
        self.assertEqual(
            [c.get("name") for c in cases],
            ["locks after the threshold", "wrong PIN is rejected", "biometric unlock"],
        )
        # Duration comes from the event times, so a slow flow is visible in the
        # trend rather than hidden behind a pass/fail bit.
        self.assertEqual(cases[0].get("time"), "2.000")
        # One line of the reason in @message (that is all the CI result page
        # shows in the list), the full error + stack in the body.
        self.assertEqual(
            cases[1].find("failure").get("message"), "Expected: exactly one matching node"
        )
        self.assertIn("package:flutter_test", cases[1].find("failure").text)
        self.assertEqual(cases[2].find("skipped").get("message"), "Skip: needs Patrol")

    def test_expect_failure_and_thrown_error_use_different_tags(self):
        """A crash is not an assertion miss; a JUnit reader ranks them apart."""
        root, totals = self._convert(
            _events(
                _suite(),
                _start(1, "sends a transaction"),
                {
                    "type": "error",
                    "testID": 1,
                    "error": "MissingPluginException",
                    "stackTrace": "",
                    "isFailure": False,
                },
                _done(1, result="error"),
            )
        )
        self.assertEqual(totals["errors"], 1)
        self.assertEqual(totals["failures"], 0)
        self.assertIsNotNone(root.find(".//testcase/error"))

    def test_only_a_failing_case_carries_its_stdout(self):
        """The unit suite is ~4100 tests and prints freely. Publishing every
        passing test's output would roughly double the XML on every retained
        build for a log nobody opens — the console already has it. A FAILING
        test's output is the one a triager needs next to the error."""
        root, _ = self._convert(
            _events(
                _suite(),
                _start(1, "passes"),
                {"type": "print", "testID": 1, "message": "[SendSheet] noise"},
                _done(1),
                _start(2, "fails"),
                {"type": "print", "testID": 2, "message": "[SendSheet] the clue"},
                {
                    "type": "error",
                    "testID": 2,
                    "error": "Expected: true",
                    "stackTrace": "",
                    "isFailure": True,
                },
                _done(2, result="failure"),
            )
        )
        cases = root.findall(".//testcase")
        self.assertIsNone(cases[0].find("system-out"))
        self.assertIn("the clue", cases[1].find("system-out").text)

    def test_hidden_loading_test_is_dropped_when_it_passes(self):
        """Counting it would inflate every file by one phantom test."""
        root, _ = self._convert(
            _events(_suite(), _start(1, "loading " + SUITE), _done(1, hidden=True))
        )
        self.assertEqual(root.findall(".//testcase"), [])
        self.assertEqual(root.get("tests"), "0")

    # ── the ways a build could look greener than it was ─────────────────
    def test_suite_that_fails_to_compile_is_reported(self):
        """That failure only ever lands on the hidden `loading` test. Drop it and
        a file that never compiled reports as a file with no problems."""
        root, totals = self._convert(
            _events(
                _suite(),
                _start(1, "loading " + SUITE),
                {
                    "type": "error",
                    "testID": 1,
                    "error": "Error: Method not found: 'resetAppState'",
                    "stackTrace": "",
                    "isFailure": False,
                },
                _done(1, result="error", hidden=True),
            )
        )
        self.assertEqual(totals["tests"], 1)
        self.assertEqual(totals["errors"], 1)
        self.assertIn("Method not found", root.find(".//testcase/error").get("message"))

    def test_unfinished_test_becomes_an_error(self):
        """The stage timeout kills `flutter test` mid-flow. The test that was
        running has a testStart and no testDone — report it, do not lose it."""
        root, totals = self._convert(
            _events(
                _suite(),
                _start(1, "finished", time=0),
                _done(1, time=1000),
                _start(2, "still running when the run was killed", time=1000),
            )
        )
        self.assertEqual(totals["tests"], 2)
        self.assertEqual(totals["errors"], 1)
        killed = root.findall(".//testcase")[1].find("error")
        self.assertIn("did not finish", killed.get("message"))

    def test_truncated_last_line_keeps_every_complete_event(self):
        """A killed writer leaves half a JSON object on the last line."""
        events_path, xml_path = self._write_raw(
            "\n".join(
                json.dumps(e)
                for e in _events(_suite(), _start(1, "flow one"), _done(1))
            )
            + '\n{"type": "testStart", "test": {"id": 2, "na'
        )
        totals = junit_report.convert(events_path, xml_path)
        self.assertEqual(totals["tests"], 1)

    def test_control_characters_are_stripped(self):
        """XML 1.0 rejects them, and a JUnit reader rejects the whole file —
        losing every result to one unprintable byte in a stack trace."""
        root, totals = self._convert(
            _events(
                _suite(),
                _start(1, "renders the list"),
                {
                    "type": "error",
                    "testID": 1,
                    "error": "\x1b[31mred\x1b[0m\x00 boom",
                    "stackTrace": "",
                    "isFailure": True,
                },
                _done(1, result="failure"),
            )
        )
        self.assertEqual(totals["failures"], 1)
        message = root.find(".//testcase/failure").get("message")
        self.assertNotIn("\x00", message)
        self.assertNotIn("\x1b", message)
        self.assertIn("red", message)

    # ── shape a JUnit reader depends on ─────────────────────────────────
    def test_classname_is_the_dotted_suite_path(self):
        """The CI result page splits the classname on `.` for its package tree."""
        root, _ = self._convert(
            _events(
                _suite(
                    path=os.path.join(
                        os.getcwd(), "integration_test", "settings_test.dart"
                    )
                ),
                _start(1, "toggles the theme"),
                _done(1),
            )
        )
        case = root.find(".//testcase")
        self.assertEqual(case.get("classname"), "integration_test.settings_test")
        # Suite paths arrive absolute; the UI shows the repo-relative one.
        self.assertEqual(
            root.find("testsuite").get("name"), "integration_test/settings_test.dart"
        )

    def test_each_suite_gets_its_own_testsuite(self):
        root, totals = self._convert(
            _events(
                _suite(0, "/repo/integration_test/a_test.dart"),
                _suite(1, "/repo/integration_test/b_test.dart"),
                _start(1, "a one", suite_id=0),
                _start(2, "b one", suite_id=1),
                _done(1),
                _done(2, result="failure"),
            )
        )
        names = [s.get("name") for s in root.findall("testsuite")]
        self.assertEqual(
            names,
            ["/repo/integration_test/a_test.dart", "/repo/integration_test/b_test.dart"],
        )
        self.assertEqual(totals["tests"], 2)
        self.assertEqual(totals["failures"], 1)

    # ── the CLI contract a calling CI job relies on ─────────────────────
    def test_missing_event_stream_exits_nonzero(self):
        """`flutter test` wrote nothing: loud, because the alternative is a
        build page that quietly shows no tests."""
        self.assertEqual(
            junit_report.main(
                ["junit_report.py", "/nonexistent/report.json", "/tmp/out.xml"]
            ),
            1,
        )

    def test_empty_run_writes_a_file_and_exits_nonzero(self):
        events_path, xml_path = self._write_raw("")
        self.assertEqual(junit_report.main(["junit_report.py", events_path, xml_path]), 1)
        # The XML still exists so the publisher shows an empty result rather than
        # failing on a missing file.
        self.assertEqual(ET.parse(xml_path).getroot().tag, "testsuites")

    def test_successful_conversion_exits_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            events_path = os.path.join(tmp, "report.json")
            xml_path = os.path.join(tmp, "nested", "junit.xml")
            with open(events_path, "w", encoding="utf-8") as handle:
                for event in _events(_suite(), _start(1, "flow"), _done(1)):
                    handle.write(json.dumps(event) + "\n")
            self.assertEqual(
                junit_report.main(["junit_report.py", events_path, xml_path]), 0
            )
            self.assertTrue(os.path.isfile(xml_path))


if __name__ == "__main__":
    unittest.main()
