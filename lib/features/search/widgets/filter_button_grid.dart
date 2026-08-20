import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../models/search_models.dart';

/// A 2-column grid of filter buttons used for "Listing type" and "Browse"
/// sections. Each button shows a colored accent rectangle with a dark label
/// overlay.
class FilterButtonGrid extends StatelessWidget {
  const FilterButtonGrid({
    required this.filters,
    required this.onTap,
    super.key,
  });

  final List<SearchFilterType> filters;
  final ValueChanged<SearchFilterType> onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: filters
          .map((f) => _FilterButton(filter: f, onTap: () => onTap(f)))
          .toList(),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.filter, required this.onTap});

  final SearchFilterType filter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Each button takes half the width minus half the spacing
    final width =
        (MediaQuery.of(context).size.width - 40 - 8) /
        2; // 20px padding each side

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: 60,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          child: Stack(
            children: [
              // Colored accent background
              Positioned.fill(child: Container(color: filter.accentColor)),
              // Label badge
              // Label badge sits on a fixed accent-colored swatch, so the
              // black/white literal preserves contrast independent of theme.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: Container(
                    color: Colors.black,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      filter.label,
                      style: MallowTheme.editorialQuote.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
