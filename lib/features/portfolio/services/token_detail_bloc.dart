import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../data/ethereum_token_info_service.dart';
import '../data/gecko_terminal_service.dart';
import '../data/jupiter_token_info_service.dart';
import '../data/session_portfolio_aggregator.dart';
import '../data/token_repository.dart';
import '../data/token_transfer_repository.dart';
import '../models/jupiter_token_info.dart';
import '../models/ohlcv_candle.dart';
import '../models/token_balance.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/data/address_scope_key.dart';
import '../../../core/services/active_networks.dart';
import '../../../shared/utils/chain.dart';
part 'token_detail_bloc.freezed.dart';

@freezed
sealed class TokenDetailEvent with _$TokenDetailEvent {
  const factory TokenDetailEvent.load(TokenBalance token) = TokenDetailLoad;
  const factory TokenDetailEvent.timeframeChanged(ChartTimeframe timeframe) =
      TokenDetailTimeframeChanged;
  const factory TokenDetailEvent.refresh() = TokenDetailRefresh;
  const factory TokenDetailEvent.loadMoreHistory() = TokenDetailLoadMoreHistory;

  /// The cached balances of [walletAddress] were mutated out-of-band — see
  /// [TokenRepository.balancesInvalidated].
  const factory TokenDetailEvent.balancesInvalidated(String walletAddress) =
      TokenDetailBalancesInvalidated;
}

@freezed
sealed class TokenDetailState with _$TokenDetailState {
  const factory TokenDetailState.initial() = TokenDetailInitial;
  const factory TokenDetailState.loading({required TokenBalance token}) =
      TokenDetailLoading;
  const factory TokenDetailState.loaded({
    required TokenBalance token,
    JupiterTokenInfo? tokenInfo,
    @Default([]) List<OhlcvCandle> candles,
    @Default(ChartTimeframe.oneDay) ChartTimeframe timeframe,
    @Default([]) List<api.Activity> activities,
    String? historyPaginationToken,

    /// [addressScopeKey] of the wallets [activities] and
    /// [historyPaginationToken] were fetched over — null when that scope was
    /// empty, so nothing was fetched.
    ///
    /// The cursor is a composite keyed by those exact addresses, and the scope
    /// can move while the sheet is open, so load-more compares against this
    /// before reusing it. See [TokenDetailBloc._onLoadMoreHistory].
    String? historyScopeKey,
    @Default(false) bool hasMoreHistory,
    @Default(false) bool isLoadingMoreHistory,
    @Default(false) bool isChartLoading,
    @Default(false) bool isRefreshing,
  }) = TokenDetailLoaded;
  const factory TokenDetailState.error(String message) = TokenDetailError;
}

@injectable
class TokenDetailBloc extends Bloc<TokenDetailEvent, TokenDetailState> {
  TokenDetailBloc(
    this._jupiterInfoService,
    this._ethInfoService,
    this._geckoService,
    this._transferRepository,
    this._walletManager,
    this._tokenRepository,
    this._aggregator,
    this._activeNetworks,
  ) : super(const TokenDetailState.initial()) {
    on<TokenDetailLoad>(_onLoad);
    on<TokenDetailTimeframeChanged>(_onTimeframeChanged);
    on<TokenDetailRefresh>(_onRefresh);
    on<TokenDetailLoadMoreHistory>(_onLoadMoreHistory);
    on<TokenDetailBalancesInvalidated>(_onBalancesInvalidated);

    // The sheet stays open across the send/swap/burn flows it launches, and
    // the holding it was opened with is a pre-transaction snapshot. A
    // confirmed transaction writes the new balance into the per-wallet cache
    // and signals here, so re-read it rather than leaving a stale position.
    _invalidationSub = _tokenRepository.balancesInvalidated.listen((address) {
      if (isClosed) return;
      add(TokenDetailEvent.balancesInvalidated(address));
    });
  }

