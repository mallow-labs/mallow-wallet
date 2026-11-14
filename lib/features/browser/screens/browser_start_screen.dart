import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../../../core/models/account.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/utils/address_format.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sliver_overscroll_anchored.dart';
import '../../../shared/widgets/tappable.dart';
import '../../cast/services/cast_bloc.dart';
import '../../cast/widgets/now_casting_bar.dart';
import '../models/browser_models.dart';
import '../services/browser_services.dart';
import '../services/browser_session.dart';
import '../services/browser_suggestions.dart';
import '../services/dapp_permission_service.dart';
import '../widgets/bookmark_sheets.dart';
import '../widgets/browser_address_bar.dart';
import '../widgets/browser_suggestion_list.dart';
import '../widgets/browser_tab_switcher.dart';
import '../widgets/browser_undo_toast.dart';
import '../widgets/start_bookmark_grid.dart';
import '../widgets/start_continue_card.dart';
import '../widgets/start_site_grid.dart';
import 'browser_screen.dart';
import 'browser_settings_screen.dart';

class BrowserStartScreen extends StatefulWidget {
  const BrowserStartScreen({
    super.key,
    this.inBrowser = false,
    this.onOpen,
    this.onOpenNewTab,
    this.session,
    this.activeWallet,
    this.permissions,
    this.walletRepository,
  });
  final BrowserSession? session;
  final bool inBrowser;
  final ValueChanged<Uri>? onOpen;
  final ValueChanged<Uri>? onOpenNewTab;

  /// The Solana wallet a site would see. Defaults to the app's active wallet
  /// when it is a Solana wallet of the current session.
  final Future<WalletInfo?> Function()? activeWallet;
  final DappPermissionService? permissions;
  final WalletRepository? walletRepository;
  @override
  State<BrowserStartScreen> createState() => _BrowserStartScreenState();
}

class _BrowserStartScreenState extends State<BrowserStartScreen> {
  final _address = TextEditingController();
  final _focus = FocusNode();
  late final _session = widget.session ?? BrowserSession.instance;
  late final _permissions = widget.permissions ?? browserPermissions;
  late final _walletRepository =
      widget.walletRepository ??
      (sl.isRegistered<WalletRepository>() ? sl<WalletRepository>() : null);
  StreamSubscription<void>? _grants;
  SessionManager? _walletSession;
  Set<Chain> _walletChains = const {};
  int _walletChainsRevision = 0;
  String? _inputError;
  bool _reorderingBookmarks = false;

  /// The connection shown on the continue card, for [_connectionOrigin].
  String? _connectedWallet;
  String? _connectionOrigin;
  int _connectionRevision = 0;

  @override
  void initState() {
    super.initState();
    _session.load();
    unawaited(browserSites.start());
    _walletRepository?.walletsRevision.addListener(_refreshWalletChains);
    _refreshWalletChains();
    if (widget.inBrowser) return;
    _session.addListener(_tabChanged);
    _grants = _permissions.changes.listen((_) => _refreshConnection());
    if (widget.activeWallet == null && sl.isRegistered<SessionManager>()) {
      _walletSession = sl<SessionManager>()..addListener(_refreshConnection);
    }
    _refreshConnection();
  }

