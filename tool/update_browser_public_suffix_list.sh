#!/usr/bin/env bash
set -euo pipefail

target="$(cd "$(dirname "$0")/.." && pwd)/assets/data/public_suffix_list.dat"
temporary="$(mktemp)"
trap 'rm -f "$temporary"' EXIT

curl --fail --location --silent --show-error \
  https://publicsuffix.org/list/public_suffix_list.dat -o "$temporary"
grep -q '^// ===BEGIN ICANN DOMAINS===' "$temporary"
grep -q '^// ===BEGIN PRIVATE DOMAINS===' "$temporary"
mv "$temporary" "$target"
