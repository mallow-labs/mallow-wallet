import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/security/security_utils.dart';
import '../../../core/utils/asset_url.dart';
import '../../browser/services/browser_visibility.dart'
    show browserPageRouteObserver;

/// Ordered https URLs to try for an HTML artwork, most-preferred first.
///
/// The gateway ladder is [AssetUrl.assetSourceCandidates] — the natural
/// gateway, then the Arweave mirror and the alternate IPFS gateways — and never
/// the image service's `/original/` route, which does not serve HTML inline.
/// Only https survives: the page is a top-level document in a web view that
/// never allows mixed content, and a `data:` or `javascript:` source has no
/// gateway to fall back to.
///
/// A Solana artwork's mint is appended as `mintKey`, as the webapp does, so a
/// generative piece can render the token it belongs to.
List<String> artworkHtmlSourceCandidates(
  String htmlUrl, {
  required String mintAccount,
  String? chain,
}) {
  final withMint = SecurityUtils.isValidSolanaAddress(mintAccount);
  return [
    for (final candidate in AssetUrl.assetSourceCandidates(
      htmlUrl,
      chain: chain,
    ))
      if (Uri.tryParse(candidate)?.scheme.toLowerCase() == 'https')
        withMint ? _withMintKey(candidate, mintAccount) : candidate,
  ];
}

/// [url] with `mintKey=<mint>` appended to its query, ahead of any fragment.
/// Appended as text rather than through [Uri.replace], which would re-encode
/// the existing query (`?ext=html` and friends) that gateways match on.
String _withMintKey(String url, String mint) {
  final hash = url.indexOf('#');
  final base = hash < 0 ? url : url.substring(0, hash);
  final fragment = hash < 0 ? '' : url.substring(hash);
  final sep = base.contains('?') ? '&' : '?';
  return '$base${sep}mintKey=$mint$fragment';
}

/// How long one gateway gets to paint before the next one is tried. A gateway
/// that hangs (an IPFS cold fetch, a 504 that takes a minute to arrive)
/// otherwise holds the viewer on its placeholder indefinitely.
const Duration _paintTimeout = Duration(seconds: 25);

/// An HTML artwork in a locked-down web view: the native counterpart of the
/// webapp's sandboxed iframe (`allow-scripts allow-pointer-lock`, so no
/// popups, no modal dialogs, no top navigation, no referrer).
///
/// The page runs its own scripts and nothing else. No JavaScript bridge is
/// injected, so the artwork cannot call into the app. It cannot open windows,
/// leave https, reach the camera, microphone or location, or download files.
/// On iOS it also gets a non-persistent data store, so it cannot keep state
/// between views. Android's equivalent clears every web view's cookies
/// app-wide, including the in-app browser's sessions, so it stays off there.
///
/// `alert`, `confirm`, `prompt` and `beforeunload` never show a dialog: each
/// is answered as dismissed, as the sandboxed iframe does without
/// `allow-modals`. A native dialog would name no origin, so an artwork could
/// pass a `prompt` off as the wallet asking for its recovery phrase, and an
/// `alert` loop would hold the screen.
///
/// Once the first page commits, the main frame stays on that page's origin.
/// Gateway redirects before it (a path gateway moving to its subdomain form)
/// still load. The iframe can only navigate itself, where it stays a
/// third-party frame; a main-frame navigation here would instead be a
/// first-party visit, and on Android the cookie store is shared with the
/// in-app browser, so a page could send signed-in requests to any site.
///
/// [sources] are tried in order. A main-frame load or HTTP error, or no paint
/// within [_paintTimeout], moves to the next one; when none paints,
/// [onFailed] fires and the caller shows its still poster instead.
///
/// [placeholder] covers the view until the page paints. It also stands in
/// whenever the view is torn down: while a page route covers this one, and
/// while the app is in the background. Either would otherwise leave the
/// artwork's audio and animation running where nobody can see them. The page
/// reloads when the view returns.
class ArtworkHtmlViewer extends StatefulWidget {
  const ArtworkHtmlViewer({
    required this.sources,
    required this.placeholder,
    super.key,
    this.interactive = false,
    this.onSourcePainted,
    this.onFailed,
  });

  final List<String> sources;
  final Widget placeholder;

  /// True claims every gesture for the page (the fullscreen viewer). False
  /// leaves drags to the enclosing scroll view, so an inline artwork does not
  /// trap the page's scroll. Taps still reach it.
  final bool interactive;

  /// The source that painted. A later viewer of the same artwork can start
  /// from it rather than retrying the gateways that already failed.
  final ValueChanged<String>? onSourcePainted;
  final VoidCallback? onFailed;

  @override
  State<ArtworkHtmlViewer> createState() => _ArtworkHtmlViewerState();
}

