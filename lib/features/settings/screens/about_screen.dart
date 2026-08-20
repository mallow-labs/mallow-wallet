import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../features/onboarding/widgets/artwork_ring_3d.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../widgets/settings_page_scaffold.dart';

/// About mallow screen.
///
/// Shows links to resources, legal pages, and social accounts.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<void> _launch(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'About mallow',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            // Resource links
            _LinkRow(
              label: 'Website',
              iconAsset: 'assets/icons/mallow_icon.svg',
              onTap: () => _launch('https://mallow.art'),
            ),
            _LinkRow(
              label: 'Help & Support',
              iconAsset: 'assets/icons/help_circle.svg',
              onTap: () => _launch('https://discord.gg/UvYjRDTRbX'),
            ),
            _LinkRow(
              label: 'Docs',
              iconAsset: 'assets/icons/docs.svg',
              onTap: () => _launch('https://docs.mallow.art'),
            ),
            _LinkRow(
              label: 'Terms of Service',
              iconAsset: 'assets/icons/page.svg',
              onTap: () => _launch('https://wallet.mallow.art/terms'),
            ),
            _LinkRow(
              label: 'Privacy Notice',
              iconAsset: 'assets/icons/view_doc.svg',
              onTap: () => _launch('https://wallet.mallow.art/privacy'),
            ),
            const Spacer(),
            // Social links
            _LinkRow(
              label: 'Follow @mallowdotart on X',
              iconAsset: 'assets/icons/brand_x.svg',
              onTap: () => _launch('https://x.com/mallowdotart'),
            ),
            _LinkRow(
              label: 'Follow @mallow.art on Instagram',
              iconAsset: 'assets/icons/brand_ig.svg',
              onTap: () => _launch('https://instagram.com/mallow.art'),
            ),
            _LinkRow(
              label: 'Join our Discord',
              iconAsset: 'assets/icons/brand_discord.svg',
              onTap: () => _launch('https://mallow.art/discord'),
            ),
            const SizedBox(height: 12),
            const Center(child: _ArtworkCredits()),
            const SizedBox(height: 6),
            const Center(child: _IconCredits()),
            const SizedBox(height: 6),
            const Center(child: _VersionLabel()),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

/// One credited artist behind the onboarding carousel
/// (`assets/images/carousel/`), with the link the credit points at.
class _ArtworkCredit {
  const _ArtworkCredit({required this.name, this.url});

  final String name;

  /// Where the credit links to, when the artist has a public page. A `null`
  /// url renders the name as plain text rather than a dead link.
  final String? url;
}

/// The artists whose work the onboarding carousel shows.
///
/// 🛑 **Required, not decorative.** The copyright in each of the nine carousel
/// works stays with its artist; this credit is what makes showing them here
/// honest, and it has the same standing as the Streamline credit below.
/// Removing a name without also removing that artist's file leaves the app
/// showing work it does not attribute.
///
/// Derived from [kDefaultCarouselArtworks] — the same list the carousel captions
/// read — so the credit here cannot name a different set of artists than the
/// ring shows. One entry per carousel card, in carousel order, named by mallow
/// username and linked to that profile. Add or drop an artist in that list, not
/// this one, and update the file-to-artwork-to-artist mapping in
/// `THIRD_PARTY_NOTICES.md` to match.
final List<_ArtworkCredit> _carouselArtists = [
  for (final artwork in kDefaultCarouselArtworks)
    _ArtworkCredit(
      name: artwork.artist,
      url: 'https://mallow.art/u/${artwork.artist}',
    ),
];

/// Onboarding-artwork attribution.
///
/// 🛑 **Required, not decorative** — see [_carouselArtists] for why. Sits
/// directly above the icon credit so the two attribution lines read as one
/// block.
class _ArtworkCredits extends StatefulWidget {
  const _ArtworkCredits();

  @override
  State<_ArtworkCredits> createState() => _ArtworkCreditsState();
}

