import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/data/mallow_tokens.dart' as mallow_tokens;
import '../../../core/services/preferences_service.dart';
import '../../../core/services/priority_fee_service.dart';
import '../../../core/services/token_price_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/tap_target_expander.dart';

import '../../../shared/utils/chain.dart';

/// Opens the swap settings sheet (slippage + priority fee). Selections are
/// persisted to [PreferencesService] / [PriorityFeeService] — callers re-read
/// them after the returned future completes.
///
/// The priority fee here is the **swap-specific override** (`setSwap`), not
/// the general Settings → Priority Fee value: a fee raised to force a swap
/// through a congested AMM route should not permanently re-price every send.
/// Leaving it on Auto falls back to the general value rather than to Auto.
///
/// [chain] is the chain the swap executes on — it drives the gas-token mark
/// shown in the custom priority fee field.
Future<void> showSwapSettingsSheet(
  BuildContext context, {
  Chain chain = Chain.solana,
}) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SwapSettingsSheet(chain: chain),
  );
}

enum _SettingsPage { root, slippage, priorityFee }

/// Slippage presets shown as radio options, in bps. `null` = Auto.
const _slippagePresetsBps = [50, 100, 200];

class _SwapSettingsSheet extends StatefulWidget {
  const _SwapSettingsSheet({required this.chain});

  final Chain chain;

  @override
  State<_SwapSettingsSheet> createState() => _SwapSettingsSheetState();
}

class _SwapSettingsSheetState extends State<_SwapSettingsSheet> {
  final _prefs = sl<PreferencesService>();
  final _priorityFee = sl<PriorityFeeService>();

  var _page = _SettingsPage.root;
  late int? _slippageBps = _prefs.swapSlippageBps;
  // The swap override as stored, not the resolved fee: showing the general
  // value here would copy it into the swap key on the next Done, silently
  // decoupling swaps from later Settings changes.
  late int? _priorityFeeLamports = _priorityFee.swapSelection.value;

  /// Whether the slippage page is in "Custom" mode — distinct from holding a
  /// preset value so the custom field stays visible while it's empty.
  late bool _customSlippage =
      _slippageBps != null && !_slippagePresetsBps.contains(_slippageBps);

  /// Whether the priority-fee page is in "Custom" mode. Same distinction: a
  /// value equal to a preset is the preset, not a custom entry.
  late bool _customPriorityFee =
      _priorityFeeLamports != null &&
      !PriorityFeeTier.values.any((t) => t.lamports == _priorityFeeLamports);

  late final _slippageController = TextEditingController(
    text: _customSlippage ? _formatPercent(_slippageBps!) : '',
  );
  late final _priorityFeeController = TextEditingController(
    text: _customPriorityFee ? _formatSol(_priorityFeeLamports!) : '',
  );

  @override
  void dispose() {
    // The sheet is drag/barrier dismissible, so a subpage edit can leave
    // without going through Done — persist here too (idempotent) so the
    // caller's `settingsChanged` always sees the final values and re-quotes.
    _persistSelections();
    _slippageController.dispose();
    _priorityFeeController.dispose();
    super.dispose();
  }

  static String _formatPercent(int bps) {
    final value = bps / 100;
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toString();
  }

  static String _formatSol(int lamports) =>
      stripTrailingZeros((lamports / 1e9).toStringAsFixed(9));

  void _persistAndShowRoot() {
    _persistSelections();
    setState(() => _page = _SettingsPage.root);
  }

