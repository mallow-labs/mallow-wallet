import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/ethereum_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/tezos_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/portfolio/data/wallet_balance_totals.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

/// Hand-written fakes (no codegen). Each records the addresses it was asked
/// about so a test can assert an address never reached the wrong chain's
/// service; everything else routes through [noSuchMethod].
class _FakeSolanaRepo implements TokenRepository {
  final asked = <String>[];
  final cached = <String>[];

  @override
  Future<List<TokenBalance>> getCachedBalances(String walletAddress) async {
    asked.add(walletAddress);
    return [_token('SOL', 5)];
  }

  @override
  Future<List<TokenBalance>> getTokenBalances(String walletAddress) async {
    asked.add(walletAddress);
    return [_token('SOL', 5)];
  }

  @override
  Future<void> cacheBalances(
    String walletAddress,
    List<TokenBalance> tokens,
  ) async {
    cached.add(walletAddress);
  }

  // The real sum — the helper must not reimplement it per chain.
  @override
  double calculateTotalValue(List<TokenBalance> tokens) =>
      tokens.fold(0.0, (sum, t) => sum + (t.totalUsdValue ?? 0));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeEthService implements EthereumTokenService {
  final asked = <String>[];

  @override
  Future<List<TokenBalance>> getCachedBalances(String address) async {
    asked.add(address);
    return [_token('ETH', 11, chain: Chain.ethereum)];
  }

  @override
  Future<List<TokenBalance>> getTokenBalances(String address) async {
    asked.add(address);
    return [_token('ETH', 11, chain: Chain.ethereum)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTezosService implements TezosTokenService {
  final asked = <String>[];

  @override
  Future<List<TokenBalance>> getCachedBalances(String address) async {
    asked.add(address);
    return [_token('XTZ', 7, chain: Chain.tezos)];
  }

  @override
  Future<List<TokenBalance>> getTokenBalances(String address) async {
    asked.add(address);
    return [_token('XTZ', 7, chain: Chain.tezos)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TokenBalance _token(String symbol, double usd, {Chain chain = Chain.solana}) =>
    TokenBalance(
      mint: symbol,
      symbol: symbol,
      name: symbol,
      decimals: 9,
      rawBalance: 1,
      uiBalance: 1,
      pricePerToken: usd,
      totalUsdValue: usd,
      chain: chain,
    );

/// The drawer header sums the session's holdings by fanning out to one service
/// per chain (`TokenBalanceBloc`), while the account/profile rows below it sum
/// per-wallet totals. When those rows routed every non-`0x…` address through
/// the Solana `TokenRepository`, a Tezos wallet's balance was fetched from
/// Helius `searchAssets` — which cannot parse a `tz1…` owner and answers empty.
/// The row then read $0 against a header showing the real total, and the
/// write-through `cacheBalances(address, [])` deleted that wallet's real Tezos
/// rows from the shared cache on the way out.
///
/// These tests pin the routing itself, not a formatted number: the assertion
/// that matters is which service each address reached.
void main() {
  const solAddress = 'So11111111111111111111111111111111111111112';
  const ethAddress = '0x1111111111111111111111111111111111111111';
  const tezosAddress = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';

  late _FakeSolanaRepo solana;
  late _FakeEthService ethereum;
  late _FakeTezosService tezos;

  setUp(() {
    solana = _FakeSolanaRepo();
    ethereum = _FakeEthService();
    tezos = _FakeTezosService();
    sl.registerSingleton<TokenRepository>(solana);
    sl.registerSingleton<EthereumTokenService>(ethereum);
    sl.registerSingleton<TezosTokenService>(tezos);
  });

  tearDown(sl.reset);

  group('cachedWalletTotalUsd', () {
    test(
      'reads a Tezos address from the Tezos cache, never the Solana one',
      () async {
        expect(await cachedWalletTotalUsd(tezosAddress), 7);
        expect(tezos.asked, [tezosAddress]);
        expect(solana.asked, isEmpty);
      },
    );

    test('reads an Ethereum address from the EVM cache', () async {
      expect(await cachedWalletTotalUsd(ethAddress), 11);
      expect(ethereum.asked, [ethAddress]);
      expect(solana.asked, isEmpty);
    });

    test('reads a Solana address from the Solana cache', () async {
      expect(await cachedWalletTotalUsd(solAddress), 5);
      expect(solana.asked, [solAddress]);
      expect(ethereum.asked, isEmpty);
      expect(tezos.asked, isEmpty);
    });

    test('returns null — not 0 — when the chain cache holds no rows, so the '
        'row shimmers instead of claiming an empty wallet', () async {
      sl.unregister<TezosTokenService>();
      sl.registerSingleton<TezosTokenService>(_EmptyTezosService());

      expect(await cachedWalletTotalUsd(tezosAddress), isNull);
    });
  });

  group('fetchWalletTotalUsd', () {
    test('fetches a Tezos address from the Tezos backend and leaves the Solana '
        'write-through cache untouched', () async {
      expect(await fetchWalletTotalUsd(tezosAddress), 7);
      expect(tezos.asked, [tezosAddress]);
      expect(solana.asked, isEmpty);
      // The wipe: cacheBalances(tz1…, []) would delete the real Tezos rows.
      expect(solana.cached, isEmpty);
    });

    test('fetches an Ethereum address from the EVM backend, which caches its '
        'own rows', () async {
      expect(await fetchWalletTotalUsd(ethAddress), 11);
      expect(ethereum.asked, [ethAddress]);
      expect(solana.cached, isEmpty);
    });

    test('fetches a Solana address and writes it back through the Solana '
        'cache', () async {
      expect(await fetchWalletTotalUsd(solAddress), 5);
      expect(solana.asked, [solAddress]);
      expect(solana.cached, [solAddress]);
    });
  });
}

class _EmptyTezosService implements TezosTokenService {
  @override
  Future<List<TokenBalance>> getCachedBalances(String address) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
