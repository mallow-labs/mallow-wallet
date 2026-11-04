import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

/// How many signer sheets the app shell has on screen right now.
///
/// The hardware-verify, Ledger connect and Keystone QR sheets are opened by
/// listeners in `app.dart` for any request, background requests included. The
/// first two close themselves with a bare `Navigator.pop`, which pops whatever
/// route is on top, so a feature that pushes or removes a route while one is
/// open can have its own route popped instead of the sheet.
///
/// A listener increments [open] immediately before it shows its sheet and
/// decrements it when that sheet completes. It counts sheets on screen, not
/// requests, so a request no listener showed never holds it above zero.
@lazySingleton
class SignerPromptTracker {
  /// Signer sheets currently on screen.
  final ValueNotifier<int> open = ValueNotifier<int>(0);

  /// Call immediately before showing a signer sheet.
  void opened() => open.value = open.value + 1;

  /// Call when that sheet completes, however it went away.
  void closed() {
    if (open.value > 0) open.value = open.value - 1;
  }
}
