import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/services/active_networks.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/utils/address_format.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_refresh_indicator.dart';
import '../../../shared/widgets/state_viewer.dart';
import '../../../shared/widgets/view_only_prompt.dart';
import '../../cast/widgets/now_casting_bar.dart';
import '../../send/widgets/send_sheet.dart';
import '../../staking/widgets/stake_status_section.dart';
import '../data/session_portfolio_aggregator.dart';
import '../models/token_balance.dart';
import '../services/token_balance_bloc.dart';
import '../utils/token_display_order.dart';
import '../widgets/portfolio_action_buttons.dart';
import '../widgets/portfolio_value_section.dart';
import '../widgets/staking_banner.dart';
import '../widgets/token_burn_flow.dart';
import '../widgets/token_list_item.dart';
import '../widgets/token_sort_header.dart';
import '../widgets/tokens_empty_state.dart';
import '../widgets/unverified_tokens_header.dart';
import 'token_detail_screen.dart';

import '../../../shared/utils/chain.dart';

void _copyMintAddress(BuildContext context, String mint) {
  Clipboard.setData(ClipboardData(text: mint));
  HapticFeedback.lightImpact();
  AppSnackBar.show(
    context,
    '${truncateAddress(mint)} copied to clipboard',
    type: AppSnackBarType.success,
    duration: const Duration(seconds: 2),
  );
}

