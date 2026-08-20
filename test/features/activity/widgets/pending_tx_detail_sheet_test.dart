import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// Re-exports `pending_evm_tx.dart` (PendingEvmTx and friends).
import 'package:mallow_wallet/core/services/pending_evm_tx_tracker.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/activity/widgets/pending_tx_detail_sheet.dart';
import 'package:mallow_wallet/features/portfolio/data/ethereum_token_service.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The "Max fee" row is the only number in this sheet the user can act on: it is
// what they weigh before deciding to cancel or speed up. A cancel is a 0-ETH
// self-send burning 21 000 gas, so pricing it against the *original*
// transaction's gas limit (90 000 for an ERC-20 transfer) overstates the
// ceiling more than 4× — the user is told a cancellation costs money it cannot
// cost.

const _wallet = '0x1111111111111111111111111111111111111111';
const _erc20GasLimit = 90000;

final _hundredGwei = BigInt.from(100000000000);

/// What the 110% replacement floor produces from [_hundredGwei] — so the cancel
/// is genuinely the highest-fee candidate, as it always is right after being
/// broadcast.
final _oneTenGwei = BigInt.from(110000000000);

class _MockEthereumTokenService extends Mock implements EthereumTokenService {}

class _MockSessionManager extends Mock implements SessionManager {}

class _MockPendingEvmTxTracker extends Mock implements PendingEvmTxTracker {}

PendingTxCandidate _candidate(PendingTxCandidateRole role, BigInt maxFee) =>
    PendingTxCandidate(
      hash: '0xabc${role.name}',
      role: role.name,
      maxFeePerGas: maxFee,
      maxPriorityFeePerGas: BigInt.from(2000000000),
      broadcastAt: 1753840000,
    );

PendingEvmTx _entry(List<PendingTxCandidate> candidates) => PendingEvmTx(
  walletAddress: _wallet,
  nonce: 7,
  chainId: 1,
  kind: PendingEvmTxKind.send,
  // A cancel candidate only ever exists on a slot already flipped to
  // `cancelling`; the row keeps the original's gas limit either way.
  status: candidates.any((c) => c.isCancel)
      ? PendingEvmTxStatus.cancelling
      : PendingEvmTxStatus.pending,
  toAddress: '0x2222222222222222222222222222222222222222',
  valueWei: BigInt.zero,
  data: '0xa9059cbb',
  gasLimit: _erc20GasLimit,
  metadata: const PendingTxMetadata(title: 'Send'),
  candidates: candidates,
  createdAt: 1753840000,
);

Future<void> _openSheet(WidgetTester tester, PendingEvmTx entry) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPendingTxDetailSheet(context, entry),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // The explorer button resolves the user's preferred explorer by name on
    // build, so the sheet can't render without this registration.
    if (!sl.isRegistered<PreferencesService>()) {
      SharedPreferences.setMockInitialValues({});
      sl.registerSingleton<PreferencesService>(
        await PreferencesService.create(),
      );
    }
  });

  late _MockSessionManager session;
  late StreamController<List<PendingEvmTx>> entries;

  setUp(() {
    final tokens = _MockEthereumTokenService();
    when(
      () => tokens.getTokenBalances(any()),
    ).thenAnswer((_) async => <TokenBalance>[]);
    session = _MockSessionManager();
    // View-only by default: the fee row is what's under test, and hiding the
    // action row keeps the signing prompts out of it.
    when(() => session.signableSessionAddresses).thenReturn(<String>{});
    // The sheet follows the tracker so it can't go stale behind an action the
    // user already took (see the cancel test below).
    entries = StreamController<List<PendingEvmTx>>();
    final tracker = _MockPendingEvmTxTracker();
    when(tracker.watch).thenAnswer((_) => entries.stream);
    sl
      ..registerSingleton<EthereumTokenService>(tokens)
      ..registerSingleton<SessionManager>(session)
      ..registerSingleton<PendingEvmTxTracker>(tracker);
  });

  tearDown(() async {
    await entries.close();
    await sl.unregister<EthereumTokenService>();
    await sl.unregister<SessionManager>();
    await sl.unregister<PendingEvmTxTracker>();
  });

  testWidgets('max fee prices a cancel candidate at the cancel gas limit', (
    tester,
  ) async {
    await _openSheet(
      tester,
      _entry([
        _candidate(PendingTxCandidateRole.original, _hundredGwei),
        _candidate(PendingTxCandidateRole.cancel, _oneTenGwei),
      ]),
    );

    // 21 000 × 110 gwei. The original's 90 000 limit would read 0.0099 ETH —
    // 4.3× the fee the cancel can actually cost.
    expect(find.text('0.00231 ETH'), findsOneWidget);
    expect(find.text('0.0099 ETH'), findsNothing);
  });

  testWidgets('max fee prices a speed-up at the original gas limit', (
    tester,
  ) async {
    await _openSheet(
      tester,
      _entry([
        _candidate(PendingTxCandidateRole.original, _hundredGwei),
        _candidate(PendingTxCandidateRole.speedup, _oneTenGwei),
      ]),
    );

    // A speed-up replays the original payload verbatim, so 90 000 × 110 gwei
    // is the right ceiling here.
    expect(find.text('0.0099 ETH'), findsOneWidget);
  });

  // WHY: the sheet stays open across the Cancel prompt it launched. Held to the
  // entry it was constructed with, it would keep offering Cancel on a slot whose
  // cancel is already in the mempool — and the second cancel prices its caps off
  // the pre-cancel candidates, at or below the bid it has to beat, so the node
  // rejects the re-signed transaction as "replacement transaction underpriced".
  // Following the tracker is what keeps the sheet and the list cell agreeing.
  testWidgets('stops offering Cancel once the cancel has been broadcast', (
    tester,
  ) async {
    when(() => session.signableSessionAddresses).thenReturn({_wallet});
    await _openSheet(
      tester,
      _entry([_candidate(PendingTxCandidateRole.original, _hundredGwei)]),
    );

    expect(find.text('Cancel'), findsOneWidget);

    entries.add([
      _entry([
        _candidate(PendingTxCandidateRole.original, _hundredGwei),
        _candidate(PendingTxCandidateRole.cancel, _oneTenGwei),
      ]),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Cancel'), findsNothing);
    // Speed up survives — bumping the cancel itself is still a valid action.
    expect(find.text('Speed up'), findsOneWidget);
  });
}
