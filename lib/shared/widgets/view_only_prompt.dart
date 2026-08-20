import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/services/wallet_repository.dart';
import '../../core/session/session_manager.dart';
import '../../di.dart';
import '../theme/mallow_theme.dart';
import '../utils/chain.dart';
import 'confirm_sheet.dart';
import 'mallow_sheet.dart';
import 'tappable.dart';

/// Shows the generic "View-only wallet" bottom sheet, used as a pre-flight
/// guard before any flow that would build a transaction or sign a message.
Future<void> showViewOnlyPrompt(BuildContext context) {
  return showMallowSheet<void>(
    context: context,
    builder: (_) => const _ViewOnlySheet(),
  );
}

/// Pre-flight guard for any flow that would build a transaction or sign a
/// message. Looks up the active wallet; if it's view-only, surfaces
/// [showViewOnlyPrompt] and returns `true` (caller should abort). Returns
/// `false` when the action may proceed.
///
/// Always re-check `context.mounted` after awaiting this — the sheet awaits
/// a DB lookup before showing.
Future<bool> guardViewOnly(BuildContext context) async {
  final wallet = await sl<WalletRepository>().getActiveWallet();
  if (!context.mounted) return true;
  if (wallet == null || wallet.canSign) return false;
  await showViewOnlyPrompt(context);
  return true;
}

/// Why the session cannot send. The two dead ends need different remedies, so
/// [guardCannotSend] surfaces them with different prompts.
enum SendBlocker {
  /// No wallet in the session can sign a transfer on the chain — it is linked
  /// watch-only, or the session holds none there at all. The remedy is
  /// importing a key, so the prompt routes to [AppRoutes.importWallet].
  noSigner,

  /// A signable wallet exists, but the **globally selected** one — which
  /// Solana's executor signs with ([WalletInfo.bindsGlobalSigner]) — is
  /// watch-only. The remedy is switching wallets, not importing one.
  activeWalletViewOnly,
}

/// Chain-aware pre-flight guard for a **send**, where the signing wallet is not
/// necessarily the active one.
///
/// [guardViewOnly] asks whether the globally selected wallet can sign, which is
/// the right question only for chains whose signer *is* that selection
/// (Solana — [WalletInfo.bindsGlobalSigner]). A Tezos or Ethereum send picks
/// its source from the session's wallets on the token's chain and signs by
/// explicit wallet id, so the active wallet's type says nothing about it:
/// a watch-only Solana selection was blocking ETH and XTZ sends from wallets
/// that could sign them perfectly well.
///
/// Pass [chain] when the token — and therefore the chain — is already known.
/// Omit it for a generic Send entry point that hasn't picked a token yet, and
/// the guard passes if the session can sign a send on **any** chain; the token
/// list and source picker narrow it from there, and the send sheet re-runs this
/// guard with the chain of the token the user picks.
///
/// Returns `true` when the caller should abort. Always re-check
/// `context.mounted` after awaiting — the sheet awaits a DB lookup.
Future<bool> guardCannotSend(BuildContext context, {Chain? chain}) async {
  final blocker = await sendBlocker(chain: chain);
  if (blocker == null) return false;
  if (!context.mounted) return true;
  switch (blocker) {
    case SendBlocker.activeWalletViewOnly:
      await showViewOnlyPrompt(context);
    case SendBlocker.noSigner:
      await _promptImportSigner(context, chain);
  }
  return true;
}

/// The pure predicate behind [guardCannotSend], with no UI.
///
/// Use it to decide whether to *show* a send affordance at all — hiding the
/// control and then gating the tap must agree, or the guard becomes
/// unreachable. See the token detail screen's action bar.
Future<bool> sessionCanSend({Chain? chain}) async =>
    await sendBlocker(chain: chain) == null;

/// What stops a send on [chain], or null when it may proceed.
///
/// 🛑 A known chain answers for itself, in **both** directions: no signable
/// session wallet on it means the send cannot be signed, whatever the active
/// selection happens to be. Falling back to the active wallet's type when the
/// chain said "no" let a session holding only a Tezos key open a *Solana* send
/// — the guard saw a signable selection, and Solana's executor then signed with
/// that Tezos wallet, which surfaces four steps later as a failed simulation
/// rather than as the missing-key problem it is.
Future<SendBlocker?> sendBlocker({Chain? chain}) async {
  final session = sl<SessionManager>();
  bool canSendOn(Chain c) {
    final wallet = session.sessionWalletForChain(c);
    return wallet != null && wallet.canSignSendTransfer;
  }

  // A chain that signs by explicit wallet id answers for itself.
  if (chain != null && chain != Chain.solana) {
    return canSendOn(chain) ? null : SendBlocker.noSigner;
  }
  if (chain == null &&
      Chain.values.where((c) => c != Chain.solana).any(canSendOn)) {
    // Chain unknown (a generic Send entry point): a signable wallet on any
    // non-Solana chain is enough to open the sheet, which then narrows by
    // token and source.
    return null;
  }
  // Solana: its executor signs with the global selection, so the send needs a
  // signable Solana wallet in the session *and* a selection that can sign — a
  // watch-only selection blocks a SOL send even when the session holds another
  // Solana wallet.
  if (!canSendOn(Chain.solana)) return SendBlocker.noSigner;
  final active = await sl<WalletRepository>().getActiveWallet();
  return active == null || active.canSign
      ? null
      : SendBlocker.activeWalletViewOnly;
}

/// The dead end a key would fix: offer the import route rather than the
/// informational [showViewOnlyPrompt], whose only action is "Done".
Future<void> _promptImportSigner(BuildContext context, Chain? chain) async {
  final (title, message) = _noSignerCopy(chain);
  final go = await showConfirmSheet(
    context,
    title: title,
    message: message,
    confirmLabel: 'Import wallet',
  );
  if ((go ?? false) && context.mounted) {
    await context.push(AppRoutes.importWallet);
  }
}

/// Prompt copy for [SendBlocker.noSigner]. "Linked watch-only" and "no wallet
/// on this chain at all" are different dead ends — collapsing them tells a user
/// who linked a Solana wallet that they don't have one.
(String, String) _noSignerCopy(Chain? chain) {
  if (chain == null) {
    return (
      'Watch-only wallet',
      'No wallet in this account can sign a transaction. '
          'Import a private key to send.',
    );
  }
  final label = chain.label;
  // `sessionWalletsForChain` includes view-only, so a hit here — given the
  // caller already established there is no *signable* wallet on the chain —
  // means the session holds the address but not its key.
  final watchOnly = sl<SessionManager>()
      .sessionWalletsForChain(chain)
      .isNotEmpty;
  return watchOnly
      ? (
          'Watch-only wallet',
          'Your $label wallet is watch-only. Import its private key to '
              'send $label assets.',
        )
      : (
          'No $label wallet',
          'This account has no $label wallet that can sign. '
              'Import one to send $label assets.',
        );
}

class _ViewOnlySheet extends StatelessWidget {
  const _ViewOnlySheet();

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      padding: EdgeInsets.only(
        left: MallowTheme.spacing20,
        right: MallowTheme.spacing20,
        top: MallowTheme.spacing20,
        bottom: sheetBottomInset(context),
      ),
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'View-only wallet',
            style: MallowTheme.editorialSubhead.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          Text(
            'This wallet cannot sign messages or transactions',
            style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: MallowTheme.spacing20),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: Material(
              color: colors.accent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
              ),
              child: Tappable(
                onTap: () => Navigator.of(context).pop(),
                child: Center(
                  child: Text(
                    'Done',
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textOnAccent,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
