import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/utils/canonical_asset_url.dart';
import '../../../core/utils/image_fallback.dart';
import '../../browser/services/browser_visibility.dart'
    show browserPageRouteObserver;

/// Google's `<model-viewer>` web component (Apache-2.0, three.js inside),
/// vendored as its UMD build so the viewer works offline from the app bundle
/// and never pulls a script from a CDN. Draco- and KTX2-compressed models
/// still fetch their decoders from gstatic.com on demand, as the webapp's
/// glTF loader does.
const String _bundleAsset = 'assets/model_viewer/model-viewer-umd.min.js';

/// The JavaScript handler the page reports through.
const String _handlerName = 'mallowModel';

/// How long a load may go without a progress report before the source counts
/// as failed. Reset on every report, so a large model on a slow connection
/// keeps going as long as bytes keep arriving; a gateway that hangs does not
/// hold the viewer on its placeholder forever.
const Duration _stallTimeout = Duration(seconds: 30);

/// The viewer page, with [bundle] (the model-viewer script) inlined.
///
/// Inlined rather than referenced: the page is loaded as data, so it has no
/// origin a relative script could load from, and a `file://` page cannot load
/// scripts on Android once file access is off. The model is set afterwards
/// through `mallowLoad`, which keeps this string the same for every artwork.
///
/// Matches the webapp's viewer: orbit, pinch-zoom and two-finger pan, an
/// auto-rotation at one turn per 30 seconds that never waits for the user to
/// let go, and the model's animation playing on load. `touch-action: none`
/// hands every touch to the camera, as the view's gesture claim (see
/// [ArtworkModelViewer]) hands every touch to the page. Selection and the
/// touch callout are off too: on iOS a press held on the canvas otherwise
/// selects the whole page, as if it were text.
@visibleForTesting
String artworkModelViewerPage(String bundle) =>
    '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}
