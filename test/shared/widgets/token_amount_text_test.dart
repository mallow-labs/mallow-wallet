import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/core/utils/price_formatter.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/shared/widgets/loading_indicator.dart';
import 'package:mallow_wallet/shared/widgets/token_amount_text.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/no_verified_list_database.dart';

class _MockDasApiService extends Mock implements DasApiService {}

// The three states exist because both of the old degradations were dishonest:
// a currency the registry didn't key either vanished from the row entirely
// (no `chain` passed) or was rescaled into the chain's native token — a
// 5,000 WEN sale rendered as "0.5 SOL". A shimmer says "not yet", a figure
// says "here it is", and "Unknown token" says "we don't know" — and the buy
// CTA is gated on the same three states, so the button can never be live over
// a price the user was never shown.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wenMint = 'WENWENvqqNya429ubCdR81ZmD69brwQaaBYY6p3LCpk';

  late _MockDasApiService das;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    clearResolvedTokens();
    das = _MockDasApiService();
    if (sl.isRegistered<TokenMetadataService>()) {
      sl.unregister<TokenMetadataService>();
    }
    sl.registerSingleton<TokenMetadataService>(
      TokenMetadataService(
        das,
        await PreferencesService.create(),
        NoVerifiedListDatabase(),
      ),
    );
  });

  tearDown(() {
    clearResolvedTokens();
    if (sl.isRegistered<TokenMetadataService>()) {
      sl.unregister<TokenMetadataService>();
    }
  });

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );

  testWidgets('a registry currency renders on the first frame, no shimmer', (
    tester,
  ) async {
    await pump(
      tester,
      const TokenAmountText(rawAmount: 1000000000, currencyMint: solMint),
    );

    // No pump() beyond the initial build: a registered token must cost exactly
    // what it cost before this widget existed.
    expect(find.text('1 SOL'), findsOneWidget);
    expect(find.byType(ShimmerBox), findsNothing);
    verifyNever(() => das.getAssetRaw(any()));
  });

  testWidgets('an unregistered mint shimmers while the lookup is in flight', (
    tester,
  ) async {
    final gate = Completer<Map<String, dynamic>>();
    when(() => das.getAssetRaw(wenMint)).thenAnswer((_) => gate.future);

    await pump(
      tester,
      const TokenAmountText(rawAmount: 12345000, currencyMint: wenMint),
    );
    await tester.pump();

    expect(find.byType(ShimmerBox), findsOneWidget);
    expect(find.text(kUnknownTokenLabel), findsNothing);

    gate.complete({
      'content': {
        'metadata': {'symbol': 'WEN'},
      },
      'token_info': {'symbol': 'WEN', 'decimals': 5},
    });
    await tester.pump();
    await tester.pump();

    // Full scaled amount at the token's real decimals, under its real ticker.
    expect(find.text('123.45 WEN'), findsOneWidget);
    expect(find.byType(ShimmerBox), findsNothing);
  });

  testWidgets('a failed lookup degrades to "Unknown token", not a figure', (
    tester,
  ) async {
    when(() => das.getAssetRaw(wenMint)).thenThrow(Exception('rpc down'));

    await pump(
      tester,
      const TokenAmountText(rawAmount: 12345000, currencyMint: wenMint),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text(kUnknownTokenLabel), findsOneWidget);
    // Specifically NOT a number: the whole point is that an unscalable amount
    // is never rendered as though it were scaled.
    expect(find.textContaining('123'), findsNothing);
    expect(find.textContaining('SOL'), findsNothing);
  });

  testWidgets('an unkeyed non-Solana currency reads unknown, no lookup', (
    tester,
  ) async {
    await pump(
      tester,
      const TokenAmountText(
        rawAmount: 1500000,
        // An objkt FA contract the registry doesn't key. DAS can't answer for
        // it at all, and it is not tez — so the row says so rather than
        // scaling 1500000 by tez's decimals and labelling it XTZ.
        currencyMint: 'KT1MsktBVQwGkUE94Uh4iSJdSCTHtBoNrzXG',
        chain: 'tezos',
      ),
    );

    expect(find.text(kUnknownTokenLabel), findsOneWidget);
    expect(find.textContaining('1.5'), findsNothing);
    verifyNever(() => das.getAssetRaw(any()));
  });

  testWidgets('a native Tezos amount still renders in tez', (tester) async {
    await pump(
      tester,
      const TokenAmountText(
        rawAmount: 1500000,
        currencyMint: null,
        chain: 'tezos',
      ),
    );

    expect(find.text('1.5 XTZ'), findsOneWidget);
    verifyNever(() => das.getAssetRaw(any()));
  });
}