class _ArtworkCreditsState extends State<_ArtworkCredits> {
  /// Recognizers by artist index, for the artists that have a link.
  late final Map<int, TapGestureRecognizer> _recognizers;

  @override
  void initState() {
    super.initState();
    _recognizers = {
      for (var i = 0; i < _carouselArtists.length; i++)
        if (_carouselArtists[i].url case final url?)
          i: (TapGestureRecognizer()..onTap = () => _launchUrl(url)),
    };
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  static Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final base = MallowTheme.uiCaption.copyWith(color: colors.textTertiary);
    final link = base.copyWith(decoration: TextDecoration.underline);
    final spans = <InlineSpan>[const TextSpan(text: 'Onboarding artwork by ')];
    for (var i = 0; i < _carouselArtists.length; i++) {
      if (i > 0) {
        final last = i == _carouselArtists.length - 1;
        spans.add(TextSpan(text: last ? ' and ' : ', '));
      }
      final recognizer = _recognizers[i];
      spans.add(
        TextSpan(
          text: _carouselArtists[i].name,
          style: recognizer == null ? null : link,
          recognizer: recognizer,
        ),
      );
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      textAlign: TextAlign.center,
    );
  }
}

/// Icon-set attribution.
///
/// 🛑 **Required, not decorative.** The Streamline free licence grants use only
/// on condition that the credit appears as hyperlinked text on an app's About
/// surface. Removing this line puts the app out of licence with every
/// Streamline icon it ships. Tabler is MIT, whose notice obligation is met by
/// `THIRD_PARTY_NOTICES.md`; it is named here because the two sets sit side by
/// side and a partial credit reads as a claim about the rest.
class _IconCredits extends StatefulWidget {
  const _IconCredits();

  @override
  State<_IconCredits> createState() => _IconCreditsState();
}

class _IconCreditsState extends State<_IconCredits> {
  late final TapGestureRecognizer _streamline;
  late final TapGestureRecognizer _tabler;

  @override
  void initState() {
    super.initState();
    _streamline = TapGestureRecognizer()
      ..onTap = () => _launchUrl('https://streamlinehq.com/');
    _tabler = TapGestureRecognizer()
      ..onTap = () => _launchUrl('https://tabler.io/icons');
  }

  @override
  void dispose() {
    _streamline.dispose();
    _tabler.dispose();
    super.dispose();
  }

  static Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final base = MallowTheme.uiCaption.copyWith(color: colors.textTertiary);
    final link = base.copyWith(decoration: TextDecoration.underline);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          const TextSpan(text: 'Free icons from '),
          TextSpan(text: 'Streamline', style: link, recognizer: _streamline),
          const TextSpan(text: ' and '),
          TextSpan(text: 'Tabler', style: link, recognizer: _tabler),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

/// Installed app version + build number, e.g. `1.4.0 (137)`.
///
/// Stateful so `PackageInfo.fromPlatform()` is read once per mount rather than
/// on every rebuild. Renders nothing until it resolves, so the layout never
/// shows a placeholder string.
class _VersionLabel extends StatefulWidget {
  const _VersionLabel();

  @override
  State<_VersionLabel> createState() => _VersionLabelState();
}

class _VersionLabelState extends State<_VersionLabel> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _packageInfo,
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Text(
          info == null ? '' : '${info.version} (${info.buildNumber})',
          style: MallowTheme.uiCaption.copyWith(
            color: context.mallowColors.textTertiary,
          ),
        );
      },
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.label, required this.onTap, this.iconAsset});

  final String label;
  final VoidCallback onTap;
  final String? iconAsset;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: iconAsset != null
                  ? SvgPicture.asset(
                      iconAsset!,
                      width: 20,
                      height: 20,
                      colorFilter: ColorFilter.mode(
                        context.mallowColors.textPrimary,
                        BlendMode.srcIn,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: MallowTheme.uiBody)),
          ],
        ),
      ),
    );
  }
}
