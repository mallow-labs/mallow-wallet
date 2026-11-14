// The reviews that could hide or misstate a move of funds, each as the
// request a website could send and what the review must show for it. They
// run the real transaction parsing, review building and review sheet
// together, with a stand-in for the node only.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/simulation_review.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/browser_transaction_tracker.dart';
import 'package:mallow_wallet/features/browser/services/solana_asset_instructions.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_adapter.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_transaction.dart';
import 'package:mallow_wallet/features/browser/services/solana_lookup_table_cache.dart';
import 'package:mallow_wallet/features/browser/services/tezos_dapp_adapter.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/hold_to_approve_button.dart';
import 'package:mallow_wallet/shared/widgets/signing_review_layout.dart';
import 'package:mallow_wallet/shared/widgets/simulation_review_sheet.dart';
import 'package:mocktail/mocktail.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

class _Wallet extends Mock implements WalletManager {}

Ed25519HDPublicKey _address(String base58) =>
    Ed25519HDPublicKey.fromBase58(base58);
Ed25519HDPublicKey _unique(int fill) =>
    Ed25519HDPublicKey(List.filled(32, fill));

final _wallet = _unique(1);
final _walletAddress = _wallet.toBase58();
final _system = _address(solanaSystemProgram);
final _token = _address(solanaTokenProgram);
final _bubblegum = _address(solanaBubblegumProgram);
final _stake = _address(solanaStakeProgram);
final _core = _address(solanaCoreProgram);
final _memo = _address('MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr');
final _usdc = _address('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v');
final _market = _address('MMA7VebX8Pi5JrrvaTBBm7nW81sfCww7ZtLBBT1YCy8');
// Someone's wallet: an address with a key, which a program-derived one is not.
final _attacker = _address('4qQ2g1cznQYXNrRKDXuMzoujEiyq2SykLnU6M315PA1T');
// An address only a program can sign for.
final _programAddress = _address(
  '4oDUXKEVwTjzURt6DwyW5BS24yBLXpntPSUTKFrSHqtW',
);
const _origin = 'https://site.example';
const _chain = 'solana:mainnet';

List<int> _u64(BigInt value) => [
  for (var i = 0; i < 8; i++) ((value >> (8 * i)) & BigInt.from(255)).toInt(),
];
List<int> _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

AccountMeta _meta(
  Ed25519HDPublicKey key, {
  bool signer = false,
  bool writable = false,
}) => writable
    ? AccountMeta.writeable(pubKey: key, isSigner: signer)
    : AccountMeta.readonly(pubKey: key, isSigner: signer);

Instruction _instruction(
  Ed25519HDPublicKey program,
  List<AccountMeta> accounts,
  List<int> data,
) => Instruction(programId: program, accounts: accounts, data: ByteArray(data));

/// An unsigned transaction paid for by the wallet, as a website sends it.
Uint8List _transaction(List<Instruction> instructions) {
  final message = Message(
    instructions: instructions,
  ).compile(recentBlockhash: solanaSystemProgram, feePayer: _wallet);
  final tx = SignedTx(
    compiledMessage: message,
    signatures: [
      for (final key in message.accountKeys.take(
        message.requiredSignatureCount,
      ))
        Signature(List.filled(64, 0), publicKey: key),
    ],
  );
  return Uint8List.fromList(tx.toByteArray().toList());
}

Instruction _memoOf(int n) =>
    _instruction(_memo, const [], utf8.encode('gm $n'));

Map<String, Object?> _systemAccount(int lamports) => {
  'lamports': lamports,
  'owner': solanaSystemProgram,
  'data': ['', 'base64'],
};

/// A node that refuses every call: one the website has kept busy.
Future<Object?> _refusing(
  String chain,
  String method,
  List<Object?> params,
) async => throw const SolanaDappRpcException(429);

/// An honest node for a transaction that changes nothing of the wallet's but
/// the fee. [inner] are the calls its programs make; [assets] the names an
/// asset lookup knows.
DappRpc _honestNode({
  List<Map<String, Object?>> inner = const [],
  Map<String, String> assets = const {},
}) => (chain, method, params) async {
  switch (method) {
    case 'getMultipleAccounts':
      return {
        'context': {'slot': 10},
        'value': [
          for (final address in params.first as List)
            address == _walletAddress ? _systemAccount(1000000000) : null,
        ],
      };
    case 'simulateTransaction':
      final addresses =
          ((params[1] as Map)['accounts'] as Map)['addresses'] as List;
      final keys = parseDappTransaction(
        base64Decode(params.first as String),
      ).compiledMessage.accountKeys.map((k) => k.toBase58()).toList();
      return {
        'context': {'slot': 12},
        'value': {
          'err': null,
          'logs': <String>[],
          'fee': 5000,
          'accounts': [
            for (final address in addresses)
              address == _walletAddress ? _systemAccount(999995000) : null,
          ],
          'preBalances': [
            for (final key in keys) key == _walletAddress ? 1000000000 : 1,
          ],
          'postBalances': [
            for (final key in keys) key == _walletAddress ? 999995000 : 1,
          ],
          'preTokenBalances': <Object?>[],
          'postTokenBalances': <Object?>[],
          'innerInstructions': inner,
        },
      };
    case 'getAssetBatch':
      return [
        for (final id in params.first as List)
          if (assets[id] case final name?)
            {
              'id': id,
              'interface': 'V1_NFT',
              'content': {
                'metadata': {'name': name},
              },
            },
      ];
    case 'getFeeForMessage':
      return {'value': 5000};
  }
  throw StateError('unexpected $method');
};

Future<SimulationReview> _simulate(
  List<Instruction> instructions,
  DappRpc rpc,
) async =>
    (await SolanaDappAdapter(
          walletManager: _Wallet(),
          rpc: rpc,
        ).prepareTransaction(
          transaction: _transaction(instructions),
          walletId: 'w',
          address: _walletAddress,
          origin: _origin,
          chain: _chain,
        ))
        .review;

SimulationReview _unsimulated(List<Instruction> instructions) =>
    SolanaDappAdapter.describeUnsimulated(
      transaction: _transaction(instructions),
      walletId: 'w',
      address: _walletAddress,
      origin: _origin,
      chain: _chain,
    ).review;

/// Shows [review] as the browser does and returns how often it was approved.
Future<ValueNotifier<int>> _show(
  WidgetTester tester,
  SimulationReview review, {
  Map<String, String> labels = const {},
}) async {
  const size = Size(600, 2400);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final approved = ValueNotifier(0);
  // Each review is a new sheet: one shown after another in a test must not
  // inherit the first one's button, already held.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SimulationReviewSheet(
            review: review,
            onReject: () {},
            onApprove: () => approved.value++,
            programLabels: ValueNotifier(labels),
          ),
        ),
      ),
    ),
  );
  return approved;
}

/// Approving [review] takes the hold: a tap does nothing, holding approves.
Future<void> _expectHold(
  WidgetTester tester,
  ValueNotifier<int> approved,
) async {
  expect(find.text('Review carefully'), findsOneWidget);
  expect(find.byType(HoldToApproveButton), findsOneWidget);
  final approve = find.byKey(const Key('approve-signing'));
  await tester.ensureVisible(approve);
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(approve);
  await tester.pump(const Duration(seconds: 2));
  expect(approved.value, 0, reason: 'a tap is not a hold');
  final hold = await tester.startGesture(tester.getCenter(approve));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 1300));
  await hold.up();
  await tester.pump();
  expect(approved.value, 1, reason: 'it stays signable');
}

/// Approving [review] takes one tap.
Future<void> _expectTap(
  WidgetTester tester,
  ValueNotifier<int> approved,
) async {
  expect(find.text('Review carefully'), findsNothing);
  expect(find.byType(HoldToApproveButton), findsNothing);
  final approve = find.byKey(const Key('approve-signing'));
  await tester.ensureVisible(approve);
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(approve);
  expect(approved.value, 1);
}

/// [instructions] as a node reports the calls the transaction's first
/// instruction makes.
Map<String, Object?> _innerCalls(List<Instruction> instructions) => {
  'index': 0,
  'instructions': [
    for (final instruction in instructions)
      {
        'programId': instruction.programId.toBase58(),
        'accounts': [
          for (final account in instruction.accounts) account.pubKey.toBase58(),
        ],
        'data': base58encode(instruction.data.toList()),
        'stackHeight': 2,
      },
  ],
};

String _short(String address) =>
    '${address.substring(0, 6)}…${address.substring(address.length - 6)}';

