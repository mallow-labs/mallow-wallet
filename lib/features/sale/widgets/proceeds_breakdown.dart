import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/explorer_utils.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_pill_chip.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../services/proceeds_calculator.dart';

/// Per-recipient proceeds rows for the listing review steps (fixed-price and
/// auction).
///
/// Layout matches the Figma spec: a label chip on the left, the
/// truncated recipient address in the middle, and the right-aligned amount.
///
/// The right column has two modes, mirroring the webapp's `ProceedsInfo`
/// (`salePrice == null` path):
/// - **Amount mode** ([priceRaw] non-null) — renders absolute token amounts
///   derived from the price. When [priceRaw] is 0 the column shows `—` so the
///   layout doesn't shift while the user is editing. Used by fixed-price.
/// - **Percentage mode** ([priceRaw] `null`) — renders each split's
///   `proceedsPct` as `X%`. Used by auctions, where the hammer price is
///   unknown at listing time so absolute amounts derived from the reserve
///   would be wrong for any auction settling above reserve.
///
/// Tap the address to copy it; long-press to open it in the user's preferred
/// Solana explorer.
class ProceedsBreakdown extends StatelessWidget {
  const ProceedsBreakdown({
    required this.splits,
    required this.token,
    required this.priceRaw,
    super.key,
  });

  final List<ProceedsSplit> splits;
  final MallowToken token;

  /// Raw sale price used to derive per-recipient amounts, or `null` to render
  /// percentages instead (see class doc).
  final int? priceRaw;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Proceeds',
          style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        for (var i = 0; i < splits.length; i++) ...[
          if (i > 0) Divider(height: 1, color: colors.divider),
          _ProceedsRow(split: splits[i], token: token, priceRaw: priceRaw),
        ],
      ],
    );
  }
}

class _ProceedsRow extends StatelessWidget {
  const _ProceedsRow({
    required this.split,
    required this.token,
    required this.priceRaw,
  });

  final ProceedsSplit split;
  final MallowToken token;
  final int? priceRaw;

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: split.address));
    HapticFeedback.lightImpact();
    AppSnackBar.show(
      context,
      'Copied to clipboard',
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _openExplorer() async {
    await HapticFeedback.mediumImpact();
    final uri = Uri.parse(buildAccountExplorerUrlFromPrefs(split.address));
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingSm),
      child: Row(
        children: [
          MallowPillChip(_chipLabel(split.label), width: 72),
          const SizedBox(width: MallowTheme.spacingSm),
          Expanded(
            child: TapTargetExpander(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _copy(context),
                onLongPress: _openExplorer,
                child: Text(
                  truncateAddress(split.address),
                  style: MallowTheme.uiMeta.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          Text(
            _valueLabel(),
            textAlign: TextAlign.right,
            style: MallowTheme.uiMeta.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  String _chipLabel(ProceedsLabel label) => switch (label) {
    ProceedsLabel.you => 'You',
    ProceedsLabel.creator => 'Creator',
    ProceedsLabel.mallow => 'mallow',
  };

  /// Right-column value: a percentage in percentage mode ([priceRaw] `null`),
  /// otherwise the absolute token amount.
  String _valueLabel() {
    final price = priceRaw;
    if (price == null) return '${displayDecimal(split.proceedsPct)}%';
    return _amountLabel(price);
  }

  /// Display the row's amount, falling back to `—` while the user hasn't
  /// entered a price and to a "less than dust" sentinel when the amount
  /// rounds to zero at the token's input precision.
  String _amountLabel(int price) {
    if (price <= 0) return '—';
    final display = token.rawToDisplay(split.amountRaw);
    final formatted = displayDecimal(display);
    if (split.amountRaw > 0 && formatted == '0' && token.inputDecimals > 0) {
      // Mirror webapp's `< 0.0…1` dust treatment.
      final zeros = '0' * (token.inputDecimals - 1);
      return '< 0.${zeros}1 ${token.symbol}';
    }
    return '$formatted ${token.symbol}';
  }
}
