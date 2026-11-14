import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/features/moderation/data/moderation_repository.dart';
import 'package:mallow_wallet/features/moderation/services/block_store.dart';
import 'package:mocktail/mocktail.dart';

class _MockApiV2 extends Mock implements api.MallowApiV2Client {}

class _MockAuth extends Mock implements AuthService {}

class _MockRepo extends Mock implements ModerationRepository {}

/// Stands in for [AuthService.walletSigChanges] and for [AuthService] itself
/// as a [ChangeNotifier].
class _Notifier extends ChangeNotifier {
  void fire() => notifyListeners();
}

const _viewer = 'VIEWER_ADDR';
const _other = 'OTHER_ADDR';
const _blockedAddr = 'BLOCKED_ADDR';

/// One `GET /v2/blocks` as the store sent it.
typedef _Call = Map<String, Object?>;

DioException _signatureRefusal() => DioException(
  requestOptions: RequestOptions(path: '/blocks'),
  response: Response<dynamic>(
    requestOptions: RequestOptions(path: '/blocks'),
    statusCode: 401,
    data: {
      'error': {'message': 'Signature required'},
    },
  ),
);

void main() {
  late _MockApiV2 apiV2;
  late _MockAuth auth;
  late _Notifier sigChanges;
  late _Notifier session;
  late BlockStore store;
  late List<_Call> listCalls;
  late bool canRead;
  late String? address;
  late SessionState sessionState;
  late Object? Function() answer;

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(() {});
  });

  setUp(() {
    apiV2 = _MockApiV2();
    auth = _MockAuth();
    sigChanges = _Notifier();
    session = _Notifier();
    listCalls = [];
    canRead = false;
    address = _viewer;
    sessionState = SessionState.authenticated;
    answer = () => null;

    when(() => auth.currentAddress).thenAnswer((_) => address);
    when(() => auth.sessionState).thenAnswer((_) => sessionState);
    when(() => auth.walletSigChanges).thenReturn(sigChanges);
    when(() => auth.addListener(any())).thenAnswer(
      (i) => session.addListener(i.positionalArguments.first as VoidCallback),
    );
    when(() => auth.removeListener(any())).thenAnswer(
      (i) =>
          session.removeListener(i.positionalArguments.first as VoidCallback),
    );
    when(
      () => auth.canSendBackgroundSignedRead(),
    ).thenAnswer((_) async => canRead);
    when(
      () => apiV2.getBlockedAccounts(
        requireProof: any(named: 'requireProof'),
        extras: any(named: 'extras'),
      ),
    ).thenAnswer((i) async {
      listCalls.add({
        'requireProof': i.namedArguments[#requireProof] as bool,
        'extras': Map<String, dynamic>.from(i.namedArguments[#extras] as Map),
      });
      final error = answer();
      if (error != null) throw error;
      return const api.ApiResponse(
        result: [api.BlockedAccount(address: _blockedAddr, createdAt: 'now')],
      );
    });

    store = BlockStore(ModerationRepository(apiV2), auth);
  });

  tearDown(() {
    store.dispose();
    sigChanges.dispose();
    session.dispose();
  });

  group('BlockStore.ensureLoaded (the profile-view background load)', () {
    // The bug: every profile view called GET /v2/blocks, which takes a signed
    // login, and its 401 re-sign opened the hardware verify sheet — on every
    // profile, and again after each cancel. With no proof cached there must be
    // no request at all, so there is no 401 and nothing to prompt with.
    test('with no proof cached, sends nothing', () async {
      await store.ensureLoaded();
      await store.ensureLoaded();

      expect(listCalls, isEmpty);
      expect(store.isBlocked(_blockedAddr), isFalse);
    });

    // With a proof the read goes out, but marked so a 401 is returned rather
    // than re-signed: the proof the client trusts may be one the server no
    // longer accepts, and that must not become a prompt either. requireProof
    // makes that case a 401 instead of an empty list.
    test('with a proof, loads once, requires the proof and skips the '
        're-sign', () async {
      canRead = true;

      await store.ensureLoaded();
      await store.ensureLoaded();

      expect(listCalls, [
        {
          'requireProof': true,
          'extras': {kSkipSignatureRetryExtra: true},
        },
      ]);
      expect(store.isBlocked(_blockedAddr), isTrue);
    });

    test('loads when a proof arrives after a skipped load', () async {
      await store.ensureLoaded();
      expect(listCalls, isEmpty);

      canRead = true;
      sigChanges.fire();
      await pumpEventQueue();

      expect(listCalls, hasLength(1));
      expect(store.isBlocked(_blockedAddr), isTrue);
    });

    test('a cookie change without a proof still sends nothing', () async {
      await store.ensureLoaded();

      sigChanges.fire();
      await pumpEventQueue();

      expect(listCalls, isEmpty);
    });

    // Nothing asked for the list yet, so a new proof is no reason to fetch it.
    test('a proof alone does not load a list nobody asked for', () async {
      canRead = true;
      sigChanges.fire();
      await pumpEventQueue();

      expect(listCalls, isEmpty);
    });

    // A 401 means the server has no proof it accepts yet. Latching the empty
    // result would hide every block until restart; it must wait for a proof.
    test('a refusal latches nothing and reloads on the next proof', () async {
      canRead = true;
      answer = _signatureRefusal;

      await store.ensureLoaded();
      expect(listCalls, hasLength(1));
      expect(store.isBlocked(_blockedAddr), isFalse);

      answer = () => null;
      sigChanges.fire();
      await pumpEventQueue();

      expect(listCalls, hasLength(2));
      expect(store.isBlocked(_blockedAddr), isTrue);
    });

    test('a failed load is swallowed and the next call retries', () async {
      canRead = true;
      answer = () => Exception('down');

      await store.ensureLoaded();
      await store.ensureLoaded();

      expect(listCalls, hasLength(2));
      expect(store.isBlocked(_blockedAddr), isFalse);
    });
  });

  // A GET that went out before a block answers with the list from before it.
  // Adopting that answer silently undid the block the user had just made.
  group('BlockStore writes and an in-flight read', () {
    late List<Completer<List<api.BlockedAccount>>> gets;
    late _MockRepo repo;

    setUp(() {
      gets = [];
      repo = _MockRepo();
      when(
        () => repo.listBlocks(background: any(named: 'background')),
      ).thenAnswer((_) {
        final get = Completer<List<api.BlockedAccount>>();
        gets.add(get);
        return get.future;
      });
      when(() => repo.block(any())).thenAnswer((_) async {});
      when(() => repo.unblock(any())).thenAnswer((_) async {});
      store.dispose();
      store = BlockStore(repo, auth);
      canRead = true;
    });

    api.BlockedAccount row(String address) =>
        api.BlockedAccount(address: address, createdAt: 'now');

    test(
      'a block survives a read that answers after it with the old list',
      () async {
        final load = store.ensureLoaded();
        await pumpEventQueue();
        expect(gets, hasLength(1), reason: 'the read is in flight');

        expect(await store.block(_blockedAddr), isTrue);
        gets.first.complete(const []);
        await load;
        await pumpEventQueue();

        expect(store.isBlocked(_blockedAddr), isTrue);
        expect(gets, hasLength(2), reason: 'the write re-reads the list');

        gets.last.complete([row(_blockedAddr)]);
        await pumpEventQueue();
        expect(store.isBlocked(_blockedAddr), isTrue);
      },
    );

    test(
      'an unblock survives a read that answers after it with the old list',
      () async {
        final load = store.ensureLoaded();
        await pumpEventQueue();
        gets.first.complete([row(_blockedAddr)]);
        await load;
        expect(store.isBlocked(_blockedAddr), isTrue);

        // A second read is out (a session change) when the unblock lands.
        final reload = store.refresh(background: true);
        expect(gets, hasLength(2));
        expect(await store.unblock(_blockedAddr), isTrue);
        gets[1].complete([row(_blockedAddr)]);
        await reload;
        await pumpEventQueue();

        expect(store.isBlocked(_blockedAddr), isFalse);
        gets.last.complete(const []);
        await pumpEventQueue();
        expect(store.isBlocked(_blockedAddr), isFalse);
      },
    );
  });

  group('BlockStore and the logged-in address', () {
    // The list is the viewer's. Serving one wallet's blocks to the next would
    // hide or show the wrong accounts.
    test(
      'a wallet switch drops the list and reloads it for the new address',
      () async {
        canRead = true;
        await store.ensureLoaded();
        expect(store.isBlocked(_blockedAddr), isTrue);

        address = _other;
        canRead = false;
        session.fire();
        await pumpEventQueue();
        expect(store.isBlocked(_blockedAddr), isFalse);
        expect(listCalls, hasLength(1));

        canRead = true;
        sigChanges.fire();
        await pumpEventQueue();
        expect(listCalls, hasLength(2));
        expect(store.isBlocked(_blockedAddr), isTrue);
      },
    );

    test('logout drops the list', () async {
      canRead = true;
      await store.ensureLoaded();

      address = null;
      sessionState = SessionState.initial;
      canRead = false;
      session.fire();
      await pumpEventQueue();

      expect(store.isBlocked(_blockedAddr), isFalse);
    });
  });

  group('BlockStore.refresh (the Blocked accounts screen)', () {
    // The screen is opened on purpose, so its read keeps the ordinary 401
    // handling: a hardware wallet gets the verify sheet there.
    test('requires the proof and does not skip the re-sign', () async {
      await store.refresh();

      expect(listCalls, [
        {'requireProof': true, 'extras': <String, dynamic>{}},
      ]);
    });
  });
}
