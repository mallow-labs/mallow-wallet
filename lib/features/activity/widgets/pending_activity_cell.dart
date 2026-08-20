import 'package:flutter/material.dart';

import '../../../core/services/pending_evm_tx.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../core/utils/token_amount.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/price_format.dart' show stripTrailingZeros;
import '../../../shared/widgets/mallow_network_image.dart';

/// A still-unresolved EVM transaction, as the Pending section renders it.
///
/// Unlike the flat [ActivityListItem] rows below it, a pending entry is a
/// rounded card: it is *actionable* (speed up / cancel) rather than a record,
/// and the card keeps the two pills visually attached to the transaction they
/// replace.
///
/// The card is [MallowColors.surfaceMuted] because the activity sheet's own
/// background is `bgSurface` — a `bgSurface` card would be invisible on it in
/// both themes. For the same reason the filled Cancel pill takes `bgSurface`
/// rather than `surfaceMuted`.
///
/// Actions are injected: [onSpeedUp] / [onCancel] null means "not offered",
/// which is how the caller applies the view-only rule (a wallet outside
/// `SessionManager.signableSessionAddresses` gets no buttons at all).
class PendingActivityCell extends StatelessWidget {
  const PendingActivityCell({
    required this.entry,
    super.key,
    this.walletLabel,
    this.onTap,
    this.onSpeedUp,
    this.onCancel,
  });

  final PendingEvmTx entry;

  /// Subtitle for an external (nonce-gap) entry, whose payload is unknown so
  /// the only thing worth naming is the wallet it is stuck on. Defaults to the
  /// truncated address.
  final String? walletLabel;

  /// Opens the detail sheet.
  final VoidCallback? onTap;

  final VoidCallback? onSpeedUp;
  final VoidCallback? onCancel;

  /// Side of the leading spinner.
  static const double _spinnerSize = 20;

