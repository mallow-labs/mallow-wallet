import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/services/pending_evm_tx.dart';
import '../../../core/services/preferences_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../models/eth_gas.dart';

/// Data resolved before the Edit Gas Fee sheet can render its live market.
@immutable
class EditGasFeeSheetData {
  const EditGasFeeSheetData({
    required this.market,
    required this.selection,
    required this.estimatedGasUsed,
    required this.defaultGasLimit,
    required this.ethPriceUsd,
    required this.title,
    required this.replacementFloor,
  });

  final EthGasMarket market;
  final EthGasSelection selection;
  final BigInt estimatedGasUsed;
  final int defaultGasLimit;
  final double? ethPriceUsd;
  final String title;
  final EvmFeeCaps replacementFloor;
}

/// Opens the Edit Gas Fee sheet
/// over the send confirm step. Returns the fee the user applied, or null if
/// they cancelled. The chosen tier / custom fee is persisted to
/// [PreferencesService] here (mirroring the swap-settings pattern); the caller
/// dispatches the returned selection into the send bloc.
///
/// [title] retitles the root page — "Speed Up Transaction" when the sheet is
/// re-pricing a stuck transaction rather than an unsent one.
///
/// [replacementFloor] switches the sheet into **replacement mode**, used by the
/// speed-up flow: every fee it offers (Low, Market, and the prefilled Advanced
/// values) is raised per-field to at least the floor — silently, since a
/// replacement below the node's 10% bump is simply rejected — and the displayed
/// estimates reflect the floored values. The gas-limit control is not offered:
/// a replacement replays the original transaction, and changing its limit would
/// invalidate the estimate that transaction was gated on. Nothing is persisted
/// to [PreferencesService] in this mode either — a floored, transaction-specific
/// fee is not the user's default send fee.
Future<EthGasSelection?> showEditGasFeeSheet(
  BuildContext context, {
  required EthGasMarket market,
  required EthGasSelection selection,
  required BigInt estimatedGasUsed,
  required int defaultGasLimit,
  double? ethPriceUsd,
  String title = 'Edit Gas Fee',
  EvmFeeCaps? replacementFloor,
}) {
  return showMallowSheet<EthGasSelection>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _EditGasFeeSheet(
      market: market,
      selection: selection,
      estimatedGasUsed: estimatedGasUsed,
      defaultGasLimit: defaultGasLimit,
      ethPriceUsd: ethPriceUsd,
      title: title,
      replacementFloor: replacementFloor,
    ),
  );
}

/// Opens the Edit Gas Fee sheet immediately while [preparation] resolves its
/// live fee market. The same sheet route changes from a loading state to the
/// normal fee editor once the data arrives.
Future<EthGasSelection?> showEditGasFeeSheetLoading(
  BuildContext context, {
  required Future<EditGasFeeSheetData> preparation,
  required ValueChanged<Object> onPreparationError,
}) {
  return showMallowSheet<EthGasSelection>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _EditGasFeeSheetLoader(
      preparation: preparation,
      onPreparationError: onPreparationError,
    ),
  );
}

class _EditGasFeeSheetLoader extends StatefulWidget {
  const _EditGasFeeSheetLoader({
    required this.preparation,
    required this.onPreparationError,
  });

  final Future<EditGasFeeSheetData> preparation;
  final ValueChanged<Object> onPreparationError;

  @override
  State<_EditGasFeeSheetLoader> createState() => _EditGasFeeSheetLoaderState();
}

class _EditGasFeeSheetLoaderState extends State<_EditGasFeeSheetLoader> {
  var _reportedError = false;

  void _reportError(Object error) {
    if (_reportedError) return;
    _reportedError = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onPreparationError(error);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EditGasFeeSheetData>(
      future: widget.preparation,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          _reportError(snapshot.error!);
          return _editGasFeeSheetLoading(context);
        }
        final data = snapshot.data;
        if (data == null) return _editGasFeeSheetLoading(context);
        return _EditGasFeeSheet(
          market: data.market,
          selection: data.selection,
          estimatedGasUsed: data.estimatedGasUsed,
          defaultGasLimit: data.defaultGasLimit,
          ethPriceUsd: data.ethPriceUsd,
          title: data.title,
          replacementFloor: data.replacementFloor,
        );
      },
    );
  }
}

