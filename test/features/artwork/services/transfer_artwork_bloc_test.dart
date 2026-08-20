import 'dart:async';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mallow_wallet/core/security/biometric_auth.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx_tracker.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/services/evm_artwork_transfer_service.dart';
import 'package:mallow_wallet/features/artwork/services/transfer_artwork_bloc.dart';
import 'package:mallow_wallet/features/send/models/eth_gas.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:solana/dto.dart' show AccountResult, Context;
import 'package:solana/solana.dart'
    show Message, Token2022Program, TokenProgramType;

import 'transfer_artwork_bloc_test.mocks.dart';

/// A representative live fee market for the EVM simulate path.
EthGasMarket _market() => EthGasMarket.fromSuggestedGasFees(const {
  'low': {'suggestedMaxPriorityFeePerGas': '1', 'suggestedMaxFeePerGas': '20'},
  'medium': {
    'suggestedMaxPriorityFeePerGas': '2',
    'suggestedMaxFeePerGas': '24',
  },
  'estimatedBaseFee': '11',
});

const _mint = 'So11111111111111111111111111111111111111112';
// A Tezos NFT: `<KT1 contract>-<tokenId>` (the shape the v2 portfolio indexes).
const _tezosMint = 'KT1Xn4hDXpTfRoVvVhWpRvKrR8iV1ATQF3qJ-7';
// An EVM NFT: `<contract>-<tokenId>`.
const _evmMint = '0x1111111111111111111111111111111111111111-42';
// A valid base58 32-byte address used as the recipient in tests.
const _recipient = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const _source = 'Ata1111111111111111111111111111111111111111';
const _collection = 'Co11ection1111111111111111111111111111111111';
// An auxiliary (non-ATA) token account the wallet holds for [_mint]; distinct
// from any derived ATA so the simulate builder must spend from exactly this
// address for the message-source assertion to pass.
const _auxHolding = 'Aux11111111111111111111111111111111111111111';

DigitalAsset _asset(
  TokenStandard standard, {
  String? collectionKey,
  bool hasMasterEditionPlugin = false,
}) => DigitalAsset(
  id: _mint,
  tokenStandard: standard,
  isMutable: true,
  frozen: false,
  supply: 1,
  freezeDelegateFrozen: false,
  permanentFreezeDelegateFrozen: false,
  hasMasterEditionPlugin: hasMasterEditionPlugin,
  collectionKey: collectionKey,
);

