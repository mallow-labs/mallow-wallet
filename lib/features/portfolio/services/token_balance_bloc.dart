import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/data/address_scope_key.dart';
import '../../../core/result/result.dart';
import '../../../core/services/active_networks.dart';
import '../../../core/services/wallet_change_listening.dart';
import '../data/ethereum_token_service.dart';
import '../data/session_portfolio_aggregator.dart';
import '../data/tezos_token_service.dart';
import '../data/token_repository.dart';
import '../models/token_balance.dart';

import '../../../shared/utils/chain.dart';
part 'token_balance_bloc.freezed.dart';

@freezed
sealed class TokenBalanceEvent with _$TokenBalanceEvent {
  const factory TokenBalanceEvent.load() = TokenBalanceLoad;
  const factory TokenBalanceEvent.refresh() = TokenBalanceRefresh;
}

@freezed
sealed class TokenBalanceState with _$TokenBalanceState {
  const factory TokenBalanceState.initial() = TokenBalanceInitial;
  const factory TokenBalanceState.loading() = TokenBalanceLoading;
  const factory TokenBalanceState.loaded({
    required List<TokenBalance> tokens,
    required double totalUsdValue,
    @Default(false) bool isRefreshing,
    DateTime? lastUpdated,

    /// Address these balances belong to. Lets consumers (e.g. the header
    /// value) tell a wallet switch apart from a same-wallet refresh.
    String? address,

    /// 24h portfolio dollar change (sum of all token changes).
    double? totalChange24h,

    /// 24h portfolio percentage change.
    double? totalChangePercent24h,
  }) = TokenBalanceLoaded;
  const factory TokenBalanceState.error(String message) = TokenBalanceError;
}

