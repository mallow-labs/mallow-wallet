#!/usr/bin/env bash
#
# Every build variable the app reads must be documented in .env.example.
#
# ENV escaped documentation entirely: it selected the Solana cluster AND the
# Web3Auth network that social key derivation depends on, and .env.example never
# named it, so a fork that filled in every documented key still shipped a
# permanently-devnet build. Nothing errored — devnet answers are well formed.
#
# 🛑 The match spans a line break on purpose. Two calls in this repo wrap:
#
#     const bool.fromEnvironment(
#       'SHOW_UNRELEASED',
#
# A one-line regex misses both, which is the same blindness that let ENV
# through. A gate that reproduces the bug it exists to catch is worse than no
# gate, because its green result is evidence of nothing.
#
# Same argument, one level down: the whitespace is `[[:space:]]` and not `\s`.
# POSIX leaves a backslash before an ordinary character undefined in an ERE,
# so `\s` is a GNU extension that a BSD grep — the one macOS ships, so any
# contributor or CI job on a Mac — is free to read as a literal `s`. Under that
# reading the wrapped calls stop matching, `missing` stays 0, and the gate
# prints OK. It fails open, so the portable spelling is the only one whose
# green is worth anything.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

EXAMPLE=".env.example"
[ -f "$EXAMPLE" ] || { echo "ERROR: $EXAMPLE is missing" >&2; exit 1; }

# Test-only knobs. These are set by the harness, never by a deployment, so a
# .env.example entry would tell a fork to configure something that is none of
# their business. Anything added here needs a reason on the same line.
EXEMPT=(
  E2E_DISABLE_GL   # e2e only: disables the GL onboarding ring on emulators
  SHOW_UNRELEASED  # local dev only: reveals unreleased surfaces
)

# The extraction runs before the loop so its exit status is checked: inside
# `< <(...)` nothing looks at it, so a grep that dies — bad flag, future
# toolchain — would feed the loop zero lines and the gate would print OK over
# a scan that never ran. `|| scan_status=$?` instead of `|| true`, as in
# check_sensitive_debug_print.sh: grep exits 1 for "no matches" (then nothing
# is read and nothing can be undocumented), 2 and up for "the scan did not
# run", and only the latter may kill the gate.
scan_status=0
extracted=$(
  grep -rzoE "fromEnvironment\([[:space:]]*'[A-Z_0-9]+'" lib/ packages/ --include='*.dart' \
    | tr -d '\0'
) || scan_status=$?
if [ "$scan_status" -gt 1 ]; then
  echo "ERROR: variable extraction failed (grep exit $scan_status) — the gate did not run." >&2
  exit 2
fi
vars=$(printf '%s' "$extracted" | grep -oE "'[A-Z_0-9]+'" | tr -d "'" | sort -u) || true

missing=0
while IFS= read -r var; do
  [ -n "$var" ] || continue
  for e in "${EXEMPT[@]}"; do [ "$var" = "$e" ] && continue 2; done
  grep -qE "^[#[:space:]]*${var}=" "$EXAMPLE" || {
    echo "UNDOCUMENTED in $EXAMPLE: $var" >&2
    missing=$((missing + 1))
  }
done <<< "$vars"

if [ "$missing" -gt 0 ]; then
  echo "" >&2
  echo "$missing build variable(s) are read by the app and documented nowhere." >&2
  echo "Add each to $EXAMPLE, or exempt it in this script WITH a reason." >&2
  exit 1
fi
echo "OK: every build variable the app reads is documented in $EXAMPLE."
