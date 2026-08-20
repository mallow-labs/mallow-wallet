import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/config/remote_config.dart';
import '../../../core/config/remote_config_service.dart';
import '../../../core/data/mallow_tokens.dart';
import '../../../core/services/token_price_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../artwork/data/artwork_repository.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/network/das_api_service.dart';
import '../../sale/services/direct_proceeds.dart';
import '../../sale/services/marketplace_config_service.dart';
import '../../sale/services/proceeds_calculator.dart';
import '../../sale/widgets/proceeds_breakdown.dart';
import '../models/market_price.dart';

/// The `fixed-price-update` cell — the "Update price" action's tx builder.
const _updateFlow = FlowKey.solana(AppFlow.fixedPriceUpdate);

/// 🔓 The `fixed-price-cancel` cell — the "Cancel listing" action's builder.
///
/// A separate cell from [_updateFlow] on purpose:
/// cancelling is how an owner gets a listed asset back, so killing a broken
/// price update must leave delisting alone — and vice versa.
const _cancelFlow = FlowKey.solana(AppFlow.fixedPriceCancel);

/// Result of [UpdateListingSheet]: the user either submitted a new
/// price (in the listing's currency) or asked to cancel the listing
/// entirely. `null` is returned when the sheet is dismissed without
/// a choice.
sealed class UpdateListingResult {
  const UpdateListingResult();
}

class UpdateListingPriceResult extends UpdateListingResult {
  const UpdateListingPriceResult(this.newPrice);

  /// New listing price as a [MarketPrice] in the listing's currency.
  final MarketPrice newPrice;
}

class UpdateListingCancelResult extends UpdateListingResult {
  const UpdateListingCancelResult();
}

/// Per-recipient proceeds rows for a candidate raw price. Resolved once when
/// the sheet opens (the royalty/fee/primary-vs-secondary inputs don't change
/// while it is), then re-applied on every keystroke.
typedef ProceedsSplitsForPrice = List<ProceedsSplit> Function(int priceRaw);

/// Resolves [UpdateListingSheet]'s proceeds rows for [mint] through the same
/// pipeline the listing *creation* review step uses (`resolveListingContext` →
/// `computeProceedsSplits`), so an owner sees the identical breakdown whether
/// they are setting a price or changing one — webapp parity, where
/// `UpdateListingModal` and `ListArtwork` both render `ProceedsInfo`.
///
/// Returns null when there's no signer or the lookups fail; the sheet then
/// renders no breakdown rather than a guessed one.
///
/// `disablePrimarySplit` is fixed at false: the market program has no
/// update-time split flag, and `UpdateListingModal` hardcodes the same.
Future<ProceedsSplitsForPrice?> resolveUpdateListingProceeds(
  String mint,
) async {
  final seller = sl<AuthService>().currentAddress;
  if (seller == null || seller.isEmpty) return null;
  try {
    final context = await resolveListingContext(
      mint: mint,
      sellerPubkey: seller,
      dasApi: sl<DasApiService>(),
      artworkRepo: sl<ArtworkRepository>(),
      marketplaceConfig: sl<MarketplaceConfigService>(),
    );
    return (int priceRaw) => computeProceedsSplits(
      seller: seller,
      priceRaw: priceRaw,
      isSecondary: context.isSecondaryMarket,
      royaltyShares: context.royaltyShares,
      royaltyBps: context.royaltyBps,
      primaryFeeBps: context.primaryFeeBps,
      secondaryFeeBps: context.secondaryFeeBps,
    );
  } catch (_) {
    return null;
  }
}

/// Bottom sheet for an owner managing an active buy-now listing. Lets
/// them either update the price (currency-aware input with live USD
/// conversion) or cancel the listing outright via a secondary action.
///
/// ### Kill-switch gating
///
/// The sheet fronts **two** cells ([_updateFlow] and [_cancelFlow]) and reads
/// both itself, reactively — it takes no message parameters. That is deliberate:
/// optional snapshot params defaulting to null meant a future call site
/// compiled fine and rendered fully-enabled buttons, and a kill landing while
/// the sheet was open went unnoticed. Reading here makes gating impossible to
/// forget and live.
class UpdateListingSheet extends StatefulWidget {
  const UpdateListingSheet({
    required this.mintAccount,
    required this.currentPrice,
    super.key,
    this.editionsSold,
    this.proceedsResolver,
  });

  final String mintAccount;

  /// Supplies the "Proceeds" breakdown — pass
  /// [resolveUpdateListingProceeds]. Awaited once on mount; a null result (or
  /// a null resolver, as in widget tests) simply renders no breakdown, since
  /// the price edit itself must never be blocked on a royalty lookup.
  final Future<ProceedsSplitsForPrice?> Function()? proceedsResolver;

  /// Existing listing price in the listing's currency — shown for
  /// reference and used to disable the submit button when the input
  /// matches.
  final MarketPrice currentPrice;

  /// Editions sold so far. Set only for open-edition listings to
  /// render an "X sold" badge opposite the current price.
  final double? editionsSold;