html,body,model-viewer{-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;-webkit-tap-highlight-color:transparent}
model-viewer{width:100%;height:100%;background:transparent;--poster-color:transparent}
model-viewer::part(default-progress-bar){display:none}
</style>
<script>$bundle</script>
</head>
<body>
<model-viewer id="m" camera-controls autoplay interaction-prompt="none" shadow-intensity="1" auto-rotate-delay="0" rotation-per-second="12deg" touch-action="none"></model-viewer>
<script>
(function(){
  var m = document.getElementById('m');
  function post(message) {
    try { window.flutter_inappwebview.callHandler('$_handlerName', message); } catch (e) {}
  }
  m.addEventListener('progress', function(e) {
    post({type: 'progress', value: e.detail.totalProgress});
  });
  m.addEventListener('load', function() { post({type: 'load'}); });
  m.addEventListener('error', function() { post({type: 'error'}); });
  window.mallowLoad = function(src) { m.src = src; };
  window.mallowConfigure = function(autoRotate) {
    m.toggleAttribute('auto-rotate', autoRotate);
  };
})();
</script>
</body>
</html>
''';

Future<String>? _page;

/// The page once [_page] has completed, so a viewer taking over a loaded
/// model can build it in its first frame.
String? _pageValue;

/// Read once and shared: the bundle is about a megabyte, and every viewer
/// loads the same page.
Future<String> _loadPage() => _page ??= rootBundle
    .loadString(_bundleAsset)
    .then(artworkModelViewerPage)
    .then((page) => _pageValue = page);

/// Warms the shared page. A bundle this large is decoded on a background
/// isolate, which a widget test's fake-async zone never lets finish, so a test
/// loads it here, under `runAsync`, before mounting a viewer.
@visibleForTesting
Future<String> debugLoadArtworkModelViewerPage() => _loadPage();

/// One artwork's loaded model, shared by its inline and fullscreen viewers so
/// that opening and closing fullscreen moves the model's web view across
/// instead of loading the model again. The camera stays where the user left
/// it, too.
///
/// The screen that shows the inline viewer creates the session, passes it to
/// both viewers and disposes it with itself. Only a model that has loaded is
/// shared: a viewer that opens while the other is still loading starts its own
/// load, as it would without a session. One viewer shows the web view at a
/// time; the plugin moves the native view to whichever mounted last.
class ArtworkModelSession {
  ArtworkModelSession({
    @visibleForTesting
    Future<void> Function(InAppWebViewKeepAlive view)? disposeView,
  }) : _disposeView = disposeView ?? InAppWebViewController.disposeKeepAlive;

  final Future<void> Function(InAppWebViewKeepAlive view) _disposeView;

  /// The web view holding the loaded model.
  InAppWebViewKeepAlive? _view;

  /// The viewer showing [_view]. Null while it is parked between two viewers.
  State<ArtworkModelViewer>? _holder;
  bool _disposed = false;

  /// Releases the model's web view, unless a viewer still shows it: that
  /// viewer then releases it when it goes.
  void dispose() {
    _disposed = true;
    final view = _view;
    if (view == null || _holder != null) return;
    _view = null;
    _disposeView(view);
  }

  /// Disposes [view] after the frame, once the platform view built with it
  /// has been unmounted.
  void _disposeAfterFrame(InAppWebViewKeepAlive view) {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _disposeView(view))
      ..ensureVisualUpdate();
  }

  /// [_view] is parked for the viewer about to take it: the fullscreen one
  /// being pushed, or the inline one its route uncovers. That viewer claims it
  /// while building the next frame, so one still unclaimed after it never
  /// will be, and a hidden WebGL scene is not left running.
  void _collectIfUnclaimed() {
    final view = _view;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (view == null || !identical(_view, view) || _holder != null) return;
        _view = null;
        _disposeView(view);
      })
      ..ensureVisualUpdate();
  }
}

/// A 3D artwork (binary glTF) in an interactive viewer: the native
/// counterpart of the webapp's three.js `ModelViewer`.
///
/// The model loads from the image service's `/original/` route. When that
/// fails it earns one retry against the asset's own gateway, and only once
/// [ImageFallback.directUrlFor]'s probe says the service, not a takedown
/// verdict, is what failed. When the retry fails too, or there is none,
/// [onFailed] fires and the caller shows its still poster instead.
///
/// The page is the app's own, loaded from the bundle; only the model, which
/// is data rather than code, comes from the network. A JavaScript bridge is
/// therefore enabled, unlike in the HTML artwork viewer, so the page can report
/// progress and load state. It accepts nothing but those reports. The view
/// cannot navigate anywhere, open windows, or reach files, the camera,
/// microphone or location.
///
/// Every touch that starts inside the view belongs to the model, inline as
/// in fullscreen: a drag there never scrolls the enclosing page, whichever
/// way it starts and whether or not the model has loaded yet. An inline model
/// that left vertical drags to the page orbited or scrolled depending on the
/// first few pixels of a drag, which read as the page stealing the gesture.
///
/// [placeholder] covers the view until the model has loaded, with
/// [progressBuilder]'s bar over it. It also stands in while a page route
/// covers this one and while the app is in the background: an auto-rotating
/// WebGL scene would otherwise keep rendering where nobody can see it. The
/// model reloads, from the web view's cache, when the view returns. With a
/// [session], a route that covers the view to show the same model, the
/// fullscreen viewer, takes the loaded model over instead, and hands it back
/// when it closes.
class ArtworkModelViewer extends StatefulWidget {
  const ArtworkModelViewer({
    required this.modelUrl,
    required this.placeholder,
    super.key,
    this.session,
    this.initialSource,
    this.autoRotate = true,
    this.progressBuilder,
    this.onLoaded,
    this.onFailed,
  });

  /// The artwork's own model URL, as the metadata names it.
  final String modelUrl;

  /// Shares the loaded model with this artwork's other viewer.
  final ArtworkModelSession? session;

  /// A source that already loaded this model, tried first. Spares the
  /// fullscreen viewer the source the inline one had to fall back from.
  final String? initialSource;
  final Widget placeholder;
  final bool autoRotate;

  /// The bar drawn over [placeholder] while the model loads: `null` progress
  /// until the first report, then 0..1.
  final Widget Function(double? progress)? progressBuilder;

  /// The source that loaded.
  final ValueChanged<String>? onLoaded;
  final VoidCallback? onFailed;

  @override
  State<ArtworkModelViewer> createState() => _ArtworkModelViewerState();
}

class _ArtworkModelViewerState extends State<ArtworkModelViewer>
    with WidgetsBindingObserver, RouteAware {
  String? _html;
  late String _source;
  bool _fallbackTried = false;

  /// Bumped every time a web view is (re)created. Keys the view, so a resume
  /// builds a fresh one, and lets callbacks from a discarded view recognise
  /// themselves as stale.
  int _attempt = 0;
  InAppWebViewController? _controller;

  /// The current web view's handle in [ArtworkModelViewer.session]; null
  /// without a session, or while no web view is built.
  InAppWebViewKeepAlive? _view;
  bool _started = false;
  bool _loaded = false;
  bool _failed = false;
  double? _progress;
  bool _routeCovered = false;
  bool _backgrounded = false;
  Timer? _stall;
  PageRoute<dynamic>? _route;

  bool get _suspended => _routeCovered || _backgrounded;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetSource();
    _newView();
    // A model taken over is shown from the first frame; its page has loaded
    // before, for the viewer that loaded it.
    _html = _loaded ? _pageValue : null;
    if (_html == null) {
      _loadPage().then((html) {
        if (mounted) setState(() => _html = html);
      });
    }
  }

  void _resetSource() {
    final url = widget.modelUrl.trim();
    final initial = widget.initialSource;
    _fallbackTried = false;
    _failed = false;
    if (url.isEmpty) {
      _source = '';
      _fail();
      return;
    }
    _source = initial != null && initial.isNotEmpty
        ? initial
        : getOriginalAssetUrl(url);
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
  void didUpdateWidget(covariant ArtworkModelViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.modelUrl != widget.modelUrl) {
      _stall?.cancel();
      _resetSource();
      _restart();
      return;
    }
    if (oldWidget.autoRotate != widget.autoRotate) _configure();
  }

  @override
  void dispose() {
    _stall?.cancel();
    _release(keep: true);
    WidgetsBinding.instance.removeObserver(this);
    browserPageRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPushNext() => _setSuspended(() => _routeCovered = true);

  @override
  void didPopNext() => _setSuspended(() => _routeCovered = false);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` (a system sheet, the app switcher) keeps the model: only
    // leaving the foreground tears it down.
    if (state == AppLifecycleState.inactive) return;
    final backgrounded =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    _setSuspended(() => _backgrounded = backgrounded);
  }

  void _setSuspended(VoidCallback change) {
    if (!mounted) return;
    final wasSuspended = _suspended;
    change();
    if (wasSuspended == _suspended) return;
    _stall?.cancel();
    // A covering route may be about to show this model; the background is
    // where nobody will, so a model left there would only keep rendering.
    _release(keep: !_backgrounded);
    setState(_restart);
  }

  /// The next view: the session's loaded model when there is one, otherwise a
  /// fresh page that has loaded nothing yet.
  void _restart() {
    _release(keep: false);
    _attempt++;
    _controller = null;
    _started = false;
    _loaded = false;
    _progress = null;
    _newView();
  }

  /// Picks the web view the next build shows. Taking over the session's
  /// loaded model skips the page load: the page and model are already up.
  void _newView() {
    final session = widget.session;
    if (session == null || _failed || _suspended) return;
    final shared = session._view;
    if (shared == null || session._disposed) {
      _view = InAppWebViewKeepAlive();
      return;
    }
    _view = shared;
    session._holder = this;
    _started = true;
    _loaded = true;
  }

  /// This viewer is done with its web view. With [keep], a loaded model is
  /// parked in the session for the next viewer; otherwise, and for a model
  /// that never loaded, the web view is disposed. A model another viewer has
  /// taken over is theirs to release.
  void _release({required bool keep}) {
    final session = widget.session;
    final view = _view;
    if (session == null || view == null) return;
    _view = null;
    if (identical(session._view, view)) {
      if (session._holder != this) return;
      session._holder = null;
      if (keep && !session._disposed) {
        session._collectIfUnclaimed();
        return;
      }
      session._view = null;
    }
    session._disposeAfterFrame(view);
  }

  /// The model is up: share it, retiring a parked one it replaces.
  void _share() {
    final session = widget.session;
    final view = _view;
    if (session == null || view == null || session._disposed) return;
    final previous = session._view;
    if (previous != null &&
        !identical(previous, view) &&
        session._holder == null) {
      session._disposeAfterFrame(previous);
    }
    session
      .._view = view
      .._holder = this;
  }

  void _armStall(int attempt) {
    _stall?.cancel();
    _stall = Timer(_stallTimeout, () => _sourceFailed(attempt));
  }

  void _onCreated(int attempt, InAppWebViewController controller) {
    if (attempt != _attempt) return;
    _controller = controller;
    controller.addJavaScriptHandler(
      handlerName: _handlerName,
      callback: (JavaScriptHandlerFunctionData data) {
        _onMessage(attempt, data.args.isEmpty ? null : data.args.first);
        return null;
      },
    );
    // A model taken over from the session is already up: it only needs this
    // viewer's settings.
    if (_loaded) {
      _configure();
    } else {
      _armStall(attempt);
    }
  }

  /// The page is up: configure it and hand it the model.
  void _onPageLoaded(int attempt) {
    if (attempt != _attempt || _started) return;
    _started = true;
    _configure();
    _loadSource(attempt);
  }

  void _configure() {
    _controller?.evaluateJavascript(
      source: 'mallowConfigure(${widget.autoRotate});',
    );
  }

  void _loadSource(int attempt) {
    _armStall(attempt);
    _controller?.evaluateJavascript(
      source: 'mallowLoad(${jsonEncode(_source)});',
    );
  }

  void _onMessage(int attempt, Object? message) {
    if (!mounted || attempt != _attempt || _failed) return;
    if (message is! Map) return;
    switch (message['type']) {
      case 'progress':
        if (_loaded) return;
        final value = message['value'];
        _armStall(attempt);
        if (value is num) {
          setState(() => _progress = value.toDouble().clamp(0.0, 1.0));
        }
      case 'load':
        if (_loaded) return;
        _stall?.cancel();
        setState(() => _loaded = true);
        _share();
        widget.onLoaded?.call(_source);
      case 'error':
        _sourceFailed(attempt);
    }
  }

  /// The current source failed. Before the model has shown, that earns the
  /// one gateway retry; after, it is a lost WebGL context, and the poster is a
  /// better picture than a blank view.
  Future<void> _sourceFailed(int attempt) async {
    if (!mounted || attempt != _attempt || _failed) return;
    _stall?.cancel();
    if (_loaded || _fallbackTried) {
      _fail();
      return;
    }
    _fallbackTried = true;
    final direct = await ImageFallback.directUrlFor(
      widget.modelUrl.trim(),
      failedUrl: _source,
    );
    if (!mounted || attempt != _attempt || _failed) return;
    if (direct == null) {
      _fail();
      return;
    }
    setState(() {
      _source = direct;
      _progress = null;
    });
    _loadSource(attempt);
  }

  /// The web content process died, almost always from memory pressure on a
  /// large model. Retrying another gateway would only load the same bytes.
  void _processGone(int attempt) {
    if (attempt != _attempt) return;
    _fail();
  }

  void _fail() {
    if (_failed) return;
    _failed = true;
    _stall?.cancel();
    _release(keep: false);
    // Deferred: this can run from initState / didUpdateWidget, where a parent
    // may not rebuild synchronously. A frame is requested because a failure
    // reported by the page or a timer arrives when none may be coming.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {});
        widget.onFailed?.call();
      })
      ..ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed || _suspended) return _ClaimTouches(child: widget.placeholder);
    final html = _html;
    final attempt = _attempt;
    // With no web view yet the claim has to come from Flutter; once there is
    // one, the view's own eager recognizer makes it, and the overlays let
    // touches through to it.
    Widget overlay(Widget child) => html == null
        ? _ClaimTouches(child: child)
        : IgnorePointer(child: child);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (html != null)
          InAppWebView(
            key: ValueKey<int>(attempt),
            keepAlive: _view,
            initialData: InAppWebViewInitialData(
              data: html,
              baseUrl: WebUri('about:blank'),
            ),
            // Eager: the view wins the gesture arena on pointer-down, before
            // the enclosing scroll view's drag recognizer can.
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
              Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
            },
            // The bridge is on because the page is ours (see the class
            // comment); the rest matches the HTML artwork viewer's sandbox,
            // spelled out so a plugin upgrade cannot quietly loosen it. The
            // data store stays persistent on iOS so a model is cached between
            // views: the page keeps no state of its own worth isolating.
            initialSettings: InAppWebViewSettings(
              useShouldOverrideUrlLoading: true,
              javaScriptBridgeEnabled: true,
              javaScriptHandlersForMainFrameOnly: true,
              javaScriptCanOpenWindowsAutomatically: false,
              supportMultipleWindows: false,
              allowFileAccess: false,
              allowContentAccess: false,
              allowFileAccessFromFileURLs: false,
              allowUniversalAccessFromFileURLs: false,
              mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
              sharedCookiesEnabled: false,
              thirdPartyCookiesEnabled: false,
              geolocationEnabled: false,
              mediaPlaybackRequiresUserGesture: true,
              isElementFullscreenEnabled: false,
              allowsLinkPreview: false,
              allowsBackForwardNavigationGestures: false,
              disableContextMenu: true,
              disableLongPressContextMenuOnLinks: true,
              // The page has no text: a held press must not start a selection.
              isTextInteractionEnabled: false,
              disableDefaultErrorPage: true,
              supportZoom: false,
              transparentBackground: true,
              verticalScrollBarEnabled: false,
              horizontalScrollBarEnabled: false,
              disallowOverScroll: true,
              isInspectable: kDebugMode,
            ),
            onWebViewCreated: (controller) => _onCreated(attempt, controller),
            shouldOverrideUrlLoading: (_, action) async =>
                artworkModelNavigationPolicy(action),
            onLoadStop: (_, _) => _onPageLoaded(attempt),
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
            onRenderProcessGone: (_, _) => _processGone(attempt),
            onWebContentProcessDidTerminate: (_) => _processGone(attempt),
          ),
        // Covers the view until the model shows.
        if (!_loaded) overlay(widget.placeholder),
        if (!_loaded && widget.progressBuilder != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: overlay(widget.progressBuilder!(_progress)),
          ),
      ],
    );
  }
}

/// Wins every touch that starts on [child] and does nothing with it, so the
/// enclosing scroll view never sees a drag that began over the model's box.
/// Stands in for the web view's own claim while there is no web view.
class _ClaimTouches extends StatelessWidget {
  const _ClaimTouches({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      EagerGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
            EagerGestureRecognizer.new,
            (_) {},
          ),
    },
    child: child,
  );
}

/// The viewer page is loaded as data and never navigates, so only that
/// initial `about:` load goes ahead. Everything else is refused, frames and
/// other apps' deep links included.
@visibleForTesting
NavigationActionPolicy artworkModelNavigationPolicy(NavigationAction action) =>
    action.isForMainFrame && action.request.url?.scheme.toLowerCase() == 'about'
    ? NavigationActionPolicy.ALLOW
    : NavigationActionPolicy.CANCEL;
