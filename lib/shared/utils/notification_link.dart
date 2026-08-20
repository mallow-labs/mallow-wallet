import 'package:url_launcher/url_launcher.dart';

import '../../core/router/app_router.dart';

/// Canonical web host every notification link belongs to.
const String _mallowHost = 'https://mallow.art';

/// Resolve a notification's link into something this app can actually open.
///
/// Both link vocabularies feed through here so an in-app row and a tapped push
/// land in the same place:
/// - in-app rows carry the relative path `getNotificationContents` builds
///   (`/artwork/{mint}`, `/gumball/{pk}`, …);
/// - push payloads carry the same link already absolutised by the notification
///   sender (`https://mallow.art/artwork/{mint}`), and comment/like rows carry
///   an absolute `contentInfo.url` for the same reason.
///
/// Returns either an in-app route path (leading `/`) or an absolute
/// `https://mallow.art/...` URL for a destination mobile has no screen for —
/// Gumball, Jellybean, store products, Talk posts and staking. Never returns a
/// path go_router can't match, which is what produced "Page not found".
///
/// Returns null only when there is nothing to open at all.
String? resolveNotificationLink(String? link) {
  if (link == null || link.isEmpty) return null;

  final uri = Uri.tryParse(link);
  if (uri == null) return null;

  final segments = uri.pathSegments;
  if (segments.isEmpty) return null;

  switch (segments.first) {
    case 'artwork' when segments.length >= 2:
      return AppRoutes.artworkDetailPath(segments[1]);
    case 'a' when segments.length >= 2:
      return AppRoutes.profilePath(segments[1]);
    case 'u' when segments.length >= 2:
      return AppRoutes.profileByUsernamePath(segments[1]);
    case 'collection' when segments.length >= 2:
      return AppRoutes.collectionPath(segments[1]);
    default:
      // A destination with no mobile screen. Open mallow.art rather than
      // pushing a route that doesn't exist. Query is preserved because
      // comment links carry `?commentId=` that anchors the web page.
      final path = uri.path.startsWith('/') ? uri.path : '/${uri.path}';
      final query = uri.query.isEmpty ? '' : '?${uri.query}';
      return '$_mallowHost$path$query';
  }
}

/// Whether [resolved] (the output of [resolveNotificationLink]) is a web URL
/// rather than an in-app route path.
bool isNotificationWebLink(String resolved) => resolved.startsWith('http');

/// Open a resolved web notification link.
///
/// `inAppBrowserView` matches `openArtworkOnWeb`: mallow.art is a verified app
/// link on both platforms, so the external browser would bounce straight back
/// into the app and land on nothing.
Future<void> openNotificationWebLink(String url) async {
  final uri = Uri.parse(url);
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
  }
}