  /// Folds the open subpage's field into the selection and writes both
  /// settings to [PreferencesService]. Safe to call repeatedly.
  void _persistSelections() {
    if (_page == _SettingsPage.slippage && _customSlippage) {
      final percent = double.tryParse(_slippageController.text);
      _slippageBps = percent == null
          ? null
          : (percent * 100).round().clamp(0, 10000);
      // An empty/unparseable custom value falls back to Auto.
      if (_slippageBps == null) _customSlippage = false;
    }
    if (_page == _SettingsPage.priorityFee && _customPriorityFee) {
      final sol = double.tryParse(_priorityFeeController.text);
      _priorityFeeLamports = sol == null || sol <= 0
          ? null
          : (sol * 1e9).round();
      // An empty/unparseable custom value falls back to Auto.
      if (_priorityFeeLamports == null) _customPriorityFee = false;
    }
    _prefs.setSwapSlippageBps(_slippageBps);
    // Clamping (and the Auto fold-back for a non-positive value) lives in the
    // service so both entry points share it. `setSwap`, not `set`: this sheet
    // owns the swap-specific override only.
    unawaited(_priorityFee.setSwap(_priorityFeeLamports));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final bottomPad = sheetBottomInset(context, includeKeyboard: false);
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: BoxDecoration(
        color: colors.bgPrimary,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetDragHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MallowTheme.spacing20,
              MallowTheme.spacing12,
              MallowTheme.spacing20,
              MallowTheme.spacing20,
            ),
            child: AnimatedSize(
              duration: MallowTheme.sheetDuration,
              curve: MallowTheme.sheetCurve,
              alignment: Alignment.topCenter,
              child: switch (_page) {
                _SettingsPage.root => _rootPage(context),
                _SettingsPage.slippage => _slippagePage(context),
                _SettingsPage.priorityFee => _priorityFeePage(context),
              },
            ),
          ),
          SizedBox(height: bottomPad),
        ],
      ),
    );
  }

  // ── Root ───────────────────────────────────────────────────────────────────

  Widget _rootPage(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Swap settings', style: MallowTheme.editorialSection),
        const SizedBox(height: MallowTheme.spacingLg),
        _settingsRow(
          context,
          label: 'Slippage',
          value: _slippageBps == null
              ? 'Auto'
              : '${_formatPercent(_slippageBps!)}%',
          onTap: () => setState(() => _page = _SettingsPage.slippage),
        ),
        const SizedBox(height: MallowTheme.spacing20),
        _settingsRow(
          context,
          label: 'Priority Fee',
          value: _priorityFeeLamports == null
              ? 'Auto'
              : '${_formatSol(_priorityFeeLamports!)} SOL',
          onTap: () => setState(() => _page = _SettingsPage.priorityFee),
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        MallowButton(
          label: 'Done',
          onPressed: () => Navigator.of(context).pop(),
          isFullWidth: true,
        ),
      ],
    );
  }

  Widget _settingsRow(
    BuildContext context, {
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            Expanded(child: Text(label, style: MallowTheme.uiBody)),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: MallowTheme.spacingSm,
                vertical: MallowTheme.spacingXs,
              ),
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              ),
              child: Text(
                value,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: MallowTheme.spacingSm),
            MallowSvgIcon(
              'assets/icons/arrow_right.svg',
              width: 12,
              height: 12,
              color: colors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  // ── Slippage ───────────────────────────────────────────────────────────────

  Widget _slippagePage(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _subpageHeader(context, 'Slippage'),
        const SizedBox(height: MallowTheme.spacing20),
        _infoCard(
          context,
          'Slippage is how much the swap rate can change before your '
          'transaction fails. Auto calculates the lowest slippage for a '
          'successful swap. If you set it too high, it could result in an '
          'unfavourable trade.',
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        _radioRow(
          context,
          label: 'Auto',
          selected: _slippageBps == null && !_customSlippage,
          onTap: () => setState(() {
            _slippageBps = null;
            _customSlippage = false;
          }),
        ),
        for (final bps in _slippagePresetsBps)
          _radioRow(
            context,
            label: '${_formatPercent(bps)}%',
            selected: !_customSlippage && _slippageBps == bps,
            onTap: () => setState(() {
              _slippageBps = bps;
              _customSlippage = false;
            }),
          ),
        _radioRow(
          context,
          label: 'Custom',
          selected: _customSlippage,
          onTap: () => setState(() => _customSlippage = true),
        ),
        if (_customSlippage) ...[
          const SizedBox(height: MallowTheme.spacing12),
          _inputField(
            context,
            controller: _slippageController,
            hintText: 'Slippage amount',
            suffix: Text(
              '%',
              style: MallowTheme.uiBody.copyWith(
                color: context.mallowColors.textSecondary,
              ),
            ),
          ),
        ],
        const SizedBox(height: MallowTheme.spacingLg),
        MallowButton(
          label: 'Done',
          onPressed: _persistAndShowRoot,
          isFullWidth: true,
        ),
      ],
    );
  }

  // ── Priority fee ───────────────────────────────────────────────────────────

  Widget _priorityFeePage(BuildContext context) {
    final colors = context.mallowColors;
    final solPrice = sl<TokenPriceService>().priceOf(mallow_tokens.solMint);
    final sol = double.tryParse(_priorityFeeController.text) ?? 0;
    final usd = solPrice == null ? null : sol * solPrice;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _subpageHeader(context, 'Priority Fee'),
        const SizedBox(height: MallowTheme.spacing20),
        _infoCard(context, kPriorityFeeExplainer),
        const SizedBox(height: MallowTheme.spacingLg),
        for (final tier in PriorityFeeTier.values)
          _radioRow(
            context,
            label: tier == PriorityFeeTier.auto
                ? tier.label
                : '${tier.label} · ${_formatSol(tier.lamports)} SOL',
            selected:
                !_customPriorityFee &&
                (tier == PriorityFeeTier.auto
                    ? _priorityFeeLamports == null
                    : _priorityFeeLamports == tier.lamports),
            onTap: () => setState(() {
              _priorityFeeLamports = tier == PriorityFeeTier.auto
                  ? null
                  : tier.lamports;
              _customPriorityFee = false;
              _priorityFeeController.clear();
            }),
          ),
        _radioRow(
          context,
          label: 'Custom',
          selected: _customPriorityFee,
          onTap: () => setState(() => _customPriorityFee = true),
        ),
        if (_customPriorityFee) ...[
          const SizedBox(height: MallowTheme.spacing12),
          _inputField(
            context,
            controller: _priorityFeeController,
            hintText: 'Priority Fee',
            prefix: MallowSvgIcon(
              widget.chain.iconAsset,
              width: 14,
              height: 14,
              color: colors.textSecondary,
            ),
            suffix: usd == null
                ? null
                : Text(
                    '~\$${usd.toStringAsFixed(2)}',
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: MallowTheme.spacingXs),
          Text(
            kPriorityFeeMaxHint,
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
        ],
        const SizedBox(height: MallowTheme.spacingLg),
        MallowButton(
          label: 'Done',
          onPressed: _persistAndShowRoot,
          isFullWidth: true,
        ),
      ],
    );
  }

  // ── Shared pieces ──────────────────────────────────────────────────────────

  Widget _subpageHeader(BuildContext context, String title) {
    return Row(
      children: [
        TapTargetExpander(
          child: GestureDetector(
            onTap: _persistAndShowRoot,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(right: MallowTheme.spacing12),
              child: MallowSvgIcon(
                'assets/icons/arrow_left.svg',
                width: 16,
                height: 16,
                color: context.mallowColors.textPrimary,
              ),
            ),
          ),
        ),
        Text(title, style: MallowTheme.editorialSection),
      ],
    );
  }

  Widget _infoCard(BuildContext context, String text) {
    final colors = context.mallowColors;
    return Container(
      padding: const EdgeInsets.all(MallowTheme.spacing12),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.radiusSm),
      ),
      child: Text(
        text,
        style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
      ),
    );
  }

  Widget _radioRow(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingSm),
          child: Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? colors.accent : colors.textSecondary,
                    width: 1.5,
                  ),
                ),
                child: selected
                    ? Center(
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colors.accent,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Text(label, style: MallowTheme.uiBody),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inputField(
    BuildContext context, {
    required TextEditingController controller,
    required String hintText,
    Widget? prefix,
    Widget? suffix,
    ValueChanged<String>? onChanged,
  }) {
    final colors = context.mallowColors;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border.all(color: colors.divider),
        borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
      ),
      child: Row(
        children: [
          if (prefix != null) ...[
            prefix,
            const SizedBox(width: MallowTheme.spacing12),
          ],
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
              ],
              onChanged: onChanged,
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: hintText,
                hintStyle: MallowTheme.uiBody.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
          ?suffix,
        ],
      ),
    );
  }
}
