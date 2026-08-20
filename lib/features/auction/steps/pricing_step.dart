import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../mint/widgets/mint_radio_row.dart';
import '../../sale/widgets/raw_amount_field.dart';
import '../../sale/widgets/sale_currency_pill.dart';
import '../services/auction_bloc.dart';
import '../../../shared/widgets/currency_picker_sheet.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/tappable.dart';

const _endPhaseOptions = [
  ('None', 0),
  ('5 mins', 300),
  ('10 mins', 600),
  ('15 mins', 900),
  ('30 mins', 1800),
  ('60 mins', 3600),
];

/// Step 2: pricing — sale currency, reserve starting bid, minimum bid
/// increment, and end phase duration.
class PricingStep extends StatelessWidget {
  const PricingStep({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuctionBloc, AuctionState>(
      buildWhen: (prev, next) =>
          prev.bidMint != next.bidMint ||
          prev.reservePrice != next.reservePrice ||
          prev.minBidIncrement != next.minBidIncrement ||
          prev.absoluteIncrement != next.absoluteIncrement ||
          prev.timeExtPeriod != next.timeExtPeriod,
      builder: (context, state) {
        final colors = context.mallowColors;
        final token = tokenByMint(state.bidMint) ?? defaultBidToken;
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sale Currency',
                style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              SaleCurrencyPill(
                token: token,
                onTap: () async {
                  final selected = await showCurrencyPickerSheet(context);
                  if (selected != null && context.mounted) {
                    context.read<AuctionBloc>().add(
                      AuctionEvent.setBidMint(selected.mint),
                    );
                  }
                },
              ),
              const SizedBox(height: MallowTheme.spacing20),
              Text(
                'Set your reserve starting bid',
                style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: 4),
              Text(
                'Minimum: ${displayDecimal(token.minListingDisplay)} ${token.symbol}',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              RawAmountField(
                token: token,
                rawAmount: state.reservePrice,
                hintText: 'Enter reserve price',
                onChanged: (raw) => context.read<AuctionBloc>().add(
                  AuctionEvent.setReservePrice(raw),
                ),
              ),
              const SizedBox(height: MallowTheme.spacing20),
              Text(
                'Set your minimum bid increment',
                style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              _BidIncrementRow(
                token: token,
                value: state.minBidIncrement,
                absolute: state.absoluteIncrement,
              ),
              const SizedBox(height: MallowTheme.spacing20),
              Text(
                'End phase duration',
                style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: 4),
              Text(
                'Setting an end phase extends the auction with each bid '
                'within the given window from the end.',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              for (final option in _endPhaseOptions)
                MintRadioRow(
                  label: option.$1,
                  selected: state.timeExtPeriod == option.$2,
                  onTap: () => context.read<AuctionBloc>().add(
                    AuctionEvent.setTimeExtPeriod(option.$2),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _BidIncrementRow extends StatefulWidget {
  const _BidIncrementRow({
    required this.token,
    required this.value,
    required this.absolute,
  });

  final MallowToken token;
  final int value;
  final bool absolute;

  @override
  State<_BidIncrementRow> createState() => _BidIncrementRowState();
}

class _BidIncrementRowState extends State<_BidIncrementRow> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format());
  }

  @override
  void didUpdateWidget(covariant _BidIncrementRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final formatted = _format();
    if (_controller.text != formatted) {
      _controller.text = formatted;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _format() {
    if (widget.value == 0) return '';
    if (widget.absolute) {
      final display = widget.token.rawToDisplay(widget.value);
      return stripTrailingZeros(
        display.toStringAsFixed(widget.token.inputDecimals),
      );
    }
    // bps*100 → percent
    return stripTrailingZeros((widget.value / 100).toStringAsFixed(2));
  }

  void _onChanged(String value) {
    final parsed = double.tryParse(value);
    if (parsed == null) {
      context.read<AuctionBloc>().add(
        AuctionEvent.setMinBidIncrement(value: 0, absolute: widget.absolute),
      );
      return;
    }
    final stored = widget.absolute
        ? widget.token.displayToRaw(parsed)
        : (parsed * 100).round();
    context.read<AuctionBloc>().add(
      AuctionEvent.setMinBidIncrement(value: stored, absolute: widget.absolute),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      children: [
        // Mode dropdown — % or absolute (token symbol)
        Tappable(
          onTap: () => _showModeMenu(context),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
              border: Border.all(color: colors.divider),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.absolute ? widget.token.symbol : '%',
                  style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(width: 4),
                MallowSvgIcon(
                  'assets/icons/arrow_down.svg',
                  width: 6,
                  height: 6,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: MallowTheme.spacingSm),
        Expanded(
          child: MallowPillField(
            controller: _controller,
            hintText: widget.absolute
                ? 'Minimum bid increment in ${widget.token.symbol}'
                : 'Minimum bid increment in %',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
            ],
            onChanged: _onChanged,
          ),
        ),
      ],
    );
  }

  Future<void> _showModeMenu(BuildContext context) async {
    final selected = await showMallowSheet<bool>(
      context: context,
      builder: (sheetContext) {
        final colors = sheetContext.mallowColors;
        return Container(
          decoration: BoxDecoration(
            color: colors.bgSurface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(MallowTheme.popupRadius),
            ),
          ),
          padding: EdgeInsets.only(
            top: 12,
            bottom: MediaQuery.of(sheetContext).padding.bottom + 12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  'Percentage (%)',
                  style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                ),
                trailing: !widget.absolute
                    ? MallowSvgIcon(
                        'assets/icons/checkmark.svg',
                        color: colors.accent,
                      )
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(false),
              ),
              ListTile(
                title: Text(
                  '${widget.token.symbol} (absolute amount)',
                  style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                ),
                trailing: widget.absolute
                    ? MallowSvgIcon(
                        'assets/icons/checkmark.svg',
                        color: colors.accent,
                      )
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(true),
              ),
            ],
          ),
        );
      },
    );
    if (selected != null && selected != widget.absolute && context.mounted) {
      context.read<AuctionBloc>().add(
        AuctionEvent.setMinBidIncrement(value: 0, absolute: selected),
      );
    }
  }
}
