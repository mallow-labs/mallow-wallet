import 'package:url_launcher/url_launcher.dart';

/// Canonical mallow.art web URL for an artwork — the same URL the share
/// action, `DeepLinkService` and the artwork sheets' outlinks use.
String artworkWebUrl(String mintAccount) =>
    'https://mallow.art/artwork/$mintAccount';

/// Opens the artwork's canonical web page in an in-app browser view.
///
/// `inAppBrowserView` matters here: `mallow.art/artwork/*` is a verified app
/// link on both platforms, so handing it to the external browser would just
/// bounce straight back into the app.
Future<void> openArtworkOnWeb(String mintAccount) async {
  final uri = Uri.parse(artworkWebUrl(mintAccount));
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
  }
}
