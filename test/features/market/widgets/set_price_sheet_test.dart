import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/market/models/market_price.dart';
import 'package:mallow_wallet/features/market/widgets/set_price_sheet.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mocktail/mocktail.dart';

/// Fake client — [TokenPriceService] only hits the network in `start()`, which
/// the sheet never invokes, so `priceOf` stays null and the USD suffix is
/// suppressed (irrelevant to the validation behavior under test).
class _FakeMallowApiClient extends Fake implements MallowApiClient {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

/// A SYOP listing's on-chain price is 0, so before this was fixed a mobile
/// "collect" silently paid the artist nothing. This sheet exists so the
/// buyer *names* the amount — it is deliberately NOT a floor.
///
/// Webapp parity (`BuyEditionModal.onBuyClick`) is the spec: the only refusal is
/// a **missing** price. An entered `0` is allowed and settles at 0, because a
/// SYOP seller chose to name no minimum. These tests pin both halves — that a
/// named amount reaches the tx as the correct atomic value, and that no
/// minimum-price gate creeps back in.
void main() {
  setUpAll(() {
    if (!sl.isRegistered<TokenPriceService>()) {
      sl.registerLazySingleton<TokenPriceService>(
        () => TokenPriceService(_FakeMallowApiClient()),
      );
    }
  });

  late _MockTokenBalanceBloc balanceBloc;

  /// Active-signer balances the sheet reads. [sol] is in whole SOL.
  TokenBalanceState solBalance(double sol) => TokenBalanceState.loaded(
    tokens: [
      TokenBalance(
        mint: solMint,
        symbol: 'SOL',
        name: 'Solana',
        decimals: 9,
        rawBalance: (sol * 1000000000).round(),
        uiBalance: sol,
        isNative: true,
      ),
    ],
    totalUsdValue: 0,
  );

  /// SOL for fees plus an SPL position, for the non-native listing case. The
  /// affordability gate reads the *listing currency*, so a USDC-priced SYOP
  /// buy is refused outright when the wallet holds only SOL.
  TokenBalanceState solAndUsdcBalance({double sol = 10, double usdc = 100}) =>
      TokenBalanceState.loaded(
        tokens: [
          TokenBalance(
            mint: solMint,
            symbol: 'SOL',
            name: 'Solana',
            decimals: 9,
            rawBalance: (sol * 1000000000).round(),
            uiBalance: sol,
            isNative: true,
          ),
          TokenBalance(
            mint: usdcMint,
            symbol: 'USDC',
            name: 'USD Coin',
            decimals: 6,
            rawBalance: (usdc * 1000000).round(),
            uiBalance: usdc,
          ),
        ],
        totalUsdValue: 0,
      );

  final submitted = <MarketPrice>[];

  setUp(() {
    balanceBloc = _MockTokenBalanceBloc();
    when(() => balanceBloc.state).thenReturn(solBalance(10));
    submitted.clear();
  });

  Widget buildSheet({String? currencyMint = solMint}) => MaterialApp(
    home: Scaffold(
      body: SetPriceSheet(
        artworkTitle: 'Amazing NFT',
        mintAccount: 'mint',
        currencyMint: currencyMint,
        tokenBalanceBloc: balanceBloc,
        onNext: submitted.add,
      ),
    ),
  );

  VoidCallback? nextOnPressed(WidgetTester tester) =>
      tester.widget<MallowButton>(find.byType(MallowButton)).onPressed;

  testWidgets('an empty price cannot be submitted — the only SYOP refusal', (
    tester,
  ) async {
    await tester.pumpWidget(buildSheet());
    await tester.pump();

    expect(nextOnPressed(tester), isNull);
    // Keyboard "done" bypasses the CTA's enabled state, so it must be refused
    // independently.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, isEmpty);
  });

  testWidgets('an explicit 0 IS submittable — webapp parity, not a bug', (
    tester,
  ) async {
    // The webapp's only SYOP check is `buyerUIPrice == null`; an entered 0
    // passes and buys at 0. A SYOP seller named no floor, so 0 is a legitimate
    // outcome. Blocking it here would make mobile refuse a purchase the webapp
    // completes.
    await tester.pumpWidget(buildSheet());
    await tester.enterText(find.byType(TextField), '0');
    await tester.pump();

    expect(nextOnPressed(tester), isNotNull);
    nextOnPressed(tester)!();
    await tester.pump();
    expect(submitted.single.rawAmount, 0);
    expect(submitted.single.currencyMint, solMint);
  });

  testWidgets('clearing an entered price re-disables the CTA', (tester) async {
    await tester.pumpWidget(buildSheet());
    await tester.enterText(find.byType(TextField), '1');
    await tester.pump();
    expect(nextOnPressed(tester), isNotNull);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(nextOnPressed(tester), isNull);
  });

  testWidgets('reports the entered price as an atomic amount in the listing '
      'currency', (tester) async {
    await tester.pumpWidget(buildSheet());
    await tester.enterText(find.byType(TextField), '2.5');
    await tester.pump();
    nextOnPressed(tester)!();
    await tester.pump();

    // 2.5 SOL → lamports. This is the value that becomes the wire `maxPrice`,
    // so a decimals mistake here underpays or overpays the artist.
    expect(submitted.single.rawAmount, 2500000000);
    expect(submitted.single.currencyMint, solMint);
  });

  testWidgets('a non-SOL listing converts with that token decimals', (
    tester,
  ) async {
    when(() => balanceBloc.state).thenReturn(solAndUsdcBalance());
    await tester.pumpWidget(buildSheet(currencyMint: usdcMint));
    await tester.enterText(find.byType(TextField), '25');
    await tester.pump();
    nextOnPressed(tester)!();
    await tester.pump();

    // USDC is 6 decimals, not 9 — the sheet must resolve them from the mint.
    expect(submitted.single.rawAmount, 25000000);
    expect(submitted.single.currencyMint, usdcMint);
  });

  testWidgets('a tiny price below the seller-side listing minimum is still '
      'allowed — no buyer-side floor', (tester) async {
    // SOL's `minListingPrice` is 0.01 SOL, but that governs what a SELLER may
    // list for. Applying it to a buyer-named amount would block a purchase the
    // webapp completes, so it must not be enforced here.
    await tester.pumpWidget(buildSheet());
    await tester.enterText(find.byType(TextField), '0.001');
    await tester.pump();

    expect(find.textContaining('Minimum price is'), findsNothing);
    expect(nextOnPressed(tester), isNotNull);
    nextOnPressed(tester)!();
    await tester.pump();
    expect(submitted.single.rawAmount, 1000000);
  });

  testWidgets('a price the wallet cannot cover is refused', (tester) async {
    when(() => balanceBloc.state).thenReturn(solBalance(2));
    await tester.pumpWidget(buildSheet());
    await tester.enterText(find.byType(TextField), '3');
    await tester.pump();

    expect(find.text('Insufficient funds'), findsOneWidget);
    expect(nextOnPressed(tester), isNull);
    // And not via the keyboard either.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, isEmpty);
  });

  testWidgets('no false-disable before balances load', (tester) async {
    // Gating on an unknown balance would block a purchase the wallet can
    // actually afford.
    when(() => balanceBloc.state).thenReturn(const TokenBalanceState.loading());
    await tester.pumpWidget(buildSheet());
    await tester.enterText(find.byType(TextField), '1');
    await tester.pump();

    expect(find.textContaining('Balance:', findRichText: true), findsNothing);
    expect(nextOnPressed(tester), isNotNull);
  });
}
