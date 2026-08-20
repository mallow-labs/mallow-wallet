import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../models/recently_viewed_item.dart';
import 'search_artwork_item.dart';
import 'search_curation_item.dart';
import 'search_result_actions.dart';
import 'search_token_item.dart';
import 'search_user_item.dart';

/// Displays the "Recently viewed" section: the last few content items the user
/// opened, each rendered with the same row widget as its search result and
/// tapping through to the same destination.
class RecentlyViewedSection extends StatelessWidget {
  const RecentlyViewedSection({
    required this.items,
    required this.onClearAll,
    super.key,
  });

  final List<RecentlyViewedItem> items;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final colors = context.mallowColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Recently viewed',
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
        const SizedBox(height: MallowTheme.spacing12),
        ...items.map(
          (item) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _onTap(context, item),
              child: _row(item),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(RecentlyViewedItem item) => switch (item.type) {
    RecentlyViewedType.user => SearchUserItem(
      user: item.user!,
      typeLabel: 'User',
      thumbnailStyle: true,
    ),
    RecentlyViewedType.artwork => SearchArtworkItem(
      artwork: item.artwork!,
      typeLabel: 'Artwork',
    ),
    RecentlyViewedType.collection => SearchCollectionItem(
      collection: item.collection!,
      typeLabel: 'Collection',
    ),
    RecentlyViewedType.curation => SearchCurationItem(
      curation: item.curation!,
      typeLabel: 'Curation',
    ),
    RecentlyViewedType.token => SearchTokenItem(
      token: item.token!,
      typeLabel: 'Token',
    ),
  };

  void _onTap(BuildContext context, RecentlyViewedItem item) {
    switch (item.type) {
      case RecentlyViewedType.user:
        openSearchUser(context, item.user!);
      case RecentlyViewedType.artwork:
        openSearchArtwork(context, item.artwork!);
      case RecentlyViewedType.collection:
        openSearchCollection(context, item.collection!);
      case RecentlyViewedType.curation:
        openSearchCuration(context, item.curation!);
      case RecentlyViewedType.token:
        openSearchToken(context, item.token!);
    }
  }
}
