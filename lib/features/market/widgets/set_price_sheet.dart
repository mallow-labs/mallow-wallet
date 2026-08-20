import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../core/services/token_price_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/balance_check.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/artwork_subject_header.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../models/market_price.dart';

/// Bottom sheet for entering the purchase price of a SYOP ("set your own
/// price") listing — the buyer names the amount because the listing's on-chain
/// price is 0. Port of the webapp's `BuyEditionModal` "Set your price" field
/// (`ChoosePriceToken` with `isSyop`), which refuses an empty price rather than
/// buying at 0.
///
/// Scaffolded like [MakeOfferSheet] / [PlaceBidSheet] (drag handle, subject
/// header, one amount pill, "Next" CTA) and hosted as [MarketActionFlowSheet]'s
/// entry step, so the entered amount flows into the same confirm → sign →
/// broadcast pipeline. The amount is validated (positive, at/above the
/// currency's minimum listing price) and balance-checked before "Next" enables,
/// then handed to `MarketEvent.buy(buyerSetsPrice: true)`, which sends it as
/// the wire `maxPrice`.
class SetPriceSheet extends StatefulWidget {
  const SetPriceSheet({
    required this.artworkTitle,
    required this.mintAccount,
    required this.tokenBalanceBloc,
    super.key,
    this.currencyMint,
    this.artworkImageUrl,
    this.artistUsername,
    this.nsfw = false,
    this.onNext,
    this.isSubmitting = false,
  });

  final String artworkTitle;
  final String mintAccount;

  /// Balances of the active signing wallet, used for the balance line and the
  /// affordability gate. Passed explicitly because the modal route this sheet
  /// runs in doesn't inherit the screen-scoped provider (same reason
  /// [PlaceBidSheet] takes one).
  final TokenBalanceBloc tokenBalanceBloc;

  /// When provided, tapping "Next" reports the entered price via this callback
  /// instead of popping the route — used by `MarketActionFlowSheet` to advance
  /// to the confirmation step within the same sheet.
  final ValueChanged<MarketPrice>? onNext;

  /// True while the host prepares the transaction after "Next" — shows the CTA
  /// spinner and blocks re-entry until the confirmation step takes over.
  final bool isSubmitting;

  /// Mint address of the listing's currency. Null = SOL. A SYOP listing still
  /// fixes the currency; only the amount is the buyer's choice.
  final String? currencyMint;

  final String? artworkImageUrl;
  final String? artistUsername;

  /// Moderation flag for the subject preview — blurs it (with an eye-icon
  /// reveal) unless the viewer's show-NSFW setting is on.
  final bool nsfw;

  @override
  State<SetPriceSheet> createState() => _SetPriceSheetState();
}

class _SetPriceSheetState extends State<SetPriceSheet> {
  final _amountController = TextEditingController();
  final _focusNode = FocusNode();

  late final MallowToken _token;

  /// User-entered amount in display units (e.g. "1.5" SOL → 1.5). Null while
  /// the field is empty or unparseable — which keeps the CTA disabled, so an
  /// empty price can never reach the tx builder. `0` is a real entered value,
  /// not "empty": see [_isValid].
  double? _displayAmount;

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
    setState(() => _displayAmount = double.tryParse(value));
  }

  /// Valid as soon as *something* parseable is entered — **including `0`**.
  ///
  /// A buyer-named price carries no floor: `BuyEditionModal.onBuyClick` refuses
  /// only a *missing* price (`buyerUIPrice == null` → "Please enter a price")
  /// and an entered `0` settles at 0, which is a legitimate SYOP outcome the
  /// artist opted into. Do NOT add [MallowToken.minListingDisplay] here — that
  /// is a floor on what a *seller* may list for, not on what a buyer may offer.
  bool get _isValid => _displayAmount != null;

  /// Affordability of the *entered* amount (not the listing's 0) against the
  /// active signer's balances — see [checkBalanceOrSkip] for the gas-reserve
  /// rules and for why an empty input or unloaded balances read as sufficient
  /// (never false-disable).
  BalanceCheckResult _balanceResult(TokenBalanceState balanceState) {
    final amount = _displayAmount;
    return checkBalanceOrSkip(
      paymentMint: _token.mint,
      requiredRawAmount: amount == null || amount <= 0
          ? null
          : _token.displayToRaw(amount),
      balanceState: balanceState,
    );
  }

  /// The signer's balance of the listing currency in display units, or null
  /// until balances load (the line is omitted rather than showing a wrong
  /// zero).
  double? _balanceDisplay(TokenBalanceState balanceState) {
    if (balanceState is! TokenBalanceLoaded) return null;
    return balanceState.tokens
            .firstWhereOrNull((t) => t.mint == _token.mint)
            ?.uiBalance ??
        0;
  }

  void _onSubmit() {
    if (!_isValid || widget.isSubmitting) return;
    // Keyboard "done" reaches here without going through the CTA's enabled
    // state, so re-check affordability against the live balances.
    if (!_balanceResult(widget.tokenBalanceBloc.state).sufficient) return;
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
              'Set Your Price',
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
            Text(
              'Your price',
              style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            MallowPillField(
              controller: _amountController,
              focusNode: _focusNode,
              hintText: 'Enter your price',
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
            BlocBuilder<TokenBalanceBloc, TokenBalanceState>(
              bloc: widget.tokenBalanceBloc,
              builder: (context, balanceState) {
                final balance = _balanceDisplay(balanceState);
                final affordable = _balanceResult(balanceState).sufficient;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (balance != null) ...[
                      const SizedBox(height: MallowTheme.spacingMd),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'Balance: ',
                              style: MallowTheme.uiCaption.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                            TextSpan(
                              text:
                                  '${formatBalance(balance)} '
                                  '${_token.symbol}',
                              style: MallowTheme.uiCaption.copyWith(
                                color: colors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: MallowTheme.spacingLg),
                    MallowButton(
                      label: affordable ? 'Next' : 'Insufficient funds',
                      onPressed: _isValid && affordable && !widget.isSubmitting
                          ? _onSubmit
                          : null,
                      isLoading: widget.isSubmitting,
                      isFullWidth: true,
                    ),
                  ],
                );
              },
            ),
            SizedBox(height: sheetBottomInset(context, includeKeyboard: false)),
          ],
        ),
      ),
    );
  }
}
