import 'dart:async';

import 'package:injectable/injectable.dart';

/// Outcome of an X (Twitter) connect round trip, parsed from the
/// `https://mallow.art/auth/callback?twitter=…` app-link redirect.
enum TwitterConnectStatus {
  /// Account linked successfully.
  success,

  /// The X account is already linked to a different mallow account.
  userExists,

  /// Any other failure (`twitter=error` or an unrecognised value).
  error,
}

/// Bridges the X connect app-link callback to whatever screen started the flow.
///
/// Connecting leaves the app for the system browser and returns via the
/// `/auth/callback?twitter=…` app link, which [DeepLinkService] captures. That
/// handler has no reference to the open EditProfileScreen, so it publishes the
/// parsed outcome here; the screen subscribes while mounted to refresh its
/// linked-account state and surface a toast.
@lazySingleton
class TwitterConnectNotifier {
  final _controller = StreamController<TwitterConnectStatus>.broadcast();

  /// Outcomes emitted as connect round trips complete.
  Stream<TwitterConnectStatus> get results => _controller.stream;

  /// Map the raw `twitter` query value to a status and publish it.
  void emitFromCallback(String rawValue) {
    final status = switch (rawValue) {
      'success' => TwitterConnectStatus.success,
      'error_user_exists' => TwitterConnectStatus.userExists,
      _ => TwitterConnectStatus.error,
    };
    if (!_controller.isClosed) _controller.add(status);
  }
}