  final JupiterTokenInfoService _jupiterInfoService;
  final EthereumTokenInfoService _ethInfoService;
  final GeckoTerminalService _geckoService;
  final TokenTransferRepository _transferRepository;
  final WalletManager _walletManager;
  final TokenRepository _tokenRepository;
  final SessionPortfolioAggregator _aggregator;
  final ActiveNetworks _activeNetworks;
  StreamSubscription<String>? _invalidationSub;

  static const _historyPageSize = 50;

  @override
  Future<void> close() async {
    await _invalidationSub?.cancel();
    return super.close();
  }

  Future<void> _onLoad(
    TokenDetailLoad event,
    Emitter<TokenDetailState> emit,
  ) async {
    final token = event.token;

    // Show cached history immediately so the History tab isn't blank while
    // the live fetch is in flight. Keyed by the scope the rows were fetched
    // over, so the cache read and the fetch below agree on one key.
    final addresses = await _historyAddresses(token);
    final cached = addresses.isEmpty
        ? const <api.Activity>[]
        : await _transferRepository.getCachedActivities(
            cacheKey: addressScopeKey(addresses),
            mint: token.mint,
            limit: _historyPageSize,
          );

    if (cached.isNotEmpty) {
      emit(
        TokenDetailState.loaded(
          token: token,
          activities: cached,
          historyScopeKey: _scopeKeyFor(addresses),
          // hasMore unknown until we hit the API; conservative: assume yes if
          // the cache filled the first page.
          hasMoreHistory: cached.length >= _historyPageSize,
          // Candles haven't been fetched yet — flag the chart as loading so
          // the skeleton shows instead of the empty-state message.
          isChartLoading: true,
        ),
      );
    } else {
      emit(TokenDetailState.loading(token: token));
    }

    await _loadAll(token, emit, timeframe: ChartTimeframe.oneDay);
  }

  Future<void> _onRefresh(
    TokenDetailRefresh event,
    Emitter<TokenDetailState> emit,
  ) async {
    final current = state;
    if (current is! TokenDetailLoaded) return;

    emit(current.copyWith(isRefreshing: true));
    await _loadAll(
      current.token,
      emit,
      timeframe: current.timeframe,
      isRefresh: true,
    );
  }

  Future<void> _onTimeframeChanged(
    TokenDetailTimeframeChanged event,
    Emitter<TokenDetailState> emit,
  ) async {
    final current = state;
    if (current is! TokenDetailLoaded) return;

    // Tezos FA tokens have no OHLCV source — just record the selection. Native
    // XTZ is chartable via CoinGecko, so it falls through to the fetch below.
    if (current.token.chain == Chain.tezos &&
        current.token.mint != TokenBalance.tezosNativeSentinel) {
      emit(current.copyWith(timeframe: event.timeframe));
      return;
    }

    emit(current.copyWith(isChartLoading: true, timeframe: event.timeframe));

    final candles = await _fetchCandles(current.token, event.timeframe);

    // Only emit if still loaded (user may have navigated away)
    final latest = state;
    if (latest is TokenDetailLoaded) {
      emit(latest.copyWith(candles: candles, isChartLoading: false));
    }
  }