  @override
  void dispose() {
    _session.removeListener(_tabChanged);
    _walletSession?.removeListener(_refreshConnection);
    _walletRepository?.walletsRevision.removeListener(_refreshWalletChains);
    _grants?.cancel();
    _address.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _refreshWalletChains() async {
    final revision = ++_walletChainsRevision;
    Set<Chain> chains = const {};
    try {
      final wallets = await _walletRepository?.getAllWallets() ?? const [];
      chains = wallets.map((wallet) => wallet.chainEnum).toSet();
    } catch (_) {
      // Hide optional catalogs when local wallet availability is unknown.
    }
    if (!mounted || revision != _walletChainsRevision) return;
    if (!setEquals(chains, _walletChains)) {
      setState(() => _walletChains = chains);
    }
  }

  String? get _activeOrigin {
    final url = _session.activeTab?.url;
    return url != null && isBrowserUrl(url) ? url.origin : null;
  }

  void _tabChanged() {
    if (_activeOrigin != _connectionOrigin) _refreshConnection();
  }

  Future<WalletInfo?> _resolveWallet() async {
    if (widget.activeWallet case final resolve?) return resolve();
    final session = _walletSession;
    if (session == null || !sl.isRegistered<WalletRepository>()) return null;
    final active = await sl<WalletRepository>().getActiveWallet();
    return session.sessionWallets
        .where((w) => w.chainEnum == Chain.solana && w.id == active?.id)
        .firstOrNull;
  }

  /// Read-only mirror of the browser's connection check: the site is
  /// connected when the active Solana wallet holds a grant for its origin.
  Future<void> _refreshConnection() async {
    final revision = ++_connectionRevision;
    final origin = _activeOrigin;
    // Never show the previous site's connection beside a new origin while
    // the lookup below is in flight.
    if (origin != _connectionOrigin) _connectedWallet = null;
    _connectionOrigin = origin;
    String? name;
    try {
      final wallet = origin == null ? null : await _resolveWallet();
      if (wallet != null &&
          await _permissions.isGranted(origin!, wallet.address)) {
        name =
            _walletSession?.ownerNameFor(wallet.address) ??
            truncateAddress(wallet.address, lead: 4, trail: 4);
      }
    } catch (_) {
      // The card simply shows no connection; the browser reports errors.
    }
    if (!mounted || revision != _connectionRevision) return;
    if (name != _connectedWallet) setState(() => _connectedWallet = name);
  }

  /// Opens [value]. [typed] when the user typed it or picked it from the
  /// suggestions: an address, as opposed to a search, is then remembered for
  /// them once it loads.
  void _open(String value, {bool typed = false}) {
    try {
      final uri = browserInputUri(value, engine: browserSearchEngine.value);
      if (typed && browserAddressUri(value) != null) _session.noteTyped(uri);
      if (widget.onOpen != null) {
        widget.onOpen!(uri);
        return;
      }
      _session.openPending(uri);
      _resume();
    } on FormatException catch (error) {
      setState(() => _inputError = error.message);
    } on StateError catch (error) {
      setState(() => _inputError = error.message);
    }
  }

  void _openNewTab(Uri uri) {
    try {
      if (widget.onOpenNewTab != null) {
        widget.onOpenNewTab!(uri);
        return;
      }
      _session.openPending(uri);
      _resume();
    } on StateError catch (error) {
      setState(() => _inputError = error.message);
    }
  }

  void _resume() => Navigator.of(context).push(BrowserScreen.route());

  /// The browser's own check for the switcher's connected-tab dots: tabs
  /// whose origin the active Solana wallet has granted.
  Future<Set<String>> _connectedTabIds() async {
    try {
      final wallet = await _resolveWallet();
      if (wallet == null) return const {};
      final origins = {
        for (final grant in await _permissions.list())
          if (grant.address == wallet.address) grant.origin,
      };
      return {
        for (final tab in _session.tabs)
          if (tab.url != null && origins.contains(tab.url!.origin)) tab.id,
      };
    } catch (_) {
      return const {};
    }
  }

  /// The tab switcher over the start page. Done comes back here; a picked
  /// tab, or a new one, opens in the browser.
  Future<void> _showTabs() async {
    final picked = await runGuardedSheet<String>('browser-tabs', () async {
      final connected = await _connectedTabIds();
      if (!mounted) return null;
      final navigator = Navigator.of(context);
      late final Route<String> route;
      route = browserTabSwitcherRoute(
        session: _session,
        connectedTabs: connected,
        onClose: (id) {
          final tab = _session.close(id);
          if (tab != null && mounted) {
            BrowserUndoToast.show(
              context,
              'Tab closed',
              onUndo: () => _session.restore(tab),
            );
          }
          // Nothing left to switch to: back to the start page.
          if (_session.tabs.isEmpty && route.isActive) {
            navigator.popUntil((candidate) => identical(candidate, route));
            navigator.pop();
          }
        },
      );
      return navigator.push(route);
    });
    if (!mounted || picked == null) return;
    try {
      if (picked == browserNewTab) {
        _session.open(null);
      } else {
        _session.select(picked);
      }
    } on StateError catch (error) {
      setState(() => _inputError = error.message);
      return;
    }
    _resume();
  }

  void _settings() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const BrowserSettingsScreen()),
  );

  Future<void> _bookmarkActions(BrowserBookmark bookmark) async {
    final action = await showBookmarkActionsSheet(context, bookmark);
    if (!mounted) return;
    switch (action) {
      case BookmarkAction.openInNewTab:
        _openNewTab(bookmark.url);
      case BookmarkAction.edit:
        final edited = await showBookmarkEditSheet(context, bookmark);
        if (edited != null) _session.bookmark(edited, replacing: bookmark.url);
      case BookmarkAction.remove:
        final removed = _session.removeBookmark(bookmark.url);
        if (removed != null) {
          BrowserUndoToast.show(
            context,
            'Bookmark removed',
            onUndo: () => _session.restoreBookmark(removed),
          );
        }
      case BookmarkAction.reorder:
        _focus.unfocus();
        setState(() => _reorderingBookmarks = true);
      case null:
        break;
    }
  }

  Widget _searchField(MallowColors colors) => MallowPillField(
    controller: _address,
    focusNode: _focus,
    hintText: 'Search or enter website',
    errorText: _inputError,
    keyboardType: TextInputType.url,
    textInputAction: TextInputAction.go,
    autocorrect: false,
    enableSuggestions: false,
    height: _fieldHeight,
    padding: const EdgeInsets.only(left: 18, right: 4),
    backgroundColor: colors.bgSurface,
    borderColor: colors.dividerLight,
    boxShadow: [
      BoxShadow(
        color: colors.shadow.withValues(alpha: 0.10),
        blurRadius: 24,
        offset: const Offset(0, 8),
      ),
    ],
    prefix: Padding(
      padding: const EdgeInsets.only(right: 6),
      child: MallowSvgIcon(
        'assets/icons/search.svg',
        width: 20,
        height: 20,
        color: colors.textSecondary,
      ),
    ),
    suffix: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder(
          valueListenable: _address,
          builder: (context, value, _) => value.text.isEmpty
              ? SizedBox(width: widget.inBrowser ? 0 : 14)
              : _fieldButton(
                  colors,
                  asset: 'assets/icons/close.svg',
                  label: 'Clear',
                  size: 18,
                  onTap: () {
                    _address.clear();
                    setState(() => _inputError = null);
                  },
                ),
        ),
        // The browser tab keeps the gear in its title row.
        if (widget.inBrowser)
          _fieldButton(
            colors,
            asset: 'assets/icons/settings.svg',
            label: 'Browser settings',
            size: 20,
            onTap: _settings,
          ),
      ],
    ),
    onChanged: (_) {
      if (_inputError != null) setState(() => _inputError = null);
    },
    onSubmitted: (value) => _open(value, typed: true),
  );

  /// Suggestions for the field's text, while the field has focus.
  Widget _suggestions() => ListenableBuilder(
    listenable: Listenable.merge([_address, _focus, browserSites]),
    builder: (context, _) {
      final suggestions = _focus.hasFocus
          ? _session.suggestions(_address.text)
          : const <BrowserSuggestion>[];
      if (suggestions.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: MallowTheme.spacingSm),
        child: BrowserSuggestionList(
          suggestions: suggestions,
          onOpen: (suggestion) {
            _focus.unfocus();
            _open(suggestion.url.toString(), typed: true);
          },
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      final colors = context.mallowColors;
      final active = widget.inBrowser ? null : _session.activeTab;
      final bookmarks = _session.bookmarks;
      // With no bookmarks the section, and its Done button, is gone, so a
      // reorder left on (clearing browsing data) must not trap back.
      final reordering = _reorderingBookmarks && bookmarks.isNotEmpty;
      return PopScope(
        canPop: !reordering,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && reordering) {
            setState(() => _reorderingBookmarks = false);
          }
        },
        child: widget.inBrowser
            ? Column(
                children: [
                  // Inside the browser the field is the blank tab's address
                  // bar: pinned in the bar's slot under the status bar.
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      MediaQuery.paddingOf(context).top + _barInset,
                      20,
                      _barInset,
                    ),
                    child: _searchField(colors),
                  ),
                  Expanded(child: _content(colors, active, bookmarks)),
                ],
              )
            : _content(colors, active, bookmarks),
      );
    },
  );

  /// Centres the field in the slot the browser's address bar takes.
  static const double _barInset =
      (BrowserAddressBar.expandedHeight - _fieldHeight) / 2;
  static const double _fieldHeight = 52;

  Widget _content(
    MallowColors colors,
    BrowserTab? active,
    List<BrowserBookmark> bookmarks,
  ) => CustomScrollView(
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    slivers: [
      // Title row holds still on a pull past the top, like every other
      // screen's top bar; the rest scrolls as a plain list.
      if (!widget.inBrowser)
        SliverOverscrollAnchored(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: _header(colors),
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList.list(
          children: [
            if (!widget.inBrowser) ...[
              const SizedBox(height: 18),
              _searchField(colors),
            ],
            _suggestions(),
            if (_session.error case final error?) ...[
              const SizedBox(height: MallowTheme.spacingMd),
              _Notice(message: error),
            ],
            if (active != null) ...[
              const SizedBox(height: MallowTheme.spacing20),
              StartContinueCard(
                tab: active,
                tabCount: _session.tabs.length,
                thumbnail: _session.thumbnail(active.id),
                connectedWallet: _activeOrigin == _connectionOrigin
                    ? _connectedWallet
                    : null,
                onTap: _resume,
                onTabs: _showTabs,
              ),
            ],
            if (bookmarks.isNotEmpty) ...[
              const SizedBox(height: 28),
              Row(
                children: [
                  const Expanded(child: _SectionTitle('Bookmarks')),
                  if (_reorderingBookmarks)
                    Tappable(
                      key: const Key('bookmark-reorder-done'),
                      semanticLabel: 'Done reordering bookmarks',
                      onTap: () => setState(() => _reorderingBookmarks = false),
                      child: SizedBox(
                        height: 44,
                        child: Center(
                          child: Text(
                            'Done',
                            style: MallowTheme.uiLabel.copyWith(
                              color: colors.accent,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              if (_reorderingBookmarks) ...[
                Text(
                  'Drag bookmarks to reorder',
                  style: MallowTheme.uiMeta.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: MallowTheme.spacingMd),
              ],
              StartBookmarkGrid(
                bookmarks: bookmarks,
                reordering: _reorderingBookmarks,
                onOpen: (bookmark) => _open(bookmark.url.toString()),
                onMore: _bookmarkActions,
                onMove: _session.moveBookmark,
              ),
            ],
            const SizedBox(height: 28),
            const _SectionTitle('Popular on Solana'),
            const SizedBox(height: 14),
            StartSiteGrid(
              sites: browserPopularSites,
              onOpen: (site) => _open(site.url),
            ),
            if (_walletChains.contains(Chain.ethereum)) ...[
              const SizedBox(height: 28),
              const _SectionTitle('Popular on Ethereum'),
              const SizedBox(height: 14),
              StartSiteGrid(
                sites: browserPopularEthereumSites,
                onOpen: (site) => _open(site.url),
              ),
            ],
            if (_walletChains.contains(Chain.tezos)) ...[
              const SizedBox(height: 28),
              const _SectionTitle('Popular on Tezos'),
              const SizedBox(height: 14),
              StartSiteGrid(
                sites: browserPopularTezosSites,
                onOpen: (site) => _open(site.url),
              ),
            ],
            widget.inBrowser
                ? const SizedBox(height: MallowTheme.spacingLg)
                : const _TabRootReserve(),
          ],
        ),
      ),
    ],
  );

  Widget _header(MallowColors colors) => Row(
    children: [
      Expanded(
        child: Semantics(
          header: true,
          child: Text(
            'Where to next?',
            style: MallowTheme.editorialSection.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ),
      ),
      Transform.translate(
        offset: const Offset(10, 0),
        child: Tooltip(
          message: 'Browser settings',
          excludeFromSemantics: true,
          child: Tappable(
            onTap: _settings,
            semanticLabel: 'Browser settings',
            child: const SizedBox.square(
              dimension: 44,
              child: Center(
                child: MallowSvgIcon(
                  'assets/icons/settings.svg',
                  width: 22,
                  height: 22,
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _fieldButton(
    MallowColors colors, {
    required String asset,
    required String label,
    required double size,
    required VoidCallback onTap,
  }) => Tooltip(
    message: label,
    excludeFromSemantics: true,
    child: Tappable(
      semanticLabel: label,
      onTap: onTap,
      child: SizedBox.square(
        dimension: 44,
        child: Center(
          child: MallowSvgIcon(
            asset,
            width: size,
            height: size,
            color: colors.textSecondary,
          ),
        ),
      ),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(
      text,
      style: MallowTheme.editorialSection.copyWith(
        color: context.mallowColors.textPrimary,
        fontSize: 21,
      ),
    ),
  );
}

/// Session-level problems (storage could not be read or written).
class _Notice extends StatelessWidget {
  const _Notice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: MallowSvgIcon(
            'assets/icons/info_circle.svg',
            width: 16,
            height: 16,
            color: colors.error,
          ),
        ),
        const SizedBox(width: MallowTheme.spacingSm),
        Expanded(
          child: Text(
            message,
            style: MallowTheme.uiMeta.copyWith(color: colors.error),
          ),
        ),
      ],
    );
  }
}

/// Clears the floating nav bar the way the other tab roots do. Widget tests
/// and previews run without the service locator, where the cast bar cannot
/// be showing, so they get the plain nav-bar reserve.
class _TabRootReserve extends StatelessWidget {
  const _TabRootReserve();

  @override
  Widget build(BuildContext context) => sl.isRegistered<CastBloc>()
      ? const NavBarBottomReserve()
      : const SizedBox(height: 140);
}
