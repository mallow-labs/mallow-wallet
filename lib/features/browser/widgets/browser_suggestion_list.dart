import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tappable.dart';
import '../services/browser_suggestions.dart';
import 'browser_host_text.dart';
import 'browser_site_tile.dart';

/// The address bar's suggestions, as a card under the field.
///
/// A row leads with the site's host, which says whose site it is; the name
/// beside it is decoration. Sits in the field's tap region, so a tap on a
/// row does not first take the focus, and the list, away from the field.
class BrowserSuggestionList extends StatelessWidget {
  const BrowserSuggestionList({
    required this.suggestions,
    required this.onOpen,
    this.maxHeight = double.infinity,
    super.key,
  });

  final List<BrowserSuggestion> suggestions;
  final ValueChanged<BrowserSuggestion> onOpen;

  /// The card scrolls past this height (the room above the keyboard).
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
    final colors = context.mallowColors;
    return TextFieldTapRegion(
      child: Container(
        key: const Key('browser-suggestions'),
        constraints: BoxConstraints(maxHeight: maxHeight.clamp(0, 10000)),
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: colors.dividerLight),
          boxShadow: [
            BoxShadow(
              color: colors.shadow.withValues(alpha: 0.10),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final suggestion in suggestions)
                _SuggestionRow(
                  suggestion: suggestion,
                  onTap: () => onOpen(suggestion),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.suggestion, required this.onTap});

  final BrowserSuggestion suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final url = suggestion.url;
    final host = url.host;
    final path = url.path == '/' ? '' : url.path;
    final name = suggestion.name.trim();
    final bookmark = suggestion.source == BrowserSuggestionSource.bookmark;
    return Semantics(
      button: true,
      label: [
        'Open $host$path',
        if (name.isNotEmpty && name != host) name,
        if (bookmark) 'Bookmark',
      ].join(', '),
      excludeSemantics: true,
      child: Tappable(
        key: ValueKey('browser-suggestion-$url'),
        onTap: onTap,
        semanticButton: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              BrowserSiteTile(
                host: host,
                iconUrl: suggestion.iconUrl,
                size: 32,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    BrowserHostText(
                      host,
                      detail: path.isEmpty ? null : path,
                      separator: '',
                      style: MallowTheme.uiLabel.copyWith(
                        color: colors.textPrimary,
                      ),
                      detailStyle: TextStyle(color: colors.textSecondary),
                    ),
                    if (name.isNotEmpty && name != host)
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MallowTheme.uiMeta.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (bookmark) ...[
                const SizedBox(width: 8),
                MallowSvgIcon(
                  'assets/icons/bookmark.svg',
                  width: 16,
                  height: 16,
                  color: colors.textTertiary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
