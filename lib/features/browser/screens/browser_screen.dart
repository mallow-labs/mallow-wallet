import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/environment.dart';
import '../../../core/config/remote_config_service.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/models/account.dart';
import '../../../core/security/app_lock_bloc.dart';
import '../../../core/services/deep_link_handler_registry.dart';
import '../../../core/services/deep_link_service.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/utils/reduce_motion.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/utils/explorer_utils.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../models/browser_models.dart';
import '../models/dapp_request.dart';
import '../services/browser_certificate_exceptions.dart';
import '../services/browser_obscured_insets.dart';
import '../services/browser_services.dart';
import '../services/browser_session.dart';
import '../services/browser_signing_service.dart';
import '../services/browser_transaction_tracker.dart';
import '../services/browser_ui_channel.dart';
import '../services/browser_visibility.dart';
import '../services/browser_wallet_selection.dart';
import '../services/dapp_request_coordinator.dart';
import '../services/ethereum_dapp_adapter.dart';
import '../services/tezos_dapp_adapter.dart';
import '../services/tezos_beacon_transport.dart';
import '../../../core/network/tezos_rpc_service.dart';
import '../widgets/browser_address_bar.dart';
import '../widgets/browser_address_field.dart';
import '../widgets/browser_bottom_bar.dart';
import '../widgets/browser_lock_cover.dart';
import '../widgets/browser_page_menu.dart';
import '../widgets/browser_status_toast.dart';
import '../widgets/browser_tab_switcher.dart';
import '../widgets/browser_undo_toast.dart';
import '../widgets/browser_wallet_picker.dart';
import '../widgets/browser_webview_host.dart';
import '../widgets/dapp_connect_sheet.dart';
import '../../walletconnect/services/walletconnect_page_code.dart';
import '../../walletconnect/services/walletconnect_service.dart';
import '../../walletconnect/walletconnect_module.dart';
import 'browser_settings_screen.dart';
import 'browser_start_screen.dart';

/// The scrim over the browser chrome while a first-party page shows its own
/// bottom sheet; see [BrowserUiSetOverlay].
const browserChromeScrimKey = ValueKey('browser-chrome-scrim');

