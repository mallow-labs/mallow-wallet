import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../features/browser/models/browser_open_link.dart';
import '../../features/walletconnect/walletconnect_module.dart';
import '../router/app_router.dart';
import 'deep_link_handler_registry.dart';
import 'twitter_connect_notifier.dart';

/// Captures inbound Android App Links / iOS Universal Links (and the
/// `mallowwallet://` custom-scheme fallback), plus WalletConnect `wc:` links,
/// and dispatches them.
///
/// Responsibilities:
///  1. Publish the X (Twitter) connect callback to whatever screen started
///     that flow.
///  2. Translate the subset of mallow.art web paths the app understands into
///     in-app `go_router` locations. Unknown paths are ignored so go_router
///     never turns an unrelated link into its error screen.
///  3. Open explicit browser handoffs in a new tab without logging the URL,
///     over the current screen when the app is already running.
///  4. Offer every other trusted link to the [DeepLinkHandlerRegistry] first,
///     so a feature can claim a path this class does not route.
///  5. Hand WalletConnect pairing links (`wc:` and `mallowwallet://wc?uri=`)
///     to WalletConnect before anything can log them.
class DeepLinkService {
  DeepLinkService({
    required GoRouter router,
    required TwitterConnectNotifier twitterConnectNotifier,
    AppLinks? appLinks,
    DeepLinkHandlerRegistry? handlerRegistry,
  }) : _router = router,
       _twitterConnectNotifier = twitterConnectNotifier,
       _appLinks = appLinks ?? AppLinks(),
       _handlerRegistry = handlerRegistry;

  final GoRouter _router;
  final TwitterConnectNotifier _twitterConnectNotifier;
  final DeepLinkHandlerRegistry? _handlerRegistry;
  final AppLinks _appLinks;
  StreamSubscription<Uri>? _sub;
  bool _disposed = false;

  /// Set while a routing action is parked waiting for the router delegate to
  /// publish its first configuration (see [_afterRouterReady]).
  VoidCallback? _routerReadyListener;

