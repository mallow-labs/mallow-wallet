import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/utils/address_format.dart';
import '../theme/mallow_theme.dart';
import '../utils/chain.dart';
import '../utils/explorer_utils.dart';
import 'app_snack_bar.dart';
import 'tap_target_expander.dart';

/// Canonical two-column key/value row.
///
/// Geist `uiCaption` label on the left in `textSecondary`; Geist `uiCaption`
/// w500 value right-aligned, also in `textSecondary`. When the row is
/// interactive (`onTap` / `onLongPress`), the value switches to
/// `textPrimary` to signal that it links to another screen or external
/// page. `valueColor` overrides both for warning states.
///
/// Provide either [value] (text) or [valueWidget] (custom) — not both. For
/// addresses prefer [MallowKvAddressRow], which auto-wires copy/explorer
/// behavior. To render a column of rows, wrap them in [MallowKvList].
class MallowKvRow extends StatelessWidget {
  const MallowKvRow({
    required this.label,
    this.value,
    this.valueWidget,
    this.valueColor,
    this.onTap,
    this.onLongPress,
    super.key,
  }) : assert(
         (value == null) != (valueWidget == null),
         'Provide exactly one of value or valueWidget',
       );

  final String label;
  final String? value;
  final Widget? valueWidget;
  final Color? valueColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final isInteractive = onTap != null || onLongPress != null;
    final defaultValueColor = isInteractive
        ? colors.textPrimary
        : colors.textSecondary;
    final effectiveValueColor = valueColor ?? defaultValueColor;

    final renderedValue =
        valueWidget ??
        Text(
          value!,
          textAlign: TextAlign.right,
          style: MallowTheme.uiCaption.copyWith(
            color: effectiveValueColor,
            fontWeight: FontWeight.w500,
          ),
        );

    Widget row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: renderedValue,
            ),
          ),
        ],
      ),
    );

    if (isInteractive) {
      row = TapTargetExpander(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onLongPress: onLongPress,
          child: row,
        ),
      );
    }

    return row;
  }
}

/// Key/value row whose value is a token mint or wallet address.
///
/// Tap copies the full address (light haptic + "Copied to clipboard"
/// snackbar). Long-press opens the address in the user's preferred Solana
/// explorer (medium haptic). Displayed value is run through
/// [truncateAddress]. Pass `isAccount: true` to use the wallet/account
/// explorer path; the default targets the token/mint path. Pass [chain]
/// to route the explorer link to Etherscan / tzkt for non-Solana
/// artworks.
class MallowKvAddressRow extends StatelessWidget {
  const MallowKvAddressRow({
    required this.label,
    required this.address,
    this.isAccount = false,
    this.chain,
    super.key,
  });

  final String label;
  final String address;
  final bool isAccount;
  final Chain? chain;

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: address));
    HapticFeedback.lightImpact();
    AppSnackBar.show(
      context,
      'Copied to clipboard',
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _openExplorer() async {
    await HapticFeedback.mediumImpact();
    final url = isAccount
        ? buildAccountExplorerUrlForChain(address, chain)
        : buildTokenExplorerUrlForChain(address, chain);
    await launchUrl(Uri.parse(url), mode: LaunchMode.inAppBrowserView);
  }

  @override
  Widget build(BuildContext context) {
    return MallowKvRow(
      label: label,
      value: truncateAddress(address),
      onTap: () => _copy(context),
      onLongPress: _openExplorer,
    );
  }
}

/// Vertical list of [MallowKvRow]s.
class MallowKvList extends StatelessWidget {
  const MallowKvList({required this.rows, super.key});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}