Widget _editGasFeeSheetLoading(BuildContext context) {
  final colors = context.mallowColors;
  return Container(
    decoration: BoxDecoration(
      color: colors.bgPrimary,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(MallowTheme.popupRadius),
      ),
    ),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Speed Up Transaction', style: MallowTheme.editorialSection),
              const SizedBox(height: MallowTheme.spacingXl),
              SizedBox.square(
                dimension: 32,
                child: CircularProgressIndicator(
                  color: colors.accent,
                  strokeWidth: 2,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: sheetBottomInset(context, includeKeyboard: false)),
      ],
    ),
  );
}

enum _Page { root, advanced }

class _EditGasFeeSheet extends StatefulWidget {
  const _EditGasFeeSheet({
    required this.market,
    required this.selection,
    required this.estimatedGasUsed,
    required this.defaultGasLimit,
    required this.ethPriceUsd,
    required this.title,
    required this.replacementFloor,
  });

  final EthGasMarket market;
  final EthGasSelection selection;
  final BigInt estimatedGasUsed;
  final int defaultGasLimit;
  final double? ethPriceUsd;
  final String title;

  /// Non-null in replacement (speed-up) mode — see [showEditGasFeeSheet].
  final EvmFeeCaps? replacementFloor;

  @override
  State<_EditGasFeeSheet> createState() => _EditGasFeeSheetState();
}

class _EditGasFeeSheetState extends State<_EditGasFeeSheet> {
  final _prefs = sl<PreferencesService>();

  var _page = _Page.root;
  late EthGasMode _mode = widget.selection.mode;

  // Advanced-page inputs, seeded from the current selection (floored first in
  // replacement mode, so the prefilled values are already bump-compliant).
  late final EthGasSelection _seed = _flooredSelection(widget.selection);
  late final _maxBaseFeeController = TextEditingController(
    text: _trimGwei(_seed.maxBaseFeeGwei),
  );
  late final _priorityController = TextEditingController(
    text: _trimGwei(_seed.priorityFeeGwei),
  );
  late final _gasLimitController = TextEditingController(
    text: widget.selection.gasLimit.toString(),
  );

  @override
  void dispose() {
    _maxBaseFeeController.dispose();
    _priorityController.dispose();
    _gasLimitController.dispose();
    super.dispose();
  }

  EthGasMarket get _market => widget.market;

  /// True while re-pricing an already-broadcast transaction (speed up).
  bool get _isReplacement => widget.replacementFloor != null;

  /// Gas limit a **preset** tier (Low / Market) carries: always the caller's
  /// default. The Advanced page's typed limit belongs to an *applied* Advanced
  /// edit only — text left behind by an abandoned one (typed, then backed out
  /// with the arrow, which keeps the controller alive) must never ride along
  /// with a preset. Downstream ([effectiveSignedGasLimit]) only floors an
  /// override that is too *low*, so a leaked inflated limit is signed verbatim:
  /// it either fails a previously-fine native send on the worst-case budget
  /// check (`value + gasLimit × maxFeePerGas`) or signs a nonsense limit for an
  /// ERC-20 / NFT transfer.
  int get _presetGasLimit => widget.defaultGasLimit;

  /// Gas limit an applied Advanced edit carries: the typed value, falling back
  /// to the caller's default when empty/unparseable. Fixed to the default in
  /// replacement mode — the limit control isn't offered there.
  int get _advancedGasLimit => _isReplacement
      ? widget.defaultGasLimit
      : (int.tryParse(_gasLimitController.text) ?? widget.defaultGasLimit);

  // ── Selection resolution ────────────────────────────────────────────────

  /// Raise [maxFeePerGas]/[maxPriorityFeePerGas] to the replacement floor,
  /// per field. A no-op outside replacement mode.
  EvmFeeCaps _flooredCaps(BigInt maxFeePerGas, BigInt maxPriorityFeePerGas) =>
      applyReplacementFloor((
        maxFeePerGas: maxFeePerGas,
        maxPriorityFeePerGas: maxPriorityFeePerGas,
      ), widget.replacementFloor);

  /// [selection] with its caps raised to the replacement floor, keeping its
  /// mode and ETA. A no-op outside replacement mode.
  EthGasSelection _flooredSelection(EthGasSelection selection) {
    if (!_isReplacement) return selection;
    final caps = _flooredCaps(
      selection.maxFeePerGas,
      selection.maxPriorityFeePerGas,
    );
    return EthGasSelection(
      mode: selection.mode,
      maxFeePerGas: caps.maxFeePerGas,
      maxPriorityFeePerGas: caps.maxPriorityFeePerGas,
      // Replacement mode only (the early return above covers the rest): the
      // limit is always the entry's own, never the Advanced text.
      gasLimit: widget.defaultGasLimit,
      speedEta: selection.speedEta,
    );
  }