@GenerateMocks([
  SolanaRpcService,
  WalletManager,
  DasApiService,
  TokenPriceService,
  TransactionExecutor,
  MallowApiV2Client,
  EvmArtworkTransferService,
  PreferencesService,
])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    provideDummy<Result<String, AppFailure>>(
      const ResultFailure(AppFailure.unknown('dummy')),
    );
    provideDummy<ApiResponse<TransferTxResponse>>(
      const ApiResponse<TransferTxResponse>(result: TransferTxResponse()),
    );
    // `anyNamed('tokenId')` on the non-nullable BigInt param needs a dummy.
    provideDummy<BigInt>(BigInt.zero);
  });

  late MockSolanaRpcService rpc;
  late MockWalletManager walletManager;
  late MockDasApiService dasApi;
  late MockTokenPriceService priceService;
  late MockTransactionExecutor executor;
  late MockMallowApiV2Client apiV2;
  late MockEvmArtworkTransferService evmService;
  late MockPreferencesService prefs;

  setUp(() {
    rpc = MockSolanaRpcService();
    walletManager = MockWalletManager();
    dasApi = MockDasApiService();
    priceService = MockTokenPriceService();
    executor = MockTransactionExecutor();
    apiV2 = MockMallowApiV2Client();
    evmService = MockEvmArtworkTransferService();
    prefs = MockPreferencesService();
    // The EVM simulate path now kicks the fee-market fetch off concurrently with
    // prepare (FINDING 8b), so it is always invoked — give it a default market;
    // individual tests override it (e.g. to fail).
    when(evmService.gasMarket()).thenAnswer((_) async => _market());
  });

  TransferArtworkBloc build() => TransferArtworkBloc(
    rpc,
    walletManager,
    dasApi,
    priceService,
    executor,
    apiV2,
    evmService,
    prefs,
  );

  group('started — token-standard gating', () {
    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'legacy NFT is supported (no unsupported reason)',
      setUp: () => when(
        dasApi.getAsset(_mint),
      ).thenAnswer((_) async => _asset(TokenStandard.nft)),
      build: build,
      act: (b) => b.add(const TransferArtworkEvent.started(_mint)),
      skip: 1, // skip the interim isCheckingStandard:true emit
      expect: () => [
        isA<TransferInput>()
            .having((s) => s.isCheckingStandard, 'isCheckingStandard', false)
            .having((s) => s.unsupportedReason, 'unsupportedReason', isNull),
      ],
    );

    for (final standard in [
      TokenStandard.pnft,
      TokenStandard.core,
      TokenStandard.cnft,
      // A Core collection "transfer" is an update-authority reassignment, built
      // by the same backend route (UpdateCollectionV1).
      TokenStandard.coreCollection,
    ]) {
      blocTest<TransferArtworkBloc, TransferArtworkState>(
        '${standard.name} is supported (built via the backend route)',
        setUp: () => when(
          dasApi.getAsset(_mint),
        ).thenAnswer((_) async => _asset(standard)),
        build: build,
        act: (b) => b.add(const TransferArtworkEvent.started(_mint)),
        skip: 1,
        expect: () => [
          isA<TransferInput>().having(
            (s) => s.unsupportedReason,
            'unsupportedReason',
            isNull,
          ),
        ],
      );
    }

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'a non-Solana standard is flagged unsupported',
      setUp: () => when(
        dasApi.getAsset(_mint),
      ).thenAnswer((_) async => _asset(TokenStandard.erc721)),
      build: build,
      act: (b) => b.add(const TransferArtworkEvent.started(_mint)),
      skip: 1,
      expect: () => [
        isA<TransferInput>().having(
          (s) => s.unsupportedReason,
          'unsupportedReason',
          isNotNull,
        ),
      ],
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'a DAS lookup failure stays optimistic (no block — simulation gates)',
      setUp: () =>
          when(dasApi.getAsset(_mint)).thenThrow(Exception('network down')),
      build: build,
      act: (b) => b.add(const TransferArtworkEvent.started(_mint)),
      skip: 1,
      expect: () => [
        isA<TransferInput>().having(
          (s) => s.unsupportedReason,
          'unsupportedReason',
          isNull,
        ),
      ],
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'Core collection warns about the update-authority handover but is not '
      'blocked',
      setUp: () => when(
        dasApi.getAsset(_mint),
      ).thenAnswer((_) async => _asset(TokenStandard.coreCollection)),
      build: build,
      act: (b) => b.add(const TransferArtworkEvent.started(_mint)),
      skip: 1,
      expect: () => [
        isA<TransferInput>()
            .having((s) => s.unsupportedReason, 'unsupportedReason', isNull)
            .having(
              (s) => s.advisoryNotice,
              'advisoryNotice',
              contains('update authority'),
            ),
      ],
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'a master-edition collection warns about losing print ability',
      setUp: () => when(dasApi.getAsset(_mint)).thenAnswer(
        (_) async =>
            _asset(TokenStandard.coreCollection, hasMasterEditionPlugin: true),
      ),
      build: build,
      act: (b) => b.add(const TransferArtworkEvent.started(_mint)),
      skip: 1,
      expect: () => [
        isA<TransferInput>().having(
          (s) => s.advisoryNotice,
          'advisoryNotice',
          allOf(contains('master edition'), contains('print')),
        ),
      ],
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'a plain supported asset carries no advisory notice',
      setUp: () => when(
        dasApi.getAsset(_mint),
      ).thenAnswer((_) async => _asset(TokenStandard.core)),
      build: build,
      act: (b) => b.add(const TransferArtworkEvent.started(_mint)),
      skip: 1,
      expect: () => [
        isA<TransferInput>().having(
          (s) => s.advisoryNotice,
          'advisoryNotice',
          isNull,
        ),
      ],
    );
  });

  group('recipient validation + canProceed', () {
    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'invalid address sets an error and blocks proceeding',
      setUp: () => when(
        dasApi.getAsset(_mint),
      ).thenAnswer((_) async => _asset(TokenStandard.nft)),
      build: build,
      act: (b) async {
        b.add(const TransferArtworkEvent.started(_mint));
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged('not-an-address'));
      },
      verify: (b) {
        final s = b.state as TransferInput;
        expect(s.recipientError, isNotNull);
        expect(b.state.canProceed, isFalse);
      },
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'valid recipient on a supported asset can proceed',
      setUp: () => when(
        dasApi.getAsset(_mint),
      ).thenAnswer((_) async => _asset(TokenStandard.nft)),
      build: build,
      act: (b) async {
        b.add(const TransferArtworkEvent.started(_mint));
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(_recipient));
      },
      verify: (b) {
        final s = b.state as TransferInput;
        expect(s.recipientError, isNull);
        expect(b.state.canProceed, isTrue);
      },
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'unsupported asset blocks proceeding even with a valid recipient',
      setUp: () => when(
        dasApi.getAsset(_mint),
      ).thenAnswer((_) async => _asset(TokenStandard.erc721)),
      build: build,
      act: (b) async {
        b.add(const TransferArtworkEvent.started(_mint));
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(_recipient));
      },
      verify: (b) => expect(b.state.canProceed, isFalse),
    );
  });

  group('backend build path (pNFT/Core/cNFT)', () {
    // Guards the wire contract the backend build path depends on: the route is
    // camelCase (`tokenStandard`), takes the kebab/lowercase enum wire value,
    // and is only hit for non-legacy standards. A snake_case regression here
    // would 422 on the real route, so this test must fail if the request shape
    // drifts.
    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'simulate requests a transfer tx with camelCase wire fields',
      setUp: () {
        when(dasApi.getAsset(_mint)).thenAnswer(
          (_) async => _asset(TokenStandard.core, collectionKey: _collection),
        );
        when(walletManager.getAddress()).thenAnswer((_) async => _source);
        when(apiV2.getTransferTx(any)).thenAnswer(
          (_) async => const ApiResponse<TransferTxResponse>(
            result: TransferTxResponse(tx: 'dHg='),
          ),
        );
        when(
          rpc.simulateWithDelta(
            address: anyNamed('address'),
            simulate: anyNamed('simulate'),
            requirePreBalance: anyNamed('requirePreBalance'),
          ),
        ).thenAnswer(
          (_) async => const SimulationDelta(
            result: SimulationResult(success: true),
            lamportsDelta: -5000,
          ),
        );
      },
      build: build,
      act: (b) async {
        b.add(const TransferArtworkEvent.started(_mint));
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(_recipient));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) {
        final req =
            verify(apiV2.getTransferTx(captureAny)).captured.single
                as TransferTxRequest;
        expect(req.tokenStandard.value, 'core');
        expect(req.asset, _mint);
        expect(req.recipient, _recipient);
        expect(req.authority, _source);
        // The contract is camelCase on the wire — snake_case would 422.
        expect(req.toJson()['tokenStandard'], 'core');
      },
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'Core collection transfers via the backend with the core-collection wire value',
      setUp: () {
        when(
          dasApi.getAsset(_mint),
        ).thenAnswer((_) async => _asset(TokenStandard.coreCollection));
        when(walletManager.getAddress()).thenAnswer((_) async => _source);
        when(apiV2.getTransferTx(any)).thenAnswer(
          (_) async => const ApiResponse<TransferTxResponse>(
            result: TransferTxResponse(tx: 'dHg='),
          ),
        );
        when(
          rpc.simulateWithDelta(
            address: anyNamed('address'),
            simulate: anyNamed('simulate'),
            requirePreBalance: anyNamed('requirePreBalance'),
          ),
        ).thenAnswer(
          (_) async => const SimulationDelta(
            result: SimulationResult(success: true),
            lamportsDelta: -5000,
          ),
        );
      },
      build: build,
      act: (b) async {
        b.add(const TransferArtworkEvent.started(_mint));
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(_recipient));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) {
        final req =
            verify(apiV2.getTransferTx(captureAny)).captured.single
                as TransferTxRequest;
        expect(req.toJson()['tokenStandard'], 'core-collection');
      },
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'legacy NFT never calls the backend transfer route',
      setUp: () {
        when(
          dasApi.getAsset(_mint),
        ).thenAnswer((_) async => _asset(TokenStandard.nft));
        when(walletManager.getAddress()).thenAnswer((_) async => _source);
        when(
          rpc.requireOwnedTokenAccount(
            owner: anyNamed('owner'),
            mint: anyNamed('mint'),
          ),
        ).thenThrow(Exception('stop before simulate'));
      },
      build: build,
      act: (b) async {
        b.add(const TransferArtworkEvent.started(_mint));
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(_recipient));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) => verifyNever(apiV2.getTransferTx(any)),
    );

    // The legacy simulate builder must spend from the account the wallet
    // actually holds (which may be an auxiliary, non-ATA account) under the
    // token program the live holding reports — the same resolution the
    // executed transaction uses via [SolanaRpcService.buildSplTransferTx]. A
    // regression to deriving the source ATA or guessing classic SPL would make
    // the simulated message diverge from what executes.
    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'legacy simulate spends from the live holding address + program',
      setUp: () {
        when(
          dasApi.getAsset(_mint),
        ).thenAnswer((_) async => _asset(TokenStandard.nft));
        when(walletManager.getAddress()).thenAnswer((_) async => _source);
        // A distinctive non-ATA holding on Token-2022: if the code regressed to
        // deriving the source ATA (or guessing classic SPL) this address/program
        // would not appear in the built message.
        when(
          rpc.requireOwnedTokenAccount(
            owner: anyNamed('owner'),
            mint: anyNamed('mint'),
          ),
        ).thenAnswer(
          (_) async => (
            address: _auxHolding,
            program: TokenProgramType.token2022Program,
            amount: 1,
          ),
        );
        // Destination ATA doesn't exist → a create-ATA ix precedes the transfer
        // ix, so the transfer ix is the last instruction we assert on.
        when(
          rpc.getAccountInfo(any, encoding: anyNamed('encoding')),
        ).thenAnswer(
          (_) async =>
              AccountResult(context: Context(slot: BigInt.zero), value: null),
        );
        // Drive the delta helper so it actually invokes the passed `simulate`
        // callback, which builds and forwards the message to simulateMessage.
        when(
          rpc.simulateWithDelta(
            address: anyNamed('address'),
            simulate: anyNamed('simulate'),
            requirePreBalance: anyNamed('requirePreBalance'),
          ),
        ).thenAnswer((inv) async {
          final simulate =
              inv.namedArguments[#simulate]
                  as Future<SimulationResult> Function(List<String>);
          await simulate(const []);
          return const SimulationDelta(
            result: SimulationResult(success: true),
            lamportsDelta: -5000,
          );
        });
        when(
          rpc.simulateMessage(
            captureAny,
            inspectAccounts: anyNamed('inspectAccounts'),
          ),
        ).thenAnswer((_) async => const SimulationResult(success: true));
      },
      build: build,
      act: (b) async {
        b.add(const TransferArtworkEvent.started(_mint));
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(_recipient));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) {
        final message =
            verify(
                  rpc.simulateMessage(
                    captureAny,
                    inspectAccounts: anyNamed('inspectAccounts'),
                  ),
                ).captured.single
                as Message;
        final transferIx = message.instructions.last;
        // Transfer ix is addressed to the live holding's program …
        expect(transferIx.programId.toBase58(), Token2022Program.programId);
        // … and spends from the live holding account (the source is the first
        // account meta on an SPL transfer ix), not a derived ATA.
        expect(transferIx.accounts.first.pubKey.toBase58(), _auxHolding);
        // The mint's classic-SPL program was never consulted for resolution.
        verifyNever(rpc.getTokenProgramTypeForMint(any));
      },
    );
  });

  group('EVM (erc721/erc1155)', () {
    // `<contract>-<tokenId>` mint key + a checksummed 0x recipient.
    const evmMint = '0x1111111111111111111111111111111111111111-42';
    const evmRecipient = '0x2222222222222222222222222222222222222222';
    // The asset's on-chain holder — a non-active session ETH wallet.
    const evmHolder = '0x3333333333333333333333333333333333333333';

    PreparedEvmTransfer prepared() => PreparedEvmTransfer(
      walletId: 'w2',
      source: evmHolder,
      to: '0x1111111111111111111111111111111111111111',
      data: Uint8List(0),
      valueWei: BigInt.zero,
      estimatedGasUsed: BigInt.from(60000),
      gasLimit: 72000,
      maxFeePerGas: BigInt.from(21),
      maxPriorityFeePerGas: BigInt.from(1),
      feeWei: BigInt.from(100),
      recipientIsContract: false,
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'ERC-721 routes to the EVM path — no DAS lookup, EVM validation',
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc721',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(evmRecipient));
      },
      skip: 1, // drop the interim isCheckingStandard:true emit
      // EVM assets must never hit the Solana-only DAS API.
      verify: (_) => verifyNever(dasApi.getAsset(any)),
      expect: () => [
        // isCheckingStandard=false + isEvm=true after start resolves.
        isA<TransferInput>()
            .having((s) => s.isEvm, 'isEvm', true)
            .having((s) => s.isCheckingStandard, 'checking', false),
        // A valid 0x recipient produces no error.
        isA<TransferInput>().having(
          (s) => s.recipientError,
          'recipientError',
          isNull,
        ),
      ],
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'ERC-721 rejects a Solana address as the recipient',
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc721',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(_recipient));
      },
      skip: 2, // drop the interim + resolved-standard input emits
      expect: () => [
        isA<TransferInput>().having(
          (s) => s.recipientError,
          'recipientError',
          'Invalid Ethereum address',
        ),
      ],
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'ERC-1155 loads the owned balance as the quantity ceiling',
      setUp: () {
        when(
          evmService.ownedErc1155Amount(
            contract: anyNamed('contract'),
            tokenId: anyNamed('tokenId'),
          ),
        ).thenAnswer((_) async => BigInt.from(5));
      },
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc1155',
          ),
        );
        await Future<void>.delayed(Duration.zero);
      },
      skip: 1, // drop the interim isCheckingStandard:true emit
      verify: (_) {
        verify(
          evmService.ownedErc1155Amount(
            contract: '0x1111111111111111111111111111111111111111',
            tokenId: BigInt.from(42),
          ),
        ).called(1);
      },
      expect: () => [
        isA<TransferInput>()
            .having((s) => s.isEvm, 'isEvm', true)
            .having((s) => s.maxQuantity, 'maxQuantity', 5),
      ],
    );

    // WHY: with the holder resolved to the session wallet that actually holds
    // the copy, a genuine zero balance means the transfer cannot succeed — the
    // pre-sign simulation would hard-fail. Surface it as unsupported (blocks
    // proceeding) rather than clamping the picker up to 1 and marching the user
    // into that dead end.
    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'ERC-1155 with a zero owned balance is flagged unsupported (no clamp-up)',
      setUp: () {
        when(
          evmService.ownedErc1155Amount(
            contract: anyNamed('contract'),
            tokenId: anyNamed('tokenId'),
          ),
        ).thenAnswer((_) async => BigInt.zero);
      },
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc1155',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(evmRecipient));
      },
      skip: 1, // drop the interim isCheckingStandard:true emit
      verify: (b) => expect(b.state.canProceed, isFalse),
      expect: () => [
        isA<TransferInput>()
            .having((s) => s.isEvm, 'isEvm', true)
            .having((s) => s.unsupportedReason, 'unsupportedReason', isNotNull),
        // A valid recipient still cannot rescue the blocked state.
        isA<TransferInput>().having(
          (s) => s.unsupportedReason,
          'unsupportedReason',
          isNotNull,
        ),
      ],
    );

    // A transient balance-read failure must NOT block a real holder: it stays a
    // soft fallback to a quantity of 1 (the simulation gate remains the safety
    // net), distinct from a definitive zero balance above.
    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'ERC-1155 balance-read failure falls back to quantity 1, not blocked',
      setUp: () {
        when(
          evmService.ownedErc1155Amount(
            contract: anyNamed('contract'),
            tokenId: anyNamed('tokenId'),
          ),
        ).thenThrow(Exception('rpc down'));
      },
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc1155',
          ),
        );
        await Future<void>.delayed(Duration.zero);
      },
      skip: 1, // drop the interim isCheckingStandard:true emit
      expect: () => [
        isA<TransferInput>()
            .having((s) => s.isEvm, 'isEvm', true)
            .having((s) => s.maxQuantity, 'maxQuantity', 1)
            .having((s) => s.unsupportedReason, 'unsupportedReason', isNull),
      ],
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'a blocked EVM simulation disables Send (failed simulationResult)',
      setUp: () {
        when(
          evmService.prepare(
            contract: anyNamed('contract'),
            tokenId: anyNamed('tokenId'),
            standard: anyNamed('standard'),
            recipient: anyNamed('recipient'),
            amount: anyNamed('amount'),
          ),
        ).thenThrow(
          const EvmTransferBlockedException('This transfer would do X'),
        );
      },
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc721',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(evmRecipient));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
      },
      skip: 1, // drop the interim isCheckingStandard:true emit
      expect: () => [
        // input (isEvm), input (recipient set), ready, ready(simulating),
        // ready(blocked simulationResult with success=false).
        isA<TransferInput>().having((s) => s.isEvm, 'isEvm', true),
        isA<TransferInput>().having(
          (s) => s.recipientError,
          'recipientError',
          isNull,
        ),
        isA<TransferReady>(),
        isA<TransferReady>().having((s) => s.isSimulating, 'simulating', true),
        isA<TransferReady>()
            .having((s) => s.isSimulating, 'simulating', false)
            .having((s) => s.simulationResult?.success, 'sim success', false),
      ],
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'started(evmHolder:) threads the holder into prepare',
      setUp: () {
        when(
          evmService.prepare(
            contract: anyNamed('contract'),
            tokenId: anyNamed('tokenId'),
            standard: anyNamed('standard'),
            recipient: anyNamed('recipient'),
            amount: anyNamed('amount'),
            holder: anyNamed('holder'),
          ),
        ).thenAnswer((_) async => prepared());
      },
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc721',
            evmHolder: evmHolder,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(evmRecipient));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
      },
      // The holder must reach the service so a non-active ETH wallet signs.
      verify: (_) {
        verify(
          evmService.prepare(
            contract: anyNamed('contract'),
            tokenId: anyNamed('tokenId'),
            standard: anyNamed('standard'),
            recipient: anyNamed('recipient'),
            amount: anyNamed('amount'),
            holder: evmHolder,
          ),
        ).called(1);
      },
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'started(evmHolder:) threads the holder into ownedErc1155Amount',
      setUp: () {
        when(
          evmService.ownedErc1155Amount(
            contract: anyNamed('contract'),
            tokenId: anyNamed('tokenId'),
            holder: anyNamed('holder'),
          ),
        ).thenAnswer((_) async => BigInt.from(3));
      },
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc1155',
            evmHolder: evmHolder,
          ),
        );
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) {
        verify(
          evmService.ownedErc1155Amount(
            contract: '0x1111111111111111111111111111111111111111',
            tokenId: BigInt.from(42),
            holder: evmHolder,
          ),
        ).called(1);
      },
    );

    // WHY (FINDING 8b): the fee-market fetch runs concurrently with prepare now.
    // A market failure must still let the simulation succeed and degrade only to
    // a null market/selection (read-only default fee) — the concurrency change
    // must not turn a market outage into a blocked transfer.
    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'a failed fee-market fetch still lets simulation succeed, degrading to a '
      'null gas selection',
      setUp: () {
        when(
          evmService.prepare(
            contract: anyNamed('contract'),
            tokenId: anyNamed('tokenId'),
            standard: anyNamed('standard'),
            recipient: anyNamed('recipient'),
            amount: anyNamed('amount'),
            holder: anyNamed('holder'),
          ),
        ).thenAnswer(
          (_) async => PreparedEvmTransfer(
            walletId: 'w1',
            source: '0x2222222222222222222222222222222222222222',
            to: '0x1111111111111111111111111111111111111111',
            data: Uint8List(0),
            valueWei: BigInt.zero,
            estimatedGasUsed: BigInt.from(90000),
            gasLimit: 108000,
            maxFeePerGas: BigInt.from(40000000000),
            maxPriorityFeePerGas: BigInt.from(1500000000),
            feeWei: BigInt.from(1234),
            recipientIsContract: false,
          ),
        );
        // gasMarket completes with an error (a feeHistory outage).
        when(
          evmService.gasMarket(),
        ).thenAnswer((_) async => throw Exception('feeHistory down'));
      },
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc721',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(evmRecipient));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (b) {
        final s = b.state as TransferReady;
        // Simulation (the safety gate) still passed; the fee just falls back to
        // the prepared node-default and no Edit affordance is offered.
        expect(s.simulationResult?.success, isTrue);
        expect(s.ethGasMarket, isNull);
        expect(s.ethGasSelection, isNull);
        expect(s.simulatedFeeWei, BigInt.from(1234));
      },
    );

    // WHY: between the biometric prompt and the terminal state sit the
    // signature, the broadcast and a best-effort inclusion wait — up to ~60s on
    // a busy block. Until the bloc forwarded `onBroadcasting`, the sheet held
    // "Approve in your wallet…" for that entire window on a transfer that
    // cannot be undone, and testers force-quit mid-flight. What is pinned here
    // is the ORDER: `TransferBroadcasting` must appear *between* signing and the
    // terminal state, which is exactly what disappears if the callback is
    // dropped again. `SendBloc._executeEthereum` has always done this; this is
    // the same state and the same copy.
    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'the EVM execute path advances signing → broadcasting → success',
      setUp: () {
        // No persisted gas preference — the review resolves the market tier.
        when(prefs.ethGasMode).thenReturn(null);
        when(prefs.ethGasMaxBaseFeeGwei).thenReturn(null);
        when(prefs.ethGasPriorityFeeGwei).thenReturn(null);
        when(
          evmService.prepare(
            contract: anyNamed('contract'),
            tokenId: anyNamed('tokenId'),
            standard: anyNamed('standard'),
            recipient: anyNamed('recipient'),
            amount: anyNamed('amount'),
            holder: anyNamed('holder'),
          ),
        ).thenAnswer((_) async => prepared());
        when(
          evmService.execute(
            any,
            feeOverride: anyNamed('feeOverride'),
            onBroadcasting: anyNamed('onBroadcasting'),
            onBroadcastRegistered: anyNamed('onBroadcastRegistered'),
          ),
        ).thenAnswer((invocation) async {
          // The service fires this the moment the signed tx is dispatched —
          // i.e. once the user has approved and there is nothing left for them
          // to do in their wallet.
          (invocation.namedArguments[#onBroadcasting] as void Function()?)
              ?.call();
          (invocation.namedArguments[#onBroadcastRegistered]
                  as void Function(PendingTxResolutionClaim?)?)
              ?.call(null);
          return '0xhash';
        });
      },
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc721',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(evmRecipient));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.execute());
        await Future<void>.delayed(Duration.zero);
      },
      // Drops the input stage (3), the ready transition, and the two simulate
      // emits — the pipeline states are what this test is about.
      skip: 6,
      expect: () => [
        isA<TransferSigning>(),
        isA<TransferBroadcasting>(),
        isA<TransferBroadcasting>().having(
          (s) => s.pendingRegistered,
          'pendingRegistered',
          isTrue,
        ),
        isA<TransferSuccess>().having(
          (s) => s.signature,
          'signature',
          '0xhash',
        ),
      ],
    );
  });

  // The EVM transfer must never sign/broadcast a prepared transfer that belongs
  // to a superseded review — the reported bug broadcast recipient A's NFT while
  // the confirm screen showed recipient B. These encode the three layers of the
  // fix: reset clears the cache, execute refuses a non-matching prepared, and a
  // late simulate can't stamp its result onto a newer ready state.
  group('EVM prepared-state invalidation', () {
    const evmMint = '0x1111111111111111111111111111111111111111-42';
    const recipientA = '0x2222222222222222222222222222222222222222';
    const recipientB = '0x4444444444444444444444444444444444444444';

    // Bridges recipient A's pending prepare completer from a `setUp` closure to
    // the `act` body of the late-simulate test.
    late Completer<PreparedEvmTransfer> latePrepare;

    PreparedEvmTransfer preparedWith({
      required BigInt feeWei,
      required bool recipientIsContract,
    }) => PreparedEvmTransfer(
      walletId: 'w1',
      source: '0x2222222222222222222222222222222222222222',
      to: '0x1111111111111111111111111111111111111111',
      data: Uint8List(0),
      valueWei: BigInt.zero,
      estimatedGasUsed: BigInt.from(60000),
      gasLimit: 72000,
      maxFeePerGas: BigInt.from(21),
      maxPriorityFeePerGas: BigInt.from(1),
      feeWei: feeWei,
      recipientIsContract: recipientIsContract,
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'reset clears the cached prepared so a later execute cannot sign it',
      setUp: () {
        // First simulate caches a prepared; the second (post-reset) simulate
        // never completes, so nothing re-caches. If reset did NOT clear the
        // cache, execute would still find the first prepared (same recipient +
        // quantity) and broadcast it — the verifyNever below would then fail.
        final hang = Completer<PreparedEvmTransfer>();
        var calls = 0;
        when(
          evmService.prepare(
            contract: anyNamed('contract'),
            tokenId: anyNamed('tokenId'),
            standard: anyNamed('standard'),
            recipient: anyNamed('recipient'),
            amount: anyNamed('amount'),
            holder: anyNamed('holder'),
          ),
        ).thenAnswer((_) {
          calls++;
          if (calls == 1) {
            return Future.value(
              preparedWith(
                feeWei: BigInt.from(100),
                recipientIsContract: false,
              ),
            );
          }
          return hang.future;
        });
      },
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc721',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(recipientA));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
        // Abandon the review, then re-enter it for the same recipient. The
        // second simulate hangs, so the cache stays empty unless reset failed
        // to clear it.
        b.add(const TransferArtworkEvent.reset());
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(recipientA));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.execute());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (b) {
        expect(b.state, isA<TransferError>());
        verifyNever(
          evmService.execute(
            any,
            feeOverride: anyNamed('feeOverride'),
            onBroadcasting: anyNamed('onBroadcasting'),
            onBroadcastRegistered: anyNamed('onBroadcastRegistered'),
          ),
        );
      },
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'execute refuses to broadcast while a re-simulation for a new recipient '
      'is in flight (the reported bug)',
      setUp: () {
        // Recipient A's simulate completes and caches. After switching to B, B's
        // simulate is still in flight, so the cache no longer matches the live
        // review. Tapping Send must surface a not-ready error and never sign the
        // stale (recipient A) prepared.
        final hang = Completer<PreparedEvmTransfer>();
        var calls = 0;
        when(
          evmService.prepare(
            contract: anyNamed('contract'),
            tokenId: anyNamed('tokenId'),
            standard: anyNamed('standard'),
            recipient: anyNamed('recipient'),
            amount: anyNamed('amount'),
            holder: anyNamed('holder'),
          ),
        ).thenAnswer((_) {
          calls++;
          if (calls == 1) {
            return Future.value(
              preparedWith(
                feeWei: BigInt.from(100),
                recipientIsContract: false,
              ),
            );
          }
          return hang.future;
        });
      },
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc721',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(recipientA));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.reset());
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(recipientB));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.execute());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (b) {
        expect(b.state, isA<TransferError>());
        verifyNever(
          evmService.execute(
            any,
            feeOverride: anyNamed('feeOverride'),
            onBroadcasting: anyNamed('onBroadcasting'),
            onBroadcastRegistered: anyNamed('onBroadcastRegistered'),
          ),
        );
      },
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'a late simulate completion for the old recipient does not overwrite the '
      'newer ready state',
      setUp: () {
        // The fee market is unavailable so the displayed fee is the prepared
        // feeWei verbatim (no tier math) — making A vs B distinguishable.
        when(
          evmService.gasMarket(),
        ).thenAnswer((_) async => throw Exception('feeHistory down'));
        // Recipient A's simulate stays pending; recipient B's completes and
        // stamps the ready state. Completing A afterwards (a late arrival) must
        // be ignored.
        final aPending = Completer<PreparedEvmTransfer>();
        var calls = 0;
        when(
          evmService.prepare(
            contract: anyNamed('contract'),
            tokenId: anyNamed('tokenId'),
            standard: anyNamed('standard'),
            recipient: anyNamed('recipient'),
            amount: anyNamed('amount'),
            holder: anyNamed('holder'),
          ),
        ).thenAnswer((_) {
          calls++;
          if (calls == 1) return aPending.future;
          return Future.value(
            preparedWith(feeWei: BigInt.from(555), recipientIsContract: false),
          );
        });
        latePrepare = aPending;
      },
      build: build,
      act: (b) async {
        b.add(
          const TransferArtworkEvent.started(
            evmMint,
            chain: 'ethereum',
            tokenStandard: 'erc721',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(recipientA));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.reset());
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(recipientB));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
        // Recipient A's simulate finally resolves — after B's already stamped
        // the ready state. It must not overwrite it.
        latePrepare.complete(
          preparedWith(feeWei: BigInt.from(999), recipientIsContract: true),
        );
        await Future<void>.delayed(Duration.zero);
      },
      verify: (b) {
        final s = b.state as TransferReady;
        // B's result stands: the late A completion (feeWei 999, contract=true)
        // was dropped.
        expect(s.simulationResult?.success, isTrue);
        expect(s.simulatedFeeWei, BigInt.from(555));
        expect(s.recipientIsContract, isFalse);
      },
    );
  });

  // The chooser lists `byOwner`
  // results with no chain filter, so a Tezos NFT does reach this flow. The old
  // `isEvm ? ethereum : solana` ternary signed it as `solana:nft-transfer`,
  // which (a) hid the unimplemented-cell backstop, because the Solana cell
  // IS implemented, and (b) let a Solana kill collaterally block Tezos.
  group('kill-switch cell derivation', () {
    test('a Tezos artwork derives the tezos cell, not solana', () {
      // Both signals a caller can have: the model's wire chain value, and — when
      // it carries none — the `KT1…` mint shape.
      expect(
        nftTransferFlowKey(mintAccount: _tezosMint, chain: 'tezos'),
        const FlowKey(Chain.tezos, AppFlow.nftTransfer),
      );
      expect(
        nftTransferFlowKey(mintAccount: _tezosMint),
        const FlowKey(Chain.tezos, AppFlow.nftTransfer),
      );
    });

    test('an EVM artwork still derives the ethereum cell', () {
      expect(
        nftTransferFlowKey(mintAccount: _evmMint, chain: 'ethereum'),
        const FlowKey(Chain.ethereum, AppFlow.nftTransfer),
      );
      expect(
        nftTransferFlowKey(mintAccount: _evmMint),
        const FlowKey(Chain.ethereum, AppFlow.nftTransfer),
      );
    });

    test('a Solana artwork still derives the solana cell', () {
      expect(
        nftTransferFlowKey(mintAccount: _mint, chain: 'solana'),
        const FlowKey.solana(AppFlow.nftTransfer),
      );
      // No chain hint and a base58 mint — the overwhelmingly common case.
      expect(
        nftTransferFlowKey(mintAccount: _mint),
        const FlowKey.solana(AppFlow.nftTransfer),
      );
    });

    test('the real AppFlow table has no tezos nft-transfer cell, so the gate '
        'rejects it loudly instead of gating it as solana', () async {
      // The whole point of the 3-way switch: with the real (not a test-local)
      // flow table, `AppFlow.nftTransfer.chains` excludes Tezos, so the key
      // this flow now derives reaches the fail-loud backstop — reported
      // to Sentry and surfaced with visible copy — rather than being signed
      // against an implemented Solana cell and dying later in Solana fee
      // simulation with an opaque error.
      final reports = <FlowKey>[];
      final gate = TransactionAuthGate.withReporter(
        _UnusedBiometric(),
        _UnusedStorage(),
        _PermissiveRemoteConfig(),
        reports.add,
      );
      final cell = nftTransferFlowKey(mintAccount: _tezosMint, chain: 'tezos');

      final outcome = await gate.authorize(usdValue: 1.0, flow: cell);

      expect(outcome.isFlowDisabled, isTrue);
      expect(outcome.disabledMessage, kUnsupportedFlowMessage);
      expect(reports, [cell]);
      // Sanity: the solana cell the old ternary produced is implemented, so
      // the backstop would have stayed silent for the same artwork.
      expect(AppFlow.nftTransfer.isImplemented(Chain.solana), isTrue);
    });

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'the signing path submits the tezos cell for a Tezos artwork',
      setUp: () {
        // A `KT1…` address is not a Solana asset, so the DAS lookup fails and
        // the bloc takes its optimistic legacy path — exactly how a Tezos NFT
        // reaches `executor.execute` today.
        when(dasApi.getAsset(_tezosMint)).thenThrow(Exception('not on solana'));
        when(walletManager.getAddress()).thenAnswer((_) async => _source);
        when(
          rpc.buildSplTransferTx(
            destination: anyNamed('destination'),
            tokenMint: anyNamed('tokenMint'),
            amount: anyNamed('amount'),
          ),
        ).thenAnswer((_) async => 'dHg=');
        // An NFT has no cached price — the executor's own gate fail-closes on a
        // null value, which is the intended behaviour for sending an asset out.
        when(priceService.usdValueOfRaw(any, any)).thenReturn(null);
        // The executor's own outcome is irrelevant here — only the cell it was
        // handed is under test.
        when(
          executor.execute(
            txsBase64: anyNamed('txsBase64'),
            usdValue: anyNamed('usdValue'),
            flow: anyNamed('flow'),
          ),
        ).thenAnswer(
          (_) async => const ResultFailure(AppFailure.unknown('not broadcast')),
        );
      },
      build: build,
      act: (b) async {
        b.add(const TransferArtworkEvent.started(_tezosMint, chain: 'tezos'));
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(_recipient));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.execute());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) {
        final flow =
            verify(
                  executor.execute(
                    txsBase64: anyNamed('txsBase64'),
                    usdValue: anyNamed('usdValue'),
                    flow: captureAnyNamed('flow'),
                  ),
                ).captured.single
                as FlowKey;
        expect(flow, const FlowKey(Chain.tezos, AppFlow.nftTransfer));
        expect(flow.toString(), 'tezos:nft-transfer');
      },
    );

    blocTest<TransferArtworkBloc, TransferArtworkState>(
      'a kill from the signing backstop lands on TransferError.failure so the '
      'flow shows the operator copy instead of "Transfer failed"',
      setUp: () {
        // Same legacy (non-DAS) path as the test above — the shortest route from
        // `execute` to a TransferError.
        when(dasApi.getAsset(_mint)).thenThrow(Exception('not indexed'));
        when(walletManager.getAddress()).thenAnswer((_) async => _source);
        when(
          rpc.buildSplTransferTx(
            destination: anyNamed('destination'),
            tokenMint: anyNamed('tokenMint'),
            amount: anyNamed('amount'),
          ),
        ).thenAnswer((_) async => 'dHg=');
        when(priceService.usdValueOfRaw(any, any)).thenReturn(null);
        when(
          executor.execute(
            txsBase64: anyNamed('txsBase64'),
            usdValue: anyNamed('usdValue'),
            flow: anyNamed('flow'),
          ),
        ).thenAnswer(
          (_) async => const ResultFailure(
            AppFailure.flowDisabled('Transfers are paused. Your NFT is safe.'),
          ),
        );
      },
      build: build,
      act: (b) async {
        b.add(const TransferArtworkEvent.started(_mint, chain: 'solana'));
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.recipientChanged(_recipient));
        b.add(const TransferArtworkEvent.proceed());
        await Future<void>.delayed(Duration.zero);
        b.add(const TransferArtworkEvent.execute());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (b) {
        final state = b.state as TransferError;
        // The kind is what the flow branches on: a bare message can't tell a
        // kill from a real failure, and the pipeline's generic error body would
        // swallow the operator's copy.
        expect(state.failure?.isFlowDisabled, isTrue);
        // Verbatim — never prefixed.
        expect(state.message, 'Transfers are paused. Your NFT is safe.');
        // The typed recipient survives so the sheet can stay open and idle.
        expect(state.previousRecipient, _recipient);
      },
    );
  });
}

/// Never called: the unsupported-cell check is the first statement in
/// [TransactionAuthGate.authorize] and returns before the gate touches storage,
/// biometrics, or the config snapshot.
class _UnusedBiometric extends Fake implements BiometricAuthService {}

class _UnusedStorage extends Fake implements SecureWalletStorage {}

class _PermissiveRemoteConfig extends Fake implements RemoteConfigService {
  @override
  ValueListenable<RemoteConfig> get config =>
      ValueNotifier(RemoteConfig.permissive);
}