  Future<void> _onLoadMoreHistory(
    TokenDetailLoadMoreHistory event,
    Emitter<TokenDetailState> emit,
  ) async {
    final current = state;
    if (current is! TokenDetailLoaded) return;
    if (current.isLoadingMoreHistory) return;
    if (!current.hasMoreHistory) return;
    if (current.historyPaginationToken == null) return;

    emit(current.copyWith(isLoadingMoreHistory: true));

    try {
      // History is resolved per chain and per session scope, and the scope can
      // move while the sheet is open: it deliberately stays up across the
      // send/swap flows it launches, and those re-point the selection
      // (`SessionManager.selectSourceWallet`).
      final addresses = await _historyAddresses(current.token);
      final scopeKey = _scopeKeyFor(addresses);

      // 🛑 The cursor is a composite keyed by the addresses of the page it came
      // from. Replaying it against a different scope matches none of the new
      // wallets, so the backend skips them all and answers with an empty page —
      // which reads here as "end of history" and strands the rest of the list
      // until the sheet is closed. A moved scope restarts pagination instead.
      if (scopeKey != current.historyScopeKey) {
        final firstPage = addresses.isEmpty
            ? const TokenTransfersResult(activities: [])
            : await _fetchFirstHistoryPage(current.token, addresses);
        emit(
          current.copyWith(
            // Replaces rather than appends: the rows on screen were fetched
            // for the old scope, while these cache under the new one.
            activities: firstPage.activities,
            historyScopeKey: scopeKey,
            historyPaginationToken: firstPage.paginationToken,
            hasMoreHistory: firstPage.hasMore,
            isLoadingMoreHistory: false,
          ),
        );
        return;
      }

      final page = await _transferRepository.fetchTransfers(
        addresses: addresses,
        mint: current.token.mint,
        paginationToken: current.historyPaginationToken,
      );

      emit(
        current.copyWith(
          activities: [...current.activities, ...page.activities],
          historyPaginationToken: page.paginationToken,
          hasMoreHistory: page.hasMore,
          isLoadingMoreHistory: false,
        ),
      );
    } catch (_) {
      emit(current.copyWith(isLoadingMoreHistory: false));
    }
  }

  /// Re-reads the displayed holding from the balance cache after a confirmed
  /// transaction mutated it. Only the balance fields move: price, market info
  /// and candles come from their own sources and a transfer doesn't touch
  /// them, so `totalUsdValue` is recomputed from the price already on screen
  /// rather than the cache's (which would make the figure jump for an
  /// unrelated reason).
  ///
  /// Every chain, resolved through [_balanceAddresses]: the Ethereum and Tezos
  /// send paths refresh their own service cache and announce it through
  /// [TokenRepository.notifyBalancesChanged], so those sheets update in place
  /// too instead of keeping the snapshot they were opened with.
  Future<void> _onBalancesInvalidated(
    TokenDetailBalancesInvalidated event,
    Emitter<TokenDetailState> emit,
  ) async {
    final current = state;
    if (current is! TokenDetailLoaded) return;

    final addresses = await _balanceAddresses(current.token.chain);
    if (!addresses.contains(event.walletAddress)) return;

    final holding = await _cachedHolding(current.token, addresses);
    if (holding == null) return;

    // The load/refresh handlers run concurrently with this one — re-read the
    // state so a fresher one isn't overwritten with the copy captured above.
    final latest = state;
    if (latest is! TokenDetailLoaded) return;
    final price = latest.token.pricePerToken;
    emit(
      latest.copyWith(
        token: latest.token.copyWith(
          rawBalance: holding.rawBalance,
          uiBalance: holding.uiBalance,
          totalUsdValue: price == null ? null : holding.uiBalance * price,
        ),
      ),
    );
  }

