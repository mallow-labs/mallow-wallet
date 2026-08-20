import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/services/fee_config.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/services/transaction_pipeline.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/mint/data/edit_prefill.dart';
import 'package:mallow_wallet/features/mint/data/mint_repository.dart';
import 'package:mallow_wallet/features/mint/pickers/collection_picker_sheet.dart';
import 'package:mallow_wallet/features/mint/services/mint_bloc.dart';
import 'package:mallow_wallet/features/mint/steps/details_step.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'details_step_test.mocks.dart';

// A Master Edition's parent link is an mpl-core Group, so the on-chain shape
// genuinely supports one — and the create/edit wire builders already send
// `collection` + `groupSigner` / `newParentCollection` for it. The picker was
// nevertheless gated to 1/1, which made every one of those code paths
// unreachable. These tests pin which mint types are allowed to reach the
// picker, matching the webapp, where `Details` (the picker's host) renders
// for 1/1 and editions on create and edit alike and only collections fall
// through to the picker-less `CollectionDetails` (`Create`,
// `Edit`).
@GenerateMocks([
  MintRepository,
  WalletManager,
  SolanaRpcService,
  TransactionPipeline,
  TokenPriceService,
  TransactionExecutor,
  EditNftPrefillService,
])
void main() {
  late MockMintRepository mockRepository;
  late MockWalletManager mockWalletManager;
  late MockSolanaRpcService mockRpcService;
  late MockTransactionPipeline mockPipeline;
  late MockTokenPriceService mockPriceService;
  late MockTransactionExecutor mockExecutor;
  late MockEditNftPrefillService mockEditPrefill;

  const address = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';

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

  Future<void> pumpDetails(WidgetTester tester, MintBloc bloc) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<MintBloc>.value(
            value: bloc,
            child: const DetailsStep(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  setUpAll(() {
    provideDummy<ApiResponse<UnsignedTxResponse>>(
      const ApiResponse<UnsignedTxResponse>(
        result: UnsignedTxResponse(tx: 'dummy'),
      ),
    );
    provideDummy<Result<String, AppFailure>>(const ResultSuccess('dummy'));
  });

  setUp(() {
    mockRepository = MockMintRepository();
    mockWalletManager = MockWalletManager();
    mockRpcService = MockSolanaRpcService();
    mockPipeline = MockTransactionPipeline();
    mockPriceService = MockTokenPriceService();
    mockExecutor = MockTransactionExecutor();
    mockEditPrefill = MockEditNftPrefillService();

    when(mockWalletManager.getAddress()).thenAnswer((_) async => address);
    when(mockRepository.fetchTxFees()).thenAnswer((_) async => null);
  });

  testWidgets(
    'a master-edition mint offers the collection picker — the backend accepts '
    'a parent for one and the mint builder already sends the group signer',
    (tester) async {
      final bloc = buildBloc()
        ..add(const MintEvent.setMintType(MintCreateType.editions));
      addTearDown(bloc.close);

      await pumpDetails(tester, bloc);

      expect(find.text('Choose a collection'), findsOneWidget);
    },
  );

  // The webapp counts `Buffer.from(name).length` — UTF-8 bytes — for both the
  // cap and the "characters remaining" caption (`Details`).
  // Counting Dart characters let a creator type 32 emoji (128 bytes) into a
  // title the webapp refuses at 8, and the two clients disagreed on how much
  // room was left for any non-ASCII title.
  testWidgets('the title counter and cap are measured in UTF-8 bytes', (
    tester,
  ) async {
    final bloc = buildBloc()
      ..add(const MintEvent.setMintType(MintCreateType.oneOfOne));
    addTearDown(bloc.close);

    await pumpDetails(tester, bloc);

    // 4 emoji = 16 bytes of the 32-byte budget, but only 8 Dart characters.
    await tester.enterText(find.byType(TextField).first, '🎨🎨🎨🎨');
    await tester.pump();
    expect(find.text('16 characters remaining'), findsOneWidget);

    // 9 emoji is 36 bytes — over budget, so the edit is refused outright and
    // the field keeps the last accepted value.
    await tester.enterText(find.byType(TextField).first, '🎨' * 9);
    await tester.pump();
    expect(bloc.state.name, '🎨🎨🎨🎨');
  });

  testWidgets('a 1/1 mint keeps the picker it always had', (tester) async {
    final bloc = buildBloc()
      ..add(const MintEvent.setMintType(MintCreateType.oneOfOne));
    addTearDown(bloc.close);

    await pumpDetails(tester, bloc);

    expect(find.text('Choose a collection'), findsOneWidget);
  });

  testWidgets(
    'a collection mint has no picker — a collection is never nested inside '
    'another one (webapp routes it to CollectionDetails)',
    (tester) async {
      final bloc = buildBloc()
        ..add(const MintEvent.setMintType(MintCreateType.collection));
      addTearDown(bloc.close);

      await pumpDetails(tester, bloc);

      expect(find.text('Choose a collection'), findsNothing);
    },
  );

  testWidgets('an edit of a master edition already in a collection shows that '
      'collection by name — a pill reading "no collection" would invite the '
      'user to re-pick a parent it never left', (tester) async {
    when(mockEditPrefill.load(any)).thenAnswer(
      (_) async => const EditNftPrefill(
        mintAccount: 'MasterEd1t10n1111111111111111111111111111111',
        tokenStandard: TokenStandard.coreCollection,
        name: 'My edition',
        description: 'desc',
        attributes: [],
        tags: [],
        nsfw: false,
        sellerFeeBasisPoints: 500,
        creators: [],
        isMasterEdition: true,
        isCollection: false,
        maxSupply: 10,
        currentSupply: 0,
        isMutable: true,
        collection: MintCollectionRef(
          mintAccount: 'PaReNt1111111111111111111111111111111111111',
          tokenStandard: TokenStandard.coreCollection,
        ),
        collectionName: 'Parent Collection',
      ),
    );
    when(
      mockRepository.fetchAttachedUnlockableContentIds(any),
    ).thenAnswer((_) async => const <int>[]);

    final bloc = buildBloc()
      ..add(
        const MintEvent.startedForEdit(
          mintAccount: 'MasterEd1t10n1111111111111111111111111111111',
        ),
      );
    addTearDown(bloc.close);

    await pumpDetails(tester, bloc);
    await tester.pump();
    await tester.pump();

    expect(find.text('Parent Collection'), findsOneWidget);
    expect(find.text('Choose a collection'), findsNothing);
  });

  // Backing out of the picker and choosing "No collection" used to be the same
  // `null`. On a master edition the second one is an irreversible on-chain
  // detach (`RemoveCollectionsFromGroupV1`), so a stray swipe must not commit
  // one.
  group('picker dismissal', () {
    late MintCollectionChoice? result;
    var returned = false;

    Future<void> pumpPicker(WidgetTester tester) async {
      result = null;
      returned = false;
      when(
        mockRepository.listCollectionsForCreator(any),
      ).thenAnswer((_) async => const <CollectionPreviewRender>[]);
      if (sl.isRegistered<MintRepository>()) sl.unregister<MintRepository>();
      sl.registerSingleton<MintRepository>(mockRepository);
      addTearDown(() {
        if (sl.isRegistered<MintRepository>()) sl.unregister<MintRepository>();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showMintCollectionPicker(
                    context: context,
                    userPubkey: address,
                  );
                  returned = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('backing out leaves the current selection alone', (
      tester,
    ) async {
      await pumpPicker(tester);
      // Swipe the sheet away without picking anything.
      await tester.fling(
        find.text('Choose a collection'),
        const Offset(0, 500),
        2000,
      );
      await tester.pumpAndSettle();

      expect(returned, isTrue);
      expect(result, isNull);
    });

    testWidgets('choosing "No collection" is an explicit clear', (
      tester,
    ) async {
      await pumpPicker(tester);
      await tester.tap(find.text('No collection'));
      await tester.pumpAndSettle();

      expect(returned, isTrue);
      expect(result, isNotNull);
      expect(result!.selection, isNull);
    });

    testWidgets('the no-collection row has no stand-alone subtitle', (
      tester,
    ) async {
      await pumpPicker(tester);

      expect(find.text('No collection'), findsOneWidget);
      expect(find.text('Mint as a stand-alone artwork'), findsNothing);

      await tester.tap(find.text('No collection'));
      await tester.pumpAndSettle();
    });
  });
}
