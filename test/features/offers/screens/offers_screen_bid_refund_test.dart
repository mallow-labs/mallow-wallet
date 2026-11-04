import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';
import 'package:mallow_wallet/features/market/widgets/market_action_flow_sheet.dart';
import 'package:mallow_wallet/features/offers/models/bid_refund_balance.dart';
import 'package:mallow_wallet/features/offers/models/bid_refund_deposit.dart';
import 'package:mallow_wallet/features/offers/data/offers_inbox_repository.dart';
import 'package:mallow_wallet/features/offers/screens/offers_screen.dart';
import 'package:mallow_wallet/features/offers/services/offers_inbox_bloc.dart';
import 'package:mallow_wallet/features/offers/widgets/bid_refund_card.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _Inbox extends MockBloc<OffersInboxEvent, OffersInboxState>
    implements OffersInboxBloc {}

class _Market extends MockBloc<MarketEvent, MarketState>
    implements MarketBloc {}

class _Balances extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class _Auth extends Mock implements AuthService {}

class _Wallets extends Mock implements WalletRepository {}

class _Session extends Mock implements SessionManager {}

class _Config extends Fake implements RemoteConfigService {
  @override
  final ValueNotifier<RemoteConfig> config = ValueNotifier(
    RemoteConfig.permissive,
  );
  @override
  Future<void> refreshIfStale() async {}
}

class _Repo extends Fake implements OffersInboxRepository {
  _Repo(this.balance);
  final BidRefundBalance balance;
  Completer<api.OffersInboxPage>? pending;
  int refundCalls = 0;
  int depositCalls = 0;
  List<String> depositOwners = [];
  List<BidRefundDeposit> deposits = [];
  @override
  Future<List<BidRefundDeposit>> getBidRefundDeposits(
    Iterable<String> solanaOwners,
  ) async {
    depositCalls++;
    depositOwners = solanaOwners.toList();
    return deposits;
  }

  @override
  Future<List<BidRefundBalance>> getBidRefunds(
    Iterable<String> solanaOwners,
  ) async {
    refundCalls++;
    return [balance];
  }

  @override
  Future<api.OffersInboxPage> getInbox({
    required Iterable<String> owners,
    api.OffersInboxSort sort = api.OffersInboxSort.latest,
    int page = 0,
    int pageSize = 30,
  }) async {
    return pending == null
        ? const api.OffersInboxPage(result: [])
        : await pending!.future;
  }
}

