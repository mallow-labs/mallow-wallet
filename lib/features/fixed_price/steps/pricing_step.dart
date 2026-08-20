import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/currency_picker_sheet.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../sale/widgets/raw_amount_field.dart';
import '../../sale/widgets/sale_currency_pill.dart';
import '../services/fixed_price_bloc.dart';

/// Step 2 (or 1 when entered from artwork detail): currency + sale price.
///
/// Layout per the Figma spec. Mirrors the auction's `_ReservePriceField`
/// for the price-input handling — same display↔raw conversion and
/// mid-edit preservation.
class PricingStep extends StatelessWidget {
  const PricingStep({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<FixedPriceBloc, FixedPriceState>(
      buildWhen: (prev, next) =>
          prev.currencyMint != next.currencyMint ||
          prev.price != next.price ||
          prev.editionsLimit != next.editionsLimit ||
          prev.selectedArtwork?.mintAccount !=
              next.selectedArtwork?.mintAccount,
      builder: (context, state) {
        final colors = context.mallowColors;
        final token = tokenByMint(state.currencyMint) ?? defaultBidToken;
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose Currency',
                style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              SaleCurrencyPill(
                token: token,
                onTap: () async {
                  final selected = await showCurrencyPickerSheet(context);
                  if (selected != null && context.mounted) {
                    context.read<FixedPriceBloc>().add(
                      FixedPriceEvent.setCurrencyMint(selected.mint),
                    );
                  }
                },
              ),
              const SizedBox(height: 4),
              Text(
                'mallow currently supports Solana tokens only',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: MallowTheme.spacing20),
              Text(
                'Set your sale price',
                style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              RawAmountField(
                token: token,
                rawAmount: state.price,
                hintText: 'Price',
                onChanged: (raw) => context.read<FixedPriceBloc>().add(
                  FixedPriceEvent.setPrice(raw),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Min: ${displayDecimal(token.minListingDisplay)} ${token.symbol} '
                'or equivalent',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              if (state.isMasterEdition) ...[
                const SizedBox(height: MallowTheme.spacing20),
                Text(
                  'Max editions per wallet',
                  style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: MallowTheme.spacingSm),
                _EditionsLimitField(value: state.editionsLimit),
                const SizedBox(height: 4),
                Text(
                  state.editionsAvailable != null
                      ? 'Optional — leave blank for no cap '
                            '(${state.editionsAvailable} editions available)'
                      : 'Optional — leave blank for no cap (open edition)',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Whole-number input for the master-edition `editionsLimit`. Only the
/// pricing step renders this — the bloc's `isMasterEdition` getter gates
/// the visibility.
class _EditionsLimitField extends StatefulWidget {
  const _EditionsLimitField({required this.value});

  final int value;

  @override
  State<_EditionsLimitField> createState() => _EditionsLimitFieldState();
}

class _EditionsLimitFieldState extends State<_EditionsLimitField> {
  late final TextEditingController _controller;
  String _lastEdited = '';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.value));
    _lastEdited = _controller.text;
  }

  @override
  void didUpdateWidget(covariant _EditionsLimitField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final formatted = _format(widget.value);
    if (formatted != _lastEdited) {
      _controller.text = formatted;
      _lastEdited = formatted;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _format(int value) => value <= 0 ? '' : value.toString();

  void _onChanged(String value) {
    _lastEdited = value;
    final parsed = int.tryParse(value) ?? 0;
    context.read<FixedPriceBloc>().add(
      FixedPriceEvent.setEditionsLimit(parsed),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MallowPillField(
      controller: _controller,
      hintText: 'No cap',
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: _onChanged,
    );
  }
}
