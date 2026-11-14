import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:solana/solana.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/models/account.dart' show WalletType;
import 'package:mallow_wallet/core/models/simulation_review.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart'
    show LedgerNotConnectedException;
import 'package:mallow_wallet/core/services/signing_copy.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/features/browser/data/browser_repository.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/browser_signing_service.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_adapter.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/hold_to_approve_button.dart';
import 'package:mallow_wallet/shared/widgets/simulation_review_sheet.dart';
import 'package:mallow_wallet/shared/widgets/transaction_pipeline_sheet.dart';

class _Adapter extends Mock implements SolanaDappAdapter {}

class _Gate extends Mock implements TransactionAuthGate {}

class _Prices extends Mock implements TokenPriceService {}

class _Storage extends Mock implements SecureWalletStorage {}

final _signer = Ed25519HDPublicKey(List.filled(32, 1));

/// An unsigned one-signer System call from [_signer]; [n] varies the bytes.
Uint8List _tx(int n) {
  final other = Ed25519HDPublicKey(List.filled(32, 2));
  final system = Ed25519HDPublicKey.fromBase58(solanaSystemProgram);
  return Uint8List.fromList([
    1,
    ...List.filled(64, 0),
    1,
    0,
    1,
    3,
    ..._signer.bytes,
    ...other.bytes,
    ...system.bytes,
    ...List.filled(32, n),
    1,
    2,
    2,
    0,
    1,
    0,
  ]);
}

SimulationReview _review(int n) => SimulationReview(
  payloadDigest: 'digest-$n',
  origin: 'https://site.example',
  walletId: 'w',
  address: _signer.toBase58(),
  chain: 'solana:mainnet',
  simulatedAt: DateTime.now().toUtc(),
  execution: SimulationExecution.succeeded,
  coverage: SimulationCoverage.complete,
  feeLamports: 5000,
  feePayer: _signer.toBase58(),
  explorerUrl: Uri.parse('https://explorer.example/$n'),
  programCalls: [ReviewProgramCall(program: 'Program$n')],
  funds: [
    FundChange(
      asset: const ReviewAsset(
        id: solanaNativeMint,
        symbol: 'SOL',
        decimals: 9,
      ),
      address: _signer.toBase58(),
      rawAmount: BigInt.from(-1000000000),
      evidence: ReviewEvidence.simulatedState,
      isNet: true,
    ),
  ],
);

