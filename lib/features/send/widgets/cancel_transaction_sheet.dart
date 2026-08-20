import 'package:flutter/material.dart';

import '../../../core/services/pending_evm_tx.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// Data resolved before the cancel confirmation can quote the replacement.
@immutable
class CancelTransactionSheetData {
  const CancelTransactionSheetData({
    required this.maxFeePerGas,
    required this.balanceWei,
    required this.ethPriceUsd,
    required this.caps,
  });

  final BigInt maxFeePerGas;
  final BigInt balanceWei;
  final double? ethPriceUsd;

  /// The exact caps to pass to the tracker after the user confirms.
  final EvmFeeCaps caps;
}

/// Confirmation sheet for cancelling a pending EVM transaction. Returns
/// true when the user confirms, null/false otherwise.
///
/// Cancelling is itself a transaction — a 0-ETH self-send that consumes the
/// stuck nonce — so the sheet's job is to price that replacement
/// ([kCancelGasLimit] × [maxFeePerGas]) and refuse to start one the wallet
/// can't pay for.
///
/// There is deliberately **no "Switch wallet" action** (unlike the send/buy
/// sheets it otherwise resembles): only the wallet that owns the stuck nonce
/// can replace it, so offering another wallet would be offering something that
/// cannot work.
///
/// [feeMayIncrease] adds the escalation caveat used for transactions broadcast
/// from another device: their fees are unknown, so the cancel starts at market
/// and the tracker walks the bid up until the node accepts it.
Future<bool?> showCancelTransactionSheet(
  BuildContext context, {
  required String walletAddress,
  required BigInt maxFeePerGas,
  required BigInt balanceWei,
  double? ethPriceUsd,
  bool feeMayIncrease = false,
}) {
  return showMallowSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => CancelTransactionSheet(
      walletAddress: walletAddress,
      maxFeePerGas: maxFeePerGas,
      balanceWei: balanceWei,
      ethPriceUsd: ethPriceUsd,
      feeMayIncrease: feeMayIncrease,
    ),
  );
}

/// Opens the cancel confirmation immediately while [preparation] resolves its
/// fee quote and balance. The same sheet route changes from a loading state to
/// [CancelTransactionSheet] once the data arrives.
Future<bool?> showCancelTransactionSheetLoading(
  BuildContext context, {
  required String walletAddress,
  required Future<CancelTransactionSheetData> preparation,
  required ValueChanged<Object> onPreparationError,
  bool feeMayIncrease = false,
}) {
  return showMallowSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CancelTransactionSheetLoader(
      walletAddress: walletAddress,
      preparation: preparation,
      onPreparationError: onPreparationError,
      feeMayIncrease: feeMayIncrease,
    ),
  );
}

class _CancelTransactionSheetLoader extends StatefulWidget {
  const _CancelTransactionSheetLoader({
    required this.walletAddress,
    required this.preparation,
    required this.onPreparationError,
    required this.feeMayIncrease,
  });

  final String walletAddress;
  final Future<CancelTransactionSheetData> preparation;
  final ValueChanged<Object> onPreparationError;
  final bool feeMayIncrease;

  @override
  State<_CancelTransactionSheetLoader> createState() =>
      _CancelTransactionSheetLoaderState();
}

class _CancelTransactionSheetLoaderState
    extends State<_CancelTransactionSheetLoader> {
  var _reportedError = false;

  void _reportError(Object error) {
    if (_reportedError) return;
    _reportedError = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onPreparationError(error);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CancelTransactionSheetData>(
      future: widget.preparation,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          _reportError(snapshot.error!);
          return _cancelTransactionSheetLoading(context);
        }
        final data = snapshot.data;
        if (data == null) return _cancelTransactionSheetLoading(context);
        return CancelTransactionSheet(
          walletAddress: widget.walletAddress,
          maxFeePerGas: data.maxFeePerGas,
          balanceWei: data.balanceWei,
          ethPriceUsd: data.ethPriceUsd,
          feeMayIncrease: widget.feeMayIncrease,
        );
      },
    );
  }
}

Widget _cancelTransactionSheetLoading(BuildContext context) {
  final colors = context.mallowColors;
  return Container(
    decoration: BoxDecoration(
      color: colors.bgPrimary,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(MallowTheme.popupRadius),
      ),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetDragHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            MallowTheme.spacing20,
            MallowTheme.spacing12,
            MallowTheme.spacing20,
            MallowTheme.spacing20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Cancel Transaction', style: MallowTheme.editorialSection),
              const SizedBox(height: MallowTheme.spacingXl),
              SizedBox.square(
                dimension: 32,
                child: CircularProgressIndicator(
                  color: colors.accent,
                  strokeWidth: 2,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: sheetBottomInset(context, includeKeyboard: false)),
      ],
    ),
  );
}