class _ArtworkHtmlViewerState extends State<ArtworkHtmlViewer>
    with WidgetsBindingObserver, RouteAware {
  int _index = 0;

  /// Bumped every time a web view is (re)created, whether for the next source
  /// or after a suspension. Keys the view, so a resume builds a fresh one, and
  /// lets callbacks from a discarded view recognise themselves as stale.
  int _attempt = 0;
  bool _painted = false;
  bool _failed = false;
  bool _routeCovered = false;
  bool _backgrounded = false;
  Timer? _timeout;
  PageRoute<dynamic>? _route;

  /// The origin of the first page this attempt committed, which main-frame
  /// navigation may no longer leave. Null until then.
  ({int attempt, String origin})? _committed;

  bool get _suspended => _routeCovered || _backgrounded;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.sources.isEmpty) _fail();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      if (_route != null) browserPageRouteObserver.unsubscribe(this);
      _route = route;
      browserPageRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didUpdateWidget(covariant ArtworkHtmlViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.sources, widget.sources)) {
      _timeout?.cancel();
      _index = 0;
      _attempt++;
      _painted = false;
      _failed = false;
      if (widget.sources.isEmpty) _fail();
    }
  }

  @override
  void dispose() {
    _timeout?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    browserPageRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPushNext() => _setRouteCovered(true);

  @override
  void didPopNext() => _setRouteCovered(false);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final backgrounded =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    // `inactive` (a system sheet, the app switcher) keeps the page: only
    // leaving the foreground tears it down.
    if (state == AppLifecycleState.inactive) return;
    _setSuspended(() => _backgrounded = backgrounded);
  }

  void _setRouteCovered(bool covered) =>
      _setSuspended(() => _routeCovered = covered);

  void _setSuspended(VoidCallback change) {
    if (!mounted) return;
    final wasSuspended = _suspended;
    change();
    if (wasSuspended == _suspended) return;
    _timeout?.cancel();
    setState(() {
      // Either way the next view is a fresh page that has not painted yet.
      _attempt++;
      _painted = false;
    });
  }

  void _startTimeout(int attempt) {
    _timeout?.cancel();
    _timeout = Timer(_paintTimeout, () => _sourceFailed(attempt));
  }

  void _markPainted(int attempt) {
    if (!mounted || attempt != _attempt || _painted) return;
    _timeout?.cancel();
    setState(() => _painted = true);
    widget.onSourcePainted?.call(widget.sources[_index]);
  }

  /// The current source failed before painting. Errors after the first paint
  /// belong to the artwork's own navigation, not to the gateway, and are left
  /// alone.
  void _sourceFailed(int attempt) {
    if (!mounted || attempt != _attempt || _painted || _failed) return;
    _timeout?.cancel();
    if (_index + 1 >= widget.sources.length) {
      _fail();
      return;
    }
    setState(() {
      _index++;
      _attempt++;
    });
  }

  void _fail() {
    _failed = true;
    // Deferred: this can run from initState / didUpdateWidget, where a parent
    // may not rebuild synchronously.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onFailed?.call();
    });
  }

  static bool _isCancellation(WebResourceErrorType type) =>
      type == WebResourceErrorType.CANCELLED ||
      type == WebResourceErrorType.FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE;

  /// Records the origin of the first page [attempt] commits.
  void _markCommitted(int attempt, WebUri? url) {
    if (attempt != _attempt || _committed?.attempt == attempt) return;
    final uri = Uri.tryParse(url?.toString() ?? '');
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      return;
    }
    _committed = (attempt: attempt, origin: uri.origin);
  }

  NavigationActionPolicy _navigationPolicy(
    int attempt,
    NavigationAction action,
  ) {
    final committed = _committed;
    return artworkNavigationPolicy(
      action,
      committedOrigin: committed?.attempt == attempt ? committed!.origin : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_failed || _suspended) return widget.placeholder;
    final attempt = _attempt;
    final source = widget.sources[_index];
    return Stack(
      fit: StackFit.expand,
      children: [
        InAppWebView(
          key: ValueKey<int>(attempt),
          initialUrlRequest: URLRequest(url: WebUri(source)),
          gestureRecognizers: widget.interactive
              ? const <Factory<OneSequenceGestureRecognizer>>{
                  Factory<OneSequenceGestureRecognizer>(
                    EagerGestureRecognizer.new,
                  ),
                }
              : null,
          // Defaults that are part of the sandbox are spelled out, so a plugin
          // upgrade that changes one cannot quietly loosen it.
          initialSettings: InAppWebViewSettings(
            useShouldOverrideUrlLoading: true,
            javaScriptBridgeEnabled: false,
            javaScriptCanOpenWindowsAutomatically: false,
            supportMultipleWindows: false,
            allowFileAccess: false,
            allowContentAccess: false,
            allowFileAccessFromFileURLs: false,
            allowUniversalAccessFromFileURLs: false,
            mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
            incognito: Platform.isIOS,
            sharedCookiesEnabled: false,
            thirdPartyCookiesEnabled: false,
            geolocationEnabled: false,
            mediaPlaybackRequiresUserGesture: true,
            allowsInlineMediaPlayback: true,
            isElementFullscreenEnabled: false,
            allowsLinkPreview: false,
            allowsBackForwardNavigationGestures: false,
            disableContextMenu: true,
            disableLongPressContextMenuOnLinks: true,
            disableDefaultErrorPage: true,
            supportZoom: false,
            transparentBackground: true,
            verticalScrollBarEnabled: false,
            horizontalScrollBarEnabled: false,
            isInspectable: kDebugMode,
          ),
          onWebViewCreated: (_) => _startTimeout(attempt),
          shouldOverrideUrlLoading: (_, action) async =>
              _navigationPolicy(attempt, action),
          onPageCommitVisible: (_, url) {
            _markCommitted(attempt, url);
            _markPainted(attempt);
          },
          onLoadStop: (_, url) {
            _markCommitted(attempt, url);
            _markPainted(attempt);
          },
          onReceivedError: (_, request, error) {
            if (request.isForMainFrame != true) return;
            if (_isCancellation(error.type)) return;
            _sourceFailed(attempt);
          },
          onReceivedHttpError: (_, request, response) {
            if (request.isForMainFrame != true) return;
            if ((response.statusCode ?? 0) < 400) return;
            _sourceFailed(attempt);
          },
          onCreateWindow: (_, _) async => false,
          onPermissionRequest: (_, request) async => PermissionResponse(
            resources: request.resources,
            action: PermissionResponseAction.DENY,
          ),
          onGeolocationPermissionsShowPrompt: (_, origin) async =>
              GeolocationPermissionShowPromptResponse(
                origin: origin,
                allow: false,
              ),
          onShowFileChooser: (_, _) async => ShowFileChooserResponse(
            handledByClient: true,
            filePaths: const [],
          ),
          // Answered here, so the platform never builds its own dialog.
          onJsAlert: (_, _) async => artworkJsAlertResponse(),
          onJsConfirm: (_, _) async => artworkJsConfirmResponse(),
          onJsPrompt: (_, _) async => artworkJsPromptResponse(),
          onJsBeforeUnload: (_, _) async => artworkJsBeforeUnloadResponse(),
        ),
        // Covers the view until the page paints. IgnorePointer is not needed:
        // nothing on an unpainted page is worth tapping.
        if (!_painted) widget.placeholder,
      ],
    );
  }
}

