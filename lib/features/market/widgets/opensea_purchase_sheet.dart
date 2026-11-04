import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/store_build.dart';
import '../../../core/result/app_failure.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/artwork_preview_header.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../artwork/services/artwork_bloc.dart';
import '../../artwork/widgets/sheets/artwork_sheet_frame.dart';
import '../services/opensea_purchase.dart';

class OpenSeaPurchaseReceipt {
  const OpenSeaPurchaseReceipt(this.hash, this.buyer);
  final String hash;
  final String buyer;
}

/// Quote, approval, and pending-status recovery share one route. Closing the
/// route leaves the submission journal intact for the next visit.
class OpenSeaPurchaseSheet extends StatefulWidget {
  const OpenSeaPurchaseSheet({required this.artwork, this.service, super.key});
  final ArtworkDetails artwork;
  final OpenSeaPurchaseService? service;

  @override
  State<OpenSeaPurchaseSheet> createState() => _OpenSeaPurchaseSheetState();
}

class _OpenSeaPurchaseSheetState extends State<OpenSeaPurchaseSheet> {
  late final _service = widget.service ?? sl<OpenSeaPurchaseService>();
  OpenSeaReview? _review;
  PendingOpenSeaPurchase? _pending;
  OpenSeaPurchaseReceipt? _receipt;
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
        if (resolution == OpenSeaResolution.pending) {
          setState(
            () => _error =
                'A purchase is awaiting confirmation. Check its status before buying again.',
          );
          return;
        }
        setState(() => _pending = null);
        if (pending.mintAccount == widget.artwork.mintAccount) {
          if (resolution == OpenSeaResolution.confirmed) {
            setState(
              () => _receipt = OpenSeaPurchaseReceipt(
                _service.confirmedHash ?? pending.hash,
                pending.buyer,
              ),
            );
          } else {
            setState(
              () => _error = resolution == OpenSeaResolution.unverified
                  ? openSeaUnverifiedMessage
                  : 'The purchase failed or was cancelled on Ethereum. Refresh the listing before trying again.',
            );
          }
          return;
        }
      }
      final review = await _service.review(widget.artwork);
      if (mounted) setState(() => _review = review);
    } catch (error) {
      if (mounted) setState(() => _error = openSeaPurchaseError(error));
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
      final hash = await _service.buy(
        review,
        onSigned: () {
          if (mounted) setState(() => _stage = 'Confirming on Ethereum…');
        },
      );
      if (mounted) {
        setState(() => _receipt = OpenSeaPurchaseReceipt(hash, review.buyer));
      }
    } catch (error) {
      final failure = AppFailure.from(error);
      if (mounted) {
        if (failure.isFlowDisabled) handleFlowDisabled(context, failure);
        if (!mounted) return;
        setState(() {
          _error = openSeaPurchaseError(error);
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
    if (!showNftCommerce) {
      return ArtworkSheetFrame(
        child: Text(
          'In-app purchases are unavailable in this build.',
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
      );
    }
    final quote = _review?.quote;
    final shortfall = quote == null ? null : _review!.shortfall;
    String eth(String amount) => '${formatOpenSeaEth(amount)} ETH';

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
                  row('Seller proceeds', eth(quote.sellerProceedsWei)),
                  row(
                    'OpenSea fees',
                    eth(
                      quote.marketplaceFees
                          .fold(
                            BigInt.zero,
                            (sum, fee) => sum + openSeaWei(fee.amountWei),
                          )
                          .toString(),
                    ),
                  ),
                  row(
                    'Creator fees',
                    eth(
                      quote.creatorFees
                          .fold(
                            BigInt.zero,
                            (sum, fee) => sum + openSeaWei(fee.amountWei),
                          )
                          .toString(),
                    ),
                  ),
                  if (openSeaWei(quote.buyerPaidExtraWei) > BigInt.zero)
                    row('Additional payment', eth(quote.buyerPaidExtraWei)),
                  row('Purchase price', eth(quote.totalWei)),
                  row(
                    'Maximum network fee',
                    eth(_review!.networkFeeWei.toString()),
                  ),
                  const Divider(),
                  row(
                    'Maximum total',
                    eth(
                      (openSeaWei(quote.totalWei) + _review!.networkFeeWei)
                          .toString(),
                    ),
                  ),
                  if (quote.tokenStandard.value == 'erc1155')
                    row(
                      'Copies purchased',
                      '1 of ${quote.listedCopies} listed',
                    ),
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
                    'Transaction: ${_pending!.hash}',
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
                if (!_busy && _error != null && showNftCommerce)
                  MallowButton(
                    label: 'View on OpenSea',
                    variant: MallowButtonVariant.text,
                    onPressed: () {
                      final parts = widget.artwork.mintAccount.split('-');
                      if (parts.length == 2) {
                        launchUrl(
                          Uri.https(
                            'opensea.io',
                            '/assets/ethereum/${parts[0]}/${parts[1]}',
                          ),
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
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
