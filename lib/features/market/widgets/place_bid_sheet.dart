import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mallow_api/mallow_api.dart' show AuctionMetadata;

import '../../../core/data/mallow_tokens.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/utils/price_formatter.dart';
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
import '../../../shared/widgets/tap_target_expander.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../models/market_price.dart';

/// Bottom sheet for entering an auction bid amount. Mirrors [MakeOfferSheet]'s
/// scaffold (drag handle, subject header, "Next" CTA) but swaps the
/// currency+amount row for a single "Bid" pill that shows the chain symbol on
/// the left and a live (debounced) USD conversion on the right, per the
/// Figma spec.
///
/// The active signer's balance of the bid currency sits directly above the CTA,
/// and a bid the wallet can't cover disables it with an "Insufficient funds"
/// label — the same [checkBalance] verdict the confirm step would reach, just
/// surfaced before the tx is built.
///
/// Returns a [MarketPrice] (raw atomic amount + currency mint) the caller
/// hands straight to `MarketEvent.placeBid`, or null if cancelled.
class PlaceBidSheet extends StatefulWidget {
  const PlaceBidSheet({
    required this.artworkTitle,
    required this.mintAccount,
    required this.tokenBalanceBloc,
    super.key,
    this.currencyMint,
    this.currentHighestBid,
    this.minBidRaw,
    this.auction,
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
  /// `MarketConfirmationSheet` takes one).
  final TokenBalanceBloc tokenBalanceBloc;

  /// When provided, tapping "Next" reports the entered price via this
  /// callback instead of popping the route — used by [MarketActionFlowSheet]
  /// to advance to the confirmation step within the same sheet. When null,
  /// the sheet pops with the [MarketPrice] for standalone use.
  final ValueChanged<MarketPrice>? onNext;

  /// True while the host prepares the transaction after "Next" — shows the
  /// CTA spinner and blocks re-entry until the confirmation step takes over.
  final bool isSubmitting;

  /// Mint address of the auction's bid currency. Null = SOL.
  final String? currencyMint;

  /// Current highest bid in the same [currencyMint], or null when no bids
  /// exist yet. Surfaced as the "Current highest bid" reference line.
  final MarketPrice? currentHighestBid;

  /// Lowest acceptable bid in raw [currencyMint] units (reserve when there are
  /// no bids, else highest bid + increment — see webapp `getMinBid`). When set,
  /// it's shown as the "Min:" hint and enforced before "Next" enables.
  /// Null/zero means no enforced floor beyond a positive amount.
  final int? minBidRaw;

  /// The auction being bid on. Drives [_AuctionInfoBox] — the minimum bid
  /// increment and the anti-sniping rule. Null hides the box.
  final AuctionMetadata? auction;

  final String? artworkImageUrl;
  final String? artistUsername;

  /// Moderation flag for the subject preview — blurs it (with an eye-icon
  /// reveal) unless the viewer's show-NSFW setting is on.
  final bool nsfw;

  @override
  State<PlaceBidSheet> createState() => _PlaceBidSheetState();
}

class _PlaceBidSheetState extends State<PlaceBidSheet> {
  static const _usdDebounce = Duration(milliseconds: 300);

  final _amountController = TextEditingController();
  final _focusNode = FocusNode();

  late final MallowToken _token;

  /// User-entered amount in display units (drives validation + the CTA).
  double? _displayAmount;

  /// Trails [_displayAmount] by [_usdDebounce] so the USD conversion doesn't
  /// recompute on every keystroke.
  double? _usdAmount;
  Timer? _usdDebounceTimer;

  /// Display-unit minimum bid (raw floor rounded *up* to 2 dp, matching the
  /// webapp's `minBidUIAmount`), or null when there's no enforced floor.
  double? _minBidDisplay;

  @override
  void initState() {
    super.initState();
    _token = tokenByMint(widget.currencyMint) ?? tokenByMint(solMint)!;
    final minRaw = widget.minBidRaw;
    if (minRaw != null && minRaw > 0) {
      // Round up to 2 dp like webapp `minBid.round(2, Big.roundUp)` so the hint
      // and the floor never sit below the true raw minimum.
      _minBidDisplay = (_token.rawToDisplay(minRaw) * 100).ceil() / 100;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _usdDebounceTimer?.cancel();
    _amountController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onAmountChanged(String value) {
    final amount = double.tryParse(value);
    setState(() => _displayAmount = amount);
    // Debounce only the USD line — validation/CTA stay instant.
    _usdDebounceTimer?.cancel();
    _usdDebounceTimer = Timer(_usdDebounce, () {
      if (!mounted) return;
      setState(() => _usdAmount = amount);
    });
  }

  /// True when a positive amount has been entered but it's under the auction's
  /// minimum — drives the "Bid too low" CTA label. Empty/zero is *not* "too
  /// low" (the CTA just stays disabled with its default label). Compared with a
  /// small epsilon so an exact-minimum entry isn't rejected by float drift.
  bool get _belowMinimum {
    final amount = _displayAmount;
    final min = _minBidDisplay;
    return amount != null && amount > 0 && min != null && amount < min - 1e-9;
  }

  bool get _isValid =>
      _displayAmount != null && _displayAmount! > 0 && !_belowMinimum;

  /// Affordability of the entered amount against the active signer's balances
  /// — see [checkBalanceOrSkip] for the gas-reserve rules and for why an empty
  /// input or unloaded balances read as sufficient (never false-disable).
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

  /// The signer's balance of the bid currency in display units, or null until
  /// balances load (the line is omitted rather than showing a wrong zero).
  double? _balanceDisplay(TokenBalanceState balanceState) {
    if (balanceState is! TokenBalanceLoaded) return null;
    return balanceState.tokens
            .firstWhereOrNull((t) => t.mint == _token.mint)
            ?.uiBalance ??
        0;
  }

  /// Prefills the input with the minimum bid when the hint is tapped.
  void _fillMinimum() {
    final min = _minBidDisplay;
    if (min == null) return;
    final text = min.toStringAsFixed(2);
    _amountController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onAmountChanged(text);
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
    final best = widget.currentHighestBid;
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
              'Place Bid',
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
            if (widget.auction != null)
              _AuctionInfoBox(auction: widget.auction!, token: _token),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  'Bid',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (_minBidDisplay != null)
                  // Tap to prefill the minimum — mirrors the webapp's clickable
                  // "Min:" amount.
                  TapTargetExpander(
                    child: GestureDetector(
                      onTap: _fillMinimum,
                      child: Text(
                        'Min: '
                        '${_minBidDisplay!.toStringAsFixed(2)} ${_token.symbol}',
                        style: MallowTheme.uiCaption.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            MallowPillField(
              controller: _amountController,
              focusNode: _focusNode,
              hintText: 'Bid amount',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
              ],
              prefix: tokenImageWidget(
                mint: _token.mint,
                symbol: _token.symbol,
                size: 16,
                enlargeChainGlyph: true,
              ),
              suffix: _UsdSuffix(amount: _usdAmount, token: _token),
              onChanged: _onAmountChanged,
              onSubmitted: (_) => _onSubmit(),
            ),
            if (best != null) ...[
              const SizedBox(height: MallowTheme.spacingMd),
              Text(
                'Current highest bid: '
                '${_token.rawToDisplay(best.rawAmount.toInt())} '
                '${_token.symbol}',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
            BlocBuilder<TokenBalanceBloc, TokenBalanceState>(
              bloc: widget.tokenBalanceBloc,
              builder: (context, balanceState) {
                final balance = _balanceDisplay(balanceState);
                final affordable = _balanceResult(balanceState).sufficient;
                final String label;
                if (!affordable) {
                  // Terminal blocker — raising the bid can't fix it, so it
                  // outranks the "Bid too low" floor hint.
                  label = 'Insufficient funds';
                } else if (_belowMinimum) {
                  label = 'Bid too low';
                } else {
                  label = 'Next';
                }
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
                      label: label,
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

/// The two facts a bidder needs before they name a number: how much they have
/// to raise the bid by, and whether their bid will push the deadline out.
/// Port of the webapp's `AuctionInfoBox` (`AuctionInfoBox`),
/// which renders in the same place — inside the place-a-bid modal, above the
/// amount field.
///
/// Both facts exist to prevent reverted transactions (`auction.test`):
/// a bid under `highest + increment` is rejected on-chain, and a bidder who
/// doesn't know about the end phase thinks sniping works.
///
/// `timeExtPeriod` and `timeExtDelta` are **independent** wire fields — see
/// `_ArtworkAuctionLivePanelState._progressWindow` for the program semantics.
/// The end-phase window is the period; the extension length is the delta.
class _AuctionInfoBox extends StatelessWidget {
  const _AuctionInfoBox({required this.auction, required this.token});

  final AuctionMetadata auction;

  /// Registry token for `auction.bidMint` — supplies the symbol on a flat
  /// (non-bps) minimum increment.
  final MallowToken token;

  /// Minutes as the webapp prints them: a bare number, no trailing zeros
  /// (900s → "15", 750s → "12.5").
  static String _minutes(int seconds) =>
      stripTrailingZeros((seconds / 60).toStringAsFixed(2));

  static String _minuteLabel(int seconds, String unit) {
    final value = _minutes(seconds);
    return '$value $unit${seconds > 60 ? 's' : ''}';
  }

  /// Port of `getMinBidIncrementDisplay` (`auction`): bps wins
  /// over the flat amount, rendered as a percentage; otherwise the raw
  /// increment in the bid currency.
  String get _minBidIncrementDisplay {
    final bps = auction.minBidIncrementBps;
    if (bps != null) {
      return '${stripTrailingZeros((bps / 100).toStringAsFixed(2))}%';
    }
    final increment = auction.minBidIncrement ?? 0;
    return '${PriceFormatter.formatRawAmount(increment.toDouble(), auction.bidMint)} '
        '${token.symbol}';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final startsAt = auction.startsAt;
    final endsAt = auction.endsAt;
    final period = auction.timeExtPeriod;
    final delta = auction.timeExtDelta;

    final isEndPhase =
        startsAt != null &&
        endsAt != null &&
        period != null &&
        now.isAfter(startsAt) &&
        now.isAfter(endsAt.subtract(Duration(seconds: period)));
    final startsOnBid = startsAt == null;
    // The webapp's test is `timeExtPeriod !== 0`, which is also true for an
    // absent period and then renders "Last 0 min". An absent period means the
    // auction carries no end-phase config at all, so treat it as no end phase
    // rather than mirroring a row that states a falsehood.
    final hasEndPhase = period != null && period > 0;

    if (!isEndPhase && !startsOnBid && !hasEndPhase) {
      return const SizedBox.shrink();
    }

    final duration = auction.duration;
    return Padding(
      padding: const EdgeInsets.only(bottom: MallowTheme.spacingLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isEndPhase) ...[
            _InfoRow(
              label: 'End phase active',
              value: period == 0
                  ? 'None'
                  : 'Last ${_minuteLabel(period, 'minute')}',
            ),
            _InfoRow(
              label: 'Minimum bid increment',
              value: _minBidIncrementDisplay,
            ),
            _InfoRow(
              label: 'Time extension per bid',
              value: (delta == null || delta == 0)
                  ? 'None'
                  : _minuteLabel(delta, 'minute'),
            ),
          ],
          if (startsOnBid) ...[
            if (duration != null && duration > 0)
              _InfoRow(
                label: 'Auction duration',
                value: _durationValue(duration),
              ),
            _InfoRow(
              label: 'Minimum bid increment',
              value: _minBidIncrementDisplay,
            ),
          ],
          if (hasEndPhase)
            _InfoRow(
              label: 'Auction end phase',
              value: 'Last ${_minuteLabel(period, 'min')}',
            ),
        ],
      ),
    );
  }

  /// "24 hours" for whole-hour durations (the webapp's preset path), else the
  /// remainder spelled out.
  static String _durationValue(int seconds) {
    if (seconds % 3600 == 0) {
      final hours = seconds ~/ 3600;
      return '$hours hour${hours == 1 ? '' : 's'}';
    }
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    return hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
  }
}

/// One label/value line of [_AuctionInfoBox], laid out like the webapp's
/// disclaimer rows (label left, value right).
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final style = MallowTheme.uiCaption.copyWith(color: colors.textSecondary);
    return Padding(
      padding: const EdgeInsets.only(bottom: MallowTheme.spacingXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: MallowTheme.spacingSm),
          Text(
            value,
            style: style.copyWith(color: colors.textPrimary),
            textAlign: TextAlign.right,
          ),
        ],
      ),
    );
  }
}

/// Live "~$X.XX" conversion shown at the trailing edge of the bid pill.
/// Rebuilds when the debounced [amount] changes or when [TokenPriceService]
/// refreshes its cached prices.
class _UsdSuffix extends StatelessWidget {
  const _UsdSuffix({required this.amount, required this.token});

  final double? amount;
  final MallowToken token;

  @override
  Widget build(BuildContext context) {
    final amt = amount;
    if (amt == null || amt <= 0) return const SizedBox.shrink();
    final priceService = sl<TokenPriceService>();
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: priceService.prices,
      builder: (context, _, _) {
        final usd = priceService.usdValueOfRaw(
          token.displayToRaw(amt),
          token.mint,
        );
        if (usd == null) return const SizedBox.shrink();
        return Text(
          '~\$${usd.toStringAsFixed(2)}',
          style: MallowTheme.uiCaption.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        );
      },
    );
  }
}
