import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/environment.dart';
import '../../../core/utils/reduce_motion.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_sheet.dart';

import '../models/browser_app_link.dart';
import '../models/browser_models.dart';
import '../models/dapp_request.dart';
import '../services/browser_appearance.dart';
import '../services/browser_bottom_overlay.dart';
import '../services/browser_certificate_exceptions.dart';
import '../services/browser_http_auth_service.dart';
import '../services/browser_site_icons.dart';
import '../services/browser_ui_channel.dart';
import '../services/dapp_provider_script.dart';
import 'browser_certificate_warning.dart';
import 'browser_host_text.dart';
import 'browser_http_auth_sheet.dart';
import 'browser_js_dialog.dart';
import '../../walletconnect/walletconnect_module.dart';

// WebViewCompat does not accept a wildcard host with an HTTPS scheme.
// The callback independently enforces HTTPS using the native source origin.
const browserWalletOriginRules = <String>{'*'};

const _popupGestureScript = r'''
(() => {
  let trustedClickAt = Number.NEGATIVE_INFINITY;
  const monotonicNow = performance.now.bind(performance);
  document.addEventListener('click', (event) => {
    if (event.isTrusted) trustedClickAt = monotonicNow();
  }, true);
  Object.defineProperty(window, '__mallowConsumePopupGesture', {
    configurable: false,
    enumerable: false,
    writable: false,
    value: () => {
      const accepted = monotonicNow() - trustedClickAt <= 1500;
      trustedClickAt = Number.NEGATIVE_INFINITY;
      return accepted;
    },
  });
})();
''';

/// Lists the page's declared icons and web app manifest without leaving the
/// page. Only `href`, `rel` and `sizes` cross the bridge, capped so a hostile
/// page cannot flood it.
const _faviconScript = r'''
(() => Array.from(document.querySelectorAll('link[rel][href]'))
  .filter((link) => /(^|\s)(icon|apple-touch-icon(-precomposed)?|manifest)(\s|$)/i.test(link.rel))
  .slice(0, 32)
  .map((link) => ({
    rel: String(link.rel).toLowerCase(),
    href: String(link.href),
    sizes: link.sizes ? String(link.sizes.value || '') : '',
  })))();
''';

/// Probes the page for the browser's chrome, in one call.
///
/// Colour: the root and body backgrounds, and the first `theme-color` whose
/// media query matches. Each is painted onto a 1×1 canvas and read back as
/// `[r, g, b, a]` bytes, so any CSS colour syntax arrives as sRGB, and
/// anything invalid as transparent.
///
/// Bottom bar (only when [band], the bar's height in logical pixels, is
/// positive): whether the page may run under the bar (`overlay`; see
/// `BrowserBottomOverlay`). Points across the bottom [band] of the viewport
/// are hit-tested. The strip is unsafe if any of them lands in a fixed
/// element or one stuck to the bottom (the page's own bottom UI), or inside a
/// scroll container other than the document, whose end could never scroll
/// out from under the bar. Otherwise it is safe if nothing is there, or if
/// the document itself scrolls and its scroll range ends with its normal
/// flow, which the spacer below extends.
///
/// The spacer is an `html::after` block the bar's height tall, in an adopted
/// stylesheet, which a page's Content Security Policy does not block. It is
/// on only while [keepSpacer] says the page runs under the bar, and is left
/// alone when [band] is zero (the keyboard is up).
///
/// [width] is the WebView's width in logical pixels; it converts the band to
/// CSS pixels for pages that do not lay out at the device width.
String _pageProbeScript({
  required double band,
  required double width,
  required bool keepSpacer,
}) =>
    '''
((band, width, keep) => {
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 1;
  const context = canvas.getContext('2d', { willReadFrequently: true });
  const rgba = (css) => {
    if (!context || !css) return null;
    context.clearRect(0, 0, 1, 1);
    context.fillStyle = 'rgba(0, 0, 0, 0)';
    context.fillStyle = String(css);
    context.fillRect(0, 0, 1, 1);
    return Array.from(context.getImageData(0, 0, 1, 1).data);
  };
  const background = (element) =>
    element ? rgba(getComputedStyle(element).backgroundColor) : null;
  const theme = Array.from(document.querySelectorAll('meta[name="theme-color" i][content]'))
    .slice(0, 8)
    .find((meta) => {
      try {
        return !meta.media || matchMedia(meta.media).matches;
      } catch (_) {
        return false;
      }
    });
  const doc = document.documentElement;
  const body = document.body;
  const result = {
    root: background(doc),
    body: background(body),
    theme: theme ? rgba(theme.content) : null,
    overlay: null,
  };
  if (!(band > 0) || !doc || !body) return result;

  const standards = document.compatMode === 'CSS1Compat';
  const viewportWidth = standards ? doc.clientWidth : window.innerWidth;
  const viewportHeight = standards ? doc.clientHeight : window.innerHeight;
  const scale = width > 0 && viewportWidth > 0 ? viewportWidth / width : 1;
  const bandPx = band * scale;
  const spacerPx = Math.ceil(bandPx);

  let sheet = null;
  try {
    sheet = document.adoptedStyleSheets.find((each) => each.__mallowSpacer) || null;
    if (keep && !sheet) {
      sheet = new CSSStyleSheet();
      Object.defineProperty(sheet, '__mallowSpacer', { value: true });
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    }
    if (sheet && keep && sheet.__mallowHeight !== spacerPx) {
      sheet.replaceSync('html::after{content:"";display:block;height:' + spacerPx + 'px}');
      sheet.__mallowHeight = spacerPx;
    }
    if (sheet) sheet.disabled = !keep;
  } catch (_) {
    sheet = null;
  }

  const ascend = (node) =>
    node.parentElement || (node.getRootNode && node.getRootNode().host) || null;
  let content = false;
  for (const offset of [2, bandPx / 2, bandPx - 2]) {
    for (const fraction of [0.15, 0.5, 0.85]) {
      const hit = document.elementFromPoint(viewportWidth * fraction, viewportHeight - offset);
      if (!hit || hit === doc || hit === body) continue;
      content = true;
      for (let node = hit; node && node !== doc && node !== body; node = ascend(node)) {
        const style = getComputedStyle(node);
        if (style.position === 'fixed' || (style.position === 'sticky' && style.bottom !== 'auto')) {
          result.overlay = false;
          return result;
        }
        if (/auto|scroll|overlay/.test(style.overflowY) && node.scrollHeight > node.clientHeight + 1) {
          result.overlay = false;
          return result;
        }
      }
    }
  }
  if (!content) {
    result.overlay = true;
    return result;
  }
  const locked = (element) => /hidden|clip/.test(getComputedStyle(element).overflowY);
  if (locked(doc) || locked(body)) {
    result.overlay = false;
    return result;
  }
  // The root's box holds the whole flow, the body's collapsed margins and the
  // spacer included, unless the page fixes its height.
  const scroller = document.scrollingElement || doc;
  const flowEnd = doc.getBoundingClientRect().bottom + window.scrollY;
  result.overlay =
    scroller.scrollHeight <= Math.max(scroller.clientHeight, flowEnd) + 1;
  return result;
})($band, $width, $keepSpacer);
''';

/// Draws the chosen icon onto a canvas inside the page and leaves a PNG data
/// URL under [key] on `window`, or an empty string on failure. The page loads
/// it with its own cookies and certificate state, so it works where the image
/// CDN is refused. A cross-origin icon needs CORS to be read back; without it
/// the capture fails and the tile uses the icon URL instead.
String _iconCaptureScript(String key, Uri icon) =>
    '''
(() => {
  const key = ${jsonEncode(key)};
  const done = (value) => {
    try {
      Object.defineProperty(window, key, { value, configurable: true });
    } catch (_) {}
  };
  try {
    const url = new URL(${jsonEncode(icon.toString())});
    const image = new Image();
    if (url.origin !== location.origin) image.crossOrigin = 'anonymous';
    const timer = setTimeout(() => done(''), 3000);
    image.onload = () => {
      clearTimeout(timer);
      try {
        const size = $browserIconCaptureSize;
        const width = image.naturalWidth || size;
        const height = image.naturalHeight || size;
        const scale = Math.min(size / width, size / height);
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = size;
        const context = canvas.getContext('2d');
        context.imageSmoothingQuality = 'high';
        context.drawImage(
          image,
          (size - width * scale) / 2,
          (size - height * scale) / 2,
          width * scale,
          height * scale,
        );
        const pixels = context.getImageData(0, 0, size, size).data;
        let drawn = false;
        for (let i = 3; i < pixels.length && !drawn; i += 4) drawn = pixels[i] > 0;
        done(drawn ? canvas.toDataURL('image/png') : '');
      } catch (_) {
        done('');
      }
    };
    image.onerror = () => {
      clearTimeout(timer);
      done('');
    };
    image.src = url.href;
  } catch (_) {
    done('');
  }
  return true;
})();
''';

