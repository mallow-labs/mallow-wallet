import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:solana/solana.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/simulation_review.dart';
import 'package:mallow_wallet/core/services/program_label_service.dart';
import 'package:mallow_wallet/features/browser/services/browser_signing_service.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_adapter.dart';

class _Wallet extends Mock implements WalletManager {}

class _Labels extends Fake implements ProgramLabelService {
  _Labels(this.instructions);
  @override
  final ProgramInstructions instructions;
}

final _signer = Ed25519HDPublicKey(List.filled(32, 1));
final _tokenAccount = Ed25519HDPublicKey(List.filled(32, 2));
final _mint = Ed25519HDPublicKey(List.filled(32, 3));
final _delegate = Ed25519HDPublicKey(List.filled(32, 4));
final _system = Ed25519HDPublicKey.fromBase58(solanaSystemProgram);

/// A one-signer System transfer from [_signer]; [lamports] varies the bytes.
Uint8List _transfer([int lamports = 1000]) {
  final data = Uint8List(12);
  ByteData.sublistView(data)
    ..setUint32(0, 2, Endian.little)
    ..setUint64(4, lamports, Endian.little);
  final keys = [_signer, _tokenAccount, _system];
  return Uint8List.fromList([
    1,
    ...List.filled(64, 0),
    1,
    0,
    1,
    keys.length,
    for (final key in keys) ...key.bytes,
    ..._tokenAccount.bytes,
    1,
    2,
    2,
    0,
    1,
    data.length,
    ...data,
  ]);
}

Map<String, Object?> _system$(int lamports) => {
  'lamports': lamports,
  'owner': solanaSystemProgram,
  'data': ['', 'base64'],
};

/// A token account of [_signer] for [_mint], frozen with a delegate when
/// [locked].
Map<String, Object?> _token({required bool locked}) {
  final bytes = Uint8List(165);
  bytes.setRange(0, 32, _mint.bytes);
  bytes.setRange(32, 64, _signer.bytes);
  bytes[64] = 1;
  bytes[108] = locked ? 2 : 1;
  if (locked) {
    bytes[72] = 1;
    bytes.setRange(76, 108, _delegate.bytes);
    bytes[121] = 1;
  }
  return {
    'owner': solanaTokenProgram,
    'lamports': 1,
    'data': [base64Encode(bytes), 'base64'],
  };
}

/// An initialized mint with zero decimals and a supply of one.
Map<String, Object?> _nftMint() {
  final bytes = Uint8List(82);
  bytes[36] = 1;
  bytes[44] = 0;
  bytes[45] = 1;
  return {
    'owner': solanaTokenProgram,
    'lamports': 1,
    'data': [base64Encode(bytes), 'base64'],
  };
}

/// Reviews a transaction whose simulation thaws [_tokenAccount] and revokes
/// its delegate: a marketplace unlock. [assets] is the DAS reply.
Future<SimulationReview> _unlock(List<Object?> assets) async {
  final adapter = SolanaDappAdapter(
    walletManager: _Wallet(),
    rpc: (chain, method, params) async {
      if (method == 'getMultipleAccounts') {
        final addresses = params.first as List;
        if (addresses.length == 1 && addresses.single == _mint.toBase58())
          return {
            'context': {'slot': 10},
            'value': [_nftMint()],
          };
        return {
          'context': {'slot': 10},
          'value': [_system$(2), _token(locked: true), _system$(1)],
        };
      }
      if (method == 'getFeeForMessage') return {'value': 5000};
      if (method == 'getAssetBatch') {
        expect(params.first, contains(_mint.toBase58()));
        return assets;
      }
      return {
        'context': {'slot': 10},
        'value': {
          'err': null,
          'accounts': [_system$(1), _token(locked: false), _system$(1)],
        },
      };
    },
  );
  final prepared = await adapter.prepareTransaction(
    transaction: _transfer(),
    walletId: 'w',
    address: _signer.toBase58(),
    origin: 'https://site.example',
    chain: 'solana:mainnet',
  );
  return prepared.review;
}

SimulationReview _review({
  String digest = 'a',
  SimulationExecution execution = SimulationExecution.succeeded,
  SimulationCoverage coverage = SimulationCoverage.complete,
  int? fee = 5000,
  String? feePayer,
  String? error,
  List<FundChange> funds = const [],
  List<AccountChange> accounts = const [],
  List<ReviewProgramCall> calls = const [],
  List<String> warnings = const [],
  Map<String, ReviewNftMetadata> nftMetadata = const {},
  Uri? explorerUrl,
  DateTime? simulatedAt,
}) => SimulationReview(
  payloadDigest: digest,
  origin: 'https://site.example',
  walletId: 'w',
  address: _signer.toBase58(),
  chain: 'solana:mainnet',
  simulatedAt: simulatedAt ?? DateTime.utc(2026, 10, 4),
  execution: execution,
  coverage: coverage,
  feeLamports: fee,
  feePayer: feePayer ?? _signer.toBase58(),
  error: error,
  funds: funds,
  accounts: accounts,
  programCalls: calls,
  warnings: warnings,
  nftMetadata: nftMetadata,
  explorerUrl: explorerUrl,
);

