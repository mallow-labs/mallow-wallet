import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/core/services/fee_config.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/services/transaction_pipeline.dart';
import 'package:mallow_wallet/core/utils/address_format.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/mint/data/edit_prefill.dart';
import 'package:mallow_wallet/features/mint/data/mint_repository.dart';
import 'package:mallow_wallet/features/mint/services/mint_bloc.dart';
import 'package:mallow_wallet/features/mint/widgets/mint_source_wallet_line.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/send/widgets/send_sheet_widgets.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'mint_source_wallet_line_test.mocks.dart';

// The mint source line is the only place a user chooses which wallet becomes
// the artwork's permanent on-chain creator. What these tests pin: it never
// offers a choice that isn't there (0–1 fundable wallets), a chosen switch
// actually re-derives the form's creator, and a switch that fails leaves the
// flow exactly where it was rather than half-moved onto a wallet that never
// authenticated.
@GenerateMocks([
  SessionPortfolioAggregator,
  SessionManager,
  MintRepository,
  WalletManager,
  SolanaRpcService,
  TransactionPipeline,
  TokenPriceService,
  TransactionExecutor,
  EditNftPrefillService,
])
void main() {
  late MockSessionPortfolioAggregator mockAggregator;
  late MockSessionManager mockSession;
  late MockMintRepository mockRepository;
  late MockWalletManager mockWalletManager;
  late MockSolanaRpcService mockRpcService;
  late MockTransactionPipeline mockPipeline;
  late MockTokenPriceService mockPriceService;
  late MockTransactionExecutor mockExecutor;
  late MockEditNftPrefillService mockEditPrefill;

  const addressA = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const addressB = '4Nd1mYQ1a4Ux9hZbFjRxHVpQeQaB1jJ1nJvBQuBLCZ3F';

  const walletA = WalletInfo(
    id: 'wallet-a',
    address: addressA,
    name: 'Wallet A',
    walletType: WalletType.hd,
    chain: 'solana',
  );
  const walletB = WalletInfo(
    id: 'wallet-b',
    address: addressB,
    name: 'Wallet B',
    walletType: WalletType.hd,
    chain: 'solana',
  );

  /// A funded candidate: 1 SOL clears the native fee buffer that
  /// `qualifies(isNative: true)` applies.
  SendSourceCandidate funded(WalletInfo wallet) =>
      SendSourceCandidate(wallet: wallet, rawBalance: 1000000000, uiBalance: 1);

  /// Below the SOL fee buffer — holds lamports but cannot fund a mint.
  SendSourceCandidate dust(WalletInfo wallet) => SendSourceCandidate(
    wallet: wallet,
    rawBalance: 1000,
    uiBalance: 0.000001,
  );

  void stubSources(List<SendSourceCandidate> candidates) {
    when(
      mockAggregator.sendSourcesForMint(
        chain: anyNamed('chain'),
        mint: anyNamed('mint'),
        refresh: anyNamed('refresh'),
      ),
    ).thenAnswer((_) async => candidates);
  }

  MintBloc buildBloc() => MintBloc(
    mockRepository,
    mockWalletManager,
    mockRpcService,
    mockEditPrefill,
    mockPipeline,
    mockPriceService,
    const FeeConfig(),
    mockExecutor,
  );

  /// Mirrors the real screen: the line always renders the wallet the *form* is
  /// building for, so a re-derived creator shows up here immediately.
  Future<void> pumpLine(
    WidgetTester tester,
    MintBloc bloc, {
    ValueChanged<bool>? onSwitchingChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<MintBloc>.value(
            value: bloc,
            child: BlocBuilder<MintBloc, MintState>(
              builder: (context, state) => MintSourceWalletLine(
                address: state.userPubkey,
                onSwitchingChanged: onSwitchingChanged ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    // Let the bloc hydrate its wallet address and the candidate scan resolve.
    await tester.pump();
    await tester.pump();
  }

  setUpAll(() {
    // `verifyNever` invokes the stub to record its matcher, so mockito needs a
    // dummy for the generic return types it can't synthesise.
    provideDummy<ApiResponse<UnsignedTxResponse>>(
      const ApiResponse<UnsignedTxResponse>(
        result: UnsignedTxResponse(tx: 'dummy'),
      ),
    );
    provideDummy<Result<String, AppFailure>>(const ResultSuccess('dummy'));
  });

  setUp(() {
    mockAggregator = MockSessionPortfolioAggregator();
    mockSession = MockSessionManager();
    mockRepository = MockMintRepository();
    mockWalletManager = MockWalletManager();
    mockRpcService = MockSolanaRpcService();
    mockPipeline = MockTransactionPipeline();
    mockPriceService = MockTokenPriceService();
    mockExecutor = MockTransactionExecutor();
    mockEditPrefill = MockEditNftPrefillService();

    if (sl.isRegistered<SessionPortfolioAggregator>()) {
      sl.unregister<SessionPortfolioAggregator>();
    }
    sl.registerSingleton<SessionPortfolioAggregator>(mockAggregator);
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    sl.registerSingleton<SessionManager>(mockSession);

    when(mockWalletManager.getAddress()).thenAnswer((_) async => addressA);
    when(mockRepository.fetchTxFees()).thenAnswer((_) async => null);
  });

  tearDown(() {
    if (sl.isRegistered<SessionPortfolioAggregator>()) {
      sl.unregister<SessionPortfolioAggregator>();
    }
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
  });

  testWidgets(
    'renders nothing when the session has a single fundable wallet — there is '
    'no choice to offer',
    (tester) async {
      stubSources([funded(walletA)]);
      final bloc = buildBloc()..add(const MintEvent.started());
      addTearDown(bloc.close);

      await pumpLine(tester, bloc);

      expect(find.byType(SendSourceLine), findsNothing);
      expect(find.text('Switch'), findsNothing);
    },
  );

  testWidgets('renders nothing when no wallet can fund the mint', (
    tester,
  ) async {
    stubSources(const []);
    final bloc = buildBloc()..add(const MintEvent.started());
    addTearDown(bloc.close);

    await pumpLine(tester, bloc);

    expect(find.byType(SendSourceLine), findsNothing);
  });

  testWidgets(
    'a second wallet holding only dust is not a candidate — the SOL fee buffer '
    'is the gate, so the affordance stays hidden',
    (tester) async {
      stubSources([funded(walletA), dust(walletB)]);
      final bloc = buildBloc()..add(const MintEvent.started());
      addTearDown(bloc.close);

      await pumpLine(tester, bloc);

      expect(find.byType(SendSourceLine), findsNothing);
    },
  );

  testWidgets(
    'two fundable wallets show the source line, and the copy says the chosen '
    'wallet becomes the permanent on-chain creator — not merely the payer',
    (tester) async {
      stubSources([funded(walletA), funded(walletB)]);
      final bloc = buildBloc()..add(const MintEvent.started());
      addTearDown(bloc.close);

      await pumpLine(tester, bloc);

      expect(find.byType(SendSourceLine), findsOneWidget);
      expect(find.text('Switch'), findsOneWidget);
      expect(
        find.textContaining('on-chain creator'),
        findsOneWidget,
        reason:
            'minting under the wrong creator identity is unrecoverable, so '
            'the wallet choice must not read as a payer choice',
      );
      expect(find.textContaining("can't be changed after minting"), findsOne);
    },
  );

  testWidgets(
    'the picker lists both wallets; choosing the non-active one switches the '
    'signer and re-derives the creator the mint will be built for',
    (tester) async {
      stubSources([funded(walletA), funded(walletB)]);
      when(mockSession.selectSourceWallet(walletB)).thenAnswer((_) async {
        // The durable switch flips what the wallet manager reports — the same
        // DB read every mint tx builder makes.
        when(mockWalletManager.getAddress()).thenAnswer((_) async => addressB);
      });
      final bloc = buildBloc()..add(const MintEvent.started());
      addTearDown(bloc.close);

      await pumpLine(tester, bloc);
      expect(bloc.state.userPubkey, addressA);

      await tester.tap(find.text('Switch'));
      await tester.pumpAndSettle();
      // The sheet swallows taps until its entrance animation has settled.
      await tester.pump(const Duration(milliseconds: 200));

      // Both candidates are offered.
      expect(find.text(truncateAddress(addressA)), findsWidgets);
      expect(find.text(truncateAddress(addressB)), findsOneWidget);

      await tester.tap(find.text(truncateAddress(addressB)));
      await tester.pumpAndSettle();

      verify(mockSession.selectSourceWallet(walletB)).called(1);
      // The form now builds for wallet B — creator row and all.
      expect(bloc.state.userPubkey, addressB);
      expect(bloc.state.creators.first.address, addressB);
      expect(bloc.state.creators.first.isSelf, isTrue);
      // Candidate balances are reloaded for the new active wallet.
      verify(
        mockAggregator.sendSourcesForMint(
          chain: anyNamed('chain'),
          mint: anyNamed('mint'),
          refresh: anyNamed('refresh'),
        ),
      ).called(2);
    },
  );

  testWidgets(
    'a failed switch surfaces the error and leaves the flow on the previous '
    'wallet — nothing is re-derived and no tx is built',
    (tester) async {
      stubSources([funded(walletA), funded(walletB)]);
      when(
        mockSession.selectSourceWallet(walletB),
      ).thenAnswer((_) async => throw Exception('login failed'));
      final bloc = buildBloc()..add(const MintEvent.started());
      addTearDown(bloc.close);

      final switching = <bool>[];
      await pumpLine(tester, bloc, onSwitchingChanged: switching.add);

      await tester.tap(find.text('Switch'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text(truncateAddress(addressB)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Error surfaced, picker still open for a retry.
      expect(find.textContaining("Couldn't switch wallet"), findsOneWidget);
      // The CTA stays blocked while the (still open) switch is unresolved.
      expect(switching.last, isTrue);

      // User backs out; the form is untouched and nothing was built or signed.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(bloc.state.userPubkey, addressA);
      expect(switching.last, isFalse);
      verifyNever(mockRepository.buildMintNftTx(any));
      verifyNever(
        mockExecutor.execute(
          txsBase64: anyNamed('txsBase64'),
          usdValue: anyNamed('usdValue'),
          flow: anyNamed('flow'),
          additionalSigners: anyNamed('additionalSigners'),
          onStage: anyNamed('onStage'),
          tracker: anyNamed('tracker'),
          useLedger: anyNamed('useLedger'),
        ),
      );
    },
  );
}
