#!/usr/bin/env python3
"""Convert `flutter test --file-reporter=json:<file>` output into JUnit XML.

For either test run — the unit suite or the integration (e2e) one. Each is a
single `flutter test`, so without this a CI job sees nothing but that command's
exit code: a red build names no test, a green build proves nothing about WHICH
tests ran, and neither reaches a test-result trend.
`--file-reporter` writes the machine-readable event stream ALONGSIDE the console
reporter (it does not replace it); this turns that stream into JUnit XML, which
most CI platforms can publish natively.

Usage:
  python3 tool/junit_report.py <events.json> <junit.xml>

The exit status is about the CONVERSION, not about the tests: 0 when the XML was
written, 1 when the event stream is missing or holds no usable event. Keep
`flutter test`'s own status as the verdict on the tests themselves.

Event stream reference: https://dart.dev/go/test-docs/json_reporter.md
"""

import json
import os
import sys
import xml.etree.ElementTree as ET

# XML 1.0 forbids most control characters. Flutter's output carries them (ANSI
# colour escapes in a stack trace, a stray \x00 from a native crash dump), and
# a JUnit reader rejects the whole file when one lands in it — losing every
# result to make room for one unprintable byte.
_LEGAL = (
    (0x9, 0x9),
    (0xA, 0xA),
    (0xD, 0xD),
    (0x20, 0xD7FF),
    (0xE000, 0xFFFD),
    (0x10000, 0x10FFFF),
)


def _clean(text):
    if not text:
        return ""
    return "".join(
        ch for ch in text if any(lo <= ord(ch) <= hi for lo, hi in _LEGAL)
    )


def _rel(path, root):
    """Absolute suite path -> repo-relative, for readable names in the UI."""
    try:
        rel = os.path.relpath(path, root)
    except ValueError:  # different drive on Windows
        return path
    return path if rel.startswith("..") else rel


def _classname(suite_path):
    """`integration_test/pin_and_lock_test.dart` -> `integration_test.pin_and_lock_test`.

    The CI test-result page splits a classname on `.` to build the package
    tree, so a dotted path gives one folder per test directory instead of one
    flat list of files.
    """
    stem = suite_path[:-5] if suite_path.endswith(".dart") else suite_path
    return stem.replace(os.sep, ".").replace("/", ".").strip(".")


def parse(events, root):
    """Fold the event stream into per-suite lists of finished test cases."""
    suites = {}  # suite id -> {'path': str, 'cases': [case]}
    tests = {}  # test id -> case

    for event in events:
        kind = event.get("type")

        if kind == "suite":
            suite = event["suite"]
            suites[suite["id"]] = {
                "path": _rel(suite.get("path") or "unknown", root),
                "cases": [],
            }

        elif kind == "testStart":
            test = event["test"]
            case = {
                "name": _rel(test.get("name") or "(unnamed)", root),
                "start": event.get("time", 0),
                "errors": [],
                "prints": [],
                "done": None,
            }
            tests[test["id"]] = case
            suites.setdefault(
                test.get("suiteID"), {"path": "unknown", "cases": []}
            )["cases"].append(case)

        elif kind == "error":
            case = tests.get(event.get("testID"))
            if case is not None:
                case["errors"].append(
                    {
                        "message": event.get("error") or "",
                        "stack": event.get("stackTrace") or "",
                        "is_failure": bool(event.get("isFailure")),
                    }
                )

        elif kind == "print":
            case = tests.get(event.get("testID"))
            if case is not None:
                case["prints"].append(event.get("message") or "")

        elif kind == "testDone":
            case = tests.get(event.get("testID"))
            if case is not None:
                case["done"] = event

    return suites


