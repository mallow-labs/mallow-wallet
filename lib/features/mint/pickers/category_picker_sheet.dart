import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/full_screen_sheet.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tappable.dart';

/// The same 26-category list the webapp's `create` page ships. Kept in
/// sync with `categories`.
const mintCategoryOptions = <String>[
  '3D',
  'Abstract',
  'AI',
  'Animation',
  'Architecture',
  'Collage',
  'Comic',
  'Digital Art',
  'Generative',
  'Glitch',
  'Illustration',
  'Landscape',
  'Music',
  'Nude',
  'Painting',
  'PFP',
  'Photography',
  'Pixelart',
  'Poetry',
  'Portrait',
  'Psychedelic',
  'Sculpture',
  'Short Film',
  'Surrealism',
  'Textile',
  'Video',
];

/// Convert a category display name to its tag id — mirrors the webapp's
/// `toDisplayId` (lowercase + spaces → dashes). e.g. `"Short Film" → "short-film"`.
String mintCategoryIdFor(String displayName) =>
    displayName.toLowerCase().replaceAll(' ', '-');

/// Set of canonical category tag ids for fast membership tests.
final Set<String> mintCategoryIdSet = mintCategoryOptions
    .map(mintCategoryIdFor)
    .toSet();

/// Map from canonical category tag id back to its display name.
final Map<String, String> _mintCategoryIdToDisplay = {
  for (final name in mintCategoryOptions) mintCategoryIdFor(name): name,
};

/// Tags that aren't recognized category ids — i.e. the user-entered tags.
List<String> mintFilterOutCategories(List<String> tags) =>
    tags.where((t) => !mintCategoryIdSet.contains(t)).toList(growable: false);

/// Display names of categories currently encoded in [tags].
List<String> mintCategoryDisplayNamesFromTags(List<String> tags) => [
  for (final t in tags)
    if (_mintCategoryIdToDisplay[t] != null) _mintCategoryIdToDisplay[t]!,
];

/// Full-screen multi-select for NFT categories. Returns the finalized
/// list when the user taps **Done**, or `null` if they dismiss.
Future<List<String>?> showMintCategoryPicker({
  required BuildContext context,
  required List<String> initial,
}) {
  return showFullScreenSheet<List<String>>(
    context: context,
    child: _CategoryPickerView(initial: initial),
  );
}

class _CategoryPickerView extends StatefulWidget {
  const _CategoryPickerView({required this.initial});

  final List<String> initial;

  @override
  State<_CategoryPickerView> createState() => _CategoryPickerViewState();
}

class _CategoryPickerViewState extends State<_CategoryPickerView> {
  late final Set<String> _selected = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: MallowTheme.spacingMd),
            child: Text(
              'Choose Categories',
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              textAlign: TextAlign.left,
            ),
          ),
          const SizedBox(height: MallowTheme.spacing20),
          Expanded(
            child: ListView.separated(
              itemCount: mintCategoryOptions.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(height: MallowTheme.spacingSm),
              itemBuilder: (context, index) {
                final category = mintCategoryOptions[index];
                final isSelected = _selected.contains(category);
                return _CategoryRow(
                  label: category,
                  selected: isSelected,
                  onTap: () => setState(() {
                    if (isSelected) {
                      _selected.remove(category);
                    } else {
                      _selected.add(category);
                    }
                  }),
                );
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.only(
              top: MallowTheme.spacingMd,
              bottom: sheetBottomInset(context),
            ),
            child: _DoneButton(
              onPressed: () => Navigator.of(context).pop(_selected.toList()),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingSm),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: selected ? colors.accent : Colors.transparent,
                border: Border.all(
                  color: selected ? colors.accent : colors.divider,
                ),
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              ),
              child: selected
                  ? MallowSvgIcon(
                      'assets/icons/checkmark.svg',
                      width: 16,
                      height: 16,
                      color: colors.textOnAccent,
                    )
                  : null,
            ),
            const SizedBox(width: MallowTheme.spacingMd),
            Expanded(
              child: Text(
                label,
                style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DoneButton extends StatelessWidget {
  const _DoneButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: Material(
        color: colors.accent,
        borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
        child: Tappable(
          onTap: onPressed,
          child: Center(
            child: Text(
              'Done',
              style: MallowTheme.uiBody.copyWith(color: colors.textOnAccent),
            ),
          ),
        ),
      ),
    );
  }
}
