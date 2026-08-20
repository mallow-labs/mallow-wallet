#!/usr/bin/env bash
# lib.sh — shared plumbing for the local E2E runners (run_e2e.sh, run_one.sh).
#
# Not executable on its own; source it:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Everything host-specific lives here so the two runners cannot drift apart.
# The --dart-define set is NOT here: it lives in test/e2e/dart_defines.sh,
# so every runner resolves the same set.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
# Gradle needs a full JDK with javac; the default java-21 here is a JRE only.
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export PATH="$JAVA_HOME/bin:$PATH"

ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
EMULATOR="$ANDROID_SDK_ROOT/emulator/emulator"
AVD="${E2E_AVD:-e2e_pixel}"
DEVICE="${E2E_DEVICE:-emulator-5554}"
# EXPORTED, because mock_backend.py reads MOCK_PORT from the environment and
# falls back to its own 8091 default. Unexported, changing the default here
# moved the harness (and the --dart-define URLs) to the new port while the
# python kept binding 8091, and every request in the run went nowhere.
export MOCK_PORT="${MOCK_PORT:-8091}"
APP_ID="com.mallow.wallet.android"

# Sets E2E_DART_DEFINES from $MOCK_PORT. Single owner.
# shellcheck source=test/e2e/dart_defines.sh
. "$(dirname "${BASH_SOURCE[0]}")/dart_defines.sh"

# One emulator, one Gradle build dir. Concurrent runs must serialise or they
# corrupt each other's build and fight over the device — so every runner takes
# this lock for its whole `flutter test` invocation and callers just block.
E2E_LOCKFILE="${E2E_LOCKFILE:-/tmp/mallow-e2e.lock}"

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_DIR="${E2E_RUN_DIR:-/tmp/mallow-e2e}"
mkdir -p "$RUN_DIR"
MOCK_LOG="$RUN_DIR/mock-$RUN_ID.log"
EMULATOR_LOG="$RUN_DIR/emulator-$RUN_ID.log"

MOCK_PID=""
E2E_TEST_PID=""

e2e::cleanup() {
  # Kill the test child FIRST. It inherits this shell's lock fd, so an orphaned
  # `flutter test` keeps the shared lock held for its full timeout -- while
  # talking to a mock backend this same trap has just killed. That combination
  # blocks every queued runner behind a run that can no longer pass.
  if [[ -n "$E2E_TEST_PID" ]]; then
    kill "$E2E_TEST_PID" 2>/dev/null || true
    wait "$E2E_TEST_PID" 2>/dev/null || true
  fi
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null || true
}

# Blocks until no other runner holds the lock, then keeps it for the rest of
# this process. `flock -x 9` on a dedicated fd, not a subshell, so the lock
# covers the emulator boot and the Gradle build too, not just `flutter test`.
e2e::take_lock() {
  exec 9>"$E2E_LOCKFILE"
  if ! flock -n 9; then
    echo "==> Waiting for another E2E run to finish (lock: $E2E_LOCKFILE)"
    flock 9
  fi
  echo "==> Holding E2E lock ($E2E_LOCKFILE)"
}

e2e::boot_emulator() {
  # Start the adb fork-server with the lock fd CLOSED, before any other adb
  # call can spawn it. It daemonises and outlives this runner, so if it
  # inherits fd 9 it holds the exclusive flock for as long as it lives -- and
  # the next runner then blocks at e2e::take_lock forever, with no failure
  # message, on a lock whose owner exited hours ago.
  "$ADB" start-server >/dev/null 2>&1 9>&- || true

  if "$ADB" devices | grep -q "emulator-.*device$"; then
    echo "==> Emulator ready: $("$ADB" devices | grep emulator | head -1)"
    return
  fi
  echo "==> Booting emulator $AVD (headless), log: $EMULATOR_LOG"
  # 4 GB RAM keeps the software-GL renderer stable on image-heavy screens.
  rm -f "$HOME/.android/avd/$AVD.avd/"*.lock 2>/dev/null || true
  # 9>&- for the same reason as the adb server above, and it matters more here:
  # the emulator is deliberately LEFT RUNNING for the next run to reuse, so an
  # inherited lock fd is never released by anything short of a reboot.
  nohup "$EMULATOR" -avd "$AVD" -no-window -no-audio -no-boot-anim \
    -gpu swiftshader_indirect -no-snapshot -memory 4096 -cores 4 -accel on \
    >"$EMULATOR_LOG" 2>&1 9>&- &
  "$ADB" wait-for-device
  echo "==> Waiting for boot to complete"
  for _ in $(seq 1 60); do
    [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] && break
    sleep 3
  done
  [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] || {
    echo "!! emulator failed to boot within timeout"; tail -40 "$EMULATOR_LOG"; exit 1;
  }
  echo "==> Emulator ready: $("$ADB" devices | grep emulator | head -1)"
}

