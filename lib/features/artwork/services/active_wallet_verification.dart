import '../../../core/network/auth_service.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';

/// Ensures the ACTIVE login wallet holds a valid `wallet-sig` so a
/// signed-login-gated backend write is authorized.
///
/// Signed-login writes (`/v0/hide`, downloads, …) run through
/// `verifySignedWalletV2`, which honors ONLY the cookie keyed to
/// `req.loginAddress` — i.e. the active wallet the app logged in as. A sig from
/// a *non-active* session wallet is not accepted (unlike private-curation
/// READS, which the monorepo widened to any profile wallet), so this gate
/// proves the ACTIVE wallet specifically:
/// - the active wallet already has a valid sig (in memory or on disk) → pass;
/// - else `signAndVerifyForWallet` signs it: HD / imported / social sign
///   silently from a local key, and a Ledger pops the `LedgerVerifyController`
///   connect + verify sheet. A social wallet is silent *unless* its stored key
///   is missing, in which case it pops an interactive Web3Auth re-login.
///
/// 🛑 **Call this only from a user-initiated action.** An interactive prompt is
/// acceptable as the direct result of a tap, never from a background/automated
/// path — a login or resume must not ambush the user with it. Background
/// callers use `AuthService.verifySessionWallet`, which defers Ledger wallets
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
  } on LedgerVerificationCancelledException {
    // The verify sheet already named the reason (out of range, wrong app, blind
    // signing off, …) — don't dump the exception on top of it.
    return 'Hardware wallet not verified';
  } catch (e) {
    return 'Wallet verification failed: $e';
  }
}
