import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/data/mallow_tokens.dart' as mallow_tokens;
import '../../../core/services/priority_fee_service.dart';
import '../../../core/services/token_price_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../widgets/settings_page_scaffold.dart';

/// Settings → Priority Fee.
///
/// One global ceiling applied to **every Solana transaction the app builds** —
/// sends, listings, bids, mints, staking — and handed to Jupiter for swaps.
/// Mirrors the webapp's Transaction Priority modal: the same three presets plus
/// a manual entry clamped at 1 SOL.
///
/// The value is a ceiling, not the fee charged: the builder asks the network
/// what it currently wants and clamps that into `[15 000, ceiling]` lamports.
/// Raising it lets a congested network charge more; it does not spend more on
/// a quiet one.
///
/// Reached both from Preferences and from the "Increase priority fee"
/// affordance a blockhash-expiry failure offers, which is why it is a route
/// rather than a sheet — it has to be pushable from on top of a live pipeline
/// sheet.
class PriorityFeeScreen extends StatefulWidget {
  const PriorityFeeScreen({super.key});

  @override
  State<PriorityFeeScreen> createState() => _PriorityFeeScreenState();
}

class _PriorityFeeScreenState extends State<PriorityFeeScreen> {
  final _service = sl<PriorityFeeService>();

  late int? _lamports = _service.selection.value;

  /// "Custom" is a mode, not a value: it must stay selected while the field is
  /// empty, and a typed value equal to a preset is still a custom entry.
  late bool _custom =
      _lamports != null &&
      !PriorityFeeTier.values.any((t) => t.lamports == _lamports);

  late final _controller = TextEditingController(
    text: _custom ? formatPriorityFeeSol(_lamports!) : '',
  );

  @override
  void dispose() {
    // This screen has no Done button — it commits as you go — but the custom
    // field can only be read here, so a back-swipe out of a half-typed custom
    // value still persists what was typed.
    _commitCustom();
    _controller.dispose();
    super.dispose();
  }

  void _commitCustom() {
    if (!_custom) return;
    final sol = double.tryParse(_controller.text);
    // An empty or non-positive entry means "no ceiling was chosen" — fold back
    // to Auto rather than persisting a zero the builder would floor anyway.
    _service.set(sol == null || sol <= 0 ? null : (sol * 1e9).round());
  }

  /// Seed the field from the live selection before switching into Custom mode.
  /// Without it, tapping Custom and leaving without typing hands [dispose] an
  /// empty field, which it reads as "no ceiling was chosen" and folds back to
  /// Auto — silently discarding the preset the user was on.
  void _selectCustom() {
    if (_controller.text.isEmpty && _lamports != null) {
      _controller.text = formatPriorityFeeSol(_lamports!);
    }
    setState(() => _custom = true);
  }

  void _selectTier(PriorityFeeTier tier) {
    _custom = false;
    _controller.clear();
    _lamports = tier == PriorityFeeTier.auto ? null : tier.lamports;
    _service.set(_lamports);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final solPrice = sl<TokenPriceService>().priceOf(mallow_tokens.solMint);
    final typed = double.tryParse(_controller.text) ?? 0;
    final usd = solPrice == null ? null : typed * solPrice;

    return SettingsPageScaffold(
      title: 'Priority Fee',
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        children: [
          Text(
            kPriorityFeeExplainer,
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: MallowTheme.spacingLg),
          for (final tier in PriorityFeeTier.values)
            _OptionRow(
              label: tier.label,
              trailing: tier == PriorityFeeTier.auto
                  ? null
                  : priorityFeeLabel(tier.lamports),
              isSelected:
                  !_custom &&
                  (tier == PriorityFeeTier.auto
                      ? _lamports == null
                      : _lamports == tier.lamports),
              onTap: () => _selectTier(tier),
            ),
          _OptionRow(
            label: 'Custom',
            trailing: null,
            isSelected: _custom,
            onTap: _selectCustom,
          ),
          if (_custom) ...[
            const SizedBox(height: MallowTheme.spacing12),
            TextField(
              controller: _controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,9}')),
              ],
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              // `onSubmitted`, not `onEditingComplete`: overriding the latter
              // replaces the default handler that dismisses the keyboard, so
              // the number pad's done key would commit but never close.
              onSubmitted: (_) => _commitCustom(),
              decoration: InputDecoration(
                hintText: 'Priority fee in SOL',
                suffixText: usd == null ? null : '~\$${usd.toStringAsFixed(2)}',
                suffixStyle: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
                filled: true,
                fillColor: colors.surfaceMuted,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(MallowTheme.radiusMd),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: MallowTheme.spacingXs),
            Text(
              kPriorityFeeMaxHint,
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.trailing,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final String? trailing;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final color = isSelected ? colors.accent : colors.textPrimary;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: MallowTheme.uiBody.copyWith(color: color),
                ),
              ),
              if (trailing case final t?) ...[
                Text(
                  t,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(width: MallowTheme.spacingSm),
              ],
              if (isSelected)
                MallowSvgIcon(
                  'assets/icons/checkmark.svg',
                  width: 16,
                  height: 16,
                  color: color,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
