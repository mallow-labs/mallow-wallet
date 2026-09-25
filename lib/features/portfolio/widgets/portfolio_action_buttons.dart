import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/config/store_build.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/chain_support_guard.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../receive/sheets/account_receive_sheet.dart';
import '../../send/widgets/send_sheet.dart';
import '../../staking/widgets/staking_sheet.dart';
import '../../swap/widgets/swap_sheet.dart';
import '../services/token_balance_bloc.dart';

/// Row of round-icon buttons: Swap / Send / Receive / Stake — Swap only in a
/// build that shows it ([showSwap]).
class PortfolioActionButtonsRow extends StatelessWidget {
  const PortfolioActionButtonsRow({super.key});

  @override
  Widget build(BuildContext context) {
    // Native staking targets a Solana validator and swap is Jupiter-backed, so
    // both are only usable when the session can sign on Solana. Disable —
    // rather than hide — them for *that* reason, so their absence is explained;
    // the `onDisabledTap` handlers below are what actually explain it
    // (`showStakeSheet` / `showSwapSheet` run the same guard as the backstop).
    // A store build that drops swap is the other case, and it hides instead —
    // see the row itself.
    //
    // Gated on the signer, not on mere wallet presence: a session holding a
    // view-only Solana wallet alongside a signable ETH one would otherwise pass
    // and then resolve its signer to the ETH address, rendering a stake form
    // that reads `Bal: 0` and cannot fund.
    final canStake = sessionSupportsFlow(AppFlow.stakeNative);
    final canSwap = sessionSupportsFlow(AppFlow.tokenSwap);

    final buttons = [
      // Hidden, not disabled, in a store build that drops swap: a greyed
      // button invites a tap that has nothing to explain.
      if (showSwap)
        _ActionButton(
          icon: 'assets/icons/data_transfer.svg',
          label: 'Swap',
          // No bloc passed on purpose: this screen's instance aggregates
          // across the session's wallets, but a swap spends from the active
          // signer alone. The sheet spins up its own per-signer instance.
          enabled: canSwap,
          onTap: () => showSwapSheet(context),
          onDisabledTap: () =>
              guardUnsupportedChain(context, AppFlow.tokenSwap, action: 'Swap'),
        ),
      _ActionButton(
        icon: 'assets/icons/send.svg',
        label: 'Send',
        onTap: () => showSendSheet(
          context,
          tokenBalanceBloc: context.read<TokenBalanceBloc>(),
        ),
      ),
      _ActionButton(
        icon: 'assets/icons/qr.svg',
        label: 'Receive',
        onTap: () => showSessionReceiveSheet(context),
      ),
      _ActionButton(
        icon: 'assets/icons/diamond.svg',
        label: 'Stake',
        iconSize: 24,
        enabled: canStake,
        onTap: () => showStakeSheet(context),
        onDisabledTap: () => guardUnsupportedChain(
          context,
          AppFlow.stakeNative,
          action: 'Staking',
        ),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      // Four buttons fill the row edge to edge. With three (the store build
      // without swap) that pins Send and Stake to the edges, so each instead
      // gets an equal third of the row and sits centred in it.
      child: showSwap
          ? Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: buttons,
            )
          : Row(
              children: [
                for (final button in buttons)
                  Expanded(child: Center(child: button)),
              ],
            ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    this.iconSize = 20,
    this.enabled = true,
    this.onTap,
    this.onDisabledTap,
  });

  final String icon;
  final String label;
  final double iconSize;
  final bool enabled;
  final VoidCallback? onTap;

  /// Tap handler used while [enabled] is false — lets a greyed-out action
  /// explain itself (e.g. "Swap is only available on Solana") instead of
  /// going dead.
  final VoidCallback? onDisabledTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : onDisabledTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.4,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: context.mallowColors.surfaceMuted,
                borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
              ),
              child: Center(
                child: MallowSvgIcon(
                  icon,
                  width: iconSize,
                  height: iconSize,
                  color: context.mallowColors.accent,
                ),
              ),
            ),
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              label,
              style: MallowTheme.uiLabel.copyWith(
                color: context.mallowColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