void main() {
  tearDown(() async {
    Config.debugOverrides.clear();
    BrowserTransactionTracker.instance.clear();
    await SolanaLookupTableCache.instance.clear();
  });

  group('a simulation the website switched off', () {
    final attackerProgram = _unique(40);

    /// Fifty SOL into an account owned by a program the attacker picks.
    Future<Instruction> drain() async {
      const seed = 'x';
      final account = await Ed25519HDPublicKey.createWithSeed(
        fromPublicKey: _wallet,
        seed: seed,
        programId: attackerProgram,
      );
      return _instruction(
        _system,
        [
          _meta(_wallet, signer: true, writable: true),
          _meta(account, writable: true),
        ],
        [
          ..._u32(3),
          ..._wallet.bytes,
          ..._u64(BigInt.from(seed.length)),
          ...utf8.encode(seed),
          ..._u64(BigInt.from(50000000000)),
          ..._u64(BigInt.zero),
          ...attackerProgram.bytes,
        ],
      );
    }

    testWidgets('an oversized batch still shows the SOL it moves, and takes '
        'the hold', (tester) async {
      final drainInstruction = await tester.runAsync(drain);
      // Read with no node at all, as the browser does past the limit.
      final parts = [
        for (var n = 0; n < kMaxSimulatedSolanaBatch; n++)
          _unsimulated([_memoOf(n)]),
        _unsimulated([drainInstruction!]),
      ];
      final review = combineSolanaReviews(
        parts,
        error: 'This batch could not be simulated.',
      );
      expect(review.execution, SimulationExecution.unavailable);
      expect(review.funds.single.rawAmount, -BigInt.from(50000000000));
      expect(review.funds.single.evidence, ReviewEvidence.requestedInstruction);

      final approved = await _show(tester, review);
      expect(find.text('You send'), findsOneWidget);
      expect(find.text('50 SOL'), findsOneWidget);
      expect(find.text('Create account; rent deposit 50 SOL'), findsOneWidget);
      expect(find.text(_short(attackerProgram.toBase58())), findsOneWidget);
      // It says where the amounts came from.
      expect(
        find.text('Effects requested by these transactions'),
        findsOneWidget,
      );
      expect(find.text('No asset changes could be identified.'), findsNothing);
      // "Could not be checked" is never the easier thing to approve.
      await _expectHold(tester, approved);
    });

    testWidgets('a node that refuses takes the hold, whatever the '
        'transaction is', (tester) async {
      final review = await tester.runAsync(
        () => _simulate([_memoOf(1)], _refusing),
      );
      expect(review!.execution, SimulationExecution.unavailable);
      final approved = await _show(tester, review);
      expect(find.text('Simulation unavailable'), findsOneWidget);
      await _expectHold(tester, approved);
    });

    testWidgets('a System instruction it cannot read is flagged, when the '
        'wallet signs it', (tester) async {
      // Allocate on the wallet's own account: it could no longer send SOL.
      final allocate = _instruction(
        _system,
        [_meta(_wallet, signer: true, writable: true)],
        [..._u32(8), ..._u64(BigInt.from(64))],
      );
      const warning =
          'A System Program instruction (Allocate) could not be read. With your signature it can move or re-assign what your wallet holds.';
      expect(_unsimulated([allocate]).warnings, [warning]);
      final review = await tester.runAsync(
        () => _simulate([allocate], _honestNode()),
      );
      await _show(tester, review!);
      expect(
        find.descendant(
          of: find.byType(ReviewCautionCard),
          matching: find.text(warning),
        ),
        findsOneWidget,
      );
    });

    test('one that only sets something up is not', () {
      // InitializeNonceAccount: the wallet pays, nothing of its own is
      // re-assigned.
      final initialize = _instruction(
        _system,
        [_meta(_unique(41), writable: true), _meta(_wallet, signer: true)],
        [..._u32(6), ..._wallet.bytes],
      );
      expect(_unsimulated([initialize]).warnings, isEmpty);
    });

    test('a token transfer that names no mint is still an outgoing '
        'transfer', () {
      final source = _unique(42);
      final destination = _unique(43);
      final review = _unsimulated([
        _instruction(
          _token,
          [
            _meta(source, writable: true),
            _meta(destination, writable: true),
            _meta(_wallet, signer: true),
          ],
          [3, ..._u64(BigInt.from(700))],
        ),
      ]);
      final fund = review.funds.single;
      expect(fund.rawAmount, -BigInt.from(700));
      expect((fund.from, fund.to), (source.toBase58(), destination.toBase58()));
    });
  });

  group('what the bytes alone say, with no node', () {
    final token2022 = _address(solanaToken2022Program);
    final derived = _unique(44);
    final recipient = _unique(45);
    final owner = _unique(46);
    List<int> seeded(int tag, List<int> rest, {bool base = true}) => [
      ..._u32(tag),
      if (base) ..._wallet.bytes,
      ..._u64(BigInt.from(4)),
      ...utf8.encode('seed'),
      ...rest,
    ];

    test('a Token-2022 transfer with a fee is a transfer', () {
      final source = _unique(47);
      final review = _unsimulated([
        _instruction(
          token2022,
          [
            _meta(source, writable: true),
            _meta(_usdc),
            _meta(recipient, writable: true),
            _meta(_wallet, signer: true),
          ],
          [26, 1, ..._u64(BigInt.from(2500000)), 6, ..._u64(BigInt.from(25))],
        ),
      ]);
      final fund = review.funds.single;
      expect(
        (fund.rawAmount, fund.asset.decimals, fund.to),
        (-BigInt.from(2500000), 6, recipient.toBase58()),
      );
      expect(review.warnings, [
        'Token-2022 extensions may cause additional effects.',
      ]);
    });

    test('a burn takes tokens out of the wallet', () {
      final source = _unique(47);
      final fund = _unsimulated([
        _instruction(
          _token,
          [
            _meta(source, writable: true),
            _meta(_usdc, writable: true),
            _meta(_wallet, signer: true),
          ],
          [15, ..._u64(BigInt.from(9000000)), 6],
        ),
      ]).funds.single;
      expect(
        (fund.asset.id, fund.rawAmount, fund.to),
        (_usdc.toBase58(), -BigInt.from(9000000), null),
      );
    });

    test('SOL the wallet signs out of an account derived from it', () {
      final fund = _unsimulated([
        _instruction(
          _system,
          [
            _meta(derived, writable: true),
            _meta(_wallet, signer: true),
            _meta(recipient, writable: true),
          ],
          [
            ..._u32(11),
            ..._u64(BigInt.from(3000000000)),
            ..._u64(BigInt.from(4)),
            ...utf8.encode('seed'),
            ...owner.bytes,
          ],
        ),
      ]).funds.single;
      expect(
        (fund.address, fund.rawAmount, fund.to),
        (derived.toBase58(), -BigInt.from(3000000000), recipient.toBase58()),
      );
    });

    test('SOL withdrawn from a nonce account the wallet controls', () {
      final sysvar = _address('SysvarRecentB1ockHashes11111111111111111111');
      final rent = _address('SysvarRent111111111111111111111111111111111');
      final fund = _unsimulated([
        _instruction(
          _system,
          [
            _meta(derived, writable: true),
            _meta(recipient, writable: true),
            _meta(sysvar),
            _meta(rent),
            _meta(_wallet, signer: true),
          ],
          [..._u32(5), ..._u64(BigInt.from(1500000))],
        ),
      ]).funds.single;
      expect(
        (fund.address, fund.rawAmount),
        (derived.toBase58(), -BigInt.from(1500000)),
      );
    });

    test('an account handed to a program, with or without a seed', () {
      for (final data in [
        // AssignWithSeed, then AllocateWithSeed.
        seeded(10, owner.bytes),
        seeded(9, [..._u64(BigInt.from(128)), ...owner.bytes]),
      ]) {
        final change = _unsimulated([
          _instruction(_system, [
            _meta(derived, writable: true),
            _meta(_wallet, signer: true),
          ], data),
        ]).accounts.single;
        expect(
          (change.kind, change.address, change.beneficiary),
          (AccountChangeKind.authority, derived.toBase58(), owner.toBase58()),
        );
      }
    });

    test('a nonce account\'s authority handed on', () {
      final review = _unsimulated([
        _instruction(
          _system,
          [_meta(derived, writable: true), _meta(_wallet, signer: true)],
          [..._u32(7), ..._attacker.bytes],
        ),
      ]);
      final change = review.accounts.single;
      expect(
        (change.kind, change.beneficiary),
        (AccountChangeKind.authority, _attacker.toBase58()),
      );
      expect(review.warnings, isEmpty);
    });

    test('a token instruction it cannot read is flagged by name', () {
      final review = _unsimulated([
        _instruction(
          token2022,
          [_meta(_unique(47), writable: true), _meta(_wallet, signer: true)],
          const [255, 1, 2, 3],
        ),
      ]);
      expect(
        review.warnings,
        contains(
          'A Token-2022 instruction (Batch) could not be read. With your signature it can move or re-assign what your wallet holds.',
        ),
      );
    });

    test('a mint\'s upkeep gets no caution, though the wallet signs it', () {
      final mint = _unique(47);
      for (final (name, data) in [
        (
          'UpdateTokenMetadataField',
          [221, 233, 49, 45, 181, 202, 220, 200, 0, 1, 0, 0, 0, 65],
        ),
        ('SetTransferFee', [26, 5, 100, 0, ..._u64(BigInt.from(5000))]),
        ('Pause', const [44, 1]),
        ('Resume', const [44, 2]),
        ('UpdateMetadataPointer', [39, 1, ...List.filled(64, 0)]),
        ('UpdateTransferHook', [36, 1, ...List.filled(32, 0)]),
      ]) {
        final review = _unsimulated([
          _instruction(token2022, [
            _meta(mint, writable: true),
            _meta(_wallet, signer: true),
          ], data),
        ]);
        expect(review.warnings, isEmpty, reason: name);
        // It is still named where the review lists what runs.
        expect(review.programCalls.single.instruction, name);
      }
    });

    testWidgets('upkeep shows no caution card on a simulated review either', (
      tester,
    ) async {
      final review = await tester.runAsync(
        () => _simulate([
          _instruction(
            token2022,
            [_meta(_unique(47), writable: true), _meta(_wallet, signer: true)],
            const [44, 1],
          ),
        ], _honestNode()),
      );
      final approved = await _show(tester, review!);
      expect(find.byType(ReviewCautionCard), findsNothing);
      await _expectTap(tester, approved);
    });

    test('an instruction with no name is flagged when it names the wallet, '
        'and only then', () {
      const tokenWarning =
          'A Token-2022 instruction could not be read. With your signature it can move or re-assign what your wallet holds.';
      const systemWarning =
          'A System Program instruction could not be read. With your signature it can move or re-assign what your wallet holds.';
      final account = _unique(47);
      Instruction unknownToken(Ed25519HDPublicKey authority) => _instruction(
        token2022,
        [_meta(account, writable: true), _meta(authority, signer: true)],
        const [200, 1, 2, 3],
      );
      Instruction unknownSystem(Ed25519HDPublicKey account) => _instruction(
        _system,
        [_meta(account, signer: true, writable: true)],
        [..._u32(99), 1, 2, 3],
      );
      expect(_unsimulated([unknownToken(_wallet)]).warnings, [
        tokenWarning,
        'Token-2022 extensions may cause additional effects.',
      ]);
      expect(_unsimulated([unknownSystem(_wallet)]).warnings, [systemWarning]);
      // Another signer's instruction, in a transaction the wallet only pays
      // for: nothing of the wallet's is within its reach.
      expect(_unsimulated([unknownToken(owner)]).warnings, isEmpty);
      expect(_unsimulated([unknownSystem(owner)]).warnings, isEmpty);
      // The same for one known to move holdings: a batch of token
      // instructions, and Allocate.
      expect(
        _unsimulated([
          _instruction(
            token2022,
            [_meta(account, writable: true), _meta(owner, signer: true)],
            const [255, 1, 2, 3],
          ),
        ]).warnings,
        isEmpty,
      );
      expect(
        _unsimulated([
          _instruction(
            _system,
            [_meta(owner, signer: true, writable: true)],
            [..._u32(8), ..._u64(BigInt.from(64))],
          ),
        ]).warnings,
        isEmpty,
      );
    });

    test('an unnamed instruction a program runs for the wallet is flagged '
        'too', () async {
      final account = _unique(47);
      final review = await _simulate(
        [
          _instruction(
            _market,
            [
              _meta(_wallet, signer: true, writable: true),
              _meta(account, writable: true),
              _meta(token2022),
            ],
            const [1, 2, 3, 4, 5, 6, 7, 8],
          ),
        ],
        _honestNode(
          inner: [
            {
              'index': 0,
              'instructions': [
                {
                  'programId': solanaToken2022Program,
                  'accounts': [account.toBase58(), _walletAddress],
                  'data': base58encode(const [200, 1, 2, 3]),
                  'stackHeight': 2,
                },
                // Upkeep, made the same way.
                {
                  'programId': solanaToken2022Program,
                  'accounts': [account.toBase58(), _walletAddress],
                  'data': base58encode(const [44, 1]),
                  'stackHeight': 2,
                },
              ],
            },
          ],
        ),
      );
      expect(review.warnings.where((w) => w.contains('could not be read')), [
        'A Token-2022 instruction could not be read. With your signature it can move or re-assign what your wallet holds.',
        kSolanaUnreadProgramsWarning,
      ]);
    });

    test('a program with no reader is said to be unread only when the '
        'wallet\'s signature reaches it', () {
      final call = [1, 2, 3, 4, 5, 6, 7, 8];
      expect(
        _unsimulated([
          _instruction(_market, [_meta(_wallet, signer: true)], call),
        ]).warnings,
        [kSolanaUnreadProgramsWarning],
      );
      // The wallet only pays the fee here.
      expect(
        _unsimulated([
          _instruction(_market, [_meta(recipient, writable: true)], call),
        ]).warnings,
        isEmpty,
      );
      // A memo the wallet signs, and creating its own token account.
      final mine = _unique(48);
      expect(
        _unsimulated([
          _instruction(_memo, [
            _meta(_wallet, signer: true),
          ], utf8.encode('gm')),
          _instruction(
            _address(solanaAssociatedTokenProgram),
            [
              _meta(_wallet, signer: true, writable: true),
              _meta(mine, writable: true),
              _meta(_wallet),
              _meta(_usdc),
              _meta(_system),
              _meta(_token),
            ],
            const [1],
          ),
        ]).warnings,
        isEmpty,
      );
    });

    test('an account loaded from a lookup table is said to be unknown', () {
      final table = _unique(49);
      final compiled =
          Message(
                instructions: [
                  _instruction(
                    _system,
                    [
                      _meta(_wallet, signer: true, writable: true),
                      _meta(recipient, writable: true),
                    ],
                    [..._u32(2), ..._u64(BigInt.from(1000000000))],
                  ),
                ],
              ).compileV0(
                recentBlockhash: solanaSystemProgram,
                feePayer: _wallet,
              )
              as CompiledMessageV0;
      // The same transfer, with its destination loaded from a table.
      final message = compiled.copyWith(
        addressTableLookups: [
          MessageAddressTableLookup(
            accountKey: table,
            writableIndexes: [0],
            readonlyIndexes: [],
          ),
        ],
        instructions: [
          compiled.instructions.single.copyWith(
            accountKeyIndexes: [0, compiled.accountKeys.length],
          ),
        ],
      );
      final bytes = Uint8List.fromList(
        SignedTx(
          compiledMessage: message,
          signatures: [Signature(List.filled(64, 0), publicKey: _wallet)],
        ).toByteArray().toList(),
      );
      final review = SolanaDappAdapter.describeUnsimulated(
        transaction: bytes,
        walletId: 'w',
        address: _walletAddress,
        origin: _origin,
        chain: _chain,
      ).review;
      // The amount leaving is still read; only who receives it is not.
      final fund = review.funds.single;
      expect((fund.rawAmount, fund.to), (-BigInt.from(1000000000), null));
      expect(
        review.warnings,
        contains(
          'Address lookup tables could not be resolved. Some affected accounts are unknown.',
        ),
      );
    });
  });

  group('an asset no balance shows', () {
    final tree = _unique(50);
    final config = _unique(51);
    final nonce = BigInt.from(31);
    final assetId = solanaCompressedAssetId(tree.toBase58(), nonce)!;
    final leaf = [...List.filled(96, 4), ..._u64(nonce), ..._u32(31)];
    Instruction transfer(Ed25519HDPublicKey to, {Ed25519HDPublicKey? owner}) =>
        _instruction(
          _bubblegum,
          [
            _meta(config),
            _meta(owner ?? _wallet, signer: owner == null),
            _meta(owner ?? _wallet),
            _meta(to),
            _meta(tree, writable: true),
          ],
          [163, 52, 200, 231, 140, 3, 69, 186, ...leaf],
        );
    Instruction delegate(Ed25519HDPublicKey to) => _instruction(
      _bubblegum,
      [
        _meta(config),
        _meta(_wallet, signer: true),
        _meta(_wallet),
        _meta(to),
        _meta(tree, writable: true),
      ],
      [90, 147, 75, 178, 85, 88, 4, 137, ...leaf],
    );

    /// [instruction] as a node reports a call another program made.
    Map<String, Object?> innerCall(Instruction instruction) => {
      'index': 0,
      'instructions': [
        {
          'programId': instruction.programId.toBase58(),
          'accounts': [
            for (final account in instruction.accounts)
              account.pubKey.toBase58(),
          ],
          'data': base58encode(instruction.data.toList()),
          'stackHeight': 2,
        },
      ],
    };

    /// A marketplace instruction whose accounts are [others] after the
    /// wallet's.
    Instruction marketCall(List<Ed25519HDPublicKey> others) => _instruction(
      _market,
      [
        _meta(_wallet, signer: true, writable: true),
        for (final other in others) _meta(other),
      ],
      const [1, 2, 3, 4, 5, 6, 7, 8],
    );

    testWidgets('a compressed NFT leaving is a movement, by name', (
      tester,
    ) async {
      final instruction = transfer(_attacker);
      // Read from the bytes alone it is already there.
      final unsimulated = _unsimulated([instruction]).nfts.single;
      expect(
        (unsimulated.assetId, unsimulated.from, unsimulated.to),
        (assetId, _walletAddress, _attacker.toBase58()),
      );

      final review = await tester.runAsync(
        () => _simulate([
          instruction,
        ], _honestNode(assets: {assetId: 'Night Garden #7'})),
      );
      final approved = await _show(tester, review!);
      expect(find.text('You send'), findsNWidgets(2));
      expect(find.text('0.000005 SOL'), findsWidgets);
      expect(find.text('Night Garden #7'), findsOneWidget);
      expect(find.byKey(const Key('review-fee-only')), findsNothing);
      // A plain move, shown: no warning and no hold, like sending a token.
      expect(find.byType(ReviewCautionCard), findsNothing);
      expect(find.text('PERMISSION'), findsNothing);
      await _expectTap(tester, approved);
    });

    testWidgets('one a marketplace moves for the wallet is read from the '
        'call the program makes', (tester) async {
      final escrow = _unique(52);
      final review = await tester.runAsync(
        () => _simulate([
          marketCall([config, escrow, tree, _bubblegum]),
        ], _honestNode(inner: [innerCall(transfer(escrow))])),
      );
      final move = review!.nfts.single;
      expect((move.assetId, move.to), (assetId, escrow.toBase58()));
      await _show(tester, review);
      expect(find.text('You send'), findsNWidgets(2));
      // No lookup named it, so it is called what it is.
      expect(find.text('Compressed NFT'), findsOneWidget);
      expect(find.text(_short(assetId)), findsOneWidget);
      expect(find.byType(ReviewCautionCard), findsNothing);
    });

    testWidgets('one arriving is shown as received', (tester) async {
      final seller = _unique(53);
      final review = await tester.runAsync(
        () => _simulate([
          transfer(_wallet, owner: seller),
        ], _honestNode(assets: {assetId: 'Night Garden #7'})),
      );
      await _show(tester, review!);
      expect(find.text('You receive'), findsOneWidget);
      expect(find.text('Night Garden #7'), findsOneWidget);
    });

    testWidgets('letting another wallet move it gets the Permission card', (
      tester,
    ) async {
      final review = await tester.runAsync(
        () => _simulate([
          delegate(_attacker),
        ], _honestNode(assets: {assetId: 'Night Garden #7'})),
      );
      final grant = review!.accounts.singleWhere(
        (a) => a.kind == AccountChangeKind.approve,
      );
      expect(
        (grant.address, grant.beneficiary),
        (assetId, _attacker.toBase58()),
      );
      final approved = await _show(tester, review);
      expect(find.text('PERMISSION'), findsOneWidget);
      expect(
        find.text('Permission to transfer Night Garden #7'),
        findsOneWidget,
      );
      expect(find.text('Delegating'), findsOneWidget);
      // The simulation ran, and still: what it grants outlasts the
      // transaction, so approving is never the tap a finger was making.
      await _expectHold(tester, approved);
    });

    for (final (name, discriminator, frozen) in [
      ('DelegateV2', [95, 87, 125, 140, 181, 131, 128, 227], false),
      ('DelegateAndFreezeV2', [17, 229, 35, 218, 190, 241, 250, 123], true),
    ]) {
      testWidgets('$name with the owner left out is the payer\'s delegation, '
          'and gets the Permission card', (tester) async {
        // The owner is optional. Left out, its position holds Bubblegum's
        // own address and the program takes the payer: the wallet.
        final instruction = _instruction(
          _bubblegum,
          [
            _meta(config),
            _meta(_wallet, signer: true, writable: true),
            _meta(_bubblegum),
            _meta(_bubblegum),
            _meta(_attacker),
            _meta(tree, writable: true),
          ],
          [
            ...discriminator,
            ...List.filled(96, 4),
            0,
            0,
            0,
            ..._u64(nonce),
            ..._u32(31),
          ],
        );
        // Read from the bytes alone it is already there.
        final unsimulated = _unsimulated([
          instruction,
        ]).accounts.singleWhere((a) => a.kind == AccountChangeKind.approve);
        expect(
          (unsimulated.address, unsimulated.beneficiary),
          (assetId, _attacker.toBase58()),
        );

        final review = await tester.runAsync(
          () => _simulate([
            instruction,
          ], _honestNode(assets: {assetId: 'Night Garden #7'})),
        );
        final grant = review!.accounts.singleWhere(
          (a) => a.kind == AccountChangeKind.approve,
        );
        expect(
          (grant.address, grant.beneficiary),
          (assetId, _attacker.toBase58()),
        );
        expect(
          review.accounts.any((a) => a.kind == AccountChangeKind.freeze),
          frozen,
        );
        final approved = await _show(tester, review);
        expect(find.text('PERMISSION'), findsOneWidget);
        expect(
          find.text('Permission to transfer Night Garden #7'),
          findsOneWidget,
        );
        expect(find.text(_short(_attacker.toBase58())), findsWidgets);
        expect(
          find.text(frozen ? 'Lock and delegate' : 'Delegating'),
          findsOneWidget,
        );
        // Not "only the fee".
        expect(find.byKey(const Key('review-fee-only')), findsNothing);
        await _expectHold(tester, approved);
      });
    }

    testWidgets('a compressed NFT\'s name is drawn as one line of plain '
        'text', (tester) async {
      // Anyone can write an NFT's metadata. A direction override would
      // reorder the words of the card around the name; a line break would
      // split its title.
      final review = await tester.runAsync(
        () => _simulate(
          [delegate(_attacker)],
          _honestNode(
            assets: {assetId: '\u202ENight\u2066 Garden\r\n\t#7\u0000\u200F'},
          ),
        ),
      );
      expect(review!.nftMetadata[assetId]?.name, 'Night Garden #7');
      await _show(tester, review);
      expect(
        find.text('Permission to transfer Night Garden #7'),
        findsOneWidget,
      );

      // A name with nothing readable in it is no name.
      final unnamed = await tester.runAsync(
        () => _simulate([
          transfer(_attacker),
        ], _honestNode(assets: {assetId: '\u202E\u200B \n\u2069'})),
      );
      expect(unnamed!.nftMetadata[assetId]?.name, 'Compressed NFT');
      await _show(tester, unnamed);
      expect(find.text('Compressed NFT'), findsOneWidget);
    });

    testWidgets('a delegation to a program address gets the Permission card '
        'and the hold when the website asks Bubblegum for it directly, and '
        'neither when a listed marketplace\'s own code makes it', (
      tester,
    ) async {
      const labels = {
        'MMA7VebX8Pi5JrrvaTBBm7nW81sfCww7ZtLBBT1YCy8': 'A Marketplace',
        solanaBubblegumProgram: 'Metaplex Bubblegum',
      };
      // The website chose the delegate, and an address of a program it
      // deployed looks like any other.
      final direct = await tester.runAsync(
        () => _simulate([delegate(_programAddress)], _honestNode()),
      );
      expect(direct!.delegatedBy, {
        assetId: {solanaBubblegumProgram},
      });
      var approved = await _show(tester, direct, labels: labels);
      expect(find.text('PERMISSION'), findsOneWidget);
      expect(
        find.text('Permission to transfer Compressed NFT'),
        findsOneWidget,
      );
      expect(find.text(_short(_programAddress.toBase58())), findsWidgets);
      await _expectHold(tester, approved);

      final listed = await tester.runAsync(
        () => _simulate([
          marketCall([config, _programAddress, tree, _bubblegum]),
        ], _honestNode(inner: [innerCall(delegate(_programAddress))])),
      );
      expect(listed!.delegatedBy, {
        assetId: {_market.toBase58()},
      });
      approved = await _show(tester, listed, labels: labels);
      expect(find.text('PERMISSION'), findsNothing);
      // The row still says what was granted.
      expect(find.text('Delegating'), findsOneWidget);
      await _expectTap(tester, approved);

      // The same call from a marketplace that is not on the list.
      approved = await _show(tester, listed);
      expect(find.text('PERMISSION'), findsOneWidget);
      await _expectHold(tester, approved);
    });

    final stakeAccount = _unique(54);
    final clock = _address('SysvarC1ock11111111111111111111111111111111');

    /// Stake Authorize: the wallet hands the withdraw authority to [next].
    Instruction authorize(Ed25519HDPublicKey next) => _instruction(
      _stake,
      [
        _meta(stakeAccount, writable: true),
        _meta(clock),
        _meta(_wallet, signer: true),
      ],
      [..._u32(1), ...next.bytes, ..._u32(1)],
    );
    const stakeHandover =
        'Control of a stake account\'s withdraw authority changes';

    testWidgets('handing on a stake account\'s withdraw authority gets the '
        'Authority card and the hold', (tester) async {
      final review = await tester.runAsync(
        () => _simulate([authorize(_attacker)], _honestNode()),
      );
      expect(review!.delegatedBy, {
        stakeAccount.toBase58(): {solanaStakeProgram},
      });
      final approved = await _show(tester, review);
      expect(find.text('AUTHORITY'), findsOneWidget);
      expect(find.text(stakeHandover), findsOneWidget);
      expect(find.text(_short(_attacker.toBase58())), findsOneWidget);
      expect(find.byKey(const Key('review-fee-only')), findsNothing);
      await _expectHold(tester, approved);
    });

    testWidgets('a listed program that takes a stake account into its own '
        'keeping is an account row, with no card and no hold', (tester) async {
      const labels = {
        'MMA7VebX8Pi5JrrvaTBBm7nW81sfCww7ZtLBBT1YCy8': 'A Staking Pool',
        solanaStakeProgram: 'Stake Program',
      };
      final review = await tester.runAsync(
        () => _simulate(
          [
            marketCall([stakeAccount, clock, _stake]),
          ],
          _honestNode(
            inner: [
              _innerCalls([authorize(_programAddress)]),
            ],
          ),
        ),
      );
      expect(review!.delegatedBy, {
        stakeAccount.toBase58(): {_market.toBase58()},
      });
      var approved = await _show(tester, review, labels: labels);
      expect(find.text('AUTHORITY'), findsNothing);
      // Still shown, or the review would say only the fee was found.
      expect(find.text('Account changes'), findsOneWidget);
      expect(find.text(stakeHandover), findsOneWidget);
      expect(find.text(_short(stakeAccount.toBase58())), findsOneWidget);
      expect(find.text(_short(_programAddress.toBase58())), findsOneWidget);
      expect(find.byKey(const Key('review-fee-only')), findsNothing);
      await _expectTap(tester, approved);

      // The same from a program that is not on the list, and the website
      // asking the Stake Program itself.
      approved = await _show(tester, review);
      expect(find.text('AUTHORITY'), findsOneWidget);
      await _expectHold(tester, approved);
      final direct = await tester.runAsync(
        () => _simulate([authorize(_programAddress)], _honestNode()),
      );
      approved = await _show(tester, direct!, labels: labels);
      expect(find.text('AUTHORITY'), findsOneWidget);
      await _expectHold(tester, approved);
    });

    testWidgets('one the node reports by its named fields is not traced to '
        'its account, so it keeps the card and the hold', (tester) async {
      const labels = {
        'MMA7VebX8Pi5JrrvaTBBm7nW81sfCww7ZtLBBT1YCy8': 'A Staking Pool',
        solanaStakeProgram: 'Stake Program',
      };
      final review = await tester.runAsync(
        () => _simulate(
          [
            marketCall([stakeAccount, clock, _stake]),
          ],
          _honestNode(
            inner: [
              {
                'index': 0,
                'instructions': [
                  {
                    'programId': solanaStakeProgram,
                    'parsed': {
                      'type': 'authorize',
                      'info': {
                        'stakeAccount': stakeAccount.toBase58(),
                        'authority': _walletAddress,
                        'newAuthority': _programAddress.toBase58(),
                        'authorityType': 'Withdrawer',
                      },
                    },
                    'stackHeight': 2,
                  },
                ],
              },
            ],
          ),
        ),
      );
      expect(review!.delegatedBy, {
        kUntracedDelegations: {_market.toBase58()},
      });
      final approved = await _show(tester, review, labels: labels);
      expect(find.text('AUTHORITY'), findsOneWidget);
      expect(find.text(stakeHandover), findsOneWidget);
      await _expectHold(tester, approved);
    });

    testWidgets('SOL withdrawn from a stake account to someone else is a '
        'movement, though no balance of the wallet\'s shows it', (
      tester,
    ) async {
      final stake = _unique(55);
      final sysvar = _address('SysvarC1ock11111111111111111111111111111111');
      final history = _address('SysvarStakeHistory1111111111111111111111111');
      final withdraw = _instruction(
        _stake,
        [
          _meta(stake, writable: true),
          _meta(_attacker, writable: true),
          _meta(sysvar),
          _meta(history),
          _meta(_wallet, signer: true),
        ],
        [..._u32(4), ..._u64(BigInt.from(12000000000))],
      );
      final review = await tester.runAsync(
        () => _simulate([withdraw], _honestNode()),
      );
      await _show(tester, review!);
      expect(find.text('You send'), findsNWidgets(2));
      expect(find.text('12 SOL'), findsOneWidget);
      expect(find.text(_short(_attacker.toBase58())), findsOneWidget);
      expect(
        find.textContaining('read from the request itself'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('review-fee-only')), findsNothing);
    });

    // A node reports the System calls a program makes by their named fields,
    // with no data: inside another program's call they arrive only like this.
    Map<String, Object?> systemCalls(
      List<(String, Map<String, Object?>)> calls,
    ) => {
      'index': 0,
      'instructions': [
        for (final (type, info) in calls)
          {
            'programId': solanaSystemProgram,
            'parsed': {'type': type, 'info': info},
            'stackHeight': 2,
          },
      ],
    };

    testWidgets('SOL a program takes out of a nonce account or a seeded '
        'account the wallet controls is a movement, though no balance of '
        'the wallet\'s shows it', (tester) async {
      final nonce = _unique(56);
      final derived = _unique(57);
      final review = await tester.runAsync(
        () => _simulate(
          [
            marketCall([nonce, derived, _attacker, _system]),
          ],
          _honestNode(
            inner: [
              systemCalls([
                (
                  'withdrawFromNonce',
                  {
                    'nonceAccount': nonce.toBase58(),
                    'destination': _attacker.toBase58(),
                    'nonceAuthority': _walletAddress,
                    'lamports': 2000000000,
                  },
                ),
                (
                  'transferWithSeed',
                  {
                    'source': derived.toBase58(),
                    'sourceBase': _walletAddress,
                    'destination': _attacker.toBase58(),
                    'lamports': 3000000000,
                    'sourceSeed': 'seed',
                    'sourceOwner': solanaSystemProgram,
                  },
                ),
                // Another account's nonce, and SOL that comes to the wallet:
                // neither is the wallet's to lose.
                (
                  'withdrawFromNonce',
                  {
                    'nonceAccount': _unique(58).toBase58(),
                    'destination': _attacker.toBase58(),
                    'nonceAuthority': _unique(59).toBase58(),
                    'lamports': 7000000000,
                  },
                ),
              ]),
            ],
          ),
        ),
      );
      expect(
        review!.funds
            .where((fund) => fund.address != _walletAddress)
            .map((fund) => (fund.address, fund.rawAmount, fund.to)),
        [
          (nonce.toBase58(), BigInt.from(-2000000000), _attacker.toBase58()),
          (derived.toBase58(), BigInt.from(-3000000000), _attacker.toBase58()),
        ],
      );
      await _show(tester, review);
      expect(find.text('2 SOL'), findsOneWidget);
      expect(find.text('3 SOL'), findsOneWidget);
      expect(find.text('7 SOL'), findsNothing);
      expect(find.byKey(const Key('review-fee-only')), findsNothing);
    });

    testWidgets('the wallet\'s own account handed to a program inside a '
        'program\'s call takes the hold, and a program\'s own account is '
        'its plumbing', (tester) async {
      Map<String, Object?> assign(String account) => systemCalls([
        ('assign', {'account': account, 'owner': _attacker.toBase58()}),
      ]);
      final mine = await tester.runAsync(
        () => _simulate([
          marketCall([_system]),
        ], _honestNode(inner: [assign(_walletAddress)])),
      );
      var approved = await _show(tester, mine!);
      expect(find.text('AUTHORITY'), findsOneWidget);
      expect(find.text('Assign account to a program'), findsOneWidget);
      expect(find.byKey(const Key('review-fee-only')), findsNothing);
      await _expectHold(tester, approved);

      final theirs = await tester.runAsync(
        () => _simulate([
          marketCall([_system]),
        ], _honestNode(inner: [assign(_unique(60).toBase58())])),
      );
      expect(
        theirs!.accounts.where(
          (change) => change.kind == AccountChangeKind.authority,
        ),
        isEmpty,
      );
      approved = await _show(tester, theirs);
      expect(find.text('AUTHORITY'), findsNothing);
      await _expectTap(tester, approved);
    });

    testWidgets('a nonce account\'s authority handed on inside a program\'s '
        'call takes the hold', (tester) async {
      final nonce = _unique(61);
      final review = await tester.runAsync(
        () => _simulate(
          [
            marketCall([nonce, _system]),
          ],
          _honestNode(
            inner: [
              systemCalls([
                (
                  'authorizeNonce',
                  {
                    'nonceAccount': nonce.toBase58(),
                    'nonceAuthority': _walletAddress,
                    'newAuthorized': _attacker.toBase58(),
                  },
                ),
              ]),
            ],
          ),
        ),
      );
      final approved = await _show(tester, review!);
      expect(find.text('AUTHORITY'), findsOneWidget);
      expect(find.text('Control of a nonce account changes'), findsOneWidget);
      await _expectHold(tester, approved);
    });

    testWidgets('a Bubblegum instruction it cannot read is a caution, when '
        'the wallet is named', (tester) async {
      final unknown = _instruction(
        _bubblegum,
        [
          _meta(config),
          _meta(_wallet, signer: true),
          _meta(tree, writable: true),
        ],
        const [9, 9, 9, 9, 9, 9, 9, 9, 1, 2, 3],
      );
      final review = await tester.runAsync(
        () => _simulate([unknown], _honestNode()),
      );
      await _show(tester, review!);
      expect(
        find.descendant(
          of: find.byType(ReviewCautionCard),
          matching: find.text(
            'A Metaplex Bubblegum instruction could not be read. It may change who controls what your wallet holds there.',
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('when only the fee was found the review says so, and lists '
        'the programs without being asked', (tester) async {
      final review = await tester.runAsync(
        () => _simulate([
          marketCall([config]),
        ], _honestNode()),
      );
      expect(review!.warnings, contains(kSolanaUnreadProgramsWarning));
      final approved = await _show(tester, review);
      expect(find.text('You send'), findsOneWidget);
      expect(find.text('0.000005 SOL'), findsWidgets);
      expect(find.byKey(const Key('review-fee-only')), findsOneWidget);
      // One plain line, not a second one and not a card.
      expect(find.byKey(const Key('review-unread-programs')), findsNothing);
      expect(find.byType(ReviewCautionCard), findsNothing);
      expect(find.text('Unknown Program'), findsOneWidget);
      expect(find.text(_short(_market.toBase58())), findsOneWidget);
      await _expectTap(tester, approved);
    });
  });

  group('a Tezos operation the wallet cannot read', () {
    const account = 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL';
    const transfer = {
      'kind': 'transaction',
      'destination': account,
      'amount': '2000000',
    };

    test('a known operation followed by one it does not read is refused '
        'whole, before any review', () {
      for (final unread in [
        {
          'kind': 'origination',
          'balance': '1000000',
          'script': <String, Object?>{},
        },
        {'kind': 'increase_paid_storage', 'amount': '1'},
        {'kind': 'transaction', ...transfer, 'unknown_field': '1'},
        'not an operation',
      ]) {
        expect(
          () => TezosDappOperationRequest.parse([
            transfer,
            unread,
          ], account: account),
          throwsA(isA<DappException>()),
          reason: '$unread',
        );
      }
      // The readable one alone is accepted.
      expect(
        TezosDappOperationRequest.parse([
          transfer,
        ], account: account).toJson().single['amount'],
        '2000000',
      );
    });

    test('forged operation bytes are never signed as a message', () {
      // Watermark 03 is an operation; only a packed text message is signed.
      final operation = Uint8List.fromList([3, ...List.filled(72, 0)]);
      expect(
        () => TezosMessageReview(
          payload: operation,
          origin: _origin,
          address: account,
          walletId: 'w',
          signingType: 'raw',
        ),
        throwsA(isA<DappException>()),
      );
      expect(
        TezosMessageReview(
          payload: MultiChainDerivation.packTezosMicheline('hello'),
          origin: _origin,
          address: account,
          walletId: 'w',
          signingType: 'micheline',
        ).text,
        'hello',
      );
    });
  });

  group('a transfer whose direction was guessed', () {
    final source = _unique(60);
    final destination = _unique(61);
    final amount = [12, ..._u64(BigInt.from(5000000000)), 6];
    Instruction transferChecked(
      Ed25519HDPublicKey authority, {
      Ed25519HDPublicKey? to,
    }) => _instruction(_token, [
      _meta(source, writable: true),
      _meta(_usdc),
      _meta(to ?? destination, writable: true),
      _meta(authority, signer: true),
    ], amount);

    testWidgets('the wallet sends what the wallet authorises, with no node '
        'to ask', (tester) async {
      final review = await tester.runAsync(
        () => _simulate([transferChecked(_wallet)], _refusing),
      );
      final approved = await _show(tester, review!);
      expect(find.text('You send'), findsOneWidget);
      expect(find.text('You receive'), findsNothing);
      expect(find.text('5,000 USDC'), findsOneWidget);
      expect(find.text(_short(destination.toBase58())), findsOneWidget);
      await _expectHold(tester, approved);
    });

    testWidgets('the wallet receives only what goes to its own account', (
      tester,
    ) async {
      final review = await tester.runAsync(() async {
        final mine = await findAssociatedTokenAddress(
          owner: _wallet,
          mint: _usdc,
        );
        return _simulate([transferChecked(_unique(62), to: mine)], _refusing);
      });
      await _show(tester, review!);
      expect(find.text('You receive'), findsOneWidget);
      expect(find.text('You send'), findsNothing);
      expect(find.text('5,000 USDC'), findsOneWidget);
    });

    testWidgets('a transfer between two other accounts gets no direction', (
      tester,
    ) async {
      final other = _unique(63);
      final recipient = _unique(64);
      final review = await tester.runAsync(
        () => _simulate([
          transferChecked(other),
          _instruction(
            _system,
            [
              _meta(other, signer: true, writable: true),
              _meta(recipient, writable: true),
            ],
            [..._u32(2), ..._u64(BigInt.from(500000000000))],
          ),
        ], _refusing),
      );
      expect(review!.funds, isEmpty);
      await _show(tester, review);
      expect(find.text('You send'), findsNothing);
      expect(find.text('You receive'), findsNothing);
      // Listed for what they are: someone else's.
      expect(
        find.text('Transfer of 5000 tokens between other accounts'),
        findsOneWidget,
      );
      expect(
        find.text('Transfer of 500 SOL between other accounts'),
        findsOneWidget,
      );
    });
  });

  group('bytes after an instruction\'s own', () {
    // The System and Token programs ignore what follows an instruction's own
    // bytes, so one more byte must not make the review read it as something
    // else, or not at all.
    const extra =
        'has extra bytes after its own. The program ignores them, and so does this review.';

    testWidgets('a token authority handed on is not shown as given up', (
      tester,
    ) async {
      final account = _unique(80);
      // SetAuthority, the account's owner, "a new one follows", the new
      // owner, and one byte more.
      final handOn = _instruction(
        _token,
        [_meta(account, writable: true), _meta(_wallet, signer: true)],
        [6, 2, 1, ..._attacker.bytes, 0],
      );
      final change = _unsimulated([handOn]).accounts.single;
      expect(
        (change.kind, change.address, change.beneficiary),
        (AccountChangeKind.authority, account.toBase58(), _attacker.toBase58()),
      );

      final review = await tester.runAsync(
        () => _simulate([handOn], _honestNode()),
      );
      final approved = await _show(tester, review!);
      expect(find.text('AUTHORITY'), findsOneWidget);
      expect(find.text('Change token authority (type 2)'), findsOneWidget);
      expect(find.text(_short(_attacker.toBase58())), findsOneWidget);
      expect(
        find.textContaining('authority removed', findRichText: true),
        findsNothing,
      );
      expect(find.byKey(const Key('review-fee-only')), findsNothing);
      await _expectHold(tester, approved);
    });

    test('an authority is removed only when the instruction says so', () {
      final account = _unique(80);
      SimulationReview setAuthority(List<int> data) => _unsimulated([
        _instruction(_token, [
          _meta(account, writable: true),
          _meta(_wallet, signer: true),
        ], data),
      ]);
      // "No new one follows", with or without bytes after it.
      for (final data in [
        [6, 2, 0],
        [6, 2, 0, 9, 9],
      ]) {
        expect(
          setAuthority(data).accounts.single.beneficiary,
          'Remove authority',
          reason: '$data',
        );
      }
      // A new authority cut short, and a flag that is neither: the program
      // runs neither, and neither is given a meaning.
      for (final data in [
        [6, 2, 1, ..._attacker.bytes.take(31)],
        [6, 2, 7, ..._attacker.bytes],
      ]) {
        final review = setAuthority(data);
        expect(review.accounts, isEmpty, reason: '$data');
        expect(review.warnings, [
          'An instruction references accounts or data that could not be decoded.',
        ]);
      }
    });

    test('a System transfer still shows the SOL it sends', () {
      final review = _unsimulated([
        _instruction(
          _system,
          [
            _meta(_wallet, signer: true, writable: true),
            _meta(_attacker, writable: true),
          ],
          [..._u32(2), ..._u64(BigInt.from(50000000000)), 0],
        ),
      ]);
      final fund = review.funds.single;
      expect(
        (fund.rawAmount, fund.to),
        (-BigInt.from(50000000000), _attacker.toBase58()),
      );
      // Read, and said to be unusual.
      expect(review.warnings, [
        'A System Program instruction (Transfer) $extra',
      ]);
    });

    test('a new account and an account handed to a program are read the '
        'same way', () {
      final account = _unique(81);
      final program = _unique(82);
      final created = _unsimulated([
        _instruction(
          _system,
          [
            _meta(_wallet, signer: true, writable: true),
            _meta(account, signer: true, writable: true),
          ],
          [
            ..._u32(0),
            ..._u64(BigInt.from(7000000000)),
            ..._u64(BigInt.zero),
            ...program.bytes,
            1,
            2,
          ],
        ),
      ]);
      expect(created.funds.single.rawAmount, -BigInt.from(7000000000));
      expect(
        (created.accounts.single.kind, created.accounts.single.beneficiary),
        (AccountChangeKind.create, program.toBase58()),
      );
      expect(created.warnings, [
        'A System Program instruction (CreateAccount) $extra',
      ]);

      final assigned = _unsimulated([
        _instruction(
          _system,
          [_meta(_wallet, signer: true, writable: true)],
          [..._u32(1), ...program.bytes, 0],
        ),
      ]);
      // The program it goes to is the 32 bytes the program reads, not those
      // and the one after.
      expect(
        (
          assigned.accounts.single.kind,
          assigned.accounts.single.address,
          assigned.accounts.single.beneficiary,
        ),
        (AccountChangeKind.authority, _walletAddress, program.toBase58()),
      );
      expect(assigned.warnings, [
        'A System Program instruction (Assign) $extra',
      ]);
    });

    test('a checked transfer and burn keep their precision', () {
      final source = _unique(83);
      final destination = _unique(84);
      final transfer = _unsimulated([
        _instruction(
          _token,
          [
            _meta(source, writable: true),
            _meta(_usdc),
            _meta(destination, writable: true),
            _meta(_wallet, signer: true),
          ],
          [12, ..._u64(BigInt.from(5000000)), 6, 0],
        ),
      ]).funds.single;
      expect(
        (transfer.rawAmount, transfer.asset.decimals),
        (-BigInt.from(5000000), 6),
      );
      final burn = _unsimulated([
        _instruction(
          _token,
          [
            _meta(source, writable: true),
            _meta(_usdc, writable: true),
            _meta(_wallet, signer: true),
          ],
          [15, ..._u64(BigInt.from(9000000)), 6, 0],
        ),
      ]).funds.single;
      expect((burn.rawAmount, burn.asset.decimals), (-BigInt.from(9000000), 6));
    });

    test('someone else\'s transfer with a byte more is theirs, and no '
        'caution', () {
      final other = _unique(85);
      final review = _unsimulated([
        _instruction(
          _system,
          [
            _meta(other, signer: true, writable: true),
            _meta(_attacker, writable: true),
          ],
          [..._u32(2), ..._u64(BigInt.from(1000000000)), 0],
        ),
      ]);
      expect(review.funds, isEmpty);
      expect(
        review.accounts.single.description,
        'Transfer of 1 SOL between other accounts',
      );
      expect(review.warnings, isEmpty);
    });
  });

  group('a Core NFT nobody takes, but someone may', () {
    // A Core NFT's owner does not change when it is given a transfer
    // delegate, so the simulation's accounts show nothing: the fee, and a
    // plain Approve.
    final asset = _unique(90);
    final assetId = asset.toBase58();
    final name = 'NFT · ${_short(assetId)}';
    // The plugin types a holder can hand on, in the program's numbering.
    const freeze = 1, burn = 2, transfer = 3;

    // [asset, collection (left out), payer, authority, system program]
    List<AccountMeta> accounts(Ed25519HDPublicKey authority) => [
      _meta(asset, writable: true),
      _meta(_core),
      _meta(_wallet, signer: true, writable: true),
      _meta(authority, signer: authority != _core),
      _meta(_system),
    ];

    /// ApprovePluginAuthorityV1: the transfer delegate goes to [to].
    Instruction approveAuthority(
      Ed25519HDPublicKey to, {
      Ed25519HDPublicKey? authority,
      int plugin = transfer,
    }) => _instruction(_core, accounts(authority ?? _wallet), [
      0x08,
      plugin,
      3,
      ...to.bytes,
    ]);

    /// AddPluginV1: the plugin, its own data, and [to] as its first holder.
    Instruction addPlugin(int plugin, Ed25519HDPublicKey to) => _instruction(
      _core,
      accounts(_wallet),
      [0x02, plugin, if (plugin == freeze) 1, 1, 3, ...to.bytes],
    );

    /// A program's instruction over the asset, signed by the wallet.
    Instruction call(Ed25519HDPublicKey program) => _instruction(
      program,
      [
        _meta(_wallet, signer: true, writable: true),
        _meta(asset, writable: true),
        _meta(_programAddress),
        _meta(_core),
        _meta(_system),
      ],
      const [1, 2, 3, 4, 5, 6, 7, 8],
    );
    const labels = {
      'MMA7VebX8Pi5JrrvaTBBm7nW81sfCww7ZtLBBT1YCy8': 'A Marketplace',
      solanaCoreProgram: 'Metaplex Core',
      solanaSystemProgram: 'System Program',
    };

    testWidgets('letting another wallet move it gets the Permission card and '
        'the hold', (tester) async {
      // Named outright, added with the plugin, and with the signing account
      // left out: Core's own address stands there, and the payer signs.
      for (final instruction in [
        approveAuthority(_attacker),
        addPlugin(transfer, _attacker),
        approveAuthority(_attacker, authority: _core),
      ]) {
        // Read from the bytes alone it is already there.
        final unsimulated = _unsimulated([instruction]);
        final grant = unsimulated.accounts.singleWhere(
          (a) => a.kind == AccountChangeKind.approve,
        );
        expect(
          (grant.address, grant.assetId, grant.beneficiary, grant.power),
          (assetId, assetId, _attacker.toBase58(), NftDelegatePower.transfer),
        );
        expect(grant.rawAllowance, BigInt.one);
        expect(unsimulated.nftMetadata.containsKey(assetId), isTrue);

        final review = await tester.runAsync(
          () => _simulate([instruction], _honestNode()),
        );
        expect(review!.execution, SimulationExecution.succeeded);
        expect(review.delegatedBy, {
          assetId: {solanaCoreProgram},
        });
        final approved = await _show(tester, review);
        expect(find.text('PERMISSION'), findsOneWidget);
        expect(find.text('Permission to transfer $name'), findsOneWidget);
        expect(find.text(_short(_attacker.toBase58())), findsWidgets);
        expect(find.text('Delegating'), findsOneWidget);
        // Not "only the fee".
        expect(find.byKey(const Key('review-fee-only')), findsNothing);
        expect(
          find.text('No asset changes could be identified.'),
          findsNothing,
        );
        await _expectHold(tester, approved);
      }
    });

    testWidgets('it shows by name when an asset lookup knows it, and says '
        'what a burn or freeze delegate may do', (tester) async {
      for (final (plugin, title) in [
        (burn, 'Permission to burn Night Garden #7'),
        (freeze, 'Permission to lock Night Garden #7'),
      ]) {
        final review = await tester.runAsync(
          () => _simulate(
            [approveAuthority(_attacker, plugin: plugin)],
            // Anyone can write an NFT's name: it is cleaned as others are.
            _honestNode(assets: {assetId: '\u202ENight Garden\n#7'}),
          ),
        );
        final approved = await _show(tester, review!);
        expect(find.text('PERMISSION'), findsOneWidget);
        expect(find.text(title), findsOneWidget);
        await _expectHold(tester, approved);
      }
    });

    testWidgets('a freeze delegate and a transfer delegate are two grants', (
      tester,
    ) async {
      final review = await tester.runAsync(
        () => _simulate([
          addPlugin(freeze, _attacker),
          addPlugin(transfer, _attacker),
        ], _honestNode()),
      );
      await _show(tester, review!);
      expect(find.text('PERMISSION'), findsNWidgets(2));
      expect(find.text('Permission to lock $name'), findsOneWidget);
      expect(find.text('Permission to transfer $name'), findsOneWidget);
    });

    testWidgets('a listed marketplace that takes it into its own keeping '
        'gets no card and no hold', (tester) async {
      // The marketplace locks a listed NFT and makes an address of its own
      // the delegate, in calls it makes itself. The wallet asked for the
      // listing; that is the review.
      final review = await tester.runAsync(
        () => _simulate(
          [call(_market)],
          _honestNode(
            inner: [
              _innerCalls([
                addPlugin(freeze, _programAddress),
                addPlugin(transfer, _programAddress),
              ]),
            ],
          ),
        ),
      );
      expect(review!.delegatedBy, {
        assetId: {_market.toBase58()},
      });
      expect(
        review.accounts
            .where((a) => a.kind == AccountChangeKind.approve)
            .map((a) => (a.beneficiary, a.power)),
        [
          (_programAddress.toBase58(), NftDelegatePower.freeze),
          (_programAddress.toBase58(), NftDelegatePower.transfer),
        ],
      );
      final approved = await _show(tester, review, labels: labels);
      expect(find.text('PERMISSION'), findsNothing);
      // Each delegate still has its row.
      expect(find.text('Delegating'), findsNWidgets(2));
      expect(find.text(name), findsNWidgets(2));
      expect(
        find.textContaining('can lock it until revoked', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'can transfer it until revoked',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('review-fee-only')), findsNothing);
      await _expectTap(tester, approved);
    });

    testWidgets('the same calls from a program that is not on the list get '
        'the card and the hold', (tester) async {
      final unlisted = _unique(91);
      final review = await tester.runAsync(
        () => _simulate(
          [call(unlisted)],
          _honestNode(
            inner: [
              _innerCalls([addPlugin(transfer, _programAddress)]),
            ],
          ),
        ),
      );
      expect(review!.delegatedBy, {
        assetId: {unlisted.toBase58()},
      });
      final approved = await _show(tester, review, labels: labels);
      expect(find.text('PERMISSION'), findsOneWidget);
      expect(find.text('Permission to transfer $name'), findsOneWidget);
      await _expectHold(tester, approved);
    });

    testWidgets('a listed marketplace that hands it to someone\'s wallet '
        'gets the card and the hold', (tester) async {
      // A program that lets its caller name any holder is no better than
      // the caller.
      final review = await tester.runAsync(
        () => _simulate(
          [call(_market)],
          _honestNode(
            inner: [
              _innerCalls([addPlugin(transfer, _attacker)]),
            ],
          ),
        ),
      );
      final approved = await _show(tester, review!, labels: labels);
      expect(find.text('PERMISSION'), findsOneWidget);
      await _expectHold(tester, approved);
    });

    test('another signer\'s NFT, and a delegate that is the wallet itself, '
        'are not the wallet\'s grant', () {
      final other = _unique(92);
      for (final instruction in [
        // The wallet only pays; someone else signs for the asset.
        approveAuthority(_attacker, authority: other),
        approveAuthority(_wallet),
      ]) {
        final review = _unsimulated([instruction]);
        expect(
          review.accounts.where((a) => a.kind == AccountChangeKind.approve),
          isEmpty,
        );
      }
    });

    testWidgets('a holder the review cannot show, and ExecuteV1, are a '
        'caution', (tester) async {
      const warning =
          'A Metaplex Core instruction could not be read. It may change who controls what your wallet holds there.';
      for (final data in [
        // A freeze nobody can lift, the update authority given the right to
        // move it, and an instruction of the caller's choosing run for the
        // asset.
        [0x08, freeze, 0],
        [0x08, transfer, 2],
        [0x1f, 1, 2, 3],
      ]) {
        expect(
          _unsimulated([_instruction(_core, accounts(_wallet), data)]).warnings,
          contains(warning),
          reason: '$data',
        );
      }
      final review = await tester.runAsync(
        () => _simulate([
          _instruction(_core, accounts(_wallet), const [0x08, freeze, 0]),
        ], _honestNode()),
      );
      await _show(tester, review!);
      expect(
        find.descendant(
          of: find.byType(ReviewCautionCard),
          matching: find.text(warning),
        ),
        findsOneWidget,
      );
    });
  });

  group('a batch of approvals, each simulated on its own', () {
    final account = _unique(70);
    final max = BigInt.parse('18446744073709551615');

    /// The wallet's token account, holding 500 of [_usdc], with [allowance]
    /// delegated to [_attacker] when it is given.
    Map<String, Object?> tokenAccount([BigInt? allowance]) {
      final bytes = Uint8List(165);
      bytes.setRange(0, 32, _usdc.bytes);
      bytes.setRange(32, 64, _wallet.bytes);
      bytes.setRange(64, 72, _u64(BigInt.from(500)));
      bytes[108] = 1;
      if (allowance != null) {
        bytes[72] = 1;
        bytes.setRange(76, 108, _attacker.bytes);
        bytes.setRange(121, 129, _u64(allowance));
      }
      return {
        'owner': solanaTokenProgram,
        'lamports': 2039280,
        'data': [base64Encode(bytes), 'base64'],
      };
    }

    /// A node on which each transaction's approval takes effect.
    Future<Object?> node(
      String chain,
      String method,
      List<Object?> params,
    ) async {
      Object? state(Object? address, BigInt? allowance) =>
          address == _walletAddress
          ? _systemAccount(1000000000)
          : address == account.toBase58()
          ? tokenAccount(allowance)
          : null;
      switch (method) {
        case 'getMultipleAccounts':
          return {
            'context': {'slot': 10},
            'value': [
              for (final address in params.first as List) state(address, null),
            ],
          };
        case 'simulateTransaction':
          final data = parseDappTransaction(
            base64Decode(params.first as String),
          ).compiledMessage.instructions.single.data.toList();
          var allowance = BigInt.zero;
          for (var i = 8; i >= 1; i--) {
            allowance = (allowance << 8) | BigInt.from(data[i]);
          }
          return {
            'context': {'slot': 10},
            'value': {
              'err': null,
              'fee': 5000,
              'accounts': [
                for (final address
                    in ((params[1] as Map)['accounts'] as Map)['addresses']
                        as List)
                  state(address, allowance),
              ],
            },
          };
        case 'getAssetBatch':
          return <Object?>[];
      }
      throw StateError('unexpected $method');
    }

    Instruction approve(BigInt allowance) => _instruction(
      _token,
      [
        _meta(account, writable: true),
        _meta(_attacker),
        _meta(_wallet, signer: true),
      ],
      [4, ..._u64(allowance)],
    );

    for (final order in [
      [BigInt.one, max],
      [max, BigInt.one],
    ]) {
      testWidgets('${order.first} then ${order.last} to one delegate shows '
          'the unlimited one', (tester) async {
        final parts = await tester.runAsync(
          () => Future.wait([
            for (final allowance in order)
              _simulate([approve(allowance)], node),
          ]),
        );
        final review = combineSolanaReviews(parts!);
        expect(review.execution, SimulationExecution.succeeded);
        await _show(tester, review);
        expect(find.text('PERMISSION'), findsOneWidget);
        expect(find.text('Unlimited USDC allowance'), findsOneWidget);
        expect(
          find.textContaining('Allowance: $max base units'),
          findsOneWidget,
        );
        expect(find.textContaining('Allowance: 1 base units'), findsNothing);
      });
    }
  });
}
