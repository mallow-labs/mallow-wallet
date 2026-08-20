#!/usr/bin/env bash
# Guard against `debugPrint` regressions in security-sensitive modules.
#
# `debugPrint` is NOT stripped in release — it still reaches platform logs
# (logcat / OSLog). A hardening pass moved every wallet/auth/secret log
# site to `AppLogger`, which drops non-error events in release. This
# guard ensures no one reintroduces a bare `debugPrint` in these paths.
#
# It is a STRUCTURAL ban, not a content scan: any `debugPrint` in the paths
# below fails, whatever it prints. It says nothing about `debugPrint`
# anywhere else in the tree.
#
# To intentionally allow a `debugPrint` (e.g. a release-safe error path
# that genuinely cannot use AppLogger), add `// ignore: app_logger_only`
# on the same line.
#
# Comment-only lines are exempt. The guarded files explain this very rule in
# prose (`social_auth_service.dart` names `debugPrint` in a doc comment to say
# why its `toString` is hand-written), and a ban that fires on its own
# documentation trains people to delete the documentation.

set -euo pipefail

# Every path below is repo-relative. Resolve them against the repo root rather
# than the caller's CWD — run from a subdirectory, this script would otherwise
# scan nothing and report OK.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PATHS=(
  "lib/core/crypto"
  "lib/core/security"
  "lib/core/network/auth_service.dart"
  # Holds the Web3Auth secp256k1 key that backs BOTH the Ethereum and the
  # Tezos address, plus the hand-redacted `_SocialKeys.toString`.
  "lib/core/services/social_auth_service.dart"
)

# Preflight: every guarded path must exist.
#
# 🛑 This is the whole reason the guard can be trusted. `grep` exits 2 for a
# missing path, and the old `2>/dev/null || true` pair swallowed both the
# message and the status — so renaming a guarded directory (an ordinary
# refactor) left this script printing OK forever while guarding nothing.
# Plain string accumulation, not an array: macOS still ships bash 3.2, where
# `${#arr[@]}` on an empty array trips `set -u`.
missing=""
for path in "${PATHS[@]}"; do
  [ -e "$path" ] || missing="$missing  $path
"
done
if [[ -n "$missing" ]]; then
  echo 'ERROR: guarded path(s) do not exist — this guard is guarding nothing.' >&2
  echo 'Fix PATHS in tool/lint/check_sensitive_debug_print.sh, or restore them:' >&2
  echo '' >&2
  printf '%s' "$missing" >&2
  exit 1
fi

# `|| scan_status=$?` instead of `|| true`: grep exits 1 for "no matches" (the
# passing case) and >1 for a real failure. Only those two answers are usable.
scan_status=0
raw=$(grep -rn --include='*.dart' -E '\bdebugPrint\b' "${PATHS[@]}") || scan_status=$?
if [[ "$scan_status" -gt 1 ]]; then
  echo "ERROR: grep failed (exit $scan_status) — the scan did not run." >&2
  exit 1
fi

# Second filter drops comment-only lines. Anchored at the `path:line:` prefix
# grep -n emits, so a `//` inside real code cannot smuggle a call site past it.
violations=$(printf '%s\n' "$raw" \
  | grep -v 'ignore: app_logger_only' \
  | grep -vE '^[^:]*:[0-9]+:[[:space:]]*(//|\*)' \
  || true)

if [[ -n "$violations" ]]; then
  echo 'ERROR: bare `debugPrint` found in security-sensitive modules.' >&2
  echo 'Use AppLogger (lib/core/observability/app_logger.dart) instead.' >&2
  echo '' >&2
  echo "$violations" >&2
  exit 1
fi

echo "OK: no bare debugPrint in ${#PATHS[@]} security-sensitive paths."