/// Fetches the web app manifest at [manifest] from inside the page and leaves
/// its icons under [key] on `window`, as a JSON list of `href` (resolved
/// against the manifest), `sizes`, `type` and `purpose`, or an empty string on
/// failure. The page's own fetch carries its cookies and certificate state,
/// as a browser's manifest request would; a Content Security Policy that
/// blocks it only costs the larger icon.
String _manifestIconsScript(String key, Uri manifest) =>
    '''
(() => {
  const key = ${jsonEncode(key)};
  const done = (value) => {
    try {
      Object.defineProperty(window, key, { value, configurable: true });
    } catch (_) {}
  };
  const text = (value, length) =>
    typeof value === 'string' ? value.slice(0, length) : '';
  try {
    const url = new URL(${jsonEncode(manifest.toString())});
    const timer = setTimeout(() => done(''), 3000);
    fetch(url.href, { credentials: 'same-origin' })
      .then((response) => (response.ok ? response.text() : ''))
      .then((body) => {
        clearTimeout(timer);
        if (!body || body.length > 256 * 1024) return done('');
        const icons = JSON.parse(body).icons;
        if (!Array.isArray(icons)) return done('');
        const list = [];
        for (const icon of icons.slice(0, 32)) {
          if (!icon || typeof icon.src !== 'string') continue;
          try {
            list.push({
              href: new URL(icon.src, url).href.slice(0, 2048),
              sizes: text(icon.sizes, 200),
              type: text(icon.type, 100),
              purpose: text(icon.purpose, 100),
            });
          } catch (_) {}
        }
        done(JSON.stringify(list));
      })
      .catch(() => {
        clearTimeout(timer);
        done('');
      });
  } catch (_) {
    done('');
  }
  return true;
})();
''';

/// Reads and removes the result left under [key]; null while it is pending.
String _pageResultScript(String key) =>
    '''
(() => {
  const key = ${jsonEncode(key)};
  if (!Object.prototype.hasOwnProperty.call(window, key)) return null;
  const value = window[key];
  delete window[key];
  return typeof value === 'string' ? value : '';
})();
''';

/// Picks the best site icon from [links] (the `_faviconScript` result) and
/// [manifestIcons] (the `_manifestIconsScript` result): HTTPS without
/// credentials, on the page's own registrable domain, largest declared size
/// first, with a general-purpose icon, then apple-touch-icon, then the page's
/// own host breaking ties. A manifest icon meant only as a monochrome mask is
/// skipped, and so is anything else that fails these rules, so a page can at
/// worst choose its own site's icon. With none left it is the origin's
/// `/favicon.ico`, which browsers request by convention when a page declares
/// nothing; if that is missing too, the tile shows a monogram.
@visibleForTesting
Uri? pickBrowserFavicon(Uri document, Object? links, {Object? manifestIcons}) {
  if (!isBrowserUrl(document)) return null;
  final candidates = [
    ..._jsonList(links).take(32),
    for (final icon in _jsonList(manifestIcons).take(32))
      if (icon is Map) {...icon, 'rel': _manifestIconRel},
  ];
  return _declaredFavicon(document, candidates) ??
      Uri(
        scheme: document.scheme,
        host: document.host,
        port: document.hasPort ? document.port : null,
        path: '/favicon.ico',
      );
}

/// Picks the colour the page shows behind its content from [raw] (the
/// `_pageProbeScript` result), as CSS paints the canvas: the root element's
/// background, or the body's where the root has none. A page with neither
/// falls back to its `theme-color`. Only opaque colours count: anything
/// translucent is drawn over a backdrop the page does not know.
@visibleForTesting
Color? pickBrowserPageColor(Object? raw) {
  raw = _probeResult(raw);
  if (raw is! Map) return null;
  List<int>? bytes(Object? value) {
    if (value is! List || value.length != 4) return null;
    if (value.any((channel) => channel is! num)) return null;
    return [
      for (final channel in value) (channel as num).toInt().clamp(0, 255),
    ];
  }

  Color? opaque(Object? value) => switch (bytes(value)) {
    [final r, final g, final b, 255] => Color.fromARGB(255, r, g, b),
    _ => null,
  };
  final root = raw['root'];
  final rootClear = bytes(root)?.last == 0;
  return opaque(root) ??
      (rootClear ? opaque(raw['body']) : null) ??
      opaque(raw['theme']);
}

/// Where a message from the page's bridge goes.
enum BrowserBridgeRoute { rejected, ui, dapp }

/// Routes the bridge message [raw] from [origin] (as the platform reports
/// it): rejected unless it comes from the main frame of the current
/// committed HTTPS [document] with that document's [documentToken].
///
/// The first-party UI channel is routed before the popup gate
/// ([popupPending]), which holds back only wallet requests. A `ui` message
/// asks for no approval and changes no grant, and a release dropped while a
/// popup decision is pending would leave the chrome dimmed under a page with
/// no sheet left to close. Its own first-party checks come next, in
/// [browserUiCommand].
@visibleForTesting
BrowserBridgeRoute browserBridgeRoute(
  Object? raw, {
  required Uri origin,
  required bool mainFrame,
  required bool ready,
  required Uri? document,
  required String documentToken,
  required bool popupPending,
}) {
  if (!ready ||
      !mainFrame ||
      !isBrowserUrl(origin) ||
      document == null ||
      !isBrowserUrl(document) ||
      origin.origin != document.origin ||
      raw is! Map ||
      raw['documentToken'] != documentToken) {
    return BrowserBridgeRoute.rejected;
  }
  if (raw['namespace'] == browserUiNamespace) return BrowserBridgeRoute.ui;
  return popupPending ? BrowserBridgeRoute.rejected : BrowserBridgeRoute.dapp;
}

/// Whether an iOS bridge call made from [requestUrl] (the sending frame's
/// URL) belongs to the committed [document].
///
/// Wallet requests must come from exactly the committed URL. A `ui` message
/// needs only the same origin: a single-page app can change its URL and
/// close a sheet in one step, and the release must not be lost while the
/// URL change is still on its way to the native host. The document token
/// still has to match, which ties it to the document.
@visibleForTesting
bool browserBridgeRequestUrlCurrent(
  Object? raw,
  Uri? requestUrl,
  Uri? document,
) {
  if (requestUrl == null || document == null) return false;
  if (requestUrl == document) return true;
  return raw is Map &&
      raw['namespace'] == browserUiNamespace &&
      isBrowserUrl(requestUrl) &&
      isBrowserUrl(document) &&
      requestUrl.origin == document.origin;
}

/// Whether the `_pageProbeScript` result in [raw] finds the strip under the
/// bottom bar safe for the page, or null if it did not probe it.
@visibleForTesting
bool? browserProbeOverlay(Object? raw) {
  final result = _probeResult(raw);
  return result is Map && result['overlay'] is bool
      ? result['overlay'] as bool
      : null;
}

