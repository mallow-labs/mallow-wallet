import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/eip712.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/network/ethereum_rpc_service.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/browser/data/browser_repository.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/browser_signing_service.dart';
import 'package:mallow_wallet/features/browser/services/browser_transaction_tracker.dart';
import 'package:mallow_wallet/features/browser/services/ethereum_dapp_adapter.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_adapter.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_send_sheet.dart';
import 'package:mallow_wallet/features/browser/widgets/ethereum_fee_affordance.dart';
import 'package:mallow_wallet/features/browser/widgets/message_signing_review.dart';
import 'package:mallow_wallet/features/browser/widgets/typed_data_signing_review.dart';
import 'package:mallow_wallet/features/send/models/eth_gas.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web3dart/web3dart.dart' show Transaction, keccak256;

class _Wallet extends Mock implements WalletManager {}

class _Gate extends Mock implements TransactionAuthGate {}

class _Prices extends Mock implements TokenPriceService {}

class _Storage extends Mock implements SecureWalletStorage {}

final _key = keccak256(Uint8List.fromList(utf8.encode('cow')));
const _address = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';

void main() {
  late _Wallet wallet;
  late _Gate gate;
  late BuildContext host;
  late Completer<void> cancelled;

  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(
      Eip712TypedData.parse({
        'types': {'EIP712Domain': <Object>[]},
        'primaryType': 'EIP712Domain',
        'domain': <String, Object>{},
        'message': <String, Object>{},
      }),
    );
    registerFallbackValue(FlowKey.solana(AppFlow.browserMessage));
    registerFallbackValue(Transaction());
  });

  setUp(() {
    wallet = _Wallet();
    gate = _Gate();
    when(
      () => gate.authorize(
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
      ),
    ).thenAnswer((_) async => TransactionAuthOutcome.allowed);
    when(
      () => wallet.signEthereumPersonalMessageForWallet(
        any(),
        any(),
        expectedAddress: any(named: 'expectedAddress'),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer(
      (invocation) async => Uint8List.fromList(
        _bytes(
          await MultiChainDerivation.signEthereumPersonalMessageWithKey(
            _key,
            invocation.positionalArguments[1] as Uint8List,
          ),
        ),
      ),
    );
    when(
      () => wallet.signEthereumTypedDataForWallet(
        any(),
        any(),
        expectedAddress: any(named: 'expectedAddress'),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer(
      (invocation) async =>
          MultiChainDerivation.signEthereumTypedDataDigestWithKey(
            _key,
            (invocation.positionalArguments[1] as Eip712TypedData).digest,
          ),
    );
  });

  DappSigningRequest request(String method, List<int> payload) {
    cancelled = Completer<void>();
    return DappSigningRequest(
      id: '1',
      method: method,
      context: DappFrameContext(
        tabId: 't',
        generation: 1,
        origin: Uri.parse('https://site.example'),
        isMainFrame: true,
        isActive: true,
      ),
      wallet: const DappWallet(
        id: 'w',
        address: _address,
        canSign: true,
        chains: [ethereumMainnet],
      ),
      chain: ethereumMainnet,
      payloads: [Uint8List.fromList(payload)],
      payloadDigest: 'digest',
      cancelled: cancelled.future,
      options: const {},
      ensureActive: () {
        if (cancelled.isCompleted) {
          throw const DappException(4001, 'Request cancelled.');
        }
      },
    );
  }

  Future<Future<Map<String, Object?>>> start(
    WidgetTester tester,
    DappSigningRequest request, {
    EthereumDappAdapter? ethereum,
    TokenPriceService? prices,
    bool settle = true,
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
    final service = BrowserSigningService(
      adapter: SolanaDappAdapter(walletManager: wallet),
      ethereumAdapter: ethereum ?? EthereumDappAdapter(walletManager: wallet),
      authGate: gate,
      prices: prices ?? _Prices(),
      session: BrowserSession(BrowserRepository(_Storage())),
    );
    final result = service.execute(host, request);
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // The placeholder animates for as long as the simulation runs.
      for (var i = 0; i < 5; i++) {
        await tester.pump(MallowTheme.sheetDuration);
      }
    }
    // The sheet swallows taps until its entrance has settled.
    await tester.pump(const Duration(milliseconds: 200));
    return result;
  }

  testWidgets('personal_sign reviews, authorizes the Ethereum cell and '
      'returns a hex signature', (tester) async {
    final result = await start(
      tester,
      request('personal_sign', utf8.encode('hello')),
    );
    expect(find.byType(MessageSigningReview), findsOneWidget);
    final outcome = _settled(result);
    await tester.tap(find.byKey(const Key('approve-signing')));
    for (var i = 0; i < 20 && !outcome.done; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(outcome.error, isNull);
    expect(outcome.value?['signature'], startsWith('0x2452a50a1b27db55'));
    final flow =
        verify(
              () => gate.authorize(
                usdValue: any(named: 'usdValue'),
                flow: captureAny(named: 'flow'),
              ),
            ).captured.single
            as FlowKey;
    expect(flow, const FlowKey(Chain.ethereum, AppFlow.browserMessage));
  });

  testWidgets('typed data shows its own review before anything is signed', (
    tester,
  ) async {
    final typed = jsonEncode({
      'types': {
        'Vote': [
          {'name': 'proposal', 'type': 'uint256'},
        ],
      },
      'primaryType': 'Vote',
      'domain': {'name': 'Gov', 'chainId': 1},
      'message': {'proposal': 1},
    });
    final result = await start(
      tester,
      request('eth_signTypedData_v4', utf8.encode(typed)),
    );
    expect(find.byType(TypedDataSigningReview), findsOneWidget);
    verifyNever(
      () => wallet.signEthereumTypedDataForWallet(
        any(),
        any(),
        expectedAddress: any(named: 'expectedAddress'),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    );
    final outcome = _settled(result);
    await tester.tap(find.byKey(const Key('reject-signing')));
    for (var i = 0; i < 20 && !outcome.done; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      outcome.error,
      isA<DappException>().having((e) => e.code, 'code', 4001),
    );
  });

  Future<
    ({
      EthereumDappAdapter adapter,
      PreferencesService prefs,
      List<PendingEvmBroadcast> broadcasts,
    })
  >
  transactionSetup(
    WidgetTester tester, {
    List<EvmAssetChange>? changes,
    Future<String> Function(String hash)? send,
    Future<EvmSimulationResult>? simulation,
  }) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.create();
    if (sl.isRegistered<PreferencesService>()) {
      sl.unregister<PreferencesService>();
    }
    sl.registerSingleton<PreferencesService>(prefs);
    addTearDown(() => sl.unregister<PreferencesService>());

    final gwei = BigInt.from(1000000000);
    EthGasTier tier(EthGasMode mode, int fee, int tip, int waitMs) =>
        EthGasTier(
          mode: mode,
          maxFeePerGas: gwei * BigInt.from(fee),
          maxPriorityFeePerGas: gwei * BigInt.from(tip),
          minWaitMs: waitMs ~/ 2,
          maxWaitMs: waitMs,
        );
    final market = EthGasMarket(
      baseFeeWei: gwei * BigInt.from(10),
      priorityLowWei: gwei,
      priorityHighWei: gwei * BigInt.two,
      congestion: 0.2,
      historicalBaseFeeMinWei: gwei,
      historicalBaseFeeMaxWei: gwei * BigInt.from(40),
      historicalPriorityMinWei: BigInt.zero,
      historicalPriorityMaxWei: gwei * BigInt.from(3),
      low: tier(EthGasMode.low, 12, 1, 60000),
      market: tier(EthGasMode.market, 20, 2, 30000),
    );
    final tracker = BrowserTransactionTracker(
      interval: const Duration(hours: 1),
    );
    addTearDown(tracker.clear);
    final broadcasts = <PendingEvmBroadcast>[];
    final adapter = EthereumDappAdapter(
      walletManager: wallet,
      rpc: (method, params) async => switch (method) {
        'eth_getTransactionCount' => '0x3',
        'eth_estimateGas' => '0x5208',
        'eth_getCode' => '0x',
        'eth_getBlockByNumber' => {'baseFeePerGas': '0x2540be400'},
        'eth_sendRawTransaction' =>
          send != null
              ? await send(
                  ethereumTransactionHash(
                    Uint8List.fromList(_bytes(params.single! as String)),
                  ),
                )
              : ethereumTransactionHash(
                  Uint8List.fromList(_bytes(params.single! as String)),
                ),
        _ => throw StateError(method),
      },
      simulate:
          ({
            required String from,
            required String to,
            required String data,
            String value = '0x0',
          }) async =>
              await simulation ??
              EvmSimulationResult(
                changes:
                    changes ??
                    [
                      EvmAssetChange(
                        assetType: 'NATIVE',
                        changeType: 'TRANSFER',
                        from: from,
                        to: to,
                        rawAmount: '1000000000000000000',
                      ),
                    ],
              ),
      gasMarket: () async => market,
      preferences: prefs,
      tracker: tracker,
      onBroadcast: broadcasts.add,
    );
    when(
      () => wallet.signEthereumTransaction(
        any(),
        any(),
        chainId: any(named: 'chainId'),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer(
      (invocation) => MultiChainDerivation.signEthereumTransactionWithKey(
        _key,
        invocation.positionalArguments[1] as Transaction,
        1,
      ),
    );
    return (adapter: adapter, prefs: prefs, broadcasts: broadcasts);
  }

  DappSigningRequest sendRequest({
    Map<String, String> fees = const {},
    String data = '0x',
    String value = '0xde0b6b3a7640000',
  }) => request(
    'eth_sendTransaction',
    utf8.encode(
      jsonEncode({
        'from': _address.toLowerCase(),
        'to': '0x${'bb' * 20}',
        'value': value,
        'data': data,
        ...fees,
      }),
    ),
  );

  testWidgets('Ethereum review closes before submission completes', (
    tester,
  ) async {
    final submission = Completer<String>();
    String? hash;
    final setup = await transactionSetup(
      tester,
      send: (signedHash) {
        hash = signedHash;
        return submission.future;
      },
    );
    final prices = _Prices();
    when(() => prices.priceOf(any())).thenReturn(null);
    final outcome = _settled(
      await start(
        tester,
        sendRequest(),
        ethereum: setup.adapter,
        prices: prices,
      ),
    );
    await tester.tap(find.byKey(const Key('approve-signing')));
    await tester.pumpAndSettle();
    expect(hash, isNotNull);
    expect(outcome.done, isFalse);
    expect(find.byType(BrowserSendSheet), findsNothing);
    expect(find.text('Confirming transaction…'), findsNothing);

    submission.complete(hash!);
    await tester.pump();
    expect(outcome.error, isNull);
    expect(outcome.value?['hash'], hash);
    expect(find.text('Transaction confirmed'), findsNothing);
    setup.adapter.tracker.clear();
  });

  testWidgets('approved before its simulation, it signs without one', (
    tester,
  ) async {
    final setup = await transactionSetup(
      tester,
      simulation: Completer<EvmSimulationResult>().future,
    );
    final prices = _Prices();
    when(() => prices.priceOf(any())).thenReturn(null);
    final outcome = _settled(
      await start(
        tester,
        sendRequest(),
        ethereum: setup.adapter,
        prices: prices,
        settle: false,
      ),
    );
    expect(find.byKey(const Key('review-pending')), findsOneWidget);
    await tester.tap(find.byKey(const Key('approve-signing-early')));
    for (var i = 0; i < 20 && !outcome.done; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(outcome.error, isNull);
    expect(outcome.value?['hash'], startsWith('0x'));
    // Its effects were never seen, so step-up auth gets no value.
    verify(
      () => gate.authorize(usdValue: null, flow: any(named: 'flow')),
    ).called(1);
    setup.adapter.tracker.clear();
  });

  for (final message in [false, true]) {
    testWidgets(
      'cancellation while ${message ? 'personal_sign' : 'eth_sendTransaction'} '
      'waits for a signer releases the request',
      (tester) async {
        final setup = message ? null : await transactionSetup(tester);
        final signing = message
            ? request('personal_sign', utf8.encode('hello'))
            : sendRequest();
        Invocation? signingInvocation;
        Future<Uint8List> waitForCancellation(Invocation invocation) async {
          signingInvocation = invocation;
          await (invocation.namedArguments[#cancelled] as Future<void>);
          (invocation.namedArguments[#ensureActive] as void Function())();
          throw StateError('Cancelled request reached signing');
        }

        if (message) {
          when(
            () => wallet.signEthereumPersonalMessageForWallet(
              any(),
              any(),
              expectedAddress: any(named: 'expectedAddress'),
              ensureActive: any(named: 'ensureActive'),
              cancelled: any(named: 'cancelled'),
            ),
          ).thenAnswer(waitForCancellation);
        } else {
          when(
            () => wallet.signEthereumTransaction(
              any(),
              any(),
              chainId: any(named: 'chainId'),
              ensureActive: any(named: 'ensureActive'),
              cancelled: any(named: 'cancelled'),
            ),
          ).thenAnswer(waitForCancellation);
        }
        final prices = _Prices();
        when(() => prices.priceOf(any())).thenReturn(null);
        final outcome = _settled(
          await start(
            tester,
            signing,
            ethereum: setup?.adapter,
            prices: prices,
          ),
        );
        await tester.tap(find.byKey(const Key('approve-signing')));
        for (
          var i = 0;
          i < 20 && signingInvocation == null && !outcome.done;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(signingInvocation, isNotNull);
        expect(
          signingInvocation!.namedArguments[#ensureActive],
          signing.ensureActive,
        );
        expect(
          signingInvocation!.namedArguments[#cancelled],
          signing.cancelled,
        );
        expect(outcome.error, isNull);
        expect(outcome.done, isFalse);
        cancelled.complete();
        for (var i = 0; i < 20 && !outcome.done; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(outcome.done, isTrue);
        expect(
          outcome.error,
          isA<DappException>().having((e) => e.code, 'code', 4001),
        );
        if (setup != null) expect(setup.broadcasts, isEmpty);
      },
    );
  }

  for (final editFee in [false, true]) {
    testWidgets(
      'editing ${editFee ? 'the fee cap' : 'only the gas limit'} of a '
      'site-priced transaction keeps defaults after a second Advanced save',
      (tester) async {
        final setup = await transactionSetup(tester);
        await setup.prefs.setEthGasMode('custom');
        await setup.prefs.setEthGasMaxBaseFeeGwei(16);
        await setup.prefs.setEthGasPriorityFeeGwei(1.5);
        final siteMaxFee = EthGasMarket.gweiToWei(98);
        final siteTip = EthGasMarket.gweiToWei(9.8);
        final prices = _Prices();
        when(() => prices.priceOf(any())).thenReturn(null);
        final outcome = _settled(
          await start(
            tester,
            sendRequest(
              fees: {
                'maxFeePerGas': '0x${siteMaxFee.toRadixString(16)}',
                'maxPriorityFeePerGas': '0x${siteTip.toRadixString(16)}',
              },
            ),
            ethereum: setup.adapter,
            prices: prices,
          ),
        );

        await tester.tap(find.byKey(const Key('edit-network-fee')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.text('Advanced').hitTestable());
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, '88.2'), findsOneWidget);
        expect(find.widgetWithText(TextField, '9.8'), findsOneWidget);
        await tester.enterText(
          find.widgetWithText(TextField, '25200'),
          '30000',
        );
        if (editFee) {
          await tester.enterText(find.widgetWithText(TextField, '88.2'), '80');
        }
        await tester.pumpAndSettle();
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();

        expect(setup.prefs.ethGasMode, 'custom');
        expect(setup.prefs.ethGasMaxBaseFeeGwei, 16);
        expect(setup.prefs.ethGasPriorityFeeGwei, 1.5);
        await tester.tap(find.byKey(const Key('edit-network-fee')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.text('Advanced').hitTestable());
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, '30000'), findsOneWidget);
        expect(
          find.widgetWithText(TextField, editFee ? '80' : '88.2'),
          findsOneWidget,
        );
        expect(find.widgetWithText(TextField, '9.8'), findsOneWidget);
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(setup.prefs.ethGasMode, 'custom');
        expect(setup.prefs.ethGasMaxBaseFeeGwei, 16);
        expect(setup.prefs.ethGasPriorityFeeGwei, 1.5);
        await tester.tap(find.byKey(const Key('approve-signing')));
        for (var i = 0; i < 20 && !outcome.done; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(outcome.done, isTrue);
        expect(outcome.error, isNull);
        final broadcast = setup.broadcasts.single;
        expect(
          broadcast.maxFeePerGas,
          editFee ? EthGasMarket.gweiToWei(89.8) : siteMaxFee,
        );
        expect(broadcast.maxPriorityFeePerGas, siteTip);
        expect(broadcast.gasLimit, 30000);
        setup.adapter.tracker.clear();
      },
    );
  }

  testWidgets('a gas-limit-only edit preserves non-round site fees and '
      'their caution through the real sheet', (tester) async {
    final setup = await transactionSetup(tester);
    final siteMaxFee = BigInt.parse('9000000000001');
    final siteTip = BigInt.parse('2000000003');
    const caution =
        "The website's maximum fee is more than 5 times the Market tier. "
        'Review the maximum network fee before approving.';
    final prices = _Prices();
    when(() => prices.priceOf(any())).thenReturn(null);
    final outcome = _settled(
      await start(
        tester,
        sendRequest(
          fees: {
            'maxFeePerGas': '0x${siteMaxFee.toRadixString(16)}',
            'maxPriorityFeePerGas': '0x${siteTip.toRadixString(16)}',
            'gas': '0x${500000.toRadixString(16)}',
          },
        ),
        ethereum: setup.adapter,
        prices: prices,
      ),
    );
    expect(find.text('Site suggested'), findsOneWidget);
    expect(find.text(caution), findsOneWidget);

    await tester.tap(find.byKey(const Key('edit-network-fee')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Advanced').hitTestable());
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '500000'), '30000');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    final prepared = tester
        .widget<EthereumFeeAffordance>(find.byType(EthereumFeeAffordance))
        .prepared;
    expect(prepared.feeFromSite, isTrue);
    expect(prepared.maxFeePerGas, siteMaxFee);
    expect(prepared.maxPriorityFeePerGas, siteTip);
    expect(prepared.gasLimit, 30000);
    expect(prepared.review.warnings, contains(caution));
    expect(find.text(caution), findsOneWidget);
    expect(find.text('Site suggested'), findsOneWidget);
    expect(setup.prefs.ethGasMode, isNull);

    await tester.tap(find.byKey(const Key('approve-signing')));
    for (var i = 0; i < 20 && !outcome.done; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(outcome.done, isTrue);
    expect(outcome.error, isNull);
    final broadcast = setup.broadcasts.single;
    expect(broadcast.maxFeePerGas, siteMaxFee);
    expect(broadcast.maxPriorityFeePerGas, siteTip);
    expect(broadcast.gasLimit, 30000);
    final signed =
        verify(
              () => wallet.signEthereumTransaction(
                any(),
                captureAny(),
                chainId: 1,
                ensureActive: any(named: 'ensureActive'),
                cancelled: any(named: 'cancelled'),
              ),
            ).captured.single
            as Transaction;
    expect(signed.maxFeePerGas!.getInWei, siteMaxFee);
    expect(signed.maxPriorityFeePerGas!.getInWei, siteTip);
    expect(signed.maxGas, 30000);
    setup.adapter.tracker.clear();
  });

  testWidgets('editing gas on a website transaction re-prices what is '
      'signed and broadcast, and saves the tier as in-app', (tester) async {
    final setup = await transactionSetup(tester);
    final gwei = BigInt.from(1000000000);
    final prices = _Prices();
    when(() => prices.priceOf(any())).thenReturn(null);
    when(() => prices.priceOf(evmNativeAssetId)).thenReturn(2000);

    final result = await start(
      tester,
      sendRequest(),
      ethereum: setup.adapter,
      prices: prices,
    );
    final outcome = _settled(result);
    expect(find.text('Market · ~30 sec'), findsOneWidget);

    await tester.tap(find.byKey(const Key('edit-network-fee')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Edit Gas Fee'), findsOneWidget);
    await tester.tap(find.text('Low'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Low · ~1 min'), findsOneWidget);
    expect(setup.prefs.ethGasMode, 'low');

    await tester.tap(find.byKey(const Key('approve-signing')));
    for (var i = 0; i < 20 && !outcome.done; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(outcome.error, isNull);
    final broadcast = setup.broadcasts.single;
    expect(broadcast.maxFeePerGas, gwei * BigInt.from(12));
    expect(broadcast.maxPriorityFeePerGas, gwei);
    expect(broadcast.nonce, 3);
    expect(outcome.value?['hash'], broadcast.hash);
    final usd = verify(
      () => gate.authorize(
        usdValue: captureAny(named: 'usdValue'),
        flow: const FlowKey(Chain.ethereum, AppFlow.browserTransaction),
      ),
    ).captured.single;
    // The edited gas limit and fee cap bound the cost authorized for signing.
    expect(usd, closeTo((1 + 25200 * 12e9 / 1e18) * 2000, 1e-9));
    setup.adapter.tracker.clear();
  });

  testWidgets('an unpriced send passes unknown USD to authorization', (
    tester,
  ) async {
    final setup = await transactionSetup(tester);
    final prices = _Prices();
    when(() => prices.priceOf(any())).thenReturn(null);
    final outcome = _settled(
      await start(
        tester,
        sendRequest(),
        ethereum: setup.adapter,
        prices: prices,
      ),
    );
    await tester.tap(find.byKey(const Key('approve-signing')));
    for (var i = 0; i < 20 && !outcome.done; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(outcome.done, isTrue);
    expect(outcome.error, isNull);
    verify(
      () => gate.authorize(
        usdValue: null,
        flow: const FlowKey(Chain.ethereum, AppFlow.browserTransaction),
      ),
    ).called(1);
    setup.adapter.tracker.clear();
  });

  testWidgets('a contract call with no decoded effects passes unknown USD '
      'to authorization even with a known ETH price', (tester) async {
    final setup = await transactionSetup(tester, changes: []);
    final prices = _Prices();
    when(() => prices.priceOf(any())).thenReturn(null);
    when(() => prices.priceOf(evmNativeAssetId)).thenReturn(2000);
    final outcome = _settled(
      await start(
        tester,
        // No value: a value with no native transfer in the simulation is
        // undecodable instead, and needs a press-and-hold.
        sendRequest(data: '0x12345678', value: '0x0'),
        ethereum: setup.adapter,
        prices: prices,
      ),
    );
    await tester.tap(find.byKey(const Key('approve-signing')));
    for (var i = 0; i < 20 && !outcome.done; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(outcome.done, isTrue);
    expect(outcome.error, isNull);
    verify(
      () => gate.authorize(
        usdValue: null,
        flow: const FlowKey(Chain.ethereum, AppFlow.browserTransaction),
      ),
    ).called(1);
    setup.adapter.tracker.clear();
  });

  for (final newerRoute in [false, true]) {
    testWidgets('cancelling a request closes its gas editor '
        '${newerRoute ? 'below a newer route' : 'above the review'}', (
      tester,
    ) async {
      final setup = await transactionSetup(tester);
      final prices = _Prices();
      when(() => prices.priceOf(any())).thenReturn(null);
      final outcome = _settled(
        await start(
          tester,
          sendRequest(),
          ethereum: setup.adapter,
          prices: prices,
        ),
      );
      await tester.tap(find.byKey(const Key('edit-network-fee')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Edit Gas Fee'), findsOneWidget);
      await tester.tap(find.text('Low'));
      await tester.pumpAndSettle();
      if (newerRoute) {
        unawaited(
          Navigator.of(host, rootNavigator: true).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('newer route')),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }
      cancelled.complete();
      await tester.pumpAndSettle();
      expect(outcome.done, isTrue);
      expect(
        outcome.error,
        isA<DappException>().having((e) => e.code, 'code', 4001),
      );
      expect(find.text('Edit Gas Fee', skipOffstage: false), findsNothing);
      expect(
        find.byKey(const Key('approve-signing'), skipOffstage: false),
        findsNothing,
      );
      expect(setup.prefs.ethGasMode, isNull);
      expect(setup.broadcasts, isEmpty);
      verifyNever(
        () => gate.authorize(
          usdValue: any(named: 'usdValue'),
          flow: any(named: 'flow'),
        ),
      );
      if (newerRoute) {
        expect(find.text('newer route'), findsOneWidget);
      } else {
        expect(Navigator.of(host).canPop(), isFalse);
      }
    });
  }
}

List<int> _bytes(String hex) => [
  for (var i = 2; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

class _Outcome {
  bool done = false;
  Map<String, Object?>? value;
  Object? error;
}

_Outcome _settled(Future<Map<String, Object?>> future) {
  final outcome = _Outcome();
  future.then(
    (value) => outcome
      ..value = value
      ..done = true,
    onError: (Object error) => outcome
      ..error = error
      ..done = true,
  );
  return outcome;
}
