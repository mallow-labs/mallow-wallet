import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/config/environment.dart';

/// The first-party UI channel between the in-app browser and the web app
/// ([isFirstPartyOrigin]).
///
/// The page gets `window.mallow.ui`:
///
/// ```js
/// window.mallow.ui = Object.freeze({
///   version: 1,
///   get theme(): 'light' | 'dark',   // the wallet's current theme
///   setOverlay(active: boolean): void,  // fire-and-forget
/// });
/// ```
///
/// and two events on `window`: `mallow:theme` (detail `{theme}`) after the
/// wallet's theme changes, and `mallow:scrim-tap` when the user taps the
/// browser chrome while it is dimmed under the page's own sheet.
///
/// `setOverlay` crosses the wallet's existing bridge as the envelope
/// `{id, namespace: 'ui', method: 'setOverlay', params: {active}, documentToken}`
/// and is answered `{id, result: null}`. It never reaches the dApp request
/// coordinator: it asks for no approval, and it does not count against the
/// limits on pending wallet requests.
///
/// Trust is native at every step. The API is injected only into a document
/// whose own origin, read before any page script runs, is exactly the web
/// app's; each message is checked again against the origin and document
/// token the native host committed; and the theme is pushed only into a
/// committed first-party document. A page cannot opt itself in: at worst a
/// third-party page that builds its own look-alike object talks to a bridge
/// that drops everything it sends.
const browserUiNamespace = 'ui';

/// The hosts of the web app, served over `https` on the default port, in
/// every build.
///
/// Exact hosts, never a suffix rule: other subdomains of the same domain are
/// content gateways that serve whatever anyone uploaded, and handing such a
/// page control over the wallet's own chrome is the opposite of the intent.
/// One host per line, so the list reads the same if one is ever dropped.
const browserFirstPartyHosts = <String>[
  // The web app, with and without `www.`.
  'mallow.art',
  'www.mallow.art',
];

/// Hosts first-party in staging and development builds only: pre-release
/// deployments of the web app. A production build never grants them the
/// channel, so the shipped app trusts exactly [browserFirstPartyHosts].
/// Same rules otherwise: exact hosts, `https`, default port.
const browserPreReleaseFirstPartyHosts = <String>[
  // Empty in a build that defines no pre-release deployment.
];

/// The built-in first-party hosts of a build of [environment].
List<String> browserFirstPartyHostsFor(Environment environment) => [
  ...browserFirstPartyHosts,
  if (environment != Environment.production)
    ...browserPreReleaseFirstPartyHosts,
];

/// [browserFirstPartyHosts] as the exact origins a document reports.
List<String> get browserFirstPartyOrigins => [
  for (final host in browserFirstPartyHosts) 'https://$host',
];

/// [browserFirstPartyHostsFor] as the exact origins a document reports.
List<String> browserFirstPartyOriginsFor(Environment environment) => [
  for (final host in browserFirstPartyHostsFor(environment)) 'https://$host',
];

/// Whether [url] is a first-party page for a build of [environment]: one of
/// [browserFirstPartyHostsFor] over `https` on the default port, and in a
/// development build also a local or private address over `https` on any
/// port ([isLocalDevelopmentHost]). Never with credentials in the URL.
bool isFirstPartyOrigin(Uri? url, Environment environment) {
  if (url == null ||
      url.scheme.toLowerCase() != 'https' ||
      url.userInfo.isNotEmpty ||
      url.host.isEmpty) {
    return false;
  }
  final host = url.host.toLowerCase();
  if (_port(url) == 443 &&
      browserFirstPartyHostsFor(environment).contains(host)) {
    return true;
  }
  return environment == Environment.development && isLocalDevelopmentHost(host);
}

/// Whether [host] names this device or the local network, where a developer
/// serves their own copy of the web app: `localhost` and `*.localhost`, mDNS
/// `*.local`, names under Tailscale's MagicDNS domain `ts.net`, and an IP
/// address in the loopback, RFC 1918 private, link-local or Tailscale (CGNAT)
/// IPv4 ranges or the IPv6 loopback, unique-local or link-local ranges. An
/// IPv6 host may be bracketed, as in a URL authority.
///
/// Addresses are parsed, never prefix-matched: `100.63.0.1` and
/// `172.32.0.1` are public. An IPv4-mapped IPv6 address (`::ffff:0:0/96`) is
/// refused however it is spelled: the IPv4 ranges above are the way to name
/// a local IPv4 host.
@visibleForTesting
bool isLocalDevelopmentHost(String host) {
  final h = host.toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) {
    return _isLocalIPv6(h.substring(1, h.length - 1));
  }
  if (h.contains(':')) return _isLocalIPv6(h);
  if (h == 'localhost') return true;
  for (final domain in const ['localhost', 'local', 'ts.net']) {
    final suffix = '.$domain';
    if (h.length > suffix.length && h.endsWith(suffix)) {
      return _dnsLabels.hasMatch(h.substring(0, h.length - suffix.length));
    }
  }
  final v4 = _ipv4(h);
  if (v4 == null) return false;
  final [a, b, _, _] = v4;
  return a == 127 || // loopback 127.0.0.0/8
      a == 10 || // RFC 1918 10.0.0.0/8
      (a == 172 && b >= 16 && b <= 31) || // RFC 1918 172.16.0.0/12
      (a == 192 && b == 168) || // RFC 1918 192.168.0.0/16
      (a == 169 && b == 254) || // link-local 169.254.0.0/16
      (a == 100 && b >= 64 && b <= 127); // Tailscale (CGNAT) 100.64.0.0/10
}

