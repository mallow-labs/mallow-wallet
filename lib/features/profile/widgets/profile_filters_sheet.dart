import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// Number of active constraints on [filter] — drives the filter button's count
/// badge. Shared by the profile and portfolio ("Your art") filter buttons so
/// they count identically.
int activeFilterCount(api.ExploreFilter? filter) {
  if (filter == null) return 0;
  var count =
      filter.listingTypes.length +
      filter.mediaTypes.length +
      filter.tags.length;
  if (filter.priceRange != null) count++;
  if (filter.search != null && filter.search!.isNotEmpty) count++;
  if (filter.mode != api.ExploreMode.all) count++;
  return count;
}

/// Returns [filter] when it carries at least one active constraint, otherwise
/// `null` so unfiltered fetches omit the filter entirely (matching the original
/// request shape). Shared by the profile and portfolio artwork-filter fetches.
api.ExploreFilter? activeFilterOrNull(api.ExploreFilter? filter) {
  if (filter == null) return null;
  final active =
      filter.listingTypes.isNotEmpty ||
      filter.mediaTypes.isNotEmpty ||
      filter.tags.isNotEmpty ||
      filter.priceRange != null ||
      (filter.search != null && filter.search!.isNotEmpty) ||
      filter.mode != api.ExploreMode.all;
  return active ? filter : null;
}

/// The sliders icon that opens the filters sheet, with a count badge when one
/// or more filters are active. Shared by the profile and portfolio filter
/// buttons; colors default to the theme's primary/accent tokens.
class FilterBadgeIcon extends StatelessWidget {
  const FilterBadgeIcon({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final icon = SvgPicture.asset(
      'assets/icons/sliders.svg',
      width: 24,
      height: 24,
      colorFilter: ColorFilter.mode(colors.textPrimary, BlendMode.srcIn),
    );
    if (count <= 0) return icon;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          top: -4,
          right: -4,
          child: Container(
            constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: colors.accent,
              borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
            ),
            alignment: Alignment.center,
            child: Text(
              '$count',
              style: MallowTheme.uiMeta.copyWith(
                color: colors.textOnAccent,
                fontSize: 10,
                height: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A selectable filter option: [id] is the value sent to the backend, [label]
/// is what the user sees. Mirrors the server's `toDisplayId` semantics.
typedef _Option = ({String id, String label});

/// Listing-type options — ids match the server's `ListingTypeDisplayIds`.
const _listingTypeOptions = <_Option>[
  (id: 'auction', label: 'Auction'),
  (id: 'buy-now', label: 'Fixed price'),
  (id: 'gumball', label: 'Gumball'),
  (id: 'jellybean', label: 'Jellybean'),
  (id: 'raffle', label: 'Raffle'),
  (id: 'unlisted', label: 'Unlisted'),
];

/// Supply-type options — backed by [api.ExploreFilter.mode]. Single-select:
/// `1/1` narrows to one-of-ones, `Editions` to open + limited editions
/// (combined, matching the `/v1/profile` route); no selection leaves `mode` at
/// [api.ExploreMode.all] for no supply-type constraint.
const _supplyTypeOptions = <({api.ExploreMode mode, String label})>[
  (mode: api.ExploreMode.oneOfOne, label: '1/1'),
  (mode: api.ExploreMode.editions, label: 'Editions'),
];

/// Media-type options — ids match the server's `MediaType` enum.
const _mediaTypeOptions = <_Option>[
  (id: 'image', label: 'Image'),
  (id: 'video', label: 'Video'),
  (id: 'html', label: 'Html'),
  (id: 'glb', label: 'Glb'),
  (id: 'pdf', label: 'Pdf'),
];

/// Category labels — mirrors the server's `Categories`. The wire id is
/// derived the same way `toDisplayId` does: lowercased, spaces to hyphens.
const _categoryLabels = <String>[
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

String _categoryId(String label) => label.toLowerCase().replaceAll(' ', '-');

/// Show the profile artwork-filters sheet. Returns the edited [api.ExploreFilter]
/// when the user taps Apply (an empty filter clears all filtering), or `null`
/// if the sheet is dismissed without applying. Pass `showUnlistedOption: false`
/// on listed-only tabs to hide the 'unlisted' listing-type chip.
///
/// The `show*Section` flags drop a whole facet. Set one `false` when the
/// calling surface already pins that facet and would override the user's pick
/// — the search sheet's "Auction" or "3D" drilldowns, for instance. Offering a
/// control whose value is discarded reads as a broken filter.
Future<api.ExploreFilter?> showProfileFiltersSheet(
  BuildContext context, {
  required api.ExploreFilter initial,
  bool showUnlistedOption = true,
  bool showListingTypeSection = true,
  bool showSupplyTypeSection = true,
  bool showCategoriesSection = true,
}) {
  return showMallowSheet<api.ExploreFilter>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.mallowColors.bgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(MallowTheme.popupRadius),
      ),
    ),
    builder: (_) => _ProfileFiltersSheet(
      initial: initial,
      showUnlistedOption: showUnlistedOption,
      showListingTypeSection: showListingTypeSection,
      showSupplyTypeSection: showSupplyTypeSection,
      showCategoriesSection: showCategoriesSection,
    ),
  );
}

/// Show the search-only filters sheet used by non-artwork tabs (Artists /
/// Collections / Curations), whose only filter is a tab-specific name search.
/// Returns the trimmed query when the user taps Apply (an empty string clears
/// the search), or `null` if the sheet is dismissed without applying.
Future<String?> showGroupSearchSheet(
  BuildContext context, {
  required String hint,
  String? initial,
}) {
  return showMallowSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.mallowColors.bgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(MallowTheme.popupRadius),
      ),
    ),
    builder: (_) => _GroupSearchSheet(hint: hint, initial: initial),
  );
}

