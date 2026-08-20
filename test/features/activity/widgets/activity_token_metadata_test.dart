import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/activity/utils/activity_helpers.dart';
import 'package:mallow_wallet/features/activity/widgets/activity_list_item.dart';
import 'package:mallow_wallet/features/activity/widgets/activity_preview.dart';
import 'package:mallow_wallet/shared/widgets/mallow_network_image.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/no_verified_list_database.dart';

class _MockDasApiService extends Mock implements DasApiService {}

// The Solana feeds name almost nothing. `/v2/activity` builds swap legs and
// plain SPL transfers from raw balance deltas, and `/v2/transfers` (the token
// detail sheet's History tab) has no `logoUrl` field at all: every leg but SOL
// arrives with an empty `symbol` and no logo. That left any token outside the
// app's ~25-entry static registry — which is most of what people actually hold
// and swap — rendering as a truncated mint beside a blank tile. These tests pin
// the on-device resolution that fills both in for a swap AND for a transfer,
// and pin the row still naming the token when it can't be resolved at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const unindexedMint = 'Unindexed11111111111111111111111111111111x';
  const solMintAddress = 'So11111111111111111111111111111111111111112';

  late _MockDasApiService das;

  Map<String, dynamic> dasResponse() => {
    'id': unindexedMint,
    'interface': 'FungibleToken',
    'content': {
      'metadata': {'name': 'Wen', 'symbol': 'WEN'},
      'links': {'image': 'https://cdn.example/wen.png'},
    },
    'token_info': {'symbol': 'WEN', 'decimals': 6},
  };

  /// A SOL → unindexed-mint swap, exactly as the feed serializes one: the
  /// bought token has no symbol and no logo.
  api.Activity swapRow({String id = 'a1', String outMint = unindexedMint}) =>
      api.Activity(
        id: id,
        type: api.ActivityType.swap,
        timestamp: 1700000000,
        signature: 'sig1',
        status: api.ActivityStatus.confirmed,
        data: {
          'inputToken': {
            'mint': solMintAddress,
            'symbol': 'SOL',
            'amount': 1.0,
            'decimals': 9,
          },
          'outputToken': {
            'mint': outMint,
            'symbol': '',
            'amount': 12.5,
            'decimals': 6,
          },
        },
      );

  /// A receive of the same unindexed mint, exactly as `/v2/transfers`
  /// serializes one for the token detail sheet's History tab: no symbol, and no
  /// `logoUrl` key on the wire at all.
  api.Activity transferRow({String id = 't1', bool isNft = false}) =>
      api.Activity(
        id: id,
        type: api.ActivityType.receive,
        timestamp: 1700000000,
        signature: 'sig2',
        status: api.ActivityStatus.confirmed,
        data: {
          'token': {
            'mint': unindexedMint,
            'symbol': '',
            'amount': 12.5,
            'decimals': 6,
          },
          'counterparty': {
            'address': 'Counterparty111111111111111111111111111',
          },
          'isNft': isNft,
        },
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // The overlay `tokenByMint` reads is process-global, so a mint resolved by
    // one test would name the token in the next one for the wrong reason.
    clearResolvedTokens();
    das = _MockDasApiService();
  });

  tearDown(() {
    clearResolvedTokens();
    if (sl.isRegistered<TokenMetadataService>()) {
      sl.unregister<TokenMetadataService>();
    }
  });

  Future<void> registerService() async {
    final prefs = await PreferencesService.create();
    if (sl.isRegistered<TokenMetadataService>()) {
      sl.unregister<TokenMetadataService>();
    }
    sl.registerSingleton<TokenMetadataService>(
      TokenMetadataService(das, prefs, NoVerifiedListDatabase()),
    );
  }

  testWidgets('a swap row names and pictures an unindexed leg', (tester) async {
    when(
      () => das.getAssetRaw(unindexedMint),
    ).thenAnswer((_) async => dasResponse());
    await registerService();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ActivityListItem(activity: swapRow())),
      ),
    );

    // Before the lookup lands the row degrades to the mint, as it always has.
    expect(find.text('SOL → Unind…1111x'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('SOL → WEN'), findsOneWidget);
    expect(find.text('+12.50 WEN'), findsOneWidget);
    // The logo the same read returned — the wire row carries no `logoUrl`, so
    // without it the leg stays a letter tile however well we name it.
    final image = tester.widget<MallowNetworkImage>(
      find.byType(MallowNetworkImage),
    );
    expect(image.imageUrl, 'https://cdn.example/wen.png');
  });

  testWidgets('a transfer row names and pictures an unindexed token', (
    tester,
  ) async {
    // The History tab in the token detail sheet is nothing but these rows, and
    // they were the half of the feed the resolution never covered: the tile
    // read the wire `symbol`/`logoUrl` straight, so a token the sheet's own
    // header pictures correctly rendered underneath it as a blank square.
    when(
      () => das.getAssetRaw(unindexedMint),
    ).thenAnswer((_) async => dasResponse());
    await registerService();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActivityListItem(
            activity: transferRow(),
            tokenMintContext: unindexedMint,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('+12.50 WEN'), findsOneWidget);
    final image = tester.widget<MallowNetworkImage>(
      find.byType(MallowNetworkImage),
    );
    expect(image.imageUrl, 'https://cdn.example/wen.png');
  });

  test('an NFT transfer is left to the server-side enrichment', () async {
    // NFT rows carry their name and image from mallow's own index, on fields a
    // fungible `getAsset` read can't supply. Sending them through DAS would
    // spend a request per row and still render the same generic icon.
    await registerService();

    expect(
      await resolveActivityTokenMetadata(transferRow(isNft: true)),
      isFalse,
    );
    verifyNever(() => das.getAssetRaw(any()));
  });

  testWidgets('a recycled row resolves the mint it now holds', (tester) async {
    // Feed rows are recycled as the list scrolls: the state that already
    // resolved one swap is handed the next one. Without re-running the lookup
    // the second row keeps showing a truncated mint forever.
    const otherMint = 'Second1111111111111111111111111111111111x';
    when(
      () => das.getAssetRaw(unindexedMint),
    ).thenAnswer((_) async => dasResponse());
    when(() => das.getAssetRaw(otherMint)).thenAnswer(
      (_) async => {
        'content': {
          'metadata': {'symbol': 'BONK'},
        },
        'token_info': {'symbol': 'BONK', 'decimals': 5},
      },
    );
    await registerService();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ActivityListItem(activity: swapRow())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActivityListItem(
            activity: swapRow(id: 'a2', outMint: otherMint),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('SOL → BONK'), findsOneWidget);
  });

  test('a leg DAS cannot resolve reports no rebuild', () async {
    // The callers turn a `true` straight into `setState(() {})`. A mint DAS
    // can't index is negative-cached for `failureTtl`, so reporting the lookup
    // as resolved would spend a rebuild — on init and on every recycle inside
    // that window — re-rendering the exact same truncated mint.
    when(() => das.getAssetRaw(unindexedMint)).thenThrow(Exception('no such'));
    await registerService();

    expect(await resolveActivityTokenMetadata(swapRow()), isFalse);
  });

  test('a leg that resolves reports a rebuild', () async {
    when(
      () => das.getAssetRaw(unindexedMint),
    ).thenAnswer((_) async => dasResponse());
    await registerService();

    expect(await resolveActivityTokenMetadata(swapRow()), isTrue);
  });

  test('a leg served from the cache still reports a rebuild', () async {
    // A recycled row re-runs the lookup for a mint already resolved by an
    // earlier row. That answers from cache without a request, but the row
    // holding it has never rendered the name, so it still has to be told.
    when(
      () => das.getAssetRaw(unindexedMint),
    ).thenAnswer((_) async => dasResponse());
    await registerService();
    await resolveActivityTokenMetadata(swapRow());

    expect(await resolveActivityTokenMetadata(swapRow(id: 'a2')), isTrue);
    verify(() => das.getAssetRaw(unindexedMint)).called(1);
  });

  testWidgets('the detail preview labels an unindexed leg', (tester) async {
    // The preview passed the wire `symbol` straight to the fallback tile, so a
    // token with no symbol rendered as an empty square with an amount under it.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ActivityPreview(activity: swapRow())),
      ),
    );

    expect(find.text('Unind'), findsOneWidget);
  });
}
