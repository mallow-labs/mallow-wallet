import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/account.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/utils/chain.dart' show apiOwnerAddress;
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/confirm_sheet.dart';

/// Ensure the active signer can authorize an owner action whose required
/// authority is [requiredAddress] (the on-chain owner for transfer/burn/list,
/// the update authority for edit). Returns true when the flow may proceed:
///
///  * active wallet is already the authority → no-op;
///  * the authority is a different signable Solana wallet in the current
///    session → re-point the signer to it ([SessionManager.selectSourceWallet]);
///  * the authority isn't a session wallet → the active wallet is acting as a
///    delegate, so sign with it unchanged.
///
/// Returns false (after routing to import or showing a message) when the
/// authority is a watch-only session wallet or the switch fails.
///
/// By default EVM holders (`0x…` addresses) short-circuit to true: there is no
/// per-chain active selection to re-point, so signing is resolved by the EVM
/// transfer flow's own holder threading. Pass [evmHolder] `true` when
/// [requiredAddress] is a known EVM session holder — the `0x` short-circuit is
/// then skipped so a **watch-only** ETH holder is still routed to import (the
/// address is matched case-insensitively, per hex checksum).
///
/// 🛑 Only a **Solana** holder is ever re-pointed. Ethereum and Tezos sign by
/// explicit wallet id, so a signable holder on either returns true with the
/// active wallet left alone ([WalletInfo.bindsGlobalSigner]) — matching the send
/// flow. Switching for them moved the backend login identity, which authorizes
/// unrelated `owner == req.loginAddress` writes, for no signing benefit.
///
/// [watchOnlyMessage] overrides the body of the watch-only prompt. The default
/// is artwork-holder phrasing; pass a fitting sentence for authorities that are
/// not "the wallet that holds this artwork" (cancel-offer, claim-proceeds).
Future<bool> ensureSigner(
  BuildContext context,
  String? requiredAddress, {
  bool evmHolder = false,
  String? watchOnlyMessage,
}) async {
  final resolution = await _resolveSigner(
    context,
    requiredAddress,
    evmHolder: evmHolder,
    watchOnlyMessage: watchOnlyMessage,
  );
  if (!resolution.canProceed) return false;
  final target = resolution.switchTarget;
  if (target == null) return true;
  try {
    await sl<SessionManager>().selectSourceWallet(target);
    return true;
  } catch (_) {
    if (context.mounted) {
      AppSnackBar.show(
        context,
        "Couldn't switch to the wallet that holds this artwork. "
        'Please try again.',
      );
    }
    return false;
  }
}

/// The precondition half of [ensureSigner] with **no** side effect on the active
/// signer: it runs the same authority resolution (routing a watch-only holder to
/// import) but never calls [SessionManager.selectSourceWallet]. Returns true
/// when the flow may proceed, deferring the actual re-point to the confirmed-
/// execution point (e.g. the mint bloc's pre-sign switch for edits, or
/// [restoreSigner]-guarded flows). Use this where the switch must not persist if
/// the user merely opens and abandons a screen/sheet.
Future<bool> ensureSignerAvailable(
  BuildContext context,
  String? requiredAddress, {
  bool evmHolder = false,
  String? watchOnlyMessage,
}) async {
  final resolution = await _resolveSigner(
    context,
    requiredAddress,
    evmHolder: evmHolder,
    watchOnlyMessage: watchOnlyMessage,
  );
  return resolution.canProceed;
}

/// [ensureSigner] for actions whose authority may be **one of several**
/// addresses: settle-auction (seller OR winner), raffle claim (winner OR
/// creator), or an artwork exposing multiple owner addresses. [candidates] are
/// tried in order — most specific first — and null/empty entries are skipped.
///
/// The **active wallet wins over candidate order**: all candidates are checked
/// against [AuthService.currentAddress] first, so settling an auction with
/// candidates `[seller, currentBidder]` while the *winner* is active does not
/// switch the user's app-wide wallet to the seller for a "Claim NFT" tap — a
/// pointless switch that also changes what the action means.
///
/// Falls back to resolving the first candidate when none is a signable session
/// wallet, so a watch-only session holder still routes to import and a
/// non-session authority still gets the delegate pass-through.
Future<bool> ensureSignerForAny(
  BuildContext context,
  List<String?> candidates, {
  String? watchOnlyMessage,
}) async {
  final resolved = candidates
      .whereType<String>()
      .where((a) => a.isNotEmpty)
      .toList();
  if (resolved.isEmpty) return true;

  final active = sl<AuthService>().currentAddress;
  if (active != null && active.isNotEmpty) {
    final activeKey = apiOwnerAddress(active);
    if (resolved.any((c) => apiOwnerAddress(c) == activeKey)) return true;
  }

  final session = sl<SessionManager>();
  for (final candidate in resolved) {
    final wallet = session.sessionWalletForAddressCaseInsensitive(candidate);
    if (wallet == null || !wallet.canSign) continue;
    return ensureSigner(context, candidate, watchOnlyMessage: watchOnlyMessage);
  }
  return ensureSigner(
    context,
    resolved.first,
    watchOnlyMessage: watchOnlyMessage,
  );
}