class _GroupSearchSheet extends StatefulWidget {
  const _GroupSearchSheet({required this.hint, this.initial});

  final String hint;
  final String? initial;

  @override
  State<_GroupSearchSheet> createState() => _GroupSearchSheetState();
}

class _GroupSearchSheetState extends State<_GroupSearchSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply() => Navigator.of(context).pop(_controller.text.trim());

  /// Clearing applies immediately: pop with an empty query rather than only
  /// clearing the field and waiting for a separate Apply tap.
  void _clearAll() => Navigator.of(context).pop('');

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SheetDragHandle(),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Row(
            children: [
              Text(
                'Filters',
                style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              ),
              const Spacer(),
              TapTargetExpander(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _clearAll,
                  child: Text(
                    'Clear all',
                    style: MallowTheme.uiCaption.copyWith(color: colors.accent),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: _SearchField(
            controller: _controller,
            hint: widget.hint,
            autofocus: true,
            onSubmitted: (_) => _apply(),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(
            left: MallowTheme.spacing20,
            right: MallowTheme.spacing20,
            top: MallowTheme.spacingLg,
            bottom: sheetBottomInset(context),
          ),
          child: MallowButton(
            label: 'Apply',
            isFullWidth: true,
            onPressed: _apply,
          ),
        ),
      ],
    );
  }
}

class _ProfileFiltersSheet extends StatefulWidget {
  const _ProfileFiltersSheet({
    required this.initial,
    this.showUnlistedOption = true,
    this.showListingTypeSection = true,
    this.showSupplyTypeSection = true,
    this.showCategoriesSection = true,
  });

  final api.ExploreFilter initial;
  final bool showUnlistedOption;
  final bool showListingTypeSection;
  final bool showSupplyTypeSection;
  final bool showCategoriesSection;

  @override
  State<_ProfileFiltersSheet> createState() => _ProfileFiltersSheetState();
}

