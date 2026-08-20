import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/portfolio/data/confirmed_tx_balances.dart';
import 'package:mallow_wallet/features/portfolio/data/jupiter_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mocktail/mocktail.dart';

class _MockPriceClient extends Mock implements JupiterPriceClient {}

class _MockJupiterTokenService extends Mock implements JupiterTokenService {}

class _UnusedAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw StateError('no network expected');

  @override
  void close({bool force = false}) {}
}

void main() {
  late MallowDatabase db;
  late TokenRepository repo;

  const wallet = 'Wallet11111111111111111111111111111111111111';
  const usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
  const unheld = 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263';

  setUp(() async {
    Config.debugOverrides['RPC_PROXY_BASE_URL'] = 'https://rpc.test';
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    repo = TokenRepository.withAdapter(
      _MockPriceClient(),
      db,
      _MockJupiterTokenService(),
      _UnusedAdapter(),
    );
    await repo.cacheBalances(wallet, [
      TokenBalance.nativeSol(lamports: 2000000000, pricePerToken: 100),
      const TokenBalance(
        mint: usdc,
        symbol: 'USDC',
        name: 'USD Coin',
        decimals: 6,
        rawBalance: 10000000,
        uiBalance: 10,
        pricePerToken: 1,
        totalUsdValue: 10,
      ),
    ]);
  });
  tearDown(() {
    Config.debugOverrides.clear();
    return db.close();
  });

  test('confirmed balances overwrite the cached rows and rescale the UI and '
      'USD values off the new amount', () async {
    await repo.applyConfirmedBalances(
      walletAddress: wallet,
      balances: const [
        (
          mint: TokenBalance.solMint,
          isNative: true,
          rawBalance: 1494995000,
          previousRawBalance: 2000000000,
        ),
        (
          mint: usdc,
          isNative: false,
          rawBalance: 122500000,
          previousRawBalance: 10000000,
        ),
      ],
    );

    final cached = await repo.getCachedBalances(wallet);
    final sol = cached.singleWhere((t) => t.isNative);
    final usdcRow = cached.singleWhere((t) => t.mint == usdc);
    expect(sol.rawBalance, 1494995000);
    expect(sol.uiBalance, closeTo(1.494995, 1e-9));
    expect(usdcRow.uiBalance, closeTo(122.5, 1e-9));
    expect(usdcRow.totalUsdValue, closeTo(122.5, 1e-9));
  });

  test('applying the same confirmed balances twice is idempotent — the write '
      'is absolute, so a re-run (or a refetch that already landed it) can '
      'never double-count', () async {
    const balances = <ConfirmedBalance>[
      (
        mint: usdc,
        isNative: false,
        rawBalance: 122500000,
        previousRawBalance: 10000000,
      ),
    ];
    await repo.applyConfirmedBalances(
      walletAddress: wallet,
      balances: balances,
    );
    await repo.applyConfirmedBalances(
      walletAddress: wallet,
      balances: balances,
    );

    final cached = await repo.getCachedBalances(wallet);
    expect(cached.singleWhere((t) => t.mint == usdc).rawBalance, 122500000);
  });

  test('a mint with no cached row is skipped rather than synthesized without '
      'its metadata, but still signals the refetch that surfaces it', () async {
    final signalled = repo.balancesInvalidated.first;

    await repo.applyConfirmedBalances(
      walletAddress: wallet,
      balances: const [
        (mint: unheld, isNative: false, rawBalance: 42, previousRawBalance: 0),
      ],
    );

    expect(await signalled.timeout(const Duration(seconds: 1)), wallet);
    final cached = await repo.getCachedBalances(wallet);
    expect(cached.where((t) => t.mint == unheld), isEmpty);
  });

  test('an empty result still signals, so a caller that could not read the '
      'transaction falls back to the authoritative refetch', () async {
    final signalled = repo.balancesInvalidated.first;

    await repo.applyConfirmedBalances(
      walletAddress: wallet,
      balances: const [],
    );

    expect(await signalled.timeout(const Duration(seconds: 1)), wallet);
  });
}
