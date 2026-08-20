import 'package:flutter/material.dart';

import '../../../core/models/account.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/utils/address_format.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../portfolio/data/session_portfolio_aggregator.dart';

import '../../../shared/utils/chain.dart';

/// Opens the source-wallet picker for the send flow.
///
/// Returns the chosen [WalletInfo], or `null` when the user cancels (or, on
/// Solana, when the signer switch fails).
///
/// 🛑 Only a **Solana** [chain] re-points the signer. Solana's executor signs
/// with the globally selected wallet ([WalletInfo.bindsGlobalSigner]), so the
/// selection must move before the chosen source can sign; the switch (and its
/// persistence) happens inside the sheet so a failed re-login keeps it open for
/// retry rather than advancing the flow (send-wallet-select spec). For that
/// chain this resolves only once the switch settles — including the awaited
/// `/v0/login`, so `AuthService.currentAddress` is the chosen wallet by then.
///
/// Tezos and Ethereum sign by explicit wallet id, so the picker just returns
/// the selection and the caller threads it into `SendEvent.setSource`. Nothing
/// global moves, so — as in the sibling `showReceiveWalletSelectSheet` — there
/// is no in-flight state, no per-row spinner and no failure path for them.
///
/// A drag- or barrier-dismiss **while a Solana switch is in flight** still
/// reports the wallet that committed. Flutter pops a modal bottom sheet by
/// calling `Navigator.pop` directly, so the dismissal cannot be blocked from
/// inside the sheet; without this reconcile the sheet would resolve `null`, the
/// caller would keep displaying the old source, and the switch would complete
/// anyway — leaving the displayed source and the wallet that actually signs in
/// disagreement.
Future<WalletInfo?> showSendWalletSelectSheet(
  BuildContext context, {
  required Chain chain,
  required String tokenSymbol,
  required List<SendSourceCandidate> candidates,
  required String? activeWalletId,
}) async {
  final outcome = SendWalletSwitchOutcome();
  final chosen = await showMallowSheet<WalletInfo>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Container(
      decoration: BoxDecoration(
        color: sheetContext.mallowColors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: SendWalletSelectSheet(
        chain: chain,
        tokenSymbol: tokenSymbol,
        candidates: candidates,
        activeWalletId: activeWalletId,
        outcome: outcome,
      ),
    ),
  );
  if (chosen != null) return chosen;
  return outcome.settle();
}

/// Carries an in-flight switch across the sheet's dismissal so
/// [showSendWalletSelectSheet] can report a switch that committed after the
/// sheet was already popped.
class SendWalletSwitchOutcome {
  Future<WalletInfo?>? _pending;

  void track(Future<WalletInfo?> switching) => _pending = switching;

  Future<WalletInfo?> settle() async {
    final pending = _pending;
    if (pending == null) return null;
    try {
      return await pending;
    } catch (_) {
      return null; // Failed switch — the caller keeps the previous source.
    }
  }
}

/// Body of the source-wallet picker. A Solana row re-points the active signer
/// on tap; a Tezos/Ethereum row just reports the selection.
class SendWalletSelectSheet extends StatefulWidget {
  const SendWalletSelectSheet({
    required this.chain,
    required this.tokenSymbol,
    required this.candidates,
    required this.activeWalletId,
    this.outcome,
    super.key,
  });

  final Chain chain;
  final String tokenSymbol;
  final List<SendSourceCandidate> candidates;
  final String? activeWalletId;

  /// Set by [showSendWalletSelectSheet] so a switch that is still in flight
  /// when the sheet is dismissed is still reported to the caller.
  final SendWalletSwitchOutcome? outcome;

  @override
  State<SendWalletSelectSheet> createState() => _SendWalletSelectSheetState();
}

class _SendWalletSelectSheetState extends State<SendWalletSelectSheet> {
  /// The wallet whose switch is in flight, so its row shows progress and other
  /// rows ignore taps until it settles.
  String? _switchingId;

  Future<void> _onSelect(SendSourceCandidate candidate) async {
    if (_switchingId != null) return;
    // Re-tapping the already-active wallet just proceeds — no signer change.
    if (candidate.wallet.id == widget.activeWalletId) {
      Navigator.of(context).pop(candidate.wallet);
      return;
    }
    // Tezos/Ethereum sign by explicit wallet id, so the selection alone is the
    // answer — no global switch, and therefore no spinner, no in-flight
    // reconcile and no failure path. See the dartdoc on
    // [showSendWalletSelectSheet].
    if (!candidate.wallet.bindsGlobalSigner) {
      Navigator.of(context).pop(candidate.wallet);
      return;
    }
    setState(() => _switchingId = candidate.wallet.id);
    // Registered before the await so a dismissal mid-switch can still be
    // reconciled by [showSendWalletSelectSheet].
    final switching = sl<SessionManager>()
        .selectSourceWallet(candidate.wallet)
        .then<WalletInfo?>((_) => candidate.wallet);
    widget.outcome?.track(switching);
    try {
      await switching;
      if (!mounted) return;
      Navigator.of(context).pop(candidate.wallet);
    } catch (_) {
      if (!mounted) return;
      setState(() => _switchingId = null);
      AppSnackBar.show(context, "Couldn't switch wallet. Please try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final bottomPad = sheetBottomInset(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetDragHandle(color: colors.divider),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Select ${widget.chain.label} wallet',
                style: MallowTheme.editorialSubhead.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: MallowTheme.spacingLg),
              for (final candidate in widget.candidates)
                _WalletRow(
                  candidate: candidate,
                  tokenSymbol: widget.tokenSymbol,
                  chain: widget.chain,
                  isSwitching: candidate.wallet.id == _switchingId,
                  onTap: () => _onSelect(candidate),
                ),
              const SizedBox(height: MallowTheme.spacingLg),
              MallowButton(
                label: 'Cancel',
                variant: MallowButtonVariant.secondary,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        SizedBox(height: bottomPad),
      ],
    );
  }
}

class _WalletRow extends StatelessWidget {
  const _WalletRow({
    required this.candidate,
    required this.tokenSymbol,
    required this.chain,
    required this.isSwitching,
    required this.onTap,
  });

  final SendSourceCandidate candidate;
  final String tokenSymbol;
  final Chain chain;
  final bool isSwitching;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacing12),
        child: Row(
          children: [
            MallowSvgIcon(chain.paddedIconAsset, width: 20, height: 20),
            const SizedBox(width: MallowTheme.spacing12),
            Expanded(
              child: Text(
                truncateAddress(candidate.wallet.address),
                style: MallowTheme.uiLabel.copyWith(color: colors.textPrimary),
              ),
            ),
            const SizedBox(width: MallowTheme.spacingSm),
            Text(
              'Bal: ${_formatBalance(candidate.uiBalance)} $tokenSymbol',
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
            if (isSwitching) ...[
              const SizedBox(width: MallowTheme.spacingSm),
              MallowLoader(size: 16, color: colors.textSecondary),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatBalance(double value) {
    if (value == 0) return '0';
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(2)}M';
    final digits = value >= 1 ? 2 : 6;
    return stripTrailingZeros(value.toStringAsFixed(digits));
  }
}