/// Main-frame navigation stays on https and, once a page has committed (a
/// non-null [committedOrigin]), on that page's origin. Subframes may also use
/// the document-local schemes an artwork builds its own frames from, and may
/// go to any https origin, as the webapp's iframe can. Everything else is
/// refused, `intent:`, `mailto:` and other apps' deep links included, so a
/// page can never hand the user to another app.
@visibleForTesting
NavigationActionPolicy artworkNavigationPolicy(
  NavigationAction action, {
  String? committedOrigin,
}) {
  final url = action.request.url;
  final scheme = url?.scheme.toLowerCase() ?? '';
  if (!action.isForMainFrame) {
    return const {'https', 'about', 'data', 'blob'}.contains(scheme)
        ? NavigationActionPolicy.ALLOW
        : NavigationActionPolicy.CANCEL;
  }
  if (scheme != 'https') return NavigationActionPolicy.CANCEL;
  if (committedOrigin == null) return NavigationActionPolicy.ALLOW;
  final uri = Uri.tryParse(url.toString());
  // Uri.origin throws for an empty host.
  return uri != null && uri.host.isNotEmpty && uri.origin == committedOrigin
      ? NavigationActionPolicy.ALLOW
      : NavigationActionPolicy.CANCEL;
}

/// `alert()` returns at once, with nothing shown.
@visibleForTesting
JsAlertResponse artworkJsAlertResponse() => JsAlertResponse(
  handledByClient: true,
  action: JsAlertResponseAction.CONFIRM,
);

/// `confirm()` returns false, with nothing shown.
@visibleForTesting
JsConfirmResponse artworkJsConfirmResponse() => JsConfirmResponse(
  handledByClient: true,
  action: JsConfirmResponseAction.CANCEL,
);

/// `prompt()` returns null, with nothing shown, so no text ever goes back.
@visibleForTesting
JsPromptResponse artworkJsPromptResponse() => JsPromptResponse(
  handledByClient: true,
  action: JsPromptResponseAction.CANCEL,
);

/// A `beforeunload` handler cannot hold the page: the unload proceeds, as it
/// does in a sandboxed iframe, with nothing shown. Only Android asks.
@visibleForTesting
JsBeforeUnloadResponse artworkJsBeforeUnloadResponse() =>
    JsBeforeUnloadResponse(
      handledByClient: true,
      action: JsBeforeUnloadResponseAction.CONFIRM,
    );
