import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../models/browser_models.dart';
import '../services/browser_services.dart';
import 'browser_address_bar.dart';
import 'browser_bottom_bar.dart';

/// Edits the full URL in the top address bar, with the same input as a new tab.
class BrowserAddressField extends StatefulWidget {
  const BrowserAddressField({
    required this.initial,
    required this.onOpen,
    super.key,
  });

  /// The full committed URL, preselected so typing replaces it.
  final String initial;
  final ValueChanged<Uri> onOpen;

  @override
  State<BrowserAddressField> createState() => _BrowserAddressFieldState();
}

class _BrowserAddressFieldState extends State<BrowserAddressField> {
  final _focus = FocusNode();
  late final _input = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );
  String? _error;

  @override
  void dispose() {
    _focus.dispose();
    _input.dispose();
    super.dispose();
  }

  void _go() {
    try {
      widget.onOpen(
        browserInputUri(_input.text, engine: browserSearchEngine.value),
      );
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return MallowPillField(
      key: const Key('browser-address-field'),
      controller: _input,
      focusNode: _focus,
      autofocus: true,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      autocorrect: false,
      enableSuggestions: false,
      hintText: 'Search or enter website',
      errorText: _error,
      height: BrowserAddressBar.capsuleHeight,
      padding: const EdgeInsets.only(left: 18, right: 4),
      backgroundColor: colors.bgSurface,
      borderColor: colors.dividerLight,
      boxShadow: [
        BoxShadow(
          color: colors.shadow.withValues(alpha: 0.10),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ],
      prefix: MallowSvgIcon(
        'assets/icons/search.svg',
        width: 20,
        height: 20,
        color: colors.textSecondary,
      ),
      suffix: ValueListenableBuilder(
        valueListenable: _input,
        builder: (context, value, _) => value.text.isEmpty
            ? const SizedBox.shrink()
            : BrowserBarIconButton(
                asset: 'assets/icons/close.svg',
                label: 'Clear',
                size: 18,
                width: 40,
                onTap: () {
                  _input.clear();
                  setState(() => _error = null);
                  _focus.requestFocus();
                },
              ),
      ),
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
      onSubmitted: (_) => _go(),
    );
  }
}
