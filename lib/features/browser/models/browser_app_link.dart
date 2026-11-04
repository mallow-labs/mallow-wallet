/// The link in the app's own scheme that a page navigated to, or null when
/// [uri] is not one the browser hands to the app.
///
/// A website's "open in the app" button navigates to `mallowwallet://…`. On
/// Android it may use the intent form instead
/// (`intent://…#Intent;scheme=mallowwallet;…;end`), which falls back to the
/// store when the app is missing; that is read as the same plain link.
///
/// Three hosts are never handed over: `auth` is the login redirect, which
/// belongs to the login SDK; `wc` is a WalletConnect pairing, which the browser
/// takes itself; and `browser` is the share handoff, which carries a website,
/// not a wallet command.
Uri? browserAppLink(Uri uri) {
  final link = uri.isScheme('intent') ? _fromIntent(uri) : uri;
  if (link == null || !link.isScheme('mallowwallet')) return null;
  if (link.userInfo.isNotEmpty) return null;
  if (const {'auth', 'wc', 'browser'}.contains(link.host)) return null;
  return link;
}

/// `intent://HOST/PATH?QUERY#Intent;scheme=mallowwallet;…;end` as
/// `mallowwallet://HOST/PATH?QUERY`. The intent's other extras (the store
/// fallback, a package name) are dropped: the app is already open.
Uri? _fromIntent(Uri uri) {
  final parts = uri.fragment.split(';');
  if (parts.length < 3 || parts.first != 'Intent' || parts.last != 'end') {
    return null;
  }
  final schemes = parts.where((p) => p.startsWith('scheme=')).toList();
  if (schemes.length != 1 || schemes.single != 'scheme=mallowwallet') {
    return null;
  }
  return uri.removeFragment().replace(scheme: 'mallowwallet');
}