const _sol = ReviewAsset(id: solanaNativeMint, symbol: 'SOL', decimals: 9);

FundChange _net(int amount, {ReviewAsset asset = _sol, String? address}) =>
    FundChange(
      asset: asset,
      address: address ?? _signer.toBase58(),
      rawAmount: BigInt.from(amount),
      evidence: ReviewEvidence.simulatedState,
      isNet: true,
    );

void main() {
  tearDown(Config.debugOverrides.clear);

  group('unlock rows name their NFT', () {
    test('DAS edition metadata supplies the name and image', () async {
      final review = await _unlock([
        {
          'id': _mint.toBase58(),
          'interface': 'V1_PRINT',
          'content': {
            'metadata': {'name': 'Edition #3'},
            'files': [
              {'uri': 'https://example.com/a.mp4', 'mime': 'video/mp4'},
              {'uri': 'https://example.com/a.png', 'mime': 'image/png'},
            ],
          },
        },
      ]);
      final kinds = review.accounts.map((a) => a.kind).toSet();
      expect(
        kinds,
        containsAll([AccountChangeKind.thaw, AccountChangeKind.revoke]),
      );
      expect(
        review.accounts.every((a) => a.assetId == _mint.toBase58()),
        isTrue,
      );
      final metadata = review.nftMetadata[_mint.toBase58()];
      expect(metadata?.name, 'Edition #3');
      expect(metadata?.imageUrl, 'https://example.com/a.png');
    });

    test('an NFT DAS files as Custom keeps its name and image', () async {
      final review = await _unlock([
        {
          'id': _mint.toBase58(),
          'interface': 'Custom',
          'content': {
            'metadata': {'name': 'Fox #12'},
            'links': {'image': 'https://example.com/fox.png'},
          },
          'token_info': {'supply': 1, 'decimals': 0},
        },
      ]);
      final metadata = review.nftMetadata[_mint.toBase58()];
      expect(metadata?.name, 'Fox #12');
      expect(metadata?.imageUrl, 'https://example.com/fox.png');
    });

    test(
      'a single-supply mint DAS files as fungible is still an NFT',
      () async {
        final review = await _unlock([
          {
            'id': _mint.toBase58(),
            'interface': 'FungibleAsset',
            'content': {
              'metadata': {'name': 'Old Ape #7', 'symbol': 'APE'},
              'links': {'image': 'https://example.com/ape.png'},
            },
          },
        ]);
        expect(review.nftMetadata[_mint.toBase58()]?.name, 'Old Ape #7');
        expect(review.tokenMetadata, isEmpty);
      },
    );

    test('a single-supply mint DAS cannot describe is still an NFT', () async {
      final review = await _unlock([null]);
      expect(review.nftMetadata, contains(_mint.toBase58()));
      expect(review.nftMetadata[_mint.toBase58()]!.name, isNull);
    });
  });

  group('dasUrl', () {
    test('mainnet uses the proxy base as is', () {
      Config.debugOverrides['RPC_PROXY_BASE_URL'] = 'https://rpc.example/';
      expect(
        SolanaDappAdapter.dasUrl('solana:mainnet'),
        'https://rpc.example/',
      );
    });

    test('devnet merges network=devnet into the existing query', () {
      Config.debugOverrides
        ..['ENV'] = 'development'
        ..['RPC_PROXY_BASE_URL'] = 'https://rpc.example/?api-key=k';
      final url = Uri.parse(SolanaDappAdapter.dasUrl('solana:devnet'));
      expect(url.host, 'rpc.example');
      expect(url.queryParameters, {'api-key': 'k', 'network': 'devnet'});
      // The plain devnet node answers DAS with nulls; it must not be used.
      expect(
        SolanaDappAdapter.rpcUrl('solana:devnet'),
        isNot(SolanaDappAdapter.dasUrl('solana:devnet')),
      );
    });
  });

  test('describeUnsimulated lists calls and a link without any RPC', () {
    // The published tables name the call.
    GetIt.I.registerSingleton<ProgramLabelService>(
      _Labels(
        ProgramInstructions({
          solanaSystemProgram: {'02000000': 'Transfer'},
        }),
      ),
    );
    addTearDown(GetIt.I.unregister<ProgramLabelService>);
    final prepared = SolanaDappAdapter.describeUnsimulated(
      transaction: _transfer(),
      walletId: 'w',
      address: _signer.toBase58(),
      origin: 'https://site.example',
      chain: 'solana:mainnet',
    );
    final review = prepared.review;
    expect(review.execution, SimulationExecution.unavailable);
    expect(review.coverage, SimulationCoverage.unavailable);
    expect(review.programCalls.single.program, solanaSystemProgram);
    expect(review.programCalls.single.instruction, 'Transfer');
    expect(review.explorerUrl?.path, '/tx/inspector');
    expect(review.feeLamports, isNull);
    expect(prepared.bytes, _transfer());
  });

  test('describeUnsimulated still refuses a wallet that is not a signer', () {
    expect(
      () => SolanaDappAdapter.describeUnsimulated(
        transaction: _transfer(),
        walletId: 'w',
        address: _delegate.toBase58(),
        origin: 'https://site.example',
        chain: 'solana:mainnet',
      ),
      throwsA(anything),
    );
  });

  group('combineSolanaReviews', () {
    test('a single review comes back unchanged', () {
      final review = _review();
      expect(combineSolanaReviews([review]), same(review));
    });

    test('net outflows and inflows sum apart per asset and account', () {
      const usdc = ReviewAsset(id: 'USDC', symbol: 'Token', decimals: 6);
      final combined = combineSolanaReviews([
        _review(
          digest: 'a',
          funds: [
            _net(-100),
            _net(-5, asset: usdc, address: 'ata'),
          ],
        ),
        _review(
          digest: 'b',
          funds: [
            _net(-50),
            _net(5, asset: usdc, address: 'ata'),
          ],
        ),
      ]);
      final sol = combined.funds.singleWhere(
        (f) => f.asset.id == solanaNativeMint,
      );
      expect(sol.rawAmount, BigInt.from(-150));
      // The site picks which signed transactions it broadcasts, so the
      // second part's receipt cannot cancel the first part's payment.
      final token = combined.funds.where((f) => f.asset.id == 'USDC').toList();
      expect(token.map((f) => f.rawAmount), [BigInt.from(-5), BigInt.from(5)]);
      expect(token.every((f) => f.isNet && f.address == 'ata'), isTrue);
      expect(combined.feeLamports, 10000);
      expect(combined.execution, SimulationExecution.succeeded);
      expect(combined.coverage, SimulationCoverage.complete);
      expect(combined.payloadDigest, isNot(anyOf('a', 'b')));
    });

    test('a receipt in one part never hides a drain in another', () {
      // Part 1 sends 10 SOL away. Part 2 pays 10 SOL in from an account
      // whose signature it never gets, so it cannot land; it simulated only
      // because simulation skips signature checks.
      const tenSol = 10000000000;
      final combined = combineSolanaReviews([
        _review(funds: [_net(-tenSol - 5000)]),
        _review(digest: 'b', funds: [_net(tenSol - 5000)]),
      ]);
      final sol = combined.funds
          .where((f) => f.asset.id == solanaNativeMint)
          .toList();
      expect(sol.map((f) => f.rawAmount), [
        BigInt.from(-tenSol - 5000),
        BigInt.from(tenSol - 5000),
      ]);
      expect(combined.execution, SimulationExecution.succeeded);
      expect(combined.coverage, SimulationCoverage.complete);
      // Step-up auth values the batch by what can leave, not the net.
      final usd = estimateBrowserOutgoingUsd(combined, (_) => 100);
      expect(usd, closeTo(1000, 0.01));
    });

    test('a part without net changes keeps its requested transfers', () {
      final requested = FundChange(
        asset: _sol,
        address: _signer.toBase58(),
        rawAmount: BigInt.from(-7),
        evidence: ReviewEvidence.requestedInstruction,
        from: _signer.toBase58(),
        to: 'recipient',
      );
      final combined = combineSolanaReviews([
        _review(funds: [_net(-100)]),
        _review(
          execution: SimulationExecution.failed,
          coverage: SimulationCoverage.partial,
          error: 'Simulation failed: {"InstructionError":[0,"Custom"]}',
          fee: null,
          funds: [requested],
        ),
      ]);
      final net = combined.funds.where((f) => f.isNet).toList();
      expect(net.map((f) => f.rawAmount), [BigInt.from(-100), BigInt.from(-7)]);
      expect(net.last.to, 'recipient');
      expect(net.last.evidence, ReviewEvidence.requestedInstruction);
      expect(combined.execution, SimulationExecution.failed);
      expect(combined.coverage, SimulationCoverage.partial);
      expect(combined.feeLamports, isNull);
      expect(
        combined.error,
        'Simulation failed: Transaction 2: {"InstructionError":[0,"Custom"]}',
      );
    });

    test('without net changes anywhere, transfers stay as they are', () {
      final requested = FundChange(
        asset: _sol,
        address: _signer.toBase58(),
        rawAmount: BigInt.from(-7),
        evidence: ReviewEvidence.requestedInstruction,
      );
      final combined = combineSolanaReviews([
        _review(execution: SimulationExecution.unavailable, funds: [requested]),
        _review(execution: SimulationExecution.unavailable, funds: [requested]),
      ]);
      expect(combined.funds, hasLength(2));
      expect(combined.funds.every((f) => !f.isNet), isTrue);
      expect(
        combined.error,
        'Simulation is unavailable. The effects and cost of these transactions could not be verified.',
      );
    });

    test('names which transactions were not simulated', () {
      final combined = combineSolanaReviews([
        _review(),
        _review(execution: SimulationExecution.unavailable),
        _review(execution: SimulationExecution.unavailable),
      ]);
      expect(
        combined.error,
        'Simulation is unavailable for transactions 2 and 3 of 3. Their effects and cost could not be verified.',
      );
    });

    test('keeps every change, warning and metadata entry, and one section '
        'per transaction', () {
      final first = Uri.parse('https://explorer.example/1');
      final second = Uri.parse('https://explorer.example/2');
      final early = DateTime.utc(2026, 10, 4, 12);
      final combined = combineSolanaReviews([
        _review(
          calls: const [ReviewProgramCall(program: 'A')],
          accounts: const [
            AccountChange(
              kind: AccountChangeKind.thaw,
              address: 'ata1',
              program: solanaTokenProgram,
              description: 'Thaw',
              evidence: ReviewEvidence.simulatedState,
            ),
          ],
          warnings: const ['w1', 'shared'],
          nftMetadata: const {'m1': ReviewNftMetadata(name: 'One')},
          explorerUrl: first,
          simulatedAt: early.add(const Duration(seconds: 3)),
        ),
        _review(
          execution: SimulationExecution.failed,
          calls: const [
            ReviewProgramCall(program: 'B'),
            ReviewProgramCall(program: 'C'),
          ],
          accounts: const [
            AccountChange(
              kind: AccountChangeKind.thaw,
              address: 'ata2',
              program: solanaTokenProgram,
              description: 'Thaw',
              evidence: ReviewEvidence.simulatedState,
            ),
          ],
          warnings: const ['shared', 'w2'],
          nftMetadata: const {'m2': ReviewNftMetadata(name: 'Two')},
          explorerUrl: second,
          simulatedAt: early,
        ),
      ]);
      expect(combined.accounts.map((a) => a.address), ['ata1', 'ata2']);
      expect(combined.warnings, ['w1', 'shared', 'w2']);
      expect(combined.nftMetadata.keys, containsAll(['m1', 'm2']));
      expect(combined.simulatedAt, early);
      expect(combined.explorerUrl, isNull);
      expect(combined.transactions, hasLength(2));
      expect(combined.transactions[0].programCalls.map((c) => c.program), [
        'A',
      ]);
      expect(combined.transactions[0].explorerUrl, first);
      expect(combined.transactions[1].programCalls.map((c) => c.program), [
        'B',
        'C',
      ]);
      expect(combined.transactions[1].execution, SimulationExecution.failed);
      expect(combined.transactions[1].explorerUrl, second);
      expect(combined.error, 'Simulation failed: Transaction 2 failed');
    });

    test('a placeholder from one part never erases what another part '
        'learned about the same NFT', () {
      final combined = combineSolanaReviews([
        _review(
          nftMetadata: const {
            'm': ReviewNftMetadata(name: 'One', imageUrl: 'https://a/1.png'),
          },
        ),
        _review(nftMetadata: const {'m': ReviewNftMetadata()}),
        _review(nftMetadata: const {'n': ReviewNftMetadata()}),
        _review(
          nftMetadata: const {
            'n': ReviewNftMetadata(imageUrl: 'https://a/2.png'),
          },
        ),
      ]);
      expect(combined.nftMetadata['m']?.name, 'One');
      expect(combined.nftMetadata['m']?.imageUrl, 'https://a/1.png');
      expect(combined.nftMetadata['n']?.imageUrl, 'https://a/2.png');
    });

    test('counts every fee as the wallet\'s when it pays any of them', () {
      final combined = combineSolanaReviews([
        _review(feePayer: 'sponsor'),
        _review(),
      ]);
      expect(combined.feePayer, _signer.toBase58());
      expect(combined.feeLamports, 10000);
      final sponsored = combineSolanaReviews([
        _review(feePayer: 'sponsor'),
        _review(feePayer: 'sponsor'),
      ]);
      expect(sponsored.feePayer, 'sponsor');
    });

    test('an explicit error replaces the composed one', () {
      final combined = combineSolanaReviews([
        _review(execution: SimulationExecution.unavailable),
      ], error: 'Too many to simulate.');
      expect(combined.error, 'Too many to simulate.');
      expect(combined.transactions, hasLength(1));
    });
  });
}
