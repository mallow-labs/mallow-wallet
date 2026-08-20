import 'package:flutter/material.dart';

import '../../core/network/solana_rpc_service.dart';
import '../theme/mallow_theme.dart';
import 'mallow_button.dart';
import 'mallow_sheet.dart';
import 'mallow_svg_icon.dart';
import 'sheet_drag_handle.dart';

/// Shared chrome for transaction-confirmation bottom sheets.
///
/// Wraps the handle bar, title, body slots, optional simulation banner, and
/// Cancel/Confirm CTA row that every confirmation sheet (market, swap, mint,
/// send) was reimplementing by hand. Ledger signing and bloc plumbing stay
/// owned by the caller — this widget is pure UI.
class GenericConfirmationSheet extends StatelessWidget {
  const GenericConfirmationSheet({
    required this.title,
    required this.confirmLabel,
    required this.onConfirm,
    super.key,
    this.cancelLabel = 'Cancel',
    this.onCancel,
    this.confirmVariant = MallowButtonVariant.primary,
    this.confirmEnabled = true,
    this.confirmLoading = false,
    this.body = const <Widget>[],
    this.simulation,
    this.confirmSlot,
    this.padding = const EdgeInsets.all(MallowTheme.spacing20),
    this.gapBeforeButtons = MallowTheme.spacingLg,
    this.showHandle = true,
    this.backgroundColor,
    this.topRadius = 20,
  });

  final String title;

  /// Default confirm-button label. Ignored when [confirmSlot] is provided.
  final String confirmLabel;

  /// Default confirm tap handler. Ignored when [confirmSlot] is provided.
  final VoidCallback onConfirm;

  final String cancelLabel;

  /// Defaults to `Navigator.of(context).pop()`.
  final VoidCallback? onCancel;

  final MallowButtonVariant confirmVariant;
  final bool confirmEnabled;
  final bool confirmLoading;

  /// Body widgets rendered between the title and the CTA row, in order.
  /// Spacing between body widgets is the caller's responsibility — that
  /// keeps mixed layouts (cards, route previews, dividers) flexible.
  final List<Widget> body;

  /// Optional simulation banner. Renders nothing while simulating or on
  /// success; renders a warning card when [SimulationBannerState.result]
  /// signals failure. A [MallowTheme.spacingMd] gap is inserted above it.
  final SimulationBannerState? simulation;

  /// Override the standard CTA: when set, the [Cancel | Confirm] row is
  /// replaced with `[Cancel | confirmSlot]`. Use for callers that need to
  /// wrap the confirm button in a `BlocBuilder` for balance checks.
  final Widget? confirmSlot;

  final EdgeInsets padding;

  /// Vertical space between the last body widget and the button row.
  final double gapBeforeButtons;

  /// Hide for hosts (like [showMallowSheet]) that already render their own
  /// drag handle.
  final bool showHandle;

  /// Defaults to `colors.bgPrimary` — pass a [MallowColors] field directly
  /// when a sheet wants the mint cost-review's lighter `bgSurface`.
  final Color? backgroundColor;

  /// Top corner radius for the sheet. Mint uses [MallowTheme.popupRadius]
  /// (12) to match its older popup chrome; market/swap/send use 20.
  final double topRadius;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final hasSimulationBanner = simulation != null && simulation!._shouldRender;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor ?? colors.bgPrimary,
        borderRadius: BorderRadius.vertical(top: Radius.circular(topRadius)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHandle) const SheetDragHandle(),
          Text(
            title,
            style: MallowTheme.editorialSubhead.copyWith(
              color: colors.textPrimary,
            ),
            textAlign: TextAlign.left,
          ),
          const SizedBox(height: MallowTheme.spacingLg),
          // The sheet grows as the body does (a simulation warning appearing,
          // a long error) and only scrolls once that growth hits
          // [maxSheetHeight]. The CTA row below stays pinned either way.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...body,
                  if (hasSimulationBanner) ...[
                    const SizedBox(height: MallowTheme.spacingMd),
                    ConfirmationSimulationBanner(state: simulation!),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: gapBeforeButtons),
          Row(
            children: [
              Expanded(
                child: MallowButton(
                  label: cancelLabel,
                  onPressed: onCancel ?? () => Navigator.of(context).pop(),
                  variant: MallowButtonVariant.secondary,
                ),
              ),
              const SizedBox(width: MallowTheme.spacingMd),
              Expanded(
                child:
                    confirmSlot ??
                    MallowButton(
                      label: confirmLabel,
                      variant: confirmVariant,
                      isLoading: confirmLoading,
                      onPressed: confirmEnabled && !confirmLoading
                          ? onConfirm
                          : null,
                    ),
              ),
            ],
          ),
          SizedBox(height: sheetBottomInset(context)),
        ],
      ),
    );
  }
}

