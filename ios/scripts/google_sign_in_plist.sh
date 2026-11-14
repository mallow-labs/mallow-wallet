#!/bin/sh
#
# Writes Google Sign-In's iOS configuration into the BUILT Info.plist, from the
# same build configuration Dart reads.
#
# GoogleSignIn refuses to start unless the reversed iOS client id is registered
# as a URL scheme, and a URL scheme can only come from Info.plist. The client
# id is per deployment, so it cannot be a literal in the checked-in plist: it
# arrives as the GOOGLE_IOS_CLIENT_ID dart-define, which Flutter hands Xcode as
# DART_DEFINES (comma-joined base64 KEY=VALUE pairs). This phase runs after the
# plist is processed and before signing, and edits the copy inside the app.
#
# Unset, it does nothing and Google sign-in reports that it is not configured.
# Idempotent: an incremental build that keeps the processed plist does not get
# a second URL type.
#
# POSIX sh only: Xcode runs it with /bin/sh, and the build machines' shells
# differ.

set -eu

plist="${TARGET_BUILD_DIR:-}/${INFOPLIST_PATH:-}"
[ -f "$plist" ] || exit 0

client_id=""
for entry in $(printf '%s' "${DART_DEFINES:-}" | tr ',' ' '); do
  decoded="$(printf '%s' "$entry" | /usr/bin/base64 --decode 2>/dev/null || true)"
  case "$decoded" in
    GOOGLE_IOS_CLIENT_ID=*) client_id="${decoded#GOOGLE_IOS_CLIENT_ID=}" ;;
  esac
done

if [ -z "$client_id" ]; then
  echo "GOOGLE_IOS_CLIENT_ID is not set: Google sign-in stays unconfigured."
  exit 0
fi

# 123-abc.apps.googleusercontent.com -> com.googleusercontent.apps.123-abc
scheme="$(printf '%s' "$client_id" | awk -F. '{ for (i = NF; i > 0; i--) printf "%s%s", $i, (i > 1 ? "." : "") }')"

buddy=/usr/libexec/PlistBuddy

"$buddy" -c "Delete :GIDClientID" "$plist" >/dev/null 2>&1 || true
"$buddy" -c "Add :GIDClientID string $client_id" "$plist"

if "$buddy" -c "Print :CFBundleURLTypes" "$plist" 2>/dev/null | grep -q "$scheme"; then
  exit 0
fi
"$buddy" -c "Print :CFBundleURLTypes" "$plist" >/dev/null 2>&1 \
  || "$buddy" -c "Add :CFBundleURLTypes array" "$plist"
count="$("$buddy" -c "Print :CFBundleURLTypes" "$plist" | grep -c "^    Dict {" || true)"
"$buddy" -c "Add :CFBundleURLTypes:$count dict" "$plist"
"$buddy" -c "Add :CFBundleURLTypes:$count:CFBundleTypeRole string Editor" "$plist"
"$buddy" -c "Add :CFBundleURLTypes:$count:CFBundleURLSchemes array" "$plist"
"$buddy" -c "Add :CFBundleURLTypes:$count:CFBundleURLSchemes:0 string $scheme" "$plist"
echo "Google sign-in URL scheme registered."
