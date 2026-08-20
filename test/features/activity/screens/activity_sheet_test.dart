import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/services/pending_evm_tx_tracker.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/activity/data/activity_repository.dart';
import 'package:mallow_wallet/features/activity/screens/activity_screen.dart';
import 'package:mallow_wallet/features/activity/services/activity_refresh_signal.dart';
import 'package:mallow_wallet/features/activity/widgets/pending_activity_section.dart';
import 'package:mallow_wallet/shared/widgets/error_view.dart';
import 'package:mocktail/mocktail.dart';

// Two properties of the "Recent activity" sheet are under test here, both about
// what the user can still see and reach while transactions are in flight:
//
// 1. A tracked EVM transaction that resolves while the sheet is open removes
//    its Pending cell immediately, but the confirmed row only exists
//    server-side. Without a live refetch the transaction appears to vanish
//    until the user closes and reopens the sheet.
// 2. The Pending group is the first section of the feed's single scroll view
//    and its size is unbounded (one slot per nonce per session EVM wallet,
//    plus external nonce gaps, and nothing expires). Because everything
//    scrolls together, a stuck wallet can never overflow the sheet or make
//    later entries unreachable — every slot is reached by scrolling the sheet
//    itself, like history under a day header.

const _wallet = '0x1111111111111111111111111111111111111111';

class _MockActivityRepository extends Mock implements ActivityRepository {}

class _MockSessionManager extends Mock implements SessionManager {}

class _MockWalletRepository extends Mock implements WalletRepository {}

class _MockPendingEvmTxTracker extends Mock implements PendingEvmTxTracker {}

late _MockActivityRepository _repo;
late ActivityRefreshSignal _signal;

/// Number of `/v2/activity` fetches the sheet has made — counted in the stub
/// rather than with `verify`, which marks calls as verified and so can't
/// distinguish "refetched" from "never fetched again".
late int _fetches;

PendingEvmTx _pending(int nonce) => PendingEvmTx(
  walletAddress: _wallet,
  nonce: nonce,
  chainId: 1,
  kind: PendingEvmTxKind.send,
  status: PendingEvmTxStatus.pending,
  toAddress: '0x2222222222222222222222222222222222222222',
  valueWei: BigInt.from(1000),
  data: '',
  gasLimit: 21000,
  // Per-nonce title so a test can target one specific cell in the list.
  metadata: PendingTxMetadata(title: 'Send $nonce', subtitle: 'to 0x2222…2222'),
  candidates: const [],
  createdAt: 1753840000,
);

api.Activity _optimisticSend() => const api.Activity(
  id: 'sig-local-send',
  type: api.ActivityType.send,
  timestamp: 1753840001,
  signature: 'sig-local-send',
  status: api.ActivityStatus.confirmed,
  data: {
    'token': {
      'mint': 'So11111111111111111111111111111111111111112',
      'symbol': 'SOL',
      'amount': 1.5,
      'decimals': 9,
    },
    'counterparty': {'address': '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM'},
    'isNft': false,
  },
);

