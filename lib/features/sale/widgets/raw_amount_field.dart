import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/mallow_pill_field.dart';

/// [MallowPillField] wrapper that handles display↔raw-amount conversion,
/// mid-edit preservation, and currency-decimal-aware input formatters.
///
/// [rawAmount] is the canonical bloc value (integer raw units).
/// [onChanged] receives the new raw value after each keystroke.
/// [hintText] is forwarded to [MallowPillField].
class RawAmountField extends StatefulWidget {
  const RawAmountField({
    required this.token,
    required this.rawAmount,
    required this.onChanged,
    this.hintText = '',
    super.key,
  });

  final MallowToken token;
  final int rawAmount;
  final ValueChanged<int> onChanged;
  final String hintText;

  @override
  State<RawAmountField> createState() => _RawAmountFieldState();
}

class _RawAmountFieldState extends State<RawAmountField> {
  late final TextEditingController _controller;
  String _lastEdited = '';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _formatRaw(widget.rawAmount));
    _lastEdited = _controller.text;
  }

  @override
  void didUpdateWidget(covariant RawAmountField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync from external state changes (e.g. token swap clearing the
    // amount), but don't clobber while the user is editing.
    final formatted = _formatRaw(widget.rawAmount);
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

  String _formatRaw(int raw) {
    if (raw <= 0) return '';
    final display = widget.token.rawToDisplay(raw);
    return stripTrailingZeros(
      display.toStringAsFixed(widget.token.inputDecimals),
    );
  }

  void _onChanged(String value) {
    _lastEdited = value;
    final parsed = double.tryParse(value);
    if (parsed == null) {
      widget.onChanged(0);
      return;
    }
    widget.onChanged(widget.token.displayToRaw(parsed));
  }

  @override
  Widget build(BuildContext context) {
    return MallowPillField(
      controller: _controller,
      hintText: widget.hintText,
      keyboardType: TextInputType.numberWithOptions(
        decimal: widget.token.inputDecimals > 0,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(
          widget.token.inputDecimals > 0
              ? RegExp(r'^\d*\.?\d*')
              : RegExp(r'^\d*'),
        ),
      ],
      onChanged: _onChanged,
    );
  }
}
