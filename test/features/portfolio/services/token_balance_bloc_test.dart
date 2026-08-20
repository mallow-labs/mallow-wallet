import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/services/active_networks.dart';
import 'package:mallow_wallet/features/portfolio/data/ethereum_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/data/tezos_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'token_balance_bloc_test.mocks.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

@GenerateMocks([
  TokenRepository,
  WalletManager,
  SessionPortfolioAggregator,
  EthereumTokenService,
  TezosTokenService,
  ActiveNetworks,
])
void main() {
  late MockTokenRepository mockRepository;
  late MockWalletManager mockWalletManager;
  late MockSessionPortfolioAggregator mockAggregator;
  late MockEthereumTokenService mockEthTokens;
  late MockTezosTokenService mockTezTokens;
  late MockActiveNetworks mockNetworks;

  const testWalletAddress = 'TEST_WALLET_ADDRESS_123';

  final testTokens = [
    const TokenBalance(
      mint: 'So11111111111111111111111111111111111111112',
      symbol: 'SOL',
      name: 'Wrapped SOL',
      decimals: 9,
      rawBalance: 1000000000,
      uiBalance: 1.0,
      pricePerToken: 200.0,
      totalUsdValue: 200.0,
    ),
    const TokenBalance(
      mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
      symbol: 'USDC',
      name: 'USD Coin',
      decimals: 6,
      rawBalance: 50000000,
      uiBalance: 50.0,
      pricePerToken: 1.0,
      totalUsdValue: 50.0,
    ),
  ];

  setUp(() {
    mockRepository = MockTokenRepository();
    mockWalletManager = MockWalletManager();
    mockAggregator = MockSessionPortfolioAggregator();
    mockEthTokens = MockEthereumTokenService();
    mockTezTokens = MockTezosTokenService();
    mockNetworks = MockActiveNetworks();
    // Default: every chain switched on, so these tests exercise the address
    // resolution rather than the Active Networks gate.
    when(mockNetworks.isEnabled(any)).thenAnswer((_) async => true);
    when(mockNetworks.changes).thenAnswer((_) => const Stream<void>.empty());

    // Default: single-signer path. The aggregator is consulted only when an
    // instance opts in via `aggregateAcrossSession` (the header/tokens tab).
    when(mockAggregator.profilePortfolioAddresses()).thenReturn(null);

    when(
      mockWalletManager.getAddress(),
    ).thenAnswer((_) async => testWalletAddress);
    // Default: the active account has no Ethereum wallet, so the ETH fan-out
    // resolves to nothing and these tests stay Solana-only. Stubbed with the
    // concrete chain (not `anyNamed`) so it stays distinct from the no-arg
    // `getAddress()` call above — an `anyNamed` matcher would also swallow that
    // call and break Solana address resolution.
    when(
      mockWalletManager.getAddress(chain: Chain.ethereum),
    ).thenAnswer((_) async => '');
    when(
      mockEthTokens.getTokenBalances(any),
    ).thenAnswer((_) async => <TokenBalance>[]);
    when(
      mockEthTokens.getCachedBalances(any),
    ).thenAnswer((_) async => <TokenBalance>[]);
    when(mockAggregator.sessionEthereumAddresses()).thenReturn(const []);
    // Default: a normal Solana session holding the active wallet.
    // `_resolveAddresses` consults this twice: to decide whether to skip the
    // Solana scope (an Eth/Tezos-only session has no Solana wallet), and to
    // confirm the session actually holds the globally-selected wallet — a
    // Profile session reads only the wallets linked in its user record.
    when(
      mockAggregator.sessionSolanaAddresses(),
    ).thenReturn(const [testWalletAddress]);
    // Default: the active account has no Tezos wallet either, so the Tezos
    // fan-out resolves to nothing and these tests stay Solana-only. Same
    // concrete-chain stubbing rationale as the Ethereum case above.
    when(
      mockWalletManager.getAddress(chain: Chain.tezos),
    ).thenAnswer((_) async => '');
    when(
      mockTezTokens.getTokenBalances(any),
    ).thenAnswer((_) async => <TokenBalance>[]);
    when(
      mockTezTokens.getCachedBalances(any),
    ).thenAnswer((_) async => <TokenBalance>[]);
    when(mockAggregator.sessionTezosAddresses()).thenReturn(const []);
    when(
      mockWalletManager.onWalletChanged,
    ).thenAnswer((_) => const Stream<String>.empty());

    // The bloc subscribes to balance-invalidation events on construction
    // (optimistic balance updates after confirmed transactions).
    when(
      mockRepository.balancesInvalidated,
    ).thenAnswer((_) => const Stream<String>.empty());

    // Default stubs for caching methods
    when(
      mockRepository.getCachedBalances(any),
    ).thenAnswer((_) async => <TokenBalance>[]);
    when(mockRepository.getCacheTimestamp(any)).thenAnswer((_) async => null);
    when(mockRepository.cacheBalances(any, any)).thenAnswer((_) async {});
    when(
      mockRepository.calculatePortfolioChange(any),
    ).thenReturn((dollarChange: null, percentChange: null));
  });

  group('TokenBalanceBloc', () {
    group('Load event - no cache', () {
      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'emits [loading, loaded] when load succeeds with no cache',
        setUp: () {
          when(
            mockRepository.getTokenBalances(testWalletAddress),
          ).thenAnswer((_) async => testTokens);
          when(
            mockRepository.calculateTotalValue(testTokens),
          ).thenReturn(250.0);
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        ),
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          const TokenBalanceState.loading(),
          isA<TokenBalanceLoaded>()
              .having((s) => s.tokens, 'tokens', testTokens)
              .having((s) => s.totalUsdValue, 'totalUsdValue', 250.0)
              .having((s) => s.isRefreshing, 'isRefreshing', false)
              .having((s) => s.lastUpdated, 'lastUpdated', isNotNull)
              // Tagged with the owning wallet so the header can tell a wallet
              // switch apart from a same-wallet refresh and snap accordingly.
              .having((s) => s.address, 'address', testWalletAddress),
        ],
        verify: (_) {
          verify(mockWalletManager.getAddress()).called(1);
          verify(mockRepository.getCachedBalances(testWalletAddress)).called(1);
          verify(mockRepository.getTokenBalances(testWalletAddress)).called(1);
          verify(
            mockRepository.cacheBalances(testWalletAddress, testTokens),
          ).called(1);
        },
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'emits [loading, loaded] with empty tokens when wallet has no tokens',
        setUp: () {
          when(
            mockRepository.getTokenBalances(testWalletAddress),
          ).thenAnswer((_) async => []);
          when(mockRepository.calculateTotalValue([])).thenReturn(0.0);
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        ),
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          const TokenBalanceState.loading(),
          isA<TokenBalanceLoaded>()
              .having((s) => s.tokens, 'tokens', isEmpty)
              .having((s) => s.totalUsdValue, 'totalUsdValue', 0.0),
        ],
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'emits [loading, error] when load fails with no cache',
        setUp: () {
          when(
            mockRepository.getTokenBalances(testWalletAddress),
          ).thenThrow(Exception('Network error'));
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        ),
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          const TokenBalanceState.loading(),
          isA<TokenBalanceError>().having(
            (e) => e.message,
            'message',
            contains('Network error'),
          ),
        ],
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'emits error when wallet manager fails',
        setUp: () {
          when(
            mockWalletManager.getAddress(),
          ).thenThrow(Exception('Wallet not initialized'));
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        ),
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          isA<TokenBalanceError>().having(
            (e) => e.message,
            'message',
            contains('Wallet not initialized'),
          ),
        ],
      );
    });

    group('Load event - with cache', () {
      final cacheTime = DateTime.now().subtract(const Duration(seconds: 10));

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'emits cached data immediately, then fresh data',
        setUp: () {
          when(
            mockRepository.getCachedBalances(testWalletAddress),
          ).thenAnswer((_) async => testTokens);
          when(
            mockRepository.getCacheTimestamp(testWalletAddress),
          ).thenAnswer((_) async => cacheTime);
          when(
            mockRepository.getTokenBalances(testWalletAddress),
          ).thenAnswer((_) async => testTokens);
          when(
            mockRepository.calculateTotalValue(testTokens),
          ).thenReturn(250.0);
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        ),
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          // First: cached data with isRefreshing=true
          isA<TokenBalanceLoaded>()
              .having((s) => s.tokens, 'tokens', testTokens)
              .having((s) => s.isRefreshing, 'isRefreshing', true)
              .having((s) => s.lastUpdated, 'lastUpdated', cacheTime),
          // Then: fresh data with isRefreshing=false
          isA<TokenBalanceLoaded>()
              .having((s) => s.tokens, 'tokens', testTokens)
              .having((s) => s.isRefreshing, 'isRefreshing', false)
              .having((s) => s.lastUpdated, 'lastUpdated', isNotNull),
        ],
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'keeps showing cached data when refresh fails',
        setUp: () {
          when(
            mockRepository.getCachedBalances(testWalletAddress),
          ).thenAnswer((_) async => testTokens);
          when(
            mockRepository.getCacheTimestamp(testWalletAddress),
          ).thenAnswer((_) async => cacheTime);
          when(
            mockRepository.calculateTotalValue(testTokens),
          ).thenReturn(250.0);
          when(
            mockRepository.getTokenBalances(testWalletAddress),
          ).thenThrow(Exception('Network error'));
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        ),
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          // First: cached data with isRefreshing=true
          isA<TokenBalanceLoaded>()
              .having((s) => s.tokens, 'tokens', testTokens)
              .having((s) => s.isRefreshing, 'isRefreshing', true),
          // Then: same cached data with isRefreshing=false (error handled gracefully)
          isA<TokenBalanceLoaded>()
              .having((s) => s.tokens, 'tokens', testTokens)
              .having((s) => s.isRefreshing, 'isRefreshing', false),
        ],
      );
    });

    group('Refresh event', () {
      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'sets isRefreshing true, then loads fresh data',
        setUp: () {
          when(
            mockRepository.getTokenBalances(testWalletAddress),
          ).thenAnswer((_) async => testTokens);
          when(
            mockRepository.calculateTotalValue(testTokens),
          ).thenReturn(250.0);
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        ),
        seed: () => TokenBalanceState.loaded(
          tokens: testTokens,
          totalUsdValue: 250.0,
          lastUpdated: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
        act: (bloc) => bloc.add(const TokenBalanceEvent.refresh()),
        expect: () => [
          // First: existing data with isRefreshing=true
          isA<TokenBalanceLoaded>().having(
            (s) => s.isRefreshing,
            'isRefreshing',
            true,
          ),
          // Then: fresh data with isRefreshing=false
          isA<TokenBalanceLoaded>()
              .having((s) => s.isRefreshing, 'isRefreshing', false)
              .having((s) => s.lastUpdated, 'lastUpdated', isNotNull),
        ],
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'keeps existing data when refresh fails',
        setUp: () {
          when(
            mockRepository.getTokenBalances(testWalletAddress),
          ).thenThrow(Exception('Refresh failed'));
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        ),
        seed: () => TokenBalanceState.loaded(
          tokens: testTokens,
          totalUsdValue: 250.0,
          lastUpdated: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
        act: (bloc) => bloc.add(const TokenBalanceEvent.refresh()),
        expect: () => [
          // First: existing data with isRefreshing=true
          isA<TokenBalanceLoaded>().having(
            (s) => s.isRefreshing,
            'isRefreshing',
            true,
          ),
          // Then: same data with isRefreshing=false (error handled gracefully)
          isA<TokenBalanceLoaded>()
              .having((s) => s.tokens, 'tokens', testTokens)
              .having((s) => s.isRefreshing, 'isRefreshing', false),
        ],
      );
    });

    group('State transitions', () {
      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'refresh updates tokens when data changes',
        setUp: () {
          final updatedTokens = [
            const TokenBalance(
              mint: 'So11111111111111111111111111111111111111112',
              symbol: 'SOL',
              name: 'Wrapped SOL',
              decimals: 9,
              rawBalance: 2000000000,
              uiBalance: 2.0,
              pricePerToken: 200.0,
              totalUsdValue: 400.0,
            ),
          ];
          when(
            mockRepository.getTokenBalances(testWalletAddress),
          ).thenAnswer((_) async => updatedTokens);
          when(
            mockRepository.calculateTotalValue(updatedTokens),
          ).thenReturn(400.0);
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        ),
        seed: () => TokenBalanceState.loaded(
          tokens: testTokens,
          totalUsdValue: 250.0,
          lastUpdated: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
        act: (bloc) => bloc.add(const TokenBalanceEvent.refresh()),
        expect: () => [
          isA<TokenBalanceLoaded>().having(
            (s) => s.isRefreshing,
            'isRefreshing',
            true,
          ),
          isA<TokenBalanceLoaded>()
              .having((s) => s.tokens.length, 'tokens.length', 1)
              .having((s) => s.totalUsdValue, 'totalUsdValue', 400.0)
              .having((s) => s.isRefreshing, 'isRefreshing', false),
        ],
        verify: (_) {
          verify(mockRepository.getTokenBalances(testWalletAddress)).called(1);
        },
      );
    });

    // The header/tokens-tab instance opts into aggregation. When a Profile spans
    // more than one Solana wallet, the portfolio is the *sum* across those
    // wallets — so the header value matches the drawer's per-profile total
    // rather than only the active signer's wallet.
    group('Aggregate session (profile mode)', () {
      const walletA = 'PROFILE_WALLET_A';
      const walletB = 'PROFILE_WALLET_B';

      final solInA = [
        const TokenBalance(
          mint: 'So11111111111111111111111111111111111111112',
          symbol: 'SOL',
          name: 'Wrapped SOL',
          decimals: 9,
          rawBalance: 1000000000,
          uiBalance: 1.0,
          pricePerToken: 200.0,
          totalUsdValue: 200.0,
          isNative: true,
        ),
      ];
      final usdcInB = [
        const TokenBalance(
          mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
          symbol: 'USDC',
          name: 'USD Coin',
          decimals: 6,
          rawBalance: 50000000,
          uiBalance: 50.0,
          pricePerToken: 1.0,
          totalUsdValue: 50.0,
        ),
      ];

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'fetches every profile wallet and sums the portfolio',
        setUp: () {
          when(
            mockAggregator.profilePortfolioAddresses(),
          ).thenReturn([walletA, walletB]);
          when(
            mockRepository.getTokenBalances(walletA),
          ).thenAnswer((_) async => solInA);
          when(
            mockRepository.getTokenBalances(walletB),
          ).thenAnswer((_) async => usdcInB);
          // Real summing so the test exercises the merge, not a canned total.
          when(mockRepository.calculateTotalValue(any)).thenAnswer((inv) {
            final list = inv.positionalArguments[0] as List<TokenBalance>;
            return list.fold<double>(0, (s, t) => s + (t.totalUsdValue ?? 0));
          });
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        )..aggregateAcrossSession = true,
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          const TokenBalanceState.loading(),
          isA<TokenBalanceLoaded>()
              .having((s) => s.tokens.length, 'tokens.length', 2)
              .having((s) => s.totalUsdValue, 'totalUsdValue', 250.0)
              .having((s) => s.isRefreshing, 'isRefreshing', false),
        ],
        verify: (_) {
          // Never falls back to the single active-signer address.
          verifyNever(mockWalletManager.getAddress());
          verify(mockRepository.getTokenBalances(walletA)).called(1);
          verify(mockRepository.getTokenBalances(walletB)).called(1);
          verify(mockRepository.cacheBalances(walletA, solInA)).called(1);
          verify(mockRepository.cacheBalances(walletB, usdcInB)).called(1);
        },
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'reads the linked wallet when the profile has one Solana wallet',
        setUp: () {
          when(
            mockAggregator.profilePortfolioAddresses(),
          ).thenReturn([walletA]);
          when(
            mockRepository.getTokenBalances(walletA),
          ).thenAnswer((_) async => testTokens);
          when(
            mockRepository.calculateTotalValue(testTokens),
          ).thenReturn(250.0);
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        )..aggregateAcrossSession = true,
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          const TokenBalanceState.loading(),
          isA<TokenBalanceLoaded>()
              .having((s) => s.totalUsdValue, 'totalUsdValue', 250.0)
              .having((s) => s.address, 'address', walletA),
        ],
        verify: (_) {
          // Why: falling through to the active signer would read whatever
          // wallet is globally selected, which a Profile session does not
          // guarantee to be one of its linked wallets — the header would then
          // total a wallet outside the profile.
          verifyNever(mockWalletManager.getAddress());
          verify(mockRepository.getTokenBalances(walletA)).called(1);
        },
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'a per-signer instance reads the session wallet, not an unlinked '
        'active selection',
        setUp: () {
          // Per-signer instances don't aggregate, so they resolve the active
          // wallet — which in a Profile session may be one the profile never
          // linked (switchToProfile leaves the previous selection in place
          // when the profile holds no signable wallet).
          when(mockAggregator.profilePortfolioAddresses()).thenReturn(null);
          when(
            mockAggregator.sessionSolanaAddresses(),
          ).thenReturn(const [walletA]);
          when(
            mockWalletManager.getAddress(),
          ).thenAnswer((_) async => 'UNLINKED_WALLET_ADDRESS');
          when(
            mockRepository.getTokenBalances(walletA),
          ).thenAnswer((_) async => testTokens);
          when(
            mockRepository.calculateTotalValue(testTokens),
          ).thenReturn(250.0);
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        ),
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          const TokenBalanceState.loading(),
          isA<TokenBalanceLoaded>().having(
            (s) => s.address,
            'address',
            walletA,
          ),
        ],
        verify: (_) {
          verify(mockRepository.getTokenBalances(walletA)).called(1);
          verifyNever(
            mockRepository.getTokenBalances('UNLINKED_WALLET_ADDRESS'),
          );
        },
      );
    });

    group('Solana-less session (Eth/Tezos-only account or profile)', () {
      const tezAddress = 'tz1TestTezosAddress';
      const tezToken = TokenBalance(
        mint: 'XTZ',
        symbol: 'XTZ',
        name: 'Tezos',
        decimals: 6,
        rawBalance: 5000000,
        uiBalance: 5.0,
        pricePerToken: 1.0,
        totalUsdValue: 5.0,
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'skips the Solana scope and surfaces the Tezos balance instead of '
        'fetching Solana on the non-Solana address',
        setUp: () {
          // Session holds a Tezos wallet but no Solana wallet.
          when(mockAggregator.sessionSolanaAddresses()).thenReturn(const []);
          when(
            mockAggregator.sessionTezosAddresses(),
          ).thenReturn(const [tezAddress]);
          when(
            mockWalletManager.getAddress(chain: Chain.tezos),
          ).thenAnswer((_) async => tezAddress);
          when(
            mockTezTokens.getTokenBalances(tezAddress),
          ).thenAnswer((_) async => [tezToken]);
          when(mockRepository.calculateTotalValue(any)).thenReturn(5.0);
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        )..aggregateAcrossSession = true,
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          const TokenBalanceState.loading(),
          isA<TokenBalanceLoaded>()
              .having((s) => s.tokens, 'tokens', [tezToken])
              .having((s) => s.totalUsdValue, 'totalUsdValue', 5.0),
        ],
        verify: (_) {
          // Why: resolving `getAddress()` (Solana) on a Solana-less session
          // returns a Tezos address; fetching Solana balances on it fails and
          // the bloc retains the previous session's cached balances — the
          // reported regression. The Solana scope must be skipped entirely.
          verifyNever(mockWalletManager.getAddress());
          verifyNever(mockRepository.getTokenBalances(any));
          verify(mockTezTokens.getTokenBalances(tezAddress)).called(1);
        },
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'a chain switched off in Active Networks contributes no rows and no '
        'USD, even when the session holds a wallet on it',
        setUp: () {
          // The session does hold a Tezos wallet with a real balance — only
          // the user's Active Networks toggle takes it off the tab.
          when(
            mockAggregator.sessionTezosAddresses(),
          ).thenReturn(const [tezAddress]);
          when(
            mockWalletManager.getAddress(chain: Chain.tezos),
          ).thenAnswer((_) async => tezAddress);
          when(
            mockTezTokens.getTokenBalances(tezAddress),
          ).thenAnswer((_) async => [tezToken]);
          when(
            mockNetworks.isEnabled(Chain.tezos),
          ).thenAnswer((_) async => false);
          when(
            mockRepository.getTokenBalances(testWalletAddress),
          ).thenAnswer((_) async => testTokens);
          when(mockRepository.calculateTotalValue(any)).thenAnswer((inv) {
            final list = inv.positionalArguments[0] as List<TokenBalance>;
            return list.fold<double>(0, (s, t) => s + (t.totalUsdValue ?? 0));
          });
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        )..aggregateAcrossSession = true,
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          const TokenBalanceState.loading(),
          isA<TokenBalanceLoaded>()
              .having(
                (s) => s.tokens.any((t) => t.chain == Chain.tezos),
                'holds a Tezos row',
                false,
              )
              // Why: the header total is summed from the same list, so a
              // switched-off chain must drop out of the value as well as the
              // rows — a hidden chain still counted in the portfolio total is
              // the inconsistency the NFT tab already avoids server-side.
              .having((s) => s.totalUsdValue, 'totalUsdValue', 250.0),
        ],
        verify: (_) {
          verifyNever(mockTezTokens.getTokenBalances(any));
        },
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'never reads a chain the session holds no wallet on, even when the '
        'active account has one',
        setUp: () {
          // The session (a Profile linking only a Solana wallet) holds no
          // Tezos wallet, but the account anchored to its signer does: seed
          // creation auto-derives Solana + Ethereum + Tezos at index 0, and
          // `getAddress(chain:)` answers from that account.
          when(
            mockAggregator.sessionTezosAddresses(),
          ).thenReturn(const <String>[]);
          when(
            mockWalletManager.getAddress(chain: Chain.tezos),
          ).thenAnswer((_) async => tezAddress);
          when(
            mockTezTokens.getTokenBalances(tezAddress),
          ).thenAnswer((_) async => [tezToken]);
          when(
            mockRepository.getTokenBalances(testWalletAddress),
          ).thenAnswer((_) async => testTokens);
          when(mockRepository.calculateTotalValue(any)).thenReturn(250.0);
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        )..aggregateAcrossSession = true,
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          const TokenBalanceState.loading(),
          isA<TokenBalanceLoaded>().having(
            (s) => s.tokens.any((t) => t.chain == Chain.tezos),
            'holds a Tezos row',
            false,
          ),
        ],
        verify: (_) {
          // Why: the account's auto-derived tz1 sibling is not part of the
          // profile. Reading it put an XTZ row — and its USD in the header
          // total — under a profile that links a single Solana wallet.
          verifyNever(mockTezTokens.getTokenBalances(any));
        },
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'keeps the Solana balances when the active signer has moved to the '
        "session's Tezos wallet",
        setUp: () {
          // The state the app is left in after a Tezos send: `SendSheet`
          // adopts the Tezos source via `SessionManager.selectSourceWallet`,
          // a *real* signer switch it never puts back, so the globally
          // selected wallet is now tz1 while the session still holds all
          // three chains.
          when(
            mockWalletManager.getAddress(),
          ).thenAnswer((_) async => tezAddress);
          when(
            mockAggregator.sessionSolanaAddresses(),
          ).thenReturn(const [testWalletAddress]);
          when(
            mockAggregator.sessionTezosAddresses(),
          ).thenReturn(const [tezAddress]);
          when(
            mockWalletManager.getAddress(chain: Chain.tezos),
          ).thenAnswer((_) async => tezAddress);
          when(
            mockTezTokens.getTokenBalances(tezAddress),
          ).thenAnswer((_) async => [tezToken]);
          when(
            mockRepository.getTokenBalances(testWalletAddress),
          ).thenAnswer((_) async => testTokens);
          when(mockRepository.calculateTotalValue(any)).thenReturn(255.0);
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        )..aggregateAcrossSession = true,
        act: (bloc) => bloc.add(const TokenBalanceEvent.load()),
        expect: () => [
          const TokenBalanceState.loading(),
          isA<TokenBalanceLoaded>().having(
            (s) => s.tokens,
            'tokens',
            containsAll([...testTokens, tezToken]),
          ),
        ],
        verify: (_) {
          // Why: which chain happens to be the active *signer* must not decide
          // whether the session's Solana wallet is read. Skipping the Solana
          // scope here wiped every SOL/SPL row — and its USD from the header
          // total — the moment a Tezos send left tz1 selected, leaving only
          // the XTZ balance on screen.
          verify(mockRepository.getTokenBalances(testWalletAddress)).called(1);
        },
      );
    });

    group('post-transaction invalidation', () {
      const tezAddress = 'tz1TestTezosAddress';
      late StreamController<String> invalidations;

      setUp(() {
        invalidations = StreamController<String>.broadcast();
        when(
          mockRepository.balancesInvalidated,
        ).thenAnswer((_) => invalidations.stream);
        when(
          mockAggregator.sessionTezosAddresses(),
        ).thenReturn(const [tezAddress]);
        when(
          mockWalletManager.getAddress(chain: Chain.tezos),
        ).thenAnswer((_) async => tezAddress);
        when(
          mockTezTokens.getTokenBalances(tezAddress),
        ).thenAnswer((_) async => <TokenBalance>[]);
        when(
          mockRepository.getTokenBalances(testWalletAddress),
        ).thenAnswer((_) async => testTokens);
        when(mockRepository.calculateTotalValue(any)).thenReturn(250.0);
      });

      tearDown(() => invalidations.close());

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'reloads when a Tezos address is signalled — a confirmed XTZ send '
        'refreshes that cache and announces it, and matching only the Solana '
        'scope dropped the signal so the tab kept the pre-send balance',
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        )..aggregateAcrossSession = true,
        act: (_) => invalidations.add(tezAddress),
        wait: const Duration(milliseconds: 50),
        expect: () => [
          const TokenBalanceState.loading(),
          isA<TokenBalanceLoaded>(),
        ],
        verify: (_) {
          verify(mockTezTokens.getTokenBalances(tezAddress)).called(1);
        },
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'ignores an address on no chain in scope — another session spending '
        'its own balance must not reload this one',
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        )..aggregateAcrossSession = true,
        act: (_) => invalidations.add('tz1SomeoneElsesTezosWallet'),
        wait: const Duration(milliseconds: 50),
        expect: () => const <TokenBalanceState>[],
      );

      blocTest<TokenBalanceBloc, TokenBalanceState>(
        'stays silent for a chain switched off in Active Networks — its rows '
        'are not on screen, so there is nothing to reload',
        setUp: () {
          when(
            mockNetworks.isEnabled(Chain.tezos),
          ).thenAnswer((_) async => false);
        },
        build: () => TokenBalanceBloc(
          mockRepository,
          mockWalletManager,
          mockAggregator,
          mockEthTokens,
          mockTezTokens,
          mockNetworks,
        )..aggregateAcrossSession = true,
        act: (_) => invalidations.add(tezAddress),
        wait: const Duration(milliseconds: 50),
        expect: () => const <TokenBalanceState>[],
      );
    });
  });
}
