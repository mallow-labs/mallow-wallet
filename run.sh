#!/usr/bin/env bash
# Run the app with the local build vars compiled in.
#
#   ./run.sh                          # default device
#   ./run.sh -d <device_id>           # pick a device
#   ./run.sh --release                # any other `flutter run` flag
#   ./run.sh --dart-define=ENV=development   # devnet; default is production
#   ./run.sh --allow-uninstall        # skip the Android install guard (below)
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
#
# --allow-uninstall is ours, not flutter's, so it is stripped here; see the
# install guard below.
flavor=""
device_selector=""
build_mode=debug
build_number=""
allow_uninstall=false
want=""
args=()
for arg in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      device) device_selector="$arg" ;;
      flavor) flavor="$arg" ;;
      build_number) build_number="$arg" ;;
    esac
    want=""
    args+=("$arg")
    continue
  fi
  case "$arg" in
    --allow-uninstall) allow_uninstall=true; continue ;;
    --flavor) want=flavor ;;
    --flavor=*) flavor="${arg#--flavor=}" ;;
    -d|--device-id) want=device ;;
    --device-id=*) device_selector="${arg#--device-id=}" ;;
    -d?*) device_selector="${arg#-d}" ;;
    --release) build_mode=release ;;
    --profile) build_mode=profile ;;
    --debug) build_mode=debug ;;
    --build-number) want=build_number ;;
    --build-number=*) build_number="${arg#--build-number=}" ;;
  esac
  args+=("$arg")
done
# The `+` form keeps an empty array from tripping `set -u` on bash 3.2 (macOS).
set -- ${args[@]+"${args[@]}"}

find_adb() {
  if command -v adb >/dev/null 2>&1; then command -v adb; return; fi
  local sdk
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
             "$(sed -n 's/^sdk\.dir=//p' android/local.properties 2>/dev/null)"; do
    if [ -n "$sdk" ] && [ -x "$sdk/platform-tools/adb" ]; then
      echo "$sdk/platform-tools/adb"
      return
    fi
  done
  return 1
}

# One "<targetPlatform><TAB><id>" line per device flutter could pick.
#
# Mirrors flutter's own -d resolution (see getDevicesById): a case-insensitive
# exact hit on id or name wins outright, otherwise every prefix hit competes.
# An empty selector means flutter chooses among all supported devices, and
# `all` is flutter's keyword for every one of them at once.
candidates=$(flutter devices --machine 2>/dev/null | awk -v sel="$device_selector" '
  function val(s) { sub(/^[^:]*: *"/, "", s); sub(/".*$/, "", s); return s }
  BEGIN { sel = tolower(sel); n = 0 }
  /^  \{/               { id = ""; nm = ""; plat = ""; sup = "false"; next }
  /^ *"id": /           { id = val($0); next }
  /^ *"name": /         { nm = val($0); next }
  /^ *"targetPlatform":/{ plat = val($0); next }
  /^ *"isSupported": /  { sup = ($0 ~ /true/) ? "true" : "false"; next }
  /^  \}/ {
    if (sup == "true" && id != "") { ids[n] = id; nms[n] = tolower(nm); plats[n] = plat; n++ }
    next
  }
  END {
    cnt = 0
    if (sel == "" || sel == "all") {
      for (i = 0; i < n; i++) pick[cnt++] = i
    } else {
      for (i = 0; i < n; i++) if (tolower(ids[i]) == sel || nms[i] == sel) pick[cnt++] = i
      if (cnt == 0)
        for (i = 0; i < n; i++) if (index(tolower(ids[i]), sel) == 1 || index(nms[i], sel) == 1) pick[cnt++] = i
    }
    for (j = 0; j < cnt; j++) print plats[pick[j]] "\t" ids[pick[j]]
  }
') || candidates=""
android_ids=$(awk -F'\t' '$1 ~ /^android-/ { print $2 }' <<<"$candidates")
other_count=$(awk -F'\t' 'NF && $1 !~ /^android-/' <<<"$candidates" | wc -l | tr -d ' ')

# Cross-check against adb. The awk above reads flutter's pretty-printed JSON by
# its layout, and a failed `flutter devices` prints nothing, so either would
# report no Android target while a phone is attached, and the install guard
# below would skip it. So every serial adb sees that flutter could pick, and
# the list above missed, is added back. adb knows serials, not names: a prefix
# hit counts only when flutter resolved the selector to nothing at all.
selector_lc=$(printf '%s' "$device_selector" | tr '[:upper:]' '[:lower:]')
if adb_bin=$(find_adb); then
  adb_ids=$("$adb_bin" devices </dev/null 2>/dev/null |
              awk 'NR > 1 && $2 == "device" { print $1 }') || adb_ids=""
  while IFS= read -r serial; do
    [ -n "$serial" ] || continue
    serial_lc=$(printf '%s' "$serial" | tr '[:upper:]' '[:lower:]')
    case "$selector_lc" in
      ""|all) ;;
      "$serial_lc") ;;
      *)
        [ -z "$candidates" ] || continue
        case "$serial_lc" in "$selector_lc"*) ;; *) continue ;; esac
        ;;
    esac
    if ! grep -qxF -- "$serial" <<<"$android_ids"; then
      echo "note: adb sees $serial, which flutter did not list. Checking it too." >&2
      android_ids=$(printf '%s\n%s' "$android_ids" "$serial" | sed '/^$/d')
    fi
  done <<<"$adb_ids"
