import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// Full-width banner image with an overlaid back button.
/// If [bannerUrl] is null, no banner image is shown (back button still renders).
/// Avatar lives in [ProfileHeader] directly below.
class ProfileBanner extends StatelessWidget {
  const ProfileBanner({
    required this.bannerUrl,
    required this.onBack,
    super.key,
  });

  final String? bannerUrl;
  final VoidCallback onBack;

  static const double _bannerHeight = 200;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final backButtonTop = topPadding + 8;

    if (bannerUrl == null || bannerUrl!.isEmpty) {
      // No banner: render just enough space for the back button.
      return SliverToBoxAdapter(
        child: SizedBox(
          height: topPadding + 48,
          child: Stack(
            children: [
              Positioned(
                top: backButtonTop,
                left: MallowTheme.spacing20,
                child: _BackButton(onBack: onBack),
              ),
            ],
          ),
        ),
      );
    }

    return SliverToBoxAdapter(
      child: Stack(
        children: [
          // Banner image — full-width, use 800px CDN bucket for crisp retina rendering
          MallowNetworkImage(
            imageUrl: bannerUrl!,
            logicalSize: 400,
            cdnFit: 'inside',
            width: double.infinity,
            height: _bannerHeight,
            errorBuilder: (ctx) => Container(
              height: _bannerHeight,
              color: ctx.mallowColors.divider,
            ),
          ),
          // Back button
          Positioned(
            top: backButtonTop,
            left: MallowTheme.spacing20,
            child: _BackButton(onBack: onBack),
          ),
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onBack,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: context.mallowColors.bgPrimary.withValues(alpha: 0.8),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: SvgPicture.asset(
              'assets/icons/arrow_left.svg',
              width: 16,
              height: 16,
              colorFilter: ColorFilter.mode(
                context.mallowColors.textPrimary,
                BlendMode.srcIn,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