void main() {
  late _Adapter adapter;
  late _Gate gate;
  late Completer<void> cancelled;
  late BuildContext host;

  setUpAll(() {
    registerFallbackValue(FlowKey.solana(AppFlow.browserTransaction));
    registerFallbackValue(PreparedSolanaTransaction(Uint8List(0), _review(0)));
    registerFallbackValue(Uint8List(0));
  });

  DappSigningRequest request(int count, WalletType? type) => DappSigningRequest(
    id: '1',
    method: 'signAllTransactions',
    context: DappFrameContext(
      tabId: 't',
      generation: 1,
      origin: Uri.parse('https://site.example'),
      isMainFrame: true,
      isActive: true,
    ),
    wallet: DappWallet(
      id: 'w',
      address: _signer.toBase58(),
      canSign: true,
      type: type,
    ),
    chain: 'solana:mainnet',
    payloads: [for (var i = 0; i < count; i++) _tx(i)],
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
    int count, {
    WalletType? type,
  }) async {
    cancelled = Completer<void>();
    adapter = _Adapter();
    gate = _Gate();
    final prices = _Prices();
    when(() => prices.priceOf(any())).thenReturn(null);
    var n = 0;
    when(
      () => adapter.prepareTransaction(
        transaction: any(named: 'transaction'),
        walletId: any(named: 'walletId'),
        address: any(named: 'address'),
        origin: any(named: 'origin'),
        chain: any(named: 'chain'),
      ),
    ).thenAnswer((invocation) async {
      final bytes = invocation.namedArguments[#transaction] as Uint8List;
      return PreparedSolanaTransaction(bytes, _review(++n));
    });
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
        approvedAt: any(named: 'approvedAt'),
      ),
    ).thenAnswer(
      (invocation) async =>
          (invocation.positionalArguments.first as PreparedSolanaTransaction)
              .bytes,
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
        .execute(host, request(count, type))
        .then<Object?>((v) => v, onError: (Object e) => e);
    await _settle(tester);
    return result;
  }

  testWidgets('a batch is one review, one approval and one authorization', (
    tester,
  ) async {
    final result = await start(tester, 3);
    expect(find.byType(SimulationReviewSheet), findsOneWidget);
    expect(find.text('Review 3 transactions'), findsOneWidget);
    expect(find.text('Sign all'), findsOneWidget);
    final review = tester
        .widget<SimulationReviewSheet>(find.byType(SimulationReviewSheet))
        .review;
    // The combined effects: three 1 SOL sends are one 3 SOL send.
    expect(review.funds.single.rawAmount, BigInt.from(-3000000000));
    expect(review.transactions, hasLength(3));

    await tester.tap(find.byKey(const Key('approve-signing')));
    await _settle(tester);

    final value = await result as Map<String, Object?>;
    expect(value['transactions'], hasLength(3));
    expect(find.byType(SimulationReviewSheet), findsNothing);
    verify(
      () => gate.authorize(
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
      ),
    ).called(1);
    final approvedAt = verify(
      () => adapter.signPrepared(
        any(),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
        approvedAt: captureAny(named: 'approvedAt'),
      ),
    ).captured;
    expect(approvedAt, hasLength(3));
    expect(approvedAt.toSet(), hasLength(1), reason: 'one approval time');
    expect(approvedAt.first, isA<DateTime>());
  });

  testWidgets('rejecting the batch signs nothing', (tester) async {
    final result = await start(tester, 2);
    await tester.tap(find.byKey(const Key('reject-signing')));
    await _settle(tester);
    expect((await result as DappException?)?.code, 4001);
    verifyNever(
      () => adapter.signPrepared(
        any(),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
        approvedAt: any(named: 'approvedAt'),
      ),
    );
  });

  testWidgets('a batch over the simulation limit is not simulated; it can be '
      'signed, with a hold and never from the placeholder', (tester) async {
    const count = kMaxSimulatedSolanaBatch + 1;
    final result = await start(tester, count);
    // Nothing to wait for, so nothing to approve ahead of.
    expect(find.byKey(const Key('approve-signing-early')), findsNothing);
    verifyNever(
      () => adapter.describeTransaction(
        transaction: any(named: 'transaction'),
        walletId: any(named: 'walletId'),
        address: any(named: 'address'),
        origin: any(named: 'origin'),
        chain: any(named: 'chain'),
      ),
    );
    expect(find.text('Review carefully'), findsOneWidget);
    expect(find.text('Review $count transactions'), findsOneWidget);
    expect(find.text('Simulation unavailable'), findsOneWidget);
    expect(
      find.textContaining('mallow simulates batches of up to 10'),
      findsOneWidget,
    );
    verifyNever(
      () => adapter.prepareTransaction(
        transaction: any(named: 'transaction'),
        walletId: any(named: 'walletId'),
        address: any(named: 'address'),
        origin: any(named: 'origin'),
        chain: any(named: 'chain'),
      ),
    );

    final approve = find.byKey(const Key('approve-signing'));
    expect(find.byType(HoldToApproveButton), findsOneWidget);
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pump(const Duration(seconds: 2));
    verifyNever(
      () => adapter.signPrepared(
        any(),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
        approvedAt: any(named: 'approvedAt'),
      ),
    );
    final hold = await tester.startGesture(tester.getCenter(approve));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 1300));
    await hold.up();
    await _settle(tester);
    final value = await result as Map<String, Object?>;
    expect(value['transactions'], hasLength(count));
    verify(
      () => adapter.signPrepared(
        any(),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
        approvedAt: any(named: 'approvedAt'),
      ),
    ).called(count);
  });

  group('a hardware signer', () {
    /// Holds each signature until the test releases it, as a device would.
    List<Completer<void>> holdSignatures() {
      final held = <Completer<void>>[];
      when(
        () => adapter.signPrepared(
          any(),
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
          approvedAt: any(named: 'approvedAt'),
        ),
      ).thenAnswer((invocation) async {
        final release = Completer<void>();
        held.add(release);
        await release.future;
        return (invocation.positionalArguments.first
                as PreparedSolanaTransaction)
            .bytes;
      });
      return held;
    }

    testWidgets('a Ledger keeps an awaiting-approval sheet up, with the '
        'batch progress, until the last signature is back', (tester) async {
      final result = await start(tester, 2, type: WalletType.ledger);
      final held = holdSignatures();
      await tester.tap(find.byKey(const Key('approve-signing')));
      await _settle(tester);

      expect(find.byType(SimulationReviewSheet), findsNothing);
      expect(find.text('$kExternalSigningLabel (1 of 2)'), findsOneWidget);
      expect(find.text(kLedgerSigningSublabel), findsOneWidget);

      held.single.complete();
      await _settle(tester);
      expect(find.text('$kExternalSigningLabel (2 of 2)'), findsOneWidget);

      held.last.complete();
      await _settle(tester);
      expect((await result as Map)['transactions'], hasLength(2));
      expect(find.textContaining(kExternalSigningLabel), findsNothing);
    });

    testWidgets('a Keystone gets the same sheet with its own instruction', (
      tester,
    ) async {
      final result = await start(tester, 1, type: WalletType.keystone);
      final held = holdSignatures();
      await tester.tap(find.byKey(const Key('approve-signing')));
      await _settle(tester);

      expect(find.text(kExternalSigningLabel), findsOneWidget);
      expect(find.text(kKeystoneSigningSublabel), findsOneWidget);

      held.single.complete();
      await _settle(tester);
      expect((await result as Map)['transactions'], hasLength(1));
      expect(find.text(kExternalSigningLabel), findsNothing);
    });

    testWidgets('a device failure stays on the sheet and says why', (
      tester,
    ) async {
      final result = await start(tester, 1, type: WalletType.ledger);
      when(
        () => adapter.signPrepared(
          any(),
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
          approvedAt: any(named: 'approvedAt'),
        ),
      ).thenThrow(StateError('device'));
      await tester.tap(find.byKey(const Key('approve-signing')));
      await _settle(tester);

      expect(await result, isA<StateError>());
      expect(find.text('Not signed'), findsOneWidget);
      expect(find.textContaining('Solana app open'), findsOneWidget);
    });

    testWidgets('closing the Ledger connect prompt closes the sheet too', (
      tester,
    ) async {
      final result = await start(tester, 1, type: WalletType.ledger);
      when(
        () => adapter.signPrepared(
          any(),
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
          approvedAt: any(named: 'approvedAt'),
        ),
      ).thenThrow(const LedgerNotConnectedException());
      await tester.tap(find.byKey(const Key('approve-signing')));
      await _settle(tester);

      expect(await result, isA<LedgerNotConnectedException>());
      expect(find.text(kExternalSigningLabel), findsNothing);
      expect(find.text('Not signed'), findsNothing);
    });

    testWidgets('a local key signs with no sheet', (tester) async {
      final result = await start(tester, 1, type: WalletType.hd);
      await tester.tap(find.byKey(const Key('approve-signing')));
      await _settle(tester);
      expect((await result as Map)['transactions'], hasLength(1));
      expect(find.byType(TransactionPipelineSheet), findsNothing);
    });
  });
}

/// Fixed pumps rather than `pumpAndSettle`: the review's placeholders
/// animate for as long as they are up. Long enough for the sheet to land and
/// for Approve to arm (`ReviewDecisionBar.armDelay`) after it.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 5; i++) {
    await tester.pump(MallowTheme.sheetDuration);
  }
}