void main() {
  const mint = 'So11111111111111111111111111111111111111112';
  const active = WalletInfo(
    id: 'active',
    address: 'ACTIVE',
    name: 'Active',
    chain: 'solana',
    walletType: WalletType.hd,
  );
  const bidder = WalletInfo(
    id: 'bidder',
    address: 'BIDDER',
    name: 'Bidder',
    chain: 'solana',
    walletType: WalletType.hd,
  );
  const ethereum = WalletInfo(
    id: 'ethereum',
    address: '0x0000000000000000000000000000000000000001',
    name: 'Ethereum',
    chain: 'ethereum',
    walletType: WalletType.hd,
  );
  const tezos = WalletInfo(
    id: 'tezos',
    address: 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb',
    name: 'Tezos',
    chain: 'tezos',
    walletType: WalletType.hd,
  );
  const balance = BidRefundBalance(
    bidder: 'BIDDER',
    refund: api.BidRefund(claim: 'CLAIM', mint: mint, amount: '42'),
  );
  late _Inbox inbox;
  late _Market market;
  late _Balances balances;
  late _Auth auth;
  late _Wallets wallets;
  late _Session session;
  late _Config config;
  late _Repo repo;
  late StreamController<MarketState> marketStates;
  late String? currentAddress;
  final switched = <WalletInfo>[];
  String? signerAtDispatch;

  setUpAll(() {
    registerFallbackValue(const MarketEvent.reset());
    registerFallbackValue(active);
  });

  setUp(() {
    inbox = _Inbox();
    market = _Market();
    balances = _Balances();
    auth = _Auth();
    wallets = _Wallets();
    session = _Session();
    config = _Config();
    repo = _Repo(balance);
    marketStates = StreamController<MarketState>.broadcast();
    currentAddress = active.address;
    switched.clear();
    signerAtDispatch = null;
    whenListen(
      inbox,
      const Stream<OffersInboxState>.empty(),
      initialState: const OffersInboxState.loaded(
        items: [],
        bidRefunds: [balance],
      ),
    );
    whenListen(
      market,
      marketStates.stream,
      initialState: const TxFlowIdle<MarketPrepData, MarketSuccessData>(),
    );
    whenListen(
      balances,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );
    when(
      () => session.sessionWallets,
    ).thenReturn([active, ethereum, bidder, tezos]);
    when(() => auth.currentAddress).thenAnswer((_) => currentAddress);
    when(
      () => session.resolveWalletForAddress(active.address),
    ).thenReturn(active);
    when(
      () => session.sessionWalletForAddress(bidder.address),
    ).thenReturn(bidder);
    when(() => session.selectSourceWallet(any())).thenAnswer((
      invocation,
    ) async {
      final target = invocation.positionalArguments.single as WalletInfo;
      switched.add(target);
      currentAddress = null;
      await Future<void>.delayed(Duration.zero);
      currentAddress = target.address;
    });
    when(() => wallets.getActiveWallet()).thenAnswer((_) async => bidder);
    when(() => market.add(any())).thenAnswer((invocation) {
      if (invocation.positionalArguments.single is MarketWithdrawBidRefund ||
          invocation.positionalArguments.single
              is MarketRecoverBidRefundDeposit ||
          invocation.positionalArguments.single is MarketReleaseSolBidRefund ||
          invocation.positionalArguments.single is MarketReleaseBidRefund) {
        signerAtDispatch = currentAddress;
      }
    });
    sl.registerSingleton<OffersInboxRepository>(repo);
    sl.registerFactory<OffersInboxBloc>(() => inbox);
    sl.registerFactory<MarketBloc>(() => market);
    sl.registerFactory<TokenBalanceBloc>(() => balances);
    sl.registerSingleton<AuthService>(auth);
    sl.registerSingleton<WalletRepository>(wallets);
    sl.registerSingleton<SessionManager>(session);
    sl.registerSingleton<RemoteConfigService>(config);
  });

  tearDown(() async {
    await marketStates.close();
    config.config.dispose();
    await sl.reset();
  });

  Future<void> openSent(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: OffersScreen()));
    await tester.pumpAndSettle();
    expect(find.byType(BidRefundCard), findsNothing);
    expect(
      find.byKey(const ValueKey('recover-bid-refund-deposits')),
      findsNothing,
    );
    await tester.tap(find.text('Sent'));
    await tester.pumpAndSettle();
    expect(find.byType(BidRefundCard), findsOneWidget);
  }

  Future<void> withdraw(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('withdraw-refund-CLAIM')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    // The tap barrier releases after the route animation, then its timer.
    await tester.pump(MallowTheme.sheetDuration);
    await tester.pump(MallowTheme.sheetTapGuardMinimum * 2);
  }

  testWidgets('deposit discovery is available only behind the Sent refund UI', (
    tester,
  ) async {
    await openSent(tester);
    expect(
      find.byKey(const ValueKey('recover-bid-refund-deposits')),
      findsOneWidget,
    );
    expect(repo.depositCalls, 0);
  });

  testWidgets(
    'deposit discovery remains accessible when the offers inbox fails',
    (tester) async {
      whenListen(
        inbox,
        const Stream<OffersInboxState>.empty(),
        initialState: const OffersInboxState.error(
          message: 'Inbox unavailable',
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: OffersScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sent'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recover-bid-refund-deposits')),
        findsOneWidget,
      );
      expect(repo.depositCalls, 0);
      await tester.tap(
        find.byKey(const ValueKey('recover-bid-refund-deposits')),
      );
      await tester.pumpAndSettle();
      expect(repo.depositCalls, 1);
      expect(find.text('No deposits are ready to recover.'), findsOneWidget);
    },
  );

  testWidgets('deposit discovery requests only Solana session addresses', (
    tester,
  ) async {
    await openSent(tester);
    await tester.tap(find.byKey(const ValueKey('recover-bid-refund-deposits')));
    await tester.pumpAndSettle();
    expect(repo.depositCalls, 1);
    expect(
      repo.depositOwners,
      unorderedEquals([active.address, bidder.address]),
    );
  });

  testWidgets('disabled deposit recovery blocks discovery and dispatch', (
    tester,
  ) async {
    config.config.value = const RemoteConfig(
      disabledMessages: {
        'solana:auction-refund-withdraw': 'Deposit recovery maintenance',
      },
    );
    await openSent(tester);
    await tester.tap(find.byKey(const ValueKey('recover-bid-refund-deposits')));
    await tester.pumpAndSettle();
    expect(find.text('Deposit recovery maintenance'), findsOneWidget);
    expect(repo.depositCalls, 0);
    verifyNever(() => session.selectSourceWallet(any()));
    verifyNever(() => market.add(any()));
  });

  Future<void> recoverDeposit(
    WidgetTester tester, {
    VoidCallback? beforeSelect,
  }) async {
    repo.deposits = [
      const BidRefundDeposit(claim: 'DEPOSIT', rentPayer: 'BIDDER'),
    ];
    await openSent(tester);
    await tester.tap(find.byKey(const ValueKey('recover-bid-refund-deposits')));
    await tester.pumpAndSettle();
    await tester.pump(MallowTheme.sheetTapGuardMinimum * 2);
    beforeSelect?.call();
    await tester.tap(find.byKey(const ValueKey('recover-deposit-DEPOSIT')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(MallowTheme.sheetDuration);
    await tester.pump(MallowTheme.sheetTapGuardMinimum * 2);
  }

  testWidgets('deposit recovery rechecks the flow after discovery', (
    tester,
  ) async {
    await recoverDeposit(
      tester,
      beforeSelect: () {
        config.config.value = const RemoteConfig(
          disabledMessages: {
            'solana:auction-refund-withdraw': 'Deposit recovery maintenance',
          },
        );
      },
    );
    expect(repo.depositCalls, 1);
    expect(find.text('Deposit recovery maintenance'), findsOneWidget);
    verifyNever(() => session.selectSourceWallet(any()));
    verifyNever(() => market.add(any()));
  });

  testWidgets(
    'deposit recovery selects the rent payer before dispatch and restores on abandon',
    (tester) async {
      await recoverDeposit(tester);
      expect(repo.depositCalls, 1);
      expect(signerAtDispatch, bidder.address);
      verify(
        () => market.add(
          const MarketEvent.recoverBidRefundDeposit(claim: 'DEPOSIT'),
        ),
      ).called(1);
      expect(find.byType(MarketActionFlowSheet), findsOneWidget);
      expect(find.text('Recover Deposit'), findsNWidgets(2));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(switched, [bidder, active]);
      expect(currentAddress, active.address);
    },
  );

  testWidgets('watch-only rent payer cannot dispatch deposit recovery', (
    tester,
  ) async {
    when(
      () => session.sessionWalletForAddress(bidder.address),
    ).thenReturn(bidder.copyWith(walletType: WalletType.viewOnly));
    await recoverDeposit(tester);
    expect(
      find.text('Import this wallet to recover the deposit it paid.'),
      findsOneWidget,
    );
    verifyNever(() => session.selectSourceWallet(any()));
    verifyNever(() => market.add(any()));
  });

  testWidgets(
    'deposit recovery reloads balances without refetching the offers feed and rereads on discovery',
    (tester) async {
      await recoverDeposit(tester);
      await tester.tap(find.text('Recover Deposit').last);
      await tester.pump();
      verify(() => market.add(const MarketEvent.confirmAndSign())).called(1);
      const result = MarketSuccessData(
        explorerUrl: 'https://example.com/tx',
        actionType: 'recover-bid-refund-deposit',
        mintAccount: 'DEPOSIT',
      );
      marketStates.add(
        const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
          signature: 'SIG',
          result: result,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 850));
      await tester.pumpAndSettle();
      verifyNever(() => inbox.add(const OffersInboxEvent.refresh()));
      verify(() => balances.add(const TokenBalanceEvent.load())).called(2);
      marketStates.add(
        TxFlowSuccess<MarketPrepData, MarketSuccessData>(
          signature: 'SIG',
          result: result.copyWith(indexed: true),
        ),
      );
      await tester.pumpAndSettle();
      verifyNever(() => inbox.add(const OffersInboxEvent.refresh()));
      repo.deposits = [];
      await tester.tap(
        find.byKey(const ValueKey('recover-bid-refund-deposits')),
      );
      await tester.pumpAndSettle();
      expect(repo.depositCalls, 2);
      expect(find.text('No deposits are ready to recover.'), findsOneWidget);
    },
  );

  for (final (refundMint, destination) in [
    (mint, null),
    ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', null),
    ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', ''),
    ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', 'ALTERNATIVE'),
  ]) {
    testWidgets(
      'non-active $refundMint bidder with destination $destination settles before dispatch and abandon restores the signer',
      (tester) async {
        whenListen(
          inbox,
          const Stream<OffersInboxState>.empty(),
          initialState: OffersInboxState.loaded(
            items: const [],
            bidRefunds: [
              BidRefundBalance(
                bidder: bidder.address,
                refund: api.BidRefund(
                  claim: 'CLAIM',
                  mint: refundMint,
                  amount: '42',
                ),
              ),
            ],
          ),
        );
        await openSent(tester);
        if (destination != null) {
          await tester.enterText(
            find.byKey(const ValueKey('refund-destination-CLAIM')),
            ' $destination ',
          );
        } else if (refundMint == mint) {
          expect(find.byType(TextFormField), findsNothing);
        }
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await withdraw(tester);
        expect(signerAtDispatch, bidder.address);
        verify(
          () => market.add(
            MarketEvent.withdrawBidRefund(
              amount: MarketPrice(rawAmount: 42, currencyMint: refundMint),
              destination: destination?.isEmpty == true ? null : destination,
            ),
          ),
        ).called(1);
        expect(find.byType(MarketActionFlowSheet), findsOneWidget);
        await tester.pump(MallowTheme.sheetTapGuardMinimum * 2);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(switched, [bidder, active]);
        expect(currentAddress, active.address);
        verifyNever(() => inbox.add(const OffersInboxEvent.refresh()));
      },
    );
  }

  testWidgets(
    'watch-only bidder gets an import prompt and cannot dispatch withdrawal',
    (tester) async {
      when(
        () => session.sessionWalletForAddress(bidder.address),
      ).thenReturn(bidder.copyWith(walletType: WalletType.viewOnly));
      await openSent(tester);
      await withdraw(tester);
      expect(find.text('Watch-only wallet'), findsOneWidget);
      expect(
        find.text('Import this bidder wallet to withdraw its refund.'),
        findsOneWidget,
      );
      verifyNever(() => session.selectSourceWallet(any()));
      verifyNever(() => market.add(any()));
    },
  );

  testWidgets(
    'disabled withdrawal flow is shown before switching or dispatching',
    (tester) async {
      config.config.value = const RemoteConfig(
        disabledMessages: {
          'solana:auction-refund-withdraw': 'Withdrawal maintenance',
        },
      );
      await openSent(tester);
      await withdraw(tester);
      expect(find.text('Withdrawal maintenance'), findsOneWidget);
      verifyNever(() => session.selectSourceWallet(any()));
      verifyNever(() => market.add(any()));
    },
  );

  testWidgets('success reloads balances; only the ack refreshes claims once', (
    tester,
  ) async {
    await openSent(tester);
    await withdraw(tester);
    await tester.pump(MallowTheme.sheetTapGuardMinimum * 2);
    await tester.tap(find.text('Withdraw Refund'));
    await tester.pump();
    verify(() => market.add(const MarketEvent.confirmAndSign())).called(1);
    const result = MarketSuccessData(
      explorerUrl: 'https://example.com/tx',
      actionType: 'withdraw-bid-refund',
      mintAccount: mint,
    );
    marketStates.add(
      const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
        signature: 'SIG',
        result: result,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 850));
    await tester.pumpAndSettle();
    expect(find.byType(MarketActionFlowSheet), findsNothing);
    verifyNever(() => inbox.add(const OffersInboxEvent.refresh()));
    // One initial balance load and one after the sheet completes.
    verify(() => balances.add(const TokenBalanceEvent.load())).called(2);
    expect(currentAddress, bidder.address);
    marketStates.add(
      TxFlowSuccess<MarketPrepData, MarketSuccessData>(
        signature: 'SIG',
        result: result.copyWith(indexed: true),
      ),
    );
    await tester.pumpAndSettle();
    verify(() => inbox.add(const OffersInboxEvent.refresh())).called(1);
  });

  testWidgets(
    'sort keeps the typed refund destination mounted while the inbox loads',
    (tester) async {
      when(() => session.sessionWallets).thenReturn([bidder]);
      when(() => session.apiOwnerAddresses).thenReturn([bidder.address]);
      final repo = _Repo(
        const BidRefundBalance(
          bidder: 'BIDDER',
          refund: api.BidRefund(
            claim: 'CLAIM',
            mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
            amount: '42',
          ),
        ),
      );
      final realInbox = OffersInboxBloc(repo, session);
      await sl.unregister<OffersInboxBloc>();
      sl.registerFactory<OffersInboxBloc>(() => realInbox);
      await openSent(tester);
      final field = find.byKey(const ValueKey('refund-destination-CLAIM'));
      await tester.enterText(field, 'ALTERNATIVE');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      repo.pending = Completer<api.OffersInboxPage>();
      realInbox.add(
        const OffersInboxEvent.setSort(sort: api.OffersInboxSort.amount),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(BidRefundCard), findsOneWidget);
      expect(find.text('ALTERNATIVE'), findsOneWidget);
      repo.pending!.complete(const api.OffersInboxPage(result: []));
      await tester.pumpAndSettle();
      expect(find.text('ALTERNATIVE'), findsOneWidget);
      expect(repo.refundCalls, 1);
    },
  );

  testWidgets(
    'inbox failure with a recoverable claim suppresses empty-inbox copy',
    (tester) async {
      whenListen(
        inbox,
        const Stream<OffersInboxState>.empty(),
        initialState: const OffersInboxState.loaded(
          items: [],
          bidRefunds: [balance],
          inboxError: 'Inbox unavailable',
          sort: api.OffersInboxSort.amount,
        ),
      );
      await openSent(tester);
      expect(find.text('Inbox unavailable'), findsOneWidget);
      expect(find.text('No offers or bids received yet.'), findsNothing);
      expect(find.text('No offers or bids sent yet.'), findsNothing);
    },
  );
  Future<void> releaseSolRefund(WidgetTester tester) async {
    repo.deposits = [
      const BidRefundDeposit(
        claim: 'DEPOSIT',
        rentPayer: 'BIDDER',
        bidder: 'ORIGINAL_BIDDER',
        amount: '2000000000',
        closable: false,
        releasable: true,
      ),
    ];
    await openSent(tester);
    await tester.tap(find.byKey(const ValueKey('recover-bid-refund-deposits')));
    await tester.pumpAndSettle();
    await tester.pump(MallowTheme.sheetTapGuardMinimum * 2);
    await tester.tap(find.byKey(const ValueKey('release-sol-refund-DEPOSIT')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(MallowTheme.sheetDuration);
    await tester.pump(MallowTheme.sheetTapGuardMinimum * 2);
  }

  testWidgets(
    'SOL release selects the rent payer, keeps the bidder recipient, and restores on abandon',
    (tester) async {
      await releaseSolRefund(tester);
      expect(signerAtDispatch, bidder.address);
      verify(
        () => market.add(
          const MarketEvent.releaseSolBidRefund(
            bidder: 'ORIGINAL_BIDDER',
            amount: MarketPrice(rawAmount: 2000000000),
          ),
        ),
      ).called(1);
      expect(find.textContaining('ORIGINAL_BIDDER'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(switched, [bidder, active]);
      expect(currentAddress, active.address);
      expect(repo.depositCalls, 1);
    },
  );

  testWidgets('watch-only rent payer cannot dispatch SOL release', (
    tester,
  ) async {
    when(
      () => session.sessionWalletForAddress(bidder.address),
    ).thenReturn(bidder.copyWith(walletType: WalletType.viewOnly));
    await releaseSolRefund(tester);
    expect(
      find.text('Import this wallet to recover the deposit it paid.'),
      findsOneWidget,
    );
    verifyNever(() => session.selectSourceWallet(any()));
    verifyNever(() => market.add(any()));
  });

  testWidgets(
    'successful SOL release rereads deposits so recovery becomes available',
    (tester) async {
      await releaseSolRefund(tester);
      await tester.tap(find.text('Release Refund'));
      await tester.pump();
      verify(() => market.add(const MarketEvent.confirmAndSign())).called(1);
      repo.deposits = [
        const BidRefundDeposit(claim: 'DEPOSIT', rentPayer: 'BIDDER'),
      ];
      const result = MarketSuccessData(
        explorerUrl: 'https://example.com/tx',
        actionType: 'release-sol-bid-refund',
        mintAccount: 'ORIGINAL_BIDDER',
        indexed: true,
      );
      marketStates.add(
        const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
          signature: 'RELEASE',
          result: result,
        ),
      );
      await tester.pump();
      expect(find.text('SOL refund released'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 850));
      await tester.pumpAndSettle();
      expect(repo.depositCalls, 2);
      expect(
        find.byKey(const ValueKey('recover-deposit-DEPOSIT')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('release-sol-refund-DEPOSIT')),
        findsNothing,
      );
      expect(currentAddress, bidder.address);
      verifyNever(() => inbox.add(const OffersInboxEvent.refresh()));
      verifyNever(
        () => market.add(
          const MarketEvent.recoverBidRefundDeposit(claim: 'DEPOSIT'),
        ),
      );
    },
  );

  for (final destination in [null, '', 'ALTERNATIVE']) {
    testWidgets(
      'token release preserves currency, recipient and destination $destination and rereads deposits',
      (tester) async {
        const tokenMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
        const amount = MarketPrice(
          rawAmount: 2_000_000,
          currencyMint: tokenMint,
        );
        repo.deposits = [
          const BidRefundDeposit(
            claim: 'TOKEN_DEPOSIT',
            rentPayer: 'BIDDER',
            bidder: 'ORIGINAL_BIDDER',
            amount: '2000000',
            mint: tokenMint,
            closable: false,
            releasable: true,
          ),
        ];
        await openSent(tester);
        await tester.tap(
          find.byKey(const ValueKey('recover-bid-refund-deposits')),
        );
        await tester.pumpAndSettle();
        await tester.pump(MallowTheme.sheetTapGuardMinimum * 2);
        if (destination != null) {
          await tester.enterText(
            find.byKey(const ValueKey('release-destination-TOKEN_DEPOSIT')),
            ' $destination ',
          );
          await tester.pump();
        }
        await tester.tap(
          find.byKey(const ValueKey('release-token-refund-TOKEN_DEPOSIT')),
        );
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pump(MallowTheme.sheetDuration);
        await tester.pump(MallowTheme.sheetTapGuardMinimum * 2);

        expect(signerAtDispatch, bidder.address);
        verify(
          () => market.add(
            MarketEvent.releaseBidRefund(
              bidder: 'ORIGINAL_BIDDER',
              amount: amount,
              destination: destination?.isEmpty == true ? null : destination,
            ),
          ),
        ).called(1);
        verifyNever(
          () => market.add(any(that: isA<MarketReleaseSolBidRefund>())),
        );
        final sheet = tester.widget<MarketActionFlowSheet>(
          find.byType(MarketActionFlowSheet),
        );
        expect(sheet.preview!.actionType, 'release-bid-refund');
        expect(sheet.preview!.totalCost, amount);
        expect(find.textContaining('ORIGINAL_BIDDER'), findsOneWidget);

        await tester.tap(find.text('Release Refund'));
        await tester.pump();
        verify(() => market.add(const MarketEvent.confirmAndSign())).called(1);
        repo.deposits = [
          const BidRefundDeposit(claim: 'TOKEN_DEPOSIT', rentPayer: 'BIDDER'),
        ];
        marketStates.add(
          const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
            signature: 'TOKEN_RELEASE',
            result: MarketSuccessData(
              explorerUrl: 'https://example.com/tx',
              actionType: 'release-bid-refund',
              mintAccount: 'ORIGINAL_BIDDER',
              indexed: true,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Token refund released'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 850));
        await tester.pumpAndSettle();
        expect(repo.depositCalls, 2);
        expect(
          find.byKey(const ValueKey('recover-deposit-TOKEN_DEPOSIT')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('release-token-refund-TOKEN_DEPOSIT')),
          findsNothing,
        );
        verifyNever(() => inbox.add(const OffersInboxEvent.refresh()));
      },
    );
  }
}