/// Dot-separated DNS labels: letters, digits and inner hyphens.
final _dnsLabels = RegExp(
  r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$',
);

final _dottedQuad = RegExp(
  r'^(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$',
);

/// Four canonical decimal octets, or null. Leading zeros are refused: a
/// browser reads them as octal, so `010.0.0.1` would not be the address it
/// appears to be.
List<int>? _ipv4(String host) {
  final match = _dottedQuad.firstMatch(host);
  if (match == null) return null;
  final octets = [for (var i = 1; i <= 4; i++) int.parse(match.group(i)!)];
  return octets.every((o) => o <= 255) ? octets : null;
}

bool _isLocalIPv6(String host) {
  // A dotted tail is an embedded IPv4 address, IPv4-mapped included: refused.
  if (host.isEmpty || host.contains('.') || host.contains('%')) return false;
  final List<int> bytes;
  try {
    bytes = Uri.parseIPv6Address(host);
  } on FormatException {
    return false;
  }
  if (bytes.length != 16) return false;
  final loopback = bytes.take(15).every((b) => b == 0) && bytes[15] == 1;
  return loopback || // ::1
      (bytes[0] & 0xfe) == 0xfc || // unique local fc00::/7 (Tailscale too)
      (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80); // link-local fe80::/10
}

int _port(Uri uri) => uri.hasPort ? uri.port : 443;

/// What a first-party page asked the browser to do.
@immutable
sealed class BrowserUiCommand {
  const BrowserUiCommand();
}

/// The page's own bottom sheet is opening ([active]) or closing: the browser
/// dims and steps its chrome aside to match, or restores it.
final class BrowserUiSetOverlay extends BrowserUiCommand {
  const BrowserUiSetOverlay({required this.active});
  final bool active;

  @override
  bool operator ==(Object other) =>
      other is BrowserUiSetOverlay && other.active == active;

  @override
  int get hashCode => active.hashCode;

  @override
  String toString() => 'BrowserUiSetOverlay(active: $active)';
}

/// Decodes a `ui` envelope, or null to drop it.
///
/// [source] is the sender's origin as the platform reports it (never the
/// message body), [document] the URL the native host committed, and
/// [documentToken] the token it issued to that document. All of them must
/// agree, and both origins must be first-party for a build of [environment].
BrowserUiCommand? browserUiCommand(
  Map<String, dynamic> message, {
  required Uri source,
  required Uri? document,
  required String documentToken,
  required bool mainFrame,
  required Environment environment,
}) {
  if (message['namespace'] != browserUiNamespace ||
      !mainFrame ||
      documentToken.isEmpty ||
      message['documentToken'] != documentToken ||
      document == null ||
      !isFirstPartyOrigin(document, environment) ||
      !isFirstPartyOrigin(source, environment) ||
      source.host.toLowerCase() != document.host.toLowerCase() ||
      _port(source) != _port(document)) {
    return null;
  }
  final params = message['params'];
  return switch ((message['method'], params)) {
    ('setOverlay', final Map<dynamic, dynamic> p) when p['active'] is bool =>
      BrowserUiSetOverlay(active: p['active'] as bool),
    _ => null,
  };
}

/// The theme name the page sees.
String browserUiTheme({required bool dark}) => dark ? 'dark' : 'light';

/// The document-start script that grants the UI channel to a first-party
/// document of a build of [environment], with the wallet's theme at the time
/// the WebView was created.
///
/// It runs immediately before the provider script and leaves a one-shot grant
/// that the provider takes, and deletes, before any page script runs. Its own
/// check of the document's origin ([_firstPartyDocumentScript], the same
/// rules as [isFirstPartyOrigin]) is what decides on iOS, and in development
/// builds on Android too; see [browserUiOriginRules].
String browserUiGrantScript({
  required Environment environment,
  required bool dark,
}) =>
    '$_grantScript(${_firstPartyDocument(environment)}, ${jsonEncode(browserUiTheme(dark: dark))});';

const _grantScript = r'''
((firstParty, theme) => {
  'use strict';
  if (window !== window.top || window.opener != null || firstParty !== true) return;
  if (theme !== 'light' && theme !== 'dark') return;
  Object.defineProperty(window, '__mallowUiGrant', {value: Object.freeze({theme}), configurable: true});
})''';

