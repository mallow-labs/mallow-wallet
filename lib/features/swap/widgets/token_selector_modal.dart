import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/utils/address_format.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_underline_tab_bar.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/sheet_overscroll_dismiss.dart';
import '../../portfolio/models/token_balance.dart';
import '../../portfolio/widgets/unverified_tokens_header.dart';

/// The picker's two browse tabs, supplied together or not at all.
///
/// [owned] is kept separate from [TokenSelectorModal.tokens] because the two
/// answer different questions: `tokens` is everything locally *searchable*
/// (held balances plus the registry's zero-balance rows), while this is only
/// what is held. [popular] loads the highest-volume tab and is called once,
/// when the picker opens.
///
/// One record rather than two optional params so "tabs" is a single state: a
/// half-supplied pair used to render no tab bar and silently drop whichever
/// side was passed — including paying for a cold ~5 MB catalog fetch with
/// nowhere to put the rows.
typedef TokenBrowseTabs = ({
  List<TokenBalance> owned,
  Future<List<TokenBalance>> Function() popular,
});

/// Modal bottom sheet for selecting a token.
class TokenSelectorModal extends StatefulWidget {
  const TokenSelectorModal({
    required this.tokens,
    super.key,
    this.title = 'Select Token',
    this.catalogSearch,
    this.browseTabs,
  });

  final List<TokenBalance> tokens;
  final String title;

  /// Supply to put an Owned / Popular tab bar under the search field; omit
  /// (the sell side) and the picker shows the flat [tokens] list it always
  /// has.
  final TokenBrowseTabs? browseTabs;

  /// Optional wider catalog searched alongside [tokens] — the buy side passes
  /// the Jupiter verified-token list so the user can pick a token they neither
  /// hold nor find in the hardcoded registry. Hits are appended below the local
  /// matches, with mints already in [tokens] filtered out. Omit (null) to keep
  /// search local-only, which is what the sell side wants: you can only sell
  /// what you hold.
  final Future<List<TokenBalance>> Function(String query)? catalogSearch;

  @override
  State<TokenSelectorModal> createState() => _TokenSelectorModalState();
}

class _TokenSelectorModalState extends State<TokenSelectorModal> {
  /// Below this length a query matches most of a 3.9k-token catalog, so the
  /// hits are noise and the work is wasted.
  static const _minCatalogQueryLength = 2;

  static const _catalogDebounce = Duration(milliseconds: 250);

  static const _tabLabels = ['Owned', 'Popular'];
  static const _popularTabIndex = 1;

  final _searchController = TextEditingController();
  List<TokenBalance> _filteredTokens = [];
  List<TokenBalance> _catalogHits = [];
  Timer? _catalogDebounceTimer;
  bool _catalogSearching = false;

  /// Guards against an out-of-order catalog response overwriting a newer one.
  int _catalogRequestId = 0;

  /// True while a query is active — the browse tabs step aside for the search
  /// results, which deliberately span every token rather than the active tab's.
  /// Derived from the field rather than mirrored into state: the controller is
  /// the only writer, so a copy could only ever go stale.
  bool get _searching => _searchController.text.trim().isNotEmpty;

  int _tabIndex = 0;
  List<TokenBalance>? _popular;

  bool get _hasTabs => widget.browseTabs != null;

  @override
  void initState() {
    super.initState();
    _filteredTokens = widget.tokens;
    // Loaded up front rather than on first tab tap: the catalog fetch behind it
    // can be cold, and a spinner that only appears once the user has committed
    // to the tab is the slowest possible moment to pay for it.
    final tabs = widget.browseTabs;
    if (tabs != null) unawaited(_loadPopular(tabs));
  }

  Future<void> _loadPopular(TokenBrowseTabs tabs) async {
    try {
      final tokens = await tabs.popular();
      if (!mounted) return;
      setState(() => _popular = tokens);
    } catch (_) {
      // The tab is a shortcut, not the only way in — search still reaches every
      // verified token. Settle on an empty list so the spinner resolves.
      if (!mounted) return;
      setState(() => _popular = const []);
    }
  }

