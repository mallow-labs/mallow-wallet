import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/artwork_subject_header.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../models/market_price.dart';

/// Bottom sheet for entering an offer amount: the
/// artwork subject header, a single "Total Offer" pill combining the
/// currency logo, the amount input, and a live USD equivalent, plus the
/// current highest offer for reference.
/// Returns a [MarketPrice] (raw atomic amount + currency mint) the
/// caller can hand straight to `MarketEvent.makeOfferV2` / `placeBid`.
/// Returns null if cancelled.
class MakeOfferSheet extends StatefulWidget {
  const MakeOfferSheet({
    required this.artworkTitle,
    required this.mintAccount,
    super.key,
    this.currencyMint,
    this.currentBestOffer,
    this.artworkImageUrl,
    this.artistUsername,
    this.nsfw = false,
    this.onNext,
    this.isSubmitting = false,
  });

  final String artworkTitle;
  final String mintAccount;

  /// When provided, tapping "Next" reports the entered price via this
  /// callback instead of popping the route — used by [MarketActionFlowSheet]
  /// to advance to the confirmation step within the same sheet. When null,
  /// the sheet pops with the [MarketPrice] for standalone use.
  final ValueChanged<MarketPrice>? onNext;

  /// True while the host prepares the transaction after "Next" — shows the
  /// CTA spinner and blocks re-entry until the confirmation step takes over.
  final bool isSubmitting;

  /// Mint address of the listing's currency. Null = SOL.
  final String? currencyMint;

  /// Current highest offer in the same [currencyMint], or null when no
  /// offers exist / the data isn't currency-aware. Surfaced as the
  /// "Current highest offer" caption — sourced from
  /// the same `/v1/offers` data the webapp uses.
  final MarketPrice? currentBestOffer;

  final String? artworkImageUrl;
  final String? artistUsername;

  /// Moderation flag for the subject preview — blurs it (with an eye-icon
  /// reveal) unless the viewer's show-NSFW setting is on.
  final bool nsfw;

  @override
  State<MakeOfferSheet> createState() => _MakeOfferSheetState();
}

class _MakeOfferSheetState extends State<MakeOfferSheet> {
  final _amountController = TextEditingController();
  final _focusNode = FocusNode();

  late final MallowToken _token;

  /// User-entered amount in display units (e.g. "1.5" SOL → 1.5).
  double? _displayAmount;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _token = tokenByMint(widget.currencyMint) ?? tokenByMint(solMint)!;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _amountController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onAmountChanged(String value) {
    final amount = double.tryParse(value);
    setState(() {
      _displayAmount = amount;
      _errorMessage = _validateAmount(amount);
    });
  }

  String? _validateAmount(double? amount) {
    if (amount == null || amount <= 0) {
      return null; // No error shown for empty/zero, just disable button
    }
    if (amount < _token.minListingDisplay) {
      return 'Minimum offer is ${_token.minListingDisplay} ${_token.symbol}';
    }
    return null;
  }

  bool get _isValid =>
      _displayAmount != null && _displayAmount! > 0 && _errorMessage == null;

  void _onSubmit() {
    if (!_isValid || widget.isSubmitting) return;
    final raw = _token.displayToRaw(_displayAmount!).toDouble();
    final price = MarketPrice(rawAmount: raw, currencyMint: _token.mint);
    final onNext = widget.onNext;
    if (onNext != null) {
      onNext(price);
    } else {
      Navigator.of(context).pop(price);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final priceService = sl<TokenPriceService>();
    final best = widget.currentBestOffer;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        padding: const EdgeInsets.all(MallowTheme.spacing20),
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetDragHandle(),
            Text(
              'Make Offer',
              style: MallowTheme.editorialSubhead.copyWith(
                color: colors.textPrimary,
              ),
              textAlign: TextAlign.left,
            ),
            const SizedBox(height: MallowTheme.spacingLg),
            ArtworkSubjectHeader(
              title: widget.artworkTitle,
              imageUrl: widget.artworkImageUrl,
              username: widget.artistUsername,
              nsfw: widget.nsfw,
            ),
            const SizedBox(height: MallowTheme.spacingLg),
            // Total Offer pill: a single field combining
            // the currency logo, the amount input, and a live USD equivalent.
            // Currency is fixed to the listing's mint — no picker until more
            // mints are supported, so no chevron affordance.
            Text(
              'Total Offer',
              style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            MallowPillField(
              controller: _amountController,
              focusNode: _focusNode,
              hintText: '0',
              errorText: _errorMessage,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
              ],
              onChanged: _onAmountChanged,
              onSubmitted: (_) => _onSubmit(),
              prefix: tokenImageWidget(
                mint: _token.mint,
                size: 20,
                enlargeChainGlyph: true,
              ),
              suffix: ValueListenableBuilder<Map<String, double>>(
                valueListenable: priceService.prices,
                builder: (context, _, _) {
                  final amount = _displayAmount;
                  final usd = amount == null
                      ? null
                      : priceService.usdValueOfRaw(
                          _token.displayToRaw(amount),
                          _token.mint,
                        );
                  if (usd == null) return const SizedBox.shrink();
                  return Text(
                    '~\$${usd.toStringAsFixed(2)}',
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  );
                },
              ),
            ),
            if (best != null) ...[
              const SizedBox(height: MallowTheme.spacingMd),
              Text(
                'Current highest offer: '
                '${PriceFormatter.formatRawAmount(best.rawAmount, _token.mint)} '
                '${_token.symbol}',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: MallowTheme.spacingLg),
            MallowButton(
              label: 'Next',
              onPressed: _isValid && !widget.isSubmitting ? _onSubmit : null,
              isLoading: widget.isSubmitting,
              isFullWidth: true,
            ),
            SizedBox(height: sheetBottomInset(context, includeKeyboard: false)),
          ],
        ),
      ),
    );
  }
}
