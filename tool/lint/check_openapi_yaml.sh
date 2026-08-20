#!/usr/bin/env bash
#
# The vendored OpenAPI spec must parse, and must not carry a latent colon.
#
# A description containing a colon-space in an unquoted YAML scalar makes the
# whole 9.4k-line document unparseable. swagger_dart_code_generator then no-ops,
# packages/mallow_api emits ZERO models, every type it exports resolves to
# `dynamic`, and the build dies on unrelated switch statements 8.7M log lines
# from the cause. That shipped: a prose scrub rewrote one description as
# "opaque to this contract: the client treats..." and took the whole app down.
#
# The generator upstream now force-quotes any scalar containing a colon. This is
# the downstream half — the vendored copy is what this repo actually compiles,
# so it is what has to be checked here.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
SPEC="packages/mallow_api/openapi/openapi.yaml"
[ -f "$SPEC" ] || { echo "ERROR: $SPEC is missing" >&2; exit 1; }

python3 - "$SPEC" <<'PY'
import re, sys, yaml

path = sys.argv[1]
raw = open(path, encoding="utf-8").read()

try:
    doc = yaml.safe_load(raw)
except yaml.YAMLError as e:
    print(f"FAIL: {path} does not parse as YAML.\n{e}", file=sys.stderr)
    print("\nA colon-space in an unquoted description is the usual cause. It emits "
          "zero Dart models and fails later as an unrelated compile error.", file=sys.stderr)
    raise SystemExit(1)

if not doc or "paths" not in doc:
    print(f"FAIL: {path} parsed but declares no paths.", file=sys.stderr)
    raise SystemExit(1)

# A plain (unquoted, non-block) scalar carrying a colon survives only while no
# space follows it. Any wording edit that inserts one breaks the document, so
# the latent case fails here rather than at some future author's expense.
latent = []
for n, line in enumerate(raw.splitlines(), 1):
    m = re.match(r'^\s*(?:- )?[\w.$-]+:\s+(?![|>&*#\'"])(.+?)\s*$', line)
    if m and ":" in m.group(1):
        latent.append((n, m.group(1)[:100]))

if latent:
    print(f"FAIL: {len(latent)} unquoted scalar(s) carry a colon in {path}:", file=sys.stderr)
    for n, text in latent[:10]:
        print(f"  {path}:{n}: {text}", file=sys.stderr)
    print("\nQuote them, or re-word with an em-dash. One added space after any of "
          "these colons makes the whole document unparseable.", file=sys.stderr)
    raise SystemExit(1)

print(f"OK: {path} parses ({len(doc['paths'])} paths), no latent colon scalars.")
PY
