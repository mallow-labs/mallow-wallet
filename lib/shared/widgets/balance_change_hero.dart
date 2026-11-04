import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'signing_review_layout.dart';

/// One net balance change for [BalanceChangeHero].
class BalanceChange {
  const BalanceChange({
    required this.label,
    required this.amount,
    required this.icon,
    this.outgoing = false,
    this.fiat,
    this.detail,
    this.detailWidget,
  });

  /// "You send" / "You receive".
  final String label;

  /// Amount with its symbol, already formatted. Never animated or abbreviated.
  final String amount;

  /// 40 dp token icon.
  final Widget icon;
  final bool outgoing;

  /// Optional fiat value; omit when the price is unknown rather than guess.
  final String? fiat;

  /// Optional small line under the amount (e.g. an unverified token's mint).
  final String? detail;
  final Widget? detailWidget;
}

/// The headline of a review: what leaves and what arrives, in large tabular
/// figures. Amounts stay `textPrimary`; the label and, for a plain swap (one
/// out, one in), a down-arrow joint carry the direction.
class BalanceChangeHero extends StatelessWidget {
  const BalanceChangeHero({required this.changes, super.key});

  final List<BalanceChange> changes;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final joint =
        changes.length == 2 && changes[0].outgoing && !changes[1].outgoing;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgPrimary,
        borderRadius: BorderRadius.circular(MallowTheme.radiusLg),
        border: Border.all(color: colors.dividerLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, change) in changes.indexed) ...[
            if (i > 0) _Seam(joint: joint),
            _Row(change),
          ],
        ],
      ),
    );
  }
}

class _Seam extends StatelessWidget {
  const _Seam({required this.joint});
  final bool joint;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return SizedBox(
      height: 1,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            left: 16,
            right: 16,
            child: ColoredBox(color: colors.dividerLight),
          ),
          if (joint)
            Positioned(
              top: -15,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: colors.bgSurface,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.dividerLight),
                  ),
                  alignment: Alignment.center,
                  child: const ReviewIcon(ReviewGlyph.arrowDown, size: 15),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.change);
  final BalanceChange change;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final fiat = change.fiat;
    // Under large text the fiat value moves beneath the amount instead of
    // squeezing it into a narrow column.
    final stacked = MediaQuery.textScalerOf(context).scale(13) > 18;
    final fiatText = fiat == null
        ? null
        : Text(
            fiat,
            style: MallowTheme.uiMetaTabular.copyWith(
              letterSpacing: 0,
              color: colors.textSecondary,
            ),
          );
    final row = Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          SizedBox.square(dimension: 40, child: change.icon),
          const SizedBox(width: MallowTheme.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  change.label,
                  style: MallowTheme.uiMeta.copyWith(
                    letterSpacing: 0,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  change.amount,
                  style: MallowTheme.uiDisplayTabular.copyWith(
                    letterSpacing: -0.3,
                    color: colors.textPrimary,
                  ),
                ),
                if (change.detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    change.detail!,
                    style: MallowTheme.uiMeta.copyWith(
                      letterSpacing: 0,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
                if (change.detailWidget != null) ...[
                  const SizedBox(height: 2),
                  change.detailWidget!,
                ],
                if (stacked && fiatText != null) ...[
                  const SizedBox(height: 2),
                  fiatText,
                ],
              ],
            ),
          ),
          if (!stacked && fiatText != null) ...[
            const SizedBox(width: MallowTheme.spacingSm),
            fiatText,
          ],
        ],
      ),
    );
    // A detail widget may carry copyable address chips, which merging would
    // fold into one node with a single tap action.
    return change.detailWidget == null
        ? MergeSemantics(child: row)
        : Semantics(container: true, child: row);
  }
}