/// The scrim over the system navigation bar's strip, which Android keeps
/// reserved under a first-party page's own bottom sheet.
const browserChromeBottomScrimKey = ValueKey('browser-chrome-bottom-scrim');

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, this.initialUrl});

  /// An explicit Share-sheet handoff opens in a new tab after restoration.
  final Uri? initialUrl;

  /// Enters the browser with a cross-fade while the app's nav bar slides away
  /// and the browser bar rises in its place.
  static Route<void> route() => PageRouteBuilder<void>(
    transitionDuration: MallowTheme.sheetDuration,
    reverseTransitionDuration: MallowTheme.sheetDuration,
    pageBuilder: (_, _, _) => const BrowserScreen(),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: MallowTheme.sheetCurve,
        reverseCurve: Curves.easeInCubic,
      ),
      child: child,
    ),
  );

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with WidgetsBindingObserver, RouteAware, TickerProviderStateMixin {
  final _session = BrowserSession.instance;
  final _walletSession = sl<SessionManager>();
  final _remote = sl<RemoteConfigService>();
  // The app-wide lock bloc, read from the BlocProvider in app.dart. AppLockBloc
  // is a DI *factory*: resolving it from `sl` would mint a fresh bloc stuck in
  // `uninitialized`, which reads as locked and leaves the website hidden
  // behind the lock placeholder for good.
  late final AppLockBloc _appLock = context.read<AppLockBloc>();
  InAppWebViewController? _controller;
  late final DappRequestCoordinator _coordinator;
  StreamSubscription<void>? _grantsSubscription;
  StreamSubscription<AppLockState>? _lockSubscription;
  WalletInfo? _wallet;

  /// The session's Ethereum wallet, which `window.ethereum` acts for. It
  /// follows the session like [_wallet] does, preferring the one last picked
  /// in the browser's wallet picker.
  WalletInfo? _ethereumWallet;
  WalletInfo? _tezosWallet;
  Chain? _preferredBrowserChain;
  String? _siteWalletOrigin;
  int _siteWalletRevision = 0;
  Future<void> _siteWalletSelection = Future.value();
  final _beacon = TezosBeaconTransport.instance;
  late final _tezos = TezosDappAdapter(
    walletManager: sl<WalletManager>(),
    rpc: sl<TezosRpcService>(),
  );
  late final _ethereum = EthereumDappAdapter(
    walletManager: sl<WalletManager>(),
  );
  String? _sessionIdentity;
  bool _profileFallbackAttempted = false;
  String? _visibleTab;
  Uri? _committed;
  int _generation = 0;
  int _hostRevision = 0;
  bool _webViewPaused = false;

  /// The last WebView built while unlocked, by its host key. The lock keeps
  /// that one; no other starts behind the lock.
  String? _unlockedHost;
  int _walletRevision = 0;
  int _revocationRevision = browserPermissions.revocationRevision;
  int _progress = 0;
  bool _canBack = false, _canForward = false;
  final _visibility = BrowserVisibility();
  PageRoute<dynamic>? _pageRoute;

  /// The committed site holds a grant for either chain's wallet.
  bool _connected = false;
  bool _solanaConnected = false;
  bool _ethereumConnected = false;
  bool _tezosConnected = false;
  Route<bool>? _connectionRoute;

  /// The WebView sits under the bars and is told their heights as obscured
  /// insets (iOS 26+); otherwise it is laid out between them.
  bool _underChrome = false;

  /// The colour the active page paints behind its content, if it offers one.
  Color? _pageColor;

  /// The colour each origin last reported, so a return visit opens in it
  /// instead of changing colour once the page has settled.
  static final _originColors = <String, Color?>{};

  /// `Uri.origin` throws for anything but http and https.
  static String? _originOf(Uri? url) =>
      url != null && (url.isScheme('https') || url.isScheme('http'))
      ? url.origin
      : null;

  Color? _rememberedColor(Uri? url) => _originColors[_originOf(url)];

  void _rememberColor(Uri url, Color? color) {
    final origin = _originOf(url);
    if (origin == null) return;
    _originColors
      ..remove(origin)
      ..[origin] = color;
    if (_originColors.length > 64) {
      _originColors.remove(_originColors.keys.first);
    }
  }

  /// The active page runs under the bottom bar where the WebView cannot be
  /// told the bar covers it (Android; see `BrowserBottomOverlay`).
  bool _underBottomBar = false;
  final _webViewKey = GlobalKey();
  (Rect, double, double, InAppWebViewController?)? _appliedInsets;
  int _insetRetries = 0;

  /// Set while the browser's own wallet picker switches Account or Profile,
  /// so that switch keeps the open tabs; see [_walletChanged].
  bool _keepTabsOnIdentitySwitch = false;
  bool _menuIsOpen = false;
  late bool _openingInitialUrl = widget.initialUrl != null;

  /// The bar is compact (a flat host row) while the page scrolls down.
  final _collapse = BrowserBarCollapse();
  bool _sheetKeyboard = false;
  Completer<Uri?>? _addressResult;
  String _addressInitial = '';
  bool get _editingAddress => _addressResult != null;
  Timer? _thumbnailTimer;
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: MallowTheme.sheetDuration,
  );
  bool _entranceStarted = false;

  /// The address bar's shrink, 0 expanded and 1 compact. The bar and the
  /// WebView's geometry under it (its frame, or its obscured insets) both
  /// follow this one value, so the page moves with the bar each frame rather
  /// than jumping to the end state while the bar is still animating.
  late final AnimationController _barCollapse = AnimationController(
    vsync: this,
  );
  bool _barCompact = false;

  /// A first-party page has its own bottom sheet up (`window.mallow.ui
  /// .setOverlay`). The bottom bar steps aside so the sheet reaches the
  /// screen's edge, the address bar goes compact, and the chrome left above
  /// the page dims with the page's own scrim. [_overlay] carries the motion,
  /// 0 at rest and 1 fully dimmed.
  bool _pageOverlay = false;
  late final AnimationController _overlay = AnimationController(vsync: this)
    ..addStatusListener((status) {
      // The WebView keeps the bottom bar's strip until the bar is back.
      if (status == AnimationStatus.dismissed && mounted) setState(() {});
    });

  bool get _unlocked =>
      _appLock.state is AppLockStateUnlocked ||
      _appLock.state is AppLockStateNoPinSet;
  bool get _live => mounted && _unlocked && _remote.config.value.browserEnabled;
  bool get _active => _live && _visibility.canReceiveRequests;

  /// The user is looking at the page. A page kept while the app is locked or
  /// away goes on running, but nothing it starts then may act for the user or
  /// wait on them: no prompts, no wallet switch.
  bool get _attended => _live && !_visibility.coverWebView;

  /// Whether [url]'s origin is open past a certificate warning, so the chrome
  /// must not present it as verified.
  bool _notSecure(Uri? url) =>
      url != null &&
      isBrowserUrl(url) &&
      BrowserCertificateExceptions.instance.covers(url.origin);

  void _certificatesChanged() {
    if (mounted) setState(() {});
  }

  bool _isCurrentFrame(DappFrameContext frame) =>
      frame.tabId == _session.activeId &&
      frame.generation == _generation &&
      frame.origin.origin == _committed?.origin;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _visibleTab = _session.activeId;
    _coordinator = DappRequestCoordinator(
      permissions: browserPermissions,
      currentWallet: () => _wallet == null
          ? null
          : DappWallet(
              id: _wallet!.id,
              address: _wallet!.address,
              canSign: _wallet!.canSign,
              canSignMessages:
                  _wallet!.canSign &&
                  solanaSignsDappMessagesVerbatim(_wallet!.walletType),
              chains: Config.isProduction
                  ? const ['solana:mainnet']
                  : const ['solana:mainnet', 'solana:devnet'],
              type: _wallet!.walletType,
            ),
      currentEthereumWallet: () => _ethereumWallet == null
          ? null
          : DappWallet(
              id: _ethereumWallet!.id,
              address: _ethereumWallet!.address,
              canSign: _ethereumWallet!.canSign,
              chains: const [ethereumMainnet],
              type: _ethereumWallet!.walletType,
            ),
      currentTezosWallet: () => _tezosWallet == null
          ? null
          : DappWallet(
              id: _tezosWallet!.id,
              address: _tezosWallet!.address,
              canSign:
                  _tezosWallet!.canSign &&
                  tezosBrowserCanSign(_tezosWallet!.walletType),
              chains: const [tezosMainnet],
              type: _tezosWallet!.walletType,
            ),
      tezosPublicKey: (wallet, active) =>
          _tezos.publicKey(wallet.id, wallet.address, active),
      connectTezosPublicKey: (wallet, active, cancelled) => _tezos.publicKey(
        wallet.id,
        wallet.address,
        active,
        cancelled: cancelled,
      ),
      cachedTezosPublicKey: (wallet) =>
          _tezos.cachedPublicKey(wallet.id, wallet.address),
      beaconTransport: _beacon,
      // Deferred: the adapter resolves its signer on first use.
      ethereumRead: (method, params) => _ethereum.read(method, params),
      approveConnection: _approveConnection,
      execute: (request) => BrowserSigningService(
        ethereumAdapter: _ethereum,
        tezosAdapter: _tezos,
        openExternal: _openExternal,
      ).execute(context, request),
      isContextCurrent: (frame) => _active && _isCurrentFrame(frame),
      isRequestCurrent: (frame) =>
          _live && _visibility.canContinueRequests && _isCurrentFrame(frame),
    );
    _session.addListener(_sessionChanged);
    BrowserCertificateExceptions.instance.addListener(_certificatesChanged);
    _walletSession.addListener(_walletChanged);
    _remote.config.addListener(_remoteChanged);
    _grantsSubscription = browserPermissions.changes.listen((_) {
      final revision = browserPermissions.revocationRevision;
      if (revision != _revocationRevision) {
        _revocationRevision = revision;
        unawaited(_disconnectRevokedProviders(revision));
      } else {
        _refreshConnection();
      }
    });
    _lockSubscription = _appLock.stream.listen((state) {
      if (state is AppLockStateLocked || state is AppLockStateUninitialized) {
        _invalidate();
        // Screenshots can show balances and addresses: none survive a lock.
        _thumbnailTimer?.cancel();
        _session.clearThumbnails();
        if (mounted) setState(() {});
      } else if (mounted) {
        setState(() {});
        _catchUpSiteWallet();
      }
    });
    _walletChanged();
    BrowserObscuredInsets.supported().then((supported) {
      if (mounted && supported) setState(() => _underChrome = true);
    });
    if (_openingInitialUrl) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openInitialUrl());
    }
  }

  Future<void> _openInitialUrl() async {
    if (!mounted) return;
    await _session.load();
    if (!mounted) return;
    if (!_remote.config.value.browserEnabled) {
      _remoteChanged();
      return;
    }
    final url = widget.initialUrl;
    if (url != null && isBrowserUrl(url)) {
      try {
        _session.openPending(url);
      } on StateError catch (error) {
        _showError(error.message);
      }
    }
    if (mounted) setState(() => _openingInitialUrl = false);
  }

  Future<void> _disconnectRevokedProviders(int revision) async {
    final controller = _controller;
    final origin = _committed?.origin;
    final generation = _generation;
    final wallet = _wallet;
    final ethereum = _ethereumWallet;
    final tezos = _tezosWallet;
    // Cancel native approvals immediately, then retain each provider whose
    // selected account still has a grant for this document.
    _invalidate(notifyPage: false);
    await _refreshConnection();
    if (!mounted ||
        _revocationRevision != revision ||
        _controller != controller ||
        _committed?.origin != origin ||
        _generation != generation ||
        !_sameWallet(_wallet, wallet) ||
        !_sameWallet(_ethereumWallet, ethereum) ||
        !_sameWallet(_tezosWallet, tezos))
      return;
    _invalidate(
      disconnect: true,
      preserveNamespaces: [
        if (_solanaConnected) 'solana',
        if (_ethereumConnected) 'eip155',
        if (_tezosConnected) 'tezos',
      ],
    );
  }

  void _invalidate({
    bool disconnect = false,
    bool notifyPage = true,
    List<String>? preserveNamespaces,
  }) {
    _finishAddress(null);
    // Everything that cancels the page's requests — a new document, a
    // reload, a tab switch, a native overlay, the WebView going away — also
    // ends its claim on the chrome.
    _setPageOverlay(false);
    _coordinator.invalidate();
    if (notifyPage) {
      _controller?.evaluateJavascript(
        source:
            'window.__mallowDisconnect && window.__mallowDisconnect({preserveConnection: ${!disconnect}${preserveNamespaces == null ? '' : ', preserveNamespaces: ${jsonEncode(preserveNamespaces)}'}});',
      );
    }
    final route = _connectionRoute;
    if (route != null && route.isActive)
      route.navigator?.removeRoute(route, false);
    _connectionRoute = null;
  }

  void _sessionChanged() {
    if (_visibleTab != _session.activeId) {
      _invalidate();
      _visibleTab = _session.activeId;
      _controller = null;
      _committed = null;
      _generation = 0;
      _canBack = false;
      _canForward = false;
      _collapse.reset();
      _thumbnailTimer?.cancel();
    }
    if (mounted) setState(() {});
  }

  void _remoteChanged() {
    if (!_remote.config.value.browserEnabled) {
      _invalidate();
      _session.clear(keepBookmarks: true);
      final route = _pageRoute;
      final navigator = route?.navigator;
      if (mounted && route != null && route.isActive && navigator != null) {
        navigator.popUntil((candidate) => identical(candidate, route));
        navigator.removeRoute(route);
      }
    }
  }

  /// Follows the session to its Solana wallet. The session notifies for
  /// more than wallet changes (a re-login finishing, a profile refresh), so
  /// open requests are cancelled only when the identity or the wallet
  /// actually changed: a connection sheet opened just after a switch must
  /// survive the switch's late notifications.
  Future<void> _walletChanged() async {
    final revision = ++_walletRevision;
    final identity =
        '${_walletSession.mode.name}:${_walletSession.isProfileMode ? _walletSession.activeProfile?.userId : _walletSession.activeAccount?.id}';
    if (identity != _sessionIdentity) {
      _invalidate(disconnect: true);
      _wallet = null;
      _ethereumWallet = null;
      _tezosWallet = null;
      // A switch to another Account or Profile closes the tabs, unless the
      // user made it from the browser's own picker to use with the open site.
      if (_sessionIdentity != null && !_keepTabsOnIdentitySwitch) {
        _session.clear(keepBookmarks: true);
      }
      if (!_keepTabsOnIdentitySwitch) {
        _preferredBrowserChain = null;
        _siteWalletOrigin = null;
      }
      _profileFallbackAttempted = false;
    }
    _sessionIdentity = identity;
    final available = _solanaWallets();
    final active = await sl<WalletRepository>().getActiveWallet();
    if (!mounted || identity != _sessionIdentity || revision != _walletRevision)
      return;
    WalletInfo? selected = available
        .where((w) => w.id == active?.id)
        .firstOrNull;
    if (selected == null &&
        _walletSession.isProfileMode &&
        !_profileFallbackAttempted) {
      _profileFallbackAttempted = true;
      final fallback =
          available.where((w) => w.canSign).firstOrNull ??
          available.firstOrNull;
      if (fallback != null) {
        try {
          await _walletSession.selectSourceWallet(fallback);
        } catch (_) {
          _showError('Select a Solana wallet to connect.');
        }
        return;
      }
    }
    // The Ethereum wallet last picked in the browser while it is in this
    // session, else the session's signable one, else a view-only one, which
    // can connect but not sign — the same rule as the Solana selection.
    final ethereumWallets = _walletSession.sessionWallets.where(
      (w) => w.chainEnum == Chain.ethereum && w.address.isNotEmpty,
    );
    final remembered = sl.isRegistered<PreferencesService>()
        ? sl<PreferencesService>().browserEthereumWalletId
        : null;
    final ethereum =
        ethereumWallets.where((w) => w.id == remembered).firstOrNull ??
        ethereumWallets.where((w) => w.canSign).firstOrNull ??
        ethereumWallets.firstOrNull;
    final tezosWallets = _walletSession.sessionWallets.where(
      (w) => w.chainEnum == Chain.tezos && w.address.isNotEmpty,
    );
    final rememberedTezos = sl.isRegistered<PreferencesService>()
        ? sl<PreferencesService>().browserTezosWalletId
        : null;
    final tezos =
        tezosWallets.where((w) => w.id == rememberedTezos).firstOrNull ??
        tezosWallets
            .where((w) => w.canSign && tezosBrowserCanSign(w.walletType))
            .firstOrNull ??
        tezosWallets.firstOrNull;
    final changed =
        !_sameWallet(selected, _wallet) ||
        !_sameWallet(ethereum, _ethereumWallet) ||
        !_sameWallet(tezos, _tezosWallet);
    // A request pinned to the previous wallet fails its own check once
    // _wallet moves on; invalidating also closes its sheet at once.
    if (changed) _invalidate(disconnect: true);
    setState(() {
      _wallet = selected;
      _ethereumWallet = ethereum;
      _tezosWallet = tezos;
    });
    await _refreshConnection();
    if (changed && _active && _connected) {
      await _controller?.evaluateJavascript(source: _restoreScript);
    }
  }

  /// The same wallet, as far as a request pinned to it can tell.
  static bool _sameWallet(WalletInfo? a, WalletInfo? b) =>
      a?.id == b?.id &&
      a?.address == b?.address &&
      a?.canSign == b?.canSign &&
      a?.walletType == b?.walletType;

  List<WalletInfo> _solanaWallets() => _walletSession.sessionWallets
      .where((w) => w.chainEnum == Chain.solana)
      .toList();

  /// Silently hands each provider back any account their site was
  /// already granted; nothing prompts.
  static const _restoreScript =
      'window.__mallowRestore && window.__mallowRestore();';

  /// Connected when the committed site holds a grant for either wallet.
  Future<void> _refreshConnection() async {
    final origin = _committed?.origin;
    final wallet = _wallet;
    final ethereum = _ethereumWallet;
    final tezos = _tezosWallet;
    var solana = false, evm = false, tez = false;
    try {
      if (origin != null) {
        solana =
            wallet != null &&
            await browserPermissions.isGranted(origin, wallet.address);
        evm =
            ethereum != null &&
            await browserPermissions.isGranted(origin, ethereum.address);
        tez =
            tezos != null &&
            await browserPermissions.isGranted(origin, tezos.address);
      }
    } catch (_) {
      _showError('Connected sites could not be loaded. Please try again.');
    }
    if (mounted &&
        _wallet?.id == wallet?.id &&
        _ethereumWallet?.id == ethereum?.id &&
        _tezosWallet?.id == tezos?.id &&
        _committed?.origin == origin)
      setState(() {
        _solanaConnected = solana;
        _ethereumConnected = evm;
        _tezosConnected = tez;
        _connected = solana || evm || tez;
      });
  }

  /// Errors float as the app's snack bar, so they never push the WebView.
  void _showError(String message) {
    if (mounted)
      AppSnackBar.show(context, message, type: AppSnackBarType.error);
  }

  /// A link in the app's own scheme goes where it would go had it opened the
  /// app, as a scanned one does: a feature's own claim first, then an in-app
  /// screen over the browser. Never a replay: each tap is a fresh one.
  bool _openAppLink(Uri link) {
    if (sl<DeepLinkHandlerRegistry>().handle(link, replay: false)) return true;
    final location = DeepLinkService.mapToLocation(link);
    if (location == null || !mounted) return false;
    unawaited(context.push(location));
    return true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _pageRoute) {
      if (_pageRoute != null) browserPageRouteObserver.unsubscribe(this);
      _pageRoute = route;
      browserPageRouteObserver.subscribe(this, route);
    }
    if (!_entranceStarted) {
      _entranceStarted = true;
      if (context.reduceMotion) {
        _entrance.value = 1;
      } else {
        _entrance.forward();
      }
    }
  }

  @override
  void didPushNext() {
    _invalidate();
    if (mounted)
      setState(() {
        _visibility.routeVisible = false;
        _controller = null;
        _hostRevision++;
      });
  }

  @override
  void didPopNext() {
    if (mounted) setState(() => _visibility.routeVisible = true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cancel = _visibility.updateLifecycle(state);
    if (cancel) {
      _invalidate();
      _pauseWebView(true);
    } else if (state == AppLifecycleState.resumed) {
      _pauseWebView(false);
    }
    if (mounted) setState(() {});
    _catchUpSiteWallet();
  }

  /// Android's WebView expects onPause and onResume around backgrounding;
  /// without them a kept page goes on running its animations and geolocation
  /// while the app is away. iOS suspends the page itself.
  void _pauseWebView(bool paused) {
    final controller = _controller;
    if (controller == null ||
        defaultTargetPlatform != TargetPlatform.android ||
        paused == _webViewPaused)
      return;
    _webViewPaused = paused;
    unawaited(
      (paused ? controller.pause() : controller.resume()).then<void>(
        (_) {},
        onError: (Object _) {},
      ),
    );
  }

  /// The OS ended the page's process, which it does to a backgrounded page
  /// under memory pressure. That WebView cannot draw again, so a new one
  /// loads the tab: the one reload that keeping the page cannot avoid.
  void _webViewGone() {
    _invalidate(notifyPage: false);
    if (mounted)
      setState(() {
        _controller = null;
        _hostRevision++;
      });
  }

  @override
  void dispose() {
    final addressResult = _addressResult;
    if (addressResult != null && !addressResult.isCompleted) {
      addressResult.complete(null);
    }
    browserPageRouteObserver.unsubscribe(this);
    _coordinator.dispose();
    _session.removeListener(_sessionChanged);
    BrowserCertificateExceptions.instance.removeListener(_certificatesChanged);
    _walletSession.removeListener(_walletChanged);
    _remote.config.removeListener(_remoteChanged);
    _grantsSubscription?.cancel();
    _lockSubscription?.cancel();
    _thumbnailTimer?.cancel();
    _entrance.dispose();
    _barCollapse.dispose();
    _overlay.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Leaving for the Explorer from an open review must not reject it or
  /// reload the page underneath; see [BrowserVisibility.beginExternalHop].
  /// External, not an in-app view: an iOS Safari view never backgrounds the
  /// app, so no resume would end the hop.
  Future<void> _openExternal(Uri url) async {
    _visibility.beginExternalHop();
    var launched = false;
    try {
      launched = await launchUrl(url, mode: LaunchMode.externalApplication);
    } finally {
      if (!launched) _visibility.endExternalHop();
    }
  }

  Future<T> _nativeOverlay<T>(Future<T> Function() show) async {
    _invalidate();
    _visibility.nativeOverlays++;
    try {
      return await show();
    } finally {
      _visibility.nativeOverlays--;
      if (_active && _connected) {
        try {
          await _controller?.evaluateJavascript(source: _restoreScript);
        } catch (_) {
          // A closing or navigating WebView no longer has a JavaScript
          // context; the overlay's own result must still reach the caller.
        }
      }
    }
  }

  Future<bool> _approveConnection(DappConnectionRequest request) async {
    if (!_active) return false;
    final tab = _session.activeTab;
    late final Route<bool> route;
    route = dappConnectRoute(
      context: context,
      request: request,
      // Decoration only: the sheet names the site by its canonical origin.
      iconUrl: tab?.url?.host == request.context.origin.host
          ? tab?.iconUrl
          : null,
      onSwitch: () => unawaited(_switchFromConnect(route, request)),
    );
    _connectionRoute = route;
    unawaited(
      request.cancelled.then((_) {
        if (route.isActive) route.navigator?.removeRoute(route, false);
      }),
    );
    final result = await Navigator.of(context).push(route) ?? false;
    if (_connectionRoute == route) _connectionRoute = null;
    if (result) request.ensureActive();
    return result;
  }

  /// Asks the page to connect, exactly as a site's own connect button would,
  /// so approval runs through the page's request and [_approveConnection].
  /// [ethereum] asks through `window.ethereum` instead of `window.solana`.
  Future<void> _connectPage({bool ethereum = false, bool tezos = false}) async {
    if ((tezos
                ? _tezosWallet
                : ethereum
                ? _ethereumWallet
                : _wallet) ==
            null ||
        _committed == null) {
      return;
    }
    await _controller?.evaluateJavascript(
      source: tezos
          ? "window.tezos && window.tezos.connect().catch(function(){});"
          : ethereum
          ? "window.ethereum && window.ethereum.request({method:'eth_requestAccounts'}).catch(function(){});"
          : 'window.solana && window.solana.connect().catch(function(){});',
    );
  }

  WalletInfo? _walletForChain(Chain? chain) => switch (chain) {
    Chain.solana => _wallet,
    Chain.ethereum => _ethereumWallet,
    Chain.tezos => _tezosWallet,
    null => null,
  };

  /// A site hint or explicit pick takes priority over another chain's grant.
  WalletInfo? get _displayWallet =>
      _walletForChain(_preferredBrowserChain) ??
      (_solanaConnected ? _wallet : null) ??
      (_ethereumConnected ? _ethereumWallet : null) ??
      (_tezosConnected ? _tezosWallet : null) ??
      _wallet ??
      _ethereumWallet ??
      _tezosWallet;

  bool get _displayWalletConnected => switch (_displayWallet?.chainEnum) {
    Chain.solana => _solanaConnected,
    Chain.ethereum => _ethereumConnected,
    Chain.tezos => _tezosConnected,
    null => false,
  };

  /// Runs before the document can connect. Serializing identity switches
  /// prevents a slower previous navigation from winning over a newer one.
  Future<void> _selectSiteWallet(Uri uri) {
    // A page navigating while the app is locked or away must not switch the
    // app's wallet; [_catchUpSiteWallet] picks one when the user is back.
    if (!isBrowserUrl(uri) || !_attended) return Future.value();
    if (_siteWalletOrigin == uri.origin) return _siteWalletSelection;
    _siteWalletOrigin = uri.origin;
    final revision = ++_siteWalletRevision;
    final tabId = _session.activeId;
    bool current() =>
        mounted &&
        revision == _siteWalletRevision &&
        _session.activeId == tabId;
    return _siteWalletSelection = _siteWalletSelection
        .then((_) async {
          final chain = browserSiteChain(uri);
          if (!current() || chain == null) return;
          await _walletChanged();
          if (!current()) return;
          final identity = _sessionIdentity;
          final accounts = await sl<WalletRepository>().getAccountViews();
          if (!current() || identity != _sessionIdentity) return;
          final selection = selectBrowserSiteWallet(
            chain: chain,
            accounts: accounts,
            currentAccount: _walletSession.activeAccount,
            currentProfile: _walletSession.isProfileMode
                ? _walletSession.activeProfile
                : null,
            preferredWalletId: _walletForChain(chain)?.id,
          );
          if (selection == null) return;
          final pick = BrowserWalletPicked(
            selection.wallet,
            account: selection.account,
            profile: selection.profile,
          );
          if (_isCurrentPick(pick)) {
            setState(() => _preferredBrowserChain = chain);
          } else {
            await _switchWallet(pick);
          }
        })
        .catchError((Object _) {
          if (current()) _showError('Could not select a wallet for this site.');
        });
  }

  /// Picks the wallet for a site the page reached while the app was locked or
  /// away, now that the user is back.
  void _catchUpSiteWallet() {
    final committed = _committed;
    if (_attended &&
        committed != null &&
        isBrowserUrl(committed) &&
        committed.origin != _siteWalletOrigin) {
      unawaited(_selectSiteWallet(committed));
    }
  }

  /// The wallet pill (and the page menu's connection card): pick the Account
  /// or Profile and address the browser uses, or disconnect the committed
  /// site.
  Future<void> _openWalletPicker() async {
    if (_menuIsOpen) return;
    final tab = _session.activeTab;
    final committed = tab?.url == null ? null : _committed;
    final result = await runGuardedSheet<BrowserWalletPickerResult>(
      'browser-wallet-picker',
      () => _menuSheet(
        () => showBrowserWalletPicker(
          context: context,
          selected: _wallet,
          displayWallet: _displayWallet,
          selectedEthereum: _ethereumWallet,
          selectedTezos: _tezosWallet,
          profileMode: _walletSession.isProfileMode,
          activeAccountId: _walletSession.activeAccount?.id,
          activeProfileId: _walletSession.activeProfile?.userId,
          host: committed?.host,
          iconUrl: _tabIcon(committed),
          siteConnected: _solanaConnected,
          ethereumConnected: _ethereumConnected,
          tezosConnected: _tezosConnected,
        ),
      ),
    );
    if (!mounted) return;
    switch (result) {
      case BrowserWalletDisconnect():
        // Disconnect must stay disconnected, so no trusted reconnect runs
        // after it.
        await _menu(BrowserMenuAction.disconnect);
      case BrowserWalletPicked()
          when !_isCurrentPick(result) ||
              result.wallet.id != _displayWallet?.id:
        // A successful switch reconnects trusted sites itself.
        if (!await _switchWallet(result)) {
          unawaited(_restoreTrustedConnection());
        }
      default:
        unawaited(_restoreTrustedConnection());
    }
  }

  /// [pick] is the wallet and the Account or Profile already in use.
  bool _isCurrentPick(BrowserWalletPicked pick) {
    final current = pick.wallet.chainEnum == Chain.tezos
        ? _tezosWallet
        : pick.wallet.chainEnum == Chain.ethereum
        ? _ethereumWallet
        : _wallet;
    if (pick.wallet.id != current?.id) return false;
    final session = _walletSession;
    if (pick.profile case final profile?) {
      return session.isProfileMode &&
          session.activeProfile?.userId == profile.userId;
    }
    return !session.isProfileMode &&
        session.activeAccount?.id == pick.account?.id;
  }

  /// Switches the app's session to [pick]: its Account or Profile when that
  /// is not the current one, then its wallet. False when the switch failed.
  ///
  /// A Solana pick becomes the app's active wallet. An Ethereum or Tezos pick does
  /// not: the app's active wallet stays the session's Solana signer, and the
  /// pick is remembered as the wallet its chain's provider acts for.
  Future<bool> _switchWallet(BrowserWalletPicked pick) async {
    _invalidate();
    final session = _walletSession;
    final wallet = pick.wallet;
    final ethereum = wallet.chainEnum == Chain.ethereum;
    final tezos = wallet.chainEnum == Chain.tezos;
    // No wallet while the switch is in flight: a request the page makes now
    // must not be pinned to the wallet the user just switched away from.
    // [_walletChanged] restores the selection once the session settles.
    setState(() {
      if (tezos) {
        _tezosWallet = null;
      } else if (ethereum) {
        _ethereumWallet = null;
      } else {
        _wallet = null;
      }
      _connected = _solanaConnected = _ethereumConnected = _tezosConnected =
          false;
    });
    _keepTabsOnIdentitySwitch = true;
    try {
      // Remembered first, so the session's own change notification already
      // resolves to the picked wallet.
      if (ethereum && sl.isRegistered<PreferencesService>()) {
        await sl<PreferencesService>().setBrowserEthereumWalletId(wallet.id);
      }
      if (tezos && sl.isRegistered<PreferencesService>()) {
        await sl<PreferencesService>().setBrowserTezosWalletId(wallet.id);
      }
      final preferred = ethereum || tezos ? null : wallet.id;
      if (pick.profile case final profile?) {
        if (!session.isProfileMode ||
            session.activeProfile?.userId != profile.userId) {
          await session.switchToProfile(profile, preferredWalletId: preferred);
        }
      } else if (pick.account case final account?) {
        if (session.isProfileMode || session.activeAccount?.id != account.id) {
          await session.switchToAccount(
            account.id,
            preferredWalletId: preferred,
          );
        }
      }
      if (!ethereum && !tezos) {
        // The switch above settles on a default signer, which may not be the
        // address the user tapped (a view-only one, say).
        final active = await sl<WalletRepository>().getActiveWallet();
        if (active?.id != wallet.id) await session.selectSourceWallet(wallet);
      }
      await _walletChanged();
      if (!mounted) return false;
      setState(() => _preferredBrowserChain = wallet.chainEnum);
      return true;
    } catch (_) {
      _showError('Could not switch wallet. Try again.');
      // The session may have moved part of the way: take the browser's
      // wallet from wherever it settled, not from before the switch.
      try {
        await _walletChanged();
      } catch (_) {
        // The error above already stands for the failed switch.
      }
      return false;
    } finally {
      _keepTabsOnIdentitySwitch = false;
    }
  }

  /// The connection sheet's Switch. The pending request is pinned to the
  /// wallet it was made with, so another pick rejects it, switches, and asks
  /// the page to connect again: the new wallet gets its own request.
  Future<void> _switchFromConnect(
    Route<bool> route,
    DappConnectionRequest request,
  ) async {
    final origin = request.context.origin;
    final ethereum = request.wallet.chains.contains(ethereumMainnet);
    final tezos = request.wallet.chains.contains(tezosMainnet);
    if (!mounted || !route.isActive) return;
    // Not a menu sheet: opening it must not cancel the request beneath it.
    final result = await showBrowserWalletPicker(
      context: context,
      selected: _wallet,
      selectedEthereum: _ethereumWallet,
      selectedTezos: _tezosWallet,
      profileMode: _walletSession.isProfileMode,
      activeAccountId: _walletSession.activeAccount?.id,
      activeProfileId: _walletSession.activeProfile?.userId,
      host: origin.host,
      connectMode: true,
      // The request names its chain; only that chain's wallets can answer it.
      onlyChain: tezos
          ? Chain.tezos
          : ethereum
          ? Chain.ethereum
          : Chain.solana,
    );
    if (!mounted ||
        !route.isActive ||
        result is! BrowserWalletPicked ||
        _isCurrentPick(result)) {
      return;
    }
    route.navigator?.removeRoute(route, false);
    // Only the page that asked gets the new request; a navigation or tab
    // change during the switch drops it.
    if (await _switchWallet(result) &&
        mounted &&
        _active &&
        _isCurrentFrame(request.context)) {
      await _connectPage(ethereum: ethereum, tezos: tezos);
    }
  }

  void _navigate(Uri uri) {
    final id = _session.activeId;
    if (id == null) {
      unawaited(_openTab(uri));
      return;
    }
    _invalidate();
    final controller = _controller;
    if (controller != null) {
      unawaited(
        controller.loadUrl(urlRequest: URLRequest(url: WebUri(uri.toString()))),
      );
    } else {
      _session.navigatePending(id, uri);
      _committed = null;
      _hostRevision++;
    }
    setState(_collapse.reset);
  }

  Future<void> _openTab(Uri? uri) async {
    // The page being left gets a fresh switcher thumbnail first; its WebView
    // is disposed as soon as the new tab becomes active.
    await _captureThumbnail();
    if (!mounted) return;
    try {
      if (uri == null) {
        _session.open(null);
      } else {
        _session.openPending(uri);
      }
    } on StateError catch (error) {
      _showError(error.message);
    }
  }

  Future<void> _address() async {
    if (!_active || _editingAddress) return;
    final tabId = _session.activeId;
    final generation = _generation;
    _addressInitial =
        _committed?.toString() ?? _session.activeTab?.url?.toString() ?? '';
    final result = Completer<Uri?>();
    final uri = await _nativeOverlay(() {
      setState(() {
        _collapse.reset();
        _addressResult = result;
      });
      return result.future;
    });
    if (!mounted) return;
    setState(() => _addressResult = null);
    if (uri != null &&
        _active &&
        _session.activeId == tabId &&
        _generation == generation) {
      _navigate(uri);
    }
  }

  void _finishAddress(Uri? uri) {
    final result = _addressResult;
    if (result == null || result.isCompleted) return;
    FocusScope.of(context).unfocus();
    result.complete(uri);
  }

  Future<void> _history() async {
    final controller = _controller;
    if (controller == null) return;
    final back = await controller.canGoBack();
    final forward = await controller.canGoForward();
    if (mounted && controller == _controller)
      setState(() {
        _canBack = back;
        _canForward = forward;
      });
  }

  Future<void> _back() async {
    if (_editingAddress) {
      _finishAddress(null);
      return;
    }
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      FocusScope.of(context).unfocus();
      return;
    }
    // A first-party page's own sheet is the top layer: back closes it, as a
    // tap on its scrim would, rather than navigating or leaving from under
    // it. A locked sheet may ignore it; see [_setPageOverlay] for the ways
    // out that do not depend on the page.
    if (_forwardScrimTap()) return;
    if (_canBack) {
      _invalidate();
      await _controller?.goBack();
    } else if (mounted)
      Navigator.pop(context);
  }

  void _closeTab(String id) {
    final tab = _session.close(id);
    final last = _session.tabs.isEmpty;
    if (tab != null && mounted) {
      BrowserUndoToast.show(
        context,
        'Tab closed',
        onUndo: () => _session.restore(tab),
      );
    }
    if (last && mounted) _exitBrowser();
  }

  /// Leaves the browser from under any overlay of its own (the tab switcher).
  void _exitBrowser() {
    final route = _pageRoute;
    final navigator = route?.navigator;
    if (route == null || navigator == null || !route.isActive) return;
    navigator.popUntil((candidate) => identical(candidate, route));
    navigator.pop();
  }

  bool get _canCaptureThumbnail =>
      _unlocked && _visibility.retainWebView && !_visibility.coverWebView;

  /// Screenshots the active page for the tab switcher: JPEG, at most 360 px
  /// wide, memory only. Never while the app is locked or the page is covered.
  Future<void> _captureThumbnail() async {
    final controller = _controller;
    final tabId = _session.activeId;
    if (!mounted ||
        controller == null ||
        tabId == null ||
        _session.activeTab?.url == null ||
        !_canCaptureThumbnail) {
      return;
    }
    final ratio = MediaQuery.devicePixelRatioOf(context);
    try {
      final bytes = await controller.takeScreenshot(
        screenshotConfiguration: ScreenshotConfiguration(
          compressFormat: CompressFormat.JPEG,
          quality: 70,
          // In points; both platforms scale it by the screen's pixel ratio.
          snapshotWidth: 360 / ratio,
        ),
      );
      // The app may have locked, or the tab changed, while the capture ran.
      if (bytes == null ||
          !mounted ||
          !_canCaptureThumbnail ||
          controller != _controller ||
          tabId != _session.activeId) {
        return;
      }
      _session.setThumbnail(tabId, bytes);
    } catch (_) {
      // Cosmetic: the switcher falls back to the site tile.
    }
  }

  /// Connects to the WalletConnect code the page is showing, which saves
  /// copying its link out of the tab. Under the same conditions as the
  /// thumbnail: never while the app is locked or the page is covered.
  Future<void> _scanPageCode() async {
    final controller = _controller;
    if (!mounted || controller == null || !_canCaptureThumbnail) return;
    String? code;
    try {
      final png = await controller.takeScreenshot(
        screenshotConfiguration: ScreenshotConfiguration(
          compressFormat: CompressFormat.PNG,
        ),
      );
      if (png != null &&
          mounted &&
          controller == _controller &&
          _canCaptureThumbnail) {
        code = walletConnectCodeIn(await decodePageCodes(png));
      }
    } catch (_) {
      // Reported below as no code found.
    }
    if (!mounted || !_canCaptureThumbnail) return;
    if (code == null) {
      AppSnackBar.show(
        context,
        'No WalletConnect code found on this page',
        type: AppSnackBarType.error,
      );
      return;
    }
    handleWalletConnectText(code);
  }

  void _scheduleThumbnail() {
    _thumbnailTimer?.cancel();
    // Load stop fires before the first paint of late content settles.
    _thumbnailTimer = Timer(
      const Duration(milliseconds: 700),
      () => unawaited(_captureThumbnail()),
    );
  }

  Future<Set<String>> _connectedTabIds() async {
    final addresses = {
      ?_wallet?.address,
      ?_ethereumWallet?.address,
      ?_tezosWallet?.address,
    };
    if (addresses.isEmpty) return const {};
    try {
      final grants = await browserPermissions.list();
      final origins = {
        for (final grant in grants)
          if (addresses.contains(grant.address)) grant.origin,
      };
      return {
        for (final tab in _session.tabs)
          if (tab.url != null && origins.contains(tab.url!.origin)) tab.id,
      };
    } catch (_) {
      return const {};
    }
  }

  Future<void> _tabs() async {
    final picked = await runGuardedSheet<String>('browser-tabs', () async {
      unawaited(_captureThumbnail());
      final connected = await _connectedTabIds();
      if (!mounted) return null;
      return _nativeOverlay(
        () => Navigator.of(context).push(
          browserTabSwitcherRoute(
            session: _session,
            connectedTabs: connected,
            onClose: _closeTab,
          ),
        ),
      );
    });
    if (!mounted || picked == null) return;
    if (picked == browserNewTab) {
      await _openTab(null);
    } else if (picked != _session.activeId) {
      _session.select(picked);
    }
  }

  void _menuOpened() {
    _invalidate();
    _menuIsOpen = true;
    _visibility.nativeOverlays++;
  }

  void _menuClosed() {
    if (!_menuIsOpen) return;
    _menuIsOpen = false;
    _visibility.nativeOverlays--;
  }

  /// The menu's own overlay bookkeeping: unlike [_nativeOverlay] it leaves
  /// the trusted reconnect to the caller, so Disconnect never reconnects the
  /// site on its way out.
  Future<T?> _menuSheet<T>(Future<T?> Function() show) async {
    _menuOpened();
    try {
      return await show();
    } finally {
      _menuClosed();
    }
  }

  Future<void> _restoreTrustedConnection() async {
    await _refreshConnection();
    if (!_active || !_connected) return;
    try {
      await _controller?.evaluateJavascript(source: _restoreScript);
    } catch (_) {
      // A closing or navigating WebView no longer has a JavaScript context.
    }
  }

  Uri? _tabIcon(Uri? committed) {
    final tab = _session.activeTab;
    return committed != null && tab?.url?.host == committed.host
        ? tab?.iconUrl
        : null;
  }

  bool get _loading {
    final tab = _session.activeTab;
    return tab != null &&
        (tab.url != null || _session.pendingUrl(tab.id) != null) &&
        _progress < 100;
  }

  Future<void> _openMenu() async {
    if (_menuIsOpen) return;
    final tab = _session.activeTab;
    final committed = tab?.url == null ? null : _committed;
    final action = await runGuardedSheet<BrowserMenuAction>(
      'browser-page-menu',
      () => _menuSheet(
        () => showMallowSheet<BrowserMenuAction>(
          context: context,
          isScrollControlled: true,
          builder: (_) => BrowserPageMenu(
            url: committed,
            title: tab?.title ?? '',
            iconUrl: _tabIcon(committed),
            bookmarked:
                committed != null &&
                _session.bookmarks.any((b) => b.url == committed),
            loading: _loading,
            wallet: _displayWallet,
            connected: _displayWalletConnected,
            notSecure: _notSecure(committed),
            canScanCode: WalletConnectService.instance != null,
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == null) {
      unawaited(_restoreTrustedConnection());
    } else if (action == BrowserMenuAction.wallet) {
      await _openWalletPicker();
    } else {
      await _runAction(action);
    }
  }

  Future<void> _runAction(BrowserMenuAction action) async {
    await _menu(action);
    // Navigation/settings recreate the provider; disconnect must stay disconnected.
    if (action == BrowserMenuAction.bookmark ||
        action == BrowserMenuAction.share ||
        action == BrowserMenuAction.stop ||
        action == BrowserMenuAction.copyLink ||
        action == BrowserMenuAction.scanPageCode)
      await _restoreTrustedConnection();
  }

  Future<void> _menu(BrowserMenuAction action) async {
    final uri = _committed;
    if (action == BrowserMenuAction.bookmark && uri != null) {
      final removed = _session.removeBookmark(uri);
      if (removed != null) {
        BrowserUndoToast.show(
          context,
          'Bookmark removed',
          onUndo: () => _session.restoreBookmark(removed),
        );
      } else {
        _session.bookmark(
          BrowserBookmark(
            url: uri,
            title: _session.activeTab?.title.isNotEmpty == true
                ? _session.activeTab!.title
                : uri.host,
            iconUrl: _session.activeTab?.url?.host == uri.host
                ? _session.activeTab?.iconUrl
                : null,
          ),
        );
      }
    }
    if (action == BrowserMenuAction.reload) {
      _invalidate();
      await _controller?.reload();
    }
    if (action == BrowserMenuAction.stop) {
      _invalidate();
      await _controller?.stopLoading();
    }
    if (action == BrowserMenuAction.newTab) await _openTab(null);
    if (action == BrowserMenuAction.copyLink && uri != null) {
      await Clipboard.setData(ClipboardData(text: uri.toString()));
      if (mounted) AppSnackBar.show(context, 'Link copied');
    }
    if (action == BrowserMenuAction.scanPageCode && uri != null) {
      await _scanPageCode();
    }
    if (action == BrowserMenuAction.close && _session.activeId != null)
      _closeTab(_session.activeId!);
    if (action == BrowserMenuAction.settings && mounted) {
      await _nativeOverlay(
        () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => const BrowserSettingsScreen(),
          ),
        ),
      );
    }
    if (action == BrowserMenuAction.disconnect && uri != null) {
      // One Disconnect covers the site: every selected chain's grant goes.
      await browserPermissions.revokeAll(uri.origin, {
        ?_wallet?.address,
        ?_ethereumWallet?.address,
        ?_tezosWallet?.address,
      });
    }
    if (action == BrowserMenuAction.share && uri != null && mounted) {
      final accepted = await _nativeOverlay(
        () => showMallowSheet<bool>(
          context: context,
          isScrollControlled: true,
          builder: (_) => BrowserShareSheet(url: uri),
        ),
      );
      if (accepted == true && mounted) {
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            uri: uri,
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      }
    }
  }

  /// Opens the preferred explorer in the system browser view, on the cluster
  /// the transaction was sent to.
  Future<void> _viewTransaction(BrowserTransactionRecord record) async {
    var url = Uri.parse(
      buildTxExplorerUrlForChain(
        record.signature,
        record.chain == tezosMainnet
            ? Chain.tezos
            : record.chain == ethereumMainnet
            ? Chain.ethereum
            : Chain.solana,
      ),
    );
    if (record.chain != ethereumMainnet) {
      final query = Map<String, String>.of(url.queryParameters)
        ..remove('cluster');
      if (record.chain == 'solana:devnet') query['cluster'] = 'devnet';
      url = Uri(
        scheme: url.scheme,
        host: url.host,
        path: url.path,
        queryParameters: query.isEmpty ? null : query,
      );
    }
    try {
      final launched = await launchUrl(url, mode: LaunchMode.inAppBrowserView);
      if (!launched) _showError('Could not open the transaction explorer.');
    } catch (_) {
      _showError('Could not open the transaction explorer.');
    }
  }

  void _syncBarCollapse(bool compact, {Curve curve = MallowTheme.sheetCurve}) {
    if (compact == _barCompact) return;
    _barCompact = compact;
    final target = compact ? 1.0 : 0.0;
    if (context.reduceMotion) {
      _barCollapse.value = target;
    } else {
      // From wherever the bar is, so a reversal mid-way stays continuous.
      _barCollapse.animateTo(
        target,
        duration: MallowTheme.sheetDuration,
        curve: curve,
      );
    }
  }

  /// Dims the chrome in step with the page's own sheet scrim: the same
  /// duration and curves as the page's sheets, from wherever it is.
  ///
  /// Only the page releases it, and there is deliberately no native timeout:
  /// a sheet locked while its transaction is pending ignores scrim taps and
  /// back on purpose. A page that never releases is still left behind by
  /// anything that ends the document's claim in [_invalidate]: navigating
  /// (a link in the page, or the page's own reload), or leaving the app and
  /// coming back, which recreates the WebView.
  void _setPageOverlay(bool active) {
    if (active == _pageOverlay || !mounted) return;
    _pageOverlay = active;
    final target = active ? 1.0 : 0.0;
    if (context.reduceMotion) {
      _overlay.value = target;
    } else if (active) {
      _overlay.animateTo(
        target,
        duration: MallowTheme.sheetDuration,
        curve: Curves.easeOutCubic,
      );
    } else {
      // Backwards, so it ends dismissed (animateTo always ends completed).
      _overlay.animateBack(
        target,
        duration: MallowTheme.sheetDuration,
        curve: Curves.easeInCubic,
      );
    }
    setState(() {});
  }

  void _uiCommand(BrowserUiCommand command, DappFrameContext frame) {
    if (!_isCurrentFrame(frame) ||
        !isFirstPartyOrigin(_committed, Config.environment))
      return;
    switch (command) {
      case BrowserUiSetOverlay(active: true):
        // Not while the wallet's own overlay covers the page.
        if (_active) _setPageOverlay(true);
      case BrowserUiSetOverlay(active: false):
        _setPageOverlay(false);
    }
  }

  /// A tap on the dimmed chrome belongs to the page's sheet, as a tap on its
  /// own scrim would; the chrome itself does nothing.
  void _scrimTapped() => _forwardScrimTap();

  /// Hands a dismissal to the page's sheet while it holds the chrome, and
  /// says whether it did.
  bool _forwardScrimTap() {
    final controller = _controller;
    if (!_pageOverlay || controller == null) return false;
    if (!isFirstPartyOrigin(_committed, Config.environment)) return false;
    unawaited(
      controller
          .evaluateJavascript(source: browserUiScrimTapScript)
          .then<void>((_) {}, onError: (Object _) {}),
    );
    return true;
  }

  void _scrolled(int y) {
    if (mounted && _collapse.scrolled(y)) setState(() {});
  }

  BrowserWalletPillState get _walletState => _displayWallet == null
      ? BrowserWalletPillState.none
      : _committed != null &&
            _session.activeTab?.url != null &&
            _displayWalletConnected
      ? BrowserWalletPillState.connected
      : BrowserWalletPillState.disconnected;

  /// Hands the bars' heights to the WebView as obscured insets once this
  /// frame is laid out, and again whenever they, the WebView's frame or the
  /// WebView itself change. A platform view that is not attached yet takes
  /// none; that is retried a few times.
  void _scheduleInsets(double top, double bottom) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final box = _webViewKey.currentContext?.findRenderObject() as RenderBox?;
      final controller = _controller;
      if (!mounted || box == null || !box.hasSize || controller == null) {
        return;
      }
      final frame = box.localToGlobal(Offset.zero) & box.size;
      final next = (frame, top, bottom, controller);
      if (next == _appliedInsets) return;
      _appliedInsets = next;
      final applied = await BrowserObscuredInsets.apply(
        frame,
        top: top,
        bottom: bottom,
      );
      if (applied > 0 || !mounted || _appliedInsets != next) {
        _insetRetries = 0;
        return;
      }
      _appliedInsets = null;
      if (_insetRetries++ < 10) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (mounted) setState(() {});
      }
    });
  }

  /// Fades [child] in with the browser's entrance, sliding from [from].
  Widget _entering(Offset from, Widget child) => FadeTransition(
    opacity: _entrance,
    child: SlideTransition(
      position: Tween<Offset>(begin: from, end: Offset.zero).animate(
        CurvedAnimation(parent: _entrance, curve: MallowTheme.sheetCurve),
      ),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tab = _session.activeTab;
    final colors = context.mallowColors;
    final safe = MediaQuery.paddingOf(context);
    // Only the page's own keyboard reshapes the layout. One raised by a
    // native sheet or the inline address editor leaves the WebView in place,
    // including while it slides away after editing ends.
    final insets = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (_visibility.nativeOverlays > 0 && insets) _sheetKeyboard = true;
    if (!insets) _sheetKeyboard = false;
    final overlaid = _visibility.nativeOverlays > 0 || _sheetKeyboard;
    final keyboard = insets && !overlaid;
    final requested = tab == null ? null : _session.pendingUrl(tab.id);
    final page = tab?.url != null || requested != null;
    final pageOverlay = _pageOverlay && page;
    // The WebView takes the bottom bar's strip as soon as the page claims the
    // chrome, and gives it back only once the bar has returned, so the page's
    // sheet never jumps while it moves.
    final overlayLayout = page && (_pageOverlay || !_overlay.isDismissed);
    final compact =
        !_editingAddress && (_collapse.compact || pageOverlay) && page;
    // While the page releases the chrome, the address bar eases back in on
    // the scrim's curve.
    _syncBarCollapse(
      compact,
      curve: overlayLayout && !_pageOverlay
          ? Curves.easeInCubic
          : MallowTheme.sheetCurve,
    );
    // The bars are transparent and the area they cover is unsafe for the
    // page: dapps put their main button at the bottom. Where the WebView can
    // be told so (_underChrome) it spans the screen and takes the bars'
    // heights as obscured insets, so content scrolls under the bars while
    // fixed elements stay clear of them; elsewhere it is laid out between
    // the bars, except that on Android it runs under the bottom bar while a
    // probe finds that safe for the page (_underBottomBar). The compact
    // address bar covers less either way, and the WebView follows it as it
    // shrinks (see the AnimatedBuilder below).
    // A page sheet uses the keyboard's layout: no bar, and (iOS 26) no bottom
    // obscured inset, so the sheet reaches the screen's edge. On iOS the
    // WebView's own safe area then reaches the page, whose
    // env(safe-area-inset-bottom) padding keeps the sheet's buttons clear of
    // the home indicator. Android's WebView reports no such inset here, so
    // there the strip of the system navigation bar stays reserved: it shows
    // the page's colour under the chrome scrim, and the sheet ends above it
    // instead of under the navigation buttons or gesture area.
    final overlayInset =
        overlayLayout && defaultTargetPlatform == TargetPlatform.android
        ? MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    final reserved = keyboard
        ? 0.0
        : overlayLayout
        ? overlayInset
        : BrowserBottomBar.height(context);
    final underChrome = _underChrome && page;
    final committed = page ? _committed : null;
    final walletState = _walletState;
    final hostKey = page ? '${tab!.id}:$_hostRevision' : null;
    if (_unlocked) _unlockedHost = hostKey;
    // Whether the page's WebView may exist. The lock only hides the one that
    // was open, so unlocking returns to the page as it was left.
    final hosted =
        _visibility.retainWebView &&
        !_openingInitialUrl &&
        _remote.config.value.browserEnabled &&
        (_unlocked || hostKey == _unlockedHost);
    final covered = !hosted || !_unlocked;
    final startPage = !page && !covered;
    // Between the bars, the strips around the WebView take the page's own
    // colour, so the pills float over the page rather than over a band of the
    // wallet's background. Under the bars the page shows there itself, and
    // its colour still picks the system bars' icons: the fill spans the
    // screen, so its region decides them under both bars.
    final pageColor = page && !covered && !_visibility.coverWebView
        ? _pageColor
        : null;
    final fill = underChrome ? null : pageColor;
    // Not !covered: a lock must not resize the page it keeps.
    final underBottomBar = _underBottomBar && page && hosted;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: colors.bgPrimary,
        resizeToAvoidBottomInset: !overlaid,
        body: Stack(
          children: [
            Positioned.fill(
              child: AnnotatedRegion<SystemUiOverlayStyle>(
                value: MallowTheme.systemBarsOver(
                  ThemeData.estimateBrightnessForColor(
                    pageColor ?? colors.bgPrimary,
                  ),
                ),
                child: AnimatedContainer(
                  duration: context.reduceMotion
                      ? Duration.zero
                      : MallowTheme.sheetDuration,
                  color: fill ?? colors.bgPrimary,
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _barCollapse,
              builder: (context, child) {
                final top =
                    safe.top + BrowserAddressBar.heightAt(_barCollapse.value);
                if (underChrome) _scheduleInsets(top, reserved);
                return Positioned(
                  left: 0,
                  right: 0,
                  // A blank tab's start page holds its own search field in
                  // the address bar's slot.
                  top: underChrome || startPage ? 0 : top,
                  bottom: underChrome || (underBottomBar && !overlayLayout)
                      ? 0
                      : reserved,
                  child: child!,
                );
              },
              child: Stack(
                key: _webViewKey,
                fit: StackFit.expand,
                children: [
                  !hosted
                      ? const BrowserLockCover()
                      : !page
                      ? BrowserStartScreen(
                          inBrowser: true,
                          onOpen: _navigate,
                          onOpenNewTab: (uri) => unawaited(_openTab(uri)),
                        )
                      : BrowserWebViewHost(
                          key: ValueKey(hostKey),
                          tabId: tab!.id,
                          url: requested ?? tab.url!,
                          onController: (controller) {
                            _controller = controller;
                            _setPageOverlay(false);
                            _appliedInsets = null;
                            _insetRetries = 0;
                            _pageColor = _rememberedColor(requested ?? tab.url);
                            _underBottomBar = false;
                            if (mounted) setState(() {});
                          },
                          beforeNavigation: _selectSiteWallet,
                          onNavigationStarted: (generation) {
                            if (_generation != generation) {
                              // The controller may already point to the
                              // new document. Cancel native work without
                              // rejecting that page's startup connect.
                              _invalidate(notifyPage: false);
                              // A new document starts with the full bar.
                              if (mounted) setState(_collapse.reset);
                            }
                            _generation = generation;
                            _progress = 0;
                          },
                          onNavigation: (generation, uri) {
                            if (generation != _generation) return;
                            final previous = _committed;
                            _committed = uri;
                            if (_originOf(uri) != _originOf(previous)) {
                              final color = _rememberedColor(uri);
                              if (mounted && color != _pageColor) {
                                setState(() => _pageColor = color);
                              }
                            }
                            // Re-send the insets for every document: a replaced WebView
                            // may attach after an apply matched its predecessor.
                            _appliedInsets = null;
                            if (uri != null && isBrowserUrl(uri)) {
                              // On another host, start from what was last
                              // seen there, so a return visit shows the
                              // site's name and icon before the page
                              // reports its own.
                              final sameHost = previous?.host == uri.host;
                              final site = sameHost ? null : _session.site(uri);
                              _session.update(
                                tab.id,
                                url: uri,
                                title: sameHost
                                    ? null
                                    : site?.title.isNotEmpty == true
                                    ? site!.title
                                    : uri.host,
                                iconUrl: site?.iconUrl,
                              );
                            }
                            _history();
                            _refreshConnection();
                          },
                          onRequest: (message, frame) async {
                            final result = await _coordinator.handle(
                              message,
                              frame,
                            );
                            final params = message['params'];
                            final silentEthereumConnect =
                                message['namespace'] == 'eip155' &&
                                message['method'] == 'connect' &&
                                params is Map &&
                                params['silent'] == true;
                            // Reads and account polls cannot change a grant.
                            if (message['method'] != 'read' &&
                                !silentEthereumConnect) {
                              await _refreshConnection();
                            }
                            return result;
                          },
                          onProgress: (progress) {
                            if (mounted) setState(() => _progress = progress);
                            if (progress == 100) _history();
                          },
                          onTitle: (title) =>
                              _session.update(tab.id, title: title),
                          onFavicon: (icon) =>
                              _session.update(tab.id, iconUrl: icon),
                          onPageColor: (color) {
                            if (_committed case final url?) {
                              _rememberColor(url, color);
                            }
                            if (mounted && color != _pageColor) {
                              setState(() => _pageColor = color);
                            }
                          },
                          // No bar to run under while a page sheet is up.
                          bottomBand:
                              defaultTargetPlatform == TargetPlatform.android &&
                                  _visibility.canReceiveRequests &&
                                  !overlayLayout
                              ? reserved
                              : 0,
                          onBottomOverlay: (under) {
                            if (mounted)
                              setState(() => _underBottomBar = under);
                          },
                          onScrollChanged: _scrolled,
                          onLoadStop: _scheduleThumbnail,
                          onPopup: (uri) {
                            if (_active && _pageRoute?.isCurrent == true)
                              unawaited(_openTab(uri));
                          },
                          onError: _showError,
                          onAppLink: _openAppLink,
                          onCertificateDeclined: () => _closeTab(tab.id),
                          canPrompt: () => _attended,
                          onProcessGone: _webViewGone,
                          onUiCommand: _uiCommand,
                        ),
                  if (hosted && (_visibility.coverWebView || !_unlocked))
                    const AbsorbPointer(child: BrowserLockCover()),
                ],
              ),
            ),
            if (!keyboard && !_editingAddress)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _entering(
                  const Offset(0, 0.12),
                  _steppingAside(
                    BrowserBottomBar(
                      host: committed?.host,
                      canBack: _canBack,
                      canForward: _canForward,
                      tabCount: _session.tabs.length,
                      wallet: _displayWallet,
                      walletState: walletState,
                      onMinimise: () => Navigator.pop(context),
                      onBack: () {
                        _invalidate();
                        _controller?.goBack();
                      },
                      onForward: () {
                        _invalidate();
                        _controller?.goForward();
                      },
                      onTabs: _tabs,
                      onMenu: _openMenu,
                      onWallet: _openWalletPicker,
                    ),
                  ),
                ),
              ),
            if (_editingAddress)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => _finishAddress(null),
                  child: ColoredBox(color: colors.scrim),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: _entering(
                const Offset(0, -0.12),
                BrowserTransactionToast(
                  tracker: BrowserTransactionTracker.instance,
                  onView: _viewTransaction,
                  // It would hang below the dimmed band, bright and live,
                  // over the page's scrim; it returns once the page lets go.
                  suppressed: pageOverlay || _editingAddress,
                  child: Stack(
                    children: [
                      if (_editingAddress)
                        Padding(
                          padding: EdgeInsets.fromLTRB(12, safe.top + 6, 12, 6),
                          child: MediaQuery.withClampedTextScaling(
                            maxScaleFactor: 1.5,
                            child: BrowserAddressField(
                              initial: _addressInitial,
                              onOpen: _finishAddress,
                            ),
                          ),
                        )
                      else if (startPage)
                        SizedBox(
                          height: safe.top + BrowserAddressBar.expandedHeight,
                        )
                      else
                        BrowserAddressBar(
                          compact: compact,
                          collapse: _barCollapse,
                          host: committed?.host,
                          iconUrl: _tabIcon(committed),
                          notSecure: _notSecure(committed),
                          blank: !page,
                          loading: _loading,
                          onAddress: _address,
                          onTabs: _tabs,
                          onReloadOrStop: () => _runAction(
                            _loading
                                ? BrowserMenuAction.stop
                                : BrowserMenuAction.reload,
                          ),
                          onExpand: () {
                            if (_collapse.set(false, force: true))
                              setState(() {});
                          },
                        ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: BrowserProgressHairline(
                          progress: page ? _progress : 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (page)
              _chromeScrim(
                safe.top,
                colors.scrim,
                // The page and its scrim are hidden behind the lock cover.
                shown: !covered && !_visibility.coverWebView,
              ),
            if (page && overlayInset > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: overlayInset,
                child: ExcludeSemantics(
                  child: _scrimLayer(
                    browserChromeBottomScrimKey,
                    colors.scrim,
                    shown: !covered && !_visibility.coverWebView,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The bottom bar slides down and fades while a page sheet is up.
  Widget _steppingAside(Widget bar) => AnimatedBuilder(
    animation: _overlay,
    builder: (context, child) {
      final t = _overlay.value;
      return IgnorePointer(
        ignoring: _pageOverlay,
        child: FractionalTranslation(
          translation: Offset(0, t),
          child: Opacity(opacity: 1 - t, child: child),
        ),
      );
    },
    child: bar,
  );

  /// The page's own sheet scrim covers the WebView; this covers everything
  /// of the wallet's above it (the status bar strip and the address bar), so
  /// the two read as one full-screen layer. It spans exactly the strip the
  /// WebView leaves, or is told is obscured, under the address bar.
  Widget _chromeScrim(double safeTop, Color scrim, {required bool shown}) =>
      AnimatedBuilder(
        animation: _barCollapse,
        builder: (context, child) => Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: safeTop + BrowserAddressBar.heightAt(_barCollapse.value),
          child: child!,
        ),
        child: _scrimLayer(browserChromeScrimKey, scrim, shown: shown),
      );

  /// One piece of the chrome scrim: faded with [_overlay], and while the page
  /// holds the chrome, a tap on it goes to the page's sheet.
  Widget _scrimLayer(Key key, Color scrim, {required bool shown}) =>
      AnimatedBuilder(
        animation: _overlay,
        builder: (context, _) {
          final t = shown ? _overlay.value : 0.0;
          final active = shown && _pageOverlay;
          return IgnorePointer(
            ignoring: !active,
            child: Semantics(
              excludeSemantics: true,
              button: active,
              label: active ? 'Dismiss' : null,
              onTap: active ? _scrimTapped : null,
              child: GestureDetector(
                key: key,
                behavior: HitTestBehavior.opaque,
                onTap: _scrimTapped,
                child: Opacity(
                  opacity: t,
                  child: ColoredBox(color: scrim),
                ),
              ),
            ),
          );
        },
      );
}
