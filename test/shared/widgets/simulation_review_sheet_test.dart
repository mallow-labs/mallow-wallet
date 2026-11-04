import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/simulation_review.dart';
import 'package:mallow_wallet/core/utils/address_format.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/hold_to_approve_button.dart';
import 'package:mallow_wallet/shared/widgets/balance_change_hero.dart';
import 'package:mallow_wallet/shared/widgets/mallow_network_image.dart';
import 'package:mallow_wallet/shared/widgets/simulation_review_sheet.dart';

const _usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const _sol = 'So11111111111111111111111111111111111111112';

SimulationReview _review({
  SimulationExecution execution = SimulationExecution.succeeded,
  SimulationCoverage coverage = SimulationCoverage.complete,
  bool effectsUndecodable = false,
  BigInt? networkFee,
  String chain = 'solana:mainnet',
  String address = '11111111111111111111111111111111',
  String? error,
  List<String> warnings = const [],
  List<FundChange> funds = const [],
  List<AccountChange> accounts = const [],
  List<NftChange> nfts = const [],
  Map<String, ReviewNftMetadata> nftMetadata = const {},
  Map<String, ReviewTokenMetadata> tokenMetadata = const {},
  List<ReviewProgramCall> programCalls = const [],
  List<ReviewTransaction> transactions = const [],
  Uri? explorerUrl,
}) => SimulationReview(
  payloadDigest: 'digest',
  origin: 'https://site.example',
  walletId: 'wallet',
  address: address,
  chain: chain,
  simulatedAt: DateTime.now().toUtc(),
  execution: execution,
  coverage: coverage,
  effectsUndecodable: effectsUndecodable,
  networkFee: networkFee,
  feeLamports: 5000,
  error: error,
  warnings: warnings,
  funds: funds,
  accounts: accounts,
  nfts: nfts,
  nftMetadata: nftMetadata,
  tokenMetadata: tokenMetadata,
  programCalls: programCalls,
  transactions: transactions,
  explorerUrl: explorerUrl,
);

List<FundChange> _swap() => [
  FundChange(
    asset: const ReviewAsset(id: _usdc, symbol: 'Token', decimals: 6),
    address: 'usdc-account',
    rawAmount: BigInt.from(-10000000),
    evidence: ReviewEvidence.simulatedState,
    isNet: true,
  ),
  FundChange(
    asset: const ReviewAsset(id: _sol, symbol: 'SOL', decimals: 9),
    address: 'wallet',
    rawAmount: BigInt.from(63245871),
    evidence: ReviewEvidence.simulatedState,
    isNet: true,
  ),
];

