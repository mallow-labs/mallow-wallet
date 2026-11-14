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

    final activeAtStart = _authService.currentAddress;
    try {
      // Step 1: Set login-token to the target profile (lightweight — no
      // session state change or listener notifications). The backend's
      // approveLinkRequestV2 merges the new wallet into req.user (login-token
      // user). Inside the try: it may already have swapped the token when it
      // throws, and the restore below has to see that.
      await _authService.loginForLinkFlow(profileWalletAddress);

      // Step 2: Sign and verify for the wallet being linked
      await _authService.signAndVerifyForWallet(newWalletRow.id, walletAddress);

      // Step 3: Sign and verify for the existing profile wallet
      // (likely cached from the loginForLinkFlow above)
      await _authService.signAndVerifyForWallet(
        profileWalletRow.id,
        profileWalletAddress,
      );

      // The approve acts on whoever the login token names. A wallet switch
      // or logout while the signatures above were up replaced it, and the new
      // wallet would be linked to that account instead: fail the link, send
      // nothing.
      if (_authService.currentAddress != activeAtStart ||
          !_authService.loginTokenIsFor(profileWalletAddress)) {
        throw WalletLinkInterruptedException();
      }

      // Step 4: Call approveLinkRequestV2 — backend reads both wallet-sig cookies
      await _api.approveLinkRequestV2(
        ApproveLinkRequestV2Body(address: walletAddress),
      );

      debugPrint('[WalletLinkService] Link successful for $walletAddress');
    } finally {
      await _restoreActiveLogin();
    }
  }

  /// Puts the active wallet's login token back after a link, whatever its
  /// outcome. Until then the resume refresh and the background reads stand
  /// down. Nothing to do when no swap is in place (the link went into the
  /// active profile, or a switch or logout already replaced the token). When
  /// the restore cannot run or fails, the swapped token is dropped instead, so
  /// the next request logs the active wallet in the ordinary way.
  Future<void> _restoreActiveLogin() async {
    if (!_authService.linkFlowActive) return;
    final originalAddress = _authService.currentAddress;
    if (originalAddress != null) {
      try {
        await _authService.loginForLinkFlow(originalAddress);
        return;
      } catch (e) {
        debugPrint('[WalletLinkService] restoring the login failed: $e');
      }
    }
    await _authService.abandonLinkFlowToken();
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

/// A wallet switch or logout happened while the link flow was waiting on its
/// signatures, so the login token no longer names the profile being linked
/// into. Nothing was sent; the user starts the link again.
class WalletLinkInterruptedException implements Exception {
  WalletLinkInterruptedException([
    this.message = 'The active wallet changed during the link. Try again.',
  ]);

  final String message;

  @override
  String toString() => 'WalletLinkInterruptedException: $message';
}
