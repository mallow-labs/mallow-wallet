import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../activity/screens/activity_detail_screen.dart';
import '../../search/services/recently_viewed_recorder.dart';
import '../../send/widgets/send_sheet.dart';
import '../../swap/widgets/swap_sheet.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../core/config/remote_config.dart';
import '../../../shared/widgets/animated_tab_content.dart';
import '../../../shared/widgets/chain_support_guard.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/full_screen_sheet.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_underline_tab_bar.dart';
import '../../../shared/widgets/view_only_prompt.dart';
import '../models/ohlcv_candle.dart';
import '../models/token_balance.dart';
import '../services/token_detail_bloc.dart';
import '../widgets/token_history_tab.dart';
import '../widgets/token_overview_tab.dart';
import '../widgets/token_position_card.dart';
import '../widgets/token_price_chart.dart';
import '../widgets/token_security_tab.dart';

/// Opens the token detail as a full-screen modal bottom sheet.
Future<void> showTokenDetailSheet(BuildContext context, TokenBalance token) {
  RecentlyViewedRecorder.recordToken(
    mintAddress: token.mint,
    name: token.name,
    symbol: token.symbol,
    iconUrl: token.logoUrl,
    usdPrice: token.pricePerToken,
    priceChange24h: token.priceChange24h,
  );
  return showFullScreenSheet<void>(
    context: context,
    child: BlocProvider(
      create: (_) => sl<TokenDetailBloc>()..add(TokenDetailEvent.load(token)),
      child: _TokenDetailView(token: token),
    ),
  );
}

class _TokenDetailView extends StatefulWidget {
  const _TokenDetailView({required this.token});

  final TokenBalance token;

  @override
  State<_TokenDetailView> createState() => _TokenDetailViewState();
}

