import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/usd_estimate.dart';
import 'package:mocktail/mocktail.dart';

class _MockMallowApi extends Mock implements MallowApiClient {}

void main() {
  late _MockMallowApi api;
  late TokenPriceService service;

  setUp(() {
    api = _MockMallowApi();
    service = TokenPriceService(api);
    sl.registerSingleton<TokenPriceService>(service);
  });

  tearDown(() => sl.unregister<TokenPriceService>());

  Future<void> pump(WidgetTester tester, num? rawAmount) {
    return tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: UsdEstimate(rawAmount: rawAmount, mint: solMint),
        ),
      ),
    );
  }

  /// Loads [usdByMint] into the service, then stops its refresh timer so the
  /// test ends with no pending timers.
  Future<void> loadPrices(
    WidgetTester tester,
    Map<String, double> usdByMint,
  ) async {
    when(api.getTokenPrices).thenAnswer(
      (_) async =>
          ApiResponse(result: TokenPricesResponse(usdByMint: usdByMint)),
    );
    service.start();
    await tester.pump();
  }

  Future<void> tearDownService(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    service.dispose();
  }

  testWidgets('shows the grouped estimate once a price lands', (tester) async {
    // 12.5 SOL in lamports.
    await pump(tester, 12500000000);
    expect(find.textContaining(r'$'), findsNothing);

    await loadPrices(tester, {solMint: 150});
    expect(find.text(r'~$1,875.00'), findsOneWidget);

    await tearDownService(tester);
  });

  testWidgets('renders nothing for an empty or zero amount', (tester) async {
    await loadPrices(tester, {solMint: 150});

    await pump(tester, null);
    expect(find.textContaining(r'$'), findsNothing);

    await pump(tester, 0);
    expect(find.textContaining(r'$'), findsNothing);

    await tearDownService(tester);
  });

  testWidgets('renders nothing when the mint has no price', (tester) async {
    await loadPrices(tester, {'otherMint': 2});
    await pump(tester, 12500000000);
    expect(find.textContaining(r'$'), findsNothing);

    await tearDownService(tester);
  });
}
