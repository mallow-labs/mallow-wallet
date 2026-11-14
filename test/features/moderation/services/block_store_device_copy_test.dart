import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/features/moderation/services/block_store.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_cache.dart';
import 'package:mocktail/mocktail.dart';

import '../support/moderation_fakes.dart';

// The block list can only be read with a signed login, and the background
// load never asks for a signature. A Ledger, Keystone or Seed Vault session
// (or a social wallet missing its key) usually holds no proof, so without a
// copy on the device its block list stayed empty: no interstitial on a
// blocked profile, nothing filtered from any list.

const _viewer = 'VIEWER';
const _other = 'OTHER_WALLET';
const _blocked = 'BLOCKED_ADDR';
const _blockedToo = 'BLOCKED_TOO';

void main() {
  late FakeSession session;
  late BlocksRepositoryMock repo;
  late MemoryModerationCache cache;
  late List<String> serverList;
  late int reads;
  final stores = <BlockStore>[];

  setUpAll(() => registerFallbackValue(() {}));

  setUp(() {
    session = FakeSession(address: _viewer);
    repo = BlocksRepositoryMock();
    cache = MemoryModerationCache();
    serverList = [_blocked];
    reads = 0;
    when(
      () => repo.listBlocks(background: any(named: 'background')),
    ).thenAnswer((_) async {
      reads++;
      return [
        for (final a in serverList)
          api.BlockedAccount(address: a, createdAt: 'now'),
      ];
    });
    when(() => repo.block(any())).thenAnswer((_) async {});
    when(() => repo.unblock(any())).thenAnswer((_) async {});
  });

  tearDown(() {
    for (final store in stores) {
      store.dispose();
    }
    stores.clear();
    session.dispose();
  });

  /// A store as a fresh launch would build it, over the same device copy.
  BlockStore launch() {
    final store = BlockStore(repo, session.auth, cache: cache);
    stores.add(store);
    return store;
  }

  Set<String>? copyOf(String account) {
    final json = cache.rows['${ModerationCacheSection.blocks}|$account'];
    return json == null
        ? null
        : (jsonDecode(json) as List<dynamic>).cast<String>().toSet();
  }

  test('a signed read stores the list on the device', () async {
    session.hasProof = true;
    final store = launch();
    await store.ensureLoaded();
    await store.persisted;

    expect(copyOf(_viewer), {_blocked});
  });

  // The case this exists for.
  test('with no proof, the stored list still applies after a '
      'restart', () async {
    session.hasProof = true;
    final first = launch();
    await first.ensureLoaded();
    await first.persisted;

    // Next launch: a session that cannot prove itself, so no read goes out.
    session.hasProof = false;
    reads = 0;
    final second = launch();
    await second.ensureLoaded();

    expect(reads, 0, reason: 'never asks for a signature to load the list');
    expect(second.isBlocked(_blocked), isTrue);
  });

  test('the stored list is published before any proof is checked', () async {
    cache.rows['${ModerationCacheSection.blocks}|$_viewer'] = jsonEncode([
      _blocked,
    ]);
    final store = launch();
    var published = 0;
    store.blocked.addListener(() => published++);

    await pumpEventQueue();

    expect(store.isBlocked(_blocked), isTrue);
    expect(published, 1, reason: 'lists on screen are told to filter again');
    verifyNever(() => session.auth.canSendBackgroundSignedRead());
  });

  test('a proof that arrives later replaces the stored list with the '
      'server\'s', () async {
    cache.rows['${ModerationCacheSection.blocks}|$_viewer'] = jsonEncode([
      _blockedToo,
    ]);
    final store = launch();
    await store.ensureLoaded();
    expect(store.isBlocked(_blockedToo), isTrue);

    session.hasProof = true;
    session.sigChanges.fire();
    await pumpEventQueue();
    await store.persisted;

    expect(store.isBlocked(_blocked), isTrue);
    expect(
      store.isBlocked(_blockedToo),
      isFalse,
      reason: 'unblocked elsewhere',
    );
    expect(copyOf(_viewer), {_blocked});
  });

  // Every list on screen filters itself again when the set notifies. A read
  // that returns the list the store already holds must stay quiet.
  test('a read that changes nothing does not notify', () async {
    cache.rows['${ModerationCacheSection.blocks}|$_viewer'] = jsonEncode([
      _blocked,
    ]);
    session.hasProof = true;
    final store = launch();
    await pumpEventQueue();
    var notified = 0;
    store.blocked.addListener(() => notified++);

    await store.ensureLoaded();
    await store.refresh();

    expect(reads, 2);
    expect(notified, 0);
    expect(store.isBlocked(_blocked), isTrue);
  });

  test('a block and an unblock rewrite the stored list', () async {
    final store = launch();
    await pumpEventQueue();

    expect(await store.block(_blockedToo), isTrue);
    await store.persisted;
    expect(copyOf(_viewer), {_blockedToo});

    expect(await store.unblock(_blockedToo), isTrue);
    await store.persisted;
    expect(copyOf(_viewer), isEmpty);
  });

  test('a block made before the stored list was read keeps what it '
      'held', () async {
    cache.rows['${ModerationCacheSection.blocks}|$_viewer'] = jsonEncode([
      _blocked,
    ]);
    final store = launch();

    // No pump: the read of the device copy is still in flight.
    expect(await store.block(_blockedToo), isTrue);
    await store.persisted;

    expect(store.isBlocked(_blocked), isTrue);
    expect(store.isBlocked(_blockedToo), isTrue);
    expect(copyOf(_viewer), {_blocked, _blockedToo});
  });

  test('a failed write changes nothing on the device', () async {
    when(() => repo.block(any())).thenThrow(StateError('offline'));
    final store = launch();
    await pumpEventQueue();

    expect(await store.block(_blockedToo), isFalse);
    await store.persisted;

    expect(copyOf(_viewer), isNull);
    expect(store.isBlocked(_blockedToo), isFalse);
  });

  group('accounts', () {
    // One account's blocks must never hide anything for another.
    test('a wallet switch does not carry the list over, and each account '
        'gets its own back', () async {
      session.hasProof = true;
      final store = launch();
      await store.ensureLoaded();
      await store.persisted;
      expect(store.isBlocked(_blocked), isTrue);

      // The other wallet has no proof and has never blocked anyone.
      session.hasProof = false;
      session.switchTo(_other);
      await pumpEventQueue();

      expect(store.isBlocked(_blocked), isFalse);
      expect(copyOf(_other), isNull);
      expect(copyOf(_viewer), {_blocked}, reason: 'kept for the way back');

      session.switchTo(_viewer);
      await pumpEventQueue();

      expect(store.isBlocked(_blocked), isTrue);
    });

    test('a block that lands after a switch goes to the account that sent '
        'it', () async {
      final store = launch();
      await pumpEventQueue();
      when(() => repo.block(any())).thenAnswer((_) async {
        // The session moves on while the request is in flight.
        session.switchTo(_other);
      });

      expect(await store.block(_blockedToo), isTrue);
      await store.persisted;

      expect(store.isBlocked(_blockedToo), isFalse, reason: 'not this account');
      expect(copyOf(_viewer), {_blockedToo});
      expect(copyOf(_other), isNull);
    });

    test('logout deletes the stored list of the account that was signed '
        'in', () async {
      session.hasProof = true;
      final store = launch();
      await store.ensureLoaded();
      await store.persisted;
      expect(copyOf(_viewer), {_blocked});

      session.logout();
      await store.persisted;

      expect(store.isBlocked(_blocked), isFalse);
      expect(copyOf(_viewer), isNull);

      // Signing back in without a proof starts from nothing.
      session.hasProof = false;
      session.switchTo(_viewer);
      await pumpEventQueue();
      expect(store.isBlocked(_blocked), isFalse);
    });

    // A switch clears the address on its way to the next wallet. A logout
    // that lands in between still has to forget the wallet being left.
    test('a logout in the middle of a switch forgets the wallet being '
        'left', () async {
      session.hasProof = true;
      final store = launch();
      await store.ensureLoaded();
      await store.persisted;

      session.address = null;
      session.state = SessionState.loading;
      session.changes.fire();
      expect(copyOf(_viewer), {_blocked}, reason: 'a switch keeps the copy');

      session.logout();
      await store.persisted;
      expect(copyOf(_viewer), isNull);
    });
  });

  test('an unreadable copy is treated as none', () async {
    cache.rows['${ModerationCacheSection.blocks}|$_viewer'] = '{not json';
    final store = launch();
    await store.ensureLoaded();
    expect(store.blocked.value, isEmpty);
  });

  test('a device that cannot store the copy still blocks in memory', () async {
    cache.failure = StateError('disk full');
    final store = launch();
    await pumpEventQueue();

    expect(await store.block(_blockedToo), isTrue);
    await store.persisted;

    expect(store.isBlocked(_blockedToo), isTrue);
  });
}
