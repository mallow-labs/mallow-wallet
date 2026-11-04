import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/simulation_review.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/simulation_review_sheet.dart';
import 'package:mallow_wallet/shared/widgets/transaction_expiry.dart';

SimulationReview _review() => SimulationReview(
  payloadDigest: 'digest',
  origin: 'https://site.example',
  walletId: 'wallet',
  address: '11111111111111111111111111111111',
  chain: 'solana:mainnet',
  simulatedAt: DateTime.now().toUtc(),
  execution: SimulationExecution.succeeded,
  coverage: SimulationCoverage.complete,
  feeLamports: 5000,
);

void main() {
  late ValueNotifier<TransactionExpiry> state;
  late int approved;
  late int rejected;

  setUp(() {
    state = ValueNotifier(const ExpiryChecking());
    approved = 0;
    rejected = 0;
  });

  Future<void> pump(
    WidgetTester tester, {
    String? slowSigner,
    bool siteSubmits = true,
    bool pending = false,
  }) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final expiry = TransactionExpiryView(
      state: state,
      origin: 'site.example',
      slowSigner: slowSigner,
      siteSubmits: siteSubmits,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: pending
                ? SimulationPendingSheet(
                    origin: 'https://site.example',
                    address: '11111111111111111111111111111111',
                    chain: 'solana:mainnet',
                    onReject: () => rejected++,
                    onApprove: () => approved++,
                    expiry: expiry,
                  )
                : SimulationReviewSheet(
                    review: _review(),
                    onReject: () => rejected++,
                    onApprove: () => approved++,
                    expiry: expiry,
                  ),
          ),
        ),
      ),
    );
    // The placeholder's shimmer never settles.
    pending ? await tester.pump() : await tester.pumpAndSettle();
  }

  String expires(WidgetTester tester) {
    final row = find.byKey(const Key('review-expires'));
    return tester
        .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
        .last
        .data!;
  }

  testWidgets('a countdown is a quiet row until the last ten seconds', (
    tester,
  ) async {
    await pump(tester);
    expect(expires(tester), 'Checking…');

    state.value = const ExpiryCountdown(Duration(milliseconds: 26400));
    await tester.pump();
    expect(expires(tester), 'in ~26 s');
    expect(find.byKey(const Key('review-expiry-notice')), findsNothing);

    state.value = const ExpiryCountdown(Duration(seconds: 8));
    await tester.pump();
    expect(expires(tester), 'in ~8 s');
    expect(find.text('Expires in about 8 seconds'), findsOneWidget);
    expect(
      find.text(
        'After that the network rejects it, and site.example has to create a new one.',
      ),
      findsOneWidget,
    );

    state.value = const ExpiryCountdown(Duration(milliseconds: 400));
    await tester.pump();
    expect(expires(tester), 'Expiring…');
  });

  testWidgets('once expired, Approve gives way to Close', (tester) async {
    await pump(tester);
    state.value = const ExpiryPassed();
    await tester.pump();

    expect(expires(tester), 'Expired');
    expect(find.text('This transaction expired'), findsOneWidget);
    expect(find.byKey(const Key('approve-signing')), findsNothing);
    await tester.tap(find.byKey(const Key('reject-signing')));
    expect(rejected, 1);
    expect(approved, 0);
  });

  testWidgets('a hardware signer is warned for the whole countdown', (
    tester,
  ) async {
    await pump(tester, slowSigner: 'Ledger');
    state.value = const ExpiryCountdown(Duration(seconds: 24));
    await tester.pump();
    expect(
      find.text('About 24 seconds left to sign on your Ledger'),
      findsOneWidget,
    );
  });

  testWidgets('a durable nonce says the site can submit it any time', (
    tester,
  ) async {
    await pump(tester);
    state.value = const ExpiryNever(
      reviewRemaining: Duration(minutes: 1, seconds: 48),
    );
    await tester.pump();
    expect(expires(tester), 'Never (durable nonce)');
    expect(find.text('in 1:48'), findsOneWidget);
    expect(find.text("This transaction doesn't expire"), findsOneWidget);
  });

  testWidgets('a durable nonce the wallet sends itself needs no card', (
    tester,
  ) async {
    await pump(tester, siteSubmits: false);
    state.value = const ExpiryNever();
    await tester.pump();
    expect(find.byKey(const Key('review-expiry-notice')), findsNothing);
    expect(find.byKey(const Key('review-closes')), findsNothing);
  });

  testWidgets('an unmeasured expiry gives its upper bound', (tester) async {
    await pump(tester);
    state.value = const ExpiryUnmeasured(Duration(milliseconds: 29200));
    await tester.pump();
    expect(expires(tester), 'Within about 29 s');
  });

  testWidgets('the placeholder sheet cannot be approved once expired', (
    tester,
  ) async {
    await pump(tester, pending: true);
    expect(find.byKey(const Key('approve-signing-early')), findsOneWidget);
    state.value = const ExpiryPassed();
    await tester.pump();
    expect(find.byKey(const Key('approve-signing-early')), findsNothing);
    expect(find.text('This transaction expired'), findsOneWidget);
  });
}
