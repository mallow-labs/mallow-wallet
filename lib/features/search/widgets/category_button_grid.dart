import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../data/category_images.dart';
import '../models/search_models.dart';

/// A 2-column grid of category buttons with artwork background images.
class CategoryButtonGrid extends StatelessWidget {
  const CategoryButtonGrid({
    required this.categories,
    required this.onTap,
    super.key,
  });

  final List<SearchFilterType> categories;
  final ValueChanged<SearchFilterType> onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: categories
          .map((c) => _CategoryButton(category: c, onTap: () => onTap(c)))
          .toList(),
    );
  }
}

class _CategoryButton extends StatelessWidget {
  const _CategoryButton({required this.category, required this.onTap});

  final SearchFilterType category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final width = (MediaQuery.of(context).size.width - 40 - 8) / 2;
    final imageUrl = categoryImageUrls[category.label];

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: 60,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background artwork image
              if (imageUrl != null && imageUrl.isNotEmpty)
                MallowNetworkImage(
                  imageUrl: imageUrl,
                  logicalSize: width,
                  errorBuilder: (_) => Container(color: colors.bgSurface),
                )
              else
                Container(color: colors.bgSurface),
              // Label badge sits on artwork imagery, so the black/white
              // literal preserves contrast independent of theme.
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
                      category.label,
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