  /// The selection implied by a preset tier.
  EthGasSelection _tierSelection(EthGasMode mode) => _flooredSelection(
    EthGasSelection.fromTier(_market.tierFor(mode), gasLimit: _presetGasLimit),
  );

  /// The custom selection built from the Advanced inputs (falls back to sane
  /// defaults for empty/unparseable fields).
  EthGasSelection _customSelection() {
    final maxBase =
        double.tryParse(_maxBaseFeeController.text) ?? _seed.maxBaseFeeGwei;
    final priority =
        double.tryParse(_priorityController.text) ?? _seed.priorityFeeGwei;
    return _flooredSelection(
      EthGasSelection.custom(
        maxBaseFeeGwei: maxBase,
        priorityFeeGwei: priority,
        gasLimit: _advancedGasLimit,
      ),
    );
  }

  Future<void> _applyPresetAndClose() async {
    // A still-custom selection reached Done without entering Advanced — keep it
    // verbatim (and its persisted knobs) rather than downgrading to a preset.
    if (_mode == EthGasMode.custom) {
      if (mounted) {
        Navigator.of(context).pop(_flooredSelection(widget.selection));
      }
      return;
    }
    final selection = _tierSelection(_mode);
    if (!_isReplacement) {
      await _prefs.setEthGasMode(_mode == EthGasMode.low ? 'low' : 'market');
    }
    if (mounted) Navigator.of(context).pop(selection);
  }

  Future<void> _applyCustomAndClose() async {
    final selection = _customSelection();
    if (!_isReplacement) {
      await _prefs.setEthGasMode('custom');
      await _prefs.setEthGasMaxBaseFeeGwei(selection.maxBaseFeeGwei);
      await _prefs.setEthGasPriorityFeeGwei(selection.priorityFeeGwei);
      // The gas limit is NOT persisted: it is per-transaction (the padded
      // estimate differs per transfer — a native send vs an ERC-721
      // safeTransferFrom), and replaying a saved limit onto another transfer
      // risks signing far too little gas. It rides through this session as the
      // applied selection; the next transfer re-seeds it from its own fresh
      // estimate.
    }
    if (mounted) Navigator.of(context).pop(selection);
  }

