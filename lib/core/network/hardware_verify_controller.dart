import 'dart:async';

import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import '../models/account.dart';
import '../services/wallet_repository.dart';

/// Request emitted when a hardware wallet needs interactive signature
/// verification.
class HardwareVerifyRequest {
  HardwareVerifyRequest({required this.address, required this.walletType});

  final String address;

  /// Which device holds the key — [WalletType.ledger] or
  /// [WalletType.seedVault].
  ///
  /// The sheet renders a different flow for each, so this is not cosmetic:
  /// telling a Seed Vault user to switch on Bluetooth and open the Solana app
  /// is a dead end they cannot act on.
  final WalletType walletType;

  final Completer<bool> completer = Completer<bool>();
}

/// Singleton controller that bridges the Dio interceptor (no BuildContext)
/// with the UI layer.
///
/// The interceptor emits requests via [requestVerification]; the app-level
/// listener in `app.dart` shows the verification bottom sheet and completes the
/// request's [Completer].
@lazySingleton
class HardwareVerifyController {
  final _requestController =
      StreamController<HardwareVerifyRequest>.broadcast();

  /// Stream of verification requests. The app.dart builder listens to this.
  Stream<HardwareVerifyRequest> get requests => _requestController.stream;

  /// Called when a hardware wallet needs an interactive verification step —
  /// a 401 "Signature required", or an action that implies wallet identity.
  ///
  /// [walletType] names the device. Callers already holding the wallet pass it;
  /// the rest fall back to [hardwareVerifyDeviceFor].
  ///
  /// Returns `true` if the user went through with it, `false` if cancelled.
  Future<bool> requestVerification(
    String address, {
    WalletType? walletType,
  }) async {
    final request = HardwareVerifyRequest(
      address: address,
      walletType: walletType ?? await hardwareVerifyDeviceFor(address),
    );
    _requestController.add(request);
    return request.completer.future;
  }

  void dispose() {
    _requestController.close();
  }
}

/// The device behind the hardware wallet at [address].
///
/// Read from [WalletRepository], which spans every wallet on the device — not
/// from the session, which is scoped to the active Profile/Account and answers
/// null for a wallet being linked into a *different* profile. Getting this
/// wrong is not cosmetic: the sheet renders a Ledger connect flow a Seed Vault
/// owner cannot complete.
///
/// An address no wallet row claims falls back to [WalletType.ledger] — what
/// every hardware wallet was before Seed Vault, so an unresolvable address
/// behaves exactly as it did before.
Future<WalletType> hardwareVerifyDeviceFor(String address) async {
  if (!GetIt.instance.isRegistered<WalletRepository>()) {
    return WalletType.ledger;
  }
  final wallet = await GetIt.instance<WalletRepository>().getWalletByAddress(
    address,
  );
  final type = wallet?.walletType;
  return type != null && type.isHardware ? type : WalletType.ledger;
}
