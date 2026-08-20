#!/usr/bin/env bash
# Boot an iOS simulator, launch the app with OBJC_PRINT_DUPLICATE_CLASSES=YES,
# and fail if the Obj-C runtime reports a duplicate class that involves the app
# bundle. Catches third-party frameworks whose class names collide with Apple
# private system frameworks (e.g. file_picker <10.3.8 vs OSAnalytics).
#
# Usage: tool/check_objc_dupes.sh
# Env:   OBJC_DUPE_WAIT            settle seconds after the first objc line (default 12)
#        OBJC_DUPE_LAUNCH_TIMEOUT  seconds to wait for that first line (default 180)
# Needs: macOS with Xcode (xcrun/simctl, lipo, PlistBuddy), a working iOS
#        simulator, flutter — and `jq`, which does NOT ship with macOS:
#        `brew install jq`. Simulator selection is three jq programs over
#        `simctl list --json`, so without it the script cannot pick a device.
#        There is no CI job for this check (headless `simctl launch` is
#        unreliable); it is a local pre-release gate — see CLAUDE.md.
#
# Toolchain notes (Xcode 26 / current simulators):
#   1. The simulator build is x86_64-only whenever a bundled pod ships no arm64
#      simulator slice (google-cast-sdk-no-bluetooth is one). iOS 26+ simulators
#      are arm64-only (no Rosetta), so an x86_64 .app cannot install there. We
#      inspect the built binary's archs and pick a pre-iOS-26 simulator when it
#      lacks arm64.
#   2. `simctl launch` no longer accepts `-e KEY VALUE`; child env must be passed
#      via SIMCTL_CHILD_* in the calling environment.
#   3. `--console` (not `--console-pty`) relays the app's stdout/stderr directly,
#      with no controlling-TTY dependency; `--console-pty` needs a real TTY and
#      silently streams nothing when stdout is a pipe (e.g. under CI/agents).
#      OBJC_PRINT_IMAGES is added as a liveness sentinel — its output is
#      guaranteed at load, so an absent `objc[` line means the launch/env
#      plumbing silently no-op'd (which would otherwise read as a false pass).
#   4. Only "implemented in both" lines that reference the app bundle
#      (Runner.app) are failures. Apple's own AuthKit/AuthKitUI duplicates are
#      present on a clean simulator and are ignored.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$REPO_ROOT/build/ios/iphonesimulator/Runner.app"
# One file, and it IS the log. `$(mktemp -t objc-dupes).log` created a temp file
# and then wrote to a *different* path, orphaning an empty file in $TMPDIR on
# every run — and the orphan was the only one `mktemp` guaranteed unique.
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/objc-dupes.XXXXXX")"
LAUNCH_WAIT_SECS="${OBJC_DUPE_WAIT:-12}"
LAUNCH_TIMEOUT_SECS="${OBJC_DUPE_LAUNCH_TIMEOUT:-180}"

UDID=""
BUNDLE_ID=""
LAUNCH_PID=""
BOOTED_BY_US=""
CREATED_BY_US=""

cleanup() {
  if [ -n "$LAUNCH_PID" ]; then
    kill "$LAUNCH_PID" 2>/dev/null || true
    wait "$LAUNCH_PID" 2>/dev/null || true
  fi
  if [ -n "$BUNDLE_ID" ] && [ -n "$UDID" ]; then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  fi
  if [ -n "$BOOTED_BY_US" ] && [ -n "$UDID" ]; then
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
  fi
  if [ -n "$CREATED_BY_US" ] && [ -n "$UDID" ]; then
    xcrun simctl delete "$UDID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

cd "$REPO_ROOT"

# Fail fast, BEFORE the multi-minute build. `jq` is the only dependency here
# that macOS does not ship: every other tool below comes with Xcode or the OS,
# so if the build succeeds they are present. Without this check the missing-jq
# abort landed at the simulator-selection step, after the whole iOS build had
# already run.
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq is required for simulator selection but is not installed."
  echo "   Install it (brew install jq) and re-run."
  exit 1
fi

echo "→ Building simulator debug .app"
flutter build ios --simulator --debug --no-codesign \
  --dart-define=ENV=development

[ -d "$APP_PATH" ] || { echo "❌ App not found at $APP_PATH"; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")
echo "→ Bundle id: $BUNDLE_ID"

# A bundled pod without arm64 simulator slices forces an x86_64-only build,
# which iOS 26+ (arm64-only) simulators cannot install. Cap the runtime major
# at 25 in that case; otherwise any runtime is fine.
APP_ARCHS=$(lipo -archs "$APP_PATH/Runner" 2>/dev/null || true)
echo "→ App binary archs: ${APP_ARCHS:-unknown}"
MAX_IOS_MAJOR=""
case " $APP_ARCHS " in
  *" arm64 "*) : ;;                 # arm64-capable → any simulator runtime works
  *) MAX_IOS_MAJOR=25 ;;            # x86_64-only → needs a pre-iOS-26 (Rosetta) sim
esac
[ -n "$MAX_IOS_MAJOR" ] && echo "→ No arm64 slice; restricting to iOS ≤ ${MAX_IOS_MAJOR} simulators"

