import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/data/mallow_tokens.dart' as mallow_tokens;
import '../../../core/models/account.dart' show WalletInfo;
import '../../../core/result/app_failure.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/priority_fee_service.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/utils/token_amount.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/balance_check.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../portfolio/data/jupiter_verified_token_list_service.dart';
import '../../portfolio/data/session_portfolio_aggregator.dart';
import '../../portfolio/models/token_balance.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../../send/widgets/send_sheet_widgets.dart';
import '../../send/widgets/send_wallet_select_sheet.dart';
import '../services/swap_bloc.dart';
import '../swap_constants.dart';
import 'swap_settings_sheet.dart';
import 'token_selector_modal.dart';

import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/chain_support_guard.dart';

/// Opens the swap sheet.
///
/// The sheet always owns its [TokenBalanceBloc] rather than inheriting the
/// caller's: a swap is funded and signed by the active wallet alone, so the
/// balances it shows and gates on must be that signer's — never the
/// session-wide aggregate the portfolio header/tokens tab displays. Post-swap,
/// the screen behind still refreshes via `TokenRepository.balancesInvalidated`.
/// The sell *picker* is deliberately wider than that (`_sessionTokens`): it
/// lists every session wallet's holdings, and narrows a pick back to the
/// signer's own balance while the funding wallet is re-adopted.
/// [initialSellToken]/[initialBuyToken] pre-select the two sides (e.g.
/// the token detail sheet seeds its token as sell and the chain's base token
/// as buy); omit either to fall back to the default seeding. Amounts on the
/// seeded tokens are re-read from this sheet's own balances.
///
/// Entry gate for `solana:token-swap`. Gating
/// here rather than at the callers means all three inherit it, and a killed
/// swap is explained before the user picks tokens instead of failing at the
/// signing backstop.
///
/// The chain gate rides along for the same reason: swap is Jupiter-backed and
/// Solana-only, and an ETH/Tezos-only session that reached the sheet would get
/// a sell side seeded with the first native token of *any* chain and a raw
/// backend error on the first quote. Callers may still read
/// [sessionSupportsFlow] to grey their button — this is the backstop that makes
/// a missed call site harmless.
Future<void> showSwapSheet(
  BuildContext context, {
  TokenBalance? initialSellToken,
  TokenBalance? initialBuyToken,
}) async {
  if (guardUnsupportedChain(context, AppFlow.tokenSwap, action: 'Swap')) {
    return;
  }
  if (await guardFlowDisabled(
    context,
    const FlowKey.solana(AppFlow.tokenSwap),
  )) {
    return;
  }
  if (!context.mounted) return;

  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) =>
              sl<TokenBalanceBloc>()..add(const TokenBalanceEvent.load()),
        ),
        BlocProvider(create: (_) => sl<SwapBloc>()),
      ],
      child: SwapSheet(
        initialSellToken: initialSellToken,
        initialBuyToken: initialBuyToken,
      ),
    ),
  );
}

class SwapSheet extends StatefulWidget {
  const SwapSheet({super.key, this.initialSellToken, this.initialBuyToken});

  final TokenBalance? initialSellToken;
  final TokenBalance? initialBuyToken;

  @override
  State<SwapSheet> createState() => _SwapSheetState();
}

class _SwapSheetState extends State<SwapSheet> {
  final _amountController = TextEditingController();
  Timer? _quoteDebounce;
  Timer? _countdownTicker;
  int _secondsToRefresh = SwapConstants.quoteRefreshInterval.inSeconds;

  /// True once the user has committed to a swap (tapped Swap). Gates the
  /// `Swap Failed` event so a failed *quote* fetch — which also lands in
  /// [TxFlowFailure] — isn't mistaken for a failed swap attempt.
  bool _swapAttempted = false;

  /// The wallet that funds (and signs) the swap — `SwapBloc` resolves the same
  /// address via `WalletManager.getAddress()` when it quotes.
  String? _sourceAddress;

  /// Signable Solana wallets in the session holding the sell token — the
  /// candidates for the "Your wallet · Switch" line. Switch only appears with
  /// two or more.
  List<SendSourceCandidate> _sources = const [];

  /// True while the picker is open / a switch is settling. Blocks the Swap CTA
  /// so a quote built for the outgoing wallet can never be signed mid-switch.
  bool _switching = false;

  /// True once the funding wallet is settled: the active wallet holds the sell
  /// token, the auto-switch to the wallet that does has committed, or the user
  /// picked a wallet themselves. Blocks any further auto-switch so a late
  /// balance refresh can't pull the user off the wallet in play.
  bool _fundingSettled = false;

