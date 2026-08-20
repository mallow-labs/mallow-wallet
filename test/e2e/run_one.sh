#!/usr/bin/env bash
# run_one.sh — serialized single-file E2E runner.
#
# Runs exactly ONE integration_test file against the sandboxed mock backend on
# the local headless emulator. Use it while developing a flow; use run_e2e.sh
# to run the whole directory.
#
# A host has one emulator and one shared Gradle build dir, so the whole
# invocation is wrapped in an exclusive flock. Several runs can start at once:
# they queue instead of corrupting each other's build. Just wait.
#
# Usage:
#   test/e2e/run_one.sh integration_test/onboarding_create_wallet_test.dart
#   test/e2e/run_one.sh --uninstall integration_test/settings_test.dart
#
# Flags:
#   --uninstall   `adb uninstall` before the run, for a genuine fresh-install
#                 case. LOCAL ONLY — a whole-directory run has no between-file hook, which is why
#                 the in-process `resetAppState()` exists.
#
# On failure it prints the tail of this run's mock.log, which is the fastest
# way to see what the app actually asked for.

UNINSTALL=false
TEST_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) TEST_FILE="$1"; shift ;;
  esac
done

# shellcheck source=test/e2e/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if [[ -z "$TEST_FILE" ]]; then
  echo "usage: test/e2e/run_one.sh [--uninstall] <integration_test/some_test.dart>" >&2
  exit 2
fi
if [[ ! -f "$TEST_FILE" ]]; then
  echo "!! no such test file: $TEST_FILE" >&2
  exit 2
fi

trap e2e::cleanup EXIT

e2e::take_lock
e2e::boot_emulator
if $UNINSTALL; then e2e::uninstall_app; fi
e2e::start_mock

if e2e::run_flutter_test "$TEST_FILE"; then
  echo "==> PASS  $TEST_FILE   (mock log: $MOCK_LOG)"
else
  status=$?
  echo "==> FAIL  $TEST_FILE"
  e2e::dump_mock_log 80
  exit "$status"
fi