  // ── Build ────────────────────────────────────────────────────────────────

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
                _Page.root => _rootPage(context),
                _Page.advanced => _advancedPage(context),
              },
            ),
          ),
          SizedBox(height: bottomPad),
        ],
      ),
    );
  }

  // ── Root page ──────────────────────────────────────────────────────────

  Widget _rootPage(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(
          context,
          widget.title,
          onBack: () => Navigator.of(context).pop(),
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        _tierRow(context, _market.low),
        _divider(context),
        _tierRow(context, _market.market),
        _divider(context),
        _advancedRow(context),
        const SizedBox(height: MallowTheme.spacingLg),
        _networkStatusCard(context),
        const SizedBox(height: MallowTheme.spacingLg),
        _actionButtons(context, onDone: _applyPresetAndClose),
      ],
    );
  }

  Widget _tierRow(BuildContext context, EthGasTier tier) {
    final colors = context.mallowColors;
    final eth = _tierEthCost(tier);
    final usd = widget.ethPriceUsd == null ? null : eth * widget.ethPriceUsd!;
    return GestureDetector(
      onTap: () => setState(() => _mode = tier.mode),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingSm),
        child: Row(
          children: [
            _radio(context, selected: _mode == tier.mode),
            const SizedBox(width: MallowTheme.spacing12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tier.label,
                    style: MallowTheme.editorialQuote.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingXs),
                  Text(
                    tier.speedRangeLabel,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _fmtUsd(usd) ?? '',
                  style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: MallowTheme.spacingXs),
                Text(
                  '${stripTrailingZeros(eth.toStringAsFixed(9))} ETH',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _advancedRow(BuildContext context) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: () => setState(() => _page = _Page.advanced),
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingSm),
          child: Row(
            children: [
              _radio(context, selected: _mode == EthGasMode.custom),
              const SizedBox(width: MallowTheme.spacing12),
              Text(
                'Advanced',
                style: MallowTheme.editorialQuote.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(width: MallowTheme.spacingXs),
              MallowSvgIcon(
                'assets/icons/arrow_right.svg',
                width: 14,
                height: 14,
                color: colors.textPrimary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _networkStatusCard(BuildContext context) {
    final colors = context.mallowColors;
    final baseFee =
        '${_trimGwei(EthGasMarket.weiToGwei(_market.baseFeeWei))} GWEI';
    final priority =
        '${_trimGwei(EthGasMarket.weiToGwei(_market.priorityLowWei))} - '
        '${_trimGwei(EthGasMarket.weiToGwei(_market.priorityHighWei))} GWEI';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Network status',
          style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: MallowTheme.spacing12),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacingSm,
            vertical: MallowTheme.spacingLg,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _statusMetric(context, 'Base fee', baseFee)),
              const SizedBox(width: MallowTheme.spacing12),
              Expanded(child: _statusMetric(context, 'Priority fee', priority)),
              const SizedBox(width: MallowTheme.spacing12),
              Expanded(child: _statusCongestion(context)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusMetric(BuildContext context, String label, String value) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: MallowTheme.spacingXs),
        Text(
          value,
          style: MallowTheme.uiIdentity.copyWith(color: colors.textPrimary),
        ),
      ],
    );
  }

  Widget _statusCongestion(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Status',
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: MallowTheme.spacingXs),
        ClipRRect(
          borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          child: LinearProgressIndicator(
            value: _market.congestion.clamp(0.0, 1.0),
            minHeight: 2,
            backgroundColor: colors.divider,
            valueColor: AlwaysStoppedAnimation(colors.accent),
          ),
        ),
        const SizedBox(height: MallowTheme.spacingXs),
        Text(
          _market.statusLabel,
          style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
        ),
      ],
    );
  }

  // ── Advanced page ────────────────────────────────────────────────────────

  Widget _advancedPage(BuildContext context) {
    final maxBase = double.tryParse(_maxBaseFeeController.text) ?? 0;
    final priority = double.tryParse(_priorityController.text) ?? 0;
    final gasLimit = _advancedGasLimit;

    // Floored in replacement mode: the sheet may quote more than the typed
    // values because that is what a bump-compliant replacement costs.
    final caps = _flooredCaps(
      EthGasMarket.gweiToWei(maxBase) + EthGasMarket.gweiToWei(priority),
      EthGasMarket.gweiToWei(priority),
    );
    final maxFeeUsd = _feeUsd(caps.maxFeePerGas, gasLimit);
    final priorityUsd = _feeUsd(caps.maxPriorityFeePerGas, gasLimit);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(
          context,
          'Edit Advanced Gas Fee',
          onBack: () => setState(() => _page = _Page.root),
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        _advancedField(
          context,
          label: 'Max base fee',
          currentText:
              'Current ${_trimGwei(EthGasMarket.weiToGwei(_market.baseFeeWei))} GWEI',
          rangeText:
              '12 hr: ${_trimGwei(EthGasMarket.weiToGwei(_market.historicalBaseFeeMinWei))} - '
              '${_trimGwei(EthGasMarket.weiToGwei(_market.historicalBaseFeeMaxWei))} GWEI',
          controller: _maxBaseFeeController,
          suffixText: 'GWEI',
          trailingText: _fmtUsd(maxFeeUsd),
          infoText:
              "The maximum you'll pay for the base network fee, regardless of "
              'conditions.',
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        _advancedField(
          context,
          label: 'Priority fee',
          currentText:
              'Current ${_trimGwei(EthGasMarket.weiToGwei(_market.priorityLowWei))} - '
              '${_trimGwei(EthGasMarket.weiToGwei(_market.priorityHighWei))} GWEI',
          rangeText:
              '12 hr: ${_trimGwei(EthGasMarket.weiToGwei(_market.historicalPriorityMinWei))} - '
              '${_trimGwei(EthGasMarket.weiToGwei(_market.historicalPriorityMaxWei))} GWEI',
          controller: _priorityController,
          suffixText: 'GWEI',
          trailingText: _fmtUsd(priorityUsd),
          infoText:
              'An optional tip to validators to prioritise your transaction in '
              'the queue.',
        ),
        // Not offered for a replacement: it replays the original transaction,
        // whose gas limit was estimated (and gated) for that exact payload.
        if (!_isReplacement) ...[
          const SizedBox(height: MallowTheme.spacingLg),
          _advancedField(
            context,
            label: 'Gas limit',
            controller: _gasLimitController,
            integerOnly: true,
            infoText:
                "The maximum amount of computational work you'll allow for "
                'this transaction.',
          ),
        ],
        const SizedBox(height: MallowTheme.spacingLg),
        _actionButtons(context, onDone: _applyCustomAndClose),
      ],
    );
  }

  Widget _advancedField(
    BuildContext context, {
    required String label,
    required TextEditingController controller,
    String? currentText,
    String? rangeText,
    String? suffixText,
    String? trailingText,
    String? infoText,
    bool integerOnly = false,
  }) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            if (currentText != null)
              Text(
                currentText,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
          ],
        ),
        const SizedBox(height: MallowTheme.spacing12),
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border.all(color: colors.divider),
            borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  keyboardType: integerOnly
                      ? TextInputType.number
                      : const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      integerOnly ? RegExp(r'\d') : RegExp(r'^\d*\.?\d*'),
                    ),
                  ],
                  onChanged: (_) => setState(() {}),
                  style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    suffixText: suffixText,
                    suffixStyle: MallowTheme.uiBody.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
              if (trailingText != null)
                Text(
                  trailingText,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        if (rangeText != null) ...[
          const SizedBox(height: MallowTheme.spacingSm),
          Text(
            rangeText,
            textAlign: TextAlign.right,
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
        ],
        if (infoText != null) ...[
          const SizedBox(height: MallowTheme.spacing12),
          Container(
            padding: const EdgeInsets.all(MallowTheme.spacing12),
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: BorderRadius.circular(MallowTheme.radiusSm),
            ),
            child: Text(
              infoText,
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ── Shared pieces ──────────────────────────────────────────────────────

  Widget _header(BuildContext context, String title, {VoidCallback? onBack}) {
    return Row(
      children: [
        if (onBack != null)
          TapTargetExpander(
            child: GestureDetector(
              onTap: onBack,
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

  Widget _actionButtons(BuildContext context, {required VoidCallback onDone}) {
    return Row(
      children: [
        Expanded(
          child: MallowButton(
            label: 'Cancel',
            variant: MallowButtonVariant.secondary,
            onPressed: () => Navigator.of(context).pop(),
            isFullWidth: true,
          ),
        ),
        const SizedBox(width: MallowTheme.spacingSm),
        Expanded(
          child: MallowButton(
            label: 'Done',
            onPressed: onDone,
            isFullWidth: true,
          ),
        ),
      ],
    );
  }

  Widget _radio(BuildContext context, {required bool selected}) {
    final colors = context.mallowColors;
    return Container(
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
    );
  }

  Widget _divider(BuildContext context) => Divider(
    height: MallowTheme.spacingLg,
    thickness: 1,
    color: context.mallowColors.divider,
  );

  // ── Formatting / math ────────────────────────────────────────────────────

  /// Expected ETH fee for a preset tier: estimated gas × (base fee + tip,
  /// capped at the tier's maxFee). Priced off the *floored* caps in
  /// replacement mode, so the displayed estimate is what would actually be
  /// signed.
  double _tierEthCost(EthGasTier tier) {
    final caps = _flooredCaps(tier.maxFeePerGas, tier.maxPriorityFeePerGas);
    final expected = _market.baseFeeWei + caps.maxPriorityFeePerGas;
    final effective = expected < caps.maxFeePerGas
        ? expected
        : caps.maxFeePerGas;
    return (widget.estimatedGasUsed * effective).toDouble() / 1e18;
  }

  /// USD of a per-gas price applied over [gasLimit], or null without a price.
  double? _feeUsd(BigInt perGasWei, int gasLimit) {
    if (widget.ethPriceUsd == null) return null;
    final feeEth = (BigInt.from(gasLimit) * perGasWei).toDouble() / 1e18;
    return feeEth * widget.ethPriceUsd!;
  }

  static String? _fmtUsd(double? usd) =>
      usd == null ? null : '~\$${usd.toStringAsFixed(2)}';

  static String _trimGwei(double gwei) => gwei == 0
      ? '0'
      : stripTrailingZeros(gwei.toStringAsFixed(gwei >= 1 ? 4 : 8));
}
