# passkeys_android (vendored)

Corbado's [`passkeys_android`](https://pub.dev/packages/passkeys_android)
2.15.0, the Android half of the passkeys plugin, copied here with two changes.
It is BSD-3-Clause (© 2023 Corbado GmbH); the licence is in `LICENSE`.

## Why it is vendored

The wallet uses a passkey's WebAuthn PRF output as a secret that unlocks a
social vault. Upstream's `MessageHandler.java` handles a credential response it
cannot parse by writing the whole response to the system log at error level and
passing the `JSONException` to Dart. Both can carry the PRF output: the response
contains it, and a `JSONException`'s message quotes the value it could not
convert. The system log ends up in bug reports, and the exception text ends up
in whatever reports the error.

## The changes

**A credential response is never logged.** In
`android/src/main/java/com/corbado/passkeys_android/MessageHandler.java`,
the five `catch (JSONException e)` blocks that parse a credential response now
call `unreadableResponse(e)`. It logs the exception's class name only and
returns a fixed error, code `android-unreadable-response`, with no response
text and no exception message.

**Two permissions the plugin cannot use are not requested.** Upstream's
`android/src/main/AndroidManifest.xml` declares `USE_CREDENTIALS` and
`CREDENTIAL_MANAGER_SET_ORIGIN`, and a library's permissions are merged into
every build of the app. The first was removed from Android in API 23. The
second lets a privileged caller, such as a browser, act for another origin; the
plugin never sets an origin. A wallet that asks for permissions it has no use
for looks like it wants more than it says, and store review reads it that way.
`USE_BIOMETRIC` stays.

Nothing else differs from upstream: `android/`, `lib/` and `pigeons/` are the
2.15.0 files. Upstream's tests, changelog and lint configuration are not
copied, and the pubspec drops the workspace and dev-dependency entries that
only upstream's repository needs.

## Updating

Copy the new upstream `android/`, `lib/` and `pigeons/` over these, re-apply
the changes above, and bump `version` here. `test/core/social_vault/
passkeys_android_fork_test.dart` in the app fails if the response is logged or
the parse exception is passed on again, or if either permission comes back.
