import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_cache.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_hide_store.dart';
import 'package:mocktail/mocktail.dart';

import '../support/moderation_fakes.dart';

// The app never reads its own reports back, and does not rely on a route to
// leave them out. Held in memory, a reported artwork came back on the first
// fetch after a restart.

const _viewer = 'VIEWER';
const _other = 'OTHER_WALLET';

void main() {
  late FakeSession session;
  late MemoryModerationCache cache;
  final stores = <ModerationHideStore>[];

  setUpAll(() => registerFallbackValue(() {}));

  setUp(() {
    session = FakeSession(address: _viewer);
    cache = MemoryModerationCache();
  });

  tearDown(() {
    for (final store in stores) {
      store.dispose();
    }
    stores.clear();
    session.dispose();
  });

  /// A store as a fresh launch would build it, over the same device copy.
  ModerationHideStore launch() {
    final store = ModerationHideStore(cache: cache, auth: session.auth);
    stores.add(store);
    return store;
  }

  Map<String, dynamic>? copyOf(String account) {
    final json = cache.rows['${ModerationCacheSection.reports}|$account'];
    return json == null ? null : jsonDecode(json) as Map<String, dynamic>;
  }

  test('a report hides its target', () {
    final store = launch();
    store.hide(api.ReportTargetType.artwork, 'mint-1');
    store.hide(api.ReportTargetType.user, 'USER_1');
    store.hide(api.ReportTargetType.curation, 'slug-1', alias: 'id-1');

    expect(store.isArtworkHidden('mint-1'), isTrue);
    expect(store.isUserHidden('USER_1'), isTrue);
    expect(store.isCurationHidden('slug-1'), isTrue);
    expect(store.isCurationHidden('id-1'), isTrue);
    expect(store.isArtworkHidden('mint-2'), isFalse);
  });

  test('each new report notifies once; a repeat does not', () {
    final store = launch();
    var notified = 0;
    store.revision.addListener(() => notified++);

    store.hide(api.ReportTargetType.artwork, 'mint-1');
    store.hide(api.ReportTargetType.artwork, 'mint-1');
    store.hide(api.ReportTargetType.artwork, '');

    expect(notified, 1);
  });

  test('reports stay hidden after a restart', () async {
    final first = launch();
    first.hide(api.ReportTargetType.artwork, 'mint-1');
    first.hide(api.ReportTargetType.curation, 'slug-1', alias: 'id-1');
    first.hide(api.ReportTargetType.user, 'USER_1');
    await first.persisted;

    final second = launch();
    var notified = 0;
    second.revision.addListener(() => notified++);
    await second.restored;

    expect(second.isArtworkHidden('mint-1'), isTrue);
    expect(second.isCurationHidden('slug-1'), isTrue);
    expect(second.isCurationHidden('id-1'), isTrue);
    expect(second.isUserHidden('USER_1'), isTrue);
    expect(notified, 1, reason: 'lists on screen are told to filter again');
  });

  test('a report filed before the stored ones were read is kept with '
      'them', () async {
    final first = launch();
    first.hide(api.ReportTargetType.artwork, 'mint-1');
    await first.persisted;

    final second = launch();
    // No wait: the read of the device copy is still in flight.
    second.hide(api.ReportTargetType.artwork, 'mint-2');
    await second.persisted;

    expect(second.isArtworkHidden('mint-1'), isTrue);
    expect(second.isArtworkHidden('mint-2'), isTrue);
    expect(copyOf(_viewer)!['artworks'], ['mint-1', 'mint-2']);
  });

  group('accounts', () {
    // What one account reported must not hide anything for another.
    test('a wallet switch does not carry reports over, and each account '
        'gets its own back', () async {
      final store = launch();
      store.hide(api.ReportTargetType.artwork, 'mint-1');
      await store.persisted;

      session.switchTo(_other);
      await store.restored;
      expect(store.isArtworkHidden('mint-1'), isFalse);

      store.hide(api.ReportTargetType.artwork, 'mint-2');
      await store.persisted;
      expect(copyOf(_other)!['artworks'], ['mint-2']);
      expect(copyOf(_viewer)!['artworks'], ['mint-1']);

      session.switchTo(_viewer);
      await store.restored;
      expect(store.isArtworkHidden('mint-1'), isTrue);
      expect(store.isArtworkHidden('mint-2'), isFalse);
    });

    test('logout deletes the stored reports of the account that was signed '
        'in', () async {
      final store = launch();
      store.hide(api.ReportTargetType.artwork, 'mint-1');
      await store.persisted;
      expect(copyOf(_viewer), isNotNull);

      session.logout();
      await store.persisted;

      expect(store.isArtworkHidden('mint-1'), isFalse);
      expect(copyOf(_viewer), isNull);
    });

    test('a switch alone deletes nothing', () async {
      final store = launch();
      store.hide(api.ReportTargetType.artwork, 'mint-1');
      await store.persisted;

      session.address = null;
      session.state = SessionState.loading;
      session.changes.fire();
      await store.persisted;

      expect(copyOf(_viewer), isNotNull);
    });
  });

  test('with nobody signed in, reports are held in memory only', () async {
    session.address = null;
    session.state = SessionState.initial;
    final store = launch();
    store.hide(api.ReportTargetType.artwork, 'mint-1');
    await store.persisted;

    expect(store.isArtworkHidden('mint-1'), isTrue);
    expect(cache.rows, isEmpty);
  });

  test('without a cache or a session it still hides for the session', () {
    final store = ModerationHideStore();
    addTearDown(store.dispose);
    store.hide(api.ReportTargetType.artwork, 'mint-1');
    expect(store.isArtworkHidden('mint-1'), isTrue);
  });
}
