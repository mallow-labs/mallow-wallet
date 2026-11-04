import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/models/simulation_review.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/features/browser/data/browser_repository.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/browser_signing_service.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_adapter.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/hold_to_approve_button.dart';
import 'package:mallow_wallet/shared/widgets/simulation_review_sheet.dart';

class _Adapter extends Mock implements SolanaDappAdapter {}

class _Gate extends Mock implements TransactionAuthGate {}

class _Prices extends Mock implements TokenPriceService {}

class _Storage extends Mock implements SecureWalletStorage {}

const _address = '11111111111111111111111111111111';

void main() {
  late _Adapter adapter;
  late _Gate gate;
  late Completer<void> cancelled;
  late BuildContext host;

  setUpAll(() {
    registerFallbackValue(FlowKey.solana(AppFlow.browserTransaction));
    registerFallbackValue(PreparedSolanaTransaction(Uint8List(0), _review()));
    registerFallbackValue(Uint8List(0));
  });

  DappSigningRequest request(String method, {int payloads = 1}) =>
      DappSigningRequest(
        id: '1',
        method: method,
        context: DappFrameContext(
          tabId: 't',
          generation: 1,
          origin: Uri.parse('https://site.example'),
          isMainFrame: true,
          isActive: true,
        ),
        wallet: const DappWallet(id: 'w', address: _address, canSign: false),
        chain: 'solana:mainnet',
        payloads: [
          for (var i = 0; i < payloads; i++) Uint8List.fromList([i]),
        ],
        payloadDigest: 'digest',
        cancelled: cancelled.future,
        options: const {},
        ensureActive: () {
          if (cancelled.isCompleted) {
            throw const DappException(4001, 'Request cancelled.');
          }
        },
      );

  Future<Future<Object?>> start(
    WidgetTester tester,
    String method, {
    int payloads = 1,
    SimulationExecution execution = SimulationExecution.succeeded,
  }) async {
    cancelled = Completer<void>();
    adapter = _Adapter();
    gate = _Gate();
    final prices = _Prices();
    when(() => prices.priceOf(any())).thenReturn(null);
    when(
      () => adapter.prepareTransaction(
        transaction: any(named: 'transaction'),
        walletId: any(named: 'walletId'),
        address: any(named: 'address'),
        origin: any(named: 'origin'),
        chain: any(named: 'chain'),
      ),
    ).thenAnswer(
      (_) async => PreparedSolanaTransaction(Uint8List(1), _review(execution)),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Builder(
          builder: (context) {
            host = context;
            return const Scaffold();
          },
        ),
      ),
    );
    final service = BrowserSigningService(
      adapter: adapter,
      authGate: gate,
      prices: prices,
      session: BrowserSession(BrowserRepository(_Storage())),
    );
    final result = service
        .execute(host, request(method, payloads: payloads))
        .then<Object?>((v) => v, onError: (Object e) => e);
    await _settle(tester);
    return result;
  }

  void verifyNothingSigned() {
    verifyNever(
      () => gate.authorize(
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
      ),
    );
    verifyNever(
      () => adapter.signPrepared(
        any(),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    );
    verifyNever(
      () => adapter.sendSigned(any(), any(), options: any(named: 'options')),
    );
  }

  for (final method in const [
    'signTransaction',
    'signAndSendTransaction',
    'signAllTransactions',
  ]) {
    testWidgets('$method shows a view-only review; closing it rejects', (
      tester,
    ) async {
      final result = await start(tester, method);
      expect(find.byType(SimulationReviewSheet), findsOneWidget);
      expect(find.byKey(const Key('review-view-only')), findsOneWidget);
      expect(find.text('View-only wallet'), findsOneWidget);
      expect(find.byKey(const Key('approve-signing')), findsNothing);
      expect(find.text('Close'), findsOneWidget);
      // The Explorer simulation link stays reachable behind the disclosure.
      expect(find.byKey(const Key('review-program-calls')), findsOneWidget);

      await tester.tap(find.byKey(const Key('reject-signing')));
      await _settle(tester);

      final error = await result as DappException?;
      expect(error, isA<DappException>());
      expect(error!.code, 4200);
      expect(error.message, contains('view-only'));
      expect(find.byType(SimulationReviewSheet), findsNothing);
      verifyNothingSigned();
    });
  }

  testWidgets('a batch is reviewed as a whole', (tester) async {
    final result = await start(tester, 'signAllTransactions', payloads: 3);
    expect(find.byType(SimulationReviewSheet), findsOneWidget);
    expect(find.text('Review 3 transactions'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reject-signing')));
    await _settle(tester);
    expect(await result, isA<DappException>());
    verify(
      () => adapter.prepareTransaction(
        transaction: any(named: 'transaction'),
        walletId: any(named: 'walletId'),
        address: any(named: 'address'),
        origin: any(named: 'origin'),
        chain: any(named: 'chain'),
      ),
    ).called(3);
    verifyNothingSigned();
  });

  testWidgets('a failed simulation offers no hold-to-approve', (tester) async {
    final result = await start(
      tester,
      'signTransaction',
      execution: SimulationExecution.failed,
    );
    expect(find.text('Simulation failed'), findsOneWidget);
    expect(find.byType(HoldToApproveButton), findsNothing);
    expect(find.text('Review carefully'), findsNothing);
    expect(find.text('Review transaction'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reject-signing')));
    await _settle(tester);
    expect(await result, isA<DappException>());
    verifyNothingSigned();
  });

  testWidgets('dismissing the sheet rejects the same way', (tester) async {
    final result = await start(tester, 'signTransaction');
    await tester.tapAt(const Offset(20, 20));
    await _settle(tester);
    final error = await result;
    expect((error! as DappException).code, 4200);
    verifyNothingSigned();
  });

  testWidgets('a message rejects at once, with no sheet', (tester) async {
    final result = await start(tester, 'signMessage');
    expect(find.byType(SimulationReviewSheet), findsNothing);
    final error = await result;
    expect((error! as DappException).code, 4200);
    verifyNever(
      () => adapter.prepareTransaction(
        transaction: any(named: 'transaction'),
        walletId: any(named: 'walletId'),
        address: any(named: 'address'),
        origin: any(named: 'origin'),
        chain: any(named: 'chain'),
      ),
    );
  });
}

/// Fixed pumps rather than `pumpAndSettle`: the review's placeholders
/// animate for as long as they are up.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 3; i++) {
    await tester.pump(MallowTheme.sheetDuration);
  }
}

SimulationReview _review([
  SimulationExecution execution = SimulationExecution.succeeded,
]) => SimulationReview(
  payloadDigest: 'digest',
  origin: 'https://site.example',
  walletId: 'w',
  address: _address,
  chain: 'solana:mainnet',
  simulatedAt: DateTime.now().toUtc(),
  execution: execution,
  coverage: SimulationCoverage.complete,
  feeLamports: 5000,
  error: execution == SimulationExecution.failed ? 'Simulation failed' : null,
);