/// Android can hand back the JSON text of the probe's result.
Object? _probeResult(Object? raw) {
  if (raw is! String) return raw;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

/// The page's web app manifest from [links] (the `_faviconScript` result),
/// when it is HTTPS on the page's own registrable domain, else null.
@visibleForTesting
Uri? browserManifestUrl(Uri document, Object? links) {
  if (!isBrowserUrl(document)) return null;
  for (final link in _jsonList(links).take(32)) {
    if (link is! Map) continue;
    final href = link['href'], rel = link['rel'];
    if (href is! String || rel is! String) continue;
    if (!_relTokens(rel).contains('manifest')) continue;
    final uri = Uri.tryParse(href);
    if (uri != null && isBrowserUrl(uri) && _sameSite(uri, document)) {
      return uri;
    }
  }
  return null;
}

/// Marks a manifest icon among the page's `<link>` icons; it has no `rel`.
const _manifestIconRel = 'mallow-manifest-icon';

/// Android can hand back the JSON text of a list.
List<Object?> _jsonList(Object? raw) {
  if (raw is String) {
    try {
      raw = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
  }
  return raw is List ? raw : const [];
}

List<String> _relTokens(String rel) => rel.toLowerCase().split(RegExp(r'\s+'));

/// Same site only: evil.example must not borrow mallow.art's logo.
bool _sameSite(Uri uri, Uri document) =>
    browserRegistrableDomain(uri.host) ==
    browserRegistrableDomain(document.host);

Uri? _declaredFavicon(Uri document, List<Object?> links) {
  // Icons load through the image CDN, which rasterises SVG; without one the
  // image decoder cannot, and the tile would only show its fallback.
  final svg = Config.imageCdnBaseUrl.isNotEmpty;
  Uri? best;
  var bestScore = -1;
  for (final link in links) {
    if (link is! Map) continue;
    final href = link['href'], rel = link['rel'], sizes = link['sizes'];
    if (href is! String || rel is! String) continue;
    final tokens = _relTokens(rel);
    final touch = tokens.any((token) => token.startsWith('apple-touch-icon'));
    final manifest = tokens.contains(_manifestIconRel);
    if (!touch && !manifest && !tokens.contains('icon')) continue;
    // A manifest icon's purpose: `monochrome` alone is a mask, drawn in one
    // colour by the platform, and `maskable` has its mark inset for cropping.
    final purpose = link['purpose'];
    final purposes = manifest && purpose is String && purpose.trim().isNotEmpty
        ? _relTokens(purpose.trim())
        : const ['any'];
    if (!purposes.contains('any') && !purposes.contains('maskable')) continue;
    final uri = Uri.tryParse(href);
    if (uri == null || !isBrowserUrl(uri)) continue;
    if (!_sameSite(uri, document)) continue;
    final path = uri.path.toLowerCase();
    final type = link['type'];
    final vector =
        path.endsWith('.svg') || (type is String && type.contains('svg'));
    if (vector && !svg) continue;
    // A vector icon scales to any tile, but a large declared raster is the
    // site's own choice of a detailed mark, so it ranks as a mid-size raster.
    var size = vector
        ? 128
        : touch
        ? 180
        : (path.endsWith('.ico') ? 16 : 32);
    if (sizes is String) {
      final declared = RegExp(
        r'(\d{1,5})x\d{1,5}',
      ).allMatches(sizes).map((match) => int.parse(match.group(1)!));
      if (declared.isNotEmpty && !vector) size = declared.reduce(max);
    }
    final score =
        size.clamp(0, 1024) * 8 +
        (purposes.contains('any') ? 4 : 0) +
        (touch ? 2 : 0) +
        (uri.host == document.host ? 1 : 0);
    if (score > bestScore) {
      best = uri;
      bestScore = score;
    }
  }
  return best;
}

/// Plugin event logs include full URLs and bridge arguments even when the
/// website console callback is a no-op. Disable them before controller creation.
void configureBrowserWebViewPrivacy() {
  PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
}

/// The Android handler bridge reports JavaScript-supplied provenance, so wallet
/// requests use WebViewCompat's native WebMessageListener instead. iOS handlers
/// provide WKFrameInfo. Neither transport accepts an origin in the request body.
class BrowserWebViewHost extends StatefulWidget {
  const BrowserWebViewHost({
    required this.tabId,
    required this.url,
    required this.onController,
    required this.onNavigationStarted,
    required this.onNavigation,
    required this.onRequest,
    required this.onProgress,
    required this.onTitle,
    required this.onPopup,
    required this.onError,
    this.onAppLink,
    this.beforeNavigation,
    this.onFavicon,
    this.onPageColor,
    this.bottomBand = 0,
    this.onBottomOverlay,
    this.onScrollChanged,
    this.onLoadStop,
    this.onCertificateDeclined,
    this.onUiCommand,
    this.canPrompt,
    this.onProcessGone,
    super.key,
  });
  final String tabId;
  final Uri url;
  final ValueChanged<InAppWebViewController> onController;

  /// Selects the site's chain wallet before startup connection requests.
  final Future<void> Function(Uri url)? beforeNavigation;
  final void Function(int generation) onNavigationStarted;
  final void Function(int generation, Uri? url) onNavigation;
  final Future<Map<String, Object?>> Function(
    Map<String, dynamic>,
    DappFrameContext,
  )
  onRequest;
  final ValueChanged<int> onProgress;
  final ValueChanged<String> onTitle;
  final ValueChanged<Uri> onPopup;
  final ValueChanged<String> onError;

  /// Opens a link in the app's own scheme that the page navigated to (see
  /// [browserAppLink]). False when nothing in the app takes it.
  final bool Function(Uri link)? onAppLink;

  /// The committed document's best declared icon, after its main frame stops
  /// loading. Never called for a document that has since been replaced.
  final ValueChanged<Uri>? onFavicon;

  /// The opaque colour the committed document paints behind its content, or
  /// null if it offers none. Called once a colour has held for a moment after
  /// the document is ready, and again whenever a later one does: pages change
  /// their background without navigating (a theme toggle, a client-side
  /// route).
  final ValueChanged<Color?>? onPageColor;

  /// The height, in logical pixels, of the bottom bar the page may run under,
  /// or 0 where it must not (the keyboard is up, the browser is covered, or
  /// the platform makes the covered strip unsafe itself). While it is
  /// positive the page is probed every second, and [onBottomOverlay] reports
  /// each change of whether the page should run under the bar.
  final double bottomBand;
  final ValueChanged<bool>? onBottomOverlay;

  /// The page's vertical scroll offset, on every scroll event. Consumers
  /// should act on direction changes only: this fires once per frame.
  final ValueChanged<int>? onScrollChanged;

  /// The main frame stopped loading and its document is committed.
  final VoidCallback? onLoadStop;

  /// The user backed out of a certificate warning and this WebView has no
  /// page of its own to return to.
  final VoidCallback? onCertificateDeclined;

  /// A first-party page's UI channel message (see `browser_ui_channel.dart`),
  /// already checked against the committed document. Never routed through
  /// [onRequest]: it asks for no approval.
  final void Function(BrowserUiCommand command, DappFrameContext frame)?
  onUiCommand;

  /// Whether the user is looking at the page. The WebView outlives the app
  /// lock and backgrounding, and the page goes on running, so a dialog or
  /// sign-in it raises then is refused rather than left waiting for whoever
  /// unlocks the app.
  final bool Function()? canPrompt;

  /// The page's process ended and this WebView cannot draw again; the owner
  /// replaces it.
  final VoidCallback? onProcessGone;

  @override
  State<BrowserWebViewHost> createState() => _BrowserWebViewHostState();
}

class _BrowserWebViewHostState extends State<BrowserWebViewHost> {
  int _generation = 0;
  int _navigationPreparationRevision = 0;
  String _documentToken = '';
  Uri? _documentUrl;
  bool _ready = false;
  int? _failedGeneration;

  /// The icon last handed to `onFavicon` for this document.
  Uri? _reportedIcon;

  /// The last web app manifest read for its icons, and what it listed.
  ({Uri url, Object? icons})? _manifest;
  Timer? _faviconRescan;

  /// The document generation and colour last handed to `onPageColor`.
  int? _colorGeneration;
  Color? _reportedColor;

  /// A colour is reported only once it has held this long. Pages often paint
  /// first in their default theme and switch a moment later, when a script
  /// adds a dark class; reporting the first paint flashed the browser's
  /// strips light and back.
  static const _colorSettle = Duration(milliseconds: 700);

  /// The colour the probes currently see, for which document, and since when.
  Color? _seenColor;
  int? _seenGeneration;
  DateTime? _seenSince;
  Timer? _colorConfirm;

  final _bottomOverlay = BrowserBottomOverlay();

  /// Probes the page again once scrolling settles, or after a resize.
  Timer? _probeRescan;

  /// Probes the page every second while [BrowserWebViewHost.bottomBand] is
  /// positive.
  Timer? _probeTicker;
  bool _probing = false;

  /// A page has drawn into this WebView. Until then the theme's background
  /// covers it: a WebView paints white before its first page, which flashes
  /// in dark mode. Later navigations keep the previous page on screen until
  /// the next one commits, so the cover is needed only once per WebView.
  bool _painted = false;
  final Set<_PopupWindowCapture> _popupCaptures = {};
  int _popupCallbacksInFlight = 0;

  /// The main-frame URL being loaded, as far as navigation callbacks tell.
  /// Only a certificate failure on its origin is shown as a warning page;
  /// one on another origin is a subresource and fails silently.
  Uri? _loading;

  /// A document has committed here, so backing out of a warning returns to it.
  bool _committedOnce = false;

  /// Recent certificate failures by origin. Android may report a main-frame
  /// failure only through onReceivedError, after the trust callback.
  final Map<String, BrowserCertificateFailure> _certificateFailures = {};
  BrowserCertificateFailure? _certificateWarning;

  /// Open sign-in prompts by protection space, so parallel requests to one
  /// server share a prompt. Prompts for different servers wait in turn.
  final Map<String, Future<BrowserHttpCredentials?>> _httpAuthPrompts = {};
  Future<void> _httpAuthQueue = Future.value();
  ModalBottomSheetRoute<BrowserHttpCredentials>? _httpAuthRoute;
  final _disposed = Completer<void>();
  InAppWebViewController? _controller;

  /// alert / confirm / prompt / beforeunload, named by the site that raised
  /// them. The platform's own dialogs name no one.
  late final _jsDialogs = BrowserJsDialogs(
    context: () => context,
    isActive: () => _canPrompt,
    document: () => (key: _generation, url: _ready ? _documentUrl : null),
  );

  bool get _canPrompt => mounted && (widget.canPrompt?.call() ?? true);

  @override
  void initState() {
    super.initState();
    configureBrowserWebViewPrivacy();
    unawaited(BrowserCertificateExceptions.instance.load());
    _syncProbeTicker();
  }

  @override
  void didUpdateWidget(BrowserWebViewHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncProbeTicker();
  }

  /// Nothing tells the app that a page added or removed bottom UI (a dialog,
  /// a cookie banner), or changed its background, so it is probed on a timer
  /// while the bottom bar is in play.
  void _syncProbeTicker() {
    final wanted = widget.bottomBand > 0 && widget.onBottomOverlay != null;
    if (wanted == (_probeTicker != null)) return;
    _probeTicker?.cancel();
    _probeTicker = wanted
        ? Timer.periodic(const Duration(seconds: 1), (_) {
            final controller = _controller;
            if (controller != null && _ready) unawaited(_probePage(controller));
          })
        : null;
  }

  /// The brightness last handed to [BrowserAppearance] by this host.
  bool? _dark;

  /// The theme baked into this WebView's first-party grant script when it
  /// was created. Later documents start from it until the wallet's theme
  /// moves, when [_syncUiStartTheme] overrides it from document start; and
  /// [_documentCommitted] tells each document the current theme again.
  bool? _grantDark;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Runs before the WebView is first built, so a new page paints in the
    // wallet's theme, and again whenever a dependency changes; only a theme
    // change goes to the platform.
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (dark == _dark) return;
    _dark = dark;
    unawaited(BrowserAppearance.apply(dark: dark));
    _pushUiTheme();
    unawaited(_syncUiStartTheme());
  }

  /// The theme first-party documents loaded later in this WebView start
  /// with: the grant's ([_grantDark]) until [_syncUiStartTheme] installs
  /// another.
  bool? _startDark;

  /// Keeps the theme a first-party document boots with in step with the
  /// wallet's, so a later navigation in this WebView never starts in the
  /// theme it was created with and flashes when corrected at commit.
  Future<void> _syncUiStartTheme() async {
    final controller = _controller;
    final dark = _dark;
    final grant = _grantDark;
    if (controller == null ||
        dark == null ||
        grant == null ||
        dark == (_startDark ?? grant)) {
      return;
    }
    _startDark = dark;
    try {
      // Always replaced, even with the grant's own theme: platform calls run
      // in order, so the script added last is the current theme's however
      // quickly the theme flips.
      await controller.removeUserScriptsByGroupName(
        groupName: browserUiStartThemeGroup,
      );
      await controller.addUserScript(
        userScript: UserScript(
          groupName: browserUiStartThemeGroup,
          source: browserUiStartThemeScript(
            environment: Config.environment,
            dark: dark,
          ),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          allowedOriginRules: browserUiOriginRules(
            Config.environment,
            android: Platform.isAndroid,
          ),
        ),
      );
    } catch (_) {
      // Cosmetic: each first-party document is told the theme at commit.
    }
  }

  /// Tells the committed first-party document the wallet's theme. Never a
  /// third-party one: it could have defined the hook itself.
  void _pushUiTheme() {
    final controller = _controller;
    final dark = _dark;
    if (controller == null ||
        dark == null ||
        !_ready ||
        !isFirstPartyOrigin(_documentUrl, Config.environment)) {
      return;
    }
    unawaited(
      controller
          .evaluateJavascript(source: browserUiThemeScript(dark: dark))
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  static const _rejected = <String, Object?>{
    'error': {
      'code': 4100,
      'message': 'Wallet request is not from the active HTTPS document',
    },
  };

  Future<Map<String, Object?>> _request(
    Object? raw,
    Uri origin,
    bool mainFrame,
  ) async {
    if (!mounted) return _rejected;
    final route = browserBridgeRoute(
      raw,
      origin: origin,
      mainFrame: mainFrame,
      ready: _ready,
      document: _documentUrl,
      documentToken: _documentToken,
      popupPending: _popupCallbacksInFlight > 0 || _popupCaptures.isNotEmpty,
    );
    if (route == BrowserBridgeRoute.rejected) return _rejected;
    final message = Map<String, dynamic>.from(raw as Map);
    if (route == BrowserBridgeRoute.ui) {
      return _uiRequest(message, origin, mainFrame);
    }
    return widget.onRequest(
      message,
      DappFrameContext(
        tabId: widget.tabId,
        generation: _generation,
        origin: origin,
        isMainFrame: mainFrame,
        isActive: true,
        certificateException: BrowserCertificateExceptions.instance.covers(
          origin.origin,
        ),
        documentToken: _documentToken,
      ),
    );
  }

  /// The first-party UI channel: checked here and handed to the screen,
  /// bypassing the dApp request path entirely. Anything else is dropped.
  Map<String, Object?> _uiRequest(
    Map<String, dynamic> message,
    Uri origin,
    bool mainFrame,
  ) {
    final onUiCommand = widget.onUiCommand;
    final command = browserUiCommand(
      message,
      source: origin,
      document: _documentUrl,
      documentToken: _documentToken,
      mainFrame: mainFrame,
      environment: Config.environment,
    );
    if (onUiCommand == null || command == null) return _rejected;
    onUiCommand(
      command,
      DappFrameContext(
        tabId: widget.tabId,
        generation: _generation,
        origin: origin,
        isMainFrame: mainFrame,
        isActive: true,
      ),
    );
    return const {'result': null};
  }

  Future<bool> _popupSourceIsCurrent(
    InAppWebViewController controller,
    CreateWindowAction action,
    int generation,
    Uri documentUrl,
  ) async {
    if (!mounted ||
        !_ready ||
        generation != _generation ||
        documentUrl != _documentUrl ||
        !isBrowserUrl(documentUrl)) {
      return false;
    }
    final actual = Uri.tryParse((await controller.getUrl())?.toString() ?? '');
    if (!mounted ||
        generation != _generation ||
        actual == null ||
        actual.origin != documentUrl.origin) {
      return false;
    }
    if (Platform.isAndroid &&
        (!action.isForMainFrame || action.hasGesture != true)) {
      return false;
    }
    if (Platform.isIOS) {
      final source = action.sourceFrame;
      final sourceOrigin = source?.securityOrigin;
      if (source == null ||
          !source.isMainFrame ||
          sourceOrigin == null ||
          sourceOrigin.protocol != 'https' ||
          sourceOrigin.host != documentUrl.host ||
          _originPort(sourceOrigin) != _uriPort(documentUrl)) {
        return false;
      }
    }
    try {
      return await controller.evaluateJavascript(
            source: 'window.__mallowConsumePopupGesture?.() === true',
          ) ==
          true;
    } catch (_) {
      return false;
    }
  }

  int _uriPort(Uri uri) => uri.hasPort ? uri.port : 443;

  /// Whether the page itself started [action], and on Android only from a
  /// tap, as for a popup: a hidden frame must not reach the app's own flows.
  bool _fromPage(NavigationAction action) => Platform.isAndroid
      ? action.isForMainFrame && action.hasGesture == true
      : action.isForMainFrame && (action.sourceFrame?.isMainFrame ?? false);

  int _originPort(SecurityOrigin origin) => origin.port <= 0
      ? origin.protocol == 'https'
            ? 443
            : 80
      : origin.port;

  bool _popupContextIsCurrent(int generation, Uri documentUrl) =>
      mounted &&
      _ready &&
      generation == _generation &&
      documentUrl == _documentUrl;

  void _deliverPopup(Uri uri, int generation, Uri documentUrl) {
    if (!_popupContextIsCurrent(generation, documentUrl)) return;
    if (!isBrowserUrl(uri)) {
      widget.onError('Only HTTPS websites can be opened in a new tab.');
      return;
    }
    widget.onPopup(uri);
  }

  Future<void> _adoptPopupWindow(
    int windowId, {
    required int generation,
    required Uri documentUrl,
    required bool captureDestination,
  }) async {
    late final _PopupWindowCapture capture;
    capture = _PopupWindowCapture(
      windowId: windowId,
      captureDestination: captureDestination,
      onDestination: (uri) => _deliverPopup(uri, generation, documentUrl),
      onDone: () => _popupCaptures.remove(capture),
    );
    _popupCaptures.add(capture);
    await capture.run();
  }

  Future<bool> _handlePopup(
    InAppWebViewController controller,
    CreateWindowAction action,
  ) async {
    _popupCallbacksInFlight++;
    try {
      final generation = _generation;
      final documentUrl = _documentUrl;
      final accepted =
          documentUrl != null &&
          await _popupSourceIsCurrent(
            controller,
            action,
            generation,
            documentUrl,
          );
      final requested = Uri.tryParse(action.request.url?.toString() ?? '');
      final knownDestination =
          requested != null &&
          requested.hasScheme &&
          requested.scheme != 'about';
      if (accepted && knownDestination) {
        _deliverPopup(requested, generation, documentUrl);
      }

      // Android cancels and releases the native transport when false is
      // returned. WebKit instead loads the request in the current WebView, so
      // an iOS popup must always be adopted and explicitly discarded.
      final needsTransport = Platform.isIOS || (accepted && !knownDestination);
      if (!needsTransport) return false;
      try {
        await _adoptPopupWindow(
          action.windowId,
          generation: generation,
          documentUrl: documentUrl ?? Uri(),
          captureDestination: accepted && !knownDestination,
        );
        return true;
      } catch (_) {
        if (mounted) widget.onError('The new tab could not be opened.');
        return Platform.isIOS;
      }
    } finally {
      _popupCallbacksInFlight--;
    }
  }

  @override
  void dispose() {
    _faviconRescan?.cancel();
    _probeRescan?.cancel();
    _probeTicker?.cancel();
    _colorConfirm?.cancel();
    for (final capture in _popupCaptures.toList()) {
      unawaited(capture.dispose());
    }
    _popupCaptures.clear();
    // A challenge still waiting answers cancel; the sheet goes with the page.
    _disposed.complete();
    _jsDialogs.dispose();
    final route = _httpAuthRoute;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
    super.dispose();
  }

  Future<void> _documentCommitted(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    final generation = _generation;
    if (_ready || _failedGeneration == generation) return;
    final actual = await controller.getUrl();
    final uri = Uri.tryParse(actual?.toString() ?? '');
    final committed = Uri.tryParse(url?.toString() ?? '');
    if (!mounted ||
        generation != _generation ||
        _ready ||
        _failedGeneration == generation ||
        uri != committed)
      return;
    if (uri == null || !isBrowserUrl(uri)) return;
    await widget.beforeNavigation?.call(uri);
    if (!mounted ||
        generation != _generation ||
        _failedGeneration == generation ||
        _ready)
      return;
    _documentUrl = uri;
    _ready = true;
    _committedOnce = true;
    widget.onNavigation(_generation, uri);
    final documentToken = _documentToken;
    // A first-party page learns the current theme before its ready event, in
    // case it changed since the grant script was baked.
    final dark = _dark;
    final theme = dark != null && isFirstPartyOrigin(uri, Config.environment)
        ? '${browserUiThemeScript(dark: dark)} '
        : '';
    await controller.evaluateJavascript(
      source:
          'window.__mallowDocumentToken = ${jsonEncode(documentToken)}; ${theme}window.dispatchEvent(new Event("mallow:document-ready"));',
    );
    await _publishTitle(controller, generation);
    await _probePage(controller);
  }

  /// Title changes reported before the document was ready are dropped, so
  /// the title is read again once it is.
  Future<void> _publishTitle(
    InAppWebViewController controller,
    int generation,
  ) async {
    if (!mounted || !_ready || generation != _generation) return;
    try {
      final title = await controller.getTitle();
      if (mounted && _ready && generation == _generation && title != null) {
        widget.onTitle(title);
      }
    } catch (_) {
      // The document URL remains authoritative if title retrieval fails.
    }
  }

  /// Reads the icon links in-page rather than through the plugin's
  /// `getFavicons()`, which also fetches `/favicon.ico`, the manifest and
  /// sometimes the page itself with its own native HTTP client, outside the
  /// WebView's cookie and privacy settings.
  Future<void> _captureFavicon(InAppWebViewController controller) async {
    final onFavicon = widget.onFavicon;
    final generation = _generation;
    final document = _documentUrl;
    if (onFavicon == null || !_ready || document == null) return;
    try {
      final links = await controller.evaluateJavascript(source: _faviconScript);
      if (!mounted ||
          !_ready ||
          generation != _generation ||
          document != _documentUrl) {
        return;
      }
      final manifest = browserManifestUrl(document, links);
      final manifestIcons = manifest == null
          ? null
          : await _manifestIcons(controller, manifest, generation);
      if (!mounted ||
          !_ready ||
          generation != _generation ||
          document != _documentUrl) {
        return;
      }
      final icon = pickBrowserFavicon(
        document,
        links,
        manifestIcons: manifestIcons,
      );
      if (icon == null || icon == _reportedIcon) return;
      _reportedIcon = icon;
      final drawn = await _drawIcon(controller, icon, generation);
      if (!mounted ||
          !_ready ||
          generation != _generation ||
          document != _documentUrl) {
        return;
      }
      if (drawn != null) BrowserSiteIcons.instance.put(icon, drawn);
      onFavicon(icon);
    } catch (_) {
      // Icons are cosmetic: the site tile falls back to a monogram.
    }
  }

  Future<void> _probePage(InAppWebViewController controller) async {
    final generation = _generation;
    final document = _documentUrl;
    if (!mounted || !_ready || document == null || _probing) return;
    final band = widget.onBottomOverlay == null ? 0.0 : widget.bottomBand;
    _probing = true;
    try {
      final raw = await controller.evaluateJavascript(
        source: _pageProbeScript(
          band: band,
          width: MediaQuery.sizeOf(context).width,
          keepSpacer: _bottomOverlay.overlay,
        ),
      );
      if (!mounted ||
          !_ready ||
          generation != _generation ||
          document != _documentUrl) {
        return;
      }
      _offerColor(controller, generation, pickBrowserPageColor(raw));
      final safe = browserProbeOverlay(raw);
      if (band > 0 && safe != null && _bottomOverlay.report(safe)) {
        widget.onBottomOverlay?.call(_bottomOverlay.overlay);
        // The WebView resizes now. Probe again once it has, which adds or
        // removes the spacer to match.
        _scheduleProbe(controller, const Duration(milliseconds: 300));
      }
    } catch (_) {
      // Cosmetic: the browser keeps its colour and the page stays above the
      // bar, as it was.
    } finally {
      _probing = false;
    }
  }

  void _offerColor(
    InAppWebViewController controller,
    int generation,
    Color? color,
  ) {
    final now = DateTime.now();
    if (generation != _seenGeneration || color != _seenColor) {
      _seenGeneration = generation;
      _seenColor = color;
      _seenSince = now;
      // Look again once it could have settled, in case nothing else probes.
      _colorConfirm?.cancel();
      _colorConfirm = Timer(
        _colorSettle + const Duration(milliseconds: 50),
        () {
          if (mounted && generation == _generation) {
            unawaited(_probePage(controller));
          }
        },
      );
      return;
    }
    if (now.difference(_seenSince!) < _colorSettle) return;
    if (generation == _colorGeneration && color == _reportedColor) return;
    _colorGeneration = generation;
    _reportedColor = color;
    widget.onPageColor?.call(color);
  }

  void _scheduleProbe(InAppWebViewController controller, Duration delay) {
    if (!_ready) return;
    _probeRescan?.cancel();
    final generation = _generation;
    _probeRescan = Timer(delay, () {
      if (mounted && generation == _generation) {
        unawaited(_probePage(controller));
      }
    });
  }

  /// The icon as the page itself draws it, or null if it could not be drawn
  /// or read back.
  Future<Uint8List?> _drawIcon(
    InAppWebViewController controller,
    Uri icon,
    int generation,
  ) async {
    final key = '__mallowIcon${const Uuid().v4().replaceAll('-', '')}';
    await controller.evaluateJavascript(source: _iconCaptureScript(key, icon));
    final value = await _pageResult(controller, key, generation);
    return value == null ? null : decodeBrowserIconCapture(value);
  }

  /// The icons [manifest] lists, as the `_manifestIconsScript` result, or
  /// null. The last manifest's answer is kept, so the rescan and the site's
  /// other pages do not fetch it again.
  Future<Object?> _manifestIcons(
    InAppWebViewController controller,
    Uri manifest,
    int generation,
  ) async {
    final cached = _manifest;
    if (cached != null && cached.url == manifest) return cached.icons;
    final key = '__mallowManifest${const Uuid().v4().replaceAll('-', '')}';
    await controller.evaluateJavascript(
      source: _manifestIconsScript(key, manifest),
    );
    final icons = await _pageResult(controller, key, generation);
    if (icons != null && generation == _generation) {
      _manifest = (url: manifest, icons: icons);
    }
    return icons;
  }

  /// Polls for the string a script left under [key] on `window`: JavaScript
  /// promises cannot cross the bridge here (it is off on Android). Null if
  /// none arrives in time or the document changes.
  Future<Object?> _pageResult(
    InAppWebViewController controller,
    String key,
    int generation,
  ) async {
    for (var attempt = 0; attempt < 25; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!mounted || generation != _generation) return null;
      var value = await controller.evaluateJavascript(
        source: _pageResultScript(key),
      );
      // Android can hand back the JSON text of the value.
      if (value is String && (value == 'null' || value.startsWith('"'))) {
        value = jsonDecode(value);
      }
      if (value != null) return value;
    }
    return null;
  }

  /// Single-page apps often add their icon links and set their background
  /// from script after the load finishes, so the page is read once more a
  /// little later.
  void _scheduleFaviconRescan(InAppWebViewController controller) {
    _faviconRescan?.cancel();
    final generation = _generation;
    _faviconRescan = Timer(const Duration(seconds: 2), () {
      if (mounted && generation == _generation) {
        unawaited(_captureFavicon(controller));
        unawaited(_probePage(controller));
      }
    });
  }

  void _markPainted() {
    if (!_painted && mounted) setState(() => _painted = true);
  }

  /// Refuses an untrusted certificate unless the user already accepted one
  /// on this origin, and turns a refused main-frame load into the
  /// warning page. A null response hands a valid certificate (iOS) back to
  /// the platform's own validation.
  Future<ServerTrustAuthResponse?> _serverTrust(
    InAppWebViewController controller,
    ServerTrustChallenge challenge,
  ) async {
    final cancel = ServerTrustAuthResponse(
      action: ServerTrustAuthResponseAction.CANCEL,
    );
    final space = challenge.protectionSpace;
    final Uri origin;
    try {
      origin = Uri(
        scheme: 'https',
        host: space.host,
        port: (space.port ?? 0) > 0 ? space.port : null,
      );
    } on FormatException {
      return cancel;
    }
    final found = browserCertificateFailure(
      challenge,
      url: origin,
      isIOS: Platform.isIOS,
    );
    if (found == null) return null;
    final fingerprint = found.fingerprint;
    await BrowserCertificateExceptions.instance.load();
    // Pinned to the certificate the user accepted: any other one warns again.
    if (found.overridable &&
        fingerprint != null &&
        BrowserCertificateExceptions.instance.allows(
          found.origin,
          fingerprint,
        )) {
      return ServerTrustAuthResponse(
        action: ServerTrustAuthResponseAction.PROCEED,
      );
    }
    // The loading URL when it is on this origin, so a proceed returns to the
    // exact page; otherwise the origin itself.
    Uri? page = _loading;
    if (_browserOrigin(page) != found.origin) {
      try {
        page = Uri.tryParse((await controller.getUrl())?.toString() ?? '');
      } catch (_) {
        page = null;
      }
    }
    final mainFrame = _browserOrigin(page) == found.origin;
    final failure = BrowserCertificateFailure(
      url: mainFrame ? page! : origin,
      fingerprint: fingerprint,
      overridable: found.overridable,
      reason: found.reason,
    );
    _certificateFailures.remove(failure.origin);
    _certificateFailures[failure.origin] = failure;
    while (_certificateFailures.length > 8) {
      _certificateFailures.remove(_certificateFailures.keys.first);
    }
    if (mainFrame && mounted) _showCertificateWarning(failure);
    return cancel;
  }

  /// Reuses securely saved HTTP credentials, prompting for missing or rejected
  /// details. The platform's own persistent credential database is not used.
  Future<HttpAuthResponse?> _httpAuth(
    InAppWebViewController controller,
    HttpAuthenticationChallenge challenge,
  ) async {
    final cancel = HttpAuthResponse(action: HttpAuthResponseAction.CANCEL);
    final space = challenge.protectionSpace;
    // iOS reports the request's own scheme, so a cleartext request is refused
    // before the password could cross the network in the clear. Android
    // reports the page's, which is always HTTPS here.
    final protocol = space.protocol?.toLowerCase();
    if (!_canPrompt ||
        space.host.isEmpty ||
        (protocol != null && protocol != 'https')) {
      return cancel;
    }
    // Android counts the attempt being made; iOS counts only failed ones.
    final failed =
        challenge.previousFailureCount > (Platform.isAndroid ? 1 : 0);
    final key = BrowserHttpAuthService.protectionSpaceKey(space)!;
    // A block body: an arrow would return the removed entry, which is this
    // very future, and whenComplete would then wait on itself forever.
    final credentials = await (_httpAuthPrompts[key] ??= BrowserHttpAuthService
        .instance
        .resolve(
          protectionSpace: space,
          failed: failed,
          proposedUsername: challenge.proposedCredential?.username,
          // A server whose certificate the user overrode has not proved who
          // it is, so saved details wait for the user to send them.
          autofill: !BrowserCertificateExceptions.instance.coversHost(
            space.host,
          ),
          isActive: () => _canPrompt,
          prompt: ({required failed, username}) =>
              _promptHttpAuth(challenge, failed: failed, username: username),
        )
        .whenComplete(() {
          _httpAuthPrompts.remove(key);
        }));
    if (credentials == null || !mounted) return cancel;
    return HttpAuthResponse(
      action: HttpAuthResponseAction.PROCEED,
      username: credentials.username,
      password: credentials.password,
      permanentPersistence: false,
    );
  }

  Future<BrowserHttpCredentials?> _promptHttpAuth(
    HttpAuthenticationChallenge challenge, {
    required bool failed,
    String? username,
  }) async {
    final previous = _httpAuthQueue;
    final done = Completer<void>();
    _httpAuthQueue = done.future;
    try {
      await previous;
      if (!mounted) return null;
      final space = challenge.protectionSpace;
      final host = space.host.toLowerCase();
      // Android reports the page's port rather than the request's.
      final port = space.port ?? 0;
      final shownHost = Platform.isIOS && port > 0 && port != 443
          ? '$host:$port'
          : host;
      // The page loading, or else the one showing. A server on another site
      // is named as such, so a page cannot pass its prompt off as its own.
      final pageHost = (_loading ?? _documentUrl)?.host.toLowerCase();
      final site = browserRegistrableDomain(host);
      final foreign =
          pageHost != null &&
          pageHost.isNotEmpty &&
          site != browserRegistrableDomain(pageHost) &&
          site != browserRegistrableDomain(_documentUrl?.host ?? '');
      final navigator = Navigator.of(context, rootNavigator: true);
      final route = _httpAuthRoute = mallowSheetRoute<BrowserHttpCredentials>(
        context: context,
        isScrollControlled: true,
        builder: (_) => BrowserHttpAuthSheet(
          host: shownHost,
          pageHost: foreign ? pageHost : null,
          failed: failed,
          username: username,
        ),
      );
      try {
        return await Future.any<BrowserHttpCredentials?>([
          navigator.push(route),
          _disposed.future.then((_) => null),
        ]);
      } finally {
        if (identical(_httpAuthRoute, route)) _httpAuthRoute = null;
      }
    } finally {
      done.complete();
    }
  }

  /// [Uri.origin] throws for a URL without one, such as about:blank.
  static String? _browserOrigin(Uri? uri) =>
      uri != null && isBrowserUrl(uri) ? uri.origin : null;

  void _showCertificateWarning(BrowserCertificateFailure failure) {
    _ready = false;
    _failedGeneration = _generation;
    if (mounted) setState(() => _certificateWarning = failure);
  }

  void _leaveCertificateWarning() {
    setState(() => _certificateWarning = null);
    // A failed navigation never commits, so the previous page is still here.
    if (!_committedOnce) widget.onCertificateDeclined?.call();
  }

  void _proceedPastCertificate(InAppWebViewController? controller) {
    final failure = _certificateWarning;
    final fingerprint = failure?.fingerprint;
    if (failure == null ||
        controller == null ||
        !failure.overridable ||
        fingerprint == null) {
      return;
    }
    unawaited(
      BrowserCertificateExceptions.instance.allow(failure.origin, fingerprint),
    );
    _certificateFailures.remove(failure.origin);
    setState(() => _certificateWarning = null);
    unawaited(
      controller.loadUrl(urlRequest: URLRequest(url: WebUri('${failure.url}'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final warning = _certificateWarning;
    return Stack(
      fit: StackFit.expand,
      children: [
        _webView(context),
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _painted ? 0 : 1,
            duration: context.reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 180),
            child: ColoredBox(color: context.mallowColors.bgPrimary),
          ),
        ),
        if (warning != null)
          BrowserCertificateWarning(
            failure: warning,
            onBack: _leaveCertificateWarning,
            onProceed: () => _proceedPastCertificate(_controller),
          ),
      ],
    );
  }

  Widget _webView(BuildContext context) => InAppWebView(
    initialSettings: InAppWebViewSettings(
      useShouldOverrideUrlLoading: true,
      javaScriptCanOpenWindowsAutomatically: false,
      supportMultipleWindows: true,
      allowFileAccess: false,
      allowContentAccess: false,
      allowFileAccessFromFileURLs: false,
      allowUniversalAccessFromFileURLs: false,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
      sharedCookiesEnabled: false,
      thirdPartyCookiesEnabled: false,
      isInspectable: false,
      safeBrowsingEnabled: true,
      mediaPlaybackRequiresUserGesture: true,
      allowsInlineMediaPlayback: true,
      isElementFullscreenEnabled: false,
      javaScriptBridgeEnabled: !Platform.isAndroid,
      javaScriptHandlersForMainFrameOnly: true,
      javaScriptBridgeForMainFrameOnly: true,
      pluginScriptsForMainFrameOnly: true,
      javaScriptHandlersOriginAllowList: {'https://.*'},
      javaScriptBridgeOriginAllowList: {'https://.*'},
      disableDefaultErrorPage: true,
      useOnDownloadStart: true,
    ),
    initialUserScripts: UnmodifiableListView([
      // First, so the provider below finds its grant. It grants only the
      // web app's own documents.
      UserScript(
        groupName: browserUiGrantGroup,
        source: browserUiGrantScript(
          environment: Config.environment,
          dark: _grantDark ??= _dark ?? true,
        ),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
        allowedOriginRules: browserUiOriginRules(
          Config.environment,
          android: Platform.isAndroid,
        ),
      ),
      UserScript(
        source:
            '''
if (window.opener == null) {
  window.__mallowSupportedChains = ${jsonEncode(Config.isProduction ? ['solana:mainnet'] : ['solana:mainnet', 'solana:devnet'])};
  $mallowDappProviderScript
}
$_popupGestureScript
''',
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      ),
    ]),
    onWebViewCreated: (controller) async {
      _controller = controller;
      if (Platform.isAndroid) {
        await InAppWebViewController.setWebContentsDebuggingEnabled(false);
        if (await WebViewFeature.isFeatureSupported(
          WebViewFeature.WEB_MESSAGE_LISTENER,
        )) {
          await controller.addWebMessageListener(
            WebMessageListener(
              jsObjectName: 'mallowNative',
              allowedOriginRules: browserWalletOriginRules,
              onPostMessage: (message, sourceOrigin, isMainFrame, reply) async {
                try {
                  final raw = message?.data;
                  if (raw is! String ||
                      raw.length > 400000 ||
                      sourceOrigin == null)
                    return;
                  final envelope = jsonDecode(raw);
                  final result = await _request(
                    envelope,
                    Uri.parse(sourceOrigin.toString()),
                    isMainFrame,
                  );
                  if (mounted)
                    await reply.postMessage(
                      WebMessage(
                        data: jsonEncode({
                          'id': envelope is Map ? envelope['id'] : null,
                          ...result,
                        }),
                      ),
                    );
                } catch (_) {
                  /* Invalid web messages never enter the signing path. */
                }
              },
            ),
          );
        } else {
          widget.onError(
            'Update Android System WebView to connect a wallet. Browsing is still available.',
          );
        }
      } else if (Platform.isIOS) {
        controller.addJavaScriptHandler(
          handlerName: 'mallowWallet',
          callback: (JavaScriptHandlerFunctionData data) async {
            if (data.args.length != 1 ||
                !browserBridgeRequestUrlCurrent(
                  data.args.single,
                  Uri.tryParse(data.requestUrl.toString()),
                  _documentUrl,
                ))
              return <String, Object?>{
                'error': {'code': 4100, 'message': 'Stale document'},
              };
            return _request(
              data.args.single,
              Uri.parse(data.origin.toString()),
              data.isMainFrame,
            );
          },
        );
      }
      // The theme may have changed since the grant above was baked.
      await _syncUiStartTheme();
      await BrowserCertificateExceptions.instance.syncPlatform(controller);
      if (!mounted) return;
      await widget.beforeNavigation?.call(widget.url);
      if (!mounted) return;
      _loading = widget.url;
      // Handed out only now: a navigation the owner starts during the setup
      // above would load without the wallet bridge, and the initial load
      // below would then replace it. The load call goes out synchronously,
      // so anything the owner issues next is queued behind it.
      widget.onController(controller);
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(widget.url.toString())),
      );
    },
    shouldOverrideUrlLoading: (controller, action) async {
      final raw = action.request.url?.toString() ?? '';
      // A site's "connect with WalletConnect" link pairs with this wallet
      // rather than leave the app. Only the page itself may start one, and
      // on Android only from a tap, as for a popup: a hidden frame must not
      // raise connection sheets. The link holds a key, so it goes nowhere
      // else either way.
      if (isWalletConnectText(raw)) {
        if (_fromPage(action)) handleWalletConnectText(raw);
        return NavigationActionPolicy.CANCEL;
      }
      final uri = Uri.tryParse(raw);
      // A site's "open in the app" button goes where the same link would go
      // had it opened the app. The same rule as for WalletConnect decides who
      // may follow one. The link can carry private parameters, so it is never
      // put in the error either.
      final appLink = uri == null ? null : browserAppLink(uri);
      if (appLink != null) {
        if (_fromPage(action) && !(widget.onAppLink?.call(appLink) ?? false)) {
          widget.onError('mallow cannot open this link.');
        }
        return NavigationActionPolicy.CANCEL;
      }
      if (uri == null || !isBrowserUrl(uri)) {
        if (action.isForMainFrame)
          widget.onError(
            'Only HTTPS websites are supported. Downloads and external app links are unavailable.',
          );
        return NavigationActionPolicy.CANCEL;
      }
      if (action.isForMainFrame) {
        final revision = ++_navigationPreparationRevision;
        await widget.beforeNavigation?.call(uri);
        if (!mounted || revision != _navigationPreparationRevision) {
          return NavigationActionPolicy.CANCEL;
        }
        _loading = uri;
      }
      return NavigationActionPolicy.ALLOW;
    },
    onLoadStart: (controller, url) {
      _ready = false;
      _failedGeneration = null;
      _generation++;
      _reportedIcon = null;
      _faviconRescan?.cancel();
      _probeRescan?.cancel();
      _bottomOverlay.newDocument();
      _documentToken = const Uuid().v4();
      _documentUrl = Uri.tryParse(url?.toString() ?? '');
      if (_browserOrigin(_documentUrl) != null) _loading = _documentUrl;
      if (_certificateWarning != null &&
          _certificateWarning!.origin != _browserOrigin(_documentUrl)) {
        setState(() => _certificateWarning = null);
      }
      widget.onNavigationStarted(_generation);
    },
    onPageCommitVisible: (controller, url) {
      _markPainted();
      unawaited(_documentCommitted(controller, url));
    },
    onLoadStop: (controller, url) async {
      _markPainted();
      // A finished load has committed. The commit callback alone is not
      // enough: Android can skip onPageCommitVisible, and its URL check can
      // still be in flight here, which left the page without its title and
      // icon.
      final generation = _generation;
      await _documentCommitted(controller, url);
      await _publishTitle(controller, generation);
      await _captureFavicon(controller);
      await _probePage(controller);
      if (mounted && _ready && generation == _generation) {
        _scheduleFaviconRescan(controller);
        widget.onLoadStop?.call();
      }
    },
    onScrollChanged: (controller, _, y) {
      widget.onScrollChanged?.call(y);
      // A page reads differently once it stops moving: what sits under the
      // bar, and a background that changed in place (a theme toggle).
      _scheduleProbe(controller, const Duration(milliseconds: 400));
    },
    onUpdateVisitedHistory: (controller, url, _) {
      final uri = Uri.tryParse(url?.toString() ?? '');
      if (_ready &&
          uri != null &&
          isBrowserUrl(uri) &&
          uri.origin == _documentUrl?.origin) {
        _documentUrl = uri;
        widget.onNavigation(_generation, uri);
        unawaited(_probePage(controller));
      }
    },
    onProgressChanged: (_, progress) => widget.onProgress(progress),
    onTitleChanged: (_, title) {
      if (_ready) widget.onTitle(title ?? '');
    },
    onReceivedError: (_, request, error) {
      if (request.isForMainFrame == true) {
        _ready = false;
        _failedGeneration = _generation;
        final failure =
            _certificateFailures[_browserOrigin(
              Uri.tryParse(request.url.toString()),
            )];
        if (failure != null) {
          if (_certificateWarning?.origin != failure.origin) {
            _showCertificateWarning(failure);
          }
          return;
        }
        widget.onError(
          'This page could not be loaded. Check your connection and try again.',
        );
      }
    },
    onReceivedServerTrustAuthRequest: _serverTrust,
    onReceivedHttpAuthRequest: _httpAuth,
    // Handling the Android callback at all also keeps the renderer's exit
    // from taking the app down with it.
    onRenderProcessGone: (_, _) => widget.onProcessGone?.call(),
    onWebContentProcessDidTerminate: (_) => widget.onProcessGone?.call(),
    onPermissionRequest: (_, request) async {
      widget.onError(
        'Camera, microphone, and device permissions are unavailable in this browser.',
      );
      return PermissionResponse(
        resources: request.resources,
        action: PermissionResponseAction.DENY,
      );
    },
    onGeolocationPermissionsShowPrompt: (_, origin) async =>
        GeolocationPermissionShowPromptResponse(
          origin: origin,
          allow: false,
          retain: false,
        ),
    // Android supports this callback. WKWebView file-input panels still require
    // iOS device verification; no native upload capability is advertised.
    onShowFileChooser: (_, _) async {
      widget.onError('File uploads are unavailable in this browser.');
      return ShowFileChooserResponse(handledByClient: true, filePaths: []);
    },
    onDownloadStartRequest: (_, _) =>
        widget.onError('Downloads are unavailable in this browser.'),
    onCreateWindow: _handlePopup,
    onJsAlert: (_, request) => _jsDialogs.alert(request),
    onJsConfirm: (_, request) => _jsDialogs.confirm(request),
    onJsPrompt: (_, request) => _jsDialogs.prompt(request),
    onJsBeforeUnload: (_, request) => _jsDialogs.beforeUnload(request),
    onEnterFullscreen: (controller) async {
      await controller.evaluateJavascript(
        source:
            'if(document.fullscreenElement) document.exitFullscreen(); '
            'if(document.webkitFullscreenElement && document.webkitExitFullscreen) document.webkitExitFullscreen(); '
            'document.querySelectorAll("video").forEach(function(video) { if(video.webkitDisplayingFullscreen && video.webkitExitFullscreen) video.webkitExitFullscreen(); });',
      );
    },
    onConsoleMessage: (_, _) {},
  );
}

class _PopupWindowCapture {
  _PopupWindowCapture({
    required this.windowId,
    required this.captureDestination,
    required this.onDestination,
    required this.onDone,
  });

  static const _lifetime = Duration(seconds: 5);
  final int windowId;
  final bool captureDestination;
  final ValueChanged<Uri> onDestination;
  final VoidCallback onDone;
  late final HeadlessInAppWebView _webView;
  Timer? _timer;
  bool _runCompleted = false;
  bool _disposeRequested = false;
  Future<void>? _disposal;

  Future<void> run() async {
    _webView = HeadlessInAppWebView(
      windowId: windowId,
      initialSettings: InAppWebViewSettings(
        useShouldOverrideUrlLoading: true,
        javaScriptEnabled: false,
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false,
        allowFileAccess: false,
        allowContentAccess: false,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
        sharedCookiesEnabled: false,
        thirdPartyCookiesEnabled: false,
        javaScriptBridgeEnabled: false,
        mediaPlaybackRequiresUserGesture: true,
      ),
      onWebViewCreated: (controller) {
        if (!captureDestination) _disposeRequested = true;
      },
      shouldOverrideUrlLoading: (_, action) async {
        if (action.isForMainFrame) _consider(action.request.url);
        return NavigationActionPolicy.CANCEL;
      },
      // This callback is only emitted for a WebView's main document. Android
      // does not consistently run shouldOverrideUrlLoading for the first URL
      // handed to an adopted window transport.
      onLoadStart: (_, url) => _consider(url),
      onReceivedError: (_, _, _) => unawaited(dispose()),
    );
    _timer = Timer(_lifetime, () => unawaited(dispose()));
    final nativeRun = _webView.run();
    unawaited(
      nativeRun.then(
        (_) {
          _runCompleted = true;
          if (!captureDestination || _disposeRequested) {
            unawaited(_disposeNative());
          }
        },
        onError: (Object _, StackTrace _) {
          _runCompleted = true;
          unawaited(_disposeNative());
        },
      ),
    );
    try {
      await nativeRun.timeout(_lifetime);
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  void _consider(WebUri? raw) {
    if (_disposeRequested || !captureDestination) return;
    final uri = Uri.tryParse(raw?.toString() ?? '');
    if (uri == null || uri.scheme == 'about') return;
    onDestination(uri);
    unawaited(dispose());
  }

  Future<void> dispose() async {
    _disposeRequested = true;
    _timer?.cancel();
    if (_runCompleted) await _disposeNative();
  }

  Future<void> _disposeNative() => _disposal ??= _performDispose();

  Future<void> _performDispose() async {
    try {
      try {
        await _webView.webViewController?.stopLoading();
      } catch (_) {
        // Native disposal below remains mandatory even if cancellation fails.
      }
      try {
        await _webView.dispose();
      } catch (_) {
        // The capture is already unusable and must not surface async errors.
      }
    } finally {
      onDone();
    }
  }
}
