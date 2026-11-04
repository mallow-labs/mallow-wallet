import 'package:flutter/material.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../core/result/app_failure.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/artwork_preview_header.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../artwork/services/artwork_bloc.dart';
import '../../artwork/widgets/sheets/artwork_sheet_frame.dart';
import '../services/magic_eden_purchase.dart';

class MagicEdenPurchaseReceipt {
  const MagicEdenPurchaseReceipt(this.signature, this.buyer);
  final String signature;
  final String buyer;
}

/// Quote, approval, and pending-status recovery share one route. Closing the
/// route leaves the submission journal intact for the next visit.
class MagicEdenPurchaseSheet extends StatefulWidget {
  const MagicEdenPurchaseSheet({
    required this.artwork,
    this.service,
    super.key,
  });
  final ArtworkDetails artwork;
  final MagicEdenPurchaseService? service;

  @override
  State<MagicEdenPurchaseSheet> createState() => _MagicEdenPurchaseSheetState();
}

class _MagicEdenPurchaseSheetState extends State<MagicEdenPurchaseSheet> {
  late final _service = widget.service ?? sl<MagicEdenPurchaseService>();
  MagicEdenReview? _review;
  PendingMagicEdenPurchase? _pending;
  MagicEdenPurchaseReceipt? _receipt;
  String? _error;
  bool _busy = false;
  String _stage = 'Loading purchase quote…';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _review = null;
      _stage = 'Loading purchase quote…';
    });
    try {
      final pending = await _service.pending();
      if (mounted) setState(() => _pending = pending);
      if (pending != null) {
        final resolution = await _service.resolve(pending);
        if (!mounted) return;
        if (resolution == MagicEdenResolution.pending) {
          setState(
            () => _error =
                'A purchase is awaiting confirmation. Check its status before buying again.',
          );
          return;
        }
        setState(() => _pending = null);
        if (pending.mintAccount == widget.artwork.mintAccount) {
          if (resolution == MagicEdenResolution.confirmed) {
            setState(
              () => _receipt = MagicEdenPurchaseReceipt(
                pending.signature,
                pending.buyer,
              ),
            );
          } else {
            setState(
              () => _error = switch (resolution) {
                MagicEdenResolution.failed =>
                  'The purchase failed on chain. Refresh the listing before trying again.',
                MagicEdenResolution.unknown => magicEdenUnknownMessage,
                _ =>
                  'The purchase expired without landing. Refresh the listing before trying again.',
              },
            );
          }
          return;
        }
      }
      final review = await _service.review(widget.artwork.mintAccount);
      if (mounted) setState(() => _review = review);
    } catch (error) {
      if (mounted) setState(() => _error = AppFailure.from(error).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _buy() async {
    final review = _review;
    if (_busy || review == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _stage = 'Approve the purchase in your wallet…';
    });
    try {
      final signature = await _service.buy(
        review,
        onSigned: () {
          if (mounted) setState(() => _stage = 'Confirming on Solana…');
        },
      );
      if (mounted) {
        setState(
          () => _receipt = MagicEdenPurchaseReceipt(signature, review.buyer),
        );
      }
    } catch (error) {
      final failure = AppFailure.from(error);
      if (mounted) {
        if (failure.isFlowDisabled) handleFlowDisabled(context, failure);
        if (!mounted) return;
        setState(() {
          _error = failure.message;
          if (!failure.isCancelled) _review = null;
        });
      }
      try {
        final pending = await _service.pending();
        if (mounted) setState(() => _pending = pending);
      } catch (_) {
        if (mounted) {
          setState(
            () => _error =
                'Could not read the pending purchase. Check its status before trying again.',
          );
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final quote = _review?.quote;
    final shortfall = quote == null ? null : magicEdenShortfall(quote);
    String payment(String amount) =>
        '${formatMagicEdenAmount(amount, quote!.currencyDecimals)} ${quote.currencySymbol}';
    String sol(String amount) => '${formatMagicEdenAmount(amount, 9)} SOL';
    final total = quote == null
        ? null
        : quote.currencyMint == solMint
        ? sol(quote.totalSolDebitLamports)
        : '${payment(quote.totalPaymentAmount)} + ${sol(quote.totalSolDebitLamports)}';

    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingXs),
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
          const SizedBox(width: MallowTheme.spacingSm),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );

    return PopScope(
      canPop: !_busy && _receipt == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy && _receipt != null) {
          Navigator.of(context).pop(_receipt);
        }
      },
      child: SingleChildScrollView(
        child: ArtworkSheetFrame(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _receipt == null ? 'Buy artwork' : 'Artwork collected',
                style: MallowTheme.uiTitle.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: MallowTheme.spacingMd),
              ArtworkPreviewHeader(
                title: widget.artwork.title,
                imageUrl: widget.artwork.imageUrl.isEmpty
                    ? null
                    : widget.artwork.imageUrl,
                username: widget.artwork.artistUsername,
                artistName: widget.artwork.artistName,
                nsfw: widget.artwork.nsfw,
              ),
              const SizedBox(height: MallowTheme.spacingMd),
              if (_receipt != null) ...[
                MallowButton(
                  label: 'Done',
                  onPressed: () => Navigator.of(context).pop(_receipt),
                  isFullWidth: true,
                ),
              ] else ...[
                if (quote != null) ...[
                  row('Seller price', payment(quote.sellerPrice)),
                  if (magicEdenAmount(quote.creatorRoyalty) > BigInt.zero)
                    row('Creator royalty', payment(quote.creatorRoyalty)),
                  row('Magic Eden fee', payment(quote.magicEdenFee)),
                  row('mallow fee', sol(quote.mallowFeeLamports)),
                  row('Estimated network fee', sol(quote.networkFeeLamports)),
                  row('Account rent', sol(quote.rentLamports)),
                  const Divider(),
                  row('Total cost', total!),
                  row('Paying with', _review!.buyer),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: MallowTheme.spacingSm,
                    ),
                    child: Text(
                      _error!,
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.error,
                      ),
                    ),
                  ),
                if (_pending != null)
                  SelectableText(
                    'Signature: ${_pending!.signature}',
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                if (_busy)
                  Text(
                    _stage,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                const SizedBox(height: MallowTheme.spacingMd),
                MallowButton(
                  label: _pending != null
                      ? 'Check transaction status'
                      : quote == null
                      ? 'Refresh quote'
                      : shortfall ?? 'Buy',
                  onPressed: _busy || shortfall != null
                      ? null
                      : _pending != null || quote == null
                      ? _refresh
                      : _buy,
                  isLoading: _busy,
                  isFullWidth: true,
                ),
                if (!_busy && quote != null)
                  MallowButton(
                    label: 'Refresh quote',
                    variant: MallowButtonVariant.text,
                    onPressed: _refresh,
                  ),
                if (!_busy)
                  MallowButton(
                    label: 'Close',
                    variant: MallowButtonVariant.text,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