# Always a FRESH mock: a stale one from an aborted run still holds $MOCK_PORT
# and still carries whatever scenario/fault that run armed, so a new run would
# quietly inherit it.
e2e::start_mock() {
  # -sTCP:LISTEN is load-bearing: without it `lsof -i tcp:$MOCK_PORT` also matches
  # every CLIENT socket on that port -- including the emulator's own host-side
  # connections to the mock -- and the kill -9 below takes the emulator down
  # with it.
  if command -v lsof >/dev/null 2>&1; then
    local stale
    stale="$(lsof -t -sTCP:LISTEN -i "tcp:$MOCK_PORT" 2>/dev/null || true)"
    if [[ -n "$stale" ]]; then
      echo "==> Killing stale listener on :$MOCK_PORT ($stale)"
      # shellcheck disable=SC2086
      kill -9 $stale 2>/dev/null || true
      sleep 0.5
    fi
  else
    echo "!! lsof is not installed -- cannot clear a stale mock on :$MOCK_PORT." >&2
    echo "!! A leftover server would answer the health check below and this run" >&2
    echo "!! would inherit the previous run's scenario/fault state. Install it" >&2
    echo "!! (apt install lsof). The PID check below is the only net left." >&2
  fi
  echo "==> Starting mock backend on :$MOCK_PORT, log: $MOCK_LOG"
  python3 test/e2e/mock_backend.py >"$MOCK_LOG" 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 20); do
    curl -sf -o /dev/null "http://127.0.0.1:$MOCK_PORT/v2/health" && break
    sleep 0.5
  done
  curl -sf -o /dev/null "http://127.0.0.1:$MOCK_PORT/v2/health" || {
    echo "!! mock backend did not come up"; cat "$MOCK_LOG"; exit 1;
  }
  # The probe proves SOMETHING answers on :$MOCK_PORT -- not that it is OURS.
  # mock_backend.py dies on EADDRINUSE, so a stale server we failed to kill
  # answers the health check happily while our own python is already gone, and
  # the run then silently inherits that run's scenario and faults.
  local owner=""
  if command -v lsof >/dev/null 2>&1; then
    # Ask who actually holds the port. This is exact and race-free; a bare
    # `kill -0 $MOCK_PID` is NOT -- the probe is answered by the stale server
    # within milliseconds, while our doomed python is still in startup and
    # therefore still very much alive. (Measured: kill -0 alone passes here.)
    owner="$(lsof -t -sTCP:LISTEN -i "tcp:$MOCK_PORT" 2>/dev/null | tr '\n' ' ')" || true
  else
    # No lsof: we cannot ask WHO listens, only whether our own python survived,
    # and only after giving it time to lose the bind race.
    sleep 1
    if kill -0 "$MOCK_PID" 2>/dev/null; then owner="$MOCK_PID"; fi
  fi
  case " $owner " in
    *" $MOCK_PID "*) : ;;
    *)
      echo "!! :$MOCK_PORT is answering, but NOT from our mock (pid $MOCK_PID;" >&2
      echo "!! listener: ${owner:-none}). A stale server from an earlier run took" >&2
      echo "!! the health check -- refusing to run against its scenario/faults." >&2
      tail -n 40 "$MOCK_LOG" >&2
      exit 1
      ;;
  esac
}

