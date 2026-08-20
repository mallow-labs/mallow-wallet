import 'dart:async';

import 'package:injectable/injectable.dart';

/// Request emitted when a Ledger wallet needs interactive signature verification.
class LedgerVerifyRequest {
  LedgerVerifyRequest({required this.address});

  final String address;
  final Completer<bool> completer = Completer<bool>();
}

/// Singleton controller that bridges the Dio interceptor (no BuildContext)
/// with the UI layer.
///
/// The interceptor emits requests via [requestVerification]; the app-level
/// [_LedgerVerifyListener] in `app.dart` shows the verification bottom sheet
/// and completes the request's [Completer].
@lazySingleton
class LedgerVerifyController {
  final _requestController = StreamController<LedgerVerifyRequest>.broadcast();

  /// Stream of verification requests. The app.dart builder listens to this.
  Stream<LedgerVerifyRequest> get requests => _requestController.stream;

  /// Called by the interceptor when a Ledger wallet gets 401 "Signature required".
  ///
  /// Returns `true` if the user successfully verified, `false` if cancelled.
  Future<bool> requestVerification(String address) {
    final request = LedgerVerifyRequest(address: address);
    _requestController.add(request);
    return request.completer.future;
  }

  void dispose() {
    _requestController.close();
  }
}