@injectable
class TokenBalanceBloc extends Bloc<TokenBalanceEvent, TokenBalanceState>
    with WalletChangeListening<TokenBalanceEvent, TokenBalanceState> {
  TokenBalanceBloc(
    this._repository,
    this.walletManager,
    this._aggregator,
    this._ethTokens,
    this._tezTokens,
    this._activeNetworks,
  ) : super(const TokenBalanceState.initial()) {
    on<TokenBalanceLoad>(_onLoad);
    on<TokenBalanceRefresh>(_onRefresh);

    startWalletChangeListening();

    // Post-tx optimistic updates write to the repository cache and signal
    // here. Re-dispatch load() so the cache emit lands instantly and the
    // authoritative refetch corrects any estimation drift. Membership (not
    // equality) so an aggregate session reloads when *any* of its wallets is
    // touched, not just the active signer.
    //
    // Matched against every chain's scope, not just the Solana one: an
    // Ethereum/Tezos send signals its own address, which is never in the
    // Solana scope, so a Solana-only membership test dropped the signal and
    // left the sent chain's pre-send balance on the tab until a pull-to-
    // refresh. Going through the per-chain resolvers also means a chain
    // switched off in Active Networks stays silent — its rows aren't shown, so
    // there is nothing to reload.
    _invalidationSub = _repository.balancesInvalidated.listen((address) async {
      if (isClosed) return;
      final List<String> addresses;
      try {
        addresses = [
          ...await _resolveAddresses(),
          ...await _resolveEthereumAddresses(),
          ...await _resolveTezosAddresses(),
        ];
      } catch (_) {
        return;
      }
      if (isClosed || !addresses.contains(address)) return;
      add(const TokenBalanceEvent.load());
    });

    // Switching a chain off in Active Networks has to drop its rows from the
    // portfolio the user backs out to — nothing else re-queries, so the
    // disabled chain's balances (and their USD in the header total) would sit
    // there until the next wallet switch or pull-to-refresh.
    _networksSub = _activeNetworks.changes.listen((_) {
      if (isClosed) return;
      add(const TokenBalanceEvent.load());
    });
  }

  final TokenRepository _repository;
  final SessionPortfolioAggregator _aggregator;
  final EthereumTokenService _ethTokens;
  final TezosTokenService _tezTokens;
  final ActiveNetworks _activeNetworks;
  StreamSubscription<String>? _invalidationSub;
  StreamSubscription<void>? _networksSub;

  @override
  final WalletManager walletManager;

  /// When true (set only by the TabNavigator-scoped instance that drives the
  /// header + tokens tab), a Profile session aggregates token balances across
  /// every Solana wallet linked to the active profile, so the portfolio total
  /// matches the drawer's per-profile aggregate. Per-signer instances (swap,
  /// send, mint, …) leave this false so spendable balances stay scoped to the
  /// active signing wallet.
  bool aggregateAcrossSession = false;

  @override
  Future<void> close() async {
    await _invalidationSub?.cancel();
    await _networksSub?.cancel();
    return super.close();
  }

  @override
  void onWalletChanged() => add(const TokenBalanceEvent.load());

  /// Bumped at the start of every load/refresh. Bloc handlers run
  /// concurrently, so a load triggered by a wallet switch can outrun a
  /// previous wallet's in-flight fetch. Each run captures its generation and
  /// drops its emissions if a newer run has started — otherwise the stale
  /// fetch would emit the previous wallet's value over the new one.
  int _loadGeneration = 0;

  Future<void> _onLoad(
    TokenBalanceLoad event,
    Emitter<TokenBalanceState> emit,
  ) async {
    final gen = ++_loadGeneration;
    final addressResult = await Result.guard(_resolveAddresses);
    final List<String> addresses;
    switch (addressResult) {
      case ResultSuccess(:final value):
        addresses = value;
      case ResultFailure(:final error):
        if (gen != _loadGeneration) return;
        emit(
          TokenBalanceState.error('Failed to load tokens: ${error.message}'),
        );
        return;
    }
    final scope = addressScopeKey(addresses);

    final cacheResult = await Result.guard(() async {
      final cachedTokens = await _cachedBalances(addresses);
      final cacheTime = await _cacheTimestamp(addresses);
      return (cachedTokens, cacheTime);
    });
    if (gen != _loadGeneration) return;
    switch (cacheResult) {
      case ResultSuccess(:final value) when value.$1.isNotEmpty:
        final cachedTokens = value.$1;
        final cachedTotalValue = _repository.calculateTotalValue(cachedTokens);
        final cachedChange = _repository.calculatePortfolioChange(cachedTokens);
        emit(
          TokenBalanceState.loaded(
            tokens: cachedTokens,
            totalUsdValue: cachedTotalValue,
            isRefreshing: true,
            lastUpdated: value.$2,
            address: scope,
            totalChange24h: cachedChange.dollarChange,
            totalChangePercent24h: cachedChange.percentChange,
          ),
        );
      case ResultSuccess():
        emit(const TokenBalanceState.loading());
      case ResultFailure():
        emit(const TokenBalanceState.loading());
    }

    await _fetchAndCacheTokens(addresses, scope, emit, gen: gen);
  }

  Future<void> _onRefresh(
    TokenBalanceRefresh event,
    Emitter<TokenBalanceState> emit,
  ) async {
    final gen = ++_loadGeneration;
    final currentState = state;
    final addressResult = await Result.guard(_resolveAddresses);
    final List<String> addresses;
    switch (addressResult) {
      case ResultSuccess(:final value):
        addresses = value;
      case ResultFailure(:final error):
        if (gen != _loadGeneration) return;
        if (currentState is TokenBalanceLoaded) {
          emit(currentState.copyWith(isRefreshing: false));
          return;
        }
        emit(
          TokenBalanceState.error('Failed to refresh tokens: ${error.message}'),
        );
        return;
    }
    final scope = addressScopeKey(addresses);

    if (gen != _loadGeneration) return;
    if (currentState is TokenBalanceLoaded) {
      emit(currentState.copyWith(isRefreshing: true));
    }

    await _fetchAndCacheTokens(
      addresses,
      scope,
      emit,
      gen: gen,
      isRefresh: true,
    );
  }

  Future<void> _fetchAndCacheTokens(
    List<String> addresses,
    String scope,
    Emitter<TokenBalanceState> emit, {
    required int gen,
    bool isRefresh = false,
  }) async {
    final result = await Result.guard(() => _fetchAndCacheBalances(addresses));
    if (gen != _loadGeneration) return;
    switch (result) {
      case ResultSuccess(:final value):
        final totalValue = _repository.calculateTotalValue(value);
        final change = _repository.calculatePortfolioChange(value);
        emit(
          TokenBalanceState.loaded(
            tokens: value,
            totalUsdValue: totalValue,
            lastUpdated: DateTime.now(),
            address: scope,
            totalChange24h: change.dollarChange,
            totalChangePercent24h: change.percentChange,
          ),
        );
      case ResultFailure(:final error):
        final currentState = state;
        // If we have cached data, keep showing it (snackbar handles the error).
        if (currentState is TokenBalanceLoaded) {
          emit(currentState.copyWith(isRefreshing: false));
          return;
        }
        emit(
          TokenBalanceState.error('Failed to load tokens: ${error.message}'),
        );
    }
  }

  // ---------------------------------------------------------------------------
  // Address resolution + per-wallet fan-out
  // ---------------------------------------------------------------------------

  /// The wallet addresses whose balances make up the current view. A flagged
  /// Profile session spanning more than one Solana wallet returns the whole set
  /// (the aggregate); every other case is the single active signing wallet — so
  /// per-signer instances and Account sessions are byte-for-byte unchanged.
  Future<List<String>> _resolveAddresses() async {
    final profileAddresses = aggregateAcrossSession
        ? _aggregator.profilePortfolioAddresses()
        : null;
    if (profileAddresses != null && profileAddresses.isNotEmpty) {
      return profileAddresses;
    }
    // An Eth/Tezos-only session holds no Solana wallet. `getAddress()` would
    // then resolve the active *non-Solana* wallet's address, and the Solana
    // balance fetch on it fails (or returns nothing) — leaving the previous
    // session's cached balances on screen. Skip the Solana scope entirely; the
    // Ethereum/Tezos fan-outs below supply this session's balances.
    if (_aggregator.sessionSolanaAddresses().isEmpty &&
        (_aggregator.sessionEthereumAddresses().isNotEmpty ||
            _aggregator.sessionTezosAddresses().isNotEmpty)) {
      return const [];
    }
    // getAddress() (default Solana) returns whatever wallet is *selected*, which
    // is an Ethereum/Tezos wallet when that's the active signer. Feeding a
    // non-Solana address to the Solana balance path reads its cached ETH/XTZ rows
    // (the cache table is keyed by address, not chain) and mislabels them as
    // Solana — duplicating the native-coin row against the dedicated ETH/Tezos
    // fan-outs below. Keep only a genuinely-Solana scope; the other chains are
    // supplied by their own fan-outs.
    //
    // 🛑 Falling back to the session's own Solana wallet — not `const []` — is
    // load-bearing. The globally-selected wallet is not guaranteed to be a
    // Solana one: flows that source from another chain re-point it
    // (`SessionManager.selectSourceWallet`, still reached by Tezos NFT transfer
    // via `ensureSigner`, and by any account whose selection simply is an
    // ETH/Tezos wallet). Returning an empty scope there dropped every SOL/SPL
    // row and its USD from the header total, leaving only the other chain's
    // balance on screen — the reported "a Tezos send wiped my balances" bug.
    // The session still holds the Solana wallet; which chain happens to be the
    // active signer must not decide whether it is read.
    final sessionSolana = _aggregator.sessionSolanaAddresses();
    final active = await walletManager.getAddress();
    if (Chain.fromAddress(active) != Chain.solana) {
      return sessionSolana.isEmpty ? const [] : [sessionSolana.first];
    }
    return scopeToSession(active, sessionSolana);
  }

  /// Cached balances for the view — a single wallet's cache, or every wallet's
  /// cache merged by (chain, mint) — plus the active session's cached Ethereum
  /// balances appended so the multi-chain portfolio paints instantly.
  Future<List<TokenBalance>> _cachedBalances(List<String> addresses) async {
    final solana = addresses.length == 1
        ? await _repository.getCachedBalances(addresses.first)
        : SessionPortfolioAggregator.mergeTokenBalances(
            await Future.wait(addresses.map(_repository.getCachedBalances)),
          );
    // Ethereum and Tezos hit independent backends — fetch them concurrently.
    final other = await Future.wait([
      _cachedEthereumTokens(),
      _cachedTezosTokens(),
    ]);
    return [...solana, ...other[0], ...other[1]];
  }

  /// Cache timestamp for the view — the wallet's own, or the oldest across the
  /// aggregated set (so "updated Xs ago" reflects the stalest wallet).
  Future<DateTime?> _cacheTimestamp(List<String> addresses) async {
    if (addresses.length == 1) {
      return _repository.getCacheTimestamp(addresses.first);
    }
    final times = await Future.wait(
      addresses.map(_repository.getCacheTimestamp),
    );
    final present = times.whereType<DateTime>();
    return present.isEmpty
        ? null
        : present.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  /// Fetch fresh balances and write each wallet's own cache, returning the
  /// single wallet's tokens or the merged aggregate. Per-wallet caching keeps
  /// the drawer and per-signer views sharing the same warm caches.
  Future<List<TokenBalance>> _fetchAndCacheBalances(
    List<String> addresses,
  ) async {
    final List<TokenBalance> solana;
    if (addresses.length == 1) {
      final tokens = await _repository.getTokenBalances(addresses.first);
      await _repository.cacheBalances(addresses.first, tokens);
      solana = tokens;
    } else {
      final lists = await Future.wait(
        addresses.map((address) async {
          final tokens = await _repository.getTokenBalances(address);
          await _repository.cacheBalances(address, tokens);
          return tokens;
        }),
      );
      solana = SessionPortfolioAggregator.mergeTokenBalances(lists);
    }
    // Ethereum and Tezos hit independent backends — fetch them concurrently.
    final other = await Future.wait([
      _fetchEthereumTokens(),
      _fetchTezosTokens(),
    ]);
    return [...solana, ...other[0], ...other[1]];
  }

  // ---------------------------------------------------------------------------
  // Ethereum fan-out (display-only this pass)
  // ---------------------------------------------------------------------------

  /// Ethereum addresses parallel to the resolved Solana scope: the aggregate
  /// (header + tokens tab) returns every session ETH wallet — **including
  /// view-only ones**, so a profile-linked wallet the device doesn't hold still
  /// reports its balance; a per-signer instance returns just the active ETH
  /// address (empty when the session holds no Ethereum wallet).
  Future<List<String>> _resolveEthereumAddresses() => _resolveChainAddresses(
    Chain.ethereum,
    _aggregator.sessionEthereumAddresses(),
  );

  /// Live Ethereum balances for the session, merged across wallets. A failing
  /// chain degrades to an empty list so it can never sink the Solana portfolio.
  Future<List<TokenBalance>> _fetchEthereumTokens() =>
      _ethereumTokens((a) => _ethTokens.getTokenBalances(a));

  /// Cached Ethereum balances for the session (no network), for instant paint.
  Future<List<TokenBalance>> _cachedEthereumTokens() =>
      _ethereumTokens((a) => _ethTokens.getCachedBalances(a));

  Future<List<TokenBalance>> _ethereumTokens(
    Future<List<TokenBalance>> Function(String address) load,
  ) async {
    final addresses = await _resolveEthereumAddresses();
    if (addresses.isEmpty) return const [];
    final lists = await Future.wait(
      addresses.map((a) async {
        try {
          return await load(a);
        } catch (_) {
          return <TokenBalance>[];
        }
      }),
    );
    return SessionPortfolioAggregator.mergeTokenBalances(lists);
  }

  // ---------------------------------------------------------------------------
  // Tezos fan-out (display-only this pass)
  // ---------------------------------------------------------------------------

  /// Tezos addresses parallel to the resolved Solana scope. Same rules as
  /// [_resolveEthereumAddresses].
  Future<List<String>> _resolveTezosAddresses() =>
      _resolveChainAddresses(Chain.tezos, _aggregator.sessionTezosAddresses());

  /// The addresses whose [chain] balances this instance should read, never
  /// leaving the session — [resolveChainScope], which [TokenDetailBloc] shares
  /// so the sheet can never resolve a wider (or narrower) scope than the row it
  /// was opened from.
  Future<List<String>> _resolveChainAddresses(
    Chain chain,
    List<String> sessionAddresses,
  ) => resolveChainScope(
    chain,
    sessionAddresses: sessionAddresses,
    activeNetworks: _activeNetworks,
    walletManager: walletManager,
    aggregateAcrossSession: aggregateAcrossSession,
  );

  /// Live Tezos balances for the session, merged across wallets. A failing chain
  /// degrades to an empty list so it can never sink the Solana portfolio.
  Future<List<TokenBalance>> _fetchTezosTokens() =>
      _tezosTokens((a) => _tezTokens.getTokenBalances(a));

  /// Cached Tezos balances for the session (no network), for instant paint.
  Future<List<TokenBalance>> _cachedTezosTokens() =>
      _tezosTokens((a) => _tezTokens.getCachedBalances(a));

  Future<List<TokenBalance>> _tezosTokens(
    Future<List<TokenBalance>> Function(String address) load,
  ) async {
    final addresses = await _resolveTezosAddresses();
    if (addresses.isEmpty) return const [];
    final lists = await Future.wait(
      addresses.map((a) async {
        try {
          return await load(a);
        } catch (_) {
          return <TokenBalance>[];
        }
      }),
    );
    return SessionPortfolioAggregator.mergeTokenBalances(lists);
  }
}
