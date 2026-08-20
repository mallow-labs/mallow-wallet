import 'dart:async';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/core/services/fee_config.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/services/transaction_pipeline.dart';
import 'package:mallow_wallet/features/mint/data/edit_prefill.dart';
import 'package:mallow_wallet/features/mint/data/mint_repository.dart';
import 'package:mallow_wallet/features/mint/models/mint_form_models.dart';
import 'package:mallow_wallet/features/mint/models/picked_mint_asset.dart';
import 'package:mallow_wallet/features/mint/services/mint_bloc.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:solana/solana.dart' show Ed25519HDKeyPair;

import 'mint_bloc_test.mocks.dart';

@GenerateMocks([
  MintRepository,
  WalletManager,
  SolanaRpcService,
  TransactionPipeline,
  TokenPriceService,
  TransactionExecutor,
  EditNftPrefillService,
  SessionManager,
  AuthService,
])
void main() {
  late MockMintRepository mockRepository;
  late MockWalletManager mockWalletManager;
  late MockSolanaRpcService mockRpcService;
  late MockTransactionPipeline mockPipeline;
  late MockTokenPriceService mockPriceService;
  late MockTransactionExecutor mockExecutor;
  late MockEditNftPrefillService mockEditPrefill;
  late MockSessionManager mockSession;
  late MockAuthService mockAuth;

  const testWalletAddress = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const testMintAccount = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
  const testSignature =
      '5wHu1qwD7TjGq5mXg1hXNxoZMmcMvisPLfkxGqzxJxbVnC4ZDvDpKsWvBsYxSxSvGmEzMfZZVFKLiCjMrpLnBqTJ';

  final testMainAsset = PickedMintAsset(
    fileName: 'art.png',
    mimeType: 'image/png',
    sizeBytes: 100,
    bytes: Uint8List(0),
    ipfsUrl: 'https://pin-gw.example.com/ipfs/Qmtest',
  );

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

  /// Stub the executor to walk awaitingApproval → broadcasting then return a
  /// successful signature. The bloc only forwards these stage events onto its
  /// own pipeline status, so simulating them here pins the status ordering
  /// without exercising the real sign/broadcast machinery (covered by the
  /// executor's own tests).
  void stubExecutorSuccess() {
    when(
      mockExecutor.execute(
        txsBase64: anyNamed('txsBase64'),
        usdValue: anyNamed('usdValue'),
        flow: anyNamed('flow'),
        additionalSigners: anyNamed('additionalSigners'),
        onStage: anyNamed('onStage'),
        tracker: anyNamed('tracker'),
        useLedger: anyNamed('useLedger'),
      ),
    ).thenAnswer((inv) async {
      final onStage =
          inv.namedArguments[#onStage] as void Function(ExecutorStageEvent)?;
      onStage?.call(
        const ExecutorStageEvent(
          stage: ExecutorStage.awaitingApproval,
          index: 0,
          total: 1,
        ),
      );
      onStage?.call(
        const ExecutorStageEvent(
          stage: ExecutorStage.broadcasting,
          index: 0,
          total: 1,
        ),
      );
      return const ResultSuccess(testSignature);
    });
  }

  setUpAll(() {
    // Mockito cannot auto-generate dummy values for sealed freezed types
    // or generic Result types.
    provideDummy<PickedMintAsset>(
      PickedMintAsset(
        fileName: 'dummy.png',
        mimeType: 'image/png',
        sizeBytes: 0,
        bytes: Uint8List(0),
      ),
    );
    provideDummy<ApiResponse<UnsignedTxResponse>>(
      const ApiResponse<UnsignedTxResponse>(
        result: UnsignedTxResponse(tx: 'dummy'),
      ),
    );
    provideDummy<Result<String, AppFailure>>(const ResultSuccess('dummy'));
  });

  // Captured from the stubbed `runIndexerCheck` by the indexer-gating test.
  void Function(String, bool)? capturedAck;
  bool capturedRequireEntry = false;

  setUp(() {
    capturedAck = null;
    capturedRequireEntry = false;
    mockRepository = MockMintRepository();
    mockWalletManager = MockWalletManager();
    mockRpcService = MockSolanaRpcService();
    mockPipeline = MockTransactionPipeline();
    mockPriceService = MockTokenPriceService();
    mockExecutor = MockTransactionExecutor();
    mockEditPrefill = MockEditNftPrefillService();
    mockSession = MockSessionManager();
    mockAuth = MockAuthService();

    // The bloc resolves the edit-signer auto-switch through the global service
    // locator (`sl<SessionManager>()`), and the failure/cancel signer-restore
    // (`restoreSigner`) reads `sl<AuthService>().currentAddress`, so register
    // both mocks there.
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    sl.registerSingleton<SessionManager>(mockSession);
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
    sl.registerSingleton<AuthService>(mockAuth);
    // Default to a null active address: `activeSignerSnapshot()` then resolves
    // to null, so tests that don't opt into the auto-switch capture no signer
    // and skip the restore entirely (matches the no-switch case).
    when(mockAuth.currentAddress).thenReturn(null);

    when(
      mockWalletManager.getAddress(),
    ).thenAnswer((_) async => testWalletAddress);
    when(mockWalletManager.isLocalSigner()).thenAnswer((_) async => true);
    // runIndexerCheck has returnValueForMissingStub: null, so the mocked
    // pipeline never invokes `onAck`. The confirm flow now *waits* for that
    // ack before declaring success (webapp parity: checkTx → checkEntry →
    // finalize → Success), so collapse the backstop to zero here — tests that
    // care about the wait stub `runIndexerCheck` explicitly and restore it.
    mintIndexedAckTimeout = Duration.zero;
    // The confirm flow now always prices the gate (falling back to the static
    // cost breakdown when simulation hasn't run), so usdValueOfRaw is always
    // called. The executor — and the gate it owns — is mocked here, so the
    // exact value is immaterial; stub a benign price so the call doesn't throw.
    when(mockPriceService.usdValueOfRaw(any, any)).thenReturn(1.0);
  });

  tearDown(() {
    mintIndexedAckTimeout = const Duration(seconds: 60);
    mintFinalizeWaitTimeout = const Duration(seconds: 30);
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
  });

  group('MintBloc.confirmMint', () {
    group('create mode', () {
      late Ed25519HDKeyPair mintKeypair;

      /// Stands in for a backend finalize that never answers. Fresh per test so
      /// a stall in one can't leak into the next.
      late Completer<void> stalledFinalize;

      final seedState = MintState(
        userPubkey: testWalletAddress,
        name: 'Test Artwork',
        description: 'A test.',
        mainAsset: testMainAsset,
      );

      setUpAll(() async {
        mintKeypair = await Ed25519HDKeyPair.random();
      });

      setUp(() {
        stalledFinalize = Completer<void>();
        // Upload returns the same asset unchanged (ipfsUrl already set in seed).
        when(mockRepository.uploadAsset(any)).thenAnswer(
          (inv) async => inv.positionalArguments[0] as PickedMintAsset,
        );
        when(
          mockRepository.uploadMetadata(any),
        ).thenAnswer((_) async => 'https://pin-gw.example.com/ipfs/QmMetadata');
        when(
          mockRepository.generateMintKeypair(),
        ).thenAnswer((_) async => mintKeypair);
        when(mockRepository.buildMintNftTx(any)).thenAnswer(
          (_) async => const ApiResponse<UnsignedTxResponse>(
            result: UnsignedTxResponse(tx: 'dummyTxBase64'),
          ),
        );
        when(
          mockRepository.finalize(
            mintAccount: anyNamed('mintAccount'),
            txIds: anyNamed('txIds'),
            type: anyNamed('type'),
          ),
        ).thenAnswer((_) async {});
        stubExecutorSuccess();
      });

      blocTest<MintBloc, MintState>(
        'stages through uploading → buildingTx → awaitingApproval → broadcasting → finalizing → success',
        build: buildBloc,
        seed: () => seedState,
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        // The confirm flow now waits on the indexer ack before it flips to
        // success (webapp parity, see the gating test above) — finalize runs
        // concurrently with that wait — so the run needs an extra async hop
        // past the zero backstop `setUp` installs for the mocked pipeline.
        wait: const Duration(milliseconds: 100),
        expect: () => [
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.uploading,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.buildingTx,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.awaitingApproval,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.broadcasting,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.finalizing,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.success,
          ),
        ],
      );

      // The success sheet's "View artwork" routes straight to
      // `/artwork/:mint`, which 404s until the marketplace entry is indexed.
      // The webapp therefore awaits `checkTx` *and* `checkEntry` before it
      // finalizes and flips to Success (`Mint`,
      // `EditNft`); declaring success on broadcast alone sends the
      // creator to a dead page for the artwork they just paid to mint.
      blocTest<MintBloc, MintState>(
        'holds at finalizing until the indexer acks, gating on the entry',
        build: () {
          // Real backstop so the assertion below measures the ack, not the
          // zero-timeout escape hatch the other tests run with.
          mintIndexedAckTimeout = const Duration(seconds: 30);
          when(
            mockPipeline.runIndexerCheck(
              signature: anyNamed('signature'),
              onAck: anyNamed('onAck'),
              isClosed: anyNamed('isClosed'),
              requireEntry: anyNamed('requireEntry'),
              delay: anyNamed('delay'),
            ),
          ).thenAnswer((inv) {
            capturedRequireEntry =
                inv.namedArguments[#requireEntry] as bool? ?? false;
            capturedAck =
                inv.namedArguments[#onAck] as void Function(String, bool);
          });
          return buildBloc();
        },
        seed: () => seedState,
        act: (bloc) async {
          bloc.add(const MintEvent.confirmMint());
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(bloc.state.pipelineStatus, MintPipelineStatus.finalizing);
          // `checkTx` acks within tens of milliseconds — strictly before the
          // marketplace entry lands — so the tx-level ack alone would not have
          // closed the 404 window.
          expect(capturedRequireEntry, isTrue);
          // …but only the *success emission* gates on the ack. Finalize is
          // backend bookkeeping for a tx that is already confirmed on-chain,
          // so it must already have fired while the ack is still outstanding.
          verify(
            mockRepository.finalize(
              mintAccount: anyNamed('mintAccount'),
              txIds: anyNamed('txIds'),
              type: anyNamed('type'),
            ),
          ).called(1);
          capturedAck!(testSignature, true);
        },
        verify: (bloc) {
          expect(bloc.state.pipelineStatus, MintPipelineStatus.success);
          expect(bloc.state.indexed, isTrue);
        },
      );

      // `runIndexerCheck`'s `isClosed` guards swallow `onAck` outright when the
      // user backs out of the mint flow, parking the handler on the full
      // backstop. Finalize does backend bookkeeping (e.g. unlockable-content
      // association) for a mint that is ALREADY confirmed on-chain, so it must
      // not be sequenced behind that wait — an OS suspend/kill in the window
      // would otherwise drop it permanently.
      blocTest<MintBloc, MintState>(
        'finalizes even when the indexer ack never arrives, without waiting '
        'out the backstop first',
        build: () {
          // Non-zero backstop so the ack wait is genuinely outstanding while
          // the assertion below runs; short enough to keep the test fast. The
          // mocked pipeline never invokes `onAck` (missing-stub returns null),
          // which is exactly the swallowed-ack case.
          mintIndexedAckTimeout = const Duration(milliseconds: 400);
          return buildBloc();
        },
        seed: () => seedState,
        act: (bloc) async {
          bloc.add(const MintEvent.confirmMint());
          await Future<void>.delayed(const Duration(milliseconds: 150));
          // Still parked on the backstop — the ack never came…
          expect(bloc.state.pipelineStatus, MintPipelineStatus.finalizing);
          // …yet the backend bookkeeping has already run.
          verify(
            mockRepository.finalize(
              mintAccount: anyNamed('mintAccount'),
              txIds: anyNamed('txIds'),
              type: anyNamed('type'),
            ),
          ).called(1);
        },
        wait: const Duration(milliseconds: 500),
        verify: (bloc) {
          // The backstop still releases success once it expires.
          expect(bloc.state.pipelineStatus, MintPipelineStatus.success);
        },
      );

      // Finalize is bookkeeping for a mint that is ALREADY confirmed on-chain,
      // and its failure is swallowed either way — so a wedged backend must not
      // hold the creator on "Finalizing…" for the whole retry budget (3
      // attempts on a 30 s-timeout Dio ≈ 90 s) before it can see the artwork it
      // just paid for.
      blocTest<MintBloc, MintState>(
        'stops waiting on a stalled finalize and still declares success',
        build: () {
          mintFinalizeWaitTimeout = const Duration(milliseconds: 200);
          when(
            mockRepository.finalize(
              mintAccount: anyNamed('mintAccount'),
              txIds: anyNamed('txIds'),
              type: anyNamed('type'),
            ),
          ).thenAnswer((_) => stalledFinalize.future);
          return buildBloc();
        },
        seed: () => seedState,
        act: (bloc) async {
          bloc.add(const MintEvent.confirmMint());
          await Future<void>.delayed(const Duration(milliseconds: 100));
          // Still inside the wait — success hasn't been declared early.
          expect(bloc.state.pipelineStatus, MintPipelineStatus.finalizing);
          await Future<void>.delayed(const Duration(milliseconds: 250));
        },
        verify: (bloc) {
          expect(bloc.state.pipelineStatus, MintPipelineStatus.success);
          // The timeout only stopped the *waiting*: the call was never
          // cancelled, so it is still outstanding and free to land later.
          expect(stalledFinalize.isCompleted, isFalse);
        },
      );

      blocTest<MintBloc, MintState>(
        'wires the ephemeral mint keypair into additionalSigners',
        build: buildBloc,
        seed: () => seedState,
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        // The verify block captures additionalSigners from the executor call.
        verify: (_) {
          final captured = verify(
            mockExecutor.execute(
              txsBase64: anyNamed('txsBase64'),
              usdValue: anyNamed('usdValue'),
              flow: anyNamed('flow'),
              additionalSigners: captureAnyNamed('additionalSigners'),
              onStage: anyNamed('onStage'),
              tracker: anyNamed('tracker'),
              useLedger: anyNamed('useLedger'),
            ),
          ).captured;
          final signers = (captured.first as List).cast<Ed25519HDKeyPair>();
          // Create flows always pass the ephemeral mint keypair so the on-chain
          // program can verify the new mint account's signature.
          expect(signers, hasLength(1));
          expect(
            signers.first.publicKey.toBase58(),
            mintKeypair.publicKey.toBase58(),
          );
        },
      );

      blocTest<MintBloc, MintState>(
        'emits pipelineStatus.error when the executor returns a failure',
        setUp: () {
          when(
            mockExecutor.execute(
              txsBase64: anyNamed('txsBase64'),
              usdValue: anyNamed('usdValue'),
              flow: anyNamed('flow'),
              additionalSigners: anyNamed('additionalSigners'),
              onStage: anyNamed('onStage'),
              tracker: anyNamed('tracker'),
              useLedger: anyNamed('useLedger'),
            ),
          ).thenAnswer(
            (_) async =>
                const ResultFailure(AppFailure.unknown('wallet rejected')),
          );
        },
        build: buildBloc,
        seed: () => seedState,
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        expect: () => [
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.uploading,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.buildingTx,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.awaitingApproval,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.error,
          ),
        ],
      );

      blocTest<MintBloc, MintState>(
        'emits error immediately when mainAsset is null in create mode (no network calls)',
        build: buildBloc,
        seed: () => const MintState(userPubkey: testWalletAddress),
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        expect: () => [
          isA<MintState>()
              .having(
                (s) => s.pipelineStatus,
                'pipelineStatus',
                MintPipelineStatus.error,
              )
              .having(
                (s) => s.pipelineError,
                'pipelineError',
                'Main artwork is required.',
              ),
        ],
        verify: (_) {
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
    });

    group('edit mode', () {
      // An existing mint with no freshly-picked assets, so the confirm pipeline
      // skips the IPFS upload phase and walks straight through
      // buildTx → sign → broadcast → finalize. Keeps the test focused on the
      // pipeline-status ordering rather than upload mechanics.
      MintState editSeed() => const MintState(
        userPubkey: testWalletAddress,
        editMintAccount: testMintAccount,
        name: 'Edited name',
        description: 'Edited description',
      );

      setUp(() {
        when(
          mockRepository.uploadMetadata(any),
        ).thenAnswer((_) async => 'ipfs://metadata');
        when(mockRepository.buildEditNftTx(any)).thenAnswer(
          (_) async => const ApiResponse<UnsignedTxResponse>(
            result: UnsignedTxResponse(tx: 'unsigned-tx'),
          ),
        );
        when(
          mockRepository.finalizeEdit(
            mintAccount: anyNamed('mintAccount'),
            txIds: anyNamed('txIds'),
          ),
        ).thenAnswer((_) async {});
        stubExecutorSuccess();
      });

      blocTest<MintBloc, MintState>(
        'stages through buildingTx → awaitingApproval → broadcasting → finalizing → success',
        build: buildBloc,
        seed: editSeed,
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        // The confirm flow now waits on the indexer ack before it flips to
        // success (webapp parity, see the gating test above) — finalize runs
        // concurrently with that wait — so the run needs an extra async hop
        // past the zero backstop `setUp` installs for the mocked pipeline.
        wait: const Duration(milliseconds: 100),
        expect: () => [
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.buildingTx,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.awaitingApproval,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.broadcasting,
          ),
          isA<MintState>()
              .having(
                (s) => s.pipelineStatus,
                'pipelineStatus',
                MintPipelineStatus.finalizing,
              )
              .having((s) => s.mintSignature, 'mintSignature', testSignature),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.success,
          ),
        ],
        verify: (_) {
          // Edit reuses the existing mint account, so it signs with the user's
          // key alone — no ephemeral signer. This is the mirror of create
          // mode's "wires the ephemeral mint keypair" assertion.
          final captured = verify(
            mockExecutor.execute(
              txsBase64: anyNamed('txsBase64'),
              usdValue: anyNamed('usdValue'),
              flow: anyNamed('flow'),
              additionalSigners: captureAnyNamed('additionalSigners'),
              onStage: anyNamed('onStage'),
              tracker: anyNamed('tracker'),
              useLedger: anyNamed('useLedger'),
            ),
          ).captured;
          expect(captured.first, isEmpty);
          verify(
            mockRepository.finalizeEdit(
              mintAccount: testMintAccount,
              txIds: anyNamed('txIds'),
            ),
          ).called(1);
        },
      );

      // The asset being edited is authored by a *non-active* signable session
      // wallet. Before building the edit tx the bloc must re-point the active
      // signer to that update authority (belt-and-suspenders behind the edit
      // screen's own `ensureSigner`), so `buildEditNftTx` is authored by the
      // update authority — not the wallet that happened to be active.
      const updateAuthority = 'Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS';
      const authorityWallet = WalletInfo(
        id: 'ua-wallet',
        address: updateAuthority,
        name: 'authority wallet',
        walletType: WalletType.hd,
        chain: 'solana',
      );
      // The wallet that is active *before* an edit re-points to the update
      // authority — the one a failed/cancelled edit must be restored to.
      const previousWallet = WalletInfo(
        id: 'active-wallet',
        address: testWalletAddress,
        name: 'active wallet',
        walletType: WalletType.hd,
        chain: 'solana',
      );

      // Wire the auto-switch to the update authority and mirror the resulting
      // active-address flip, so the pre-edit signer is [previousWallet] and the
      // post-switch signer is [authorityWallet]. `currentAddress` starts at the
      // active wallet (so `activeSignerSnapshot()` captures [previousWallet])
      // and flips to the authority once switched (so `restoreSigner`'s
      // "already active" short-circuit doesn't suppress the restore) — the same
      // flip the app-level session listener performs in production.
      void stubAuthoritySwitch() {
        when(
          mockSession.sessionWalletForAddress(updateAuthority),
        ).thenReturn(authorityWallet);
        when(
          mockSession.resolveWalletForAddress(updateAuthority),
        ).thenReturn(authorityWallet);
        when(
          mockSession.sessionWalletForAddress(testWalletAddress),
        ).thenReturn(previousWallet);
        when(
          mockSession.resolveWalletForAddress(testWalletAddress),
        ).thenReturn(previousWallet);
        when(mockAuth.currentAddress).thenReturn(testWalletAddress);
        when(mockSession.selectSourceWallet(authorityWallet)).thenAnswer((
          _,
        ) async {
          when(
            mockWalletManager.getAddress(),
          ).thenAnswer((_) async => updateAuthority);
          when(mockAuth.currentAddress).thenReturn(updateAuthority);
        });
      }

      blocTest<MintBloc, MintState>(
        'auto-switches the signer to the update authority before '
        'buildEditNftTx when it differs from the active wallet',
        setUp: () {
          when(
            mockSession.sessionWalletForAddress(updateAuthority),
          ).thenReturn(authorityWallet);
          when(
            mockSession.resolveWalletForAddress(updateAuthority),
          ).thenReturn(authorityWallet);
          // Switching the source wallet flips what the wallet manager reports
          // as the active address — mirror that so the built tx authority
          // reflects the post-switch signer.
          when(mockSession.selectSourceWallet(authorityWallet)).thenAnswer((
            _,
          ) async {
            when(
              mockWalletManager.getAddress(),
            ).thenAnswer((_) async => updateAuthority);
          });
        },
        build: buildBloc,
        seed: () => editSeed().copyWith(editUpdateAuthority: updateAuthority),
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        verify: (_) {
          verify(mockSession.selectSourceWallet(authorityWallet)).called(1);
          final req =
              verify(mockRepository.buildEditNftTx(captureAny)).captured.single
                  as EditNftV2Request;
          expect(req.authority, updateAuthority);
        },
      );

      blocTest<MintBloc, MintState>(
        'does NOT switch the signer when the update authority is already the '
        'active wallet',
        seed: () => editSeed().copyWith(editUpdateAuthority: testWalletAddress),
        setUp: () {
          when(
            mockSession.sessionWalletForAddress(testWalletAddress),
          ).thenReturn(
            const WalletInfo(
              id: 'active-wallet',
              address: testWalletAddress,
              name: 'active wallet',
              walletType: WalletType.hd,
              chain: 'solana',
            ),
          );
        },
        build: buildBloc,
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        verify: (_) {
          verifyNever(mockSession.selectSourceWallet(any));
          final req =
              verify(mockRepository.buildEditNftTx(captureAny)).captured.single
                  as EditNftV2Request;
          expect(req.authority, testWalletAddress);
        },
      );

      blocTest<MintBloc, MintState>(
        'collection edit builds the webapp-parity v2 body '
        '(editTarget=parent_collection, createType=editCollection, no '
        'collection/maxSupply) and finalizes with type=editCollection so '
        'the backend queues UpdateCollectionMetadata instead of '
        'UpdateNftMetadata',
        setUp: () {
          when(
            mockRepository.finalizeEdit(
              mintAccount: anyNamed('mintAccount'),
              txIds: anyNamed('txIds'),
              type: anyNamed('type'),
            ),
          ).thenAnswer((_) async {});
        },
        build: buildBloc,
        seed: () => editSeed().copyWith(
          mintType: MintCreateType.collection,
          editTokenStandard: TokenStandard.coreCollection,
        ),
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        // The confirm flow now waits on the indexer ack before it flips to
        // success (webapp parity, see the gating test above) — finalize runs
        // concurrently with that wait — so the run needs an extra async hop
        // past the zero backstop `setUp` installs for the mocked pipeline.
        wait: const Duration(milliseconds: 100),
        expect: () => [
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.buildingTx,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.awaitingApproval,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.broadcasting,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.finalizing,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.success,
          ),
        ],
        verify: (_) {
          final req =
              verify(mockRepository.buildEditNftTx(captureAny)).captured.single
                  as EditNftV2Request;
          expect(req.editTarget, EditNftV2EditTarget.parentCollection);
          expect(req.createType, 'editCollection');
          expect(req.tokenStandard, TokenStandard.coreCollection);
          // The backend's `collection` is a double-option: an absent field
          // means "leave group membership untouched", and a present
          // maxSupply would read as a master-edition supply change.
          expect(req.collection, isNull);
          expect(req.maxSupply, isNull);
          verify(
            mockRepository.finalizeEdit(
              mintAccount: testMintAccount,
              txIds: anyNamed('txIds'),
              type: 'editCollection',
            ),
          ).called(1);
        },
      );

      // The v2 edit route reads an EMPTY `unlockableContentIds` as an
      // explicit clear and emits `RemoveExternalPluginAdapter`
      // (the backend's `append_app_data_ixs`), so these
      // three cases are the difference between a creator fixing a typo and a
      // creator destroying the collector's exclusive content.
      blocTest<MintBloc, MintState>(
        'round-trips the unlockable-content ids already on the asset so the '
        'edit does not clear the on-chain AppData plugin',
        build: buildBloc,
        seed: () =>
            editSeed().copyWith(exclusiveContentExistingIds: const [42, 7]),
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        verify: (_) {
          final req =
              verify(mockRepository.buildEditNftTx(captureAny)).captured.single
                  as EditNftV2Request;
          expect(req.unlockableContentIds, const [42, 7]);
        },
      );

      blocTest<MintBloc, MintState>(
        'sends an empty unlockableContentIds for a parent-collection edit — '
        'the backend rejects the field with editTarget=parent_collection and '
        'that path never touches the AppData plugin',
        setUp: () {
          when(
            mockRepository.finalizeEdit(
              mintAccount: anyNamed('mintAccount'),
              txIds: anyNamed('txIds'),
              type: anyNamed('type'),
            ),
          ).thenAnswer((_) async {});
        },
        build: buildBloc,
        seed: () => editSeed().copyWith(
          mintType: MintCreateType.collection,
          editTokenStandard: TokenStandard.coreCollection,
          exclusiveContentExistingIds: const [42],
        ),
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        verify: (_) {
          final req =
              verify(mockRepository.buildEditNftTx(captureAny)).captured.single
                  as EditNftV2Request;
          expect(req.unlockableContentIds, isEmpty);
        },
      );

      blocTest<MintBloc, MintState>(
        'refuses to build the edit at all when the attached-content lookup '
        'failed — guessing [] would strip the plugin',
        build: buildBloc,
        seed: () => editSeed().copyWith(unlockableContentUnknown: true),
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        expect: () => [
          isA<MintState>()
              .having(
                (s) => s.pipelineStatus,
                'pipelineStatus',
                MintPipelineStatus.error,
              )
              .having(
                (s) => s.pipelineError,
                'pipelineError',
                contains('exclusive content'),
              ),
        ],
        verify: (_) {
          verifyNever(mockRepository.buildEditNftTx(any));
        },
      );

      blocTest<MintBloc, MintState>(
        'emits error (and never finalizes) when the executor returns a failure',
        setUp: () {
          when(
            mockExecutor.execute(
              txsBase64: anyNamed('txsBase64'),
              usdValue: anyNamed('usdValue'),
              flow: anyNamed('flow'),
              additionalSigners: anyNamed('additionalSigners'),
              onStage: anyNamed('onStage'),
              tracker: anyNamed('tracker'),
              useLedger: anyNamed('useLedger'),
            ),
          ).thenAnswer(
            (_) async =>
                const ResultFailure(AppFailure.unknown('wallet rejected')),
          );
        },
        build: buildBloc,
        seed: editSeed,
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        expect: () => [
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.buildingTx,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.awaitingApproval,
          ),
          isA<MintState>()
              .having(
                (s) => s.pipelineStatus,
                'pipelineStatus',
                MintPipelineStatus.error,
              )
              .having((s) => s.pipelineError, 'pipelineError', isNotNull),
        ],
        verify: (_) {
          verifyNever(
            mockRepository.finalizeEdit(
              mintAccount: anyNamed('mintAccount'),
              txIds: anyNamed('txIds'),
            ),
          );
        },
      );

      blocTest<MintBloc, MintState>(
        'carries a kill-switch failure onto pipelineFailure so the host can '
        'show the operator copy instead of "Update failed"',
        setUp: () {
          when(
            mockExecutor.execute(
              txsBase64: anyNamed('txsBase64'),
              usdValue: anyNamed('usdValue'),
              flow: anyNamed('flow'),
              additionalSigners: anyNamed('additionalSigners'),
              onStage: anyNamed('onStage'),
              tracker: anyNamed('tracker'),
              useLedger: anyNamed('useLedger'),
            ),
          ).thenAnswer(
            (_) async => const ResultFailure(
              AppFailure.flowDisabled('Edits are paused. Your NFT is safe.'),
            ),
          );
        },
        build: buildBloc,
        seed: editSeed,
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        skip: 2, // buildingTx, awaitingApproval
        expect: () => [
          isA<MintState>()
              .having(
                (s) => s.pipelineStatus,
                'pipelineStatus',
                MintPipelineStatus.error,
              )
              .having(
                (s) => s.pipelineFailure?.isFlowDisabled,
                'pipelineFailure.isFlowDisabled',
                isTrue,
              )
              // Verbatim — never "Mint failed: …".
              .having(
                (s) => s.pipelineError,
                'pipelineError',
                'Edits are paused. Your NFT is safe.',
              ),
        ],
        // The host reads this to tag the analytics event with the same cell the
        // backstop refused (this seed is a 1/1 edit, not a collection edit).
        verify: (bloc) => expect(bloc.flowCell, AppFlow.nftEdit),
      );

      blocTest<MintBloc, MintState>(
        'still reaches success when finalize fails after a confirmed '
        'broadcast — the tx is already on-chain, so a finalize hiccup must '
        'not surface as "Mint failed"',
        setUp: () {
          // Group setUp already stubs finalizeEdit to succeed; override it to
          // fail so we exercise the post-broadcast finalize-resilience path.
          when(
            mockRepository.finalizeEdit(
              mintAccount: anyNamed('mintAccount'),
              txIds: anyNamed('txIds'),
            ),
          ).thenThrow(Exception('finalize 500'));
        },
        build: buildBloc,
        seed: editSeed,
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        // Finalize retries with backoff (~1.2s) before giving up, so give the
        // bloc room to emit success after the failed attempts.
        wait: const Duration(seconds: 2),
        expect: () => [
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.buildingTx,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.awaitingApproval,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.broadcasting,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.finalizing,
          ),
          isA<MintState>().having(
            (s) => s.pipelineStatus,
            'pipelineStatus',
            MintPipelineStatus.success,
          ),
        ],
        verify: (_) {
          // Finalize is retried before the flow gives up and proceeds.
          verify(
            mockRepository.finalizeEdit(
              mintAccount: testMintAccount,
              txIds: anyNamed('txIds'),
            ),
          ).called(3);
        },
      );

      // The signer-switch is durable (SessionManager.selectSourceWallet persists
      // it), so a failed/cancelled edit that already re-pointed the active wallet
      // to a different update authority must restore the pre-edit signer — never
      // leave the user's active wallet silently switched.
      blocTest<MintBloc, MintState>(
        'restores the pre-edit signer when building the edit tx throws after '
        'the auto-switch',
        setUp: () {
          stubAuthoritySwitch();
          // Build fails *after* the switch — the exact class of failure this
          // guards against (backend 500 / network drop mid-edit).
          when(
            mockRepository.buildEditNftTx(any),
          ).thenThrow(Exception('build 500'));
        },
        build: buildBloc,
        seed: () => editSeed().copyWith(editUpdateAuthority: updateAuthority),
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        verify: (_) {
          // Switched to the authority, then restored to the pre-edit signer.
          verify(mockSession.selectSourceWallet(authorityWallet)).called(1);
          verify(mockSession.selectSourceWallet(previousWallet)).called(1);
        },
      );

      blocTest<MintBloc, MintState>(
        'restores the pre-edit signer when the user cancels auth '
        '(TransactionAuthCancelled) after the auto-switch',
        setUp: () {
          stubAuthoritySwitch();
          // User backs out at the auth gate — surfaces as a cancel that lands
          // in the same catch as any other failure.
          when(
            mockExecutor.execute(
              txsBase64: anyNamed('txsBase64'),
              usdValue: anyNamed('usdValue'),
              flow: anyNamed('flow'),
              additionalSigners: anyNamed('additionalSigners'),
              onStage: anyNamed('onStage'),
              tracker: anyNamed('tracker'),
              useLedger: anyNamed('useLedger'),
            ),
          ).thenAnswer((_) async => throw TransactionAuthCancelledException());
        },
        build: buildBloc,
        seed: () => editSeed().copyWith(editUpdateAuthority: updateAuthority),
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        verify: (_) {
          verify(mockSession.selectSourceWallet(authorityWallet)).called(1);
          verify(mockSession.selectSourceWallet(previousWallet)).called(1);
        },
      );

      blocTest<MintBloc, MintState>(
        'keeps the signer switched to the update authority on a successful edit '
        '(no restore)',
        setUp: stubAuthoritySwitch,
        build: buildBloc,
        seed: () => editSeed().copyWith(editUpdateAuthority: updateAuthority),
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        verify: (_) {
          // A confirmed edit intentionally leaves the signer on the authority —
          // only the forward switch happens, never a restore.
          verify(mockSession.selectSourceWallet(authorityWallet)).called(1);
          verifyNever(mockSession.selectSourceWallet(previousWallet));
        },
      );
    });
  });

  // Prefill has to learn which unlockable-content records are attached to the
  // asset *before* the user can save, because the v2 edit route treats an
  // empty id list as "remove the plugin".
  group('MintBloc.startedForEdit unlockable content', () {
    const prefill = EditNftPrefill(
      mintAccount: testMintAccount,
      tokenStandard: TokenStandard.core,
      name: 'Art',
      description: 'd',
      attributes: [],
      tags: [],
      nsfw: false,
      sellerFeeBasisPoints: 1000,
      creators: [MintCreator(address: testWalletAddress, share: 100)],
      isMasterEdition: false,
      isCollection: false,
      maxSupply: 0,
      currentSupply: 0,
      isMutable: true,
      existingImageUrl: 'ipfs://art.png',
    );

    setUp(() {
      when(mockRepository.fetchTxFees()).thenAnswer((_) async => null);
      when(mockEditPrefill.load(any)).thenAnswer((_) async => prefill);
    });

    blocTest<MintBloc, MintState>(
      'seeds the attached ids into state so the edit request can round-trip '
      'them',
      setUp: () {
        when(
          mockRepository.fetchAttachedUnlockableContentIds(testMintAccount),
        ).thenAnswer((_) async => const [11, 12]);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(
        const MintEvent.startedForEdit(mintAccount: testMintAccount),
      ),
      verify: (bloc) {
        expect(bloc.state.exclusiveContentExistingIds, const [11, 12]);
        expect(bloc.state.unlockableContentUnknown, isFalse);
      },
    );

    blocTest<MintBloc, MintState>(
      'flags the lookup as unknown when it fails instead of defaulting to an '
      'empty list, which the backend would execute as a plugin removal',
      setUp: () {
        when(
          mockRepository.fetchAttachedUnlockableContentIds(testMintAccount),
        ).thenAnswer((_) async => null);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(
        const MintEvent.startedForEdit(mintAccount: testMintAccount),
      ),
      verify: (bloc) {
        expect(bloc.state.exclusiveContentExistingIds, isEmpty);
        expect(bloc.state.unlockableContentUnknown, isTrue);
      },
    );

    blocTest<MintBloc, MintState>(
      'never looks the ids up for a collection edit — the v2 route rejects '
      'the field there and a collection mint is not in the artwork index',
      build: buildBloc,
      act: (bloc) => bloc.add(
        const MintEvent.startedForEdit(
          mintAccount: testMintAccount,
          isCollection: true,
        ),
      ),
      verify: (bloc) {
        verifyNever(mockRepository.fetchAttachedUnlockableContentIds(any));
        expect(bloc.state.unlockableContentUnknown, isFalse);
      },
    );
  });

  // The mint source picker commits the wallet switch
  // itself; this event is what stops the *form* from carrying the previous
  // wallet's identity and numbers into the tx. The wallet it picks is written
  // on-chain as the creator and can never be changed, so "some state survived
  // the switch" is not a cosmetic bug here.
  group('MintBloc.sourceWalletChanged', () {
    const switchedAddress = '4Nd1mYQ1a4Ux9hZbFjRxHVpQeQaB1jJ1nJvBQuBLCZ3F';
    const coCreator = '2zTdfnJqQ8jNPDrEXpDqYQoHhgH3RqvzZzYmBRnkgLcw';

    /// Mirror the durable switch the picker already committed: the DB-backed
    /// active address (what every mint tx builder reads) is now the new wallet.
    void stubSwitchedWallet() {
      when(
        mockWalletManager.getAddress(),
      ).thenAnswer((_) async => switchedAddress);
    }

    /// Let the follow-up cost simulation run to completion so the re-derived
    /// fee estimate is observable. [cost] lamports leave the payer.
    void stubSimulation({required int cost}) {
      when(
        mockRepository.generateMintKeypair(),
      ).thenAnswer((_) async => Ed25519HDKeyPair.random());
      when(mockRepository.buildMintNftTx(any)).thenAnswer(
        (_) async => const ApiResponse<UnsignedTxResponse>(
          result: UnsignedTxResponse(tx: 'simTxBase64'),
        ),
      );
      when(
        mockRpcService.simulateWithDelta(
          address: anyNamed('address'),
          simulate: anyNamed('simulate'),
          requirePreBalance: anyNamed('requirePreBalance'),
        ),
      ).thenAnswer(
        (_) async => SimulationDelta(
          result: const SimulationResult(success: true),
          lamportsDelta: -cost,
        ),
      );
    }

    final seedState = MintState(
      userPubkey: testWalletAddress,
      name: 'Test Artwork',
      description: 'A test.',
      mainAsset: testMainAsset,
      creators: const [
        MintCreatorInput(address: testWalletAddress, shareText: '60'),
        MintCreatorInput(address: coCreator, shareText: '40'),
      ],
      simulatedTxCostLamports: 999999,
    );

    blocTest<MintBloc, MintState>(
      're-points the on-chain creator at the newly-active wallet, keeping the '
      "self row's share and any hand-added co-creators",
      setUp: () {
        stubSwitchedWallet();
        stubSimulation(cost: 4200);
      },
      build: buildBloc,
      seed: () => seedState.copyWith(
        creators: [
          const MintCreatorInput(
            address: testWalletAddress,
            shareText: '60',
            isSelf: true,
          ),
          const MintCreatorInput(address: coCreator, shareText: '40'),
        ],
      ),
      act: (bloc) => bloc.add(const MintEvent.sourceWalletChanged()),
      wait: const Duration(milliseconds: 50),
      verify: (bloc) {
        expect(bloc.state.userPubkey, switchedAddress);
        expect(bloc.state.creators.first.address, switchedAddress);
        expect(bloc.state.creators.first.isSelf, isTrue);
        expect(bloc.state.creators.first.shareText, '60');
        expect(bloc.state.creators[1].address, coCreator);
      },
    );

    blocTest<MintBloc, MintState>(
      'discards the fee estimate simulated for the previous wallet and '
      're-simulates against the new payer',
      setUp: () {
        stubSwitchedWallet();
        stubSimulation(cost: 4200);
      },
      build: buildBloc,
      seed: () => seedState,
      act: (bloc) => bloc.add(const MintEvent.sourceWalletChanged()),
      wait: const Duration(milliseconds: 50),
      verify: (bloc) {
        // Not the seeded 999999 — the estimate is the new wallet's.
        expect(bloc.state.simulatedTxCostLamports, 4200);
        // And the simulation inspected the new payer, not the old one.
        verify(
          mockRpcService.simulateWithDelta(
            address: switchedAddress,
            simulate: anyNamed('simulate'),
            requirePreBalance: anyNamed('requirePreBalance'),
          ),
        ).called(1);
        verifyNever(
          mockRpcService.simulateWithDelta(
            address: testWalletAddress,
            simulate: anyNamed('simulate'),
            requirePreBalance: anyNamed('requirePreBalance'),
          ),
        );
      },
    );

    blocTest<MintBloc, MintState>(
      'drops the parent collection — the picker only lists collections the '
      'previous wallet created, so the new one cannot mint into it',
      setUp: () {
        stubSwitchedWallet();
        stubSimulation(cost: 4200);
      },
      build: buildBloc,
      seed: () => seedState.copyWith(
        collection: const MintCollectionRef(
          mintAccount: testMintAccount,
          tokenStandard: TokenStandard.core,
        ),
        collectionName: 'Previous wallet collection',
      ),
      act: (bloc) => bloc.add(const MintEvent.sourceWalletChanged()),
      wait: const Duration(milliseconds: 50),
      verify: (bloc) {
        expect(bloc.state.collection, isNull);
        expect(bloc.state.collectionName, isNull);
        expect(bloc.state.userPubkey, switchedAddress);
      },
    );

    blocTest<MintBloc, MintState>(
      'leaves the form on the previous wallet when the address cannot be '
      'resolved — a stale creator is worse than no change',
      setUp: () {
        when(mockWalletManager.getAddress()).thenThrow(Exception('db closed'));
      },
      build: buildBloc,
      seed: () => seedState,
      act: (bloc) => bloc.add(const MintEvent.sourceWalletChanged()),
      wait: const Duration(milliseconds: 50),
      expect: () => const <MintState>[],
      verify: (bloc) {
        expect(bloc.state.userPubkey, testWalletAddress);
        // Nothing re-simulated, nothing built — the flow never advances on a
        // switch that didn't land.
        verifyNever(mockRepository.buildMintNftTx(any));
      },
    );

    blocTest<MintBloc, MintState>(
      'is a no-op in edit mode — the authority is the asset\'s update '
      'authority, not a user choice',
      build: buildBloc,
      seed: () => seedState.copyWith(
        editMintAccount: testMintAccount,
        userPubkey: testWalletAddress,
      ),
      act: (bloc) => bloc.add(const MintEvent.sourceWalletChanged()),
      wait: const Duration(milliseconds: 50),
      expect: () => const <MintState>[],
      verify: (bloc) {
        expect(bloc.state.userPubkey, testWalletAddress);
        verifyNever(mockWalletManager.getAddress());
      },
    );
  });

  // The v2 builders reserve the group-rent subsidy slot, persist an
  // `NftUpload` row, and auth-sign — unless the body says `dryRun: true`,
  // which gates all three server-side. The cost preview runs every
  // time the confirm sheet opens, so a non-dry preview silently spends the
  // subsidy the *real* mint was going to use and leaves an orphan upload row
  // behind on every abandoned sheet. These tests pin the two call sites apart.
  group('cost preview vs. real submit (dryRun)', () {
    void stubSimulation() {
      when(
        mockRepository.generateMintKeypair(),
      ).thenAnswer((_) async => Ed25519HDKeyPair.random());
      when(mockRepository.buildMintNftTx(any)).thenAnswer(
        (_) async => const ApiResponse<UnsignedTxResponse>(
          result: UnsignedTxResponse(tx: 'simTxBase64'),
        ),
      );
      when(mockRepository.buildEditNftTx(any)).thenAnswer(
        (_) async => const ApiResponse<UnsignedTxResponse>(
          result: UnsignedTxResponse(tx: 'simTxBase64'),
        ),
      );
      when(
        mockRpcService.simulateWithDelta(
          address: anyNamed('address'),
          simulate: anyNamed('simulate'),
          requirePreBalance: anyNamed('requirePreBalance'),
        ),
      ).thenAnswer(
        (_) async => const SimulationDelta(
          result: SimulationResult(success: true),
          lamportsDelta: -4200,
        ),
      );
    }

    void stubConfirmPipeline() {
      when(mockRepository.uploadAsset(any)).thenAnswer(
        (inv) async => inv.positionalArguments[0] as PickedMintAsset,
      );
      when(
        mockRepository.uploadMetadata(any),
      ).thenAnswer((_) async => 'https://pin-gw.example.com/ipfs/QmMetadata');
      when(
        mockRepository.generateMintKeypair(),
      ).thenAnswer((_) async => Ed25519HDKeyPair.random());
      when(mockRepository.buildMintNftTx(any)).thenAnswer(
        (_) async => const ApiResponse<UnsignedTxResponse>(
          result: UnsignedTxResponse(tx: 'dummyTxBase64'),
        ),
      );
      when(mockRepository.buildEditNftTx(any)).thenAnswer(
        (_) async => const ApiResponse<UnsignedTxResponse>(
          result: UnsignedTxResponse(tx: 'dummyTxBase64'),
        ),
      );
      when(
        mockRepository.finalize(
          mintAccount: anyNamed('mintAccount'),
          txIds: anyNamed('txIds'),
          type: anyNamed('type'),
        ),
      ).thenAnswer((_) async {});
      when(
        mockRepository.finalizeEdit(
          mintAccount: anyNamed('mintAccount'),
          txIds: anyNamed('txIds'),
          type: anyNamed('type'),
        ),
      ).thenAnswer((_) async {});
      stubExecutorSuccess();
    }

    final createSeed = MintState(
      userPubkey: testWalletAddress,
      name: 'Test Artwork',
      description: 'A test.',
      mainAsset: testMainAsset,
    );

    const editSeed = MintState(
      userPubkey: testWalletAddress,
      editMintAccount: testMintAccount,
      existingMetadataUri: 'https://pin-gw.example.com/ipfs/QmExisting',
      name: 'Edited name',
      description: 'Edited description',
    );

    blocTest<MintBloc, MintState>(
      'mint cost preview is a dry run',
      setUp: stubSimulation,
      build: buildBloc,
      seed: () => createSeed,
      act: (bloc) => bloc.add(const MintEvent.simulateTxCost()),
      wait: const Duration(milliseconds: 50),
      verify: (_) {
        final req =
            verify(mockRepository.buildMintNftTx(captureAny)).captured.single
                as MintNftV2Request;
        expect(req.dryRun, isTrue);
      },
    );

    blocTest<MintBloc, MintState>(
      'the mint the user signs is NOT a dry run — a dry-run body is never '
      'auth-signed and never persists the upload record',
      setUp: stubConfirmPipeline,
      build: buildBloc,
      seed: () => createSeed,
      act: (bloc) => bloc.add(const MintEvent.confirmMint()),
      wait: const Duration(milliseconds: 50),
      verify: (_) {
        final req =
            verify(mockRepository.buildMintNftTx(captureAny)).captured.single
                as MintNftV2Request;
        expect(req.dryRun, isFalse);
      },
    );

    blocTest<MintBloc, MintState>(
      'edit cost preview is a dry run',
      setUp: stubSimulation,
      build: buildBloc,
      seed: () => editSeed,
      act: (bloc) => bloc.add(const MintEvent.simulateTxCost()),
      wait: const Duration(milliseconds: 50),
      verify: (_) {
        final req =
            verify(mockRepository.buildEditNftTx(captureAny)).captured.single
                as EditNftV2Request;
        expect(req.dryRun, isTrue);
      },
    );

    blocTest<MintBloc, MintState>(
      'the edit the user signs is NOT a dry run',
      setUp: stubConfirmPipeline,
      build: buildBloc,
      seed: () => editSeed,
      act: (bloc) => bloc.add(const MintEvent.confirmMint()),
      wait: const Duration(milliseconds: 50),
      verify: (_) {
        final req =
            verify(mockRepository.buildEditNftTx(captureAny)).captured.single
                as EditNftV2Request;
        expect(req.dryRun, isFalse);
      },
    );
  });

  // A Master Edition's link to its parent Core Collection is an mpl-core
  // Group, not the asset's update authority — so the plain `collection` field
  // does nothing for it. Moving one needs `newParentCollection`
  // (+ `newGroupSigner` when the destination has no group yet), and clearing
  // one needs an *explicit* `collection: null`; an omitted field reads as
  // "leave membership untouched". Without these the
  // edit still costs the user the edit fee and changes nothing.
  group('master-edition parent collection edit', () {
    const oldParent = 'PaReNt1111111111111111111111111111111111111';
    const newParent = 'PaReNt2222222222222222222222222222222222222';

    setUp(() {
      when(
        mockRepository.uploadMetadata(any),
      ).thenAnswer((_) async => 'https://pin-gw.example.com/ipfs/QmMetadata');
      when(
        mockRepository.generateMintKeypair(),
      ).thenAnswer((_) async => Ed25519HDKeyPair.random());
      when(mockRepository.buildEditNftTx(any)).thenAnswer(
        (_) async => const ApiResponse<UnsignedTxResponse>(
          result: UnsignedTxResponse(tx: 'dummyTxBase64'),
        ),
      );
      when(
        mockRepository.finalizeEdit(
          mintAccount: anyNamed('mintAccount'),
          txIds: anyNamed('txIds'),
          type: anyNamed('type'),
        ),
      ).thenAnswer((_) async {});
      stubExecutorSuccess();
    });

    MintState masterEditionSeed({
      required String? currentParent,
      required String? pickedParent,
    }) => MintState(
      userPubkey: testWalletAddress,
      editMintAccount: testMintAccount,
      isMasterEditionEdit: true,
      mintType: MintCreateType.editions,
      editTokenStandard: TokenStandard.coreCollection,
      existingMetadataUri: 'https://pin-gw.example.com/ipfs/QmExisting',
      name: 'Edited name',
      description: 'Edited description',
      preEditCollectionMint: currentParent,
      collection: pickedParent == null
          ? null
          : const MintCollectionRef(
              mintAccount: newParent,
              tokenStandard: TokenStandard.coreCollection,
            ),
    );

    // The whole tri-state hinges on the prefill knowing the current parent. If
    // it came back null for a grouped Master Edition, `requiresUpdate` would
    // report a change for an edit the user never made, and the picker would
    // invite them to re-pick a parent the asset never left.
    blocTest<MintBloc, MintState>(
      'a prefilled parent makes an untouched master-edition edit a no-op — '
      'unchanged must never look like cleared',
      setUp: () {
        when(mockRepository.fetchTxFees()).thenAnswer((_) async => null);
        when(
          mockRepository.fetchAttachedUnlockableContentIds(any),
        ).thenAnswer((_) async => const <int>[]);
        when(mockEditPrefill.load(any)).thenAnswer(
          (_) async => const EditNftPrefill(
            mintAccount: testMintAccount,
            tokenStandard: TokenStandard.coreCollection,
            name: 'Art',
            description: 'd',
            attributes: [],
            tags: [],
            nsfw: false,
            sellerFeeBasisPoints: 1000,
            creators: [MintCreator(address: testWalletAddress, share: 100)],
            isMasterEdition: true,
            isCollection: false,
            maxSupply: 10,
            currentSupply: 0,
            isMutable: true,
            existingImageUrl: 'ipfs://art.png',
            collection: MintCollectionRef(
              mintAccount: oldParent,
              tokenStandard: TokenStandard.coreCollection,
            ),
            collectionName: 'Parent Collection',
          ),
        );
      },
      build: buildBloc,
      act: (bloc) => bloc.add(
        const MintEvent.startedForEdit(mintAccount: testMintAccount),
      ),
      verify: (bloc) {
        expect(bloc.state.preEditCollectionMint, oldParent);
        expect(bloc.state.collection?.mintAccount, oldParent);
        expect(bloc.state.collectionName, 'Parent Collection');
        expect(bloc.state.requiresUpdate, isFalse);
      },
    );

    EditNftV2Request capturedEditRequest() =>
        verify(mockRepository.buildEditNftTx(captureAny)).captured.single
            as EditNftV2Request;

    blocTest<MintBloc, MintState>(
      'clearing the parent sends an explicit collection:null so the backend '
      'emits RemoveCollectionsFromGroup instead of a no-op',
      build: buildBloc,
      seed: () =>
          masterEditionSeed(currentParent: oldParent, pickedParent: null),
      act: (bloc) => bloc.add(const MintEvent.confirmMint()),
      wait: const Duration(milliseconds: 50),
      verify: (_) {
        final req = capturedEditRequest();
        expect(req.collection, const EditNftV2CollectionUpdate.detach());
        expect(req.collection!.isDetach, isTrue);
        // Detach and move are mutually exclusive on the backend.
        expect(req.newParentCollection, isNull);
        expect(req.newGroupSigner, isNull);
      },
    );

    blocTest<MintBloc, MintState>(
      'moving to a different parent sends newParentCollection plus a '
      'newGroupSigner — without the signer the backend 400s when the '
      'destination has no group yet',
      build: buildBloc,
      seed: () =>
          masterEditionSeed(currentParent: oldParent, pickedParent: newParent),
      act: (bloc) => bloc.add(const MintEvent.confirmMint()),
      wait: const Duration(milliseconds: 50),
      verify: (_) {
        final req = capturedEditRequest();
        expect(req.newParentCollection, newParent);
        expect(req.newGroupSigner, isNotNull);
        // Webapp parity (`EditNft`): the ref is sent alongside.
        expect(req.collection?.ref?.asset, newParent);
      },
    );

    blocTest<MintBloc, MintState>(
      'an unchanged parent omits the re-parent fields and keeps the ref — '
      'a metadata-only edit must not touch group membership',
      build: buildBloc,
      seed: () =>
          masterEditionSeed(currentParent: newParent, pickedParent: newParent),
      act: (bloc) => bloc.add(const MintEvent.confirmMint()),
      wait: const Duration(milliseconds: 50),
      verify: (_) {
        final req = capturedEditRequest();
        expect(req.newParentCollection, isNull);
        expect(req.newGroupSigner, isNull);
        expect(req.collection?.isDetach, isFalse);
        expect(req.collection?.ref?.asset, newParent);
      },
    );

    blocTest<MintBloc, MintState>(
      'a 1/1 asset never gets the master-edition fields — the backend rejects '
      'newParentCollection and collection:null for anything but a Master '
      'Edition, and a plain Core asset detaches via the omitted field',
      build: buildBloc,
      seed: () => const MintState(
        userPubkey: testWalletAddress,
        editMintAccount: testMintAccount,
        editTokenStandard: TokenStandard.core,
        existingMetadataUri: 'https://pin-gw.example.com/ipfs/QmExisting',
        name: 'Edited name',
        description: 'Edited description',
        preEditCollectionMint: oldParent,
      ),
      act: (bloc) => bloc.add(const MintEvent.confirmMint()),
      wait: const Duration(milliseconds: 50),
      verify: (_) {
        final req = capturedEditRequest();
        expect(req.collection, isNull);
        expect(req.newParentCollection, isNull);
        expect(req.newGroupSigner, isNull);
      },
    );

    // The backend rejects `collection: null` together with
    // `newParentCollection`, and the user pays
    // the build round-trip either way, so the two must be unreachable
    // together rather than merely discouraged. They key off the same picked
    // value, so no UI state can produce both.
    for (final picked in <String?>[null, newParent]) {
      blocTest<MintBloc, MintState>(
        'detach and re-parent are never requested together '
        '(picked parent: ${picked ?? 'none'})',
        build: buildBloc,
        seed: () =>
            masterEditionSeed(currentParent: oldParent, pickedParent: picked),
        act: (bloc) => bloc.add(const MintEvent.confirmMint()),
        wait: const Duration(milliseconds: 50),
        verify: (_) {
          final req = capturedEditRequest();
          expect(
            req.collection?.isDetach == true && req.newParentCollection != null,
            isFalse,
          );
        },
      );
    }
  });

  // Un-gating the collection picker for master editions made this event
  // reachable during an edit for the first time. The webapp's inheritance
  // effect bails out on `isEdit` (`CreateContext`) — picking a
  // parent there only moves the asset. Inheriting the parent's royalties and
  // creator shares instead would silently rewrite an existing artwork's
  // on-chain payout split, which no confirmation screen surfaces.
  group('setCollection inheritance', () {
    const parentMint = 'PaReNt1111111111111111111111111111111111111';

    CollectionPreviewRender parentSource() => const CollectionPreviewRender(
      slug: parentMint,
      name: 'Parent Collection',
      imageUrl: 'https://img',
      tags: ['generative'],
      nft: CollectionPreviewNft(
        mintAccount: parentMint,
        royalties: CollectionRoyalties(
          feeBPS: 250,
          shares: [MintCreator(address: 'SomeOneE1se', share: 100)],
        ),
      ),
    );

    blocTest<MintBloc, MintState>(
      'an edit only moves the asset — the parent\'s royalties, creators and '
      'tags must not overwrite what is already on chain',
      build: buildBloc,
      seed: () => const MintState(
        userPubkey: testWalletAddress,
        editMintAccount: testMintAccount,
        isMasterEditionEdit: true,
        mintType: MintCreateType.editions,
        editTokenStandard: TokenStandard.coreCollection,
        royaltyPercent: '10',
        tags: ['photography'],
        creators: [MintCreatorInput(address: testWalletAddress, isSelf: true)],
      ),
      act: (bloc) => bloc.add(
        MintEvent.setCollection(
          collection: const MintCollectionRef(
            mintAccount: parentMint,
            tokenStandard: TokenStandard.coreCollection,
          ),
          name: 'Parent Collection',
          source: parentSource(),
        ),
      ),
      verify: (bloc) {
        expect(bloc.state.collection?.mintAccount, parentMint);
        expect(bloc.state.collectionName, 'Parent Collection');
        expect(bloc.state.royaltyPercent, '10');
        expect(bloc.state.tags, const ['photography']);
        expect(bloc.state.creators.single.address, testWalletAddress);
      },
    );

    blocTest<MintBloc, MintState>(
      'a create still inherits from the parent — that is where the webapp '
      'applies the collection defaults',
      build: buildBloc,
      seed: () => const MintState(
        userPubkey: testWalletAddress,
        mintType: MintCreateType.editions,
        royaltyPercent: '10',
      ),
      act: (bloc) => bloc.add(
        MintEvent.setCollection(
          collection: const MintCollectionRef(
            mintAccount: parentMint,
            tokenStandard: TokenStandard.coreCollection,
          ),
          name: 'Parent Collection',
          source: parentSource(),
        ),
      ),
      verify: (bloc) {
        expect(bloc.state.royaltyPercent, '2.5');
        expect(bloc.state.tags, const ['generative']);
      },
    );
  });

  // A Master Edition's max supply cannot be lowered below the number of
  // editions already printed — mpl-core rejects the underflow. The webapp
  // gates on it in the form (`Supply`,
  // `maxSupply == null || maxSupply >= nftRender.supply`); without the same
  // gate the creator pays a signature and the network fee for a transaction
  // that can only fail.
  group('MintState.canGoNext — edition supply floor', () {
    MintState editState({required int printed, required String supply}) =>
        MintState(
          step: MintStep.editionSupply,
          mintType: MintCreateType.editions,
          editMintAccount: 'EditMintAccount1111111111111111111111111111',
          editCurrentSupply: printed,
          editionSupply: supply,
        );

    test('blocks a supply below what has already been printed', () {
      expect(editState(printed: 25, supply: '10').canGoNext, isFalse);
    });

    test('allows a supply equal to the printed count', () {
      expect(editState(printed: 25, supply: '25').canGoNext, isTrue);
    });

    test('allows raising the supply', () {
      expect(editState(printed: 25, supply: '100').canGoNext, isTrue);
    });

    test('open edition is never blocked by the printed floor', () {
      expect(
        editState(
          printed: 25,
          supply: '10',
        ).copyWith(editionType: MintEditionType.open).canGoNext,
        isTrue,
      );
    });

    test('create mode keeps the plain [2, 10000] bounds', () {
      const create = MintState(
        step: MintStep.editionSupply,
        mintType: MintCreateType.editions,
        editionSupply: '10',
      );
      expect(create.canGoNext, isTrue);
      expect(create.copyWith(editionSupply: '1').canGoNext, isFalse);
      expect(create.copyWith(editionSupply: '10001').canGoNext, isFalse);
    });
  });
  // A royalty creator address is written into on-chain metadata that is
  // immutable for the life of the artwork. A character-class check accepts a
  // typo, the mint succeeds, and every future royalty payment goes to an
  // address nobody holds — there is no later gate that catches this. The
  // webapp decodes (`new PublicKey(address)`) in `Royalties`.
  group('creator address validation', () {
    const good = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';

    MintState withCreators(List<MintCreatorInput> creators) =>
        MintState(creators: creators);

    test('accepts a real pubkey', () {
      expect(
        withCreators(const [MintCreatorInput(address: good)]).creatorsError,
        isNull,
      );
    });

    test('rejects base58 that does not decode to 32 bytes', () {
      // 40 chars, valid base58, inside the old 32-44 heuristic window.
      expect(
        withCreators([
          MintCreatorInput(address: good.substring(0, 40)),
        ]).creatorsError,
        'Creator address is invalid',
      );
    });

    test('still reports an empty address ahead of validity', () {
      expect(
        withCreators(const [MintCreatorInput(address: '')]).creatorsError,
        'Each wallet needs an address',
      );
    });
  });
}