/// Body of [showCancelTransactionSheet]; public so widget tests can mount it
/// without a modal route.
class CancelTransactionSheet extends StatelessWidget {
  const CancelTransactionSheet({
    required this.walletAddress,
    required this.maxFeePerGas,
    required this.balanceWei,
    this.ethPriceUsd,
    this.feeMayIncrease = false,
    super.key,
  });

  /// Wallet that broadcast the stuck transaction — the only one that can
  /// replace it.
  final String walletAddress;

  /// Per-gas cap the cancel will be signed with; the displayed fee is the
  /// worst case, [kCancelGasLimit] × this.
  final BigInt maxFeePerGas;

  /// The wallet's ETH balance, gating Confirm.
  final BigInt balanceWei;
  final double? ethPriceUsd;
  final bool feeMayIncrease;

  /// Worst-case cancel cost in wei.
  BigInt get _feeWei => BigInt.from(kCancelGasLimit) * maxFeePerGas;

  bool get _canAfford => balanceWei >= _feeWei;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final feeEth = _feeWei.toDouble() / 1e18;
    final price = ethPriceUsd;

    return Container(
      decoration: BoxDecoration(
        color: colors.bgPrimary,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetDragHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MallowTheme.spacing20,
              MallowTheme.spacing12,
              MallowTheme.spacing20,
              MallowTheme.spacing20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context),
                const SizedBox(height: MallowTheme.spacingLg),
                _explainer(context),
                const SizedBox(height: MallowTheme.spacingLg),
                Text(
                  'Fee',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: MallowTheme.spacing12),
                _feeRow(context, feeEth: feeEth, price: price),
                const SizedBox(height: MallowTheme.spacing12),
                _walletRow(context),
                if (!_canAfford) ...[
                  const SizedBox(height: MallowTheme.spacingSm),
                  Text(
                    'Not enough ETH to pay the cancellation fee.',
                    style: MallowTheme.uiCaption.copyWith(color: colors.error),
                  ),
                ],
                const SizedBox(height: MallowTheme.spacingLg),
                _actions(context),
              ],
            ),
          ),
          SizedBox(height: sheetBottomInset(context, includeKeyboard: false)),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Row(
      children: [
        TapTargetExpander(
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(right: MallowTheme.spacing12),
              child: MallowSvgIcon(
                'assets/icons/arrow_left.svg',
                width: 16,
                height: 16,
                color: context.mallowColors.textPrimary,
              ),
            ),
          ),
        ),
        Text('Cancel Transaction', style: MallowTheme.editorialSection),
      ],
    );
  }

  Widget _explainer(BuildContext context) {
    final colors = context.mallowColors;
    final copy = StringBuffer(
      'Cancelling submits a replacement transaction to the network. A small '
      'fee is required. Cancellation is not guaranteed.',
    );
    if (feeMayIncrease) {
      // Blind cancel: the stuck transaction's fees are unknown, so the bid is
      // raised until the node accepts it — each raise is a fresh signature.
      copy.write(
        ' This transaction was sent from another device, so the fee may adjust '
        'upward and you may be asked to approve more than once.',
      );
    }
    return Container(
      padding: const EdgeInsets.all(MallowTheme.spacing12),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.radiusSm),
      ),
      child: Text(
        copy.toString(),
        style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
      ),
    );
  }

  Widget _feeRow(
    BuildContext context, {
    required double feeEth,
    required double? price,
  }) {
    final colors = context.mallowColors;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacingMd),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
      ),
      child: Row(
        children: [
          MallowSvgIcon(
            'assets/icons/ethereum.svg',
            width: 16,
            height: 16,
            color: colors.textPrimary,
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          Expanded(
            child: Text(
              '${stripTrailingZeros(feeEth.toStringAsFixed(9))} ETH',
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
          ),
          if (price != null)
            Text(
              '~\$${(feeEth * price).toStringAsFixed(2)}',
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _walletRow(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      children: [
        Text(
          'Your wallet: ',
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
        Expanded(
          child: Text(
            truncateAddress(walletAddress),
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: MallowButton(
            label: 'Cancel',
            variant: MallowButtonVariant.secondary,
            onPressed: () => Navigator.of(context).pop(),
            isFullWidth: true,
          ),
        ),
        const SizedBox(width: MallowTheme.spacingSm),
        Expanded(
          child: MallowButton(
            label: 'Confirm',
            enabled: _canAfford,
            onPressed: () => Navigator.of(context).pop(true),
            isFullWidth: true,
          ),
        ),
      ],
    );
  }
}
