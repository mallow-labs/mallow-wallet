import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_kv_row.dart';

/// Stats tab content: simple key/value rows for the user's lifetime
/// creator/collector counts. Styled to match the artwork detail screen's
/// "Details" tab — same [MallowKvRow] + Newsreader/Geist typography with
/// dividers between rows.
class ProfileStats extends StatelessWidget {
  const ProfileStats({
    required this.createdCount,
    required this.collectedCount,
    super.key,
  });

  final int createdCount;
  final int collectedCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MallowTheme.spacing20,
        MallowTheme.spacingMd,
        MallowTheme.spacing20,
        MallowTheme.spacingMd,
      ),
      child: MallowKvList(
        rows: [
          MallowKvRow(label: 'Artworks created', value: '$createdCount'),
          MallowKvRow(label: 'Artworks collected', value: '$collectedCount'),
        ],
      ),
    );
  }
}