  /// The wallets whose cached balances make up the displayed holding on
  /// [chain]: the profile-wide set when a Profile session aggregates its
  /// portfolio, otherwise the session's active Solana wallet — or its first
  /// Solana wallet when the selection sits on another chain.
  ///
  /// Also the scope [_historyAddresses] reads the History tab over, so the tab
  /// and the balance above it always describe the same wallets.
  ///
  /// Ethereum and Tezos go through [resolveChainScope] — the same function
  /// `TokenBalanceBloc` resolves its own fan-out with, rather than a second
  /// copy of the rule that can drift from it. `aggregateAcrossSession` is true
  /// because the sheet is only ever opened over an aggregated row (the
  /// tokens tab's `TokenBalanceBloc` is the aggregating instance), so the
  /// summed holding must be rewritten from the same set it was summed over —
  /// resolving one wallet's share of it would make the balance jump *up* after
  /// a send.
  Future<List<String>> _balanceAddresses(Chain chain) async {
    switch (chain) {
      case Chain.ethereum:
      case Chain.tezos:
        return resolveChainScope(
          chain,
          sessionAddresses: chain == Chain.ethereum
              ? _aggregator.sessionEthereumAddresses()
              : _aggregator.sessionTezosAddresses(),
          activeNetworks: _activeNetworks,
          walletManager: _walletManager,
          aggregateAcrossSession: true,
        );
      case Chain.solana:
        break;
    }
    final profile = _aggregator.profilePortfolioAddresses();
    if (profile != null && profile.isNotEmpty) return profile;
    // 🛑 The globally-selected wallet is not guaranteed to be a Solana one —
    // an Ethereum/Tezos flow re-points it (`SessionManager.selectSourceWallet`)
    // and an account may simply have one selected. Falling back to the
    // session's own Solana wallet rather than an empty scope is what the tokens
    // tab does (`TokenBalanceBloc._resolveAddresses`); an empty scope here
    // stops the sheet refreshing the balance it shows and blanks its History.
    final sessionSolana = _aggregator.sessionSolanaAddresses();
    try {
      final active = await _walletManager.getAddress();
      if (Chain.fromAddress(active) != Chain.solana) {
        return sessionSolana.isEmpty ? const [] : [sessionSolana.first];
      }
      return scopeToSession(active, sessionSolana);
    } catch (_) {
      return sessionSolana.isEmpty ? const [] : [sessionSolana.first];
    }
  }