  @override
  State<UpdateListingSheet> createState() => _UpdateListingSheetState();
}

class _UpdateListingSheetState extends State<UpdateListingSheet> {
  final _amountController = TextEditingController();
  final _focusNode = FocusNode();

  late final MallowToken _token;
  late final TokenPriceService _priceService;
  late final double _currentDisplay;

  /// New price in display units of [_token].
  double? _newDisplay;
  String? _errorMessage;

  /// Non-null once [UpdateListingSheet.proceedsResolver] has resolved rows.
  ProceedsSplitsForPrice? _proceedsFor;

  @override
  void initState() {
    super.initState();
    _token =
        tokenByMint(widget.currentPrice.currencyMint) ?? tokenByMint(solMint)!;
    _priceService = sl<TokenPriceService>();
    _currentDisplay = _token.rawToDisplay(
      widget.currentPrice.rawAmount.toInt(),
    );
    // This sheet is itself a flow entry point (it fronts two cells and reads
    // them at render time rather than gating a tap), so it owns the nudge.
    refreshRemoteConfigOnFlowEntry();
    // One event per killed cell per sheet-open. Emitted from initState, not
    // the reactive builder — a rebuild-driven emit (or a live flip while the
    // sheet is open) would inflate the incident-reach count.
    for (final flow in const [_updateFlow, _cancelFlow]) {
      if (flowDisabledMessage(flow) != null) {
        trackFlowDisabledHit(flow, FlowDisabledSurface.sheet);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
    _loadProceeds();
  }

  Future<void> _loadProceeds() async {
    final resolver = widget.proceedsResolver;
    if (resolver == null) return;
    final splitsFor = await resolver();
    if (!mounted || splitsFor == null) return;
    setState(() => _proceedsFor = splitsFor);
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
      _newDisplay = amount;
      _errorMessage = _validateAmount(amount);
    });
  }

  String? _validateAmount(double? amount) {
    if (amount == null || amount <= 0) return null;
    if (amount < _token.minListingDisplay) {
      return 'Minimum price is ${_token.minListingDisplay} ${_token.symbol}';
    }
    if (amount == _currentDisplay) {
      return 'New price matches the current price';
    }
    return null;
  }

  /// Entered price in the listing currency's smallest unit — 0 while the field
  /// is empty or non-positive, which [ProceedsBreakdown] renders as `—`.
  int get _newPriceRaw {
    final display = _newDisplay;
    if (display == null || display <= 0) return 0;
    return _token.displayToRaw(display);
  }

  bool get _isValid =>
      _newDisplay != null &&
      _newDisplay! > 0 &&
      _newDisplay != _currentDisplay &&
      _errorMessage == null;

  void _onSubmit() {
    if (!_isValid) return;
    final raw = _token.displayToRaw(_newDisplay!).toDouble();
    Navigator.of(context).pop(
      UpdateListingPriceResult(
        MarketPrice(rawAmount: raw, currencyMint: _token.mint),
      ),
    );
  }