def _case_element(case, classname):
    """One <testcase>, or None when the case must not appear in the report."""
    done = case["done"]

    # `hidden` marks the synthetic "loading <file>" test package:test wraps every
    # suite in. Reporting the passing ones would double every file's test count,
    # but a FAILING one is a compile error or a suite that never loaded — drop
    # that and a build with zero real results looks like a build with zero
    # problems.
    if done is not None and done.get("hidden") and done.get("result") == "success":
        return None

    end = (done or {}).get("time", case["start"])
    element = ET.Element(
        "testcase",
        {
            "classname": classname,
            "name": _clean(case["name"]),
            "time": "%.3f" % (max(0, end - case["start"]) / 1000.0),
        },
    )

    if done is None:
        # No testDone: the run was killed mid-test (the stage timeout, an
        # emulator that died, a hard abort). Silently dropping it would report a
        # truncated run as a smaller, greener one.
        ET.SubElement(
            element,
            "error",
            {"message": "test did not finish — the run ended before it "
                        "reported a result"},
        ).text = _clean("\n".join(case["prints"]))
        return element

    if done.get("skipped"):
        reason = next(
            (p for p in case["prints"] if p.startswith("Skip:")), "skipped"
        )
        ET.SubElement(element, "skipped", {"message": _clean(reason)})
    elif done.get("result") != "success" or case["errors"]:
        # `error` vs `failure` is package:test's own split: isFailure marks an
        # expect() that did not match, everything else is an unexpected throw.
        tag = "failure" if all(e["is_failure"] for e in case["errors"]) else "error"
        fallback = {"message": done.get("result", "failed"), "stack": ""}
        first = case["errors"][0] if case["errors"] else fallback
        summary = (first["message"].strip().splitlines() or ["failed"])[0]
        ET.SubElement(element, tag, {"message": _clean(summary)}).text = _clean(
            "\n\n".join(e["message"] + "\n" + e["stack"] for e in case["errors"])
        )
        # Only a FAILING case carries its stdout — it is the log a triager
        # actually opens. Attaching it to every case instead would roughly
        # double a ~4100-test unit report, on every retained build, for output
        # that is already in the console log.
        if case["prints"]:
            ET.SubElement(element, "system-out").text = _clean(
                "\n".join(case["prints"])
            )

    return element


def build_xml(suites):
    root = ET.Element("testsuites")
    totals = {"tests": 0, "failures": 0, "errors": 0, "skipped": 0, "time": 0.0}

    for suite in suites.values():
        elements = [
            e
            for e in (_case_element(c, _classname(suite["path"])) for c in suite["cases"])
            if e is not None
        ]
        if not elements:
            continue
        counts = {
            "tests": len(elements),
            "failures": sum(1 for e in elements if e.find("failure") is not None),
            "errors": sum(1 for e in elements if e.find("error") is not None),
            "skipped": sum(1 for e in elements if e.find("skipped") is not None),
            "time": sum(float(e.get("time")) for e in elements),
        }
        node = ET.SubElement(
            root,
            "testsuite",
            {
                "name": suite["path"],
                "tests": str(counts["tests"]),
                "failures": str(counts["failures"]),
                "errors": str(counts["errors"]),
                "skipped": str(counts["skipped"]),
                "time": "%.3f" % counts["time"],
            },
        )
        node.extend(elements)
        for key in totals:
            totals[key] += counts[key]

    for key, value in totals.items():
        root.set(key, "%.3f" % value if key == "time" else str(value))
    return root, totals


def convert(events_path, xml_path):
    events = []
    with open(events_path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except ValueError:
                # A killed `flutter test` leaves a half-written last line. Every
                # complete event before it is still worth reporting.
                pass

    suites = parse(events, os.getcwd())
    root, totals = build_xml(suites)

    directory = os.path.dirname(os.path.abspath(xml_path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    ET.ElementTree(root).write(xml_path, encoding="utf-8", xml_declaration=True)
    return totals


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    events_path, xml_path = argv[1], argv[2]
    if not os.path.isfile(events_path):
        print(
            "junit_report: no event stream at %s — flutter test wrote none, so "
            "CI will show no per-test results for this build" % events_path,
            file=sys.stderr,
        )
        return 1

    totals = convert(events_path, xml_path)
    if totals["tests"] == 0:
        print(
            "junit_report: %s holds no completed test — writing an empty report"
            % events_path,
            file=sys.stderr,
        )
        return 1

    print(
        "junit_report: %d tests, %d failed, %d errored, %d skipped, %.1fs -> %s"
        % (
            totals["tests"],
            totals["failures"],
            totals["errors"],
            totals["skipped"],
            totals["time"],
            xml_path,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
