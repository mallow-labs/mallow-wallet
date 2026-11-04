import 'browser_models.dart';

/// Identity distinguishes repeated shares of the same website for the router.
class BrowserOpenRequest {
  BrowserOpenRequest(this.url);
  final Uri url;
}

/// The share targets (the iOS action extension and the Android share-sheet
/// activity) hand off a website, never a wallet command. Keeping this separate
/// from ordinary artwork links makes the user's choice explicit.
Uri? browserOpenLinkUrl(Uri link) {
  if (link.scheme != 'mallowwallet' ||
      link.host != 'browser' ||
      link.path != '/open' ||
      link.userInfo.isNotEmpty ||
      link.hasPort ||
      link.hasFragment) {
    return null;
  }
  List<String>? values;
  try {
    values = link.queryParametersAll['url'];
  } on FormatException {
    return null;
  }
  if (values == null || values.length != 1) return null;
  final value = values.single;
  if (value.contains(RegExp(r'\s'))) return null;
  final url = Uri.tryParse(value);
  return url != null && isBrowserUrl(url) ? url : null;
}
