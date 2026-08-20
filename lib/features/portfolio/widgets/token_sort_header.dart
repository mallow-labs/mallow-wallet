import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';

enum TokenSortOption { topValue, name }

extension TokenSortOptionLabel on TokenSortOption {
  String get label => switch (this) {
    TokenSortOption.topValue => 'Top value',
    TokenSortOption.name => 'Name',
  };
}

/// Tappable header showing current sort and opening the sort bottom sheet.
class TokenSortHeader extends StatelessWidget {
  const TokenSortHeader({
    required this.currentSort,
    required this.onSortChanged,
    super.key,
  });

  final TokenSortOption currentSort;
  final ValueChanged<TokenSortOption> onSortChanged;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          final result = await _showTokenSortSheet(
            context,
            currentSort: currentSort,
          );
          if (result != null) onSortChanged(result);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MallowSvgIcon(
                'assets/icons/arrows_sort.svg',
                width: 16,
                height: 16,
              ),
              const SizedBox(width: 4),
              Text(
                currentSort.label,
                style: MallowTheme.uiCaption.copyWith(
                  color: context.mallowColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<TokenSortOption?> _showTokenSortSheet(
  BuildContext context, {
  required TokenSortOption currentSort,
}) {
  return showMallowSheet<TokenSortOption>(
    context: context,
    backgroundColor: context.mallowColors.bgPrimary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(MallowTheme.popupRadius),
      ),
    ),
    builder: (context) => _TokenSortSheet(currentSort: currentSort),
  );
}

class _TokenSortSheet extends StatelessWidget {
  const _TokenSortSheet({required this.currentSort});

  final TokenSortOption currentSort;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: context.mallowColors.dividerLight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Title
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MallowTheme.spacing20,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Sort by', style: MallowTheme.editorialQuote),
              ),
            ),
            const SizedBox(height: 8),
            // Options
            for (final option in TokenSortOption.values)
              _TokenSortOptionTile(
                option: option,
                isSelected: option == currentSort,
                onTap: () => Navigator.of(context).pop(option),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _TokenSortOptionTile extends StatelessWidget {
  const _TokenSortOptionTile({
    required this.option,
    required this.isSelected,
    required this.onTap,
  });

  final TokenSortOption option;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacing20,
          vertical: 12,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                option.label,
                style: MallowTheme.uiBody.copyWith(
                  color: isSelected
                      ? context.mallowColors.textPrimary
                      : context.mallowColors.textSecondary,
                ),
              ),
            ),
            if (isSelected)
              MallowSvgIcon(
                'assets/icons/checkmark.svg',
                width: 18,
                height: 18,
                color: context.mallowColors.textPrimary,
              ),
          ],
        ),
      ),
    );
  }
}
