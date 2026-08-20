import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

/// Request emitted when a Ledger wallet operation needs the device connected
/// but the BLE link is currently down (initial cold start, inactivity timeout,
/// out of range, etc.).
class LedgerConnectRequest {
  LedgerConnectRequest({required this.address});

  final String address;
  final Completer<bool> completer = Completer<bool>();
}

/// Singleton controller that bridges Ledger-aware service code (no
/// BuildContext) with the UI layer.
///
/// [WalletManager] emits requests via [requestConnection] before invoking a
/// Ledger signing API; the app-level `_LedgerConnectListener` in `app.dart`
/// shows the connect bottom sheet and completes the request's [Completer].
@lazySingleton
class LedgerConnectController {
  final _requestController = StreamController<LedgerConnectRequest>.broadcast();

  /// Stream of connection requests. The app.dart listener subscribes here.
  Stream<LedgerConnectRequest> get requests => _requestController.stream;

  /// Called when a Ledger sign call is about to run but the device is not
  /// connected. Returns `true` if the user successfully connected,
  /// `false` if the sheet was dismissed or connection failed.
  Future<bool> requestConnection(String address) {
    final request = LedgerConnectRequest(address: address);
    debugPrint(
      '[LedgerConnect] requestConnection($address) — '
      'hasListener=${_requestController.hasListener}',
    );
    _requestController.add(request);
    return request.completer.future.then((ok) {
      debugPrint('[LedgerConnect] requestConnection($address) resolved: $ok');
      return ok;
    });
  }

  void dispose() {
    _requestController.close();
  }
}