class _TokenDetailViewState extends State<_TokenDetailView>
    with SingleTickerProviderStateMixin {
  static const _historyTabIndex = 2;
  // Distance from the bottom (in px) at which we prefetch the next history
  // page. Far enough that fetch latency hides under continued scrolling.
  static const _loadMoreThreshold = 400.0;

  /// Every chain has a History tab. `GET /v2/transfers` routes each wallet to
  /// the upstream that can answer for it — Solana to Helius, Ethereum to
  /// Alchemy, Tezos to TzKT — so the tab no longer depends on the token's
  /// chain, only on there being a session wallet on it.
  static const _tabs = ['Overview', 'Security', 'History'];

  final ScrollController _scrollController = ScrollController();
  int _activeTab = 0;

  api.Activity? _selectedActivity;
  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;

  // True when nothing in the session can send this token, which hides the
  // Swap/Send action bar. Tracked reactively: the active wallet can change
  // while the sheet is open (account switch from the drawer).
  bool _isViewOnly = false;
  StreamSubscription<String>? _walletChangeSub;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _refreshViewOnly();
    _walletChangeSub = sl<WalletManager>().onWalletChanged.listen(
      (_) => _refreshViewOnly(),
    );
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _slideController, curve: Curves.easeInOut),
        );
  }

  @override
  void dispose() {
    _walletChangeSub?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  Future<void> _refreshViewOnly() async {
    // Keyed to the *token's* chain, not the active wallet's type: an ETH/XTZ
    // send signs with the session's wallet on that chain, so a watch-only
    // Solana selection says nothing about it. Reading it from the active wallet
    // hid the whole bar — which also made the Send button's own
    // [guardCannotSend] unreachable, since the control was never rendered.
    // Swap stays correct either way: it is Solana-only and disables itself for
    // other chains via `AppFlow.tokenSwap.isImplemented`.
    final canSend = await sessionCanSend(chain: widget.token.chain);
    if (!mounted) return;
    if (canSend == _isViewOnly) {
      setState(() => _isViewOnly = !canSend);
    }
  }

  void _showActivityDetail(api.Activity activity) {
    setState(() => _selectedActivity = activity);
    _slideController.forward();
  }

  void _hideActivityDetail() {
    _slideController.reverse().then((_) {
      if (mounted) setState(() => _selectedActivity = null);
    });
  }

  void _onScroll() {
    if (_activeTab != _historyTabIndex) return;
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - _loadMoreThreshold) {
      return;
    }

    final state = context.read<TokenDetailBloc>().state;
    if (state is! TokenDetailLoaded) return;
    if (!state.hasMoreHistory || state.isLoadingMoreHistory) return;

    context.read<TokenDetailBloc>().add(
      const TokenDetailEvent.loadMoreHistory(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TokenDetailBloc, TokenDetailState>(
      builder: (context, state) {
        final token = switch (state) {
          TokenDetailLoading(:final token) => token,
          TokenDetailLoaded(:final token) => token,
          _ => widget.token,
        };

        final isLoading = state is TokenDetailLoading;
        final loaded = state is TokenDetailLoaded ? state : null;

        return Stack(
          children: [
            CustomScrollView(
              controller: _scrollController,
              slivers: [
                // Pinned header (drag handle + token info + price)
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _TokenHeaderDelegate(token: token, loaded: loaded),
                ),
                // Chart
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: MallowTheme.spacing20,
                    ),
                    child: TokenPriceChart(
                      candles: loaded?.candles ?? const [],
                      timeframe: loaded?.timeframe ?? ChartTimeframe.oneDay,
                      isLoading: isLoading || (loaded?.isChartLoading ?? false),
                      onTimeframeChanged: (tf) {
                        context.read<TokenDetailBloc>().add(
                          TokenDetailEvent.timeframeChanged(tf),
                        );
                      },
                    ),
                  ),
                ),
                // Position card (only if user has balance)
                if (token.uiBalance > 0)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        MallowTheme.spacing20,
                        MallowTheme.spacingLg,
                        MallowTheme.spacing20,
                        MallowTheme.spacingMd,
                      ),
                      child: TokenPositionCard(token: token),
                    ),
                  ),
                // Tab bar
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _TabBarDelegate(
                    tabs: _tabs,
                    activeIndex: _activeTab,
                    onTabSelected: (i) => setState(() => _activeTab = i),
                  ),
                ),
                // Tab content — history is full width; other tabs get horizontal padding.
                SliverToBoxAdapter(
                  child: AnimatedTabContent(
                    activeIndex: _activeTab,
                    builder: (_, i) => switch (i) {
                      0 => Padding(
                        padding: const EdgeInsets.fromLTRB(
                          MallowTheme.spacing20,
                          24,
                          MallowTheme.spacing20,
                          0,
                        ),
                        child: TokenOverviewTab(
                          token: token,
                          tokenInfo: loaded?.tokenInfo,
                          isLoading: loaded == null,
                        ),
                      ),
                      1 => Padding(
                        padding: const EdgeInsets.fromLTRB(
                          MallowTheme.spacing20,
                          24,
                          MallowTheme.spacing20,
                          0,
                        ),
                        child: TokenSecurityTab(
                          tokenInfo: loaded?.tokenInfo,
                          chain: token.chain,
                        ),
                      ),
                      2 => Padding(
                        // 4 + ActivityDayHeader's internal top (20) = 24,
                        // matching the overview/security tab top gap above.
                        padding: const EdgeInsets.only(
                          top: MallowTheme.spacingXs,
                        ),
                        child: TokenHistoryTab(
                          activities: loaded?.activities ?? const [],
                          tokenMint: token.mint,
                          isLoadingMore: loaded?.isLoadingMoreHistory ?? false,
                          onActivityTap: _showActivityDetail,
                        ),
                      ),
                      _ => const SizedBox.shrink(),
                    },
                  ),
                ),
                // Bottom padding for action bar (only when it's shown)
                if (!_isViewOnly)
                  const SliverToBoxAdapter(child: SizedBox(height: 100)),
              ],
            ),
            // Floating action bar with gradient — hidden for view-only wallets,
            // which can't sign the swap/send transactions it would open.
            if (!_isViewOnly)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                // The bloc's token, not the snapshot the sheet was opened
                // with: a send/swap done from here updates the holding, and
                // the next sheet must open against the current balance.
                child: _ActionBar(token: token),
              ),
            if (_selectedActivity != null)
              SlideTransition(
                position: _slideAnimation,
                child: SizedBox.expand(
                  child: ColoredBox(
                    color: context.mallowColors.bgSurface,
                    child: ActivityDetailScreen(
                      activity: _selectedActivity!,
                      onBack: _hideActivityDetail,
                      chain: token.chain,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Pinned header delegate (drag handle + token info + price stats + gradient)
// ---------------------------------------------------------------------------

class _TokenHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _TokenHeaderDelegate({required this.token, this.loaded});

  final TokenBalance token;
  final TokenDetailLoaded? loaded;

  // spacingMd(12) + TokenHeader(48) + spacingMd(12) + PriceStatsRow(~48).
  // No bottom gradient: the tab bar sliver pins flush against this header,
  // and a transparent fade here would let scrolled content show through the
  // gap between the two pinned sections.
  static const _headerHeight = 124.0;

  @override
  double get minExtent => _headerHeight;

  @override
  double get maxExtent => _headerHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final colors = context.mallowColors;

    return Container(
      color: colors.bgSurface,
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: MallowTheme.spacingMd),
          _TokenHeader(token: token),
          const SizedBox(height: MallowTheme.spacingMd),
          _PriceStatsRow(token: token, loaded: loaded),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_TokenHeaderDelegate old) =>
      token != old.token || loaded != old.loaded;
}

// ---------------------------------------------------------------------------
// Token Header
// ---------------------------------------------------------------------------

class _TokenHeader extends StatelessWidget {
  const _TokenHeader({required this.token});

  final TokenBalance token;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final isNative = token.isNative;

    return Row(
      children: [
        tokenImageWidget(
          mint: token.mint,
          symbol: token.symbol,
          logoUrl: token.logoUrl,
          size: 48,
          // Match the activity rows: show the colored brand logos for native
          // SOL / ETH / XTZ rather than the monochrome chain marks.
          useChainSvg: false,
        ),
        const SizedBox(width: MallowTheme.spacingMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                token.name,
                style: MallowTheme.editorialQuote.copyWith(
                  color: colors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (!isNative) ...[
                const SizedBox(height: 2),
                Text(
                  truncateAddress(token.mint),
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Price + Stats Row
// ---------------------------------------------------------------------------

class _PriceStatsRow extends StatelessWidget {
  const _PriceStatsRow({required this.token, this.loaded});

  final TokenBalance token;
  final TokenDetailLoaded? loaded;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final price = loaded?.tokenInfo?.price ?? token.pricePerToken;
    final change = loaded?.tokenInfo?.priceChange24h ?? token.priceChange24h;
    final marketCap = loaded?.tokenInfo?.marketCap;
    final volume24h = loaded?.tokenInfo?.volume24h;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Price + change (left side)
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                price != null
                    ? '\$${PriceFormatter.formatSpotPrice(price)}'
                    : '—',
                style: MallowTheme.uiDisplayTabular.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              if (change != null) ...[
                const SizedBox(height: 2),
                _PriceChange(change: change),
              ],
            ],
          ),
        ),
        // Market stats (right side)
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (marketCap != null)
              _StatLine(
                label: 'Market Cap',
                value: '\$${PriceFormatter.formatCompactValue(marketCap)}',
              ),
            if (volume24h != null)
              _StatLine(
                label: '24h Volume',
                value: '\$${PriceFormatter.formatCompactValue(volume24h)}',
              ),
          ],
        ),
      ],
    );
  }
}

class _PriceChange extends StatelessWidget {
  const _PriceChange({required this.change});

  final double change;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final isPositive = change >= 0;
    final color = isPositive ? colors.positive : colors.negative;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          isPositive ? '↑' : '↓',
          style: TextStyle(color: color, fontSize: 11, height: 1),
        ),
        const SizedBox(width: 2),
        Text(
          '${change.abs().toStringAsFixed(2)}%',
          style: MallowTheme.uiCaption.copyWith(color: color),
        ),
      ],
    );
  }
}