  void _onCancelListing() {
    Navigator.of(context).pop(const UpdateListingCancelResult());
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        padding: const EdgeInsets.all(MallowTheme.spacing20),
        decoration: BoxDecoration(
          color: context.mallowColors.bgPrimary,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetDragHandle(),
              Text(
                'Update listing',
                style: MallowTheme.editorialSubhead.copyWith(
                  color: context.mallowColors.textPrimary,
                ),
                textAlign: TextAlign.left,
              ),
              const SizedBox(height: MallowTheme.spacingLg),
              _CurrentListingPrice(
                currentPrice: widget.currentPrice,
                token: _token,
                priceService: _priceService,
                editionsSold: widget.editionsSold,
              ),
              const SizedBox(height: MallowTheme.spacingMd),
              const MallowSectionLabel(label: 'New Price'),
              const SizedBox(height: MallowTheme.spacingMd),
              MallowPillField(
                controller: _amountController,
                focusNode: _focusNode,
                hintText: _stripTrailing(_currentDisplay, _token.inputDecimals),
                errorText: _errorMessage,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
                ],
                onChanged: _onAmountChanged,
                onSubmitted: (_) => _onSubmit(),
                suffix: Text(
                  _token.symbol,
                  style: MallowTheme.uiBody.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                ),
              ),
              if (_newDisplay != null && _newDisplay! > 0)
                _UsdLine(
                  amountRaw: _token.displayToRaw(_newDisplay!).toDouble(),
                  token: _token,
                  priceService: _priceService,
                ),
              // The same per-recipient split the listing *creation* review
              // step shows, so an owner can see what a price change actually
              // pays them before committing to it (webapp `UpdateListingModal`
              // renders `ProceedsInfo` here too). Rows show `—` until a price
              // is typed, exactly as on the creation surface.
              if (_proceedsFor != null) ...[
                const SizedBox(height: MallowTheme.spacingLg),
                ProceedsBreakdown(
                  splits: _proceedsFor!(_newPriceRaw),
                  token: _token,
                  priceRaw: _newPriceRaw,
                ),
              ],
              const SizedBox(
                height: MallowTheme.spacingLg + MallowTheme.spacingXs,
              ),
              _actions(),
              SizedBox(
                height: sheetBottomInset(context, includeKeyboard: false),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The two actions, each dead-and-explained when its own cell is killed.
  ///
  /// Rebuilds off [RemoteConfigService.config] so a refresh landing while the
  /// sheet is open takes effect without reopening it, and — the point of —
  /// so a **dual** kill renders BOTH operator messages. An owner has to be told
  /// whether delisting is paused (and therefore whether their asset is stuck)
  /// independently of what the update cell says; collapsing the two into one
  /// presentation drops exactly the copy that answers that.
  Widget _actions() {
    return ValueListenableBuilder<RemoteConfig>(
      valueListenable: sl<RemoteConfigService>().config,
      builder: (context, config, _) {
        final updateDisabled = config.disabledMessage(
          _updateFlow.chain,
          _updateFlow.flow,
        );
        final cancelDisabled = config.disabledMessage(
          _cancelFlow.chain,
          _cancelFlow.flow,
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MallowButton(
              label: 'Update price',
              onPressed: _isValid && updateDisabled == null ? _onSubmit : null,
              isFullWidth: true,
            ),
            if (updateDisabled != null)
              _DisabledReason(message: updateDisabled),
            const SizedBox(height: MallowTheme.spacingSm),
            MallowButton(
              label: 'Cancel listing',
              variant: MallowButtonVariant.secondary,
              onPressed: cancelDisabled == null ? _onCancelListing : null,
              isFullWidth: true,
            ),
            if (cancelDisabled != null)
              _DisabledReason(message: cancelDisabled),
          ],
        );
      },
    );
  }

  static String _stripTrailing(double value, int decimals) {
    final s = value.toStringAsFixed(decimals);
    return s.contains('.')
        ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
        : s;
  }
}

/// The operator's kill-switch copy under the action it disabled, rendered
/// verbatim — the same "explain, don't silently grey out" rule the
/// [showFlowUnavailableSheet] path follows, in the inline form.
class _DisabledReason extends StatelessWidget {
  const _DisabledReason({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: MallowTheme.spacingXs,
        left: 16,
        right: 16,
      ),
      child: Text(
        message,
        style: MallowTheme.uiCaption.copyWith(
          color: context.mallowColors.textTertiary,
        ),
      ),
    );
  }
}

class _UsdLine extends StatelessWidget {
  const _UsdLine({
    required this.amountRaw,
    required this.token,
    required this.priceService,
  });

  final double amountRaw;
  final MallowToken token;
  final TokenPriceService priceService;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: MallowTheme.spacingXs,
        left: 16,
        right: 16,
      ),
      child: ValueListenableBuilder<Map<String, double>>(
        valueListenable: priceService.prices,
        builder: (context, _, _) {
          final usd = priceService.usdValueOfRaw(amountRaw, token.mint);
          if (usd == null) return const SizedBox.shrink();
          return Text(
            '\$${usd.toStringAsFixed(2)} USD',
            style: MallowTheme.uiCaption.copyWith(
              color: context.mallowColors.textSecondary,
            ),
          );
        },
      ),
    );
  }
}

class _CurrentListingPrice extends StatelessWidget {
  const _CurrentListingPrice({
    required this.currentPrice,
    required this.token,
    required this.priceService,
    this.editionsSold,
  });

  final MarketPrice currentPrice;
  final MallowToken token;
  final TokenPriceService priceService;
  final double? editionsSold;

  @override
  Widget build(BuildContext context) {
    final display = token.rawToDisplay(currentPrice.rawAmount.toInt());
    return Container(
      padding: const EdgeInsets.all(MallowTheme.spacing12),
      decoration: BoxDecoration(
        color: context.mallowColors.accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(MallowTheme.radiusSm),
      ),
      child: Row(
        children: [
          MallowSvgIcon(
            'assets/icons/tag.svg',
            width: 20,
            height: 20,
            color: context.mallowColors.accent,
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Current price',
                  style: MallowTheme.uiMeta.copyWith(
                    color: context.mallowColors.accent,
                  ),
                ),
                const SizedBox(height: MallowTheme.spacingXs),
                ValueListenableBuilder<Map<String, double>>(
                  valueListenable: priceService.prices,
                  builder: (context, _, _) {
                    final usd = priceService.usdValueOfRaw(
                      currentPrice.rawAmount,
                      token.mint,
                    );
                    final usdSuffix = usd != null
                        ? ' (\$${usd.toStringAsFixed(2)})'
                        : '';
                    return Text(
                      '${display.toStringAsFixed(token.inputDecimals)} ${token.symbol}'
                      '$usdSuffix',
                      style: MallowTheme.uiBody,
                    );
                  },
                ),
              ],
            ),
          ),
          if (editionsSold != null) ...[
            const SizedBox(width: MallowTheme.spacingSm),
            Text(
              '${editionsSold!.toInt()} sold',
              style: MallowTheme.uiCaption.copyWith(
                color: context.mallowColors.accent,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
