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

# Android has had no flavourless variant since the store split, so a build with
# no --flavor is a trap. Gradle's assembleDebug writes app-play-debug.apk and
# app-dappstore-debug.apk and never app-debug.apk — which is the only name
# `flutter run` looks for when no flavour is given. The build still succeeds, so
# flutter picks up whatever stale app-debug.apk is left in
# build/app/outputs/flutter-apk/ and installs THAT. A debug APK carries
# libflutter.so for the target device's ABI alone, so a leftover emulator build
# lands on a phone and dies at launch on a missing arm64 library, pointing at
# nothing that looks like the real cause.
#
# iOS is the opposite: one Runner scheme, no flavours, and --flavor is an error
# there. So resolve the target device and default the flavour only when every
# device flutter could pick is an Android one.
flavor_given=false
device_selector=""
want_device=false
for arg in "$@"; do
  if $want_device; then device_selector="$arg"; want_device=false; continue; fi
  case "$arg" in
    --flavor|--flavor=*) flavor_given=true ;;
    -d|--device-id) want_device=true ;;
    --device-id=*) device_selector="${arg#--device-id=}" ;;
    -d?*) device_selector="${arg#-d}" ;;
  esac
done

if ! $flavor_given; then
  # Mirrors flutter's own -d resolution (see getDevicesById): a case-insensitive
  # exact hit on id or name wins outright, otherwise every prefix hit competes.
  # An empty selector means flutter chooses among all supported devices.
  target_is_android=$(flutter devices --machine 2>/dev/null | awk -v sel="$device_selector" '
    function val(s) { sub(/^[^:]*: *"/, "", s); sub(/".*$/, "", s); return s }
    BEGIN { sel = tolower(sel); n = 0 }
    /^  \{/               { id = ""; nm = ""; plat = ""; sup = "false"; next }
    /^ *"id": /           { id = val($0); next }
    /^ *"name": /         { nm = val($0); next }
    /^ *"targetPlatform":/{ plat = val($0); next }
    /^ *"isSupported": /  { sup = ($0 ~ /true/) ? "true" : "false"; next }
    /^  \}/ {
      if (sup == "true" && id != "") { ids[n] = tolower(id); nms[n] = tolower(nm); plats[n] = plat; n++ }
      next
    }
    END {
      cnt = 0
      if (sel == "") {
        for (i = 0; i < n; i++) pick[cnt++] = i
      } else {
        for (i = 0; i < n; i++) if (ids[i] == sel || nms[i] == sel) pick[cnt++] = i
        if (cnt == 0)
          for (i = 0; i < n; i++) if (index(ids[i], sel) == 1 || index(nms[i], sel) == 1) pick[cnt++] = i
      }
      if (cnt == 0) exit
      for (j = 0; j < cnt; j++) if (plats[pick[j]] !~ /^android-/) exit
      print "android"
    }
  ') || target_is_android=""

  if [ "$target_is_android" = "android" ]; then
    echo "note: Android target, so defaulting to --flavor play." >&2
    echo "      Pass --flavor dappstore for the Solana dApp Store build." >&2
    set -- --flavor play "$@"
  fi
fi

# exec so Ctrl-C and the hot-reload keypresses reach flutter directly, and its
# exit code is ours.
exec flutter run \
  --dart-define-from-file=.env \
  --dart-define-from-file=.env.local \
  "$@"