  /// Side of the artwork thumbnail an NFT transfer leads with, after the
  /// spinner.
  static const double _thumbSize = 40;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final actions = PendingTxActionRow(
      entry: entry,
      onSpeedUp: onSpeedUp,
      onCancel: onCancel,
    );

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(MallowTheme.spacing12),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(MallowTheme.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox.square(
                  dimension: _spinnerSize,
                  child: CircularProgressIndicator(
                    color: colors.positive,
                    strokeWidth: 2,
                  ),
                ),
                ?_buildThumbnail(),
                const SizedBox(width: MallowTheme.spacing12),
                Expanded(child: _buildContent(context)),
                ?_buildAmounts(context),
              ],
            ),
            if (actions.isVisible) ...[
              const SizedBox(height: MallowTheme.spacing12),
              actions,
            ],
          ],
        ),
      ),
    );
  }

  /// The artwork an NFT transfer is moving. Sits *after* the spinner rather
  /// than replacing it so every pending cell keeps the same "still in flight"
  /// affordance regardless of what it is transferring.
  Widget? _buildThumbnail() {
    final url = entry.metadata.imageUrl;
    if (url == null || url.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(left: MallowTheme.spacingSm),
      child: MallowNetworkImage(
        imageUrl: url,
        logicalSize: 60,
        width: _thumbSize,
        height: _thumbSize,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final colors = context.mallowColors;
    final metadata = entry.metadata;
    // Cancelling is the headline once a cancel is in flight: the original
    // action is no longer what the user is waiting on.
    final title = entry.isCancelling ? 'Cancelling…' : metadata.title;
    final subtitle = entry.isExternal
        ? (walletLabel ?? truncateAddress(entry.walletAddress))
        : (entry.isCancelling
              ? (metadata.subtitle ?? metadata.title)
              : metadata.subtitle);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: MallowTheme.editorialQuote.copyWith(color: colors.textPrimary),
        ),
        if (subtitle != null && subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
        ],
      ],
    );
  }

  /// Signed amounts, mirroring the activity rows below. External entries show
  /// none — we know a nonce is stuck, not what it moves.
  Widget? _buildAmounts(BuildContext context) {
    if (entry.isExternal) return null;
    final colors = context.mallowColors;
    final metadata = entry.metadata;

    final String? primary;
    final String? secondary;
    if (metadata.swapOutAmountRaw != null || metadata.swapInAmountRaw != null) {
      // A swap's two legs. The schema carries one `decimals`, so both legs are
      // read at it — placeholder precision until an EVM swap actually ships.
      primary = _formatAmount(
        metadata.swapOutAmountRaw,
        metadata.swapOutSymbol,
        metadata.decimals,
        negative: false,
      );
      secondary = _formatAmount(
        metadata.swapInAmountRaw,
        metadata.swapInSymbol,
        metadata.decimals,
        negative: true,
      );
    } else {
      primary = _formatAmount(
        metadata.amountRaw,
        metadata.tokenSymbol,
        metadata.decimals,
      );
      secondary = null;
    }
    if (primary == null) return null;

    return Padding(
      padding: const EdgeInsets.only(left: MallowTheme.spacingSm),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 140),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              primary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MallowTheme.uiBody.copyWith(
                fontSize: 14,
                color: colors.textPrimary,
              ),
            ),
            if (secondary != null) ...[
              const SizedBox(height: 4),
              Text(
                secondary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MallowTheme.uiBody.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w300,
                  color: colors.warning,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// `+2.03K USDT` from a signed smallest-unit string. [negative] overrides the
/// sign for a leg whose raw amount is stored unsigned (the swap fields).
/// Returns null when there is nothing to render.
String? _formatAmount(
  String? raw,
  String? symbol,
  int? decimals, {
  bool? negative,
}) {
  if (raw == null || raw.isEmpty) return null;
  final value = BigInt.tryParse(raw);
  if (value == null) return null;
  final places = decimals ?? 18;
  final ui =
      double.tryParse(TokenAmount.formatTokenAmount(value.abs(), places)) ?? 0;
  final amount = stripTrailingZeros(
    PriceFormatter.formatCompactAmount(
      ui,
      places,
      maxBaseDecimals: 2,
      maxSubDecimals: 4,
    ),
  );
  final sign = (negative ?? value.isNegative) ? '-' : '+';
  return symbol == null || symbol.isEmpty
      ? '$sign$amount'
      : '$sign$amount $symbol';
}

/// The Speed up / Cancel pills and the rules for when each is offered — shared
/// by the pending cell and the detail sheet so the two can't drift.
///
/// A null handler means the action isn't available to this caller (view-only
/// wallet); the entry's own state decides the rest:
///  - **Speed up** is hidden only for a *derived* external entry — there is no
///    stored payload to re-sign. Once a blind cancel has been broadcast against
///    it the entry has candidates, and speeding up bumps that cancel (matching
///    `PendingEvmTxTracker.speedUp`, which throws for exactly the no-candidate
///    case).
///  - **Cancel** is hidden once the entry is already cancelling, and disabled
///    (with a hint) on an external entry above the lowest stuck nonce, because
///    replacements can only mine in nonce order.
class PendingTxActionRow extends StatelessWidget {
  const PendingTxActionRow({
    required this.entry,
    super.key,
    this.onSpeedUp,
    this.onCancel,
  });

  final PendingEvmTx entry;
  final VoidCallback? onSpeedUp;
  final VoidCallback? onCancel;

  bool get _showSpeedUp =>
      onSpeedUp != null && (!entry.isExternal || entry.candidates.isNotEmpty);

  bool get _showCancel => onCancel != null && !entry.isCancelling;

  /// Whether this row renders anything at all — lets the host skip its own
  /// spacing when it doesn't.
  bool get isVisible => _showSpeedUp || _showCancel;

  @override
  Widget build(BuildContext context) {
    if (!isVisible) return const SizedBox.shrink();
    final cancelEnabled = entry.canCancelNow;
    final colors = context.mallowColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (_showSpeedUp)
              _PendingPill(label: 'Speed up', outlined: true, onTap: onSpeedUp),
            if (_showSpeedUp && _showCancel)
              const SizedBox(width: MallowTheme.spacingSm),
            if (_showCancel)
              _PendingPill(
                label: 'Cancel',
                outlined: false,
                onTap: cancelEnabled ? onCancel : null,
              ),
          ],
        ),
        if (_showCancel && !cancelEnabled) ...[
          const SizedBox(height: 6),
          Text(
            'Cancel the earlier transaction first',
            style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
          ),
        ],
      ],
    );
  }
}

/// Outlined-accent (Speed up) or filled (Cancel) action pill.
class _PendingPill extends StatelessWidget {
  const _PendingPill({
    required this.label,
    required this.outlined,
    required this.onTap,
  });

  final String label;
  final bool outlined;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final foreground = outlined ? colors.accent : colors.textPrimary;

    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing12,
            vertical: MallowTheme.spacingSm,
          ),
          decoration: BoxDecoration(
            color: outlined ? null : colors.bgSurface,
            border: outlined ? Border.all(color: colors.accent) : null,
            borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          ),
          child: Text(
            label,
            style: MallowTheme.uiCaption.copyWith(color: foreground),
          ),
        ),
      ),
    );
  }
}
