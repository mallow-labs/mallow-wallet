import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockDasApiService extends Mock implements DasApiService {}

/// The cached Jupiter verified list, as a single settable row.
class _FakeDatabase extends Fake implements MallowDatabase {
  CachedJupiterTokenListData? row;

  @override
  Future<CachedJupiterTokenListData?> getJupiterTokenListEntry(String mint) =>
      Future.value(row?.mint == mint ? row : null);
}

// Seven memecoin listing currencies (WEN, SILLY, GUAC, FWOG, VALUE, PXLPSHR,
// ART) were deliberately dropped from the static registry, which left their
// listings unpriceable: with no `chain` the amount rendered blank, and with
// one it was rescaled to the chain's native token — a 5,000 WEN sale showed
// as "0.5 SOL". This service is what replaced static registration, so what
// matters in these tests is not "does it call DAS" but the two properties the
// buy/bid CTAs are gated on:
//
//   * a mint is only ever `resolved` when a real symbol AND real decimals are
//     in hand (never signable for an amount that was never displayed), and
//   * a registry mint costs nothing — no request, no shimmer, no gating delay.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wenMint = 'WENWENvqqNya429ubCdR81ZmD69brwQaaBYY6p3LCpk';

  Map<String, dynamic> dasResponse({
    String? symbol = 'WEN',
    int? decimals = 5,
    String? image = 'https://cdn.example/wen.png',
  }) => {
    'id': wenMint,
    'interface': 'FungibleToken',
    'content': {
      'metadata': {'name': 'Wen', 'symbol': symbol},
      'links': {'image': ?image},
    },
    'token_info': {'symbol': ?symbol, 'decimals': ?decimals},
  };

  /// A verified-list row for [wenMint], as the swap picker's 24h refresh
  /// would have cached it.
  CachedJupiterTokenListData verifiedRow({
    String? symbol = 'WEN',
    int? decimals = 5,
    String? iconUrl = 'https://jup.example/wen.png',
  }) => CachedJupiterTokenListData(
    mint: wenMint,
    symbol: symbol,
    name: 'Wen',
    decimals: decimals,
    iconUrl: iconUrl,
    cachedAt: 0,
  );

  late _MockDasApiService das;
  late _FakeDatabase database;
  late PreferencesService prefs;

  Future<TokenMetadataService> build() async {
    prefs = await PreferencesService.create();
    return TokenMetadataService(das, prefs, database);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    das = _MockDasApiService();
    database = _FakeDatabase();
    // The overlay is process-global (it backs `tokenByMint` for every caller),
    // so leaking a resolved mint across tests would make later assertions pass
    // for the wrong reason.
    clearResolvedTokens();
  });

  tearDown(clearResolvedTokens);

  group('registry short-circuit', () {
    test(
      'a registered mint resolves synchronously and never hits DAS',
      () async {
        final service = await build();

        expect(service.needsLookup(usdcMint), isFalse);
        expect(service.statusOf(usdcMint), TokenMetadataStatus.resolved);
        expect((await service.resolve(usdcMint))?.symbol, 'USDC');
        verifyNever(() => das.getAssetRaw(any()));
      },
    );

    test(
      'an absent mint is not a lookup — it means the native currency',
      () async {
        final service = await build();

        expect(service.needsLookup(null), isFalse);
        expect(service.needsLookup(''), isFalse);
        expect(service.statusOf(null), TokenMetadataStatus.resolved);
        verifyNever(() => das.getAssetRaw(any()));
      },
    );

    test('a non-Solana chain runs no lookup and resolves nothing', () async {
      final service = await build();

      // DAS only indexes Solana, so there is no request to make for a Tezos
      // FA-contract currency. It resolves to null rather than to XTZ: the
      // chain's base token is a different currency, and handing it back would
      // scale the amount by tez's decimals under tez's ticker.
      expect(service.needsLookup('KT1Tjn', chain: 'tezos'), isFalse);
      expect((await service.resolve('KT1Tjn', chain: 'tezos'))?.symbol, isNull);
      verifyNever(() => das.getAssetRaw(any()));
    });

    test(
      'an absent mint still resolves to the chain native currency',
      () async {
        final service = await build();

        // The legitimate use of the chain hint: no `currencyMint` on a Tezos
        // event means the amount is in mutez.
        expect((await service.resolve(null, chain: 'tezos'))?.symbol, 'XTZ');
        verifyNever(() => das.getAssetRaw(any()));
      },
    );
  });

  group('cached Jupiter verified list', () {
    test('answers the whole lookup without a request', () async {
      database.row = verifiedRow();
      final service = await build();

      final token = await service.resolve(wenMint);

      expect(token?.symbol, 'WEN');
      expect(token?.decimals, 5);
      expect(service.imageUrlFor(wenMint), 'https://jup.example/wen.png');
      expect(tokenByMint(wenMint)?.symbol, 'WEN');
      // The catalog is already on disk, so paying an RPC round-trip for what
      // it holds is the thing this source exists to avoid.
      verifyNever(() => das.getAssetRaw(any()));
      // …and it is cached like any other resolution, so a device whose
      // catalog is later replaced still knows this mint.
      final persisted =
          jsonDecode(prefs.tokenMetadataCache!) as Map<String, dynamic>;
      expect(persisted[wenMint]['symbol'], 'WEN');
    });

    test('a row with no decimals falls through to DAS', () async {
      // Decimals are load-bearing, and rows cached by an earlier build can
      // lack them. Half a row is a miss, not a partial answer.
      database.row = verifiedRow(decimals: null);
      when(
        () => das.getAssetRaw(wenMint),
      ).thenAnswer((_) async => dasResponse());
      final service = await build();

      expect((await service.resolve(wenMint))?.decimals, 5);
      verify(() => das.getAssetRaw(wenMint)).called(1);
    });

    test('a mint the catalog never carried falls through to DAS', () async {
      // The list is only populated once the swap sheet has been opened, and
      // covers only verified mints, so a miss is the ordinary case.
      when(
        () => das.getAssetRaw(wenMint),
      ).thenAnswer((_) async => dasResponse());
      final service = await build();

      expect((await service.resolve(wenMint))?.symbol, 'WEN');
      verify(() => das.getAssetRaw(wenMint)).called(1);
    });
  });

  group('DAS fallback', () {
    test(
      'populates the registry overlay, the cache and the prefs blob',
      () async {
        when(
          () => das.getAssetRaw(wenMint),
        ).thenAnswer((_) async => dasResponse());
        final service = await build();

        expect(service.statusOf(wenMint), TokenMetadataStatus.resolving);

        final token = await service.resolve(wenMint);

        expect(token?.symbol, 'WEN');
        expect(token?.decimals, 5);
        expect(service.statusOf(wenMint), TokenMetadataStatus.resolved);
        expect(service.imageUrlFor(wenMint), 'https://cdn.example/wen.png');
        // The overlay is the whole point: every existing `tokenByMint` caller
        // (price formatting, balance checks, proceeds rows) becomes correct
        // without being rewired.
        expect(tokenByMint(wenMint)?.symbol, 'WEN');
        // …but a mint we merely looked up must not become a *mallow* token:
        // that set drives verified badges and the seller's currency picker.
        expect(isRegistryMint(wenMint), isFalse);
        expect(mallowTokenMints.contains(wenMint), isFalse);

        final persisted =
            jsonDecode(prefs.tokenMetadataCache!) as Map<String, dynamic>;
        expect(persisted[wenMint]['symbol'], 'WEN');
        expect(persisted[wenMint]['decimals'], 5);
      },
    );

    test(
      'falls back to content.metadata.symbol when token_info has none',
      () async {
        when(() => das.getAssetRaw(wenMint)).thenAnswer(
          (_) async => {
            'content': {
              'metadata': {'symbol': 'FWOG'},
            },
            'token_info': {'decimals': 6},
          },
        );
        final service = await build();

        expect((await service.resolve(wenMint))?.symbol, 'FWOG');
      },
    );

    test(
      'a response with no decimals is a failure, not a partial success',
      () async {
        // Decimals are the load-bearing field: without them there is no way to
        // scale the amount, and a guessed scale is how "0.5 SOL" happened.
        when(
          () => das.getAssetRaw(wenMint),
        ).thenAnswer((_) async => dasResponse(decimals: null));
        final service = await build();

        expect(await service.resolve(wenMint), isNull);
        expect(service.statusOf(wenMint), TokenMetadataStatus.unresolved);
        expect(tokenByMint(wenMint), isNull);
      },
    );
  });

  group('cache', () {
    test('a hit inside the TTL skips DAS entirely', () async {
      when(
        () => das.getAssetRaw(wenMint),
      ).thenAnswer((_) async => dasResponse());
      final service = await build();

      await service.resolve(wenMint);
      await service.resolve(wenMint);
      await service.resolve(wenMint);

      verify(() => das.getAssetRaw(wenMint)).called(1);
    });

    test('a warm start resolves from prefs with no request', () async {
      SharedPreferences.setMockInitialValues({
        'pref_token_metadata_cache': jsonEncode({
          wenMint: {
            'symbol': 'WEN',
            'decimals': 5,
            'fetchedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          },
        }),
      });
      final service = await build();

      // Synchronous: the price row must not flash a shimmer for a currency
      // this device already knows, and the CTA must not gate on it.
      expect(service.statusOf(wenMint), TokenMetadataStatus.resolved);
      expect(tokenByMint(wenMint)?.decimals, 5);
      verifyNever(() => das.getAssetRaw(any()));
    });

    test(
      'past the 30-day TTL it refetches, but keeps serving the cached value',
      () async {
        when(
          () => das.getAssetRaw(wenMint),
        ).thenAnswer((_) async => dasResponse());
        final service = await build();
        await service.resolve(wenMint);
        verify(() => das.getAssetRaw(wenMint)).called(1);

        service.clock = () =>
            DateTime.now().add(TokenMetadataService.cacheTtl * 2);

        // Decimals are immutable, so an expired entry is still a correct figure —
        // the TTL exists only for symbol/logo churn. The user sees no shimmer…
        expect(service.statusOf(wenMint), TokenMetadataStatus.resolved);
        expect((await service.resolve(wenMint))?.symbol, 'WEN');
        // …while the refresh runs underneath.
        verify(() => das.getAssetRaw(wenMint)).called(1);
      },
    );
  });

  test('concurrent lookups for one mint share a single request', () async {
    var calls = 0;
    when(() => das.getAssetRaw(wenMint)).thenAnswer((_) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return dasResponse();
    });
    final service = await build();

    // Every price row on an artwork page asks for the same listing currency in
    // the same frame; without coalescing that is one RPC per row.
    final results = await Future.wait([
      service.resolve(wenMint),
      service.resolve(wenMint),
      service.resolve(wenMint),
    ]);

    expect(calls, 1);
    expect(results.map((t) => t?.symbol), everyElement('WEN'));
  });

  group('failure', () {
    test('a thrown DAS call leaves the mint unresolved', () async {
      when(() => das.getAssetRaw(wenMint)).thenThrow(Exception('rpc down'));
      final service = await build();

      expect(await service.resolve(wenMint), isNull);
      expect(service.statusOf(wenMint), TokenMetadataStatus.unresolved);
      // Nothing is published to the overlay, so price surfaces render
      // "Unknown token" rather than a number in the wrong denomination.
      expect(tokenByMint(wenMint), isNull);
    });

    test(
      'a failure is negative-cached only for its TTL, then retried',
      () async {
        var attempt = 0;
        when(() => das.getAssetRaw(wenMint)).thenAnswer((_) async {
          if (attempt++ == 0) throw Exception('rpc blip');
          return dasResponse();
        });
        final now = DateTime.now();
        final service = await build();
        service.clock = () => now;

        expect(await service.resolve(wenMint), isNull);
        // Inside the window every price row on the screen asking again must not
        // become one DAS request per row per rebuild.
        expect(await service.resolve(wenMint), isNull);
        expect(attempt, 1);

        // Past it the blip must not still be pinning the mint: a permanently
        // negative-cached failure kept the price at "Unknown token" and the buy
        // / bid CTA disabled for the rest of the process.
        service.clock = () => now.add(TokenMetadataService.failureTtl * 2);
        expect(service.statusOf(wenMint), TokenMetadataStatus.resolving);

        expect((await service.resolve(wenMint))?.symbol, 'WEN');
        expect(service.statusOf(wenMint), TokenMetadataStatus.resolved);
      },
    );
  });
}
