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
import 'package:mallow_wallet/shared/widgets/signing_review_layout.dart';
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
  Map<String, Set<String>> delegatedBy = const {},
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
  delegatedBy: delegatedBy,
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

/// The review is reject-first and approving takes the hold.
void _expectHold() {
  expect(find.text('Review carefully'), findsOneWidget);
  expect(find.byType(HoldToApproveButton), findsOneWidget);
}

/// Approving the review takes a tap.
void _expectTap() {
  expect(find.text('Review carefully'), findsNothing);
  expect(find.byType(HoldToApproveButton), findsNothing);
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
    'undecodable Ethereum effects warn about hidden changes, and a simulation '
    'that could not run takes the hold',
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
      // Unchecked is never the easier thing to approve, on any chain.
      expect(find.text('Review carefully'), findsOneWidget);
      expect(find.byType(HoldToApproveButton), findsOneWidget);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('approve-signing')));
      await tester.pump(const Duration(seconds: 2));
      expect(approved, 0, reason: 'a tap is not a hold');
    },
  );

  for (final chain in ['solana:mainnet', 'eip155:1', 'tezos:NetXdQprcVkpaWU']) {
    for (final execution in [
      SimulationExecution.failed,
      SimulationExecution.unavailable,
    ]) {
      testWidgets('a $chain review whose simulation is ${execution.name} '
          'is reject-first and needs a hold', (tester) async {
        var approved = 0;
        await _pump(
          tester,
          _review(
            chain: chain,
            execution: execution,
            coverage: SimulationCoverage.partial,
            error: execution == SimulationExecution.failed
                ? 'reverted'
                : 'Simulation is unavailable.',
          ),
          onApprove: () => approved++,
        );
        expect(find.text('Review carefully'), findsOneWidget);
        final approve = find.byKey(const Key('approve-signing'));
        expect(find.byType(HoldToApproveButton), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(approve);
        await tester.pump(const Duration(seconds: 2));
        expect(approved, 0, reason: 'a tap is not a hold');
        // Still signable: holding approves.
        final hold = await tester.startGesture(tester.getCenter(approve));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 1300));
        await hold.up();
        await tester.pump();
        expect(approved, 1);
      });
    }
  }

  testWidgets('a Tezos contract call, never fully decoded, keeps the tap', (
    tester,
  ) async {
    await _pump(
      tester,
      _review(
        chain: 'tezos:NetXdQprcVkpaWU',
        coverage: SimulationCoverage.partial,
        effectsUndecodable: true,
      ),
    );
    expect(find.byType(HoldToApproveButton), findsNothing);
    expect(find.text('Review carefully'), findsNothing);
  });

  for (final chain in ['solana:mainnet', 'eip155:1']) {
    testWidgets('$chain effects that could not be decoded take the hold', (
      tester,
    ) async {
      await _pump(
        tester,
        _review(
          chain: chain,
          coverage: SimulationCoverage.partial,
          effectsUndecodable: true,
          error:
              'The simulation returned effects this wallet could not decode.',
        ),
      );
      expect(find.text('Review carefully'), findsOneWidget);
      expect(find.byType(HoldToApproveButton), findsOneWidget);
    });
  }

  group('a program the wallet signs for and cannot read', () {
    const unread =
        'Some instructions you sign for could not be read. The programs they run can change assets or permissions that are not shown here.';

    testWidgets('is one plain line when the simulation ran', (tester) async {
      await _pump(
        tester,
        _review(
          coverage: SimulationCoverage.partial,
          warnings: const [unread],
          funds: _swap(),
        ),
      );
      expect(find.byKey(const Key('review-unread-programs')), findsOneWidget);
      expect(find.text(unread), findsOneWidget);
      expect(find.byType(ReviewCautionCard), findsNothing);
      expect(find.byType(HoldToApproveButton), findsNothing);
    });

    testWidgets('is a caution when it did not', (tester) async {
      await _pump(
        tester,
        _review(
          execution: SimulationExecution.unavailable,
          coverage: SimulationCoverage.unavailable,
          error: 'Simulation is unavailable.',
          warnings: const [unread],
        ),
        size: const Size(390, 1200),
      );
      expect(find.byKey(const Key('review-unread-programs')), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ReviewCautionCard),
          matching: find.text(unread),
        ),
        findsOneWidget,
      );
      expect(find.byType(HoldToApproveButton), findsOneWidget);
    });
  });

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

  group('an Ethereum approval', () {
    const contract = '0x2222222222222222222222222222222222222222';
    const spender = '0x3333333333333333333333333333333333333333';
    AccountChange change(
      AccountChangeKind kind,
      String description, {
      BigInt? allowance,
      String assetId = contract,
    }) => AccountChange(
      kind: kind,
      address: contract,
      program: contract,
      assetId: assetId,
      description: description,
      beneficiary: kind == AccountChangeKind.approve ? spender : null,
      rawAllowance: allowance,
      evidence: ReviewEvidence.simulatedState,
    );

    testWidgets('takes the hold, whatever its size: a contract can use it '
        'later without asking', (tester) async {
      for (final (name, approval) in [
        (
          'a limited allowance',
          change(
            AccountChangeKind.approve,
            'Token spending permission',
            allowance: BigInt.from(1000000),
          ),
        ),
        (
          'an unlimited allowance',
          change(
            AccountChangeKind.approve,
            'Token spending permission',
            allowance: (BigInt.one << 256) - BigInt.one,
          ),
        ),
        (
          'a whole collection',
          change(
            AccountChangeKind.approve,
            'Permission to transfer every NFT you hold in this collection',
          ),
        ),
        (
          'one NFT',
          change(
            AccountChangeKind.approve,
            'Permission to transfer one NFT',
            assetId: '$contract:7',
          ),
        ),
      ]) {
        await _pump(
          tester,
          _review(
            chain: 'eip155:1',
            accounts: [approval],
            networkFee: BigInt.from(52500000000000),
          ),
          size: const Size(600, 1400),
        );
        expect(find.text('PERMISSION'), findsOneWidget, reason: name);
        expect(find.byType(HoldToApproveButton), findsOneWidget, reason: name);
        expect(find.text('Review carefully'), findsOneWidget, reason: name);
      }
    });

    testWidgets('a revocation keeps the tap', (tester) async {
      await _pump(
        tester,
        _review(
          chain: 'eip155:1',
          accounts: [
            change(
              AccountChangeKind.revoke,
              'Token allowance revoked',
              allowance: BigInt.zero,
            ),
          ],
          networkFee: BigInt.from(52500000000000),
        ),
      );
      expect(find.text('PERMISSION'), findsNothing);
      _expectTap();
    });
  });

  testWidgets('a Tezos delegation gets the Authority card and the hold', (
    tester,
  ) async {
    const account = 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL';
    await _pump(
      tester,
      _review(
        chain: 'tezos:NetXdQprcVkpaWU',
        address: account,
        accounts: const [
          AccountChange(
            kind: AccountChangeKind.authority,
            address: account,
            program: account,
            description: 'Delegate to tz1aRoaRhSpRYvFdyvgWLL6TGyRoGF51wDjM',
            evidence: ReviewEvidence.requestedInstruction,
          ),
        ],
        networkFee: BigInt.from(1500),
      ),
      size: const Size(600, 1400),
    );
    expect(find.text('AUTHORITY'), findsOneWidget);
    _expectHold();
  });

  group('a Solana delegation of what the account holds', () {
    const mint = 'MintDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD';
    // A point on the curve: an address someone can hold the key to.
    const delegate = '4qQ2g1cznQYXNrRKDXuMzoujEiyq2SykLnU6M315PA1T';
    // Off the curve: an address only a program can sign for.
    const programDelegate = '4oDUXKEVwTjzURt6DwyW5BS24yBLXpntPSUTKFrSHqtW';
    const market = 'TCMPhJdwDryooaGtiocG1u3xcYbRpiJzb283XfCZsDp';
    const tokenMetadata = 'metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s';
    const tokenProgram = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
    AccountChange approve({
      BigInt? allowance,
      BigInt? balance,
      String? id,
      String beneficiary = delegate,
      ReviewEvidence evidence = ReviewEvidence.requestedInstruction,
    }) => AccountChange(
      kind: AccountChangeKind.approve,
      address: 'token-account',
      program: 'token-program',
      description: 'Token spending permission',
      beneficiary: beneficiary,
      rawAllowance: allowance,
      balance: balance,
      assetId: id,
      evidence: evidence,
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
      // What it grants outlasts the transaction: approving takes the hold.
      _expectHold();
    });

    testWidgets('the same grant reported twice gets one card', (tester) async {
      await _pump(
        tester,
        _review(
          accounts: [
            approve(allowance: BigInt.one, balance: BigInt.one, id: mint),
            approve(
              allowance: BigInt.one,
              balance: BigInt.one,
              id: mint,
              evidence: ReviewEvidence.simulatedState,
            ),
            freeze,
          ],
          nftMetadata: const {mint: ReviewNftMetadata(name: 'Moon Garden')},
        ),
        size: const Size(600, 1400),
      );
      expect(find.text('PERMISSION'), findsOneWidget);
    });

    group('in a batch, where each transaction is simulated on its own', () {
      final max = BigInt.parse('18446744073709551615');
      // What each transaction of the batch reports: the decoded call, then
      // the state its own simulation left.
      List<AccountChange> reports(BigInt allowance, {String? id}) => [
        approve(allowance: allowance, balance: BigInt.from(500), id: id),
        approve(
          allowance: allowance,
          balance: BigInt.from(500),
          id: id,
          evidence: ReviewEvidence.simulatedState,
        ),
      ];
      List<ReviewTransaction> two() => [
        for (var i = 0; i < 2; i++)
          ReviewTransaction(execution: SimulationExecution.succeeded),
      ];

      for (final order in [
        [BigInt.one, max],
        [max, BigInt.one],
      ]) {
        testWidgets('approvals of ${order.first} then ${order.last} to one '
            'delegate show the unlimited one', (tester) async {
          await _pump(
            tester,
            _review(
              accounts: [for (final allowance in order) ...reports(allowance)],
              transactions: two(),
            ),
            size: const Size(600, 1400),
          );
          expect(find.text('PERMISSION'), findsOneWidget);
          expect(find.text('Unlimited token allowance'), findsOneWidget);
          expect(find.text('Delegating'), findsOneWidget);
          expect(
            find.textContaining('Allowance: $max base units'),
            findsOneWidget,
          );
          expect(find.textContaining('Allowance: 1 base units'), findsNothing);
        });
      }

      testWidgets('an NFT approval of zero, then of the NFT, gets the card', (
        tester,
      ) async {
        await _pump(
          tester,
          _review(
            accounts: [
              ...reports(BigInt.zero, id: mint),
              ...reports(BigInt.one, id: mint),
            ],
            nftMetadata: const {mint: ReviewNftMetadata(name: 'Moon Garden')},
            transactions: two(),
          ),
          size: const Size(600, 1400),
        );
        expect(find.text('PERMISSION'), findsOneWidget);
        expect(find.text('Permission to transfer Moon Garden'), findsOneWidget);
        expect(
          find.textContaining(
            'can transfer it until revoked',
            findRichText: true,
          ),
          findsOneWidget,
        );
      });

      testWidgets('two delegates on one account each keep a card and a row', (
        tester,
      ) async {
        const second = 'GKot5hBsd81kMupNCXHaqbhv3huEbxAFMLnpcX2hniwn';
        await _pump(
          tester,
          _review(
            accounts: [
              approve(allowance: max, id: 'fungible-mint'),
              approve(
                allowance: BigInt.from(7),
                id: 'fungible-mint',
                beneficiary: second,
              ),
            ],
            transactions: two(),
          ),
          size: const Size(600, 1600),
        );
        expect(find.text('PERMISSION'), findsNWidgets(2));
        expect(find.text('Delegating'), findsNWidgets(2));
      });
    });

    group('to a program address', () {
      final labels = ValueNotifier<Map<String, String>>(const {
        market: 'Tensor Marketplace',
        tokenMetadata: 'Metaplex Token Metadata',
        tokenProgram: 'Token Program',
      });

      Future<void> pumpDelegation(
        WidgetTester tester, {
        Set<String>? origins = const {market},
        List<String> calls = const [market, tokenMetadata, tokenProgram],
        SimulationExecution execution = SimulationExecution.succeeded,
      }) => _pump(
        tester,
        _review(
          execution: execution,
          accounts: [
            approve(
              allowance: BigInt.one,
              balance: BigInt.one,
              id: mint,
              beneficiary: programDelegate,
            ),
            freeze,
          ],
          nftMetadata: const {mint: ReviewNftMetadata(name: 'Moon Garden')},
          programCalls: [
            for (final program in calls) ReviewProgramCall(program: program),
          ],
          delegatedBy: {'token-account': ?origins},
        ),
        programLabels: labels,
        size: const Size(600, 1400),
      );

      testWidgets('a listed program\'s own delegation needs no card and no '
          'hold; the Lock and delegate row still says what it grants', (
        tester,
      ) async {
        await pumpDelegation(tester);
        expect(find.text('PERMISSION'), findsNothing);
        expect(find.text('Lock and delegate'), findsOneWidget);
        expect(
          find.textContaining(
            'can transfer it until revoked',
            findRichText: true,
          ),
          findsOneWidget,
        );
        _expectTap();
      });

      /// The Permission card for the NFT, and the hold: the review cannot
      /// tell this program address from one of a program the site deployed.
      void expectCardAndHold() {
        expect(find.text('PERMISSION'), findsOneWidget);
        expect(find.text('Permission to transfer Moon Garden'), findsOneWidget);
        expect(
          find.text(truncateAddress(programDelegate, lead: 6, trail: 6)),
          findsWidgets,
        );
        expect(find.text('Program permission'), findsNothing);
        _expectHold();
      }

      testWidgets('a site that delegates through Token Metadata or the token '
          'program itself gets the Permission card and the hold', (
        tester,
      ) async {
        for (final origin in [tokenMetadata, tokenProgram]) {
          await pumpDelegation(tester, origins: {origin});
          expectCardAndHold();
        }
      });

      testWidgets('so does one a listed program and a pass-through both '
          'made', (tester) async {
        await pumpDelegation(tester, origins: {market, tokenMetadata});
        expectCardAndHold();
      });

      testWidgets('an unlisted program anywhere in the calls gets the card '
          'and the hold', (tester) async {
        await pumpDelegation(
          tester,
          calls: const [market, 'Unknown11111111111111111111111111111111111'],
        );
        expectCardAndHold();
      });

      testWidgets('an untraced delegation gets the card and the hold', (
        tester,
      ) async {
        await pumpDelegation(tester, origins: null);
        expectCardAndHold();
      });

      testWidgets('a call that could not be tied to an account counts '
          'against every account', (tester) async {
        // The listed program made this delegation, and a pass-through made
        // a call the review could not read to the account it set.
        await _pump(
          tester,
          _review(
            accounts: [
              approve(
                allowance: BigInt.one,
                balance: BigInt.one,
                id: mint,
                beneficiary: programDelegate,
              ),
            ],
            nftMetadata: const {mint: ReviewNftMetadata(name: 'Moon Garden')},
            programCalls: const [
              ReviewProgramCall(program: market),
              ReviewProgramCall(program: tokenProgram),
            ],
            delegatedBy: const {
              'token-account': {market},
              kUntracedDelegations: {tokenProgram},
            },
          ),
          programLabels: labels,
          size: const Size(600, 1400),
        );
        expectCardAndHold();
      });

      testWidgets('a failed simulation gets the card and the hold', (
        tester,
      ) async {
        await pumpDelegation(tester, execution: SimulationExecution.failed);
        expectCardAndHold();
      });

      testWidgets('a key someone holds keeps the Permission card, however it '
          'was made', (tester) async {
        // A program that lets its caller name any holder is no better than
        // the caller.
        await _pump(
          tester,
          _review(
            accounts: [
              approve(allowance: BigInt.one, balance: BigInt.one, id: mint),
              freeze,
            ],
            nftMetadata: const {mint: ReviewNftMetadata(name: 'Moon Garden')},
            programCalls: const [ReviewProgramCall(program: market)],
            delegatedBy: const {
              'token-account': {market},
            },
          ),
          programLabels: labels,
          size: const Size(600, 1400),
        );
        expect(find.text('PERMISSION'), findsOneWidget);
        _expectHold();
      });
    });

    group('a Core NFT\'s delegates', () {
      const core = 'CoREENxT6tW1HoK8ypY1SxRMZTcVPm7R94rH4PZNhX7d';
      const asset = 'AssetFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF';
      AccountChange grant(
        NftDelegatePower power, {
        String beneficiary = delegate,
      }) => AccountChange(
        kind: AccountChangeKind.approve,
        address: asset,
        program: core,
        assetId: asset,
        description: 'Core NFT ${power.name} delegate',
        beneficiary: beneficiary,
        rawAllowance: BigInt.one,
        power: power,
        evidence: ReviewEvidence.requestedInstruction,
      );
      const named = {asset: ReviewNftMetadata(name: 'Piece')};

      testWidgets('the card says what a burn or freeze delegate may do', (
        tester,
      ) async {
        for (final (power, title, body, row) in [
          (
            NftDelegatePower.transfer,
            'Permission to transfer Piece',
            'can transfer this NFT out of your wallet at any time, until the permission is revoked.',
            'can transfer it until revoked',
          ),
          (
            NftDelegatePower.burn,
            'Permission to burn Piece',
            'can destroy this NFT at any time, until the permission is revoked.',
            'can burn it until revoked',
          ),
          (
            NftDelegatePower.freeze,
            'Permission to lock Piece',
            'can lock this NFT in your wallet at any time, so that you cannot move it until they unlock it.',
            'can lock it until revoked',
          ),
        ]) {
          await _pump(
            tester,
            _review(accounts: [grant(power)], nftMetadata: named),
            size: const Size(600, 1400),
          );
          expect(find.text('PERMISSION'), findsOneWidget, reason: power.name);
          expect(find.text(title), findsOneWidget);
          expect(
            find.textContaining(body, findRichText: true),
            findsOneWidget,
            reason: power.name,
          );
          expect(find.text('Delegating'), findsOneWidget);
          expect(
            find.textContaining(row, findRichText: true),
            findsOneWidget,
            reason: power.name,
          );
          _expectHold();
        }
      });

      testWidgets('a freeze and a transfer delegate to one address are two '
          'grants, each with its card and its row', (tester) async {
        await _pump(
          tester,
          _review(
            accounts: [
              grant(NftDelegatePower.freeze),
              grant(NftDelegatePower.transfer),
              // The same grant read twice is still one.
              grant(NftDelegatePower.transfer),
            ],
            nftMetadata: named,
          ),
          size: const Size(600, 1600),
        );
        expect(find.text('PERMISSION'), findsNWidgets(2));
        expect(find.text('Permission to lock Piece'), findsOneWidget);
        expect(find.text('Permission to transfer Piece'), findsOneWidget);
        expect(find.text('Delegating'), findsNWidgets(2));
      });

      testWidgets('it reads as an NFT even when nothing else names the '
          'asset', (tester) async {
        await _pump(
          tester,
          _review(accounts: [grant(NftDelegatePower.burn)]),
          size: const Size(600, 1400),
        );
        expect(
          find.text(
            'Permission to burn NFT · ${truncateAddress(asset, lead: 6, trail: 6)}',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('base units'), findsNothing);
      });

      testWidgets('a listed marketplace that makes its own address the '
          'delegate gets no card and no hold; one that goes through Core '
          'directly does', (tester) async {
        final labels = ValueNotifier<Map<String, String>>(const {
          market: 'Tensor Marketplace',
          core: 'Metaplex Core',
        });
        Future<void> pump(Set<String> origins) => _pump(
          tester,
          _review(
            accounts: [
              grant(NftDelegatePower.freeze, beneficiary: programDelegate),
              grant(NftDelegatePower.transfer, beneficiary: programDelegate),
            ],
            nftMetadata: named,
            programCalls: const [
              ReviewProgramCall(program: market),
              ReviewProgramCall(program: core),
            ],
            delegatedBy: {asset: origins},
          ),
          programLabels: labels,
          size: const Size(600, 1600),
        );
        await pump(const {market});
        expect(find.text('PERMISSION'), findsNothing);
        // Still said, in the rows.
        expect(find.text('Delegating'), findsNWidgets(2));
        expect(
          find.textContaining('can lock it until revoked', findRichText: true),
          findsOneWidget,
        );
        _expectTap();

        await pump(const {core});
        expect(find.text('PERMISSION'), findsNWidgets(2));
        _expectHold();
      });
    });

    group('a change of authority', () {
      const stakeProgram = 'Stake11111111111111111111111111111111111111';
      const stake = 'StakeAccountHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH';
      const description =
          'Control of a stake account\'s withdraw authority changes';
      final labels = ValueNotifier<Map<String, String>>(const {
        market: 'Tensor Marketplace',
        stakeProgram: 'Stake Program',
        tokenProgram: 'Token Program',
      });
      Future<void> pumpHandover(
        WidgetTester tester, {
        String beneficiary = programDelegate,
        Map<String, Set<String>> delegatedBy = const {
          stake: {market},
        },
        List<String> calls = const [market, stakeProgram],
        SimulationExecution execution = SimulationExecution.succeeded,
      }) => _pump(
        tester,
        _review(
          execution: execution,
          error: execution == SimulationExecution.failed
              ? 'Simulation failed'
              : null,
          accounts: [
            AccountChange(
              kind: AccountChangeKind.authority,
              address: stake,
              program: stakeProgram,
              description: description,
              beneficiary: beneficiary,
              evidence: ReviewEvidence.requestedInstruction,
            ),
          ],
          programCalls: [
            for (final program in calls) ReviewProgramCall(program: program),
          ],
          delegatedBy: delegatedBy,
        ),
        programLabels: labels,
        size: const Size(600, 1400),
      );

      testWidgets('gets the Authority card and the hold', (tester) async {
        await _pump(
          tester,
          _review(
            accounts: const [
              AccountChange(
                kind: AccountChangeKind.authority,
                address: stake,
                program: stakeProgram,
                description: description,
                beneficiary: delegate,
                evidence: ReviewEvidence.requestedInstruction,
              ),
            ],
          ),
          size: const Size(600, 1400),
        );
        expect(find.text('AUTHORITY'), findsOneWidget);
        expect(find.text(description), findsOneWidget);
        _expectHold();
      });

      testWidgets('made by a listed program\'s own code, to an address of a '
          'program, is an account row: no card and no hold', (tester) async {
        await pumpHandover(tester);
        expect(find.text('AUTHORITY'), findsNothing);
        // Still shown: a row, not a card.
        expect(find.text('Account changes'), findsOneWidget);
        expect(find.text(description), findsOneWidget);
        // "Account <stake account> · to <the program's address>".
        final row = find.textContaining(' · to ', findRichText: true);
        expect(row, findsOneWidget);
        expect(
          find.descendant(
            of: row,
            matching: find.text(truncateAddress(stake, lead: 6, trail: 6)),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: row,
            matching: find.text(
              truncateAddress(programDelegate, lead: 6, trail: 6),
            ),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('review-fee-only')), findsNothing);
        _expectTap();
      });

      testWidgets('reported by the call and by the simulated state is still '
          'one row', (tester) async {
        const handover = AccountChange(
          kind: AccountChangeKind.authority,
          address: stake,
          program: stakeProgram,
          description: description,
          beneficiary: programDelegate,
          evidence: ReviewEvidence.requestedInstruction,
        );
        await _pump(
          tester,
          _review(
            accounts: const [handover, handover],
            programCalls: const [ReviewProgramCall(program: market)],
            delegatedBy: const {
              stake: {market},
            },
          ),
          programLabels: labels,
          size: const Size(600, 1400),
        );
        expect(find.text(description), findsOneWidget);
      });

      testWidgets('asked of the Stake Program by the website itself gets '
          'the card and the hold', (tester) async {
        // The Stake Program hands the authority to whoever its caller
        // names.
        await pumpHandover(
          tester,
          delegatedBy: const {
            stake: {stakeProgram},
          },
          calls: const [stakeProgram],
        );
        expect(find.text('AUTHORITY'), findsOneWidget);
        expect(find.text('Account changes'), findsNothing);
        _expectHold();
      });

      testWidgets('to someone\'s wallet, untraced, beside an unlisted '
          'program or on a failed simulation gets the card and the hold', (
        tester,
      ) async {
        await pumpHandover(tester, beneficiary: delegate);
        expect(find.text('AUTHORITY'), findsOneWidget);
        _expectHold();

        await pumpHandover(tester, delegatedBy: const {});
        expect(find.text('AUTHORITY'), findsOneWidget);
        _expectHold();

        await pumpHandover(
          tester,
          calls: const [market, 'Unknown11111111111111111111111111111111111'],
        );
        expect(find.text('AUTHORITY'), findsOneWidget);
        _expectHold();

        await pumpHandover(tester, execution: SimulationExecution.failed);
        expect(find.text('AUTHORITY'), findsOneWidget);
        _expectHold();
      });

      testWidgets('an unlimited allowance a listed program gives its own '
          'address gets no card either', (tester) async {
        Future<void> pump(Set<String> origins) => _pump(
          tester,
          _review(
            accounts: [
              approve(
                allowance: BigInt.parse('18446744073709551615'),
                balance: BigInt.from(500),
                id: 'fungible-mint',
                beneficiary: programDelegate,
              ),
            ],
            programCalls: const [
              ReviewProgramCall(program: market),
              ReviewProgramCall(program: tokenProgram),
            ],
            delegatedBy: {'token-account': origins},
          ),
          programLabels: labels,
        );
        await pump(const {market});
        expect(find.text('PERMISSION'), findsNothing);
        expect(find.text('Delegating'), findsOneWidget);
        _expectTap();

        await pump(const {tokenProgram});
        expect(find.text('PERMISSION'), findsOneWidget);
        expect(find.text('Unlimited token allowance'), findsOneWidget);
        _expectHold();
      });
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

    testWidgets('one unit short of the balance, to a key someone holds, '
        'still gets the card', (tester) async {
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
      expect(find.text('PERMISSION'), findsOneWidget);
      expect(find.text('499 base units allowance'), findsOneWidget);
      expect(
        find.textContaining(
          'can spend up to this amount of your token',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Delegating'), findsOneWidget);
    });

    testWidgets('one unit short of unlimited on an empty account gets the '
        'card, whoever the delegate is', (tester) async {
      final almost = BigInt.parse('18446744073709551614');
      for (final beneficiary in [delegate, programDelegate]) {
        for (final balance in [BigInt.zero, null]) {
          await _pump(
            tester,
            _review(
              accounts: [
                approve(
                  allowance: almost,
                  balance: balance,
                  id: 'fungible-mint',
                  beneficiary: beneficiary,
                ),
              ],
            ),
          );
          expect(
            find.text('PERMISSION'),
            findsOneWidget,
            reason: '$beneficiary, balance $balance',
          );
          expect(find.text('$almost base units allowance'), findsOneWidget);
          expect(find.text('Program permission'), findsNothing);
        }
      }
    });

    testWidgets('a partial allowance only a program can use gets the '
        'Permission card and the hold, or neither when a listed program '
        'chose it', (tester) async {
      final labels = ValueNotifier<Map<String, String>>(const {
        market: 'Tensor Marketplace',
        tokenProgram: 'Token Program',
      });
      Future<void> pump(Set<String> origins) => _pump(
        tester,
        _review(
          accounts: [
            approve(
              allowance: BigInt.from(499),
              balance: BigInt.from(500),
              id: 'fungible-mint',
              beneficiary: programDelegate,
            ),
          ],
          programCalls: const [
            ReviewProgramCall(program: market),
            ReviewProgramCall(program: tokenProgram),
          ],
          delegatedBy: {'token-account': origins},
        ),
        programLabels: labels,
      );
      // A program address the review cannot tie to a listed program may be
      // one of a program the site deployed.
      await pump(const {tokenProgram});
      expect(find.text('PERMISSION'), findsOneWidget);
      expect(find.text('499 base units allowance'), findsOneWidget);
      expect(find.text('Program permission'), findsNothing);
      _expectHold();

      await pump(const {market});
      expect(find.text('PERMISSION'), findsNothing);
      expect(find.text('Delegating'), findsOneWidget);
      _expectTap();
    });

    testWidgets('an NFT approval of zero gets none', (tester) async {
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
      // Nothing is granted, so nothing more is asked.
      _expectTap();
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

  group('a simulation that found the fee and nothing else', () {
    const market = 'TCMPhJdwDryooaGtiocG1u3xcYbRpiJzb283XfCZsDp';
    FundChange fee() => FundChange(
      asset: const ReviewAsset(id: _sol, symbol: 'SOL', decimals: 9),
      address: 'wallet',
      rawAmount: BigInt.from(-5000),
      evidence: ReviewEvidence.simulatedState,
      isNet: true,
    );

    testWidgets('says so, and lists the programs without being asked', (
      tester,
    ) async {
      await _pump(
        tester,
        _review(
          coverage: SimulationCoverage.partial,
          funds: [fee()],
          programCalls: const [
            ReviewProgramCall(program: market, instruction: 'List'),
          ],
        ),
        size: const Size(600, 1400),
      );
      expect(find.byKey(const Key('review-fee-only')), findsOneWidget);
      expect(
        find.textContaining('No change to what your wallet holds was found'),
        findsOneWidget,
      );
      // In the open, not behind the disclosure.
      expect(find.text('Program calls'), findsOneWidget);
      expect(find.text('List'), findsOneWidget);
      expect(find.text('Unknown Program'), findsOneWidget);
      // A statement, not a warning: approving stays a tap.
      expect(find.text('Review carefully'), findsNothing);
      expect(find.byType(HoldToApproveButton), findsNothing);
    });

    testWidgets('does not say so when anything else was found', (tester) async {
      await _pump(
        tester,
        _review(
          funds: [fee()],
          nfts: const [
            NftChange(
              kind: NftChangeKind.transfer,
              assetId: 'compressed',
              description: 'Compressed NFT ownership changes',
              evidence: ReviewEvidence.requestedInstruction,
              from: '11111111111111111111111111111111',
              to: 'recipient',
            ),
          ],
          nftMetadata: const {
            'compressed': ReviewNftMetadata(name: 'Night Garden #7'),
          },
          programCalls: const [
            ReviewProgramCall(program: market, instruction: 'List'),
          ],
        ),
        size: const Size(600, 1400),
      );
      expect(find.byKey(const Key('review-fee-only')), findsNothing);
      expect(find.text('You send'), findsNWidgets(2));
      expect(find.text('Night Garden #7'), findsOneWidget);
      // The calls stay behind their disclosure.
      expect(find.text('List'), findsNothing);
    });

    testWidgets('nor on Ethereum, whose review is not built from balances '
        'alone', (tester) async {
      await _pump(
        tester,
        _review(chain: 'eip155:1', networkFee: BigInt.from(52500000000000)),
      );
      expect(find.byKey(const Key('review-fee-only')), findsNothing);
    });
  });

  testWidgets('a token transfer whose mint is unknown names the account it '
      'leaves, not a token', (tester) async {
    const account = 'TokenAccountDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD';
    await _pump(
      tester,
      _review(
        execution: SimulationExecution.unavailable,
        error: 'Simulation is unavailable.',
        funds: [
          FundChange(
            asset: const ReviewAsset(id: account, symbol: 'Token'),
            address: account,
            rawAmount: BigInt.from(-42),
            evidence: ReviewEvidence.requestedInstruction,
            from: account,
            to: 'destination',
          ),
        ],
      ),
    );
    expect(find.text('You send'), findsOneWidget);
    expect(find.text('42 base units Token'), findsOneWidget);
    expect(
      find.textContaining('Unknown token · from account ', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Unverified token', findRichText: true),
      findsNothing,
    );
  });

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