  /// Every Solana token the session's **signable** wallets hold, merged per
  /// mint — the sell picker's rows.
  ///
  /// Wider than [_heldTokens] on purpose. The swap is signed by one wallet, but
  /// the sheet auto-switches to whichever session wallet holds the sell token
  /// ([_adoptFundedSource]), so scoping the picker to the active signer hid
  /// holdings that are perfectly sellable — and that the portfolio behind the
  /// sheet lists. Empty until the first read lands (and if it fails), in which
  /// case the picker falls back to the active signer's own balances.
  List<TokenBalance> _sessionTokens = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadSourceAddress());
    unawaited(_loadSessionTokens());
    // Seed any pre-selected sides before the first balance push so
    // _onBalancesUpdated refreshes (rather than overwrites) them.
    final sell = widget.initialSellToken;
    final buy = widget.initialBuyToken;
    if (sell != null) {
      context.read<SwapBloc>().add(SwapEvent.setSellToken(sell));
    }
    if (buy != null) {
      context.read<SwapBloc>().add(SwapEvent.setBuyToken(buy));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pushBalances(context.read<TokenBalanceBloc>().state);
      unawaited(_loadSources(context.read<SwapBloc>().state.sellToken));
    });
    _countdownTicker = Timer.periodic(const Duration(seconds: 1), _onTick);
  }

  @override
  void dispose() {
    _quoteDebounce?.cancel();
    _countdownTicker?.cancel();
    _amountController.dispose();
    super.dispose();
  }

  /// Loaded balances from this sheet's [TokenBalanceBloc], **Solana only**.
  ///
  /// The bloc merges the session's Ethereum and Tezos balances in alongside the
  /// Solana ones, but swap is Jupiter-backed and no provider is wired for the
  /// other chains yet — an ETH or XTZ row in either picker can only produce a
  /// quote that fails. Filtering at the one place both the bloc and the pickers
  /// read from also keeps the default seeding honest: `_onBalancesUpdated`
  /// takes the first `isNative` row it sees, and the repository's sort pins
  /// *every* chain's native coin ahead of the rest, so a session whose Solana
  /// wallet is empty could seed the sell side with native ETH or tez.
  List<TokenBalance> _solanaBalances(TokenBalanceState state) => state.maybeMap(
    loaded: (s) => s.tokens.where((t) => t.chain == Chain.solana).toList(),
    orElse: () => const <TokenBalance>[],
  );

  void _pushBalances(TokenBalanceState state) {
    final tokens = _solanaBalances(state);
    if (tokens.isEmpty) return;
    context.read<SwapBloc>().add(SwapEvent.balancesUpdated(tokens));
  }

  Future<void> _loadSourceAddress() async {
    try {
      final address = await sl<WalletManager>().getAddress();
      if (mounted) setState(() => _sourceAddress = address);
    } catch (_) {
      // No wallet resolvable — the source line simply stays hidden.
    }
  }

  /// Candidate funding wallets for [sell]. Swap always signs with the active
  /// **Solana** wallet (`WalletManager.getAddress()`), so a non-Solana sell
  /// side has no source to pick and the affordance stays hidden.
  Future<void> _loadSources(TokenBalance? sell, {bool refresh = false}) async {
    if (sell == null || sell.chain != Chain.solana) {
      if (mounted && _sources.isNotEmpty) setState(() => _sources = const []);
      return;
    }
    final mint = sell.mint;
    final candidates = await sl<SessionPortfolioAggregator>()
        .sendSourcesForMint(chain: Chain.solana, mint: mint, refresh: refresh);
    if (!mounted) return;
    // The sell side may have changed while the balances were being read.
    if (context.read<SwapBloc>().state.sellToken?.mint != mint) return;
    setState(() => _sources = candidates);
    if (_fundingSettled) return;
    if (await _adoptFundedSource(sell, candidates)) {
      _fundingSettled = true;
    } else if (!refresh && mounted) {
      // Candidates come from the per-wallet balance cache, which reports an
      // unread sibling at zero — confirm against the network before concluding
      // that no session wallet can fund the swap.
      await _loadSources(sell, refresh: true);
    } else {
      _fundingSettled = true;
    }
  }

  /// Point the swap at a wallet that can actually fund it. The sheet is often
  /// opened for a token the active signer doesn't hold — the portfolio it was
  /// opened from aggregates every session wallet, while a swap is funded and
  /// signed by the active wallet alone — so adopt the session wallet holding
  /// the sell token instead of dead-ending on an empty balance.
  ///
  /// Returns true once the funding wallet is settled: the active wallet already
  /// holds [sell], or the switch to the wallet that does has committed. Returns
  /// false when no session wallet holds it — the sheet then stays exactly where
  /// it is, since there is nothing better to switch to — or when the switch
  /// failed, leaving the user the manual Switch affordance.
  Future<bool> _adoptFundedSource(
    TokenBalance sell,
    List<SendSourceCandidate> candidates,
  ) async {
    if (_switching) return false;
    if (_sourceAddress == null) await _loadSourceAddress();
    final active = _sourceAddress;
    if (active == null || !mounted) return false;
    final picked = pickFundingSource(
      candidates,
      activeAddress: active,
      isNative: sell.isNative,
    );
    if (picked == null) return false;
    final target = picked.wallet;
    if (target.address == active) return true;
    // Set before the switch: _onSourceSwitched re-reads the candidates for the
    // new wallet, and that pass must not re-enter the auto-switch.
    _fundingSettled = true;
    setState(() => _switching = true);
    try {
      await sl<SessionManager>().selectSourceWallet(target);
    } catch (_) {
      // Silent — the user never asked for this switch, so a failure snackbar
      // would blame them for a tap they never made. The swap stays on the
      // active wallet and blocks truthfully at the balance check.
      if (mounted) setState(() => _switching = false);
      return false;
    }
    if (!mounted) return true;
    setState(() => _switching = false);
    _onSourceSwitched(target);
    return true;
  }

  /// "Switch" tapped — open the shared picker, which commits the signer switch
  /// itself (and keeps itself open on failure). It resolves `null` on cancel or
  /// on a failed switch, in which case the flow stays on the previous wallet.
  Future<void> _onSwitchSource(TokenBalance sellToken) async {
    if (_switching) return;
    String? activeWalletId;
    for (final c in _sources) {
      if (c.wallet.address == _sourceAddress) {
        activeWalletId = c.wallet.id;
        break;
      }
    }
    setState(() => _switching = true);
    try {
      final chosen = await showSendWalletSelectSheet(
        context,
        chain: Chain.solana,
        tokenSymbol: sellToken.symbol,
        candidates: _sources,
        activeWalletId: activeWalletId,
      );
      if (!mounted || chosen == null) return;
      // An explicit choice outranks the auto-switch: a balance refresh landing
      // afterwards must not move the user off the wallet they picked.
      _fundingSettled = true;
      if (chosen.address != _sourceAddress) _onSourceSwitched(chosen);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// Re-derive everything that was computed for the previous wallet: the quote
  /// (the bloc drops it and re-fetches for the new taker) and the balances the
  /// sell-side row and Half/Max read from.
  void _onSourceSwitched(WalletInfo wallet) {
    final bloc = context.read<SwapBloc>();
    setState(() {
      _sourceAddress = wallet.address;
      _secondsToRefresh = SwapConstants.quoteRefreshInterval.inSeconds;
    });
    bloc.add(const SwapEvent.sourceWalletChanged());
    context.read<TokenBalanceBloc>().add(const TokenBalanceEvent.refresh());
    unawaited(_loadSources(bloc.state.sellToken));
  }

  void _onTick(Timer _) {
    final flow = context.read<SwapBloc>().state.flow;
    if (flow is! TxFlowReady<SwapQuoteData, SwapSuccessData>) return;
    if (_secondsToRefresh <= 1) {
      _refreshQuote();
    } else {
      setState(() => _secondsToRefresh--);
    }
  }

  void _refreshQuote() {
    setState(
      () => _secondsToRefresh = SwapConstants.quoteRefreshInterval.inSeconds,
    );
    context.read<SwapBloc>().add(const SwapEvent.getQuote());
  }

  void _onAmountChanged(String value) {
    context.read<SwapBloc>().add(SwapEvent.setAmount(value));
    _quoteDebounce?.cancel();
    _quoteDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _refreshQuote();
    });
  }

  void _setAmount(double amount) {
    final text = stripTrailingZeros(amount.toStringAsFixed(9));
    _amountController.text = text;
    _amountController.selection = TextSelection.collapsed(offset: text.length);
    context.read<SwapBloc>().add(SwapEvent.setAmount(text));
    _refreshQuote();
  }

  void _onHalf(TokenBalance token) => _setAmount(token.uiBalance / 2);

  void _onMax(TokenBalance token) {
    // Native SOL keeps headroom for fees + rent so Max doesn't produce an
    // unpayable transaction.
    final raw = token.isNative
        ? (token.rawBalance - SwapConstants.maxReserveLamports).clamp(
            0,
            token.rawBalance,
          )
        : token.rawBalance;
    _setAmount(
      double.parse(
        TokenAmount.formatTokenAmount(BigInt.from(raw), token.decimals),
      ),
    );
  }

  Future<void> _openSettings() async {
    // Gas is paid on the chain the sell side lives on.
    final chain =
        context.read<SwapBloc>().state.sellToken?.chain ?? Chain.solana;
    final prefs = sl<PreferencesService>();
    final fee = sl<PriorityFeeService>();
    final before = (prefs.swapSlippageBps, fee.routerLamports);
    await showSwapSettingsSheet(context, chain: chain);
    if (!mounted) return;
    context.read<SwapBloc>().add(const SwapEvent.settingsChanged());
    // `settingsChanged` re-fetches the order with the new slippage / priority
    // fee — restart the countdown so the ticker doesn't fire a duplicate
    // refresh moments later.
    if (before != (prefs.swapSlippageBps, fee.routerLamports)) {
      setState(
        () => _secondsToRefresh = SwapConstants.quoteRefreshInterval.inSeconds,
      );
    }
  }

  List<TokenBalance> _heldTokens() =>
      _solanaBalances(context.read<TokenBalanceBloc>().state);

  /// Fills [_sessionTokens] from the per-wallet cache first — instant, and the
  /// portfolio this sheet was opened from has already written it — then from
  /// the network, so a session wallet whose cache was never read still
  /// contributes its holdings.
  Future<void> _loadSessionTokens() async {
    final aggregator = sl<SessionPortfolioAggregator>();
    // Cache first, then the network — sequentially, so a fast network pass
    // can't be clobbered by a slower cache read landing after it. An empty
    // result is a failed fan-out far more often than a session that genuinely
    // holds nothing (each wallet degrades to an empty list of its own), so it
    // never wipes rows an earlier pass produced; a throw leaves them alone for
    // the same reason, and the picker falls back to the active signer's
    // balances if neither pass produced anything.
    for (final refresh in const [false, true]) {
      try {
        final tokens = await aggregator.signableSolanaBalances(
          refresh: refresh,
        );
        if (!mounted) return;
        if (tokens.isNotEmpty) setState(() => _sessionTokens = tokens);
      } catch (_) {
        // Try the next pass, or keep what the previous one produced.
      }
    }
  }

  /// Both pickers' rows: everything the session's signable wallets hold — the
  /// same holdings the portfolio's Tokens tab lists — falling back to the
  /// active signer's own balances until that read lands.
  List<TokenBalance> _sessionCandidates() =>
      _sessionTokens.isEmpty ? _heldTokens() : _sessionTokens;

  /// [selected] as the *signing* wallet holds it, at zero when it holds none.
  ///
  /// The pickers' rows are summed across the session; the sheet's Balance line
  /// and Half/Max spend the signing wallet's holding alone. Defers to
  /// [SwapBloc.narrowToHeld] — the same rule the bloc re-applies on the next
  /// balance push — so the row can never briefly offer another wallet's funds.
  TokenBalance _signerBalanceFor(TokenBalance selected) =>
      SwapBloc.narrowToHeld(selected, _heldTokens());

  Future<void> _selectSellToken() async {
    final selected = await showMallowSheet<TokenBalance>(
      context: context,
      isScrollControlled: true,
      builder: (_) => TokenSelectorModal(
        tokens: _sessionCandidates(),
        title: 'Select token to sell',
      ),
    );
    if (selected == null || !mounted) return;
    // A pick that *changes* the sell token re-opens the funding question: the
    // new token may be held only by a sibling wallet, and without this the latch
    // would leave the swap pointed at a signer with none of it. Re-picking the
    // token already selected must not clear it — the re-settle rides on the
    // sell-token listener in [build], which only fires on a mint/chain change,
    // so a no-op pick would drop the latch with nothing left to close it and
    // let the next candidate read auto-switch the user off a wallet they chose.
    final current = context.read<SwapBloc>().state.sellToken;
    if (selected.mint != current?.mint || selected.chain != current?.chain) {
      _fundingSettled = false;
    }
    context.read<SwapBloc>().add(
      SwapEvent.setSellToken(_signerBalanceFor(selected)),
    );
    _refreshQuote();
  }

  Future<void> _selectBuyToken() async {
    // Buy side also offers registry tokens the user doesn't hold yet.
    final owned = _sessionCandidates();
    final ownedMints = owned.map((t) => t.mint).toSet();
    final tokens = [
      ...owned,
      for (final token in mallow_tokens.swappableTokens())
        if (!ownedMints.contains(token.mint))
          TokenBalance(
            mint: token.mint,
            symbol: token.symbol,
            name: token.symbol,
            decimals: token.decimals,
            rawBalance: 0,
            uiBalance: 0,
            isNative: token.mint == mallow_tokens.solMint,
            isVerified: true,
          ),
    ];
    // Warm the verified catalog while the user is still reading the list, so
    // the first keystroke usually searches a populated cache instead of
    // blocking on the ~5 MB cold fetch.
    unawaited(sl<JupiterVerifiedTokenListService>().ensureCached());
    final selected = await showMallowSheet<TokenBalance>(
      context: context,
      isScrollControlled: true,
      builder: (_) => TokenSelectorModal(
        tokens: tokens,
        title: 'Select token to buy',
        catalogSearch: _searchVerifiedTokens,
        browseTabs: (owned: owned, popular: () => _popularTokens(tokens)),
      ),
    );
    if (selected != null && mounted) {
      context.read<SwapBloc>().add(
        SwapEvent.setBuyToken(_signerBalanceFor(selected)),
      );
      _refreshQuote();
    }
  }

  /// Buy-side catalog search: every Jupiter-verified Solana mint, not just the
  /// held balances and the hardcoded registry. Balances are zero because the
  /// user by definition doesn't hold these — [TokenBalanceBloc] fills the real
  /// figure in once a catalog token is picked, same as the registry rows above.
  Future<List<TokenBalance>> _searchVerifiedTokens(String query) async {
    final hits = await sl<JupiterVerifiedTokenListService>().search(query);
    return hits.map(_catalogTokenBalance).toList(growable: false);
  }

  /// Buy-side "Popular" tab: mallowSOL, then the verified catalog's
  /// highest-24h-volume mints.
  ///
  /// mallowSOL is pinned rather than ranked — it is mallow's own token and the
  /// sheet's default buy side, but it trades ~1500th by volume, so the ranking
  /// alone would leave it off the tab entirely.
  ///
  /// [local] is the picker's own row set (session holdings + registry). Rows are
  /// substituted from it by mint so a token the user already owns shows its real
  /// balance here instead of the catalog's placeholder zero — and so the pinned
  /// row exists even when the catalog is cold, since the registry always
  /// supplies mallowSOL. The substitution keeps the catalog's verified tag: a
  /// held row carries `isVerified` from market-data enrichment, which may not
  /// have landed, and every ranked row here comes from the verified list by
  /// definition — without it a top-volume token renders under the picker's
  /// "Unverified" header.
  Future<List<TokenBalance>> _popularTokens(List<TokenBalance> local) async {
    final byMint = {for (final token in local) token.mint: token};
    final top = await sl<JupiterVerifiedTokenListService>().popular();
    return [
      ?byMint[mallow_tokens.mallowSolMint],
      for (final token in top)
        if (token.mint != mallow_tokens.mallowSolMint)
          byMint[token.mint]?.copyWith(isVerified: true) ??
              _catalogTokenBalance(token),
    ];
  }

  TokenBalance _catalogTokenBalance(JupiterListToken token) => TokenBalance(
    mint: token.mint,
    symbol: token.symbol,
    name: token.name,
    decimals: token.decimals,
    rawBalance: 0,
    uiBalance: 0,
    logoUrl: token.iconUrl,
    isNative: token.mint == mallow_tokens.solMint,
    isVerified: true,
  );

  void _onFlowChanged(BuildContext context, SwapState state) {
    final flow = state.flow;
    if (flow is TxFlowSuccess<SwapQuoteData, SwapSuccessData>) {
      final result = flow.result;
      final sell = state.sellToken;
      final usd = sell == null
          ? null
          : sl<TokenPriceService>().usdValueOfRaw(
              TokenAmount.toInt(
                TokenAmount.parseTokenAmount(state.amount, sell.decimals),
              ),
              sell.mint,
            );
      unawaited(
        sl<AnalyticsService>().trackTransaction(
          AnalyticsEvent.swapCompleted,
          txType: TxType.swap,
          signature: flow.signature,
          properties: {
            AnalyticsProp.inputMint: sell?.mint,
            AnalyticsProp.outputMint: state.buyToken?.mint,
            AnalyticsProp.inputSymbol: result.inputSymbol,
            AnalyticsProp.outputSymbol: result.outputSymbol,
            AnalyticsProp.usdValue: usd,
          },
          entryPoint: EntryPoint.swapTab,
        ),
      );
      _swapAttempted = false;
      AppSnackBar.show(
        context,
        'Swapped ${stripTrailingZeros(result.inputAmount.toStringAsFixed(6))} '
        '${result.inputSymbol} for '
        '${stripTrailingZeros(result.outputAmount.toStringAsFixed(6))} '
        '${result.outputSymbol}',
        type: AppSnackBarType.success,
      );
      // Stay open so the user can swap again — clear the form back to idle,
      // keeping the selected tokens. Balances are refreshed by the bloc, which
      // reconciles them against the confirmed tx and then signals the portfolio
      // to reload; firing a refresh here as well would only start an earlier
      // (still pre-swap) Helius read that the repository's in-flight
      // coalescing would hand straight back to that reload.
      _amountController.clear();
      context.read<SwapBloc>().add(const SwapEvent.reset());
      setState(
        () => _secondsToRefresh = SwapConstants.quoteRefreshInterval.inSeconds,
      );
    } else if (flow is TxFlowFailure<SwapQuoteData, SwapSuccessData>) {
      // Only a *committed* swap counts as a failed swap — a failed quote
      // fetch lands here too but isn't a swap attempt.
      if (_swapAttempted) {
        // A kill-switch stop is not a swap failure: it gets its own
        // `flow_disabled_hit` from [handleFlowDisabled] and must not be bucketed
        // into the failure taxonomy at all.
        if (!flow.failure.isFlowDisabled) {
          unawaited(
            sl<AnalyticsService>().trackTransaction(
              AnalyticsEvent.swapFailed,
              txType: TxType.swap,
              // No signature: the swap never reached a confirmed broadcast.
              isOnchainTx: false,
              properties: {
                AnalyticsProp.reason: _swapFailureReason(flow.failure).wire,
              },
              entryPoint: EntryPoint.swapTab,
            ),
          );
        }
        _swapAttempted = false;
      }
      // The operator's message is the response. The sheet stays open
      // with the form untouched, and deliberately does NOT re-quote the way the
      // cancel branch below does: the cell is off, so a fresh quote would only
      // re-arm a CTA that can't succeed. No snackbar either — the sheet says it.
      if (handleFlowDisabled(
        context,
        flow.failure,
        flow: const FlowKey.solana(AppFlow.tokenSwap),
      )) {
        return;
      }
      if (flow.failure.isCancelled) {
        // User backed out of the auth prompt — restore the quote so the
        // form stays actionable.
        context.read<SwapBloc>().add(const SwapEvent.getQuote());
      } else {
        AppSnackBar.show(context, flow.failure.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final bottomPad = sheetBottomInset(context, includeKeyboard: false);
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;

    return MultiBlocListener(
      listeners: [
        BlocListener<TokenBalanceBloc, TokenBalanceState>(
          listener: (context, state) => _pushBalances(state),
        ),
        BlocListener<SwapBloc, SwapState>(
          listenWhen: (a, b) => a.flow.runtimeType != b.flow.runtimeType,
          listener: _onFlowChanged,
        ),
        BlocListener<SwapBloc, SwapState>(
          // Candidates are per-mint: a different sell token is a different
          // funding balance, so the picker's rows have to be re-read.
          listenWhen: (a, b) =>
              a.sellToken?.mint != b.sellToken?.mint ||
              a.sellToken?.chain != b.sellToken?.chain,
          listener: (context, state) =>
              unawaited(_loadSources(state.sellToken)),
        ),
      ],
      child: Container(
        decoration: BoxDecoration(
          color: colors.bgPrimary,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MallowTheme.popupRadius),
          ),
        ),
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: BlocBuilder<SwapBloc, SwapState>(
          builder: (context, state) {
            // Scrollable so the open keyboard can't overflow small screens.
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SheetDragHandle(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      MallowTheme.spacing20,
                      MallowTheme.spacing12,
                      MallowTheme.spacing20,
                      MallowTheme.spacing20,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _header(context),
                        const SizedBox(height: MallowTheme.spacingLg),
                        _sideLabel(context, 'Sell', state.sellToken),
                        const SizedBox(height: MallowTheme.spacing12),
                        _sellCard(context, state),
                        const SizedBox(height: MallowTheme.spacing12),
                        _halfMaxRow(context, state),
                        const SizedBox(height: MallowTheme.spacingLg),
                        _sideLabel(context, 'Buy', state.buyToken),
                        const SizedBox(height: MallowTheme.spacing12),
                        _buyCard(context, state),
                        const SizedBox(height: MallowTheme.spacingLg),
                        _rateRow(context, state),
                        const SizedBox(height: MallowTheme.spacingLg),
                        ?_sourceLine(context, state),
                        _swapButton(context, state),
                      ],
                    ),
                  ),
                  SizedBox(height: bottomPad),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text('Swap', style: MallowTheme.editorialSection)),
        TapTargetExpander(
          child: GestureDetector(
            onTap: _openSettings,
            behavior: HitTestBehavior.opaque,
            child: MallowSvgIcon(
              'assets/icons/settings.svg',
              width: 24,
              height: 24,
              color: context.mallowColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _sideLabel(BuildContext context, String label, TokenBalance? token) {
    final colors = context.mallowColors;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: MallowTheme.uiLabel.copyWith(color: colors.textPrimary),
          ),
        ),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'Balance: ',
                style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
              ),
              TextSpan(
                text: token == null ? '—' : formatBalance(token.uiBalance),
                style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sellCard(BuildContext context, SwapState state) {
    final colors = context.mallowColors;
    final sellToken = state.sellToken;

    double? usd = state.quoteData?.order.inUsdValue?.toDouble();
    if (usd == null && sellToken != null) {
      final raw = TokenAmount.toInt(
        TokenAmount.parseTokenAmount(state.amount, sellToken.decimals),
      );
      usd = sl<TokenPriceService>().usdValueOfRaw(raw, sellToken.mint);
    }

    return _card(
      context,
      chip: _tokenChip(context, sellToken, onTap: _selectSellToken),
      amount: TextField(
        controller: _amountController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
        ],
        onChanged: _onAmountChanged,
        textAlign: TextAlign.right,
        style: MallowTheme.uiDisplay,
        decoration: InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          hintText: '0',
          hintStyle: MallowTheme.uiDisplay.copyWith(
            color: colors.textSecondary,
          ),
        ),
      ),
      meta: usd == null ? null : '~\$${usd.toStringAsFixed(2)}',
    );
  }

  Widget _buyCard(BuildContext context, SwapState state) {
    final colors = context.mallowColors;
    final quote = state.quoteData;

    String? meta;
    if (quote != null) {
      final inUsd = quote.order.inUsdValue?.toDouble();
      final outUsd = quote.order.outUsdValue?.toDouble();
      if (outUsd != null) {
        meta = '~\$${outUsd.toStringAsFixed(2)}';
        if (inUsd != null && inUsd > 0) {
          final diffPct = (outUsd - inUsd) / inUsd * 100;
          meta += ' (${diffPct.toStringAsFixed(2)}%)';
        }
      }
    }

    return _card(
      context,
      chip: _tokenChip(context, state.buyToken, onTap: _selectBuyToken),
      amount: Text(
        quote == null ? '0' : _formatAmount(quote.outputAmount),
        textAlign: TextAlign.right,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: MallowTheme.uiDisplay.copyWith(
          color: quote == null ? colors.textSecondary : colors.textPrimary,
        ),
      ),
      meta: meta,
    );
  }

  Widget _card(
    BuildContext context, {
    required Widget chip,
    required Widget amount,
    String? meta,
  }) {
    final colors = context.mallowColors;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: BorderRadius.circular(MallowTheme.radiusMd),
      ),
      child: Row(
        children: [
          chip,
          const SizedBox(width: MallowTheme.spacing12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                amount,
                if (meta != null) ...[
                  const SizedBox(height: MallowTheme.spacingXs),
                  Text(
                    meta,
                    style: MallowTheme.uiMeta.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tokenChip(
    BuildContext context,
    TokenBalance? token, {
    required VoidCallback onTap,
  }) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (token != null) ...[
              tokenImageWidget(
                mint: token.mint,
                size: 24,
                symbol: token.symbol,
                logoUrl: token.logoUrl,
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Text(token.symbol, style: MallowTheme.uiBody),
            ] else
              Text(
                'Select token',
                style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
              ),
            const SizedBox(width: MallowTheme.spacingSm),
            MallowSvgIcon(
              'assets/icons/arrow_down.svg',
              width: 6,
              height: 6,
              color: colors.textPrimary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _halfMaxRow(BuildContext context, SwapState state) {
    final token = state.sellToken;
    if (token == null) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        _smallButton(context, 'Half', () => _onHalf(token)),
        const SizedBox(width: MallowTheme.spacingSm),
        _smallButton(context, 'Max', () => _onMax(token)),
      ],
    );
  }

  Widget _smallButton(BuildContext context, String label, VoidCallback onTap) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacingSm,
            vertical: MallowTheme.spacingXs,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: colors.divider),
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
          child: Text(
            label,
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ),
      ),
    );
  }

  Widget _rateRow(BuildContext context, SwapState state) {
    final colors = context.mallowColors;
    final quote = state.quoteData;
    final sellToken = state.sellToken;
    final buyToken = state.buyToken;
    if (quote == null || sellToken == null || buyToken == null) {
      // Keep the row's height stable so the sheet doesn't jump when the
      // first quote lands.
      return const SizedBox(height: 16);
    }
    return Row(
      children: [
        Expanded(
          child: Text(
            '1 ${sellToken.symbol} ≈ ${_formatAmount(quote.rate)} '
            '${buyToken.symbol}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
          ),
        ),
        Text(
          'Refresh in $_secondsToRefresh sec',
          style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(width: MallowTheme.spacingSm),
        TapTargetExpander(
          child: GestureDetector(
            onTap: _refreshQuote,
            behavior: HitTestBehavior.opaque,
            child: MallowSvgIcon(
              'assets/icons/sync.svg',
              width: 16,
              height: 16,
              color: colors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  /// "Your wallet: `<addr>` · Switch" above the CTA. Null when there is no
  /// resolvable source wallet; the Switch action itself is hidden unless the
  /// session offers a second candidate for the sell token.
  Widget? _sourceLine(BuildContext context, SwapState state) {
    final address = _sourceAddress;
    final sellToken = state.sellToken;
    if (address == null) return null;
    // Mid-swap the transaction is already committed to the current wallet;
    // switching then would leave the two out of step.
    final canSwitch =
        _sources.length >= 2 &&
        !_switching &&
        !_isBusy(state.flow) &&
        sellToken != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SendSourceLine(
          address: address,
          onSwitch: canSwitch ? () => _onSwitchSource(sellToken) : null,
        ),
        const SizedBox(height: MallowTheme.spacing12),
      ],
    );
  }

  static bool _isBusy(SwapFlowState flow) =>
      flow is TxFlowPreparing<SwapQuoteData, SwapSuccessData> ||
      flow is TxFlowSigning<SwapQuoteData, SwapSuccessData> ||
      flow is TxFlowBroadcasting<SwapQuoteData, SwapSuccessData>;

  Widget _swapButton(BuildContext context, SwapState state) {
    final isBusy = _isBusy(state.flow);
    final quote = state.quoteData;
    final sellToken = state.sellToken;

    return BlocBuilder<TokenBalanceBloc, TokenBalanceState>(
      builder: (context, balanceState) {
        int? requiredRaw;
        if (sellToken != null && state.amount.isNotEmpty) {
          final big = TokenAmount.parseTokenAmount(
            state.amount,
            sellToken.decimals,
          );
          if (big > BigInt.zero) requiredRaw = TokenAmount.toInt(big);
        }
        final balanceResult = checkBalanceOrSkip(
          paymentMint: sellToken?.mint,
          requiredRawAmount: requiredRaw,
          balanceState: balanceState,
        );

        return MallowButton(
          label: 'Swap',
          isFullWidth: true,
          isLoading: isBusy,
          // Disabled while a switch is in flight: the current quote belongs to
          // the outgoing wallet until the re-quote lands.
          enabled: quote != null && quote.canExecute && !isBusy && !_switching,
          onPressed: () {
            if (!ensureSufficientBalance(context, balanceResult)) return;
            _swapAttempted = true;
            context.read<SwapBloc>().add(const SwapEvent.execute());
          },
        );
      },
    );
  }

  /// Swap amounts/rates keep more precision than balances — e.g. `1.039485`.
  static String _formatAmount(double value) {
    if (value == 0) return '0';
    final digits = value >= 1 ? 6 : 9;
    return stripTrailingZeros(value.toStringAsFixed(digits));
  }
}

/// Bucket a swap [AppFailure] into the analytics [FailureReason] taxonomy.
/// Message keywords (Jupiter surfaces "slippage"/"insufficient") win over the
/// coarse [AppFailure.kind]; anything unmapped → [FailureReason.unknown].
///
/// A kill-switch stop never reaches here: the call site drops the `Swap Failed`
/// event entirely, because an operator switching a flow off is not a failure of
/// the swap.
FailureReason _swapFailureReason(AppFailure failure) {
  if (failure.isCancelled) return FailureReason.userRejected;
  final msg = failure.message.toLowerCase();
  if (msg.contains('slippage')) return FailureReason.slippageExceeded;
  if (msg.contains('insufficient')) {
    return msg.contains('fee') || msg.contains('rent')
        ? FailureReason.insufficientFees
        : FailureReason.insufficientFunds;
  }
  if (msg.contains('timed out') || msg.contains('timeout')) {
    return FailureReason.timeout;
  }
  return switch (failure.kind) {
    AppFailureKind.network => FailureReason.networkError,
    AppFailureKind.rpc => FailureReason.simulationFailed,
    AppFailureKind.signing => FailureReason.signatureFailed,
    _ => FailureReason.unknown,
  };
}
