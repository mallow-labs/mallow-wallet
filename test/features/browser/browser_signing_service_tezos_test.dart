import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/models/account.dart' show WalletType;
import 'package:ledger_flutter_plus/ledger_flutter_plus.dart'
    show LedgerDeviceException, ConnectionType;
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/tezos_rpc_service.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/features/browser/data/browser_repository.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/browser_signing_service.dart';
import 'package:mallow_wallet/features/browser/services/browser_transaction_tracker.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_adapter.dart';
import 'package:mallow_wallet/features/browser/services/tezos_dapp_adapter.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_send_sheet.dart';
import 'package:mallow_wallet/features/browser/widgets/message_signing_review.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

class _Wallet extends Mock implements WalletManager {}

class _Gate extends Mock implements TransactionAuthGate {}

class _Prices extends Mock implements TokenPriceService {}

class _Storage extends Mock implements SecureWalletStorage {}

class _Rpc extends Mock implements TezosRpcService {}

const _mnemonic =
    'gym exact clown can answer hope sample mirror knife twenty powder super imitate lion churn almost shed chalk dust civil gadget pyramid helmet trade';
const _address = 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL';
void main() {
  late _Wallet wallet;
  late _Gate gate;
  late _Rpc rpc;
  late Completer<void> cancelled;
  late BuildContext host;
  late BrowserTransactionTracker tracker;
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(const FlowKey(Chain.tezos, AppFlow.browserMessage));
  });
  setUp(() {
    wallet = _Wallet();
    gate = _Gate();
    rpc = _Rpc();
    tracker = BrowserTransactionTracker();
    cancelled = Completer();
    when(
      () => gate.authorize(
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
      ),
    ).thenAnswer((_) async => TransactionAuthOutcome.allowed);
    when(
      () => wallet.getTezosPublicKey(
        'w',
        expectedAddress: any(named: 'expectedAddress'),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer(
      (_) => MultiChainDerivation.getTezosPublicKeyAtIndex(_mnemonic, 0),
    );
    when(
      () => wallet.signTezosPayloadForWallet(
        'w',
        any(),
        expectedAddress: _address,
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer(
      (invocation) => MultiChainDerivation.signTezosPayload(
        _mnemonic,
        0,
        invocation.positionalArguments[1] as Uint8List,
      ),
    );
  });
  tearDown(() => tracker.dispose());
  Future<Future<Map<String, Object?>>> start(
    WidgetTester tester, {
    String method = 'signPayload',
    List<int>? bytes,
    WalletType? type,
  }) async {
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
    cancelled = Completer<void>();
    final service = BrowserSigningService(
      adapter: SolanaDappAdapter(walletManager: wallet),
      tezosAdapter: TezosDappAdapter(
        walletManager: wallet,
        rpc: rpc,
        tracker: tracker,
      ),
      authGate: gate,
      prices: _Prices(),
      session: BrowserSession(BrowserRepository(_Storage())),
    );
    final result = service.execute(
      host,
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
        wallet: DappWallet(
          id: 'w',
          address: _address,
          canSign: true,
          chains: const [tezosMainnet],
          type: type,
        ),
        chain: tezosMainnet,
        payloads: [
          Uint8List.fromList(
            bytes ?? MultiChainDerivation.packTezosMicheline('hello'),
          ),
        ],
        payloadDigest: 'digest',
        cancelled: cancelled.future,
        options: const {'signingType': 'micheline'},
        ensureActive: () {
          if (cancelled.isCompleted)
            throw const DappException(4001, 'Cancelled');
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    return result;
  }

  testWidgets(
    'Given an approved Tezos message, step-up uses the Tezos flow and returns edsig',
    (tester) async {
      final pending = await start(tester);
      expect(find.byType(MessageSigningReview), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      await tester.tap(find.byKey(const Key('approve-signing')));
      await tester.pumpAndSettle();
      expect((await pending)['signature'], startsWith('edsig'));
      final flow =
          verify(
                () => gate.authorize(
                  usdValue: null,
                  flow: captureAny(named: 'flow'),
                ),
              ).captured.single
              as FlowKey;
      expect(flow.chain, Chain.tezos);
      expect(flow.flow, AppFlow.browserMessage);
    },
  );
  testWidgets('Given rejection, the message is never signed', (tester) async {
    final pending = await start(tester);
    final settled = pending.then<Object?>((r) => r, onError: (Object e) => e);
    await tester.tap(find.byKey(const Key('reject-signing')));
    await tester.pumpAndSettle();
    expect(await settled, isA<DappException>());
    verifyNever(
      () => wallet.getTezosPublicKey(
        any(),
        expectedAddress: any(named: 'expectedAddress'),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    );
    verifyNever(
      () => gate.authorize(
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
      ),
    );
  });
  testWidgets(
    'Given cancellation, the exact open approval sheet closes without signing',
    (tester) async {
      final pending = await start(tester);
      final settled = pending.then<Object?>((r) => r, onError: (Object e) => e);
      var done = false;
      Object? outcome;
      unawaited(
        settled.then((value) {
          done = true;
          outcome = value;
        }),
      );
      cancelled.complete();
      for (var i = 0; i < 20 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done, isTrue);
      expect(outcome, isA<DappException>());
      expect(find.byType(MessageSigningReview), findsNothing);
      verifyNever(
        () => wallet.getTezosPublicKey(
          any(),
          expectedAddress: any(named: 'expectedAddress'),
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      );
    },
  );
  testWidgets('Given cancelled auth, no Tezos key is loaded', (tester) async {
    when(
      () => gate.authorize(
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
      ),
    ).thenAnswer((_) async => TransactionAuthOutcome.cancelled);
    final pending = await start(tester);
    final settled = pending.then<Object?>((r) => r, onError: (Object e) => e);
    await tester.tap(find.byKey(const Key('approve-signing')));
    await tester.pumpAndSettle();
    expect(await settled, isA<DappException>());
    verifyNever(
      () => wallet.getTezosPublicKey(
        any(),
        expectedAddress: any(named: 'expectedAddress'),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    );
  });
  for (final approve in [false, true]) {
    testWidgets(
      'Given a transaction, review shows XTZ costs and ${approve ? 'approval signs and sends' : 'rejection never signs'}',
      (tester) async {
        when(() => rpc.getBranchHash()).thenAnswer(
          (_) async => 'BMXTnznPZDFf3TbpmdXptcTqcEuTHiCTgjxZaWif3YgVVPpp4Nq',
        );
        when(() => rpc.getChainId()).thenAnswer((_) async => 'NetXdQprcVkpaWU');
        when(() => rpc.nextCounter(_address)).thenAnswer((_) async => 1);
        when(() => rpc.getManagerKey(_address)).thenAnswer(
          (_) => MultiChainDerivation.getTezosPublicKeyAtIndex(_mnemonic, 0),
        );
        when(
          () => rpc.runOperation(
            branch: any(named: 'branch'),
            contents: any(named: 'contents'),
            chainId: any(named: 'chainId'),
          ),
        ).thenAnswer(
          (_) async => {
            'contents': [
              {
                'metadata': {
                  'operation_result': {
                    'status': 'applied',
                    'consumed_milligas': '2000000',
                  },
                },
              },
            ],
          },
        );
        when(
          () => wallet.signTezosOperation(
            'w',
            any(),
            expectedAddress: _address,
            ensureActive: any(named: 'ensureActive'),
            cancelled: any(named: 'cancelled'),
          ),
        ).thenAnswer(
          (invocation) => MultiChainDerivation.signTezosOperation(
            _mnemonic,
            0,
            invocation.positionalArguments[1] as String,
          ),
        );
        final injection = Completer<String>();
        String? hash;
        when(() => rpc.injectOperation(any())).thenAnswer((invocation) {
          hash = tezosOperationHash(
            invocation.positionalArguments[0] as String,
          );
          return injection.future;
        });
        final pending = await start(
          tester,
          method: 'sendOperations',
          bytes: utf8.encode(
            jsonEncode([
              {
                'kind': 'transaction',
                'destination': _address,
                'amount': '1000000',
              },
            ]),
          ),
        );
        final settled = pending.then<Object?>(
          (r) => r,
          onError: (Object e) => e,
        );
        expect(find.text('Tezos Mainnet'), findsOneWidget);
        expect(find.text('Fee and storage burn'), findsOneWidget);
        expect(find.text('Operation details'), findsOneWidget);
        expect(find.textContaining('SOL'), findsNothing);
        await tester.tap(
          find.byKey(Key(approve ? 'approve-signing' : 'reject-signing')),
        );
        await tester.pumpAndSettle();
        if (approve) {
          expect(find.byType(BrowserSendSheet), findsNothing);
          expect(find.text('Confirming transaction…'), findsNothing);
          expect(hash, isNotNull);
          injection.complete(hash!);
          await tester.pump();
          final result = await settled as Map;
          expect(result['hash'], startsWith('o'));
          final flow =
              verify(
                    () => gate.authorize(
                      usdValue: null,
                      flow: captureAny(named: 'flow'),
                    ),
                  ).captured.single
                  as FlowKey;
          expect(flow.chain, Chain.tezos);
          expect(flow.flow, AppFlow.browserTransaction);
          verify(() => rpc.injectOperation(any())).called(1);
          tracker.clear();
        } else {
          expect(await settled, isA<DappException>());
          verifyNever(
            () => wallet.signTezosOperation(
              any(),
              any(),
              expectedAddress: any(named: 'expectedAddress'),
              ensureActive: any(named: 'ensureActive'),
              cancelled: any(named: 'cancelled'),
            ),
          );
        }
      },
    );
  }
  testWidgets(
    'Given a Ledger message, native approval leads to device progress and a verified signature',
    (tester) async {
      final signed = Completer<String>();
      Future<void>? deviceCancellation;
      when(
        () => wallet.signTezosPayloadForWallet(
          'w',
          any(),
          expectedAddress: _address,
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      ).thenAnswer((invocation) {
        deviceCancellation =
            invocation.namedArguments[#cancelled] as Future<void>?;
        return signed.future;
      });
      final pending = await start(tester, type: WalletType.ledger);
      await tester.tap(find.byKey(const Key('approve-signing')));
      for (var i = 0; i < 20 && deviceCancellation == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(deviceCancellation, cancelled.future);
      expect(find.textContaining('Tezos Wallet app'), findsOneWidget);
      final signature = await tester.runAsync(
        () => MultiChainDerivation.signTezosPayload(
          _mnemonic,
          0,
          MultiChainDerivation.packTezosMicheline('hello'),
        ),
      );
      signed.complete(signature!);
      await tester.pumpAndSettle();
      expect((await pending)['signature'], signature);
    },
  );
  testWidgets(
    'Given a rejected Ledger message, the device sheet names Tezos and offers no Ethereum settings',
    (tester) async {
      when(
        () => wallet.signTezosPayloadForWallet(
          'w',
          any(),
          expectedAddress: _address,
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      ).thenThrow(
        LedgerDeviceException(
          errorCode: 0x6e00,
          message: 'Wrong app',
          connectionType: ConnectionType.ble,
        ),
      );
      final pending = await start(tester, type: WalletType.ledger);
      final settled = pending.then<Object?>((r) => r, onError: (Object e) => e);
      await tester.tap(find.byKey(const Key('approve-signing')));
      await tester.pumpAndSettle();
      expect(await settled, isA<LedgerDeviceException>());
      expect(find.textContaining('Open the Tezos Wallet app'), findsOneWidget);
      expect(find.textContaining('Ethereum'), findsNothing);
    },
  );
}