/// Inline tokens tab content for the main tab navigator.
///
/// Uses the [TokenBalanceBloc] already provided by [TabNavigator].
class TokensTabContent extends StatelessWidget {
  const TokensTabContent({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TokenBalanceBloc, TokenBalanceState>(
      builder: (context, state) {
        return StateViewer(
          isLoading: state.maybeWhen(
            loading: () => true,
            initial: () => true,
            orElse: () => false,
          ),
          error: state.mapOrNull(error: (e) => e.message),
          onRetry: () => context.read<TokenBalanceBloc>().add(
            const TokenBalanceEvent.load(),
          ),
          child: state.maybeMap(
            loaded: (s) => _TokensLoaded(
              tokens: s.tokens,
              totalUsd: s.totalUsdValue,
              isRefreshing: s.isRefreshing,
              totalChange24h: s.totalChange24h,
              totalChangePercent24h: s.totalChangePercent24h,
            ),
            orElse: () => const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}

class _TokensLoaded extends StatefulWidget {
  const _TokensLoaded({
    required this.tokens,
    required this.totalUsd,
    this.isRefreshing = false,
    this.totalChange24h,
    this.totalChangePercent24h,
  });

  final List<TokenBalance> tokens;
  final double totalUsd;
  final bool isRefreshing;
  final double? totalChange24h;
  final double? totalChangePercent24h;

  @override
  State<_TokensLoaded> createState() => _TokensLoadedState();
}

class _TokensLoadedState extends State<_TokensLoaded> {
  var _sort = TokenSortOption.topValue;

  /// Whether this session can send anything at all — the gate on the action
  /// row, the row-swipe actions, and the empty state's actionable layout.
  ///
  /// Not "the active wallet is view-only": an ETH/XTZ send signs with the
  /// session's wallet on that chain, so a watch-only *Solana* selection says
  /// nothing about it. Reading the active wallet hid the Send affordance
  /// outright for a session that could send perfectly well.
  bool _canSend = true;
  StreamSubscription<String>? _walletChangeSub;
  StreamSubscription<void>? _networksSub;

  /// Chains switched off in Active Networks. Empty until the first read lands,
  /// which shows every session chain for a frame — the same rows as before the
  /// preference existed, never a row the user turned off for longer than that.
  Set<Chain> _disabledChains = const {};

  /// Mints held by a session wallet that can actually sign for them — the rows
  /// a swipe action can complete on. Null until the first scan lands, which
  /// leaves the swipe enabled exactly as before rather than blanking every row
  /// for a frame.
  Set<String>? _signableMints;

  /// Non-Solana chains the session holds a transfer-signing wallet on — the
  /// rows swipe-to-send is offered on off Solana.
  ///
  /// Chain-level rather than per-mint like [_signableMints]: the per-wallet
  /// balance cache that scan reads carries no chain of its own, so there is no
  /// equivalent set to build for Tezos or Ethereum. The send sheet's source
  /// picker does the final narrowing.
  ///
  /// Solana is excluded deliberately — its send signs with the global wallet
  /// selection, which [_canSend] and [_signableMints] already gate.
  Set<Chain> _sendableChains = const {};

  @override
  void initState() {
    super.initState();
    _refreshCanSend();
    _loadSignableMints();
    _sendableChains = _computeSendableChains();
    _loadDisabledChains();
    _walletChangeSub = sl<WalletManager>().onWalletChanged.listen((_) {
      _refreshCanSend();
      // A wallet switch can change the session's signable set (and a Profile
      // switch changes it wholesale), so the gate is re-scanned with it.
      _loadSignableMints();
      _refreshSendableChains();
      // Active Networks is stored per session scope, so a Profile switch can
      // change which chains are off.
      _loadDisabledChains();
    });
    _networksSub = sl<ActiveNetworks>().changes.listen(
      (_) => _loadDisabledChains(),
    );
  }

  Set<Chain> _computeSendableChains() => {
    for (final w in sl<SessionManager>().sessionWallets)
      if (w.chainEnum != Chain.solana && w.canSignSendTransfer) w.chainEnum,
  };

  void _refreshSendableChains() {
    final chains = _computeSendableChains();
    if (!mounted || setEquals(chains, _sendableChains)) return;
    setState(() => _sendableChains = chains);
  }

  Future<void> _loadDisabledChains() async {
    try {
      final disabled = await sl<ActiveNetworks>().disabled();
      if (!mounted || setEquals(disabled, _disabledChains)) return;
      setState(() => _disabledChains = disabled);
    } catch (_) {
      // Leave the rows as they are rather than hiding chains on a storage
      // read failure — the preference defaults to enabled.
    }
  }

  @override
  void didUpdateWidget(_TokensLoaded oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refresh can surface a mint that wasn't cached at mount — re-scan so a
    // newly-arrived row isn't left permanently un-swipeable.
    if (!identical(oldWidget.tokens, widget.tokens)) _loadSignableMints();
  }

  Future<void> _loadSignableMints() async {
    try {
      final mints = await sl<SessionPortfolioAggregator>()
          .signableSolanaMints();
      if (!mounted) return;
      setState(() => _signableMints = mints);
    } catch (_) {
      // Leave the gate as-is rather than disabling every row on a cache read
      // failure — the flows themselves still refuse a wallet that can't sign.
    }
  }

  @override
  void dispose() {
    _walletChangeSub?.cancel();
    _networksSub?.cancel();
    super.dispose();
  }

  /// Native chains the current session holds a wallet for, ordered SOL → ETH →
  /// XTZ, minus any the user switched off in Active Networks. Drives which
  /// 0-balance gas-token rows the empty state shows (e.g. a watch-only
  /// Ethereum address shows only ETH). View-only wallets count — the row
  /// reflects an address the session can receive into. Falls back to Solana if
  /// the session somehow has no wallets.
  ///
  /// The disabled set matters here as well as in the bloc: the bloc drops a
  /// switched-off chain's *balances*, but the 0-balance placeholder is
  /// synthesized from the session's wallets, so without this filter an XTZ row
  /// would survive Tezos being turned off.
  List<Chain> _emptyStateChains() {
    final present = sl<SessionManager>().sessionWallets
        .map((w) => w.chainEnum)
        .where((c) => !_disabledChains.contains(c))
        .toSet();
    final ordered = [
      Chain.solana,
      Chain.ethereum,
      Chain.tezos,
    ].where(present.contains).toList();
    return ordered.isEmpty ? const [Chain.solana] : ordered;
  }

  /// No chain argument: the tab spans every session chain, so the question is
  /// whether *anything* here can be sent. The token detail sheet and the send
  /// sheet's source picker narrow it per token from there.
  Future<void> _refreshCanSend() async {
    final canSend = await sessionCanSend();
    if (!mounted) return;
    if (canSend != _canSend) {
      setState(() => _canSend = canSend);
    }
  }

  /// True while a swipe-triggered sheet (send or burn) is open. Blocks a
  /// second swipe from opening a duplicate sheet during the window before the
  /// first sheet's modal barrier goes up — notably the burn flow, which builds
  /// its transaction (a network round-trip) before showing anything.
  bool _actionInProgress = false;

  Future<void> _sendToken(BuildContext context, TokenBalance token) async {
    if (_actionInProgress) return;
    _actionInProgress = true;
    try {
      await showSendSheet(
        context,
        initialToken: token,
        tokenBalanceBloc: context.read<TokenBalanceBloc>(),
      );
    } finally {
      _actionInProgress = false;
    }
  }

  Future<void> _burnToken(BuildContext context, TokenBalance token) async {
    if (_actionInProgress) return;
    _actionInProgress = true;
    try {
      await runTokenBurnFlow(
        context,
        token: token,
        tokenBalanceBloc: context.read<TokenBalanceBloc>(),
      );
    } finally {
      _actionInProgress = false;
    }
  }

  /// The fetched tokens plus a 0-balance native row for every session chain
  /// that has no native token in the list. A chain's *wallet existing* — not
  /// its balance — is what guarantees its gas-token row, so a Tezos wallet
  /// holding 0 XTZ still shows an XTZ row alongside non-zero Solana balances.
  /// The empty-state path already does this; this mirrors it for the case
  /// where at least one chain has a balance (so the empty state never renders).
  List<TokenBalance> get _tokensWithNativeRows {
    final tokens = List<TokenBalance>.of(widget.tokens);
    final nativeChains = tokens
        .where((t) => t.isNative)
        .map((t) => t.chain)
        .toSet();
    for (final chain in _emptyStateChains()) {
      if (!nativeChains.contains(chain)) {
        tokens.add(nativePlaceholder(chain));
      }
    }
    return tokens;
  }

  /// Native Solana, Tezos, and Ethereum pinned to the top in a fixed order;
  /// everything else keeps the user-selected sort below them.
  List<TokenBalance> get _sortedTokens =>
      sortTokensForDisplay(_tokensWithNativeRows, sort: _sort);

  @override
  Widget build(BuildContext context) {
    if (widget.tokens.isEmpty) {
      return MallowRefreshIndicator(
        onRefresh: () async {
          final bloc = context.read<TokenBalanceBloc>();
          bloc.add(const TokenBalanceEvent.refresh());
          // Unlike the loaded list, the empty state has no inline refresh
          // spinner to hand off to — hold the indicator until the refetch
          // completes (isRefreshing clears).
          await bloc.stream.firstWhere(
            (state) => state.maybeMap(
              loaded: (s) => !s.isRefreshing,
              error: (_) => true,
              orElse: () => false,
            ),
          );
        },
        child: TokensEmptyState(
          totalUsd: widget.totalUsd,
          canSend: _canSend,
          chains: _emptyStateChains(),
        ),
      );
    }

    final tokens = _sortedTokens;
    final verified = tokens.where((t) => t.isVerified).toList();
    final unverified = tokens.where((t) => !t.isVerified).toList();
    // Staking needs SOL to stake — check the balance, not the row's presence:
    // _tokensWithNativeRows synthesizes a 0-balance SOL row for every session
    // Solana wallet, so `any(isNative && solana)` would always be true.
    final hasSol = tokens.any(
      (t) => t.isNative && t.chain == Chain.solana && t.rawBalance > 0,
    );

    return MallowRefreshIndicator(
      onRefresh: () async {
        context.read<TokenBalanceBloc>().add(const TokenBalanceEvent.refresh());
        await context.read<TokenBalanceBloc>().stream.firstWhere(
          (state) => state.maybeMap(loading: (_) => false, orElse: () => true),
        );
      },
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(
            child: SizedBox(height: MallowTheme.spacing26),
          ),
          // Portfolio value
          SliverToBoxAdapter(
            child: PortfolioValueSection(
              totalUsd: widget.totalUsd,
              isRefreshing: widget.isRefreshing,
              totalChange24h: widget.totalChange24h,
              totalChangePercent24h: widget.totalChangePercent24h,
            ),
          ),
          const SliverToBoxAdapter(
            child: SizedBox(height: MallowTheme.spacing26),
          ),
          // Action buttons — hidden for view-only wallets (cannot sign).
          if (_canSend) ...[
            const SliverToBoxAdapter(child: PortfolioActionButtonsRow()),
            const SliverToBoxAdapter(
              child: SizedBox(height: MallowTheme.spacing26),
            ),
          ],
          // Staking banner — only when there is SOL to stake.
          if (hasSol) ...[
            const SliverToBoxAdapter(child: StakingBanner()),
            const SliverToBoxAdapter(
              child: SizedBox(height: MallowTheme.spacing26),
            ),
          ],
          // Native-stake status cells (activating / unstaked / claimable).
          // Gated on having stake, not on `hasSol` like the banner above — a
          // user who staked everything has no spendable SOL and still needs to
          // see it. Carries its own trailing 26 and collapses to nothing when
          // there is no stake, so the gap doesn't survive without the cells.
          const SliverToBoxAdapter(child: StakeStatusSection()),
          // Sort header
          SliverToBoxAdapter(
            child: TokenSortHeader(
              currentSort: _sort,
              onSortChanged: (sort) => setState(() => _sort = sort),
            ),
          ),
          const SliverToBoxAdapter(
            child: SizedBox(height: MallowTheme.spacingXs),
          ),
          // Verified tokens
          _TokenListSliver(
            tokens: verified,
            enableSwipe: _canSend,
            signableMints: _signableMints,
            sendableChains: _sendableChains,
            onTap: (token) => showTokenDetailSheet(context, token),
            onLongPress: (token) => _copyMintAddress(context, token.mint),
            onSend: (token) => _sendToken(context, token),
            onBurn: (token) => _burnToken(context, token),
          ),
          if (unverified.isNotEmpty) ...[
            const SliverToBoxAdapter(child: UnverifiedTokensHeader()),
            _TokenListSliver(
              tokens: unverified,
              enableSwipe: _canSend,
              signableMints: _signableMints,
              sendableChains: _sendableChains,
              onTap: (token) => showTokenDetailSheet(context, token),
              onLongPress: (token) => _copyMintAddress(context, token.mint),
              onSend: (token) => _sendToken(context, token),
              onBurn: (token) => _burnToken(context, token),
            ),
          ],
          // Bottom reserve for nav bar (grows when cast bar is active).
          const SliverToBoxAdapter(child: NavBarBottomReserve()),
        ],
      ),
    );
  }
}

class _TokenListSliver extends StatelessWidget {
  const _TokenListSliver({
    required this.tokens,
    required this.onTap,
    required this.onLongPress,
    required this.onSend,
    required this.onBurn,
    required this.enableSwipe,
    required this.signableMints,
    required this.sendableChains,
  });

  final List<TokenBalance> tokens;
  final ValueChanged<TokenBalance> onTap;
  final ValueChanged<TokenBalance> onLongPress;
  final ValueChanged<TokenBalance> onSend;
  final ValueChanged<TokenBalance> onBurn;
  final bool enableSwipe;

  /// Mints a session wallet can sign for; null while the scan is in flight.
  final Set<String>? signableMints;

  /// Non-Solana chains the session can sign a transfer on.
  final Set<Chain> sendableChains;

  @override
  Widget build(BuildContext context) {
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        final token = tokens[index];
        return Column(
          children: [
            _maybeSwipeable(
              token,
              TokenListItem(
                token: token,
                onTap: () => onTap(token),
                onLongPress: () => onLongPress(token),
              ),
            ),
            if (index < tokens.length - 1)
              Divider(
                height: 1,
                indent: MallowTheme.spacing20,
                endIndent: MallowTheme.spacing20,
                color: context.mallowColors.divider,
              ),
          ],
        );
      }, childCount: tokens.length),
    );
  }

  /// Wraps [child] in a swipe-to-act gesture when allowed. Swipe right sends;
  /// swipe left burns. The action fires the instant the swipe is released
  /// (past threshold) and the row springs back — nothing is removed inline.
  ///
  /// Burn is Solana-only (it builds an SPL burn+close tx), so a Tezos or
  /// Ethereum row is send-only — as is native SOL, which has no token account
  /// to close. Send itself is chain-agnostic: the sheet takes the row's token
  /// and picks a source on that token's chain.
  ///
  /// A row no session wallet can sign for is not swipeable at all: it still
  /// shows in the aggregated portfolio (reads need no key), but the action
  /// would dead-end — send with an empty source picker, burn with a tx it has
  /// no wallet to close. Solana checks that per mint ([signableMints]); the
  /// other chains check it per chain ([sendableChains]).
  Widget _maybeSwipeable(TokenBalance token, Widget child) {
    if (!enableSwipe) return child;
    if (token.chain != Chain.solana) {
      if (!sendableChains.contains(token.chain)) return child;
      return _SwipeActionRow(
        key: ValueKey('swipe_${token.chain}_${token.mint}'),
        onSwipeRight: () => onSend(token),
        onSwipeLeft: null,
        child: child,
      );
    }
    final signable = signableMints;
    if (signable != null && !signable.contains(token.mint)) return child;
    final canBurn = !token.isNative;
    return _SwipeActionRow(
      key: ValueKey('swipe_${token.chain}_${token.mint}'),
      onSwipeRight: () => onSend(token),
      onSwipeLeft: canBurn ? () => onBurn(token) : null,
      child: child,
    );
  }
}

/// A horizontal swipe-to-act row. Reveals a colored action panel as it's
/// dragged and fires the matching callback the moment the drag is released
/// past the threshold (no fling-to-edge delay), then snaps back. A direction
/// with a null callback is disabled (drag in that direction is ignored).
class _SwipeActionRow extends StatefulWidget {
  const _SwipeActionRow({
    required this.child,
    required this.onSwipeRight,
    required this.onSwipeLeft,
    super.key,
  });

