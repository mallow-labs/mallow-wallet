import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart' as db;
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/security/biometric_auth.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockBiometric extends Mock implements BiometricAuthService {}

class _MockDb extends Mock implements db.MallowDatabase {}

void main() {
  late _MockStorage storage;
  late _MockBiometric biometric;
  late _MockDb database;

  const correctPin = '123456';
  const wrongPin = '000000';

  setUp(() {
    storage = _MockStorage();
    biometric = _MockBiometric();
    database = _MockDb();

    // Defaults: wallet exists, PIN set, biometric disabled, no lockout.
    when(() => database.hasAnyWallets()).thenAnswer((_) async => true);
    when(() => storage.hasPin()).thenAnswer((_) async => true);
    when(() => storage.loadBiometricEnabled()).thenAnswer((_) async => false);
    // PIN verification is delegated to SecureWalletStorage.verifyPin (which
    // hashes internally); the bloc only sees the boolean outcome.
    when(
      () => storage.verifyPin(any()),
    ).thenAnswer((inv) async => inv.positionalArguments.first == correctPin);
    when(() => storage.loadFailedPinAttempts()).thenAnswer((_) async => 0);
    when(() => storage.loadPinCooldownUntil()).thenAnswer((_) async => null);
    when(() => storage.storeFailedPinAttempts(any())).thenAnswer((_) async {});
    when(() => storage.storePinCooldownUntil(any())).thenAnswer((_) async {});
    when(() => storage.deletePinCooldownUntil()).thenAnswer((_) async {});
    when(() => storage.deleteFailedPinAttempts()).thenAnswer((_) async {});
    when(() => storage.clearPinLockout()).thenAnswer((_) async {});
  });

  AppLockBloc buildBloc() => AppLockBloc(storage, biometric, database);

  // Pump the event loop until the bloc finishes processing a queued event.
  // bloc_test's `expectLater` machinery is overkill for these tests — we
  // just need every queued `add` to drain before we assert on `state`.
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  group('AppLockBloc persisted lockout', () {
    test(
      'hydrates failedAttempts and active cooldown from storage on init',
      () async {
        final cooldown = DateTime.now().add(const Duration(seconds: 30));
        when(() => storage.loadFailedPinAttempts()).thenAnswer((_) async => 5);
        when(
          () => storage.loadPinCooldownUntil(),
        ).thenAnswer((_) async => cooldown);

        final bloc = buildBloc();
        bloc.add(const AppLockEvent.init());
        await settle();

        final state = bloc.state;
        expect(state, isA<AppLockStateLocked>());
        final locked = state as AppLockStateLocked;
        expect(locked.failedAttempts, 5);
        // Stored value preserves the deadline (within a second tolerance for
        // ISO-8601 serialization round-trip).
        expect(
          locked.cooldownUntil!.difference(cooldown).inSeconds.abs(),
          lessThanOrEqualTo(1),
        );

        await bloc.close();
      },
    );

    test('drops an expired cooldown on init but keeps the counter so the next '
        'failure escalates to the right tier', () async {
      final expired = DateTime.now().subtract(const Duration(minutes: 1));
      when(() => storage.loadFailedPinAttempts()).thenAnswer((_) async => 5);
      when(
        () => storage.loadPinCooldownUntil(),
      ).thenAnswer((_) async => expired);

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      final state = bloc.state as AppLockStateLocked;
      expect(state.failedAttempts, 5);
      expect(state.cooldownUntil, isNull);
      verify(() => storage.deletePinCooldownUntil()).called(1);

      await bloc.close();
    });

    test('persists the incremented counter on each wrong PIN', () async {
      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      bloc.add(const AppLockEvent.unlockWithPin(wrongPin));
      await settle();

      verify(() => storage.storeFailedPinAttempts(1)).called(1);
      // No cooldown yet — below threshold.
      verifyNever(() => storage.storePinCooldownUntil(any()));

      await bloc.close();
    });

    test('persists cooldown deadline when reaching the threshold', () async {
      // Hydrate at 4 prior failures so a single new failure crosses into
      // the first cooldown tier.
      when(() => storage.loadFailedPinAttempts()).thenAnswer((_) async => 4);

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      bloc.add(const AppLockEvent.unlockWithPin(wrongPin));
      await settle();

      verify(() => storage.storeFailedPinAttempts(5)).called(1);
      final captured = verify(
        () => storage.storePinCooldownUntil(captureAny()),
      ).captured;
      expect(captured, hasLength(1));
      final deadline = captured.single as DateTime;
      final delta = deadline.difference(DateTime.now()).inSeconds;
      // First-tier cooldown is 30s. Allow a couple-second slack for the
      // time between scheduling and the verify call.
      expect(delta, inInclusiveRange(25, 35));

      await bloc.close();
    });

    test('escalates to the correct cooldown tier after a mid-cooldown '
        'restart', () async {
      // Simulate: app was force-closed during the first cooldown. On wake
      // the persisted state is "5 failed attempts, cooldown elapsed". The
      // next wrong PIN should land us in the second tier (60s).
      when(() => storage.loadFailedPinAttempts()).thenAnswer((_) async => 9);
      when(() => storage.loadPinCooldownUntil()).thenAnswer(
        (_) async => DateTime.now().subtract(const Duration(seconds: 1)),
      );

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      bloc.add(const AppLockEvent.unlockWithPin(wrongPin));
      await settle();

      verify(() => storage.storeFailedPinAttempts(10)).called(1);
      final deadline =
          verify(
                () => storage.storePinCooldownUntil(captureAny()),
              ).captured.single
              as DateTime;
      // Second tier is 60s. Slack ±5s.
      expect(
        deadline.difference(DateTime.now()).inSeconds,
        inInclusiveRange(55, 65),
      );

      await bloc.close();
    });

    test('clears persisted lockout on successful PIN unlock', () async {
      when(() => storage.loadFailedPinAttempts()).thenAnswer((_) async => 3);

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      bloc.add(const AppLockEvent.unlockWithPin(correctPin));
      await settle();

      expect(bloc.state, isA<AppLockStateUnlocked>());
      verify(() => storage.clearPinLockout()).called(1);

      await bloc.close();
    });

    test('does not increment or persist counter while cooldown is still '
        'active', () async {
      when(() => storage.loadFailedPinAttempts()).thenAnswer((_) async => 5);
      when(() => storage.loadPinCooldownUntil()).thenAnswer(
        (_) async => DateTime.now().add(const Duration(seconds: 30)),
      );

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      bloc.add(const AppLockEvent.unlockWithPin(wrongPin));
      await settle();

      verifyNever(() => storage.storeFailedPinAttempts(any()));
      verifyNever(() => storage.storePinCooldownUntil(any()));
      // Counter is unchanged.
      expect((bloc.state as AppLockStateLocked).failedAttempts, 5);

      await bloc.close();
    });

    test('disable() clears persisted lockout', () async {
      when(() => storage.deletePin()).thenAnswer((_) async {});
      when(() => storage.storeBiometricEnabled(false)).thenAnswer((_) async {});

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      bloc.add(const AppLockEvent.disable(correctPin));
      await settle();

      verify(() => storage.clearPinLockout()).called(1);

      await bloc.close();
    });

    test('reset() clears persisted lockout', () async {
      when(() => storage.deletePin()).thenAnswer((_) async {});
      when(() => storage.storeBiometricEnabled(false)).thenAnswer((_) async {});

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      bloc.add(const AppLockEvent.reset());
      await settle();

      verify(() => storage.clearPinLockout()).called(1);

      await bloc.close();
    });
  });
}