/// Pumps without settling: both the loading skeleton's shimmer and the header
/// refresh loader animate indefinitely, so `pumpAndSettle` never returns.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _openSheet(
  WidgetTester tester, {
  List<PendingEvmTx> pending = const [],
}) async {
  final tracker = _MockPendingEvmTxTracker();
  when(() => tracker.watch()).thenAnswer((_) => Stream.value(pending));
  when(() => tracker.refreshNow()).thenAnswer((_) async {});
  sl.registerSingleton<PendingEvmTxTracker>(tracker);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showActivitySheet(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _pumpFrames(tester);

  // One neutral tap inside the sheet. `SheetOverscrollDismiss` (the wrapper
  // `showFullScreenSheet` puts around every full-screen sheet) creates its
  // `AnimationController` lazily, and disposing a sheet that was never touched
  // constructs a ticker from `dispose()` — which trips a framework assertion
  // when the test's widget tree is finalised. A pointer-down initialises the
  // controller, so teardown is clean.
  await tester.tap(find.text('Recent activity'));
  await tester.pump();
}

void main() {
  setUpAll(() => registerFallbackValue(<String>[_wallet]));

  setUp(() {
    _fetches = 0;
    _repo = _MockActivityRepository();
    when(
      () => _repo.getCachedActivities(any(), limit: any(named: 'limit')),
    ).thenAnswer((_) async => <api.Activity>[]);
    when(() => _repo.cacheActivities(any(), any())).thenAnswer((_) async {});
    when(
      () => _repo.getActivities(
        addresses: any(named: 'addresses'),
        page: any(named: 'page'),
        limit: any(named: 'limit'),
        types: any(named: 'types'),
        before: any(named: 'before'),
      ),
    ).thenAnswer((_) async {
      _fetches++;
      return const api.ActivityListResponse(
        result: [],
        pagination: api.ActivityPagination(page: 0, limit: 50, hasMore: false),
      );
    });

    final session = _MockSessionManager();
    when(() => session.apiOwnerAddresses).thenReturn([_wallet]);
    when(() => session.signableSessionAddresses).thenReturn({_wallet});

    final wallets = _MockWalletRepository();
    when(() => wallets.getActiveSelection()).thenAnswer((_) async => null);

    _signal = ActivityRefreshSignal();

    sl
      ..registerSingleton<ActivityRepository>(_repo)
      ..registerSingleton<SessionManager>(session)
      ..registerSingleton<WalletRepository>(wallets)
      ..registerSingleton<ActivityRefreshSignal>(_signal);
  });

  tearDown(() async {
    _signal.dispose();
    await sl.unregister<ActivityRepository>();
    await sl.unregister<SessionManager>();
    await sl.unregister<WalletRepository>();
    await sl.unregister<ActivityRefreshSignal>();
    await sl.unregister<PendingEvmTxTracker>();
  });

  testWidgets('refresh signal refetches the feed while the sheet is open', (
    tester,
  ) async {
    await _openSheet(tester, pending: [_pending(1)]);
    expect(_fetches, 1, reason: 'initial load');

    // What the tracker fires when a pending transaction resolves: the Pending
    // cell is gone, and only a refetch can surface the confirmed server row.
    _signal.requestRefresh();
    await _pumpFrames(tester);

    expect(_fetches, 2, reason: 'the signal must trigger a refetch');
  });

  testWidgets('optimistic send is visible before the server returns it', (
    tester,
  ) async {
    await _openSheet(tester);

    _signal.requestRefresh(optimisticActivity: _optimisticSend());
    await _pumpFrames(tester);

    expect(find.text('Transferred'), findsOneWidget);
  });

  testWidgets('a stuck wallet scrolls with the feed instead of overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532); // 390 × 844 logical
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _openSheet(
      tester,
      pending: [for (var nonce = 1; nonce <= 8; nonce++) _pending(nonce)],
    );

    expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow');
    expect(find.text('Pending'), findsOneWidget);
    expect(find.byType(PendingActivitySection), findsOneWidget);

    // With something in flight the "No activity yet" view is suppressed —
    // it would contradict the pending cell rendered right above it.
    expect(find.byType(MallowEmptyView), findsNothing);

    // Eight cells don't fit a phone viewport; the last one must be reachable
    // by scrolling the sheet itself, because the group is part of the one
    // scroll view rather than a pinned box that clips it.
    expect(find.text('Send 1'), findsOneWidget);
    final lastCell = find.text('Send 8');
    expect(
      tester.getBottomLeft(lastCell).dy,
      greaterThan(844),
      reason: 'the 8th cell starts below the fold',
    );
    await tester.dragUntilVisible(
      lastCell,
      find.byType(CustomScrollView),
      const Offset(0, -100),
    );
    await tester.pump();
    expect(tester.getBottomLeft(lastCell).dy, lessThanOrEqualTo(844));
  });
}