class _ProfileFiltersSheetState extends State<_ProfileFiltersSheet> {
  late final TextEditingController _searchController;
  late final TextEditingController _minController;
  late final TextEditingController _maxController;

  final Set<String> _listingTypes = {};
  final Set<String> _mediaTypes = {};
  final Set<String> _categories = {};
  api.ExploreMode _mode = api.ExploreMode.all;
  bool _freeOnly = false;

  @override
  void initState() {
    super.initState();
    final f = widget.initial;
    _searchController = TextEditingController(text: f.search ?? '');
    // A hidden section must not smuggle its constraint through Apply — the
    // user can't see it to clear it. Same reasoning as the 'unlisted' chip.
    if (widget.showListingTypeSection) _listingTypes.addAll(f.listingTypes);
    // Drop a stale 'unlisted' selection when the chip is hidden, so applying
    // from a listed-only tab can't silently keep an unlisted constraint.
    if (!widget.showUnlistedOption) _listingTypes.remove('unlisted');
    _mediaTypes.addAll(f.mediaTypes);
    if (widget.showCategoriesSection) _categories.addAll(f.tags);
    _mode = widget.showSupplyTypeSection ? f.mode : api.ExploreMode.all;

    final range = f.priceRange;
    // A max of 0 with no min is the Free/SYOP sentinel (mirrors the webapp).
    _freeOnly = range != null && range.max == 0 && range.min == null;
    _minController = TextEditingController(
      text: _freeOnly ? '' : _formatAmount(range?.min),
    );
    _maxController = TextEditingController(
      text: _freeOnly ? '' : _formatAmount(range?.max),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _minController.dispose();
    _maxController.dispose();
    super.dispose();
  }

  static String _formatAmount(double? value) {
    if (value == null) return '';
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toString();
  }

  void _toggle(Set<String> set, String id) {
    setState(() {
      if (!set.remove(id)) set.add(id);
    });
  }

  /// Clearing all filters applies immediately: pop with an empty filter rather
  /// than only resetting the fields and waiting for a separate Apply tap.
  void _clearAll() => Navigator.of(context).pop(const api.ExploreFilter());

  void _apply() {
    api.PriceRange? priceRange;
    if (_freeOnly) {
      priceRange = const api.PriceRange(max: 0);
    } else {
      final min = double.tryParse(_minController.text.trim());
      final max = double.tryParse(_maxController.text.trim());
      if (min != null || max != null) {
        priceRange = api.PriceRange(min: min, max: max);
      }
    }

    final search = _searchController.text.trim();
    Navigator.of(context).pop(
      api.ExploreFilter(
        mode: _mode,
        listingTypes: _listingTypes.toList(),
        mediaTypes: _mediaTypes.toList(),
        tags: _categories.toList(),
        priceRange: priceRange,
        search: search.isEmpty ? null : search,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    // Hugs its content and grows with it — the filter list is only as tall as
    // the facets the profile actually has — until it hits the cap
    // [showMallowSheet] applies.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SheetDragHandle(),
        // Header: title + Clear all
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Row(
            children: [
              Text(
                'Filters',
                style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              ),
              const Spacer(),
              TapTargetExpander(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _clearAll,
                  child: Text(
                    'Clear all',
                    style: MallowTheme.uiCaption.copyWith(color: colors.accent),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SearchField(
                  controller: _searchController,
                  hint: 'Search artwork...',
                ),
                const SizedBox(height: MallowTheme.spacingLg),
                if (widget.showListingTypeSection)
                  _Section(
                    title: 'Listing type',
                    child: _chipWrap(
                      options: widget.showUnlistedOption
                          ? _listingTypeOptions
                          : _listingTypeOptions
                                .where((o) => o.id != 'unlisted')
                                .toList(),
                      selected: _listingTypes,
                    ),
                  ),
                if (widget.showSupplyTypeSection)
                  _Section(title: 'Supply type', child: _supplyType()),
                _Section(title: 'Price range', child: _priceRange(colors)),
                _Section(
                  title: 'Media types',
                  child: _chipWrap(
                    options: _mediaTypeOptions,
                    selected: _mediaTypes,
                  ),
                ),
                if (widget.showCategoriesSection)
                  _Section(
                    title: 'Categories',
                    child: _chipWrap(
                      options: _categoryLabels
                          .map((l) => (id: _categoryId(l), label: l))
                          .toList(),
                      selected: _categories,
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Apply button
        Padding(
          padding: EdgeInsets.only(
            left: MallowTheme.spacing20,
            right: MallowTheme.spacing20,
            top: MallowTheme.spacingMd,
            bottom: sheetBottomInset(context),
          ),
          child: MallowButton(
            label: 'Apply',
            isFullWidth: true,
            onPressed: _apply,
          ),
        ),
      ],
    );
  }

  Widget _chipWrap({
    required List<_Option> options,
    required Set<String> selected,
  }) {
    return Wrap(
      spacing: MallowTheme.spacingSm,
      runSpacing: MallowTheme.spacingSm,
      children: [
        for (final option in options)
          _SelectChip(
            label: option.label,
            selected: selected.contains(option.id),
            onTap: () => _toggle(selected, option.id),
          ),
      ],
    );
  }

  /// Single-select supply-type chips backed by [_mode]. Re-tapping the active
  /// chip clears back to [api.ExploreMode.all] (no supply-type constraint).
  Widget _supplyType() {
    return Wrap(
      spacing: MallowTheme.spacingSm,
      runSpacing: MallowTheme.spacingSm,
      children: [
        for (final option in _supplyTypeOptions)
          _SelectChip(
            label: option.label,
            selected: _mode == option.mode,
            onTap: () => setState(() {
              _mode = _mode == option.mode ? api.ExploreMode.all : option.mode;
            }),
          ),
      ],
    );
  }

  Widget _priceRange(MallowColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SelectChip(
          label: 'Free/SYOP',
          selected: _freeOnly,
          onTap: () {
            setState(() {
              _freeOnly = !_freeOnly;
              if (_freeOnly) {
                _minController.clear();
                _maxController.clear();
              }
            });
          },
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        Row(
          children: [
            Expanded(child: _amountField(colors, _minController, 'Min')),
            const SizedBox(width: MallowTheme.spacingMd),
            Expanded(child: _amountField(colors, _maxController, 'Max')),
          ],
        ),
      ],
    );
  }

  Widget _amountField(
    MallowColors colors,
    TextEditingController controller,
    String hint,
  ) {
    return MallowPillField(
      controller: controller,
      hintText: hint,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      prefix: Text(
        '\$',
        style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
      ),
      onChanged: (value) {
        // Typing a bound and the Free/SYOP toggle are mutually exclusive.
        if (value.isNotEmpty && _freeOnly) setState(() => _freeOnly = false);
      },
    );
  }
}

/// Name-search text field shared by the full filters sheet and the
/// search-only group sheet.
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.hint,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return MallowPillField(
      controller: controller,
      hintText: hint,
      autofocus: autofocus,
      textInputAction: TextInputAction.search,
      onSubmitted: onSubmitted,
    );
  }
}

/// Titled filter section with consistent spacing.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: MallowTheme.spacingLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: MallowTheme.uiCaption.copyWith(
              color: context.mallowColors.textSecondary,
            ),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          child,
        ],
      ),
    );
  }
}

/// Pill toggle: filled accent when selected, outlined divider when not.
class _SelectChip extends StatelessWidget {
  const _SelectChip({
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
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? colors.accent : Colors.transparent,
            border: Border.all(
              color: selected ? colors.accent : colors.divider,
            ),
            borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          ),
          child: Text(
            label,
            style: MallowTheme.uiCaption.copyWith(
              color: selected ? colors.textOnAccent : colors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
