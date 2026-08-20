import 'dart:convert';
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

/// Serves a scriptable `searchAssets` response — the Helius view of the
/// wallet, which may lag behind a transaction we just confirmed.
class _HeliusAdapter implements HttpClientAdapter {
  _HeliusAdapter({required this.lamports, required this.usdcRaw});

  int lamports;
  int usdcRaw;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': 'mallow-wallet',
      'result': {
        'items': [
          {
            'id': _usdc,
            'interface': 'FungibleToken',
            'content': {
              'metadata': {'symbol': 'USDC', 'name': 'USD Coin'},
            },
            'token_info': {
              'balance': usdcRaw,
              'decimals': 6,
              'symbol': 'USDC',
              'price_info': {'price_per_token': 1.0},
            },
          },
        ],
        'nativeBalance': {'lamports': lamports, 'price_per_sol': 100.0},
      },
    }),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

const _usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const _wallet = 'Wallet11111111111111111111111111111111111111';

// A swap of 0.5 SOL (plus a 5000 lamport fee) into 112.5 USDC.
const _preLamports = 2000000000;
const _postLamports = 1494995000;
const _preUsdc = 10000000;
const _postUsdc = 122500000;

const _swapBalances = <ConfirmedBalance>[
  (
    mint: TokenBalance.solMint,
    isNative: true,
    rawBalance: _postLamports,
    previousRawBalance: _preLamports,
  ),
  (
    mint: _usdc,
    isNative: false,
    rawBalance: _postUsdc,
    previousRawBalance: _preUsdc,
  ),
];

void main() {
  late MallowDatabase db;
  late _HeliusAdapter helius;
  late TokenRepository repo;

  setUp(() {
    Config.debugOverrides['RPC_PROXY_BASE_URL'] = 'https://rpc.test';
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    final jupiter = _MockJupiterTokenService();
    when(() => jupiter.getMarketInfo(any())).thenAnswer((_) async => {});
    // The stale view: exactly what the wallet held before the swap.
    helius = _HeliusAdapter(lamports: _preLamports, usdcRaw: _preUsdc);
    repo = TokenRepository.withAdapter(_MockPriceClient(), db, jupiter, helius);
  });
  tearDown(() {
    Config.debugOverrides.clear();
    return db.close();
  });

  Future<TokenBalance> fetch(String mint) async {
    final tokens = await repo.getTokenBalances(_wallet);
    return tokens.singleWhere((t) => t.mint == mint);
  }

  test('a fetch still reporting the pre-transaction balances is recognised as '
      'stale and corrected — the indexer lagging must not roll a confirmed '
      'swap back to its pre-swap numbers', () async {
    await repo.applyConfirmedBalances(
      walletAddress: _wallet,
      balances: _swapBalances,
    );

    expect((await fetch(TokenBalance.solMint)).rawBalance, _postLamports);
    final usdc = await fetch(_usdc);
    expect(usdc.rawBalance, _postUsdc);
    // Display + USD values follow the corrected amount, not the stale one.
    expect(usdc.uiBalance, closeTo(122.5, 1e-9));
    expect(usdc.totalUsdValue, closeTo(122.5, 1e-9));
  });

  test('the guard survives repeated stale reads — Helius can lag for more '
      'than one refresh', () async {
    await repo.applyConfirmedBalances(
      walletAddress: _wallet,
      balances: _swapBalances,
    );

    expect((await fetch(_usdc)).rawBalance, _postUsdc);
    expect((await fetch(_usdc)).rawBalance, _postUsdc);
  });

  test('a value that is neither pre nor post wins outright — the chain moved '
      'past our transaction (a later swap, an incoming transfer) and pinning '
      'it would show a balance the wallet no longer has', () async {
    await repo.applyConfirmedBalances(
      walletAddress: _wallet,
      balances: _swapBalances,
    );

    helius.usdcRaw = 500000000;
    expect((await fetch(_usdc)).rawBalance, 500000000);

    // Guard retired: a subsequent read of the pre-value is accepted as real.
    helius.usdcRaw = _preUsdc;
    expect((await fetch(_usdc)).rawBalance, _preUsdc);
  });

  test('once the indexer catches up the guard retires, so a genuine later '
      'move back to the pre-swap balance is not overwritten', () async {
    await repo.applyConfirmedBalances(
      walletAddress: _wallet,
      balances: _swapBalances,
    );

    helius.usdcRaw = _postUsdc;
    expect((await fetch(_usdc)).rawBalance, _postUsdc);

    helius.usdcRaw = _preUsdc;
    expect((await fetch(_usdc)).rawBalance, _preUsdc);
  });

  test('the guard expires — it is a lag window, not a permanent override of '
      'what the indexer reports', () async {
    await repo.applyConfirmedBalances(
      walletAddress: _wallet,
      balances: _swapBalances,
      guardTtl: Duration.zero,
    );

    expect((await fetch(_usdc)).rawBalance, _preUsdc);
  });

  test('a holding the transaction did not move is never guarded', () async {
    await repo.applyConfirmedBalances(
      walletAddress: _wallet,
      balances: const [
        (
          mint: _usdc,
          isNative: false,
          rawBalance: _preUsdc,
          previousRawBalance: _preUsdc,
        ),
      ],
    );

    helius.usdcRaw = 7;
    expect((await fetch(_usdc)).rawBalance, 7);
  });

  test('clearing a wallet cache drops its guards, so the refetch that '
      'repopulates it is taken at face value', () async {
    await repo.applyConfirmedBalances(
      walletAddress: _wallet,
      balances: _swapBalances,
    );
    await repo.clearCache(_wallet);

    expect((await fetch(_usdc)).rawBalance, _preUsdc);
  });
}