  @override
  void dispose() {
    _catalogDebounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredTokens = widget.tokens;
      } else {
        final lowerQuery = query.toLowerCase();
        // A pasted mint has to match the tokens the user can already see —
        // the catalog drops hits that duplicate a local row, so without this
        // the picker reads "No tokens found" for a mint that is right there.
        // Mints are base58 and case-sensitive: match the trimmed query
        // exactly, never as a lowercased substring, which would flood the
        // list for short queries.
        final trimmedQuery = query.trim();
        _filteredTokens = widget.tokens.where((token) {
          return token.symbol.toLowerCase().contains(lowerQuery) ||
              token.name.toLowerCase().contains(lowerQuery) ||
              token.mint == trimmedQuery;
        }).toList();
      }
    });
    _scheduleCatalogSearch(query);
  }

  void _scheduleCatalogSearch(String query) {
    if (widget.catalogSearch == null) return;
    _catalogDebounceTimer?.cancel();
    // Bump here rather than when the search runs: the debounce window would
    // otherwise be unguarded, so a response to the previous query landing
    // inside it would publish — and clear the spinner — as if it had settled
    // the query the user has already replaced.
    final requestId = ++_catalogRequestId;
    final trimmed = query.trim();
    if (trimmed.length < _minCatalogQueryLength) {
      // The bump above also invalidates any in-flight request so its late
      // result can't repopulate the list the user just cleared.
      setState(() {
        _catalogHits = const [];
        _catalogSearching = false;
      });
      return;
    }
    setState(() => _catalogSearching = true);
    _catalogDebounceTimer = Timer(
      _catalogDebounce,
      () => unawaited(_runCatalogSearch(trimmed, requestId)),
    );
  }

  Future<void> _runCatalogSearch(String query, int requestId) async {
    final localMints = widget.tokens.map((t) => t.mint).toSet();
    try {
      final hits = await widget.catalogSearch!(query);
      if (!mounted || requestId != _catalogRequestId) return;
      setState(() {
        _catalogHits = hits
            .where((t) => !localMints.contains(t.mint))
            .toList(growable: false);
        _catalogSearching = false;
      });
    } catch (_) {
      // The catalog is a supplement — a failure leaves the local matches alone.
      if (!mounted || requestId != _catalogRequestId) return;
      setState(() => _catalogSearching = false);
    }
  }

  /// The active browse tab's rows. Null on "Popular" while it is still loading,
  /// which the caller renders as a spinner rather than an empty tab.
  List<TokenBalance>? get _browseRows =>
      _tabIndex == _popularTabIndex ? _popular : widget.browseTabs?.owned;

  /// [tokens] with the unverified ones moved below the verified ones under
  /// their own header — the same split the tokens tab and the send picker use.
  ///
  /// A mint carrying no verified tag is an unrecognized airdrop as often as it
  /// is a real holding, and this picker is the last screen before an
  /// irreversible swap, so the two are never interleaved: a spoofed "USDC" must
  /// not be able to sit next to the real one.
  static List<Object> _withUnverifiedSection(List<TokenBalance> tokens) {
    final unverified = tokens.where((t) => !t.isVerified).toList();
    if (unverified.isEmpty) return tokens;
    return [
      ...tokens.where((t) => t.isVerified),
      const _UnverifiedSectionMarker(),
      ...unverified,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Browsing a tab and searching are separate modes: a query searches every
    // token — held, registry and catalog — never just the active tab's.
    final browsing = _hasTabs && !_searching;
    final rows = _withUnverifiedSection(
      browsing
          ? (_browseRows ?? const <TokenBalance>[])
          : [..._filteredTokens, ..._catalogHits],
    );
    final loading = browsing ? _browseRows == null : _catalogSearching;
    return Container(
      height: media.size.height * 0.7,
      decoration: BoxDecoration(
        color: context.mallowColors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetDragHandle(),
          // Title
          Padding(
            padding: const EdgeInsets.all(MallowTheme.spacingMd),
            child: Text(
              widget.title,
              style: MallowTheme.uiBody.copyWith(
                color: context.mallowColors.textPrimary,
              ),
              textAlign: TextAlign.left,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacingMd,
            ),
            child: MallowPillField(
              controller: _searchController,
              hintText: 'Search by name or symbol',
              textInputAction: TextInputAction.search,
              prefix: MallowSvgIcon(
                'assets/icons/search.svg',
                width: 20,
                height: 20,
                color: context.mallowColors.textSecondary,
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          if (_hasTabs) ...[
            const SizedBox(height: MallowTheme.spacingLg),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MallowTheme.spacingMd,
              ),
              // Left visible while searching, like the buy sheet's chain tabs:
              // the query spans every token, so the tab is where the user
              // lands back when they clear it, not a filter on the results.
              child: MallowUnderlineTabBar(
                tabs: _tabLabels,
                activeIndex: _tabIndex,
                onTabSelected: (index) => setState(() => _tabIndex = index),
              ),
            ),
          ],
          const SizedBox(height: MallowTheme.spacingSm),
          // Token list
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: loading
                        ? const CircularProgressIndicator.adaptive()
                        : Text(
                            browsing && _tabIndex != _popularTabIndex
                                ? 'You don\'t own any tokens yet'
                                : 'No tokens found',
                            style: MallowTheme.uiBody.copyWith(
                              color: context.mallowColors.textSecondary,
                            ),
                          ),
                  )
                : SheetOverscrollDismiss(
                    child: ListView.builder(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: EdgeInsets.only(
                        bottom: sheetBottomInset(context),
                      ),
                      // Reached only with rows on screen, and a browse tab with
                      // rows has finished loading — so this trailing spinner is
                      // always the catalog-search one.
                      itemCount: rows.length + (loading ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == rows.length) {
                          return const Padding(
                            padding: EdgeInsets.all(MallowTheme.spacingMd),
                            child: Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator.adaptive(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          );
                        }
                        final token = rows[index];
                        if (token is! TokenBalance) {
                          return const UnverifiedTokensHeader();
                        }
                        return _TokenListTile(
                          token: token,
                          onTap: () => Navigator.of(context).pop(token),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Row marker standing in for the "Unverified tokens" section header, so the
/// list stays a single flat index space.
class _UnverifiedSectionMarker {
  const _UnverifiedSectionMarker();
}

class _TokenListTile extends StatelessWidget {
  const _TokenListTile({required this.token, required this.onTap});

  final TokenBalance token;
  final VoidCallback onTap;

  /// `name • AbCdE…12345`, or just the name for a chain's base token (SOL /
  /// ETH / XTZ) — those have no meaningful mint to disambiguate (ETH and XTZ
  /// carry a sentinel, not an address), and there is only ever one of each.
  String get _subtitle => token.isNative
      ? token.name
      : '${token.name} • ${truncateAddress(token.mint)}';

  @override
  Widget build(BuildContext context) {
    // The sheet's own `Container` decoration sits between this tile and the
    // nearest `Material`, which hides the tap ink (and trips a `ListTile`
    // assertion on Flutter 3.44+). A transparent `Material` of its own gives
    // the splash a surface to paint on without changing the row's colour.
    return Material(
      color: Colors.transparent,
      child: ListTile(
        onTap: onTap,
        leading: tokenImageWidget(
          mint: token.mint,
          size: 40,
          symbol: token.symbol,
          logoUrl: token.logoUrl,
          useChainSvg: false,
        ),
        title: Text(token.symbol, style: MallowTheme.uiBody),
        subtitle: Text(
          _subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: MallowTheme.uiMeta.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(_formatBalance(token.uiBalance), style: MallowTheme.uiBody),
            if (token.totalUsdValue != null)
              Text(
                '\$${token.totalUsdValue!.toStringAsFixed(2)}',
                style: MallowTheme.uiMeta.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatBalance(double balance) {
    if (balance >= 1000000) {
      return '${(balance / 1000000).toStringAsFixed(2)}M';
    } else if (balance >= 1000) {
      return '${(balance / 1000).toStringAsFixed(2)}K';
    } else if (balance >= 1) {
      return balance.toStringAsFixed(2);
    } else {
      return balance.toStringAsFixed(4);
    }
  }
}