fi

# A -d that matches nothing leaves no device to check, which reads the same as
# "no Android target". Refuse rather than let flutter resolve it its own way.
if [ -n "$device_selector" ] && [ -z "$android_ids" ] && [ "$other_count" = 0 ] \
   && ! $allow_uninstall; then
  echo "error: -d $device_selector matched no device that flutter or adb lists," >&2
  echo "       so the install guard cannot check it. Run \`flutter devices\` and" >&2
  echo "       pass an id from it, or rerun with --allow-uninstall." >&2
  exit 1
fi

if [ -z "$flavor" ] && [ -n "$android_ids" ] && [ "$other_count" = 0 ]; then
  echo "note: Android target, so defaulting to --flavor play." >&2
  echo "      Pass --flavor dappstore for the Solana dApp Store build." >&2
  flavor=play
  set -- --flavor play "$@"
fi

# Install guard: never let `flutter run` uninstall the wallet.
#
# When `adb install -r` fails and the app is already on the device, flutter
# does not stop. It prints "Uninstalling old version...", uninstalls the app,
# and installs again. Uninstalling deletes the app's data and its Android
# Keystore entries, and allowBackup is false, so every key held only on that
# device is gone for good. Two predictable failures lead there:
#
#   - The build is signed by a different key than the installed copy
#     (INSTALL_FAILED_UPDATE_INCOMPATIBLE). Every machine has its own random
#     ~/.android/debug.keystore unless you share one, so a debug build from a
#     second machine is enough. A Play Store install is signed by Google's
#     app-signing key, which no local build can match.
#   - The build's versionCode is lower than the installed one
#     (INSTALL_FAILED_VERSION_DOWNGRADE): flutter installs without -d.
#
# So, before flutter builds anything, check both on every Android device it
# could pick, and refuse on a mismatch. Unpredictable install failures (a full
# disk, say) still reach flutter's uninstall; this guard does not cover them.
#
# The device reports each signer as java.security.Signature#hashCode, which is
# java.util.Arrays.hashCode over the certificate's DER bytes. The awk below
# computes the same value from the keystore Gradle will sign with, so nothing
# needs pulling off the device.

refuse_install() {
  local id="$1" pkg="$2" reason="$3"
  {
    echo "error: refusing to run on $id: installing would uninstall the wallet."
    echo "       $reason"
    echo
    echo "       When an install fails, flutter uninstalls the app and installs again."
    echo "       Uninstalling deletes the app's data and its Keystore entries, and"
    echo "       allowBackup is false, so keys held only on that device are lost."
    echo
    echo "       Back the keys up or move them off the device first. Then rerun with"
    echo "       --allow-uninstall, or remove the app yourself:"
    echo "           adb -s $id uninstall $pkg"
  } >&2
  exit 1
}

props_value() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | tail -n 1; }