/// Bordered surface used for the "details" block (price/fee/total rows,
/// recipient + amount, swap rate, etc.).
class ConfirmationDetailCard extends StatelessWidget {
  const ConfirmationDetailCard({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      padding: const EdgeInsets.all(MallowTheme.spacingMd),
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: BorderRadius.circular(MallowTheme.radiusMd),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// Label/value row used inside [ConfirmationDetailCard]. Pass [value] for a
/// plain text right side or [valueChild] when the right side needs a custom
/// widget (shimmer placeholder, multi-segment text, etc.).
class ConfirmationDetailRow extends StatelessWidget {
  const ConfirmationDetailRow({
    required this.label,
    this.value,
    this.valueChild,
    this.valueColor,
    this.textStyle,
    super.key,
  }) : assert(
         value != null || valueChild != null,
         'Provide either value (String) or valueChild (Widget).',
       );

  final String label;
  final String? value;
  final Widget? valueChild;
  final Color? valueColor;

  /// Base style for the label/value text. Defaults to [MallowTheme.uiBody];
  /// disclosure breakdowns pass [MallowTheme.uiCaption] so the rows match
  /// their smaller section header.
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final baseStyle = textStyle ?? MallowTheme.uiBody;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: baseStyle),
        Flexible(
          child:
              valueChild ??
              Text(
                value!,
                style: baseStyle.copyWith(color: valueColor),
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
              ),
        ),
      ],
    );
  }
}

/// Snapshot of a confirmation sheet's simulation state used by
/// [ConfirmationSimulationBanner].
///
/// Loading and success are intentionally invisible — only a failed
/// simulation surfaces a warning so the review sheet stays quiet on the
/// happy path.
class SimulationBannerState {
  const SimulationBannerState({
    required this.isSimulating,
    required this.result,
    this.warningTitle = 'Transaction may fail',
    this.proceedHint =
        'You can still proceed, but the transaction might fail on-chain.',
  });

  final bool isSimulating;
  final SimulationResult? result;

  /// Heading shown above the simulation error text. Defaults to the
  /// generic transaction copy; swap/market override with their own.
  final String warningTitle;

  /// Body copy reminding the user the warning isn't blocking.
  final String proceedHint;

  bool get _shouldRender => !isSimulating && result != null && !result!.success;
}

/// Inline warning rendered when a [SimulationBannerState] indicates failure.
/// Returns a [SizedBox.shrink] while loading or on success.
class ConfirmationSimulationBanner extends StatelessWidget {
  const ConfirmationSimulationBanner({required this.state, super.key});

  final SimulationBannerState state;

  @override
  Widget build(BuildContext context) {
    if (!state._shouldRender) return const SizedBox.shrink();
    final warning = context.mallowColors.warning;
    final result = state.result!;
    return Container(
      padding: const EdgeInsets.all(MallowTheme.spacing12),
      decoration: BoxDecoration(
        color: warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(MallowTheme.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MallowSvgIcon(
                'assets/icons/alert_triangle.svg',
                width: 20,
                height: 20,
                color: warning,
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Expanded(
                child: Text(
                  state.warningTitle,
                  style: MallowTheme.uiBody.copyWith(color: warning),
                ),
              ),
            ],
          ),
          const SizedBox(height: MallowTheme.spacingXs),
          Text(
            result.error ?? 'Unknown error',
            style: MallowTheme.uiMeta.copyWith(color: warning),
          ),
          const SizedBox(height: MallowTheme.spacingXs),
          Text(
            state.proceedHint,
            style: MallowTheme.uiMeta.copyWith(
              color: context.mallowColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
