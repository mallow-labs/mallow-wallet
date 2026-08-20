import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';

/// Bottom sheet for entering a raffle ticket count. Returns the parsed count
/// on "Buy", or null when cancelled/dismissed — the same contract the old
/// [AlertDialog] had, so callers are unchanged.
///
/// 🛑 **Unreachable while `kShowRaffleEntry` is off** (store builds — see
/// `core/config/store_build.dart`). Its
/// one push site is `artwork_detail_screen/actions.dart::_onBuyRaffleTickets`,
/// reached only from `ArtworkRaffleSheet.onBuyTickets`, which the flag
/// replaces with a "View on mallow.art" outlink. The sheet is left intact so
/// re-enabling entry is a flag flip, not a re-implementation — do not add a
/// new caller without gating it on that flag.
class RaffleTicketSheet extends StatefulWidget {
  const RaffleTicketSheet({
    this.unitPriceRaw,
    this.currencyMint,
    this.maxTickets,
    super.key,
  });

  /// Ticket price in **raw base units** of [currencyMint]
  /// (`RaffleMetadata.priceRaw`). Null hides the cost line.
  final double? unitPriceRaw;
  final String? currencyMint;

  /// Ceiling for the ticket count — `min(remaining supply, wallet limit -
  /// tickets already held)`, the same cap the webapp applies to its quantity
  /// picker (`BuyTicketsModal`).
  /// Null leaves the field uncapped.
  final int? maxTickets;

  @override
  State<RaffleTicketSheet> createState() => _RaffleTicketSheetState();
}

class _RaffleTicketSheetState extends State<RaffleTicketSheet> {
  final _controller = TextEditingController(text: '1');
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  int? get _count {
    final value = int.tryParse(_controller.text.trim());
    if (value == null || value <= 0) return null;
    final max = widget.maxTickets;
    if (max != null && value > max) return null;
    return value;
  }

  /// "Total: 0.3 SOL" for the typed count. Null when there's no price or no
  /// valid count. Mirrors the webapp's `getTotalPrice`
  /// (`useBuyTickets`):
  /// `ticketPrice × ticketCount`, in base units, formatted through the token's
  /// decimals.
  String? get _totalLabel {
    final unit = widget.unitPriceRaw;
    final count = _count;
    if (unit == null || count == null) return null;
    final token = tokenByMint(widget.currencyMint ?? solMint);
    if (token == null) return null;
    final total = token.rawToDisplay((unit * count).round());
    return 'Total: ${displayDecimal(total)} ${token.symbol}';
  }

  void _onBuy() {
    final value = _count;
    if (value == null) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      padding: const EdgeInsets.all(MallowTheme.spacing20),
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetDragHandle(),
          Text(
            'Buy raffle tickets',
            style: MallowTheme.editorialSubhead.copyWith(
              color: colors.textPrimary,
            ),
            textAlign: TextAlign.left,
          ),
          const SizedBox(height: MallowTheme.spacingLg),
          Text(
            'Ticket count',
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          MallowPillField(
            controller: _controller,
            focusNode: _focusNode,
            hintText: '1',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _onBuy(),
          ),
          if (widget.maxTickets != null) ...[
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              'Max ${widget.maxTickets} for this wallet',
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
          if (_totalLabel != null) ...[
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              _totalLabel!,
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
          ],
          const SizedBox(height: MallowTheme.spacingLg),
          Row(
            children: [
              Expanded(
                child: MallowButton(
                  label: 'Cancel',
                  variant: MallowButtonVariant.secondary,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: MallowTheme.spacingMd),
              Expanded(
                child: MallowButton(
                  label: 'Buy',
                  enabled: _count != null,
                  onPressed: _count == null ? null : _onBuy,
                ),
              ),
            ],
          ),
          SizedBox(height: sheetBottomInset(context)),
        ],
      ),
    );
  }
}
