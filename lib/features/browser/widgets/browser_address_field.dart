import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../models/browser_models.dart';
import '../services/browser_services.dart';
import '../services/browser_session.dart';
import '../services/browser_suggestions.dart';
import 'browser_address_bar.dart';
import 'browser_bottom_bar.dart';
import 'browser_suggestion_list.dart';

/// Edits the full URL in the top address bar, with the same input as a new
/// tab, and suggests sites under it once the text is edited.
class BrowserAddressField extends StatefulWidget {
  const BrowserAddressField({
    required this.initial,
    required this.onOpen,
    this.session,
    super.key,
  });

  /// The full committed URL, preselected so typing replaces it.
  final String initial;
  final ValueChanged<Uri> onOpen;

  /// Supplies the suggestions and records typed addresses. Defaults to the
  /// browser's session if one is running; with none the field only parses.
  final BrowserSession? session;

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
  late final _session = widget.session ?? BrowserSession.existing;
  String? _error;

  @override
  void dispose() {
    _focus.dispose();
    _input.dispose();
    super.dispose();
  }

  void _go() {
    try {
      final uri = browserInputUri(
        _input.text,
        engine: browserSearchEngine.value,
      );
      if (browserAddressUri(_input.text) != null) _session?.noteTyped(uri);
      widget.onOpen(uri);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      _focus.requestFocus();
    }
  }

  void _pick(BrowserSuggestion suggestion) {
    _session?.noteTyped(suggestion.url);
    widget.onOpen(suggestion.url);
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) return _field(context);
    final media = MediaQuery.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(context),
        ListenableBuilder(
          listenable: Listenable.merge([_input, session, browserSites]),
          builder: (context, _) {
            // The committed URL, untouched, is not a query.
            final text = _input.text;
            final suggestions = text == widget.initial
                ? const <BrowserSuggestion>[]
                : session.suggestions(text);
            if (suggestions.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: BrowserSuggestionList(
                suggestions: suggestions,
                onOpen: _pick,
                // Above the keyboard, below the field and the status bar.
                maxHeight:
                    media.size.height -
                    media.viewInsets.bottom -
                    media.padding.top -
                    BrowserAddressBar.capsuleHeight -
                    32,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _field(BuildContext context) {
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