  final Widget child;
  final VoidCallback? onSwipeRight;
  final VoidCallback? onSwipeLeft;

  @override
  State<_SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<_SwipeActionRow>
    with SingleTickerProviderStateMixin {
  // Unbounded so a velocity-seeded spring can carry the row past 0 briefly and
  // settle back; its value is the live offset in px during the snap-back.
  late final AnimationController _settle = AnimationController.unbounded(
    vsync: this,
  )..addListener(() => setState(() {}));

  /// Live drag distance in px (positive = right, negative = left).
  double _dragExtent = 0;

  /// Fraction of the row width the drag must pass to trigger an action.
  static const _thresholdFraction = 0.3;

  /// Cap the row's asymptotic travel so it can't be dragged clear off-screen,
  /// while the rubber-band below keeps the edge elastic rather than dead.
  static const _maxDragFraction = 0.6;

  /// Seconds of release velocity projected forward when deciding whether a
  /// quick flick (that didn't travel far) should still trip the action.
  static const _momentumProjection = 0.12;

  /// Flick speed (px/s) that trips an action on velocity alone.
  static const _flickVelocity = 700.0;

  /// Critically damped spring for the snap-back — returns to rest without
  /// overshoot, but honours the release velocity it's seeded with.
  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 500,
  );

  double get _offset => _settle.isAnimating ? _settle.value : _dragExtent;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  /// Diminishing-returns rubber-band: 1:1 up to the action threshold, then
  /// progressively resisted so the row keeps giving elastic feedback while
  /// asymptotically approaching [_maxDragFraction] × width instead of hitting a
  /// dead hard stop.
  double _rubberBand(double value, double width) {
    final threshold = width * _thresholdFraction;
    final mag = value.abs();
    if (mag <= threshold) return value;
    final sign = value < 0 ? -1.0 : 1.0;
    final span = width * (_maxDragFraction - _thresholdFraction);
    final overshoot = mag - threshold;
    final damped = span * (1 - 1 / (overshoot / span + 1));
    return sign * (threshold + damped);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _settle.stop();
    final width = context.size?.width ?? 0;
    var next = _dragExtent + (details.primaryDelta ?? 0);
    // Ignore drags toward a disabled action.
    if (next > 0 && widget.onSwipeRight == null) next = 0;
    if (next < 0 && widget.onSwipeLeft == null) next = 0;
    setState(() => _dragExtent = _rubberBand(next, width));
  }

