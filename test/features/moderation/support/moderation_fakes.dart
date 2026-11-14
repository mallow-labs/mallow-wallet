import 'package:flutter/foundation.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/features/moderation/data/moderation_repository.dart';
import 'package:mallow_wallet/features/moderation/services/block_store.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_cache.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_filter.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_hide_store.dart';
import 'package:mallow_wallet/shared/utils/chain.dart' show apiOwnerAddress;
import 'package:mocktail/mocktail.dart';

/// A [ModerationCache] held in memory: what survives a "restart" in a test is
/// whatever a second store is handed the same instance of.
class MemoryModerationCache implements ModerationCache {
  final Map<String, String> rows = {};

  /// When set, every read and write throws it.
  Object? failure;

  static String _key(String section, String account) => '$section|$account';

  @override
  Future<String?> read(String section, String account) async {
    if (failure != null) throw failure!;
    return rows[_key(section, account)];
  }

  @override
  Future<void> write(String section, String account, String json) async {
    if (failure != null) throw failure!;
    rows[_key(section, account)] = json;
  }

  @override
  Future<void> remove(String section, String account) async {
    rows.remove(_key(section, account));
  }
}

class SessionAuthMock extends Mock implements AuthService {}

class BlocksRepositoryMock extends Mock implements ModerationRepository {}

/// Stands in for [AuthService] as a [ChangeNotifier], and for
/// [AuthService.walletSigChanges].
class TestNotifier extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// A signed-in session a test can switch and end. Unlike a bare mock it
/// reports the session state the stores read to tell a logout from a switch.
class FakeSession {
  FakeSession({this.address = 'VIEWER'}) {
    when(() => auth.currentAddress).thenAnswer((_) => address);
    when(() => auth.sessionState).thenAnswer((_) => state);
    when(() => auth.walletSigChanges).thenReturn(sigChanges);
    when(() => auth.addListener(any())).thenAnswer(
      (i) => changes.addListener(i.positionalArguments.first as VoidCallback),
    );
    when(() => auth.removeListener(any())).thenAnswer(
      (i) =>
          changes.removeListener(i.positionalArguments.first as VoidCallback),
    );
    when(
      () => auth.canSendBackgroundSignedRead(),
    ).thenAnswer((_) async => hasProof && address != null);
  }

  final SessionAuthMock auth = SessionAuthMock();
  final TestNotifier changes = TestNotifier();
  final TestNotifier sigChanges = TestNotifier();

  String? address;
  SessionState state = SessionState.authenticated;

  /// Whether the session holds a valid ownership proof.
  bool hasProof = false;

  /// A wallet switch as listeners see it: no address while the next wallet
  /// logs in, then the new one.
  void switchTo(String next) {
    address = null;
    state = SessionState.loading;
    changes.fire();
    address = next;
    state = SessionState.authenticated;
    changes.fire();
  }

  void logout() {
    address = null;
    state = SessionState.initial;
    changes.fire();
  }

  void dispose() {
    changes.dispose();
    sigChanges.dispose();
  }
}

/// A block list holding [blocked], with no server and no device copy.
BlockStore blockStoreHolding(Iterable<String> blocked, {FakeSession? session}) {
  final store = BlockStore(
    BlocksRepositoryMock(),
    (session ?? FakeSession()).auth,
  );
  store.blocked.value = blocked.map(apiOwnerAddress).toSet();
  return store;
}

/// A filter over a fixed block list and an empty, in-memory report store.
/// [own] are the viewer's own addresses.
({ModerationFilter filter, BlockStore blocks, ModerationHideStore hides})
moderationOver({
  Iterable<String> blocked = const [],
  Iterable<String> own = const [],
}) {
  final blocks = blockStoreHolding(blocked);
  final hides = ModerationHideStore();
  final mine = own.map(apiOwnerAddress).toSet();
  return (
    filter: ModerationFilter(
      blocks: blocks,
      hides: hides,
      isOwnAddress: (a) => mine.contains(apiOwnerAddress(a)),
    ),
    blocks: blocks,
    hides: hides,
  );
}
