import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/expandable_text.dart';
import '../../../shared/widgets/external_link_sheet.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// About tab content: bio text, follower/collector counts, social icons.
class ProfileBio extends StatefulWidget {
  const ProfileBio({
    required this.bio,
    required this.followerCount,
    required this.followingCount,
    required this.collectorCount,
    this.onFollowersTap,
    this.onFollowingTap,
    this.twitterUrl,
    this.instagramUrl,
    this.websiteUrl,
    this.youtubeUrl,
    super.key,
  });

  final String bio;
  final int followerCount;

  /// How many profiles this user follows. The webapp header pairs Followers
  /// with Following (not Collectors); mobile keeps Collectors as well because
  /// it is the only place that number is shown.
  final int followingCount;
  final int collectorCount;

  /// Opens the followers screen (Followers tab) when the follower count is
  /// tapped.
  final VoidCallback? onFollowersTap;

  /// Opens the same screen on its Following tab.
  final VoidCallback? onFollowingTap;

  final String? twitterUrl;
  final String? instagramUrl;
  final String? websiteUrl;
  final String? youtubeUrl;

  @override
  State<ProfileBio> createState() => _ProfileBioState();
}

class _ProfileBioState extends State<ProfileBio> {
  Future<void> _launchUrl(String url) async {
    final uri = _normalize(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }
  }

  /// Confirms via an [showExternalLinkSheet] bottom sheet before sending the
  /// user out to their personal website.
  Future<void> _launchWithConfirm(String url) async {
    final uri = _normalize(url);
    if (uri == null) return;
    final confirmed = await showExternalLinkSheet(
      context,
      displayUrl: uri.host,
    );
    if (confirmed != true || !mounted) return;
    await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
  }

  /// Prepends `https://` when no scheme is present and validates the result.
  /// Returns `null` for empty or unparseable input.
  Uri? _normalize(String url) {
    if (url.trim().isEmpty) return null;
    final normalized = url.startsWith(RegExp(r'https?://'))
        ? url
        : 'https://$url';
    final uri = Uri.tryParse(normalized);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) return uri;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MallowTheme.spacing20,
        MallowTheme.spacingMd,
        MallowTheme.spacing20,
        MallowTheme.spacingMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Bio + expand/collapse button
          if (widget.bio.isNotEmpty) ...[
            ExpandableText(text: widget.bio),
            const SizedBox(height: MallowTheme.spacingSm),
          ],
          // Follower • Following • Collector counts. Followers and Following
          // both open the follow lists on the matching tab — the webapp header
          // opens the same two-tab modal from the same two numbers.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CountLabel(
                text:
                    '${widget.followerCount} '
                    '${widget.followerCount == 1 ? 'Follower' : 'Followers'}',
                onTap: widget.onFollowersTap,
              ),
              const _CountSeparator(),
              _CountLabel(
                text: '${widget.followingCount} Following',
                onTap: widget.onFollowingTap,
              ),
              const _CountSeparator(),
              _CountLabel(
                text:
                    '${widget.collectorCount} '
                    '${widget.collectorCount == 1 ? 'Collector' : 'Collectors'}',
              ),
            ],
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          Wrap(
            spacing: 8,
            children: [
              if (widget.twitterUrl?.isNotEmpty ?? false)
                _SocialIcon(
                  assetPath: 'assets/icons/brand_x.svg',
                  onTap: () => _launchUrl(widget.twitterUrl!),
                ),
              if (widget.instagramUrl?.isNotEmpty ?? false)
                _SocialIcon(
                  assetPath: 'assets/icons/brand_ig.svg',
                  onTap: () => _launchUrl(widget.instagramUrl!),
                ),
              if (widget.websiteUrl?.isNotEmpty ?? false)
                _SocialIcon(
                  assetPath: 'assets/icons/globe.svg',
                  onTap: () => _launchWithConfirm(widget.websiteUrl!),
                ),
              if (widget.youtubeUrl?.isNotEmpty ?? false)
                _SocialIcon(
                  assetPath: 'assets/icons/brand_youtube.svg',
                  onTap: () => _launchUrl(widget.youtubeUrl!),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One "N Label" count in the profile's count row. Tappable only when [onTap]
/// is supplied — Collectors has no list screen to open.
class _CountLabel extends StatelessWidget {
  const _CountLabel({required this.text, this.onTap});

  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      style: MallowTheme.uiCaption.copyWith(
        color: context.mallowColors.textSecondary,
      ),
    );
    if (onTap == null) return label;
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: label,
      ),
    );
  }
}

class _CountSeparator extends StatelessWidget {
  const _CountSeparator();

  @override
  Widget build(BuildContext context) => Text(
    ' • ',
    style: MallowTheme.uiCaption.copyWith(
      color: context.mallowColors.textSecondary,
    ),
  );
}

class _SocialIcon extends StatelessWidget {
  const _SocialIcon({
    required this.assetPath,
    required this.onTap,
    this.iconSize = 16,
  });

  final String assetPath;
  final VoidCallback onTap;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 24,
          height: 24,
          child: Center(
            child: SvgPicture.asset(
              assetPath,
              width: iconSize,
              height: iconSize,
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
