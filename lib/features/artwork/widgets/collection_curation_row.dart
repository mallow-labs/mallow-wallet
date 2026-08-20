import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../models/artwork_curation.dart';

/// Two-column row showing Collection (left) and Curated in (right).
///
/// Each side renders only when its data is present — when only one side
/// has data, a single full-width column is shown instead of an empty
/// placeholder header.
class CollectionCurationRow extends StatelessWidget {
  const CollectionCurationRow({
    super.key,
    this.collectionName,
    this.collectionImageUrl,
    this.onCollectionTap,
    this.curations = const [],
    this.onCurationsTap,
  });

  final String? collectionName;
  final String? collectionImageUrl;
  final VoidCallback? onCollectionTap;
  final List<ArtworkCuration> curations;
  final VoidCallback? onCurationsTap;

  @override
  Widget build(BuildContext context) {
    final hasCollection = collectionName != null;
    final hasCurations = curations.isNotEmpty;

    if (!hasCollection && !hasCurations) return const SizedBox.shrink();

    final collectionCell = hasCollection
        ? _LabeledCell(
            label: 'Collection',
            child: _ThumbnailLabel(
              imageUrl: collectionImageUrl,
              label: collectionName!,
              onTap: onCollectionTap,
            ),
          )
        : null;

    final curationsCell = hasCurations
        ? _LabeledCell(
            label: 'Curated in',
            child: _ThumbnailLabel(
              imageUrl: curations.first.imageUrl,
              label: curations.length > 1
                  ? '${curations.first.name} '
                  : curations.first.name,
              suffix: curations.length > 1
                  ? '+${curations.length - 1} more'
                  : null,
              onTap: onCurationsTap,
            ),
          )
        : null;

    if (collectionCell != null && curationsCell != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: collectionCell),
          const SizedBox(width: MallowTheme.spacingMd),
          Expanded(child: curationsCell),
        ],
      );
    }

    return collectionCell ?? curationsCell!;
  }
}

class _LabeledCell extends StatelessWidget {
  const _LabeledCell({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        child,
      ],
    );
  }
}

class _ThumbnailLabel extends StatelessWidget {
  const _ThumbnailLabel({
    required this.label,
    this.imageUrl,
    this.suffix,
    this.onTap,
  });

  final String? imageUrl;
  final String label;
  final String? suffix;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    final row = Row(
      children: [
        if (imageUrl != null)
          MallowNetworkImage(
            imageUrl: imageUrl!,
            logicalSize: 24,
            width: 24,
            height: 24,
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
            errorBuilder: (_) => _placeholder(colors),
          )
        else
          _placeholder(colors),
        const SizedBox(width: MallowTheme.spacingSm),
        Flexible(
          child: RichText(
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              children: [
                TextSpan(
                  text: label,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (suffix != null)
                  TextSpan(
                    text: suffix,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    if (onTap == null) return row;
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: row,
      ),
    );
  }

  Widget _placeholder(MallowColors colors) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: colors.divider,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
    );
  }
}
