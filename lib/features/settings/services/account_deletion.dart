import 'package:dio/dio.dart' show DioException;
import 'package:flutter/foundation.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/models/account.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';

/// Result of [deleteMallowAccount]. `deleted` means the local session was torn
/// down; `failed` means nothing changed and the profile is still there.
enum AccountDeletionOutcome { deleted, failed }

/// Whether `POST /v2/user/delete` has something to delete, and the username it
/// would remove — null when the signed-in address never set one.
///
/// `signedIn` is the whole predicate; the username only names the doc in the
/// copy. Every `/v2/session` upserts a `users` document for the address, so an
/// authenticated address **always** has a server record — the linked addresses,
/// the sign-in history and the push-notification registrations keyed off them —
/// whether or not a username was ever chosen. The route looks that doc up by
/// address, not by name, so a missing username is not a missing record and must
/// not withhold the delete: App Review signs in and never sets a username, and
/// that is exactly the account 5.1.1(v) requires be deletable.
///
/// Read from [AuthService.currentUser] rather than
/// [SessionManager.activeProfile] on purpose: the route is authenticated by the
/// `login-token` cookie and deletes the user document for **that** address, so
/// the authenticated user is the only source that describes the doc actually
/// being deleted. It is also mode-agnostic — an Account-mode session whose
/// active wallet happens to own a profile can still delete it.
({bool signedIn, String? username}) deletableProfile() {
  final user = sl<AuthService>().currentUser;
  final username = user?.username?.trim();
  return (
    signedIn: user != null,
    username: (username == null || username.isEmpty) ? null : username,
  );
}

/// Delete (anonymize) the logged-in user's mallow profile, then tear the local
/// session down.
///
/// Scope is the profile document only — wallets, recovery phrase, artworks,
/// listings, offers and on-chain history are untouched. Accounts (imported
/// wallets) outlive Profiles, so there is always an Account to fall back to:
/// on success the session drops to Account mode rather than routing to
/// onboarding.
///
/// `404` alone is treated as success. It means there is no user document to
/// delete — either it is already gone (a retry after a partial failure) or the
/// known legacy case where a `users` doc storing a checksummed EVM address
/// authenticates but misses the normalized lookup. Either way the profile is
/// not coming back, and refusing to clear the session would trap the user in a
/// loop.
///
/// A `401` is a **failure**. The route never ran: the `login-token` was
/// rejected or expired, so the profile is still there. Reporting it as deleted
/// would tear the local session down and tell the user their account is gone
/// while it still exists server-side — the exact flow App Review exercises.
/// The user has to sign in again and retry. Every other failure likewise
/// leaves the profile intact and returns [AccountDeletionOutcome.failed].
///
/// A Google or Apple wallet's social vault — its encrypted backup — is NOT
/// part of the profile and is never deleted here, whatever the wallet the
/// session is signed in with. The vault is the only thing that brings such a
/// wallet back on a new device; deleting it because a profile was deleted
/// would trade a username for a wallet. It has its own action, Delete wallet
/// backup on the Sign-in keys screen, and the Delete profile screen says so
/// ([profileHasWalletBackup]).
Future<AccountDeletionOutcome> deleteMallowAccount() async {
  try {
    await sl<api.MallowApiV2Client>().deleteUser();
  } on DioException catch (e) {
    final status = e.response?.statusCode;
    if (status != 404) {
      debugPrint('[AccountDeletion] delete failed: $status');
      return AccountDeletionOutcome.failed;
    }
  } catch (e) {
    debugPrint('[AccountDeletion] delete failed: $e');
    return AccountDeletionOutcome.failed;
  }
  await _dropToAccountSession();
  return AccountDeletionOutcome.deleted;
}

/// Whether the signed-in address is a Google or Apple wallet with a social
/// vault: an encrypted backup mallow keeps after the profile is deleted. The
/// Delete profile screen states that, and where the backup is deleted, so the
/// deletion path it describes is complete.
Future<bool> profileHasWalletBackup() async {
  final address = sl<AuthService>().currentAddress;
  if (address == null) return false;
  final wallets = await sl<WalletRepository>().getAllWallets();
  return wallets.any(
    (w) =>
        w.walletType == WalletType.social &&
        w.socialVaultId != null &&
        w.address.toLowerCase() == address.toLowerCase(),
  );
}

/// Drop the Profile identity and clear the session, leaving the user on their
/// active Account.
Future<void> _dropToAccountSession() async {
  final session = sl<SessionManager>();
  final accountId = session.activeAccount?.id;
  if (session.isProfileMode && accountId != null) {
    // The only public path back to Account mode. It nulls `activeProfile`,
    // re-persists the login mode, and fires `onWalletChanged`, which is what
    // makes the session-backed headers (settings row, drawer) repaint without
    // the deleted username. It re-points the active wallet, so the app-level
    // wallet-change listener kicks off a `/v2/session` — harmless, because the
    // `logout()` below bumps `AuthService`'s session generation and that login
    // tears its own session back down when it lands.
    await session.switchToAccount(accountId);
  }
  // Belt and braces: `switchToAccount` clears the persisted pointer itself, but
  // it returns early when the account id no longer resolves, and the
  // Account-mode branch above never runs it at all. A surviving pointer makes
  // the next cold start try to restore a profile that no longer exists.
  await sl<SecureWalletStorage>().deleteActiveProfileId();

  // MUST be last, and must not be skipped. The backend clears the `login-token`
  // cookie on the delete response, but this client has no cookie jar:
  // `_AuthInterceptor` replays a token it holds in memory and in
  // `SecureWalletStorage` on every request, unconditionally. Only `logout()`
  // deletes that token and removes the interceptor. It touches session state
  // only — wallets, keys and the active Account are untouched.
  await sl<AuthService>().logout();
}