# Prints the keystore Gradle will sign this build with, as
# "<path>\t<store password>\t<alias>". Mirrors android/app/build.gradle.kts:
# a release build takes its flavour's properties file when one exists, and
# everything else (debug, profile, and a release with no properties file) takes
# AGP's debug keystore.
signing_keystore() {
  local props="" ks pass alias
  if [ "$build_mode" = release ]; then
    if [ "$flavor" = dappstore ]; then props=android/dappstore-key.properties
    else props=android/key.properties; fi
  fi
  if [ -n "$props" ] && [ -f "$props" ]; then
    ks=$(props_value "$props" storeFile)
    pass=$(props_value "$props" storePassword)
    alias=$(props_value "$props" keyAlias)
    # Gradle's file() in the app module resolves a relative path against android/app.
    case "$ks" in /*) ;; *) ks="android/app/$ks" ;; esac
  else
    if [ -n "${ANDROID_USER_HOME:-}" ]; then ks="$ANDROID_USER_HOME/debug.keystore"
    elif [ -n "${ANDROID_SDK_HOME:-}" ]; then ks="$ANDROID_SDK_HOME/.android/debug.keystore"
    else ks="$HOME/.android/debug.keystore"; fi
    pass=android
    alias=androiddebugkey
  fi
  printf '%s\t%s\t%s\n' "$ks" "$pass" "$alias"
}

# Arrays.hashCode of the signing certificate, in Integer.toHexString form.
# Fails when the keystore is missing or unreadable.
expected_cert_hash() {
  local ks pass alias bytes
  IFS=$'\t' read -r ks pass alias <<<"$(signing_keystore)"
  [ -f "$ks" ] || return 1
  command -v keytool >/dev/null 2>&1 || return 1
  bytes=$(KS_PASS="$pass" keytool -exportcert -keystore "$ks" -alias "$alias" \
            -storepass:env KS_PASS 2>/dev/null | od -An -v -tu1) || return 1
  [ -n "$bytes" ] || return 1
  # Signed-byte arithmetic, wrapped to 32 bits. The hex is printed in two 16-bit
  # halves because some awks cast %x arguments to a 32-bit signed int.
  awk '
    BEGIN { h = 1 }
    { for (i = 1; i <= NF; i++) { b = $i; if (b > 127) b -= 256
        h = (31 * h + b) % 4294967296; if (h < 0) h += 4294967296 } }
    END { hi = int(h / 65536); lo = h % 65536
          if (hi > 0) printf "%x%04x\n", hi, lo; else printf "%x\n", lo }
  ' <<<"$bytes"
}

if [ -n "$android_ids" ] && ! $allow_uninstall; then
  case "$flavor" in
    dappstore) pkg=art.mallow.twa ;;
    *) pkg=com.mallow.wallet.android ;;
  esac
  if [ -z "$build_number" ]; then
    build_number=$(sed -n 's/^version:[^+]*+\([0-9][0-9]*\).*/\1/p' pubspec.yaml)
  fi
  new_code="${build_number:-1}"

  adb=$(find_adb) || {
    echo "error: adb not found, so the install guard cannot check the device." >&2
    echo "       Put adb on PATH or set ANDROID_HOME, or rerun with --allow-uninstall." >&2
    exit 1
  }
  ks_path=$(signing_keystore | cut -f1)
  want_hash=$(expected_cert_hash) || want_hash=""

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    dump=$("$adb" -s "$id" shell dumpsys package "$pkg" </dev/null 2>/dev/null) ||
      refuse_install "$id" "$pkg" "Could not ask the device which build of $pkg is installed."
    case "$dump" in *"Package [$pkg]"*) ;; *) continue ;; esac

    have_code=$(awk -v p="Package [$pkg]" '
      index($0, p) { on = 1 }
      on && match($0, /versionCode=[0-9]+/) { print substr($0, RSTART + 12, RLENGTH - 12); exit }
    ' <<<"$dump")
    # Android 9+ prints "PackageSignatures{<id> version:N, signatures:[a, b], past
    # signatures:[...]}"; older releases print "PackageSignatures{<id> [a, b]}".
    have_hash=$(awk -v p="Package [$pkg]" '
      index($0, p) { on = 1 }
      on && /PackageSignatures\{/ {
        s = $0
        if (match(s, /version:[0-9]+, signatures:\[[^]]*\]/)) s = substr(s, RSTART, RLENGTH)
        else if (match(s, /PackageSignatures\{[0-9a-f]+ \[[^]]*\]/)) s = substr(s, RSTART, RLENGTH)
        else exit
        sub(/^[^[]*\[/, "", s); sub(/\]$/, "", s); gsub(/ /, "", s)
        print s; exit
      }
    ' <<<"$dump")

    if [ -z "$want_hash" ]; then
      refuse_install "$id" "$pkg" "$pkg is installed, but the signing key this build would use could not be read ($ks_path). Gradle would create a new random key."
    fi
    if [ -z "$have_hash" ]; then
      refuse_install "$id" "$pkg" "$pkg is installed, but its signing certificate could not be read from dumpsys."
    fi
    if [ "$have_hash" != "$want_hash" ]; then
      refuse_install "$id" "$pkg" "The installed $pkg is signed by a different key (device reports $have_hash; $ks_path gives $want_hash)."
    fi
    if [ -n "$have_code" ] && [ "$have_code" -gt "$new_code" ]; then
      refuse_install "$id" "$pkg" "The installed $pkg has versionCode $have_code, newer than this build's $new_code."
    fi
  done <<<"$android_ids"
fi

# exec so Ctrl-C and the hot-reload keypresses reach flutter directly, and its
# exit code is ours.
exec flutter run \
  --dart-define-from-file=.env \
  --dart-define-from-file=.env.local \
  "$@"