/// The call, as JavaScript, that says whether the current document is
/// first-party for a build of [environment].
String _firstPartyDocument(Environment environment) =>
    '$_firstPartyDocumentScript(${jsonEncode(browserFirstPartyOriginsFor(environment))}, ${environment == Environment.development})';

/// [isFirstPartyOrigin] for the document the script runs in, given the exact
/// origins and whether local development hosts count. It reads the browser's
/// own parse of the URL, whose host is already canonical: IPv4 as four
/// decimal octets, IPv6 bracketed, lowercase and compressed, with no dotted
/// tail.
const _firstPartyDocumentScript = r'''
((origins, local) => {
  'use strict';
  if (location.protocol !== 'https:') return false;
  if (origins.includes(location.origin)) return true;
  if (local !== true) return false;
  const host = location.hostname.toLowerCase();
  const label = '[a-z0-9](?:[a-z0-9-]*[a-z0-9])?';
  if (host === 'localhost' || new RegExp(`^${label}(?:\\.${label})*\\.(?:localhost|local|ts\\.net)$`).test(host)) return true;
  const v4 = /^(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$/.exec(host);
  if (v4) {
    const [a, b, c, d] = v4.slice(1).map(Number);
    if (a > 255 || b > 255 || c > 255 || d > 255) return false;
    return a === 127 || a === 10 || (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) || (a === 169 && b === 254) || (a === 100 && b >= 64 && b <= 127);
  }
  const v6 = /^\[([0-9a-f:]+)\]$/.exec(host);
  if (!v6) return false;
  const halves = v6[1].split('::');
  if (halves.length > 2) return false;
  const [head, tail] = halves.map(half => (half ? half.split(':') : []));
  const gap = 8 - head.length - (tail ? tail.length : 0);
  if (tail ? gap < 1 : gap !== 0) return false;
  const groups = [...head, ...Array(tail ? gap : 0).fill('0'), ...(tail || [])];
  if (!groups.every(group => /^[0-9a-f]{1,4}$/.test(group))) return false;
  const [first] = groups.map(group => parseInt(group, 16));
  const loopback = groups.slice(0, 7).every(group => parseInt(group, 16) === 0) && parseInt(groups[7], 16) === 1;
  return loopback || (first & 0xfe00) === 0xfc00 || (first & 0xffc0) === 0xfe80;
})''';

/// The user-script group of [browserUiGrantScript].
const browserUiGrantGroup = 'mallow-ui';

/// The user-script group of [browserUiStartThemeScript].
const browserUiStartThemeGroup = 'mallow-ui-theme';

/// The document-start script that hands documents loaded later in the same
/// WebView the wallet's current theme, after the wallet's theme has moved
/// away from the one baked into [browserUiGrantScript].
///
/// The grant has to run before the provider, and a user script added later
/// runs after every earlier one, so the grant itself is left alone. This
/// script is added after the provider instead, and still runs before any
/// page script: it sets the theme through the provider's own hook, so a page
/// that reads `window.mallow.ui.theme` at boot already sees the current one.
/// Replaced, never stacked, on each change; see [browserUiStartThemeGroup].
String browserUiStartThemeScript({
  required Environment environment,
  required bool dark,
}) =>
    '$_startThemeScript(${_firstPartyDocument(environment)}, ${jsonEncode(browserUiTheme(dark: dark))});';

const _startThemeScript = r'''
((firstParty, theme) => {
  'use strict';
  if (window !== window.top || firstParty !== true) return;
  const set = Object.getOwnPropertyDescriptor(window, '__mallowUiSetTheme')?.value;
  if (typeof set === 'function') set(theme);
})''';

/// The platform origin rules for the grant and start-theme scripts.
///
/// On Android the WebView enforces them natively, so production and staging
/// builds list the exact first-party origins. A development build cannot:
/// the rules name a scheme, a host or a `*.` host wildcard, and a port, so
/// they have no way to say "any private address on any port" — an IP range
/// is not a host wildcard. It uses `'*'` instead, and the decision rests on
/// the script's own check of the document's origin and, for every message,
/// on the native check in [browserUiCommand].
///
/// iOS always uses `'*'`: the plugin only wraps the script in an unanchored
/// regular-expression test that the script's own exact check already does
/// better.
Set<String> browserUiOriginRules(
  Environment environment, {
  required bool android,
}) => android && environment != Environment.development
    ? browserFirstPartyOriginsFor(environment).toSet()
    : const {'*'};

/// Tells a first-party page the wallet's theme. It updates
/// `window.mallow.ui.theme` and dispatches `mallow:theme`, only on a change.
String browserUiThemeScript({required bool dark}) =>
    'window.__mallowUiSetTheme && window.__mallowUiSetTheme(${jsonEncode(browserUiTheme(dark: dark))});';

/// A tap on the dimmed browser chrome, for the page to treat exactly like a
/// tap on its own sheet's scrim.
const browserUiScrimTapScript =
    "window.dispatchEvent(new CustomEvent('mallow:scrim-tap'));";
