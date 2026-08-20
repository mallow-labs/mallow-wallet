import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/data/address_scope_key.dart';
import 'package:mallow_wallet/core/services/active_networks.dart';
import 'package:mallow_wallet/features/portfolio/data/ethereum_token_info_service.dart';
import 'package:mallow_wallet/features/portfolio/data/gecko_terminal_service.dart';
import 'package:mallow_wallet/features/portfolio/data/jupiter_token_info_service.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/portfolio/data/token_transfer_repository.dart';
import 'package:mallow_wallet/features/portfolio/models/jupiter_token_info.dart';
import 'package:mallow_wallet/features/portfolio/models/ohlcv_candle.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_detail_bloc.dart';
import 'package:mocktail/mocktail.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockJupiter extends Mock implements JupiterTokenInfoService {}

class _MockEthInfo extends Mock implements EthereumTokenInfoService {}

class _MockGecko extends Mock implements GeckoTerminalService {}

class _MockTransfers extends Mock implements TokenTransferRepository {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockTokenRepository extends Mock implements TokenRepository {}

class _MockAggregator extends Mock implements SessionPortfolioAggregator {}

class _MockActiveNetworks extends Mock implements ActiveNetworks {}

const _addr = '8M9bV1Rjs1R4w4uX4qzPCsBkLs1ehrhRrUkkPwbAddrz';
const _siblingAddr = '9N1cW2Sktu2S5x5vY5razQDtCmLt2fisSsVllQxcBees';
const _tezAddr = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';
const _ethAddr = '0x742d35Cc6634C0532925a3b844Bc454e4438f44e';
const _ethSiblingAddr = '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';

TokenBalance _token({
  String mint = 'MINT111',
  int rawBalance = 1000000,
  double uiBalance = 1,
  double? pricePerToken,
  bool isNative = false,
}) {
  return TokenBalance(
    mint: mint,
    symbol: 'TKN',
    name: 'Token',
    decimals: 6,
    rawBalance: rawBalance,
    uiBalance: uiBalance,
    pricePerToken: pricePerToken,
    totalUsdValue: pricePerToken == null ? null : uiBalance * pricePerToken,
    isNative: isNative,
  );
}

api.Activity _activity(String id) {
  return api.Activity(
    id: id,
    type: api.ActivityType.send,
    timestamp: 1700000000,
    signature: 'sig-$id',
    status: api.ActivityStatus.confirmed,
    data: const {},
  );
}

OhlcvCandle _candle(int ts) {
  return OhlcvCandle(
    timestamp: ts,
    open: 1,
    high: 2,
    low: 0.5,
    close: 1.5,
    volume: 100,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(ChartTimeframe.oneDay);
    registerFallbackValue(Chain.solana);
    registerFallbackValue(const <String>[]);
  });

  late _MockJupiter jupiter;
  late _MockEthInfo ethInfo;
  late _MockGecko gecko;
  late _MockTransfers transfers;
  late _MockWalletManager wallet;
  late _MockTokenRepository tokenRepo;
  late _MockAggregator aggregator;
  late _MockActiveNetworks activeNetworks;
  late StreamController<String> invalidations;

  setUp(() {
    jupiter = _MockJupiter();
    ethInfo = _MockEthInfo();
    gecko = _MockGecko();
    transfers = _MockTransfers();
    wallet = _MockWalletManager();
    tokenRepo = _MockTokenRepository();
    aggregator = _MockAggregator();
    activeNetworks = _MockActiveNetworks();
    invalidations = StreamController<String>.broadcast();
    when(() => activeNetworks.isEnabled(any())).thenAnswer((_) async => true);
    when(wallet.getAddress).thenAnswer((_) async => _addr);
    when(
      () => tokenRepo.balancesInvalidated,
    ).thenAnswer((_) => invalidations.stream);
    when(
      () => tokenRepo.getCachedBalances(any()),
    ).thenAnswer((_) async => const <TokenBalance>[]);
    when(aggregator.profilePortfolioAddresses).thenReturn(null);
    when(aggregator.sessionSolanaAddresses).thenReturn([_addr]);
    // Default: a Solana-only session. The EVM/Tezos groups opt in.
    when(aggregator.sessionEthereumAddresses).thenReturn(const []);
    when(aggregator.sessionTezosAddresses).thenReturn(const []);
  });

  tearDown(() => invalidations.close());

  TokenDetailBloc buildBloc() => TokenDetailBloc(
    jupiter,
    ethInfo,
    gecko,
    transfers,
    wallet,
    tokenRepo,
    aggregator,
    activeNetworks,
  );