class _StatLine extends StatelessWidget {
  const _StatLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label / ',
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          Text(
            value,
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab bar delegate (pinned to top when scrolling)
// ---------------------------------------------------------------------------

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  const _TabBarDelegate({
    required this.tabs,
    required this.activeIndex,
    required this.onTabSelected,
  });

  final List<String> tabs;
  final int activeIndex;
  final ValueChanged<int> onTabSelected;

  // MallowUnderlineTabBar's natural height: 2*spacingSm(8) + uiCaption
  // lineHeight(14) + 2px active underline = 32.
  static const _tabBarHeight = 32.0;

  @override
  double get minExtent => _tabBarHeight;

  @override
  double get maxExtent => _tabBarHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final colors = context.mallowColors;
    return ColoredBox(
      color: colors.bgSurface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
        child: MallowUnderlineTabBar(
          tabs: tabs,
          activeIndex: activeIndex,
          onTabSelected: onTabSelected,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_TabBarDelegate old) =>
      activeIndex != old.activeIndex || tabs != old.tabs;
}

// ---------------------------------------------------------------------------
// Bottom action buttons
// ---------------------------------------------------------------------------

/// Buy-side token to pre-select when swapping [token] from the detail sheet.
/// Only reached for Solana tokens — Swap is Jupiter-backed and Solana-only, so
/// the button is hidden for Ethereum/Tezos. An SPL token buys SOL; native SOL
/// returns null so the swap sheet seeds its own default (it can't swap for
/// itself).
TokenBalance? _swapBuyToken(TokenBalance token) {
  if (!token.isNative) return TokenBalance.nativeForChain(token.chain);
  return null;
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.token});

