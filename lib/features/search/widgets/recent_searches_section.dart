import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// Displays the "Recent searches" section with a list of past queries
/// and a "Clear all" action.
class RecentSearchesSection extends StatelessWidget {
  const RecentSearchesSection({
    required this.searches,
    required this.onTap,
    required this.onClearAll,
    super.key,
  });

  final List<String> searches;
  final ValueChanged<String> onTap;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    if (searches.isEmpty) return const SizedBox.shrink();

    final colors = context.mallowColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Recent searches',
              style: GoogleFonts.newsreader(
                fontSize: 15,
                fontStyle: FontStyle.italic,
                color: colors.textPrimary,
              ),
            ),
            TapTargetExpander(
              child: GestureDetector(
                onTap: onClearAll,
                child: Text(
                  'Clear all',
                  style: TextStyle(
                    fontFamily: 'Geist',
                    fontSize: 13,
                    color: colors.textTertiary,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Search items
        ...searches.map(
          (query) => _RecentSearchRow(query: query, onTap: () => onTap(query)),
        ),
      ],
    );
  }
}

class _RecentSearchRow extends StatelessWidget {
  const _RecentSearchRow({required this.query, required this.onTap});

  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              SvgPicture.asset(
                'assets/icons/search.svg',
                width: 20,
                height: 20,
                colorFilter: ColorFilter.mode(
                  colors.textTertiary,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  query,
                  style: TextStyle(
                    fontFamily: 'Geist',
                    fontSize: 15,
                    color: colors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
