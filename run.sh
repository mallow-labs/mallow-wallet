#!/usr/bin/env bash
# Run the app with the local build vars compiled in.
#
#   ./run.sh                          # default device
#   ./run.sh -d <device_id>           # pick a device
#   ./run.sh --release                # any other `flutter run` flag
#   ./run.sh --dart-define=ENV=development   # devnet; default is production
#
# `.env` holds the build configuration and `.env.local` holds personal
# overrides merged on top. Both are compiled in with --dart-define-from-file.
# They are NOT bundled assets: a Flutter asset ships as readable plaintext
# inside the IPA/APK, so anyone could unzip the artifact and read every value.
#
# Your arguments are appended last, and later flags win, so anything you pass
# overrides the defaults here.
set -euo pipefail

[ -f pubspec.yaml ] || { echo "run this from the repository root" >&2; exit 1; }

# A missing --dart-define-from-file path is a hard build error ("Did not find
# the file passed to ..."), though an empty one is fine. So fail loudly on a
# missing .env, and self-heal the optional .env.local.
if [ ! -f .env ]; then
  echo ".env is missing. Create one with:" >&2
  echo "    cp .env.example .env" >&2
  echo "then read it — the Solana RPC entry is the one that matters." >&2
  exit 1
fi
[ -f .env.local ] || ( umask 077; : > .env.local )

# ENV defaults to `production` when nothing sets it, which means mainnet RPC,
# mainnet explorer links, the live rewards store, and — the one that is not
# reversible in the user's head — the sapphire_mainnet Web3Auth network, on
# which a social account derives a DIFFERENT address than on devnet. That is
# the right default for a build somebody runs to try the app, and the wrong one
# for a dev pointed at a test backend. So say so rather than guess: this script
# does not inject a value, because a devnet default here is exactly what the
# app-side default stopped doing.
if ! grep -qE '^[[:space:]]*ENV=' .env .env.local 2>/dev/null \
   && [[ "${*:-}" != *"ENV="* ]]; then
  echo "note: ENV is unset, so this build targets production (mainnet)." >&2
  echo "      For a devnet build add ENV=development to .env.local, or pass" >&2
  echo "      --dart-define=ENV=development." >&2
fi

# exec so Ctrl-C and the hot-reload keypresses reach flutter directly, and its
# exit code is ours.
exec flutter run \
  --dart-define-from-file=.env \
  --dart-define-from-file=.env.local \
  "$@"
