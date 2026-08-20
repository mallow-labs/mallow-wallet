import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../core/database/database.dart';
import '../../../core/network/auth_service.dart';

/// Service for linking and unlinking wallet addresses to mallow user profiles.
///
/// The link flow (dual-signature):
/// 1. Sign auth-token challenge for the *new* wallet → sets wallet-sig cookie
/// 2. Sign auth-token challenge for the *existing profile* wallet → sets cookie
/// 3. Call POST /v0/wallet/approveLinkRequestV2 — backend verifies both JWTs
///
/// The unlink flow:
/// 1. Call POST /v0/wallet/removeAddress (requires active login token)
@lazySingleton
class WalletLinkService {
  WalletLinkService(this._api, this._authService, this._db);

  final MallowApiClient _api;
  final AuthService _authService;
  final MallowDatabase _db;

  /// Link [walletAddress] into the profile that owns [profileWalletAddress].
  ///
  /// Both wallets must have local keypairs (HD or importedKey). View-only
  /// wallets cannot participate in the link flow.
  ///
  /// Throws [ViewOnlyWalletException] if either wallet cannot sign.
  Future<void> linkWallet(
    String walletAddress,
    String profileWalletAddress,
  ) async {
    // Look up wallet IDs from DB
    final newWalletRow = await _db.getWalletByAddress(walletAddress);
    if (newWalletRow == null) {
      throw ArgumentError('Wallet not found: $walletAddress');
    }

    final profileWalletRow = await _db.getWalletByAddress(profileWalletAddress);
    if (profileWalletRow == null) {
      throw ArgumentError('Profile wallet not found: $profileWalletAddress');
    }

    debugPrint(
      '[WalletLinkService] Linking $walletAddress → profile of $profileWalletAddress',
    );

    // Step 1: Set login-token to the target profile (lightweight — no session
    // state change or listener notifications). The backend's
    // approveLinkRequestV2 merges the new wallet into req.user (login-token user).
    await _authService.loginForLinkFlow(profileWalletAddress);

    // Step 2: Sign and verify for the wallet being linked
    await _authService.signAndVerifyForWallet(newWalletRow.id, walletAddress);

    // Step 3: Sign and verify for the existing profile wallet
    // (likely cached from the loginForLinkFlow above)
    await _authService.signAndVerifyForWallet(
      profileWalletRow.id,
      profileWalletAddress,
    );

    // Step 4: Call approveLinkRequestV2 — backend reads both wallet-sig cookies
    await _api.approveLinkRequestV2(
      ApproveLinkRequestV2Body(address: walletAddress),
    );

    debugPrint('[WalletLinkService] Link successful for $walletAddress');

    // Restore login-token to the original active wallet (loginForLinkFlow
    // temporarily changed it to the target profile).
    final originalAddress = _authService.currentAddress;
    if (originalAddress != null) {
      await _authService.loginForLinkFlow(originalAddress);
    }
  }

  /// Unlink [walletAddress] from its current profile.
  ///
  /// Requires an active login session (login-token cookie).
  Future<void> unlinkWallet(String walletAddress) async {
    debugPrint('[WalletLinkService] Unlinking $walletAddress');

    await _api.removeAddress(RemoveAddressBody(address: walletAddress));

    debugPrint('[WalletLinkService] Unlink successful for $walletAddress');
  }
}