  final TokenBalance token;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Gradient fade
        Container(
          height: 10,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [colors.bgSurface.withValues(alpha: 0), colors.bgSurface],
            ),
          ),
        ),
        // Buttons
        ColoredBox(
          color: colors.bgSurface,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                0,
                MallowTheme.spacing20,
                MallowTheme.spacing20,
              ),
              child: Row(
                children: [
                  // Swap is Jupiter-backed and Solana-only; Ethereum/Tezos have
                  // no swap route yet (cross-chain swap is planned), so the
                  // button is disabled for them rather than opening a sheet that
                  // can't quote or execute.
                  Expanded(
                    child: MallowButton(
                      label: 'Swap',
                      // Keyed off the same capability matrix as the session
                      // gate, but on the *token's* chain: this button is about
                      // whether this asset can be swapped, not whether the
                      // session could swap something else.
                      enabled: AppFlow.tokenSwap.isImplemented(token.chain),
                      onDisabledTap: () => AppSnackBar.show(
                        context,
                        'Swap is only available on '
                        '${flowChainsLabel(AppFlow.tokenSwap)} — '
                        '${token.chain.label} tokens cannot be swapped yet.',
                      ),
                      onPressed: () async {
                        if (await guardViewOnly(context)) return;
                        if (!context.mounted) return;
                        unawaited(
                          showSwapSheet(
                            context,
                            initialSellToken: token,
                            initialBuyToken: _swapBuyToken(token),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: MallowTheme.spacingMd),
                  Expanded(
                    child: MallowButton(
                      label: 'Send',
                      onPressed: () async {
                        // Chain-aware: an ETH/XTZ send signs with the session's
                        // wallet on the token's chain, so a watch-only *Solana*
                        // selection has no bearing on it.
                        if (await guardCannotSend(
                          context,
                          chain: token.chain,
                        )) {
                          return;
                        }
                        if (!context.mounted) return;
                        unawaited(showSendSheet(context, initialToken: token));
                      },
                      variant: MallowButtonVariant.secondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
