import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/settings/services/account_deletion.dart';
import 'package:mocktail/mocktail.dart';

class _MockApiV2 extends Mock implements api.MallowApiV2Client {}

class _MockAuth extends Mock implements AuthService {}

class _MockSession extends Mock implements SessionManager {}

class _MockStorage extends Mock implements SecureWalletStorage {}

DioException _http(int status) => DioException(
  requestOptions: RequestOptions(path: '/user/delete'),
  response: Response<void>(
    requestOptions: RequestOptions(path: '/user/delete'),
    statusCode: status,
  ),
);

void main() {
  late _MockApiV2 apiV2;
  late _MockAuth auth;
  late _MockSession session;
  late _MockStorage storage;

  const accountId = 'acc-1';
  const account = Account(id: accountId, name: 'Account 01');

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerSingleton<T>(instance);
  }

  setUp(() {
    apiV2 = _MockApiV2();
    auth = _MockAuth();
    session = _MockSession();
    storage = _MockStorage();

    register<api.MallowApiV2Client>(apiV2);
    register<AuthService>(auth);
    register<SessionManager>(session);
    register<SecureWalletStorage>(storage);

    // Default: a Profile session anchored to an account that still exists.
    when(() => session.isProfileMode).thenReturn(true);
    when(() => session.activeAccount).thenReturn(account);
    when(
      () => session.switchToAccount(
        any(),
        preferredWalletId: any(named: 'preferredWalletId'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.deleteActiveProfileId()).thenAnswer((_) async {});
    when(() => auth.logout()).thenAnswer((_) async {});
  });

  tearDown(() {
    sl.unregister<api.MallowApiV2Client>();
    sl.unregister<AuthService>();
    sl.unregister<SessionManager>();
    sl.unregister<SecureWalletStorage>();
  });

  group('deletableUsername', () {
    test('null when the logged-in address owns no profile', () {
      when(() => auth.currentUser).thenReturn(null);
      expect(deletableUsername(), isNull);

      when(() => auth.currentUser).thenReturn(const api.User());
      expect(deletableUsername(), isNull);
    });

    // A whitespace-only username is not a username: rendering "@   " in the
    // confirmation sheet would name nothing, and the row would offer a delete
    // the user can't verify.
    test('null when the username is blank', () {
      when(() => auth.currentUser).thenReturn(const api.User(username: '   '));
      expect(deletableUsername(), isNull);
    });

    test('the username when one exists', () {
      when(() => auth.currentUser).thenReturn(const api.User(username: 'ada'));
      expect(deletableUsername(), 'ada');
    });
  });

  group('deleteMallowAccount', () {
    // The single most important guarantee: the backend's `Set-Cookie` clear is
    // a no-op for this client (no cookie jar — `_AuthInterceptor` replays a
    // token it holds itself), so without this call the dead session keeps
    // being replayed on every later request.
    test('success clears the session via AuthService.logout', () async {
      when(() => apiV2.deleteUser()).thenAnswer((_) async {});

      expect(await deleteMallowAccount(), AccountDeletionOutcome.deleted);

      verify(() => auth.logout()).called(1);
    });

    // Wallets outlive Profiles, so the terminal state is an Account-mode
    // session — not onboarding, and not a fresh profile.
    test('success drops a Profile session back to its Account', () async {
      when(() => apiV2.deleteUser()).thenAnswer((_) async {});

      await deleteMallowAccount();

      verify(() => session.switchToAccount(accountId)).called(1);
    });

    // A surviving pointer makes the next cold start try to restore a profile
    // that no longer exists.
    test('success clears the persisted active-profile pointer', () async {
      when(() => apiV2.deleteUser()).thenAnswer((_) async {});

      await deleteMallowAccount();

      verify(() => storage.deleteActiveProfileId()).called(1);
    });

    // An Account-mode session has no ProfileGroup to drop, but the pointer and
    // the session still have to go.
    test(
      'Account-mode session skips the switch but still tears down',
      () async {
        when(() => session.isProfileMode).thenReturn(false);
        when(() => apiV2.deleteUser()).thenAnswer((_) async {});

        expect(await deleteMallowAccount(), AccountDeletionOutcome.deleted);

        verifyNever(() => session.switchToAccount(any()));
        verify(() => storage.deleteActiveProfileId()).called(1);
        verify(() => auth.logout()).called(1);
      },
    );

    // 404 means there is no user doc to delete — already gone, or the known
    // legacy checksummed-EVM-address lookup miss. Surfacing an error would trap
    // those users with a profile they can never remove.
    test('404 is treated as success and still clears the session', () async {
      when(() => apiV2.deleteUser()).thenThrow(_http(404));

      expect(await deleteMallowAccount(), AccountDeletionOutcome.deleted);

      verify(() => storage.deleteActiveProfileId()).called(1);
      verify(() => auth.logout()).called(1);
    });

    // A 401 means the route never ran, so the profile is still there. Reporting
    // it as deleted would show "Your mallow account was deleted" and tear the
    // local session down over a profile that still exists server-side — the
    // exact flow App Review exercises.
    test(
      '401 fails rather than claiming a deletion that never happened',
      () async {
        when(() => apiV2.deleteUser()).thenThrow(_http(401));

        expect(await deleteMallowAccount(), AccountDeletionOutcome.failed);

        verifyNever(() => auth.logout());
        verifyNever(() => storage.deleteActiveProfileId());
      },
    );

    // The profile is still there. Clearing the session would log the user out
    // of an account that was never deleted.
    test('500 fails and leaves the session untouched', () async {
      when(() => apiV2.deleteUser()).thenThrow(_http(500));

      expect(await deleteMallowAccount(), AccountDeletionOutcome.failed);

      verifyNever(() => auth.logout());
      verifyNever(() => session.switchToAccount(any()));
      verifyNever(() => storage.deleteActiveProfileId());
    });

    test('a non-Dio failure also leaves the session untouched', () async {
      when(() => apiV2.deleteUser()).thenThrow(StateError('offline'));

      expect(await deleteMallowAccount(), AccountDeletionOutcome.failed);

      verifyNever(() => auth.logout());
      verifyNever(() => storage.deleteActiveProfileId());
    });
  });
}