  void _onDragEnd(DragEndDetails details) {
    final width = context.size?.width ?? 0;
    final threshold = width * _thresholdFraction;
    final velocity = details.velocity.pixelsPerSecond.dx;
    // Project the release momentum forward so a quick flick that stopped short
    // of the threshold still commits, and a hard flick commits on speed alone.
    final projected = _dragExtent + velocity * _momentumProjection;

    VoidCallback? action;
    if (projected >= threshold || velocity >= _flickVelocity) {
      // onSwipeRight is null when disabled, which naturally no-ops.
      action = widget.onSwipeRight;
    } else if (projected <= -threshold || velocity <= -_flickVelocity) {
      action = widget.onSwipeLeft;
    }

    // Spring back to rest, seeded with the release velocity so the snap
    // continues the finger's motion instead of a dead linear tween.
    final from = _dragExtent;
    _dragExtent = 0;
    _settle.animateWith(SpringSimulation(_spring, from, 0, velocity));

    // Fire after the snap-back is kicked off so the sheet opens immediately.
    action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final offset = _offset;
    return Stack(
      children: [
        if (offset != 0)
          Positioned.fill(
            child: offset > 0
                ? const _SwipeBackground.send()
                : const _SwipeBackground.burn(),
          ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          child: Transform.translate(
            offset: Offset(offset, 0),
            // Opaque row so the action panel is only revealed by the slide,
            // not visible through the row itself.
            child: ColoredBox(
              color: context.mallowColors.bgSurface,
              child: widget.child,
            ),
          ),
        ),
      ],
    );
  }
}

/// Colored panel revealed behind a token row during a swipe: green "Send" on a
/// right-swipe, red "Burn" on a left-swipe.
class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground.send() : _isBurn = false;
  const _SwipeBackground.burn() : _isBurn = true;

  final bool _isBurn;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      color: _isBurn ? colors.negative : colors.positive,
      alignment: _isBurn ? Alignment.centerRight : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _isBurn
                ? Icons.local_fire_department_rounded
                : Icons.arrow_upward_rounded,
            color: Colors.white,
            size: 22,
          ),
          const SizedBox(width: MallowTheme.spacingXs),
          Text(
            _isBurn ? 'Burn' : 'Send',
            style: MallowTheme.uiMeta.copyWith(color: Colors.white),
          ),
        ],
      ),
    );
  }
}
