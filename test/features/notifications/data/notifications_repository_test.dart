import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/features/notifications/data/notifications_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockApi extends Mock implements api.MallowApiClient {}

class _MockAuth extends Mock implements AuthService {}

/// Stands in for [AuthService.walletSigChanges] and for [AuthService] itself
/// as a [ChangeNotifier].
class _Notifier extends ChangeNotifier {
  void fire() => notifyListeners();
}

const _viewer = 'VIEWER_ADDR';

/// One unread-count read as the repository sent it.
typedef _Call = Map<String, Object?>;

void main() {
  late _MockApi apiClient;
  late _MockAuth auth;
  late _Notifier sigChanges;
  late _Notifier session;
  late NotificationsRepository repo;
  late List<_Call> calls;
  late bool canRead;
  late String? address;

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(() {});
  });

  setUp(() {
    apiClient = _MockApi();
    auth = _MockAuth();
    sigChanges = _Notifier();
    session = _Notifier();
    calls = [];
    canRead = true;
    address = _viewer;
    when(() => auth.currentAddress).thenAnswer((_) => address);
    when(() => auth.walletSigChanges).thenReturn(sigChanges);
    when(() => auth.addListener(any())).thenAnswer(
      (i) => session.addListener(i.positionalArguments.first as VoidCallback),
    );
    when(
      () => auth.canSendBackgroundSignedRead(),
    ).thenAnswer((_) async => canRead);
    when(
      () => apiClient.getNotificationUnreadCount(
        requireProof: any(named: 'requireProof'),
        extras: any(named: 'extras'),
      ),
    ).thenAnswer((i) async {
      calls.add({
        'requireProof': i.namedArguments[#requireProof] as bool,
        'extras': Map<String, dynamic>.from(i.namedArguments[#extras] as Map),
      });
      return const api.NotificationUnreadCountResponse(
        result: api.NotificationUnreadCount(
          unreadCount: 2,
          hasUnreadMessages: true,
        ),
      );
    });
    repo = NotificationsRepository(apiClient, auth);
  });

  tearDown(() {
    sigChanges.dispose();
    session.dispose();
  });

  // The unread count needs a proof once requireProof is sent, and the badge
  // refresh runs when the account drawer opens. A 401 re-sign there would ask
  // a hardware wallet to sign every time the drawer opened, so the refresh
  // opts out of it.
  test('the badge refresh requires the proof and skips the re-sign', () async {
    await repo.refreshUnreadCount();

    expect(calls, [
      {
        'requireProof': true,
        'extras': {kSkipSignatureRetryExtra: true},
      },
    ]);
    expect(repo.hasUnread.value, isTrue);
  });

  // No proof, no request: there is then no 401, so nothing to prompt with.
  test('with no proof cached, sends nothing and keeps the badge', () async {
    canRead = false;
    repo.hasUnread.value = true;

    await repo.refreshUnreadCount();

    expect(calls, isEmpty);
    expect(repo.hasUnread.value, isTrue);
  });

  test('refreshes when a proof arrives after a skipped refresh', () async {
    canRead = false;
    await repo.refreshUnreadCount();

    canRead = true;
    sigChanges.fire();
    await pumpEventQueue();

    expect(calls, hasLength(1));
    expect(repo.hasUnread.value, isTrue);
  });

  test('a proof alone does not refresh a badge nobody asked for', () async {
    sigChanges.fire();
    await pumpEventQueue();

    expect(calls, isEmpty);
  });

  // The badge described the previous wallet's notifications.
  test('a wallet switch or logout resets the badge', () async {
    await repo.refreshUnreadCount();
    expect(repo.hasUnread.value, isTrue);

    address = 'OTHER_ADDR';
    canRead = false;
    session.fire();
    expect(repo.hasUnread.value, isFalse);

    repo.hasUnread.value = true;
    address = null;
    session.fire();
    expect(repo.hasUnread.value, isFalse);
  });

  // A refresh for the new wallet must not join the old wallet's request still
  // in flight: the badge would wait on, and then drop, the wrong answer.
  test('a refresh after a switch does not join the old wallet\'s', () async {
    final answers = <Completer<api.NotificationUnreadCountResponse>>[];
    when(
      () => apiClient.getNotificationUnreadCount(
        requireProof: any(named: 'requireProof'),
        extras: any(named: 'extras'),
      ),
    ).thenAnswer((_) {
      final answer = Completer<api.NotificationUnreadCountResponse>();
      answers.add(answer);
      return answer.future;
    });
    const unread = api.NotificationUnreadCountResponse(
      result: api.NotificationUnreadCount(
        unreadCount: 1,
        hasUnreadMessages: true,
      ),
    );
    const read = api.NotificationUnreadCountResponse(
      result: api.NotificationUnreadCount(
        unreadCount: 0,
        hasUnreadMessages: false,
      ),
    );

    final forA = repo.refreshUnreadCount();
    await pumpEventQueue();
    expect(answers, hasLength(1));

    address = 'OTHER_ADDR';
    session.fire();
    final forB = repo.refreshUnreadCount();
    await pumpEventQueue();
    expect(answers, hasLength(2), reason: 'B sends its own request');

    answers[1].complete(unread);
    await forB;
    answers[0].complete(read);
    await forA;

    expect(repo.hasUnread.value, isTrue, reason: "B's answer, not A's");
  });

  test('a direct read requires the proof and keeps the 401 re-sign', () async {
    await repo.getUnreadCount();

    expect(calls, [
      {'requireProof': true, 'extras': <String, dynamic>{}},
    ]);
  });
}