  /// [token]'s cached balance summed over [addresses], or null when no wallet
  /// has a cached row for it (nothing to update from — the pending refetch
  /// will surface it).
  ///
  /// Matched on `isNative` as well as mint: native SOL and wrapped SOL share
  /// a mint address and must never be read as each other.
  Future<({int rawBalance, double uiBalance})?> _cachedHolding(
    TokenBalance token,
    List<String> addresses,
  ) async {
    try {
      final perWallet = await Future.wait(
        addresses.map(_tokenRepository.getCachedBalances),
      );
      final rows = [
        for (final balances in perWallet)
          for (final row in balances)
            if (row.mint == token.mint && row.isNative == token.isNative) row,
      ];
      if (rows.isEmpty) return null;
      return (
        rawBalance: rows.fold(0, (sum, r) => sum + r.rawBalance),
        uiBalance: rows.fold(0.0, (sum, r) => sum + r.uiBalance),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadAll(
    TokenBalance token,
    Emitter<TokenDetailState> emit, {
    required ChartTimeframe timeframe,
    bool isRefresh = false,
  }) async {
    // Transfer history is the one source that is NOT chain-specific:
    // `/v2/transfers` routes each wallet to the upstream that can answer for it
    // (Helius / Alchemy / TzKT). Market info and candles are per-chain — see
    // [_fetchTokenInfo] and [_fetchCandles]. Each source degrades to empty
    // independently so a partial backend never blanks the whole screen.
    final addresses = await _historyAddresses(token);

    final results = await Future.wait([
      _fetchTokenInfo(token),
      _fetchCandles(token, timeframe),
      if (addresses.isNotEmpty)
        _fetchFirstHistoryPage(token, addresses)
      else
        Future.value(const TokenTransfersResult(activities: [])),
    ]);

    final tokenInfo = results[0] as JupiterTokenInfo?;
    final candles = results[1] as List<OhlcvCandle>;
    final historyResult = results[2] as TokenTransfersResult;

    emit(
      TokenDetailState.loaded(
        token: token,
        tokenInfo: tokenInfo,
        candles: candles,
        timeframe: timeframe,
        activities: historyResult.activities,
        historyScopeKey: _scopeKeyFor(addresses),
        historyPaginationToken: historyResult.paginationToken,
        hasMoreHistory: historyResult.hasMore,
      ),
    );
  }

  /// Market info for [token] from its chain's own source.
  ///
  /// Tezos has none: the name/symbol/price/logo already come from the balances
  /// backend (TzKT + CoinGecko) and ride along on `token`. Jupiter is a
  /// Solana-only aggregator — searching it with a Tezos contract returns an
  /// unrelated Solana token — so it must not be asked.
  Future<JupiterTokenInfo?> _fetchTokenInfo(TokenBalance token) {
    if (token.isEvm) return _ethInfoService.getTokenInfo(token.mint);
    if (token.chain == Chain.tezos) return Future.value(null);
    return _jupiterInfoService.getTokenInfo(token.mint);
  }

  /// Fetch the first page of history. On error, fall back to whatever
  /// the cache had so the tab doesn't go empty.
  Future<TokenTransfersResult> _fetchFirstHistoryPage(
    TokenBalance token,
    List<String> addresses,
  ) async {
    try {
      return await _transferRepository.fetchTransfers(
        addresses: addresses,
        mint: token.mint,
      );
    } catch (_) {
      final cached = await _transferRepository.getCachedActivities(
        cacheKey: addressScopeKey(addresses),
        mint: token.mint,
        limit: _historyPageSize,
      );
      return TokenTransfersResult(activities: cached);
    }
  }

  /// The wallets whose transfer history backs [token]'s History tab.
  ///
  /// Scoped to **the token's own chain**, and within it the **same scope the
  /// tokens tab summed the displayed row over** ([_balanceAddresses]) — a
  /// Profile session's linked wallets, else the session's own active wallet on
  /// that chain. Reading a narrower set than the balance above it is what left
  /// the tab permanently empty for a Profile holding the token on a wallet
  /// other than the active signer.
  ///
  /// Only the token's chain, because `GET /v2/transfers` interprets the `mint`
  /// in that chain's terms: wallets on any other chain can only ever return
  /// nothing, and each one still costs an upstream round-trip.
  Future<List<String>> _historyAddresses(TokenBalance token) =>
      _balanceAddresses(token.chain);

  /// The key [addresses] cache and paginate under, or null for an empty scope
  /// (nothing is fetched, so there is no scope the held page belongs to).
  static String? _scopeKeyFor(List<String> addresses) =>
      addresses.isEmpty ? null : addressScopeKey(addresses);

  /// CoinGecko onchain network for [token]'s chart.
  String _chartNetwork(TokenBalance token) => token.isEvm
      ? GeckoTerminalService.networkEthereum
      : GeckoTerminalService.networkSolana;

  /// On-chain address used to look up [token]'s chart pool. Native ETH has no
  /// contract address (its mint is the `native` sentinel) and CoinGecko charts
  /// contracts, not the gas coin, so it's charted via WETH — the canonical
  /// price proxy for ether. (Native SOL already carries its wrapped-SOL mint.)
  String _chartAddress(TokenBalance token) =>
      token.isEvm && token.mint == TokenBalance.evmNativeSentinel
      ? GeckoTerminalService.wethAddress
      : token.mint;

  /// Fetch chart candles for [token] from the right source. GeckoTerminal
  /// doesn't index Tezos, so native XTZ uses CoinGecko's coin OHLC endpoint;
  /// other Tezos tokens (FA1.2/FA2) have no chart source and return empty.
  /// Solana/EVM use the onchain pool OHLCV.
  Future<List<OhlcvCandle>> _fetchCandles(
    TokenBalance token,
    ChartTimeframe timeframe,
  ) {
    if (token.chain == Chain.tezos) {
      return token.mint == TokenBalance.tezosNativeSentinel
          ? _geckoService.getCoinOhlc(
              GeckoTerminalService.coinIdTezos,
              timeframe,
            )
          : Future.value(const <OhlcvCandle>[]);
    }
    return _geckoService.getOhlcv(
      _chartAddress(token),
      timeframe,
      network: _chartNetwork(token),
    );
  }
}