  /// Begin handling inbound links. Processes the cold-start link (the URI that
  /// launched the app, if any) then subscribes for warm-start links delivered
  /// while the app is already running.
  Future<void> start() async {
    Uri? initialLink;
    Uri? initialBrowserLink;
    try {
      final initial = await _appLinks.getInitialLink();
      if (_disposed) return;
      initialLink = initial;
      if (initial != null && browserOpenLinkUrl(initial) != null) {
        initialBrowserLink = initial;
      }
      if (initial != null) _handleUri(initial, coldStart: true);
    } catch (e) {
      debugPrint('DeepLinkService: getInitialLink failed: $e');
    }

    if (_disposed) return;
    var firstEvent = true;
    _sub = _appLinks.uriLinkStream.listen((uri) {
      // app_links replays the cold-start link on its stream. A share action
      // has a fresh request id, so later shares of the same page still open.
      final replay = firstEvent && uri == initialLink;
      firstEvent = false;
      // A browser handoff replay is dropped here. Every other replay goes on
      // flagged, for a handler that must tell it from a second scan.
      if (replay && uri == initialBrowserLink) return;
      _handleUri(uri, replay: replay);
    }, onError: (Object e) => debugPrint('DeepLinkService: stream error: $e'));
  }

  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    _clearRouterReadyListener();
  }

  void _handleUri(Uri uri, {bool coldStart = false, bool replay = false}) {
    if (_disposed) return;
    // The Web3Auth OAuth redirect is consumed natively by the SDK to finish
    // the login; app_links hands it to this listener as well. Drop it before
    // anything else: the app must never route it or read a parameter out of
    // it, and its query — the login handshake — must stay out of the platform
    // log, which `debugPrint` reaches in release builds too.
    if (uri.scheme == 'mallowwallet' && uri.host == 'auth') return;

    // A WalletConnect link carries the key that encrypts its pairing, so it
    // is taken before anything below can log it, and never routed. The OS
    // replay of a cold-start link would pair a second time, which fails.
    if (uri.scheme == 'wc' ||
        (uri.scheme == 'mallowwallet' && uri.host == 'wc')) {
      if (!replay) handleWalletConnectLink(uri);
      return;
    }

    // Consume this namespace before logging or OAuth callback handling: a
    // shared website can contain private query parameters and fragments.
    if (uri.scheme == 'mallowwallet' && uri.host == 'browser') {
      final url = browserOpenLinkUrl(uri);
      if (url == null) return;
      final request = BrowserOpenRequest(url);
      // A share from a running app goes on top of whatever is open — usually
      // the screen the user shared from — so leaving the browser returns
      // there and the tab underneath does not change. A cold start has no
      // screen to return to yet, so it lands on the browser tab instead.
      if (coldStart || _router.routerDelegate.currentConfiguration.isEmpty) {
        _router.go(AppRoutes.browserOpen, extra: request);
      } else {
        _router.push(AppRoutes.browserOpen, extra: request);
      }
      return;
    }

    // Debug only, for the same reason the redirect is dropped above: an inbound
    // link names the artwork, collection or profile the user opened, and
    // `debugPrint` is not stripped from a release build.
    if (kDebugMode) debugPrint('DeepLinkService: inbound $uri');

    // Only act on links from a trusted origin. Verified App Links / Universal
    // Links are already host-restricted by the OS, but links can also arrive
    // via the `mallowwallet://` custom scheme or be handed in programmatically,
    // so re-check the origin here before emitting a connect callback or
    // routing — never act on an attacker-crafted origin (defense in depth).
    if (!isTrustedOrigin(uri)) return;

    // A feature's own claim comes before the twitter check and the route map:
    // a path `mapToLocation` does not know would otherwise be ignored. A
    // handler that returns true has consumed the link.
    if (_handlerRegistry?.handle(uri, replay: replay) ?? false) return;

    // 1. X (Twitter) connect callback — the backend `/v2/twitter/callback`
    //    redirects here with `?twitter=success|error|error_user_exists` once
    //    the OAuth round trip finishes. Publish the outcome for the open
    //    EditProfileScreen to refresh + toast; nothing to route.
    final twitter = uri.queryParameters['twitter'];
    if (twitter != null) {
      _twitterConnectNotifier.emitFromCallback(twitter);
      return;
    }

    // 2. Known mallow.art web path → in-app location.
    final location = mapToLocation(uri);
    if (location != null) {
      // These targets are top-level routes, not nested under home, so a plain
      // `go` would leave them alone on the stack — the in-page back button and
      // the OS back/swipe would have nothing to pop to. Seed home as the base
      // then push the destination so back returns to home, as it does for
      // in-app navigation (which pushes onto the home stack).
      _router.go(AppRoutes.home);
      _afterRouterReady(() => _router.push(location));
    }

    // 3. Anything else is left alone — the OS/browser keeps it.
  }

  /// Runs [action] once the router delegate holds a real configuration, then
  /// one frame later.
  ///
  /// `push` captures its base stack synchronously from the delegate's *current*
  /// configuration, but that stays [RouteMatchList.empty] until the `Router`
  /// widget mounts and processes its first route information. On a cold-start
  /// deep link the link is handled while the app is still on its pre-router
  /// splash, so pushing immediately — or one frame later, since that frame is
  /// still a pre-router one — stacks the destination onto an empty base. Home
  /// never lands underneath and back is a dead tap. Waiting on the delegate
  /// ties the push to the state it actually depends on instead of to a frame
  /// count. The extra frame keeps the push out of the delegate's own
  /// notification, which fires mid-build while the Router is mounting.
  void _afterRouterReady(VoidCallback action) {
    void run() => WidgetsBinding.instance.addPostFrameCallback((_) => action());

    _clearRouterReadyListener();
    final delegate = _router.routerDelegate;
    if (delegate.currentConfiguration.isNotEmpty) {
      run();
      return;
    }
    void onDelegateChanged() {
      if (delegate.currentConfiguration.isEmpty) return;
      _clearRouterReadyListener();
      run();
    }

    _routerReadyListener = onDelegateChanged;
    delegate.addListener(onDelegateChanged);
  }

  void _clearRouterReadyListener() {
    final listener = _routerReadyListener;
    if (listener == null) return;
    _router.routerDelegate.removeListener(listener);
    _routerReadyListener = null;
  }

  /// Whether [uri] originates from somewhere the app trusts: a verified
  /// `mallow.art` (sub)domain over HTTPS, or the `mallowwallet://` custom
  /// scheme (which carries no host). Any other origin is ignored.
  static bool isTrustedOrigin(Uri uri) {
    if (uri.scheme == 'mallowwallet') return true;
    if (uri.scheme == 'https') {
      final host = uri.host.toLowerCase();
      return host == 'mallow.art' || host.endsWith('.mallow.art');
    }
    return false;
  }

  /// Maps a mallow.art (or `mallowwallet://`) URI to an in-app location, or
  /// null when the first path segment isn't one the app routes. Also used by
  /// the search sheet to resolve a pasted mallow.art link to its destination.
  static String? mapToLocation(Uri uri) {
    final segments = uri.pathSegments;
    if (segments.length < 2) return null;
    final id = segments[1];
    if (id.isEmpty) return null;

    switch (segments.first) {
      case 'artwork':
        return AppRoutes.artworkDetailPath(id);
      case 'collection':
        return AppRoutes.collectionPath(id);
      case 'u':
        return AppRoutes.deepLinkProfileByUsernamePath(id);
      case 'a':
        return AppRoutes.deepLinkProfilePath(id);
      default:
        return null;
    }
  }
}
