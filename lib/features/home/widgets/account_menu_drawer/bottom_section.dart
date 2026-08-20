part of '../account_menu_drawer.dart';

class _BottomSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        MenuRow(
          icon: 'assets/icons/help.svg',
          label: 'Get help',
          onTap: () => _launchUrl(AccountMenuLinks.discord),
        ),
        const SizedBox(height: 8),
        MenuRow(
          icon: 'assets/icons/star.svg',
          label: 'Review',
          onTap: _requestReview,
        ),
        const SizedBox(height: 20),
        Divider(height: 1, color: context.mallowColors.dividerLight),
        const SizedBox(height: 20),
        Row(
          children: [
            _SocialIcon(
              icon: 'assets/icons/brand_x.svg',
              onTap: () => _launchUrl(AccountMenuLinks.twitter),
              padding: 4,
            ),
            const SizedBox(width: 4),
            _SocialIcon(
              icon: 'assets/icons/brand_ig.svg',
              onTap: () => _launchUrl(AccountMenuLinks.instagram),
              padding: 4,
            ),
            const SizedBox(width: 4),
            _SocialIcon(
              icon: 'assets/icons/docs.svg',
              onTap: () => _launchUrl(AccountMenuLinks.docs),
            ),
            const SizedBox(width: 4),
            _SocialIcon(
              icon: 'assets/icons/github.svg',
              onTap: () => _launchUrl(AccountMenuLinks.github),
            ),
            const SizedBox(width: 4),
            _SocialIcon(
              icon: 'assets/icons/mallow_icon.svg',
              onTap: () => _launchUrl(AccountMenuLinks.mallow),
              padding: 6,
            ),
          ],
        ),
      ],
    );
  }

  /// Native in-app rating dialog (SKStoreReviewController / Play In-App
  /// Review). Both OSes rate-limit it, so a tap may silently no-op.
  Future<void> _requestReview() async {
    final inAppReview = InAppReview.instance;
    if (await inAppReview.isAvailable()) {
      await inAppReview.requestReview();
    }
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }
  }
}
