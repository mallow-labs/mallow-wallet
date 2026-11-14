import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/models/simulation_review.dart';
import 'package:mallow_wallet/shared/widgets/hold_to_approve_button.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/signing_copy.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/features/browser/data/browser_repository.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/browser_signing_service.dart';
import 'package:mallow_wallet/features/browser/services/browser_transaction_tracker.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_adapter.dart';
import 'package:mallow_wallet/features/browser/services/solana_slot_time.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_send_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

class _Adapter extends Mock implements SolanaDappAdapter {}

class _Gate extends Mock implements TransactionAuthGate {}

class _Prices extends Mock implements TokenPriceService {}

class _Storage extends Mock implements SecureWalletStorage {}

const _address = '11111111111111111111111111111111';

/// A one-signer transfer, signed when [signed].
SignedTx _tx({required bool signed}) {
  final signer = Ed25519HDPublicKey(List.filled(32, 1));
  final other = Ed25519HDPublicKey(List.filled(32, 2));
  final system = Ed25519HDPublicKey.fromBase58(solanaSystemProgram);
  return SignedTx.fromBytes([
    1,
    ...List.filled(64, signed ? 7 : 0),
    1,
    0,
    1,
    3,
    ...signer.bytes,
    ...other.bytes,
    ...system.bytes,
    ...other.bytes,
    1,
    2,
    2,
    0,
    1,
    0,
  ]);
}

Uint8List _wire(SignedTx tx) => Uint8List.fromList(tx.toByteArray().toList());