Future<void> _pump(
  WidgetTester tester,
  SimulationReview review, {
  VoidCallback? onApprove,
  VoidCallback? onReject,
  double? Function(String)? priceOf,
  ValueListenable<Map<String, String>>? programLabels,
  Size size = const Size(390, 900),
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: reduceMotion),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SimulationReviewSheet(
              review: review,
              onReject: onReject ?? () {},
              onApprove: onApprove ?? () {},
              priceOf: priceOf,
              programLabels: programLabels,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openDetails(WidgetTester tester) async {
  final details = find.text('Program calls');
  await tester.ensureVisible(details);
  await tester.tap(details);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a normal review approves and rejects with a tap', (
    tester,
  ) async {
    var approved = 0, rejected = 0;
    await _pump(
      tester,
      _review(funds: _swap()),
      onApprove: () => approved++,
      onReject: () => rejected++,
    );
    expect(find.text('Review transaction'), findsOneWidget);
    expect(find.text('You send'), findsOneWidget);
    expect(find.text('10 USDC'), findsOneWidget);
    expect(find.text('0.063245871 SOL'), findsOneWidget);
    expect(find.text('0.000005 SOL'), findsOneWidget);
    // Approve ignores taps for a moment after it first appears.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('approve-signing')));
    await tester.tap(find.byKey(const Key('reject-signing')));
    expect((approved, rejected), (1, 1));
    expect(find.byType(HoldToApproveButton), findsNothing);
  });

  testWidgets('USD values show only for known mainnet prices', (tester) async {
    await _pump(
      tester,
      _review(funds: _swap()),
      priceOf: (id) => id == _usdc ? 1.0 : null,
    );
    expect(find.text(r'$10.00'), findsOneWidget);
    expect(find.textContaining(r'$0'), findsNothing);

    await _pump(
      tester,
      _review(funds: _swap(), chain: 'solana:devnet'),
      priceOf: (_) => 1.0,
    );
    expect(find.textContaining(r'$'), findsNothing);
  });

  testWidgets(
    'failed simulation: Reject is primary and approval needs a hold at 320 dp',
    (tester) async {
      var approved = 0;
      await _pump(
        tester,
        _review(
          execution: SimulationExecution.failed,
          coverage: SimulationCoverage.partial,
          error: 'Simulation failed: {"InstructionError":[0,{"Custom":6001}]}',
          warnings: ['Some effects could not be decoded.'],
        ),
        onApprove: () => approved++,
        size: const Size(320, 800),
      );
      expect(find.text('Review carefully'), findsOneWidget);
      expect(find.text('Simulation failed'), findsOneWidget);
      expect(
        find.text('{"InstructionError":[0,{"Custom":6001}]}'),
        findsOneWidget,
      );
      expect(find.text('Some effects could not be decoded.'), findsNothing);
      final approve = find.byKey(const Key('approve-signing'));
      expect(approve, findsOneWidget);

      await tester.tap(approve);
      await tester.pump(const Duration(seconds: 2));
      expect(approved, 0, reason: 'a tap is not a hold');

      final early = await tester.startGesture(tester.getCenter(approve));
      await tester.pump(const Duration(milliseconds: 600));
      await early.up();
      await tester.pump(const Duration(seconds: 2));
      expect(approved, 0, reason: 'releasing early cancels');

      final hold = await tester.startGesture(tester.getCenter(approve));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1300));
      expect(approved, 1, reason: 'completes while still held');
      await hold.up();
      await tester.pump();
      expect(approved, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'undecodable Ethereum effects warn about hidden changes without a hold',
    (tester) async {
      var approved = 0;
      await _pump(
        tester,
        _review(
          chain: 'eip155:1',
          execution: SimulationExecution.unavailable,
          coverage: SimulationCoverage.partial,
          effectsUndecodable: true,
          error:
              'The simulation returned effects this wallet could not decode.',
          networkFee: BigInt.from(52500000000000),
        ),
        onApprove: () => approved++,
        size: const Size(320, 900),
      );
      expect(find.text('Simulation effects unavailable'), findsOneWidget);
      expect(
        find.text(
          'This wallet could not decode the simulation\'s effects. Assets or permissions not shown here can change if you approve.',
        ),
        findsOneWidget,
      );
      expect(find.text('Simulation failed'), findsNothing);
      expect(find.textContaining('This transaction would fail'), findsNothing);
      expect(find.text('≈ 0.000053 ETH'), findsOneWidget);
      expect(
        find.text('No asset changes could be identified.'),
        findsOneWidget,
      );
      // The ordinary title and decision bar, as on a Solana review.
      expect(find.text('Review carefully'), findsNothing);
      expect(find.byType(HoldToApproveButton), findsNothing);
      // Approve ignores taps for a moment after it first appears.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('approve-signing')));
      expect(approved, 1);
    },
  );

  for (final (chain, execution) in [
    ('eip155:1', SimulationExecution.failed),
    ('tezos:NetXdQprcVkpaWU', SimulationExecution.succeeded),
  ]) {
    testWidgets('a $chain review never needs a hold ($execution)', (
      tester,
    ) async {
      await _pump(
        tester,
        _review(
          chain: chain,
          execution: execution,
          coverage: SimulationCoverage.partial,
          effectsUndecodable: execution == SimulationExecution.succeeded,
          error: execution == SimulationExecution.failed ? 'reverted' : null,
        ),
        onApprove: () {},
      );
      expect(find.byType(HoldToApproveButton), findsNothing);
      expect(find.text('Review carefully'), findsNothing);
    });
  }

  testWidgets('reduced motion still requires the hold', (tester) async {
    var approved = 0;
    await _pump(
      tester,
      _review(execution: SimulationExecution.failed, error: 'boom'),
      onApprove: () => approved++,
      reduceMotion: true,
    );
    final approve = find.byKey(const Key('approve-signing'));
    final early = await tester.startGesture(tester.getCenter(approve));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Keep holding…'), findsOneWidget);
    await early.up();
    await tester.pump();
    expect(approved, 0);
    final hold = await tester.startGesture(tester.getCenter(approve));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 1300));
    await hold.up();
    expect(approved, 1);
  });

  testWidgets('screen readers approve through a semantics action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var approved = 0;
    await _pump(
      tester,
      _review(execution: SimulationExecution.failed, error: 'boom'),
      onApprove: () => approved++,
    );
    final node = tester.getSemantics(find.byKey(const Key('approve-signing')));
    expect(node.label, 'Hold to approve anyway');
    final action = node
        .getSemanticsData()
        .customSemanticsActionIds!
        .map(CustomSemanticsAction.getAction)
        .single!;
    expect(action.label, 'Approve anyway');
    node.owner!.performAction(
      node.id,
      SemanticsAction.customAction,
      CustomSemanticsAction.getIdentifier(action),
    );
    expect(approved, 1);
    handle.dispose();
  });

  testWidgets('unlimited allowances are a permission card above the hero', (
    tester,
  ) async {
    await _pump(
      tester,
      _review(
        accounts: [
          AccountChange(
            kind: AccountChangeKind.approve,
            address: 'usdc-account',
            program: 'token-program',
            description: 'Token spending permission',
            beneficiary: 'Hk3PvZ8s1mQ4oYt6nR2wQx',
            rawAllowance: BigInt.parse('18446744073709551615'),
            evidence: ReviewEvidence.requestedInstruction,
          ),
        ],
        funds: _swap(),
      ),
    );
    expect(find.text('PERMISSION'), findsOneWidget);
    expect(find.text('Unlimited USDC allowance'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Unlimited USDC allowance')).dy,
      lessThan(tester.getTopLeft(find.text('You send')).dy),
    );
    await _openDetails(tester);
    expect(find.text('Unlimited token allowance'), findsNothing);
    expect(
      find.text('Beneficiary / authority: Hk3PvZ8s1mQ4oYt6nR2wQx'),
      findsNothing,
    );
  });

  test('format exact amounts without floating point rounding', () {
    expect(
      formatReviewAmount(BigInt.parse('18446744073709551615'), 9),
      '18446744073.709551615',
    );
    expect(formatReviewAmount(BigInt.from(-1), 9), '−0.000000001');
    expect(formatReviewAmount(BigInt.one, null), '1 base units');
  });

  testWidgets('requested EVM approval of zero explains the NFT token ID risk', (
    tester,
  ) async {
    const contract = '0x2222222222222222222222222222222222222222';
    const spender = '0x3333333333333333333333333333333333333333';
    await _pump(
      tester,
      _review(
        chain: 'eip155:1',
        execution: SimulationExecution.unavailable,
        coverage: SimulationCoverage.unavailable,
        accounts: [
          AccountChange(
            kind: AccountChangeKind.approve,
            address: contract,
            program: contract,
            assetId: contract,
            description: 'Token approval (allowance or NFT token ID)',
            beneficiary: spender,
            rawAllowance: BigInt.zero,
            evidence: ReviewEvidence.requestedInstruction,
          ),
        ],
      ),
    );
    expect(
      find.text('Token approval (allowance or NFT token ID)'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'either a zero token allowance or the right to transfer NFT #0',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(find.text('0x3333…333333'), findsOneWidget);
    expect(find.text('0x2222…222222'), findsOneWidget);
    expect(find.text('0 base units allowance'), findsNothing);
    expect(
      find.textContaining('can spend up to this amount', findRichText: true),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('simulated EVM zero allowance keeps its amount wording', (
    tester,
  ) async {
    await _pump(
      tester,
      _review(
        chain: 'eip155:1',
        accounts: [
          AccountChange(
            kind: AccountChangeKind.approve,
            address: 'contract',
            program: 'contract',
            assetId: 'contract',
            description: 'Token spending permission',
            beneficiary: 'spender',
            rawAllowance: BigInt.zero,
            evidence: ReviewEvidence.simulatedState,
          ),
        ],
      ),
    );
    expect(find.text('0 base units allowance'), findsOneWidget);
    expect(find.textContaining('NFT #0', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('a Solana delegation of what the account holds', () {
    const mint = 'MintDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD';
    const delegate = 'De1egateEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE';
    AccountChange approve({BigInt? allowance, BigInt? balance, String? id}) =>
        AccountChange(
          kind: AccountChangeKind.approve,
          address: 'token-account',
          program: 'token-program',
          description: 'Token spending permission',
          beneficiary: delegate,
          rawAllowance: allowance,
          balance: balance,
          assetId: id,
          evidence: ReviewEvidence.requestedInstruction,
        );
    const freeze = AccountChange(
      kind: AccountChangeKind.freeze,
      address: 'token-account',
      // Token Metadata freezes through a Token program call, so the freeze
      // lands on the same program and account as the approval.
      program: 'token-program',
      description: 'Freeze token account',
      assetId: mint,
      evidence: ReviewEvidence.requestedInstruction,
    );

    testWidgets('approve one NFT and freeze it: a Permission card names the '
        'delegate\'s power', (tester) async {
      await _pump(
        tester,
        _review(
          accounts: [
            approve(allowance: BigInt.one, balance: BigInt.one, id: mint),
            freeze,
          ],
          nftMetadata: const {mint: ReviewNftMetadata(name: 'Moon Garden')},
        ),
        size: const Size(600, 1400),
      );
      expect(find.text('PERMISSION'), findsOneWidget);
      expect(find.text('Permission to transfer Moon Garden'), findsOneWidget);
      expect(
        find.textContaining(
          'can transfer this NFT out of your wallet at any time',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('It is also frozen', findRichText: true),
        findsOneWidget,
      );
      // The action row no longer reads as a harmless lock.
      expect(find.text('Lock'), findsNothing);
      expect(find.text('Lock and delegate'), findsOneWidget);
      expect(
        find.textContaining(
          'can transfer it until revoked',
          findRichText: true,
        ),
        findsOneWidget,
      );
      // A card, not a block: approving stays a tap.
      expect(find.byType(HoldToApproveButton), findsNothing);
    });

    testWidgets('a single-supply mint known only from its NFT change counts', (
      tester,
    ) async {
      await _pump(
        tester,
        _review(
          accounts: [approve(allowance: BigInt.one, id: mint)],
          nfts: const [
            NftChange(
              kind: NftChangeKind.approve,
              assetId: mint,
              description: 'NFT delegate set',
              evidence: ReviewEvidence.simulatedState,
            ),
          ],
        ),
      );
      expect(find.text('PERMISSION'), findsOneWidget);
      expect(
        find.textContaining('Permission to transfer NFT · '),
        findsOneWidget,
      );
    });

    testWidgets('an allowance of the whole balance gets a card', (
      tester,
    ) async {
      await _pump(
        tester,
        _review(
          accounts: [
            approve(
              allowance: BigInt.from(500),
              balance: BigInt.from(500),
              id: 'fungible-mint',
            ),
          ],
        ),
      );
      expect(find.text('PERMISSION'), findsOneWidget);
      expect(
        find.textContaining(
          'can spend all of the token in this account',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('a partial allowance, or an NFT approval of zero, gets none', (
      tester,
    ) async {
      await _pump(
        tester,
        _review(
          accounts: [
            approve(
              allowance: BigInt.from(499),
              balance: BigInt.from(500),
              id: 'fungible-mint',
            ),
          ],
        ),
      );
      expect(find.text('PERMISSION'), findsNothing);
      expect(find.text('Delegating'), findsOneWidget);

      await _pump(
        tester,
        _review(
          accounts: [approve(allowance: BigInt.zero, id: mint)],
          nftMetadata: const {mint: ReviewNftMetadata(name: 'Moon Garden')},
        ),
      );
      expect(find.text('PERMISSION'), findsNothing);
      expect(
        find.textContaining('can transfer it', findRichText: true),
        findsNothing,
      );
    });
  });

  testWidgets('a Core update-authority change shows the bare address beside '
      'what the authority becomes', (tester) async {
    const asset = 'AssetFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF';
    const collection = 'Co11ectionGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG';
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pump(
      tester,
      _review(
        nfts: const [
          NftChange(
            kind: NftChangeKind.authority,
            assetId: asset,
            description: 'Update authority moves to a collection',
            evidence: ReviewEvidence.simulatedState,
            from: 'O1dAuthorityHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH',
            to: collection,
          ),
        ],
        nftMetadata: const {asset: ReviewNftMetadata(name: 'Moon Garden')},
      ),
    );
    expect(find.text('Moon Garden'), findsOneWidget);
    expect(
      find.textContaining(
        'Update authority moves to a collection · ',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Addres', findRichText: true), findsNothing);
    final chip = find.text(truncateAddress(collection, lead: 6, trail: 6));
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pump();
    expect(copied, [collection]);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('Solana zero approval remains a delegation action', (
    tester,
  ) async {
    await _pump(
      tester,
      _review(
        accounts: [
          AccountChange(
            kind: AccountChangeKind.approve,
            address: 'token-account',
            program: 'token-program',
            description: 'Token spending permission',
            beneficiary: 'spender',
            rawAllowance: BigInt.zero,
            evidence: ReviewEvidence.requestedInstruction,
          ),
        ],
      ),
    );
    expect(find.text('Delegating'), findsOneWidget);
    expect(find.textContaining('Allowance: 0 base units'), findsOneWidget);
    expect(find.text('PERMISSION'), findsNothing);
    expect(find.textContaining('NFT #0', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final (kind, outgoing) in [
    (NftChangeKind.transfer, true),
    (NftChangeKind.transfer, false),
    (NftChangeKind.burn, true),
    (NftChangeKind.mint, false),
  ]) {
    testWidgets(
      'EVM NFT ${kind.name} ${outgoing ? 'out' : 'in'} matches a checksummed wallet',
      (tester) async {
        const address = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';
        final other = kind == NftChangeKind.transfer
            ? '0x1111111111111111111111111111111111111111'
            : '0x0000000000000000000000000000000000000000';
        const assetId = '0x2222222222222222222222222222222222222222:0';
        await _pump(
          tester,
          _review(
            chain: 'eip155:1',
            address: address,
            nfts: [
              NftChange(
                kind: kind,
                assetId: assetId,
                description: outgoing
                    ? 'NFT leaves wallet'
                    : 'NFT enters wallet',
                evidence: ReviewEvidence.simulatedState,
                from: outgoing ? address.toLowerCase() : other,
                to: outgoing ? other : address.toLowerCase(),
              ),
            ],
            nftMetadata: const {
              assetId: ReviewNftMetadata(name: 'Moon Garden'),
            },
          ),
        );
        expect(
          find.text(outgoing ? 'You send' : 'You receive'),
          findsOneWidget,
        );
        expect(find.text('Moon Garden'), findsOneWidget);
        expect(
          find.text('No asset changes could be identified.'),
          findsNothing,
        );
        expect(
          find.text(outgoing ? 'NFT leaves wallet' : 'NFT enters wallet'),
          findsNothing,
        );
        expect(
          tester
              .widget<BalanceChangeHero>(find.byType(BalanceChangeHero))
              .changes
              .single
              .outgoing,
          outgoing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (rawQuantity, outgoing, expected) in [
    ('5000', true, '5,000 × Moon Garden'),
    ('5000', false, '5,000 × Moon Garden'),
    (null, true, 'Unknown quantity · Moon Garden'),
    ('9007199254740993', true, '9,007,199,254,740,993 × Moon Garden'),
  ]) {
    testWidgets('ERC-1155 ${outgoing ? 'send' : 'receive'} shows $expected', (
      tester,
    ) async {
      const address = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';
      const other = '0x1111111111111111111111111111111111111111';
      const assetId = '0x2222222222222222222222222222222222222222:42';
      await _pump(
        tester,
        _review(
          chain: 'eip155:1',
          address: address,
          nfts: [
            NftChange(
              kind: NftChangeKind.transfer,
              assetId: assetId,
              description: 'NFT transfer',
              evidence: ReviewEvidence.simulatedState,
              from: outgoing ? address.toLowerCase() : other,
              to: outgoing ? other : address.toLowerCase(),
              quantity: rawQuantity == null ? null : BigInt.parse(rawQuantity),
              isMultiCopy: true,
            ),
          ],
          nftMetadata: const {assetId: ReviewNftMetadata(name: 'Moon Garden')},
        ),
      );
      expect(find.text(outgoing ? 'You send' : 'You receive'), findsOneWidget);
      expect(find.text(expected), findsOneWidget);
      expect(find.text('Moon Garden'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Solana NFT parties remain case-sensitive', (tester) async {
    const address = 'Hk3PvZ8s1mQ4oYt6nR2wQx';
    await _pump(
      tester,
      _review(
        address: address,
        nfts: [
          NftChange(
            kind: NftChangeKind.transfer,
            assetId: 'art',
            description: 'Core NFT ownership changes',
            evidence: ReviewEvidence.simulatedState,
            from: address.toLowerCase(),
            to: 'recipient',
          ),
        ],
      ),
    );
    expect(find.text('You send'), findsNothing);
    expect(find.text('You receive'), findsNothing);
    expect(find.text('No asset changes could be identified.'), findsOneWidget);
    expect(find.text('Core NFT ownership changes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'NFT transfers use the hero while authority changes stay visible',
    (tester) async {
      final review = _review(
        nfts: const [
          NftChange(
            kind: NftChangeKind.transfer,
            assetId: 'transfer-asset',
            description: 'Core NFT ownership changes',
            evidence: ReviewEvidence.simulatedState,
            from: '11111111111111111111111111111111',
            to: 'recipient',
          ),
          NftChange(
            kind: NftChangeKind.authority,
            assetId: 'authority-asset',
            description: 'Core NFT update authority changes',
            evidence: ReviewEvidence.simulatedState,
            from: 'old-authority',
            to: 'replacement-authority',
          ),
        ],
      );
      await _pump(tester, review, size: const Size(600, 1000));

      // Short rows are visible without opening anything.
      expect(find.text('You send'), findsOneWidget);
      expect(find.textContaining('NFT · transf'), findsOneWidget);

      await _openDetails(tester);
      expect(find.text('Previous owner: old-owner'), findsNothing);
      expect(find.text('Recipient: recipient'), findsNothing);
      expect(find.text('Previous authority: old-authority'), findsNothing);
      expect(find.text('New authority: replacement-authority'), findsNothing);
    },
  );

  testWidgets('program calls contain only calls and the Explorer link', (
    tester,
  ) async {
    await _pump(
      tester,
      _review(
        programCalls: const [
          ReviewProgramCall(
            program: 'token-program',
            instruction: 'TransferChecked',
          ),
        ],
        explorerUrl: Uri.parse(
          'https://explorer.solana.com/tx/inspector?cluster=devnet&message=test',
        ),
        funds: [
          ..._swap(),
          FundChange(
            asset: const ReviewAsset(id: 'mystery-mint', symbol: 'Token'),
            address: 'src',
            rawAmount: BigInt.from(-42),
            evidence: ReviewEvidence.requestedInstruction,
            from: 'src',
            to: 'dst',
          ),
        ],
      ),
      size: const Size(600, 1400),
    );
    expect(find.text('TransferChecked'), findsNothing);
    await _openDetails(tester);
    expect(find.text('TransferChecked'), findsOneWidget);
    expect(find.text('token-…rogram'), findsOneWidget);
    expect(find.text('Open simulation in Solana Explorer'), findsOneWidget);
    expect(find.text('Raw units: -10000000'), findsNothing);
    expect(find.text('Mint: mystery-mint'), findsNothing);
    expect(find.text('To: dst'), findsNothing);
    expect(find.text('Decoded requested instruction'), findsNothing);
    expect(find.text('Payload SHA-256: digest'), findsNothing);
    expect(find.text('Website: https://site.example'), findsNothing);
  });

  testWidgets('a batch splits program calls by transaction, each with its '
      'own Explorer link', (tester) async {
    final opened = <Uri>[];
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SimulationReviewSheet(
              review: _review(
                funds: _swap(),
                execution: SimulationExecution.failed,
                error: 'Simulation failed: Transaction 2: {}',
                transactions: [
                  ReviewTransaction(
                    execution: SimulationExecution.succeeded,
                    explorerUrl: Uri.parse('https://explorer.example/1'),
                    programCalls: const [
                      ReviewProgramCall(program: 'first', instruction: 'Lock'),
                    ],
                  ),
                  ReviewTransaction(
                    execution: SimulationExecution.failed,
                    explorerUrl: Uri.parse('https://explorer.example/2'),
                    programCalls: const [
                      ReviewProgramCall(program: 'second', instruction: 'List'),
                    ],
                  ),
                ],
              ),
              title: 'Review 2 transactions',
              onReject: () {},
              onApprove: () {},
              programLabels: ValueNotifier(const {}),
              openExternal: (url) async => opened.add(url),
            ),
          ),
        ),
      ),
    );
    expect(
      find.text('Effects requested by these transactions'),
      findsOneWidget,
    );
    expect(
      find.textContaining('A transaction in this batch fails'),
      findsOneWidget,
    );
    await _openDetails(tester);
    final first = find.byKey(const Key('program-calls-transaction-1'));
    final second = find.byKey(const Key('program-calls-transaction-2'));
    expect(
      find.descendant(of: first, matching: find.text('Transaction 1 of 2')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: first, matching: find.text('Lock')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: second, matching: find.text('Simulation failed')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: second, matching: find.text('List')),
      findsOneWidget,
    );
    expect(find.text('Open simulation in Solana Explorer'), findsNWidgets(2));
    final link = find.descendant(
      of: second,
      matching: find.text('Open simulation in Solana Explorer'),
    );
    await tester.ensureVisible(link);
    await tester.tap(link);
    expect(opened, [Uri.parse('https://explorer.example/2')]);
  });

  testWidgets('an unlocked NFT without metadata still reads as an NFT', (
    tester,
  ) async {
    const mint = 'MintAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    AccountChange action(AccountChangeKind kind) => AccountChange(
      kind: kind,
      address: 'token-account',
      program: 'token-program',
      description: 'action',
      evidence: ReviewEvidence.simulatedState,
      assetId: mint,
    );
    await _pump(
      tester,
      _review(
        accounts: [
          action(AccountChangeKind.thaw),
          action(AccountChangeKind.revoke),
        ],
        nftMetadata: const {mint: ReviewNftMetadata()},
      ),
    );
    expect(find.text('Unlock'), findsOneWidget);
    expect(find.text('Token account'), findsNothing);
    expect(find.textContaining('NFT · '), findsOneWidget);
  });

  testWidgets('a program call reads "Program ✓ [Instruction]" over its '
      'copyable address', (tester) async {
    const jupiter = 'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4';
    const unknown = 'Unknown1111111111111111111111111111111111';
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final labels = ValueNotifier<Map<String, String>>(const {});
    addTearDown(labels.dispose);
    await _pump(
      tester,
      _review(
        funds: _swap(),
        programCalls: const [
          ReviewProgramCall(program: jupiter, instruction: 'Route'),
          ReviewProgramCall(program: unknown, instruction: 'Swap'),
          ReviewProgramCall(program: unknown),
        ],
      ),
      programLabels: labels,
      size: const Size(600, 1400),
    );
    await _openDetails(tester);
    // Unlisted, a program is headed "Unknown Program", unverified, over its
    // shortened address.
    expect(find.text('Jupiter Aggregator v6'), findsNothing);
    expect(find.text('Unknown Program'), findsNWidgets(3));
    expect(find.byKey(const Key('program-verified')), findsNothing);
    expect(find.text('JUP6Lk…yVTaV4'), findsOneWidget);
    expect(find.text('Route'), findsOneWidget);

    // A list that lands while the review is open names the call in place,
    // with a verified mark and the address chip beneath the name.
    labels.value = const {jupiter: 'Jupiter Aggregator v6'};
    await tester.pump();
    expect(find.text('Jupiter Aggregator v6'), findsOneWidget);
    expect(find.text('JUP6Lk…yVTaV4'), findsOneWidget);
    expect(find.byKey(const Key('program-verified')), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('JUP6Lk…yVTaV4')).dy,
      greaterThan(tester.getBottomLeft(find.text('Jupiter Aggregator v6')).dy),
    );
    expect(find.text('Route'), findsOneWidget);
    expect(find.text('Swap'), findsOneWidget);
    // An unnamed program shows its address once, under "Unknown Program".
    expect(find.text('Unknown Program'), findsNWidgets(2));
    expect(find.text('Unknow…111111'), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('Unknow…111111').first).dy,
      greaterThan(tester.getBottomLeft(find.text('Unknown Program').first).dy),
    );
    // A call with no known instruction has no chip.
    expect(find.byKey(const Key('program-instruction')), findsNWidgets(2));

    // The name itself copies nothing; the address chip does.
    await tester.tap(find.text('Jupiter Aggregator v6'));
    await tester.pump();
    expect(copied, isEmpty);

    await tester.tap(find.text('JUP6Lk…yVTaV4'));
    await tester.pump();
    expect(copied, [jupiter]);
    expect(find.text('Address copied'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 3));

    await tester.tap(find.text('Unknow…111111').first);
    await tester.pump();
    expect(copied, [jupiter, unknown]);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('token addresses in the balance and action rows copy', (
    tester,
  ) async {
    const mint = 'MintBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
    const nft = 'NftCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    AccountChange action(AccountChangeKind kind) => AccountChange(
      kind: kind,
      address: 'TokenAccountDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD',
      program: 'token-program',
      description: 'action',
      evidence: ReviewEvidence.simulatedState,
      assetId: nft,
    );
    await _pump(
      tester,
      _review(
        funds: [
          FundChange(
            asset: const ReviewAsset(id: mint, symbol: 'Token', decimals: 6),
            address: 'wallet',
            rawAmount: BigInt.from(2500000),
            evidence: ReviewEvidence.simulatedState,
            isNet: true,
          ),
        ],
        accounts: [
          action(AccountChangeKind.thaw),
          action(AccountChangeKind.revoke),
        ],
        nftMetadata: const {nft: ReviewNftMetadata(name: 'Fox #1')},
      ),
      size: const Size(600, 1400),
    );
    expect(find.text('Fox #1'), findsOneWidget);
    await tester.tap(find.text('MintBB…BBBBBB'));
    await tester.pump();
    await tester.pumpAndSettle(const Duration(seconds: 3));
    await tester.tap(find.text('TokenA…DDDDDD'));
    await tester.pump();
    expect(copied, [mint, 'TokenAccountDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD']);
    expect(find.text('Address copied'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('account changes stay visible outside the program calls', (
    tester,
  ) async {
    await _pump(
      tester,
      _review(
        funds: _swap(),
        accounts: const [
          AccountChange(
            kind: AccountChangeKind.close,
            address: 'CLoSeAccount1111111111111111111111',
            program: 'token-program',
            description: 'Token account closed',
            beneficiary: 'RentDest9999999999999999999999999',
            evidence: ReviewEvidence.requestedInstruction,
          ),
        ],
      ),
      size: const Size(390, 1400),
    );
    expect(find.text('Account changes'), findsOneWidget);
    expect(find.text('Token account closed'), findsOneWidget);
    expect(find.text('RentDe…999999'), findsOneWidget);
  });

  testWidgets('counterparties show 6…6 and copy in full with one tap', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    const destination = '9fZaQm3LkP8vR7Tq1xYzAbCdEfGhJkLmN';
    await _pump(
      tester,
      _review(
        execution: SimulationExecution.failed,
        error: 'boom',
        funds: [
          FundChange(
            asset: const ReviewAsset(id: _usdc, symbol: 'Token', decimals: 6),
            address: 'src',
            rawAmount: BigInt.from(-25000000),
            evidence: ReviewEvidence.requestedInstruction,
            from: 'src',
            to: destination,
          ),
        ],
      ),
    );
    final chip = find.text('9fZaQm…hJkLmN');
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    expect(copied, destination);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('the caption names where the balance changes came from', (
    tester,
  ) async {
    await _pump(tester, _review(funds: _swap()));
    expect(find.textContaining('Estimated from simulation'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Estimated from simulation')).dy,
      greaterThan(tester.getTopLeft(find.text('Review transaction')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Estimated from simulation')).dy,
      lessThan(tester.getTopLeft(find.text('You send')).dy),
    );
    await _pump(
      tester,
      _review(
        funds: [
          FundChange(
            asset: const ReviewAsset(id: _sol, symbol: 'SOL', decimals: 9),
            address: 'wallet',
            rawAmount: BigInt.from(-5),
            evidence: ReviewEvidence.requestedInstruction,
            isNet: true,
          ),
        ],
      ),
    );
    expect(find.textContaining('Estimated from simulation'), findsNothing);
    expect(find.textContaining('read from the request itself'), findsOneWidget);
  });
  testWidgets('mixed snapshot slots join the caption, not a caution', (
    tester,
  ) async {
    await _pump(
      tester,
      _review(funds: _swap(), warnings: [kSimulationSnapshotSlotsWarning]),
    );
    expect(
      find.text(
        'Estimated from simulation; balance snapshots use different slots.',
      ),
      findsOneWidget,
    );
    expect(find.text(kSimulationSnapshotSlotsWarning), findsNothing);
  });

  testWidgets('the wallet row shows the short address', (tester) async {
    await _pump(tester, _review(funds: _swap()));
    // Outside a session there is no owner name: the address alone.
    expect(find.text('1111…1111'), findsOneWidget);
  });

  testWidgets('same-account actions combine, distinct accounts do not', (
    tester,
  ) async {
    AccountChange action(AccountChangeKind kind, String account) =>
        AccountChange(
          kind: kind,
          address: account,
          program: 'token-program',
          description: 'action',
          evidence: ReviewEvidence.simulatedState,
          assetId: 'art',
        );
    await _pump(
      tester,
      _review(
        funds: _swap(),
        accounts: [
          action(AccountChangeKind.approve, 'a'),
          action(AccountChangeKind.freeze, 'a'),
          action(AccountChangeKind.thaw, 'b'),
          action(AccountChangeKind.revoke, 'b'),
          action(AccountChangeKind.approve, 'c'),
          action(AccountChangeKind.freeze, 'd'),
          action(AccountChangeKind.revoke, 'e'),
          action(AccountChangeKind.thaw, 'f'),
        ],
        nftMetadata: const {'art': ReviewNftMetadata(name: 'Moon Garden')},
      ),
      size: const Size(600, 1600),
    );
    for (final label in [
      'Lock and delegate',
      'Unlock',
      'Delegating',
      'Freezing',
      'Revoking',
      'Thawing',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(BalanceChangeHero), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('Lock and delegate')).dy,
      greaterThan(tester.getTopLeft(find.text('You receive')).dy),
    );
    expect(find.text('Moon Garden'), findsNWidgets(6));
  });

  testWidgets(
    'NFT transfers use metadata and are not duplicated by token deltas',
    (tester) async {
      await _pump(
        tester,
        _review(
          funds: [
            FundChange(
              asset: const ReviewAsset(id: 'art', symbol: 'Token', decimals: 0),
              address: 'token-account',
              rawAmount: -BigInt.one,
              evidence: ReviewEvidence.simulatedState,
              isNet: true,
            ),
          ],
          nfts: const [
            NftChange(
              kind: NftChangeKind.transfer,
              assetId: 'art',
              description: 'transfer',
              evidence: ReviewEvidence.simulatedState,
              from: 'token-account',
              to: 'recipient',
            ),
            NftChange(
              kind: NftChangeKind.transfer,
              assetId: 'core-art',
              description: 'transfer',
              evidence: ReviewEvidence.simulatedState,
              from: 'sender',
              to: '11111111111111111111111111111111',
            ),
          ],
          nftMetadata: const {
            'art': ReviewNftMetadata(
              name: 'Moon Garden',
              imageUrl: 'https://example.com/art.png',
            ),
            'core-art': ReviewNftMetadata(name: 'Sun Garden'),
          },
        ),
      );
      expect(find.text('You send'), findsOneWidget);
      expect(find.text('You receive'), findsOneWidget);
      expect(find.text('Moon Garden'), findsOneWidget);
      expect(find.text('transfer'), findsNothing);
      expect(find.text('Sun Garden'), findsOneWidget);
      expect(
        tester
            .widget<MallowNetworkImage>(find.byType(MallowNetworkImage))
            .logicalSize,
        40,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an unverified token shows its own symbol and image, still flagged',
    (tester) async {
      const mint = 'Moon1111111111111111111111111111111111111111';
      await _pump(
        tester,
        _review(
          funds: [
            FundChange(
              asset: const ReviewAsset(id: mint, symbol: 'Token', decimals: 6),
              address: 'wallet',
              rawAmount: BigInt.from(2500000),
              evidence: ReviewEvidence.simulatedState,
              isNet: true,
            ),
          ],
          tokenMetadata: const {
            mint: ReviewTokenMetadata(
              symbol: 'MOON',
              imageUrl: 'https://example.com/moon.png',
            ),
          },
        ),
      );
      expect(find.text('2.5 MOON'), findsOneWidget);
      expect(find.textContaining('Unverified token'), findsOneWidget);
      expect(
        tester
            .widget<MallowNetworkImage>(find.byType(MallowNetworkImage))
            .imageUrl,
        'https://example.com/moon.png',
      );
      expect(tester.takeException(), isNull);
    },
  );

  group('ReviewTokenMetadata.fromCreator', () {
    ReviewTokenMetadata? read(Object? symbol, [Object? image]) =>
        ReviewTokenMetadata.fromCreator(
          symbol: symbol,
          image: image,
          reservedSymbols: const {'sol', 'usdc'},
        );

    test('keeps a plain symbol and an https image', () {
      final metadata = read(' MOON ', 'https://example.com/moon.png');
      expect(metadata?.symbol, 'MOON');
      expect(metadata?.imageUrl, 'https://example.com/moon.png');
      expect(read('MOON', 'http://example.com/moon.png')?.imageUrl, isNull);
      expect(read('MOON', 'ipfs://moon')?.imageUrl, isNull);
    });

    test('refuses known, look-alike, spaced or overlong symbols', () {
      expect(read('USDC'), isNull);
      expect(read('Sol'), isNull);
      // A Cyrillic "С" would otherwise pass for USDC.
      expect(read('USD\u0421'), isNull);
      expect(read('MOON COIN'), isNull);
      expect(read('\u202eNOOM'), isNull);
      expect(read('ABCDEFGHIJKLM'), isNull);
      expect(read(''), isNull);
      expect(read(42), isNull);
    });
  });
}
