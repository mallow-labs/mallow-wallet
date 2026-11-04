#!/usr/bin/env python3
"""Run the browser bridge fixture with real Android touches.

Usage: python3 tool/test_browser_native_popups.py emulator-5554
Requires flutter and adb on PATH. Uses only synthetic fixture pages.
ADB can override the adb path; BROWSER_TEST_SCREENSHOT optionally captures each
pre-tap screen to the supplied PNG path for failure diagnosis.
"""

import os
from pathlib import Path
import re
import subprocess
import sys


def main():
    if len(sys.argv) != 2:
        sys.exit("Usage: test_browser_native_popups.py <android-device-id>")
    device = sys.argv[1]
    # Emulators only. Teardown of `flutter test integration_test/` force-stops
    # and UNINSTALLS the app, on Ctrl-C too. On a real phone that deletes its
    # wallet keys for good (allowBackup=false, nothing to restore from), so a
    # physical serial is refused, as test/e2e/lib.sh refuses it.
    if not re.fullmatch(r"emulator-\d+", device):
        sys.exit(
            f"{device} is not an emulator serial (emulator-<port>). This test "
            "uninstalls the app on teardown, which would wipe a real device's "
            "wallets. Point it at an emulator."
        )
    adb = os.environ.get("ADB", "adb")
    subprocess.run([adb, "-s", device, "get-state"], check=True)
    command = [
        "flutter", "test", "integration_test/browser_bridge_provenance_test.dart",
        "--flavor", "play", "-d", device, "--reporter", "expanded",
        "--dart-define=BROWSER_NATIVE_POPUP_INPUT=true",
    ]
    root = Path(__file__).resolve().parent.parent
    process = subprocess.Popen(
        command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1,
    )
    taps = 0
    try:
        for line in process.stdout:
            print(line, end="", flush=True)
            match = re.search(r"BROWSER_NATIVE_TAP (\d+) (\d+)", line)
            if match:
                if os.environ.get("BROWSER_TEST_SCREENSHOT"):
                    with open(os.environ["BROWSER_TEST_SCREENSHOT"], "wb") as shot:
                        subprocess.run(
                            [adb, "-s", device, "exec-out", "screencap", "-p"],
                            stdout=shot, check=True, timeout=10,
                        )
                subprocess.run(
                    [adb, "-s", device, "shell", "input", "tap", *match.groups()],
                    check=True, timeout=10,
                )
                taps += 1
        status = process.wait()
        if status == 0 and taps != 3:
            sys.exit(f"Expected three native touches; delivered {taps}")
        return status
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    sys.exit(main())
