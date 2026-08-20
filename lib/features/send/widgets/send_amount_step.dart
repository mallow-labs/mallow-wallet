import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/decimal_input_formatter.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../portfolio/models/token_balance.dart';
import 'send_sheet_widgets.dart';

/// Third send step: amount entry with live fiat
/// equivalent and Half/Max helpers.
class SendAmountStep extends StatelessWidget {
  const SendAmountStep({
    required this.token,
    required this.controller,
    required this.focusNode,
    required this.errorText,
    required this.fiatText,
    required this.isValidating,
    required this.onChanged,
    required this.onHalf,
    required this.onMax,
    required this.onBack,
    required this.onCancel,
    required this.onNext,
    this.sourceAddress,
    this.onSwitch,
    super.key,
  });

  final TokenBalance token;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? errorText;

  /// `~$8.42`-style equivalent of the typed amount, or null when no price.
  final String? fiatText;
  final bool isValidating;
  final ValueChanged<String> onChanged;
  final VoidCallback onHalf;
  final VoidCallback onMax;
  final VoidCallback onBack;
  final VoidCallback onCancel;
  final VoidCallback onNext;
  final String? sourceAddress;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SendStepHeader(title: 'Send', onBack: onBack),
          const SizedBox(height: MallowTheme.spacingLg),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Amount',
                  style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
                ),
              ),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Balance: ',
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    TextSpan(
                      text:
                          '${_formatBalance(token.uiBalance)} ${token.symbol}',
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: MallowTheme.spacing12),
          MallowPillField(
            controller: controller,
            focusNode: focusNode,
            hintText: '0.00',
            errorText: errorText,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalInputFormatter(token.decimals)],
            onChanged: onChanged,
            prefix: tokenImageWidget(
              mint: token.mint,
              size: 16,
              symbol: token.symbol,
              logoUrl: token.logoUrl,
              enlargeChainGlyph: true,
            ),
            suffix: fiatText == null
                ? null
                : Text(
                    fiatText!,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
          ),
          const SizedBox(height: MallowTheme.spacing12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _Chip(label: 'Half', onTap: onHalf),
              const SizedBox(width: MallowTheme.spacingSm),
              _Chip(label: 'Max', onTap: onMax),
            ],
          ),
          const Spacer(),
          const SizedBox(height: MallowTheme.spacingMd),
          SendStepButtons(
            primaryLabel: 'Next',
            isLoading: isValidating,
            onCancel: onCancel,
            onPrimary: onNext,
            sourceAddress: sourceAddress,
            onSwitch: onSwitch,
          ),
        ],
      ),
    );
  }

  static String _formatBalance(double value) {
    if (value == 0) return '0';
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(2)}M';
    final digits = value >= 1 ? 2 : 6;
    return stripTrailingZeros(value.toStringAsFixed(digits));
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacingSm,
            vertical: MallowTheme.spacingXs,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: colors.divider),
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
          child: Text(
            label,
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ),
      ),
    );
  }
}
