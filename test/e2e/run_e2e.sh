#!/usr/bin/env bash
# run_e2e.sh — full-suite E2E runner, the whole suite, end to end.
#
# Boots a headless Android emulator (if not already running), starts a fresh
# sandboxed mock backend, and runs the whole integration_test suite against
# them with the app pointed at the mock via --dart-define. Everything is local
# and offline: no Firebase, no real backend, no chain.
#
# A CI job would do the same, plus the toolchain provisioning: one
# `flutter test integration_test/` over the whole directory.
#
# That does NOT amortise the build across the directory. flutter_tools re-runs
# `assembleDebug`, uninstalls, reinstalls and cold-boots the app for EVERY
# file -- measured at ~34 s of pure overhead per file, against 2-13 s of test
# work. Bundling many cases into few files is what keeps a whole-suite run
# affordable; see rule 1 in test/e2e/README.md.
#
# Usage:
#   test/e2e/run_e2e.sh                 # whole integration_test/ directory
#   test/e2e/run_e2e.sh <test-file>     # one file (prefer run_one.sh)
#
# For iterating on a single flow use test/e2e/run_one.sh — same lock, same
# defines, plus an --uninstall hook and mock-log triage on failure.

# shellcheck source=test/e2e/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TARGET="${1:-integration_test/}"

trap e2e::cleanup EXIT

# One emulator and one Gradle build dir per host — serialise with the same
# lock run_one.sh takes, so a concurrent run queues instead of colliding.
e2e::take_lock
e2e::boot_emulator
e2e::start_mock

if e2e::run_flutter_test "$TARGET"; then
  echo "==> PASS  $TARGET   (mock log: $MOCK_LOG)"
else
  status=$?
  echo "==> FAIL  $TARGET"
  e2e::dump_mock_log 80
  exit "$status"
fi
