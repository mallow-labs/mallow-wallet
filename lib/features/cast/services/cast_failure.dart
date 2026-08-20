/// User-facing copy for cast failures.
///
/// Cast talks to platform channels rather than the API / signing stack, so the
/// shared mapper in `lib/core/result/app_failure.dart` has nothing to classify
/// here: every native failure is a [PlatformException], which `AppFailure.from`
/// files as `AppFailureKind.unknown` with `error.toString()` as the message —
/// i.e. it would put `PlatformException(NO_DISCOVERY, Call startDiscovery
/// first, null, null)` in front of a tester. This file follows the same
/// convention (throwable in, one user-facing sentence out) against a
/// cast-specific table of native error codes.
///
/// Codes come from `android/app/src/main/kotlin/com/mallow/wallet/android/CastPlugin.kt`
/// and `ios/Runner/IosChromecastPlugin.swift`. Unknown codes fall through to a
/// generic sentence — never the raw code.
library;

import 'package:flutter/services.dart';

/// Copy for a failed `connectToDevice`, addressed to the device the user
/// actually tapped so the sentence reads as an answer to their action.
String castConnectFailureMessage(Object error, {required String deviceName}) {
  final name = deviceName.trim().isEmpty ? 'that screen' : deviceName.trim();

  if (error is MissingPluginException) {
    return 'Casting isn\'t supported on this device.';
  }

  if (error is PlatformException) {
    return switch (error.code) {
      // The native scan was torn down before the connect landed — usually the
      // sheet was reopened, or the OS reclaimed discovery in the background.
      'NO_DISCOVERY' =>
        'Lost track of nearby screens. Search again, then pick $name.',
      // The route/device disappeared between discovery and connect.
      'DEVICE_NOT_FOUND' =>
        '$name is no longer on the network. Check that it\'s powered on and '
            'on the same Wi-Fi, then search again.',
      // Cast SDK refused to open a session — most often another sender owns it.
      'SESSION_FAILED' =>
        'Couldn\'t start casting on $name. If another device is already '
            'casting to it, stop that first, then try again.',
      'NO_SESSION' => 'The cast session ended. Reconnect to keep casting.',
      'CAST_UNAVAILABLE' => _kPlayServicesMessage,
      _ => 'Couldn\'t connect to $name. Try again.',
    };
  }

  // MultiCastService throws a StateError when no backend claims the device —
  // the device row is stale (discovery updated underneath the tap).
  if (error is StateError) {
    return '$name is no longer available. Search again and pick a screen.';
  }

  return 'Couldn\'t connect to $name. Try again.';
}

/// Copy for a failed `startDiscovery`. Distinct from the connect table: no
/// device is involved yet, so the actionable advice is about the phone's own
/// ability to scan.
String castDiscoveryFailureMessage(Object error) {
  if (error is MissingPluginException) {
    return 'Casting isn\'t supported on this device.';
  }
  if (error is PlatformException && error.code == 'CAST_UNAVAILABLE') {
    return _kPlayServicesMessage;
  }
  return 'Couldn\'t search for screens. Check your Wi-Fi connection and try '
      'again.';
}

/// Emitted when the Android Cast SDK can't initialise — the usual cause is a
/// device without (or with an outdated) Google Play services, where an empty
/// device list is otherwise indistinguishable from "nothing on this network".
const _kPlayServicesMessage =
    'Casting needs Google Play services, which isn\'t available on this '
    'device.';