# Puts the committed Firebase placeholder in place when the real file is absent.
#
# android/app/build.gradle.kts applies com.google.gms.google-services, which
# fails the Gradle build outright when android/app/google-services.json is
# missing -- and that file is gitignored. So on a fresh clone the README's
# Quick start died in Gradle before a single test ran. The public CI workflow
# already stages the same file; doing it here too is what makes the two agree.
#
# ONLY when absent. A real google-services.json belongs to whoever put it there
# and points at a real Firebase project; overwriting it would silently change
# what their next non-E2E build talks to.
e2e::stage_firebase_placeholder() {
  local target="android/app/google-services.json"
  if [[ -f "$target" ]]; then return 0; fi

  # Every location the placeholder is known to live. The loop below takes the
  # first that is actually on disk, so this works without knowing which
  # checkout it is running in.
  local candidates=("test/e2e/google-services.placeholder.json")
  local placeholder="" candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then placeholder="$candidate"; break; fi
  done
  if [[ -z "$placeholder" ]]; then
    echo "!! google-services.placeholder.json not found -- the Gradle build" >&2
    echo "!! needs a google-services.json and this is the committed stand-in." >&2
    exit 1
  fi
  echo "==> Staging Firebase placeholder -> $target"
  cp "$placeholder" "$target"
}

# Uninstalls the app so the next run starts from a genuine fresh install (no
# secure storage, no prefs, no sqlite file). LOCAL ONLY: a directory run does
# `flutter test integration_test/` as one shell line with no between-file hook,
# which is exactly why `resetAppState()` exists as the in-process substitute.
e2e::uninstall_app() {
  echo "==> Uninstalling $APP_ID"
  "$ADB" uninstall "$APP_ID" >/dev/null 2>&1 || true
}

# Runs one target with the shared define set (E2E_DART_DEFINES, sourced from
# test/e2e/dart_defines.sh above -- edit the defines THERE, not here).
e2e::run_flutter_test() {
  local target="$1"
  # Staged here rather than in each runner: this function is the only place
  # either runner builds the APK, so both get it without having to remember.
  e2e::stage_firebase_placeholder
  echo "==> Running $target"
  # Route TERM/INT through the EXIT trap so a killed runner (a tool timeout
  # will do it) tears down its child instead of orphaning it. Registered here,
  # next to the only long-running child, so both runners get it without each
  # having to remember. Cleans up on any exit path.
  trap 'exit 143' TERM
  trap 'exit 130' INT
  # 9>&- keeps the shared lock fd out of the child: even if this shell dies
  # abruptly, the lock releases when its own fd closes rather than staying
  # pinned by a surviving `flutter test`.
  # E2E_EXTRA_FLAGS lets a caller narrow the scope -- above all with
  # `--exclude-tags nightly`, which is the smoke subset an internal CI job runs
  # inside its 45-minute budget. It is EMPTY by default, so a plain
  # `run_e2e.sh` runs every flow in the directory, nightly-tagged cases
  # included. Both it and E2E_DART_DEFINES are unquoted on purpose: they are
  # flag lists, not single arguments.
  # shellcheck disable=SC2086
  flutter test "$target" ${E2E_EXTRA_FLAGS:-} \
    -d "$DEVICE" \
    $E2E_DART_DEFINES 9>&- &
  E2E_TEST_PID=$!
  wait "$E2E_TEST_PID"
}

# mock.log lines are the fastest triage tool in the suite: every request is
# logged with its path, so an unexpected empty DEFAULTS response is visible
# without re-running anything.
e2e::dump_mock_log() {
  echo
  echo "==================== mock.log (last ${1:-60} lines) ===================="
  tail -n "${1:-60}" "$MOCK_LOG" 2>/dev/null || echo "(no mock log at $MOCK_LOG)"
  echo "======================================================================="
  echo "full log: $MOCK_LOG"
}