/// Snapshot the active **signable** session wallet before a flow re-points the
/// signer, so an abandoned flow can put it back via [restoreSigner]. Returns
/// null when there is nothing to restore (no resolvable active wallet).
///
/// Resolves via [SessionManager.resolveWalletForAddress], which also searches
/// the active account — the active signer is not guaranteed to be in
/// `sessionWallets` (Profile mode), and a session-only lookup would return null
/// there, silently turning every [restoreSigner] into a no-op so an abandoned
/// confirm sheet would permanently move the user's wallet.
WalletInfo? activeSignerSnapshot() {
  final address = sl<AuthService>().currentAddress;
  if (address == null || address.isEmpty) return null;
  return sl<SessionManager>().resolveWalletForAddress(address);
}

/// Re-point the active signer back to [previous] (captured by
/// [activeSignerSnapshot]) when the active wallet has since moved. No-op when
/// [previous] is null or is already the active wallet. Best-effort: a failed
/// restore leaves the signer as-is.
Future<void> restoreSigner(WalletInfo? previous) async {
  if (previous == null) return;
  if (sl<AuthService>().currentAddress == previous.address) return;
  try {
    await sl<SessionManager>().selectSourceWallet(previous);
  } catch (_) {
    // Leave the signer as-is; restore is best-effort.
  }
}

/// Outcome of resolving the signer for [requiredAddress]: whether the flow may
/// proceed, and the signable session wallet the signer should be re-pointed to
/// at execution time ([switchTarget], null when no switch is needed).
typedef _SignerResolution = ({bool canProceed, WalletInfo? switchTarget});

Future<_SignerResolution> _resolveSigner(
  BuildContext context,
  String? requiredAddress, {
  required bool evmHolder,
  String? watchOnlyMessage,
}) async {
  if (requiredAddress == null || requiredAddress.isEmpty) {
    return (canProceed: true, switchTarget: null);
  }
  if (sl<AuthService>().currentAddress == requiredAddress) {
    return (canProceed: true, switchTarget: null);
  }
  if (!evmHolder && requiredAddress.startsWith('0x')) {
    return (canProceed: true, switchTarget: null); // EVM — see doc above.
  }
  final session = sl<SessionManager>();
  final target = evmHolder
      ? session.sessionWalletForAddressCaseInsensitive(requiredAddress)
      : session.sessionWalletForAddress(requiredAddress);
  // Active wallet acts as a delegate.
  if (target == null) return (canProceed: true, switchTarget: null);
  if (!target.canSign) {
    final go = await showConfirmSheet(
      context,
      title: 'Watch-only wallet',
      message:
          watchOnlyMessage ??
          'This artwork is held by a watch-only wallet in your account. '
              'Import its private key to sign for it.',
      confirmLabel: 'Import wallet',
    );
    if ((go ?? false) && context.mounted) {
      await context.push(AppRoutes.importWallet);
    }
    return (canProceed: false, switchTarget: null);
  }
  // Signable holder on a chain that signs by explicit wallet id (Ethereum,
  // Tezos): re-pointing the active wallet buys nothing and costs the backend
  // login identity — the address `verifySignedWalletV2` keys its cookie by, and
  // therefore the authority behind every unrelated `owner == req.loginAddress`
  // write. Only Solana's executor resolves its signer from the global
  // selection, so only Solana earns the switch ([WalletInfo.bindsGlobalSigner],
  // the same rule the send flow follows).
  if (!target.bindsGlobalSigner) return (canProceed: true, switchTarget: null);
  return (canProceed: true, switchTarget: target);
}