void main() {
  late _Adapter adapter;
  late _Gate gate;
  late BrowserTransactionTracker tracker;
  late Completer<void> cancelled;
  late BuildContext host;
  final signed = _wire(_tx(signed: true));
  final id = _tx(signed: true).id;

  setUpAll(() {
    registerFallbackValue(FlowKey.solana(AppFlow.browserTransaction));
    registerFallbackValue(PreparedSolanaTransaction(Uint8List(0), _review()));
    registerFallbackValue(Uint8List(0));
  });

  DappSigningRequest request() => DappSigningRequest(
    id: '1',
    method: 'signAndSendTransaction',
    context: DappFrameContext(
      tabId: 't',
      generation: 1,
      origin: Uri.parse('https://site.example'),
      isMainFrame: true,
      isActive: true,
    ),
    wallet: const DappWallet(id: 'w', address: _address, canSign: true),
    chain: 'solana:mainnet',
    payloads: [_wire(_tx(signed: false))],
    payloadDigest: 'digest',
    cancelled: cancelled.future,
    options: const {},
    ensureActive: () {
      if (cancelled.isCompleted) {
        throw const DappException(4001, 'Request cancelled.');
      }
    },
  );

  /// Runs the request up to its review. Fixtures are built here, inside the
  /// test's fake async zone, so their futures resolve under `pump`.
  Future<Future<Object?>> start(
    WidgetTester tester, {
    Future<PreparedSolanaTransaction> Function()? prepare,
    DappRpc? rpc,
  }) async {
    cancelled = Completer<void>();
    adapter = _Adapter();
    gate = _Gate();
    tracker = BrowserTransactionTracker(interval: const Duration(seconds: 1));
    addTearDown(tracker.dispose);
    final prices = _Prices();
    when(() => prices.priceOf(any())).thenReturn(null);
    when(() => adapter.tracker).thenReturn(tracker);
    if (rpc != null) when(() => adapter.rpc).thenReturn(rpc);
    when(
      () => adapter.prepareTransaction(
        transaction: any(named: 'transaction'),
        walletId: any(named: 'walletId'),
        address: any(named: 'address'),
        origin: any(named: 'origin'),
        chain: any(named: 'chain'),
      ),
    ).thenAnswer(
      (_) =>
          prepare?.call() ??
          Future.value(PreparedSolanaTransaction(signed, _review())),
    );
    when(
      () => gate.authorize(
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
      ),
    ).thenAnswer((_) async => TransactionAuthOutcome.allowed);
    when(
      () => adapter.signPrepared(
        any(),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer((_) async => signed);
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
      slotTime: SolanaSlotTimeSource(fetch: () async => 200),
    );
    final result = service
        .execute(host, request())
        .then<Object?>((v) => v, onError: (Object e) => e);
    await _settle(tester);
    // A test's own chain may have expired the review, replacing the button.
    // While the simulation is pending the same action is a press-and-hold.
    if (rpc == null) {
      expect(
        find.text('Sign and send').evaluate().length +
            find
                .text('Hold to sign and send without the review')
                .evaluate()
                .length,
        1,
      );
    }
    return result;
  }

  Future<void> approve(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('approve-signing')));
    await tester.pump();
    await tester.pump(MallowTheme.sheetDuration);
    await tester.pump(MallowTheme.sheetDuration);
  }

  testWidgets('closes after signing while broadcast is still pending', (
    tester,
  ) async {
    final signing = Completer<Uint8List>();
    final broadcast = Completer<String>();
    final lookup = Completer<Object?>();
    final result = await start(tester);
    when(
      () => adapter.signPrepared(
        any(),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer((_) => signing.future);
    when(
      () => adapter.sendSigned(any(), any(), options: any(named: 'options')),
    ).thenAnswer((_) {
      tracker.start(
        signature: id,
        chain: 'solana:mainnet',
        lookup: (_, _) => lookup.future,
      );
      return broadcast.future;
    });
    await approve(tester);
    expect(find.byType(BrowserSendSheet), findsOneWidget);
    expect(find.text(kLocalSigningLabel), findsOneWidget);
    verifyNever(
      () => adapter.sendSigned(any(), any(), options: any(named: 'options')),
    );

    signing.complete(signed);
    await _settle(tester);
    expect(find.byType(BrowserSendSheet), findsNothing);
    expect(find.text(kConfirmingLabel), findsNothing);
    expect(tracker.isPresented(tracker.records.single), isFalse);

    broadcast.complete(id);
    await tester.pump();
    expect(await result, {'signature': id});
    lookup.complete({
      'value': [
        {'confirmationStatus': 'confirmed', 'err': null, 'slot': 4},
      ],
    });
    await tester.pump(const Duration(seconds: 1));
    expect(tracker.records.single.status, BrowserTransactionStatus.confirmed);
    expect(find.text('Transaction confirmed'), findsNothing);
  });

  testWidgets('submission failures return to the website after dismissal', (
    tester,
  ) async {
    final broadcast = Completer<String>();
    final result = await start(tester);
    when(
      () => adapter.sendSigned(any(), any(), options: any(named: 'options')),
    ).thenAnswer((_) => broadcast.future);
    await approve(tester);
    expect(find.byType(BrowserSendSheet), findsNothing);

    broadcast.completeError(
      const DappException(-32000, 'Submission rejected.'),
    );
    await tester.pump();
    expect(
      await result,
      isA<DappException>().having(
        (e) => e.message,
        'message',
        'Submission rejected.',
      ),
    );
    expect(find.byType(BrowserSendSheet), findsNothing);
  });

  testWidgets('cancelling step-up auth closes the sheet and rejects', (
    tester,
  ) async {
    final result = await start(tester);
    when(
      () => gate.authorize(
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
      ),
    ).thenAnswer((_) async => TransactionAuthOutcome.cancelled);
    await approve(tester);
    await _settle(tester);

    final error = await result;
    expect(error, isA<DappException>());
    expect((error! as DappException).code, 4001);
    expect(find.byType(BrowserSendSheet), findsNothing);
    verifyNever(
      () => adapter.sendSigned(any(), any(), options: any(named: 'options')),
    );
  });

  testWidgets('a signing failure says nothing was sent', (tester) async {
    final result = await start(tester);
    when(
      () => adapter.signPrepared(
        any(),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenThrow(
      const DappException(4001, 'Review expired. Request a new transaction.'),
    );
    await approve(tester);

    expect(await result, isA<DappException>());
    expect(find.text('Transaction not sent'), findsOneWidget);
    expect(
      find.text('Review expired. Request a new transaction.'),
      findsOneWidget,
    );
    verifyNever(
      () => adapter.sendSigned(any(), any(), options: any(named: 'options')),
    );
  });

  testWidgets('rejecting the review closes it and broadcasts nothing', (
    tester,
  ) async {
    final result = await start(tester);
    await tester.tap(find.byKey(const Key('reject-signing')));
    await _settle(tester);
    expect((await result)! as DappException, isA<DappException>());
    expect(find.byType(BrowserSendSheet), findsNothing);
    verifyNever(
      () => gate.authorize(
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
      ),
    );
  });

  testWidgets('closing an expired review tells the site it expired', (
    tester,
  ) async {
    final result = await start(
      tester,
      // The blockhash is in no recent list and no longer valid.
      rpc: (chain, method, params) async => switch (method) {
        'getAccountInfo' => {
          'value': {
            'data': [base64Encode(Uint8List(8)), 'base64'],
          },
        },
        'isBlockhashValid' => {'value': false},
        _ => throw StateError(method),
      },
    );
    await _settle(tester);
    expect(find.text('This transaction expired'), findsOneWidget);
    expect(find.byKey(const Key('approve-signing')), findsNothing);

    await tester.tap(find.byKey(const Key('reject-signing')));
    await _settle(tester);
    final error = (await result)! as DappException;
    expect(error.message, 'Transaction expired. Request a new one.');
    verifyNever(
      () => adapter.signPrepared(
        any(),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    );
  });

  group('while the simulation runs', () {
    late Completer<PreparedSolanaTransaction> simulation;
    Future<Future<Object?>> simulating(WidgetTester tester) {
      simulation = Completer();
      return start(tester, prepare: () => simulation.future);
    }

    testWidgets('the sheet is up, and fills in when the review lands', (
      tester,
    ) async {
      final result = await simulating(tester);
      expect(find.byKey(const Key('review-pending')), findsOneWidget);
      expect(find.byKey(const Key('approve-signing-early')), findsOneWidget);
      expect(find.byKey(const Key('approve-signing')), findsNothing);

      simulation.complete(PreparedSolanaTransaction(signed, _review()));
      await _settle(tester);
      expect(find.byKey(const Key('review-pending')), findsNothing);
      when(
        () => adapter.sendSigned(any(), any(), options: any(named: 'options')),
      ).thenAnswer((_) async => id);
      await approve(tester);
      expect(await result, {'signature': id});
      // What is signed is the reviewed transaction.
      verify(
        () => adapter.signPrepared(
          any(
            that: isA<PreparedSolanaTransaction>().having(
              (p) => p.review.execution,
              'execution',
              SimulationExecution.succeeded,
            ),
          ),
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      ).called(1);
    });

    testWidgets('a tap does not approve before the result: it takes the '
        'hold, and Reject is the primary action', (tester) async {
      final result = await simulating(tester);
      expect(find.byType(HoldToApproveButton), findsOneWidget);

      await tester.tap(find.byKey(const Key('approve-signing-early')));
      await _settle(tester);
      // Released at once, and long after the arm delay: still nothing.
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byKey(const Key('approve-signing-early')));
      await _settle(tester);

      expect(find.byKey(const Key('review-pending')), findsOneWidget);
      verifyNever(
        () => adapter.describeTransaction(
          transaction: any(named: 'transaction'),
          walletId: any(named: 'walletId'),
          address: any(named: 'address'),
          origin: any(named: 'origin'),
          chain: any(named: 'chain'),
        ),
      );
      verifyNever(
        () => adapter.signPrepared(
          any(),
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      );
      await tester.tap(find.byKey(const Key('reject-signing')));
      await _settle(tester);
      expect(await result, isA<DappException>());
    });

    testWidgets('approving early signs the transaction as received', (
      tester,
    ) async {
      final result = await simulating(tester);
      final unsimulated = PreparedSolanaTransaction(
        signed,
        SimulationReview(
          payloadDigest: 'digest',
          origin: 'https://site.example',
          walletId: 'w',
          address: _address,
          chain: 'solana:mainnet',
          simulatedAt: DateTime.now().toUtc(),
          execution: SimulationExecution.unavailable,
          coverage: SimulationCoverage.unavailable,
        ),
      );
      when(
        () => adapter.describeTransaction(
          transaction: any(named: 'transaction'),
          walletId: any(named: 'walletId'),
          address: any(named: 'address'),
          origin: any(named: 'origin'),
          chain: any(named: 'chain'),
        ),
      ).thenReturn(unsimulated);
      when(
        () => adapter.sendSigned(any(), any(), options: any(named: 'options')),
      ).thenAnswer((_) async => id);
      when(
        () => gate.authorize(
          usdValue: any(named: 'usdValue'),
          flow: any(named: 'flow'),
        ),
      ).thenAnswer((_) async => TransactionAuthOutcome.allowed);

      final early = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('approve-signing-early'))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1300));
      await early.up();
      await _settle(tester);
      expect(await result, {'signature': id});
      verify(
        () => adapter.signPrepared(
          unsimulated,
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      ).called(1);
      // Its effects were never seen: step-up auth gets no value, which it
      // counts as over any threshold.
      verify(
        () => gate.authorize(usdValue: null, flow: any(named: 'flow')),
      ).called(1);
      expect(find.byType(BrowserSendSheet), findsNothing);
    });

    testWidgets('a tap aimed at the early Approve as an unchecked review '
        'lands approves nothing; the review takes the hold', (tester) async {
      final result = await simulating(tester);
      simulation.complete(
        PreparedSolanaTransaction(
          signed,
          SimulationReview(
            payloadDigest: 'digest',
            origin: 'https://site.example',
            walletId: 'w',
            address: _address,
            chain: 'solana:mainnet',
            simulatedAt: DateTime.now().toUtc(),
            execution: SimulationExecution.unavailable,
            coverage: SimulationCoverage.unavailable,
            error: 'Simulation is unavailable.',
          ),
        ),
      );
      // The answer is in, but no frame has replaced the placeholder yet.
      await tester.idle();
      expect(find.byKey(const Key('approve-signing-early')), findsOneWidget);
      final early = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('approve-signing-early'))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1300));
      await early.up();
      await _settle(tester);

      expect(find.byKey(const Key('approve-signing-early')), findsNothing);
      expect(find.text('Review carefully'), findsOneWidget);
      expect(find.byType(HoldToApproveButton), findsOneWidget);
      verifyNever(
        () => adapter.signPrepared(
          any(),
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      );
      await tester.tap(find.byKey(const Key('reject-signing')));
      await _settle(tester);
      expect(await result, isA<DappException>());
    });

    testWidgets('a failure after an early approval lands on the sheet', (
      tester,
    ) async {
      final result = await simulating(tester);
      when(
        () => adapter.describeTransaction(
          transaction: any(named: 'transaction'),
          walletId: any(named: 'walletId'),
          address: any(named: 'address'),
          origin: any(named: 'origin'),
          chain: any(named: 'chain'),
        ),
      ).thenThrow(const DappException(-32602, 'Invalid transaction.'));
      final early = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('approve-signing-early'))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1300));
      await early.up();
      await _settle(tester);
      expect(await result, isA<DappException>());
      expect(find.text('Transaction not sent'), findsOneWidget);
      expect(find.text('Invalid transaction.'), findsOneWidget);
    });

    testWidgets('rejecting answers the website at once', (tester) async {
      final result = await simulating(tester);
      await tester.tap(find.byKey(const Key('reject-signing')));
      await _settle(tester);
      expect(
        await result,
        isA<DappException>()
            .having((e) => e.code, 'code', 4001)
            .having((e) => e.message, 'message', 'Transaction rejected.'),
      );
      expect(find.byType(BrowserSendSheet), findsNothing);
      // A simulation that lands afterwards opens nothing.
      simulation.complete(PreparedSolanaTransaction(signed, _review()));
      await _settle(tester);
      expect(find.byType(BrowserSendSheet), findsNothing);
      verifyNever(
        () => adapter.signPrepared(
          any(),
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      );
    });

    testWidgets('a review that cannot be prepared says why', (tester) async {
      final result = await simulating(tester);
      simulation.completeError(
        const DappException(-32602, 'Invalid transaction.'),
      );
      await _settle(tester);
      expect(
        await result,
        isA<DappException>().having((e) => e.code, 'code', -32602),
      );
      expect(find.text('Transaction not reviewed'), findsOneWidget);
      expect(find.text('Invalid transaction.'), findsOneWidget);
      expect(find.byKey(const Key('approve-signing')), findsNothing);

      await tester.tap(find.byKey(const Key('reject-signing')));
      await _settle(tester);
      expect(find.byType(BrowserSendSheet), findsNothing);
    });

    testWidgets('a cancelled request closes the sheet', (tester) async {
      final result = await simulating(tester);
      cancelled.complete();
      await _settle(tester);
      expect(
        await result,
        isA<DappException>().having(
          (e) => e.message,
          'message',
          'Request cancelled.',
        ),
      );
      expect(find.byType(BrowserSendSheet), findsNothing);
    });
  });
}

/// Fixed pumps rather than `pumpAndSettle`: the review's placeholders and
/// the striped panel animate for as long as they are up. Long enough for the
/// sheet to land and for Approve to arm (`ReviewDecisionBar.armDelay`).
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 5; i++) {
    await tester.pump(MallowTheme.sheetDuration);
  }
}

SimulationReview _review() => SimulationReview(
  payloadDigest: 'digest',
  origin: 'https://site.example',
  walletId: 'w',
  address: _address,
  chain: 'solana:mainnet',
  simulatedAt: DateTime.now().toUtc(),
  execution: SimulationExecution.succeeded,
  coverage: SimulationCoverage.complete,
  feeLamports: 5000,
);