# Pick the newest available iPhone simulator within the runtime ceiling.
UDID=$(xcrun simctl list devices available --json \
  | jq -r --arg maxmajor "$MAX_IOS_MAJOR" '
    [ .devices | to_entries[]
      | select(.key | test("iOS"))
      | (.key | capture("iOS-(?<maj>[0-9]+)-?(?<min>[0-9]+)?")) as $v
      | .value[]
      | select(.name | startswith("iPhone"))
      | { udid, name, maj: ($v.maj | tonumber), min: (($v.min // "0") | tonumber) } ]
    | (if $maxmajor == "" then . else map(select(.maj <= ($maxmajor | tonumber))) end)
    | sort_by(.maj, .min) | last | .udid // empty')

if [ -z "$UDID" ]; then
  echo "→ No suitable iPhone simulator present, creating a temporary one"
  read -r runtime device_type < <(xcrun simctl list runtimes available --json \
    | jq -r --arg maxmajor "$MAX_IOS_MAJOR" '
      [ .runtimes[]
        | select(.identifier | test("iOS"))
        | (.identifier | capture("iOS-(?<maj>[0-9]+)-?(?<min>[0-9]+)?")) as $v
        | { id: .identifier,
            maj: ($v.maj | tonumber),
            min: (($v.min // "0") | tonumber),
            dt: ([.supportedDeviceTypes[] | select(.name | startswith("iPhone"))] | last | .identifier) }
        | select(.dt != null) ]
      | (if $maxmajor == "" then . else map(select(.maj <= ($maxmajor | tonumber))) end)
      | sort_by(.maj, .min) | last
      | if . == null then "" else "\(.id) \(.dt)" end')
  [ -n "$runtime" ] && [ -n "$device_type" ] || { echo "❌ No compatible iOS runtime + iPhone device type available (need iOS ≤ ${MAX_IOS_MAJOR:-any})"; exit 1; }
  UDID=$(xcrun simctl create "objc-dupes-smoke" "$device_type" "$runtime")
  CREATED_BY_US=1
fi
echo "→ Using simulator $UDID"

state=$(xcrun simctl list devices --json \
  | jq -r --arg udid "$UDID" '[.devices[][] | select(.udid == $udid)] | .[0].state // empty')
if [ "$state" != "Booted" ]; then
  xcrun simctl boot "$UDID"
  BOOTED_BY_US=1
fi
xcrun simctl bootstatus "$UDID" -b

echo "→ Installing app"
xcrun simctl install "$UDID" "$APP_PATH"

echo "→ Launching with OBJC_PRINT_DUPLICATE_CLASSES=YES"
# Env passes through SIMCTL_CHILD_*; --console relays the app's stderr (where the
# objc runtime writes) to our log. OBJC_PRINT_IMAGES is the liveness sentinel.
SIMCTL_CHILD_OBJC_PRINT_DUPLICATE_CLASSES=YES \
SIMCTL_CHILD_OBJC_PRINT_IMAGES=YES \
  xcrun simctl launch --console \
    --terminate-running-process \
    "$UDID" "$BUNDLE_ID" > "$LOG_FILE" 2>&1 &
LAUNCH_PID=$!

# Wait for the first objc runtime line rather than sleeping a fixed interval.
# An x86_64-only build runs under Rosetta on an Apple Silicon agent, and the
# first translation of the whole framework set can take far longer than the
# settle wait — a blind sleep reads that as "no output" and fails the run.
EARLY_EXIT=""
deadline=$((SECONDS + LAUNCH_TIMEOUT_SECS))
while [ "$SECONDS" -lt "$deadline" ]; do
  grep -q "objc\[" "$LOG_FILE" && break
  # simctl exiting on its own means the launch failed or the app died; there
  # is nothing left to wait for.
  if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
    EARLY_EXIT=1
    break
  fi
  sleep 1
done

# Settle: let the remaining image loads print after the first sentinel line.
[ -n "$EARLY_EXIT" ] || sleep "$LAUNCH_WAIT_SECS"
kill "$LAUNCH_PID" 2>/dev/null || true
wait "$LAUNCH_PID" 2>/dev/null || true
LAUNCH_PID=""

# Liveness guard: without the objc runtime sentinel the launch silently no-op'd
# (wrong env plumbing, install failure, immediate crash) and any "clean" result
# below would be a false pass.
if ! grep -q "objc\[" "$LOG_FILE"; then
  echo "❌ No Obj-C runtime output captured — the app did not start under the"
  echo "   dup-class instrumentation. This is a harness failure, not a pass."
  if [ -n "$EARLY_EXIT" ]; then
    echo "   simctl exited on its own — the launch itself failed (see below)."
  else
    echo "   simctl was still running after ${LAUNCH_TIMEOUT_SECS}s. Raise"
    echo "   OBJC_DUPE_LAUNCH_TIMEOUT if the agent is slow, or check whether the"
    echo "   app's stdout/stderr is reaching us at all."
  fi
  echo "── launch log ($LOG_FILE) ──"
  cat "$LOG_FILE" || true
  echo "── end of launch log ──"
  exit 1
fi

# Only app-bundle collisions matter. Apple's own system-framework duplicates
# (e.g. AuthKit vs AuthKitUI) appear on a clean simulator and are not our bug.
if grep -F "is implemented in both" "$LOG_FILE" | grep -F "Runner.app"; then
  echo
  echo "❌ Obj-C duplicate class detected — a bundled framework defines a class"
  echo "   name that collides with an Apple private framework. This is the"
  echo "   exact pattern that crashes on real devices (e.g. file_picker <10.3.8)."
  echo "   Full launch log: $LOG_FILE"
  exit 1
fi

echo "✓ No app-bundle Obj-C duplicate-class warnings"
