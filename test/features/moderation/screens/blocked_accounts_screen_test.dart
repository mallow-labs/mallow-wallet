import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/moderation/data/moderation_repository.dart';
import 'package:mallow_wallet/features/moderation/screens/blocked_accounts_screen.dart';
import 'package:mallow_wallet/features/moderation/services/block_store.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements ModerationRepository {}

class _MockAuth extends Mock implements AuthService {}

class _MockAvatars extends Mock implements AvatarService {}

const _gone = 'UNBLOCKED_ADDR';
const _kept = 'STILL_BLOCKED_ADDR';

api.BlockedAccount _row(String address) =>
    api.BlockedAccount(address: address, createdAt: 'now');

void main() {
  late _MockRepo repo;
  late _MockAuth auth;
  late ChangeNotifier sigChanges;
  late BlockStore store;
  late List<Completer<List<api.BlockedAccount>>> reads;

  setUpAll(() => registerFallbackValue(() {}));

  setUp(() {
    repo = _MockRepo();
    auth = _MockAuth();
    sigChanges = ChangeNotifier();
    reads = [];
    when(() => auth.currentAddress).thenReturn('VIEWER');
    when(() => auth.walletSigChanges).thenReturn(sigChanges);
    when(
      () => auth.canSendBackgroundSignedRead(),
    ).thenAnswer((_) async => false);
    when(
      () => repo.listBlocks(background: any(named: 'background')),
    ).thenAnswer((_) {
      final read = Completer<List<api.BlockedAccount>>();
      reads.add(read);
      return read.future;
    });
    when(() => repo.unblock(any())).thenAnswer((_) async {});
    store = BlockStore(repo, auth);

    final avatars = _MockAvatars();
    when(() => avatars.cachedFile(any())).thenReturn(null);
    when(() => avatars.avatarFile(any())).thenAnswer((_) async => null);
    for (final unregister in [
      if (sl.isRegistered<AvatarService>())
        () => sl.unregister<AvatarService>(),
      if (sl.isRegistered<BlockStore>()) () => sl.unregister<BlockStore>(),
    ]) {
      unregister();
    }
    sl.registerSingleton<AvatarService>(avatars);
    sl.registerSingleton<BlockStore>(store);
  });

  tearDown(() {
    sl.unregister<AvatarService>();
    sl.unregister<BlockStore>();
    sigChanges.dispose();
  });

  // The screen's read can be overtaken by a write (an unblock from a profile's
  // interstitial). Its rows then predate the write; the store already dropped
  // them, and the screen must not show them either.
  testWidgets('rows a write overtook are not shown', (tester) async {
    when(
      () => auth.canSendBackgroundSignedRead(),
    ).thenAnswer((_) async => true);
    await tester.pumpWidget(const MaterialApp(home: BlockedAccountsScreen()));
    await tester.pump();
    expect(reads, hasLength(1), reason: 'the screen read is out');

    await tester.runAsync(() => store.unblock(_gone));
    reads.first.complete([_row(_gone), _row(_kept)]);
    await tester.pump();
    await tester.pump();
    expect(find.text(_gone), findsNothing);

    // The store re-reads after the write; the screen follows that list.
    expect(reads, hasLength(2));
    // That re-read was started from the real zone the unblock ran in.
    await tester.runAsync(() async {
      reads.last.complete([_row(_kept)]);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.text(_kept), findsOneWidget);
    expect(find.text(_gone), findsNothing);
  });

  testWidgets('a read nothing overtook shows every row', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: BlockedAccountsScreen()));
    await tester.pump();

    reads.first.complete([_row(_gone), _row(_kept)]);
    await tester.pump();
    await tester.pump();

    expect(find.text(_kept), findsOneWidget);
    expect(find.text(_gone), findsOneWidget);
  });
}
