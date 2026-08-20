/// Entry-point gate for flows this build only implements on some chains.
///
/// Keys off [AppFlow.chains] — the build's capability matrix, and the same one
/// the kill-switch backstop consults — so a disabled entry point can never
/// drift from what the transaction builders actually support. 29 of the 32
/// cells are Solana-only, which is why an ETH- or Tezos-only session must be
/// stopped here rather than at a Jupiter/Metaplex call that fails with a raw
/// backend error.
///
/// Answers a different question than the other two entry guards: this one is
/// "can this build + session do it at all", not "can this wallet sign"
/// (`guardViewOnly`) or "has an operator switched it off" (`guardFlowDisabled`).
/// It runs first — a user on an unsupported chain should be told the action
/// doesn't exist for them before being asked to switch signers for it.
///
/// Place it in the sheet or route being entered, beside the kill-switch gate,
/// not at each caller — see [guardUnsupportedChain].
library;

import 'package:flutter/widgets.dart';

import '../../core/config/remote_config.dart';
import '../../core/session/session_manager.dart';
import '../../di.dart';
import '../utils/chain.dart';
import 'app_snack_bar.dart';

/// Human list of the chains [flow] runs on: `Solana`, `Solana or Ethereum`.
///
/// Ordered by [Chain.values] rather than [AppFlow.chains] so the phrasing is
/// stable across flows (the sets are literals and carry no order).
String flowChainsLabel(AppFlow flow) {
  final labels = [
    for (final c in Chain.values)
      if (flow.chains.contains(c)) c.label,
  ];
  // Never empty: all 32 `AppFlow` cells pass a non-empty const set literal.
  if (labels.length == 1) return labels.single;
  return '${labels.take(labels.length - 1).join(', ')} or ${labels.last}';
}

/// Whether the current session can run [flow] at all — a signable wallet on one
/// of the chains this build implements it for.
///
/// Cheap enough to call from `build` to decide a disabled state:
/// [SessionManager.sessionWalletForChain] is a `firstWhereOrNull` over the
/// session's wallets and [AppFlow.chains] is a const set. Reads the session
/// without subscribing to it, so a caller that must re-evaluate on a wallet
/// switch has to rebuild on its own.
bool sessionSupportsFlow(AppFlow flow) {
  final session = sl<SessionManager>();
  return flow.chains.any((c) => session.sessionWalletForChain(c) != null);
}

/// Pre-flight guard shaped like `guardViewOnly`: `true` ⇒ **abort** (the reason
/// has been shown), `false` ⇒ proceed. [action] names what the user tapped and
/// starts the sentence.
///
/// Belongs in the sheet/route being entered rather than at each caller, so a
/// call site added later inherits it — the convention `showSwapSheet` sets for
/// the kill-switch gate. Callers may *additionally* read [sessionSupportsFlow]
/// to grey their button; this stays the backstop.
bool guardUnsupportedChain(
  BuildContext context,
  AppFlow flow, {
  required String action,
}) {
  if (sessionSupportsFlow(flow)) return false;
  AppSnackBar.show(context, _unsupportedMessage(flow, action));
  return true;
}

/// Snack-bar copy for a [flow] the session can't run.
///
/// Distinguishes the two reasons deliberately: "no wallet on a supported chain"
/// is a different dead end than "the wallet is watch-only", and collapsing them
/// tells a Solana holder their chain is unsupported. Built only on the failure
/// path — [SessionManager.sessionWalletsForChain] allocates a set and a list per
/// call, and the message would be thrown away on the common path.
String _unsupportedMessage(AppFlow flow, String action) {
  final label = flowChainsLabel(flow);
  // `sessionWalletsForChain` includes view-only, so a hit here — given
  // `sessionSupportsFlow` already said no — means the session holds the right
  // chain but can't sign on it.
  final watchOnly = flow.chains.any(
    (c) => sl<SessionManager>().sessionWalletsForChain(c).isNotEmpty,
  );
  return watchOnly
      ? '$action needs a $label wallet that can sign — this one is view-only.'
      : '$action is only available on $label. '
            'Add a $label wallet to this account.';
}
