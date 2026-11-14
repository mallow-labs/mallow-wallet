import '../../../core/crypto/exceptions.dart'
    show LegacySocialWalletException, TransactionAuthCancelledException;
import '../../../core/network/auth_service.dart';
import '../../../core/services/seed_vault_service.dart'
    show SeedVaultApprovalCancelledException;
import '../../../core/session/session_manager.dart';
import '../../../di.dart';

/// Ensures the ACTIVE login wallet holds a valid `wallet-sig` so a
/// signed-login-gated backend write is authorized.
///
/// Every signed-login action the user starts runs this first: hide, download,
/// block, unblock, report, connect and disconnect X, sending and checking the
/// email code, profile delete. The 401 re-sign
/// cannot stand in for it. That retry is trigger-blind, so it skips a social
/// wallet whose key needs an interactive re-login, and the action fails. Here
/// the user has just tapped, so the re-login is what they get.
///
/// Signed-login writes (`/v0/hide`, downloads, …) run through
/// `verifySignedWalletV2`, which honors ONLY the cookie keyed to
/// `req.loginAddress` — i.e. the active wallet the app logged in as. A sig from
/// a *non-active* session wallet is not accepted (unlike private-curation
/// READS, which the monorepo widened to any profile wallet), so this gate
/// proves the ACTIVE wallet specifically:
/// - the active wallet already has a valid sig (in memory or on disk) → pass;
/// - else `signAndVerifyForWallet` signs it: HD / imported / social sign
///   silently from a local key; a Ledger pops the `HardwareVerifyController`
///   connect + verify sheet; a Seed Vault wallet signs through its own
///   full-screen OS approval, a Keystone through the QR exchange. A social
///   wallet is silent *unless* its stored key is missing, in which case its
///   social vault is reopened — a sign-in sheet or a passkey prompt — or, for
///   a wallet from the older sign-in, which has no vault, the failure says
///   how to bring the wallet back.
///
/// Closing any of those prompts is a cancel, and reads "Sign-in was
/// cancelled" (a dismissed Ledger sheet keeps "Hardware wallet not verified":
/// the sheet already showed why).
///
/// 🛑 **Call this only from a user-initiated action.** An interactive prompt is
/// acceptable as the direct result of a tap, never from a background/automated
/// path — a login or resume must not ambush the user with it. Background
/// callers use `AuthService.verifySessionWallet`, which defers hardware wallets
/// and social wallets whose stored key is missing instead.
///
/// Returns null on success, or a user-facing message the caller surfaces.
Future<String?> ensureActiveWalletVerified() async {
  final session = sl<SessionManager>();
  final auth = sl<AuthService>();

  final activeAddress = auth.currentAddress;
  if (activeAddress == null || activeAddress.isEmpty) {
    return 'No active wallet — switch to a signing wallet first';
  }

  // Active wallet already verified (in memory or on disk)? hasValidWalletSigForAny
  // hydrates a disk-only hit so the cookie actually rides the next request.
  if (await auth.hasValidWalletSigForAny([activeAddress])) return null;

  final active = session.sessionWalletForAddress(activeAddress);
  if (active == null || !active.canSign) {
    return 'Active wallet can\'t sign — switch to a signing wallet';
  }

  try {
    await auth.signAndVerifyForWallet(active.id, active.address);
    return null;
  } on HardwareVerificationCancelledException {
    // The verify sheet already named the reason (out of range, wrong app, blind
    // signing off, …) — don't dump the exception on top of it.
    return 'Hardware wallet not verified';
  } on TransactionAuthCancelledException {
    // The social key recovery's sign-in was closed, or the Keystone sheet
    // (its cancel is a subtype). Their own copy says "Transaction aborted",
    // which is wrong for a profile action.
    return 'Sign-in was cancelled';
  } on SeedVaultApprovalCancelledException {
    // Seed Vault's own approval screen was dismissed.
    return 'Sign-in was cancelled';
  } on LegacySocialWalletException catch (e) {
    return e.message;
  } catch (e) {
    return 'Wallet verification failed: $e';
  }
}