  /// Wire up the load path with empty cache and successful API calls.
  void stubFreshLoad({
    List<api.Activity> activities = const [],
    bool hasMore = false,
    String? paginationToken,
    List<OhlcvCandle> candles = const [],
    JupiterTokenInfo? info,
  }) {
    when(
      () => transfers.getCachedActivities(
        cacheKey: any(named: 'cacheKey'),
        mint: any(named: 'mint'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => const <api.Activity>[]);
    when(
      () => transfers.fetchTransfers(
        addresses: any(named: 'addresses'),
        mint: any(named: 'mint'),
        paginationToken: any(named: 'paginationToken'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer(
      (_) async => TokenTransfersResult(
        activities: activities,
        paginationToken: paginationToken,
      ),
    );
    when(() => gecko.getOhlcv(any(), any())).thenAnswer((_) async => candles);
    when(() => jupiter.getTokenInfo(any())).thenAnswer((_) async => info);
  }

  group('TokenDetailEvent.load', () {
    blocTest<TokenDetailBloc, TokenDetailState>(
      'cold start (no cache) emits loading then loaded with API results',
      setUp: () {
        stubFreshLoad(
          activities: [_activity('a'), _activity('b')],
          candles: [_candle(1)],
        );
      },
      build: buildBloc,
      act: (bloc) => bloc.add(TokenDetailEvent.load(_token())),
      expect: () => [
        isA<TokenDetailLoading>(),
        isA<TokenDetailLoaded>()
            .having((s) => s.activities.length, 'activities', 2)
            .having((s) => s.candles.length, 'candles', 1)
            .having((s) => s.timeframe, 'timeframe', ChartTimeframe.oneDay)
            .having((s) => s.isChartLoading, 'isChartLoading', false),
      ],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'cached history shows immediately with isChartLoading=true, then settles to loaded',
      setUp: () {
        when(
          () => transfers.getCachedActivities(
            cacheKey: any(named: 'cacheKey'),
            mint: any(named: 'mint'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => [_activity('cached')]);
        when(
          () => transfers.fetchTransfers(
            addresses: any(named: 'addresses'),
            mint: any(named: 'mint'),
            paginationToken: any(named: 'paginationToken'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer(
          (_) async => TokenTransfersResult(activities: [_activity('fresh')]),
        );
        when(
          () => gecko.getOhlcv(any(), any()),
        ).thenAnswer((_) async => [_candle(1)]);
        when(() => jupiter.getTokenInfo(any())).thenAnswer((_) async => null);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(TokenDetailEvent.load(_token())),
      expect: () => [
        isA<TokenDetailLoaded>()
            .having((s) => s.activities.single.id, 'cached id', 'cached')
            .having((s) => s.isChartLoading, 'chart loading flag', true),
        isA<TokenDetailLoaded>()
            .having((s) => s.activities.single.id, 'fresh id', 'fresh')
            .having((s) => s.isChartLoading, 'chart loading flag', false),
      ],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'when API transfers fail, falls back to the cache for history',
      setUp: () {
        when(
          () => transfers.getCachedActivities(
            cacheKey: any(named: 'cacheKey'),
            mint: any(named: 'mint'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => [_activity('fallback')]);
        when(
          () => transfers.fetchTransfers(
            addresses: any(named: 'addresses'),
            mint: any(named: 'mint'),
            paginationToken: any(named: 'paginationToken'),
            limit: any(named: 'limit'),
          ),
        ).thenThrow(Exception('helius 500'));
        when(
          () => gecko.getOhlcv(any(), any()),
        ).thenAnswer((_) async => const <OhlcvCandle>[]);
        when(() => jupiter.getTokenInfo(any())).thenAnswer((_) async => null);
      },
      build: buildBloc,
      // The cache responds with one item, so the bloc emits the cached
      // snapshot first; then _loadAll runs, hits the API failure, falls
      // back to cached activities again, and emits the final loaded state.
      act: (bloc) => bloc.add(TokenDetailEvent.load(_token())),
      verify: (bloc) {
        final s = bloc.state as TokenDetailLoaded;
        // hasMoreHistory must be false when the fallback path runs — the
        // fallback constructs a TokenTransfersResult with no pagination
        // token.
        expect(s.hasMoreHistory, isFalse);
        expect(s.activities.single.id, 'fallback');
      },
    );
  });

  group('history scope', () {
    /// The `addresses` the bloc asked the transfers endpoint for.
    List<String> capturedScope() =>
        verify(
              () => transfers.fetchTransfers(
                addresses: captureAny(named: 'addresses'),
                mint: any(named: 'mint'),
                paginationToken: any(named: 'paginationToken'),
                limit: any(named: 'limit'),
              ),
            ).captured.single
            as List<String>;

    blocTest<TokenDetailBloc, TokenDetailState>(
      'reads every profile wallet, not just the active signer — the row the '
      'sheet was opened over is summed across them, so history scoped to one '
      'wallet showed nothing for a token held on another',
      setUp: () {
        stubFreshLoad();
        when(
          aggregator.profilePortfolioAddresses,
        ).thenReturn([_addr, _siblingAddr]);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(TokenDetailEvent.load(_token())),
      verify: (_) => expect(capturedScope(), [_addr, _siblingAddr]),
    );

    // 🛑 The backend fans every address out to Helius and fails soft on the
    // first error, so one 0x/tz1 address in the list empties the page for the
    // Solana wallets too — the whole tab, not just that address's share.
    blocTest<TokenDetailBloc, TokenDetailState>(
      "never sends the session's Ethereum or Tezos addresses",
      setUp: () {
        stubFreshLoad();
        when(aggregator.sessionEthereumAddresses).thenReturn([_ethAddr]);
        when(aggregator.sessionTezosAddresses).thenReturn([_tezAddr]);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(TokenDetailEvent.load(_token())),
      verify: (_) => expect(capturedScope(), [_addr]),
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      "falls back to the session's own Solana wallet when the selected wallet "
      'is on another chain — an Ethereum/Tezos flow re-points the selection, '
      'and an empty scope there blanks the History of a token still held',
      setUp: () {
        stubFreshLoad();
        when(wallet.getAddress).thenAnswer((_) async => _ethAddr);
        when(aggregator.sessionSolanaAddresses).thenReturn([_siblingAddr]);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(TokenDetailEvent.load(_token())),
      verify: (_) => expect(capturedScope(), [_siblingAddr]),
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'pages load-more over the same scope as the first page — a narrower '
      'second page would drop rows the first one showed',
      setUp: () {
        when(
          aggregator.profilePortfolioAddresses,
        ).thenReturn([_addr, _siblingAddr]);
        when(
          () => transfers.fetchTransfers(
            addresses: any(named: 'addresses'),
            mint: any(named: 'mint'),
            paginationToken: 'cursor-1',
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => const TokenTransfersResult(activities: []));
      },
      build: buildBloc,
      seed: () => TokenDetailState.loaded(
        token: _token(),
        historyPaginationToken: 'cursor-1',
        // The cursor belongs to this scope, so load-more continues it rather
        // than restarting (see the scope-change test below).
        historyScopeKey: addressScopeKey([_addr, _siblingAddr]),
        hasMoreHistory: true,
      ),
      act: (bloc) => bloc.add(const TokenDetailEvent.loadMoreHistory()),
      verify: (_) => expect(capturedScope(), [_addr, _siblingAddr]),
    );

    /// The cursor the backend mints for a page fetched over [addresses].
    /// Continuation is per address, so a cursor only ever continues the exact
    /// scope that produced it.
    String cursorFor(List<String> addresses) =>
        'cursor:${addressScopeKey(addresses)}';

    blocTest<TokenDetailBloc, TokenDetailState>(
      'restarts history for the new scope when the wallet selection moves '
      'between the first page and load-more — the sheet stays open across the '
      'send/swap flows that re-point it, and replaying a cursor keyed by the '
      'old scope returns an empty page, which would read as "end of history" '
      'and strand the rest of the list until the sheet is closed',
      setUp: () {
        when(
          () => transfers.getCachedActivities(
            cacheKey: any(named: 'cacheKey'),
            mint: any(named: 'mint'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => const <api.Activity>[]);
        when(
          () => gecko.getOhlcv(any(), any()),
        ).thenAnswer((_) async => const <OhlcvCandle>[]);
        when(() => jupiter.getTokenInfo(any())).thenAnswer((_) async => null);
        when(
          () => transfers.fetchTransfers(
            addresses: any(named: 'addresses'),
            mint: any(named: 'mint'),
            paginationToken: any(named: 'paginationToken'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((invocation) async {
          final addresses =
              invocation.namedArguments[#addresses] as List<String>;
          final cursor = invocation.namedArguments[#paginationToken] as String?;
          // Models the backend: a cursor from another scope names none of
          // these wallets, so every one of them is skipped and the page comes
          // back empty with no next cursor.
          if (cursor != null && cursor != cursorFor(addresses)) {
            return const TokenTransfersResult(activities: []);
          }
          return TokenTransfersResult(
            activities: [_activity('${addresses.single}-page')],
            paginationToken: cursorFor(addresses),
          );
        });
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(TokenDetailEvent.load(_token()));
        await bloc.stream.firstWhere((s) => s is TokenDetailLoaded);
        // The send/swap flow launched from the sheet re-points the selection
        // (SessionManager.selectSourceWallet) while it is still open.
        when(aggregator.sessionSolanaAddresses).thenReturn([_siblingAddr]);
        when(wallet.getAddress).thenAnswer((_) async => _siblingAddr);
        bloc.add(const TokenDetailEvent.loadMoreHistory());
      },
      verify: (bloc) {
        final captured = verify(
          () => transfers.fetchTransfers(
            addresses: captureAny(named: 'addresses'),
            mint: any(named: 'mint'),
            paginationToken: captureAny(named: 'paginationToken'),
            limit: any(named: 'limit'),
          ),
        ).captured;
        expect(captured, [
          // First page, original scope.
          [_addr], null,
          // Load-more after the switch: the new scope from the start, never
          // the old scope's cursor.
          [_siblingAddr], null,
        ]);

        final s = bloc.state as TokenDetailLoaded;
        // Rows are replaced, not appended: the ones on screen were fetched for
        // the old scope, while these cache under the new one.
        expect(s.activities.map((a) => a.id), ['$_siblingAddr-page']);
        expect(s.historyScopeKey, addressScopeKey([_siblingAddr]));
        // Pagination still live — the stale cursor ended it here.
        expect(s.hasMoreHistory, isTrue);
        expect(s.historyPaginationToken, cursorFor([_siblingAddr]));
      },
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'reads the cache under the same scope key it fetches with, so the '
      'aggregated page paints before the network answers',
      setUp: () {
        stubFreshLoad();
        when(
          aggregator.profilePortfolioAddresses,
        ).thenReturn([_addr, _siblingAddr]);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(TokenDetailEvent.load(_token())),
      verify: (_) {
        final key = verify(
          () => transfers.getCachedActivities(
            cacheKey: captureAny(named: 'cacheKey'),
            mint: any(named: 'mint'),
            limit: any(named: 'limit'),
          ),
        ).captured.single;
        expect(key, addressScopeKey([_addr, _siblingAddr]));
      },
    );
  });

  group('TokenDetailEvent.timeframeChanged', () {
    blocTest<TokenDetailBloc, TokenDetailState>(
      'is ignored when state is not loaded',
      build: buildBloc,
      act: (bloc) => bloc.add(
        const TokenDetailEvent.timeframeChanged(ChartTimeframe.oneHour),
      ),
      expect: () => const <TokenDetailState>[],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'updates timeframe and replaces candles when in a loaded state',
      setUp: () {
        when(
          () => gecko.getOhlcv(any(), ChartTimeframe.oneWeek),
        ).thenAnswer((_) async => [_candle(2), _candle(3)]);
      },
      build: buildBloc,
      seed: () =>
          TokenDetailState.loaded(token: _token(), candles: [_candle(1)]),
      act: (bloc) => bloc.add(
        const TokenDetailEvent.timeframeChanged(ChartTimeframe.oneWeek),
      ),
      expect: () => [
        // Intermediate state: timeframe updated, chart spinner on.
        isA<TokenDetailLoaded>()
            .having((s) => s.timeframe, 'timeframe', ChartTimeframe.oneWeek)
            .having((s) => s.isChartLoading, 'isChartLoading', true),
        // Final state: new candles, spinner off.
        isA<TokenDetailLoaded>()
            .having((s) => s.candles.length, 'candle count', 2)
            .having((s) => s.isChartLoading, 'isChartLoading', false)
            .having((s) => s.timeframe, 'timeframe', ChartTimeframe.oneWeek),
      ],
    );
  });

  group('TokenDetailEvent.loadMoreHistory', () {
    blocTest<TokenDetailBloc, TokenDetailState>(
      'is ignored when not in a loaded state',
      build: buildBloc,
      act: (bloc) => bloc.add(const TokenDetailEvent.loadMoreHistory()),
      expect: () => const <TokenDetailState>[],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'is ignored when hasMoreHistory=false',
      build: buildBloc,
      seed: () => TokenDetailState.loaded(token: _token()),
      act: (bloc) => bloc.add(const TokenDetailEvent.loadMoreHistory()),
      verify: (_) {
        verifyNever(
          () => transfers.fetchTransfers(
            addresses: any(named: 'addresses'),
            mint: any(named: 'mint'),
            paginationToken: any(named: 'paginationToken'),
            limit: any(named: 'limit'),
          ),
        );
      },
      expect: () => const <TokenDetailState>[],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'is ignored when no pagination token is available',
      build: buildBloc,
      seed: () =>
          TokenDetailState.loaded(token: _token(), hasMoreHistory: true),
      act: (bloc) => bloc.add(const TokenDetailEvent.loadMoreHistory()),
      verify: (_) {
        verifyNever(
          () => transfers.fetchTransfers(
            addresses: any(named: 'addresses'),
            mint: any(named: 'mint'),
            paginationToken: any(named: 'paginationToken'),
            limit: any(named: 'limit'),
          ),
        );
      },
      expect: () => const <TokenDetailState>[],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'appends the next page of activities and updates pagination metadata',
      setUp: () {
        when(
          () => transfers.fetchTransfers(
            addresses: any(named: 'addresses'),
            mint: any(named: 'mint'),
            paginationToken: 'cursor-1',
            limit: any(named: 'limit'),
          ),
        ).thenAnswer(
          (_) async => TokenTransfersResult(
            activities: [_activity('page2-a'), _activity('page2-b')],
            paginationToken: 'cursor-2',
          ),
        );
      },
      build: buildBloc,
      seed: () => TokenDetailState.loaded(
        token: _token(),
        activities: [_activity('page1')],
        historyPaginationToken: 'cursor-1',
        historyScopeKey: addressScopeKey([_addr]),
        hasMoreHistory: true,
      ),
      act: (bloc) => bloc.add(const TokenDetailEvent.loadMoreHistory()),
      expect: () => [
        isA<TokenDetailLoaded>().having(
          (s) => s.isLoadingMoreHistory,
          'isLoadingMoreHistory',
          true,
        ),
        isA<TokenDetailLoaded>()
            .having(
              (s) => s.activities.map((a) => a.id).toList(),
              'activity ids',
              ['page1', 'page2-a', 'page2-b'],
            )
            .having((s) => s.historyPaginationToken, 'next cursor', 'cursor-2')
            .having((s) => s.hasMoreHistory, 'hasMoreHistory', true)
            .having(
              (s) => s.isLoadingMoreHistory,
              'isLoadingMoreHistory',
              false,
            ),
      ],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'is a no-op when a load-more is already in flight',
      build: buildBloc,
      seed: () => TokenDetailState.loaded(
        token: _token(),
        historyPaginationToken: 'cursor-1',
        hasMoreHistory: true,
        isLoadingMoreHistory: true,
      ),
      act: (bloc) => bloc.add(const TokenDetailEvent.loadMoreHistory()),
      verify: (_) {
        verifyNever(
          () => transfers.fetchTransfers(
            addresses: any(named: 'addresses'),
            mint: any(named: 'mint'),
            paginationToken: any(named: 'paginationToken'),
            limit: any(named: 'limit'),
          ),
        );
      },
      expect: () => const <TokenDetailState>[],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'clears the loading flag and keeps existing activities when fetch fails',
      setUp: () {
        when(
          () => transfers.fetchTransfers(
            addresses: any(named: 'addresses'),
            mint: any(named: 'mint'),
            paginationToken: any(named: 'paginationToken'),
            limit: any(named: 'limit'),
          ),
        ).thenThrow(Exception('500'));
      },
      build: buildBloc,
      seed: () => TokenDetailState.loaded(
        token: _token(),
        activities: [_activity('page1')],
        historyPaginationToken: 'cursor-1',
        historyScopeKey: addressScopeKey([_addr]),
        hasMoreHistory: true,
      ),
      act: (bloc) => bloc.add(const TokenDetailEvent.loadMoreHistory()),
      expect: () => [
        isA<TokenDetailLoaded>().having(
          (s) => s.isLoadingMoreHistory,
          'flag on',
          true,
        ),
        isA<TokenDetailLoaded>()
            .having((s) => s.isLoadingMoreHistory, 'flag off', false)
            .having(
              (s) => s.activities.single.id,
              'activities preserved',
              'page1',
            ),
      ],
    );
  });

  group('TokenDetailEvent.refresh', () {
    blocTest<TokenDetailBloc, TokenDetailState>(
      'is ignored when state is not loaded',
      build: buildBloc,
      act: (bloc) => bloc.add(const TokenDetailEvent.refresh()),
      expect: () => const <TokenDetailState>[],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'flips isRefreshing on, then emits a fresh loaded state',
      setUp: () {
        stubFreshLoad(activities: [_activity('new')]);
      },
      build: buildBloc,
      seed: () => TokenDetailState.loaded(
        token: _token(),
        activities: [_activity('old')],
      ),
      act: (bloc) => bloc.add(const TokenDetailEvent.refresh()),
      expect: () => [
        isA<TokenDetailLoaded>().having(
          (s) => s.isRefreshing,
          'isRefreshing',
          true,
        ),
        isA<TokenDetailLoaded>()
            .having((s) => s.activities.single.id, 'new activity', 'new')
            .having((s) => s.isRefreshing, 'isRefreshing', false),
      ],
    );
  });

  group('balance refresh after a confirmed transaction', () {
    blocTest<TokenDetailBloc, TokenDetailState>(
      'a post-send cache write updates the displayed holding — the sheet stays '
      'open across the send flow, so its opening snapshot would otherwise keep '
      'showing the pre-transaction balance',
      setUp: () {
        when(
          () => tokenRepo.getCachedBalances(_addr),
        ).thenAnswer((_) async => [_token(rawBalance: 400000, uiBalance: 0.4)]);
      },
      build: buildBloc,
      seed: () => TokenDetailState.loaded(token: _token(pricePerToken: 2.5)),
      // Fired through the repository stream, not added directly: the
      // subscription is the wiring the send flow actually reaches the bloc by.
      act: (_) => invalidations.add(_addr),
      wait: const Duration(milliseconds: 10),
      expect: () => [
        isA<TokenDetailLoaded>()
            .having((s) => s.token.uiBalance, 'uiBalance', 0.4)
            .having((s) => s.token.rawBalance, 'rawBalance', 400000)
            // Repriced from the price already on screen, not the cache's, so a
            // transfer never moves the USD figure for a pricing reason.
            .having((s) => s.token.totalUsdValue, 'totalUsdValue', 1.0),
      ],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'ignores an invalidation for a wallet outside the displayed holding — '
      'another wallet spending its own balance must not rewrite this one',
      build: buildBloc,
      seed: () => TokenDetailState.loaded(token: _token()),
      act: (_) => invalidations.add(_siblingAddr),
      wait: const Duration(milliseconds: 10),
      expect: () => const <TokenDetailState>[],
      verify: (_) => verifyNever(() => tokenRepo.getCachedBalances(any())),
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'sums every profile wallet holding the mint when the portfolio is '
      'aggregated — narrowing to the signer would drop the rest of the position',
      setUp: () {
        when(
          aggregator.profilePortfolioAddresses,
        ).thenReturn([_addr, _siblingAddr]);
        when(
          () => tokenRepo.getCachedBalances(_addr),
        ).thenAnswer((_) async => [_token(rawBalance: 400000, uiBalance: 0.4)]);
        when(
          () => tokenRepo.getCachedBalances(_siblingAddr),
        ).thenAnswer((_) async => [_token(rawBalance: 2000000, uiBalance: 2)]);
      },
      build: buildBloc,
      seed: () => TokenDetailState.loaded(
        token: _token(rawBalance: 3000000, uiBalance: 3),
      ),
      act: (_) => invalidations.add(_addr),
      wait: const Duration(milliseconds: 10),
      expect: () => [
        isA<TokenDetailLoaded>()
            .having((s) => s.token.uiBalance, 'summed uiBalance', 2.4)
            .having((s) => s.token.rawBalance, 'summed rawBalance', 2400000),
      ],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'reads the native row, not the wrapped one — native SOL and wrapped SOL '
      'share a mint address and only `isNative` tells them apart',
      setUp: () {
        when(() => tokenRepo.getCachedBalances(_addr)).thenAnswer(
          (_) async => [
            _token(
              mint: TokenBalance.solMint,
              rawBalance: 7000000,
              uiBalance: 7,
            ),
            _token(
              mint: TokenBalance.solMint,
              rawBalance: 2000000,
              uiBalance: 2,
              isNative: true,
            ),
          ],
        );
      },
      build: buildBloc,
      seed: () => TokenDetailState.loaded(
        token: _token(mint: TokenBalance.solMint, isNative: true),
      ),
      act: (_) => invalidations.add(_addr),
      wait: const Duration(milliseconds: 10),
      expect: () => [
        isA<TokenDetailLoaded>().having(
          (s) => s.token.uiBalance,
          'native uiBalance',
          2,
        ),
      ],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'updates a Tezos holding from its own tz1 address — the XTZ sheet stays '
      'open across the send flow and kept the pre-send balance until a '
      'pull-to-refresh',
      setUp: () {
        when(aggregator.sessionTezosAddresses).thenReturn([_tezAddr]);
        when(
          () => tokenRepo.getCachedBalances(_tezAddr),
        ).thenAnswer((_) async => [_token(rawBalance: 400000, uiBalance: 0.4)]);
      },
      build: buildBloc,
      seed: () => TokenDetailState.loaded(
        token: _token(pricePerToken: 2.5).copyWith(chain: Chain.tezos),
      ),
      act: (_) => invalidations.add(_tezAddr),
      wait: const Duration(milliseconds: 10),
      expect: () => [
        isA<TokenDetailLoaded>()
            .having((s) => s.token.uiBalance, 'uiBalance', 0.4)
            .having((s) => s.token.rawBalance, 'rawBalance', 400000)
            .having((s) => s.token.totalUsdValue, 'totalUsdValue', 1.0),
      ],
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'resolves a non-Solana holding against the session wallets on its own '
      "chain — the active account's auto-derived sibling may sit outside the "
      'session, and rewriting the row from it would show a balance the '
      'session does not own',
      setUp: () {
        // The session holds no Ethereum wallet; the signalled address is the
        // account sibling `WalletManager.getAddress(chain:)` would have found.
        when(aggregator.sessionEthereumAddresses).thenReturn(const <String>[]);
      },
      build: buildBloc,
      seed: () => TokenDetailState.loaded(
        token: _token().copyWith(chain: Chain.ethereum),
      ),
      act: (_) => invalidations.add(_addr),
      wait: const Duration(milliseconds: 10),
      expect: () => const <TokenDetailState>[],
      // Nothing is re-read, so the row keeps the balance it was opened with
      // rather than one sourced from a wallet outside the session.
      verify: (_) => verifyNever(() => tokenRepo.getCachedBalances(any())),
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'sums every session wallet on the holding\'s own chain — the sheet is '
      'opened over the tokens tab\'s aggregated row, so re-reading one '
      "wallet's share of it would make the balance jump *up* after a send",
      setUp: () {
        when(
          aggregator.sessionEthereumAddresses,
        ).thenReturn([_ethAddr, _ethSiblingAddr]);
        when(
          () => tokenRepo.getCachedBalances(_ethAddr),
        ).thenAnswer((_) async => [_token(rawBalance: 400000, uiBalance: 0.4)]);
        when(
          () => tokenRepo.getCachedBalances(_ethSiblingAddr),
        ).thenAnswer((_) async => [_token(rawBalance: 2000000, uiBalance: 2)]);
      },
      build: buildBloc,
      seed: () => TokenDetailState.loaded(
        token: _token(
          rawBalance: 3000000,
          uiBalance: 3,
        ).copyWith(chain: Chain.ethereum),
      ),
      act: (_) => invalidations.add(_ethAddr),
      wait: const Duration(milliseconds: 10),
      expect: () => [
        isA<TokenDetailLoaded>()
            .having((s) => s.token.uiBalance, 'summed uiBalance', 2.4)
            .having((s) => s.token.rawBalance, 'summed rawBalance', 2400000),
      ],
      // Never asked which wallet is active: the scope is the session's set on
      // that chain, not whatever the account happens to have selected.
      verify: (_) =>
          verifyNever(() => wallet.getAddress(chain: any(named: 'chain'))),
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'stops re-reading a holding whose chain was switched off in Active '
      'Networks — the tokens tab drops those rows, and a sheet resolving a '
      'scope the portfolio no longer reads is exactly the drift this shares '
      "TokenBalanceBloc's resolver to prevent",
      setUp: () {
        when(aggregator.sessionEthereumAddresses).thenReturn([_ethAddr]);
        when(
          () => activeNetworks.isEnabled(Chain.ethereum),
        ).thenAnswer((_) async => false);
      },
      build: buildBloc,
      seed: () => TokenDetailState.loaded(
        token: _token().copyWith(chain: Chain.ethereum),
      ),
      act: (_) => invalidations.add(_ethAddr),
      wait: const Duration(milliseconds: 10),
      expect: () => const <TokenDetailState>[],
      verify: (_) => verifyNever(() => tokenRepo.getCachedBalances(any())),
    );
  });

  group('EVM token detail', () {
    const evmContract = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48';
    TokenBalance evmToken() => const TokenBalance(
      mint: evmContract,
      symbol: 'USDC',
      name: 'USD Coin',
      decimals: 6,
      rawBalance: 1000000,
      uiBalance: 1,
      chain: Chain.ethereum,
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'loads EVM info + eth-network candles, and reads history over the '
      "session's Ethereum wallets — /v2/transfers routes an 0x address to "
      'Alchemy, so an ERC-20 has a History tab like any Solana token',
      setUp: () {
        stubFreshLoad(activities: [_activity('eth-1')]);
        when(() => ethInfo.getTokenInfo(any())).thenAnswer((_) async => null);
        when(
          () => gecko.getOhlcv(any(), any(), network: any(named: 'network')),
        ).thenAnswer((_) async => [_candle(1)]);
        when(
          aggregator.sessionEthereumAddresses,
        ).thenReturn([_ethAddr, _ethSiblingAddr]);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(TokenDetailEvent.load(evmToken())),
      expect: () => [
        isA<TokenDetailLoading>(),
        isA<TokenDetailLoaded>()
            .having((s) => s.candles.length, 'candles', 1)
            .having((s) => s.activities.single.id, 'history row', 'eth-1'),
      ],
      verify: (_) {
        // Charts routed to CoinGecko's `eth` network, info to the EVM service —
        // never the Solana providers.
        final network = verify(
          () => gecko.getOhlcv(
            any(),
            any(),
            network: captureAny(named: 'network'),
          ),
        ).captured.single;
        expect(network, GeckoTerminalService.networkEthereum);
        verify(() => ethInfo.getTokenInfo(evmContract)).called(1);
        verifyNever(() => jupiter.getTokenInfo(any()));

        // History asked for over the session's ETH wallets, keyed by the token
        // contract — never the Solana scope, which would return nothing.
        final captured = verify(
          () => transfers.fetchTransfers(
            addresses: captureAny(named: 'addresses'),
            mint: captureAny(named: 'mint'),
            paginationToken: any(named: 'paginationToken'),
            limit: any(named: 'limit'),
          ),
        ).captured;
        expect(captured[0], [_ethAddr, _ethSiblingAddr]);
        expect(captured[1], evmContract);
      },
    );

    // Symmetric with the Solana scope rule: an address on another chain can
    // only cost a round-trip to return nothing.
    blocTest<TokenDetailBloc, TokenDetailState>(
      'asks for no history when the session holds no Ethereum wallet',
      setUp: () {
        stubFreshLoad();
        when(() => ethInfo.getTokenInfo(any())).thenAnswer((_) async => null);
        when(
          () => gecko.getOhlcv(any(), any(), network: any(named: 'network')),
        ).thenAnswer((_) async => [_candle(1)]);
        when(aggregator.sessionEthereumAddresses).thenReturn(const []);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(TokenDetailEvent.load(evmToken())),
      verify: (_) {
        verifyNever(
          () => transfers.fetchTransfers(
            addresses: any(named: 'addresses'),
            mint: any(named: 'mint'),
            paginationToken: any(named: 'paginationToken'),
            limit: any(named: 'limit'),
          ),
        );
      },
    );

    // The tokens tab drops rows for a chain switched off in Active Networks;
    // the sheet's History must not keep reading it either.
    blocTest<TokenDetailBloc, TokenDetailState>(
      'asks for no history when Ethereum is switched off in Active Networks',
      setUp: () {
        stubFreshLoad();
        when(() => ethInfo.getTokenInfo(any())).thenAnswer((_) async => null);
        when(
          () => gecko.getOhlcv(any(), any(), network: any(named: 'network')),
        ).thenAnswer((_) async => [_candle(1)]);
        when(aggregator.sessionEthereumAddresses).thenReturn([_ethAddr]);
        when(
          () => activeNetworks.isEnabled(Chain.ethereum),
        ).thenAnswer((_) async => false);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(TokenDetailEvent.load(evmToken())),
      verify: (_) {
        verifyNever(
          () => transfers.fetchTransfers(
            addresses: any(named: 'addresses'),
            mint: any(named: 'mint'),
            paginationToken: any(named: 'paginationToken'),
            limit: any(named: 'limit'),
          ),
        );
      },
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'charts native ETH via the WETH contract — its mint is the `native` '
      'sentinel, which CoinGecko (a contract-keyed API) cannot resolve',
      setUp: () {
        when(() => ethInfo.getTokenInfo(any())).thenAnswer((_) async => null);
        when(
          () => gecko.getOhlcv(any(), any(), network: any(named: 'network')),
        ).thenAnswer((_) async => [_candle(1)]);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(TokenDetailEvent.load(TokenBalance.nativeEth())),
      expect: () => [
        isA<TokenDetailLoading>(),
        isA<TokenDetailLoaded>().having((s) => s.candles.length, 'candles', 1),
      ],
      verify: (_) {
        // The chart address must be substituted to WETH; passing the raw
        // `native` sentinel would 404 and blank the chart.
        final address = verify(
          () => gecko.getOhlcv(
            captureAny(),
            any(),
            network: any(named: 'network'),
          ),
        ).captured.single;
        expect(address, GeckoTerminalService.wethAddress);
        expect(address, isNot(TokenBalance.evmNativeSentinel));
      },
    );
  });

  group('Tezos token detail', () {
    const faContract = 'KT1K9gCRgaLRFKTErYt1wVxA3Frb9FjasjTV';
    TokenBalance tezToken() => const TokenBalance(
      mint: faContract,
      symbol: 'FA',
      name: 'Some FA token',
      decimals: 6,
      rawBalance: 1000000,
      uiBalance: 1,
      pricePerToken: 1.5,
      chain: Chain.tezos,
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'shows the balance-provided token (price from /v2/tezos/balances) and '
      'never touches Jupiter or CoinGecko — Jupiter is Solana-only and would '
      'return an unrelated token',
      setUp: () {
        stubFreshLoad();
        when(aggregator.sessionTezosAddresses).thenReturn([_tezAddr]);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(TokenDetailEvent.load(tezToken())),
      expect: () => [
        isA<TokenDetailLoading>(),
        isA<TokenDetailLoaded>()
            .having((s) => s.token.pricePerToken, 'balance price', 1.5)
            .having((s) => s.tokenInfo, 'no market info', isNull)
            .having((s) => s.candles, 'no chart', isEmpty),
      ],
      verify: (_) {
        // None of the Solana/EVM data sources are hit for a Tezos token, and
        // an FA token has no chart source at all — not even the coin OHLC
        // endpoint, which is native-XTZ-only.
        verifyNever(() => jupiter.getTokenInfo(any()));
        verifyNever(() => gecko.getOhlcv(any(), any()));
        verifyNever(() => gecko.getCoinOhlc(any(), any()));
      },
    );

    // 🛑 The FA mint must reach the backend case-exactly: TzKT matches
    // `token.contract` on case-sensitive base58, so a lowercased `kt1…` filters
    // to a contract that does not exist and the tab renders empty.
    blocTest<TokenDetailBloc, TokenDetailState>(
      "reads history over the session's Tezos wallets, keyed by the case-exact "
      'KT1 contract',
      setUp: () {
        stubFreshLoad(activities: [_activity('tez-1')]);
        when(aggregator.sessionTezosAddresses).thenReturn([_tezAddr]);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(TokenDetailEvent.load(tezToken())),
      verify: (_) {
        final captured = verify(
          () => transfers.fetchTransfers(
            addresses: captureAny(named: 'addresses'),
            mint: captureAny(named: 'mint'),
            paginationToken: any(named: 'paginationToken'),
            limit: any(named: 'limit'),
          ),
        ).captured;
        expect(captured[0], [_tezAddr]);
        expect(captured[1], faContract);
      },
    );

    blocTest<TokenDetailBloc, TokenDetailState>(
      'charts native XTZ via the CoinGecko coin OHLC endpoint — GeckoTerminal '
      'does not index Tezos, so the onchain pool path cannot be used',
      setUp: () {
        when(
          () => gecko.getCoinOhlc(any(), any()),
        ).thenAnswer((_) async => [_candle(1)]);
      },
      build: buildBloc,
      act: (bloc) =>
          bloc.add(TokenDetailEvent.load(TokenBalance.nativeTezos())),
      expect: () => [
        isA<TokenDetailLoading>(),
        isA<TokenDetailLoaded>().having((s) => s.candles.length, 'candles', 1),
      ],
      verify: (_) {
        // Charted by coin id `tezos`, never the onchain pool path or Jupiter.
        final coinId = verify(
          () => gecko.getCoinOhlc(captureAny(), any()),
        ).captured.single;
        expect(coinId, GeckoTerminalService.coinIdTezos);
        verifyNever(() => gecko.getOhlcv(any(), any()));
        verifyNever(() => jupiter.getTokenInfo(any()));
      },
    );
  });
}
