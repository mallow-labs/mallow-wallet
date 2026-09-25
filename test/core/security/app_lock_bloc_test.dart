import 'package:flutter/services.dart';
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
    // The bloc reads both factors through one storage call. Its retry — a PIN
    // that reads absent is re-read before it is believed — belongs to the
    // store and is covered in secure_storage_pin_test.dart; here it answers
    // from the two stubs above so each test can set the factors it needs.
    when(() => storage.loadAuthFactors()).thenAnswer(
      (_) async => (
        hasPin: await storage.hasPin(),
        biometricEnabled: await storage.loadBiometricEnabled(),
      ),
    );
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
      when(() => storage.deleteBiometricEnabled()).thenAnswer((_) async {});

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      bloc.add(const AppLockEvent.reset());
      await settle();

      verify(() => storage.clearPinLockout()).called(1);

      await bloc.close();
    });

    test('reset() only deletes — it never writes the biometric flag back '
        'into the store the wipe just emptied', () async {
      when(() => storage.deletePin()).thenAnswer((_) async {});
      when(() => storage.deleteBiometricEnabled()).thenAnswer((_) async {});

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      bloc.add(const AppLockEvent.reset());
      await settle();

      verify(() => storage.deleteBiometricEnabled()).called(1);
      // Both wipe callers await the erase sweep and only then dispatch this
      // event, so a `storeBiometricEnabled(false)` here would re-create
      // `mallow_biometric_enabled` after the sweep — and on iOS a Keychain
      // item outlives an app reinstall.
      verifyNever(() => storage.storeBiometricEnabled(any()));

      await bloc.close();
    });

    test('a delete that fails still drops the in-memory lock state', () async {
      // The vault reports a refused delete now instead of swallowing it, and
      // this event is dispatched after the wipe has already swept the store.
      // The state is the part that cannot be skipped: a bloc still holding
      // `unlocked(hasPin: true)` raises the LockScreen on the next
      // backgrounding, and the PIN that would dismiss it has just been
      // deleted.
      when(
        () => storage.deletePin(),
      ).thenThrow(PlatformException(code: 'delete_failed'));
      when(() => storage.deleteBiometricEnabled()).thenAnswer((_) async {});

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      bloc.add(const AppLockEvent.reset());
      await settle();

      expect(bloc.state, isA<AppLockStateNoPinSet>());
      // And one refusal does not skip the rest: whatever can still be deleted
      // must not be left behind the sweep.
      verify(() => storage.deleteBiometricEnabled()).called(1);
      verify(() => storage.clearPinLockout()).called(1);

      await bloc.close();
    });
  });

  // The app-lock floor is mandatory: onboarding cannot finish with neither a
  // PIN nor biometrics. So on a device that already holds wallets, an absent
  // factor is far more likely a transient secure-storage miss than a state a
  // user can be in — and believing it runs the whole session unlocked and
  // opens the re-auth gate in Settings. The bloc therefore reads the pair
  // through the store's retrying helper, and treats a read it cannot make at
  // all as a lock, not as the absence of one.
  group('AppLockBloc auth-factor floor on init', () {
    test('the factors are read through the retrying helper, not the raw '
        'single reads', () async {
      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      // The retry lives behind this one call: reading hasPin() directly here
      // would put the lock floor back at the mercy of a single keystore miss.
      verify(() => storage.loadAuthFactors()).called(1);

      await bloc.close();
    });

    test('a device with neither factor still ends in noPinSet', () async {
      // Nothing in the app turns the lock off any more — onboarding cannot
      // finish without a factor and `AppLockEvent.disable` is dispatched
      // nowhere — so this is an install that predates the mandatory floor.
      // The fail-closed arm below must not swallow it into a lock that
      // install has no way to pass.
      when(() => storage.hasPin()).thenAnswer((_) async => false);

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      expect(bloc.state, isA<AppLockStateNoPinSet>());

      await bloc.close();
    });

    test('a device with no wallets is not read at all — it has no lock to '
        'lose', () async {
      when(() => database.hasAnyWallets()).thenAnswer((_) async => false);

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      expect(bloc.state, isA<AppLockStateNoPinSet>());
      verifyNever(() => storage.loadAuthFactors());

      await bloc.close();
    });

    test('a factor read that throws locks the app instead of leaving it on '
        'the splash', () async {
      // The reads go through MnemonicVault, which reports an unreadable
      // Keychain/Keystore item as an error rather than as null. Uncaught, the
      // handler emits nothing at all: the bloc stays `uninitialized` and
      // app.dart renders its splash for the rest of the launch, with no way
      // back. The database says wallets are here, so the answer is a lock.
      when(
        () => storage.loadAuthFactors(),
      ).thenThrow(PlatformException(code: 'read_failed'));

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      expect(bloc.state, isA<AppLockStateLocked>());
      // hasPin so the lock screen offers the PIN pad; the biometric-only blur
      // would have no way forward if biometrics then failed.
      expect((bloc.state as AppLockStateLocked).hasPin, isTrue);

      await bloc.close();
    });

    test('an unreadable wallet table locks the app rather than skipping the '
        'lock', () async {
      // Only an emptiness the database *confirmed* may skip the lock.
      when(() => database.hasAnyWallets()).thenThrow(StateError('db closed'));

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      expect(bloc.state, isA<AppLockStateLocked>());

      await bloc.close();
    });

    test('a lockout counter that will not read keeps the lock the factors '
        'asked for', () async {
      // A biometric-only device, and the bookkeeping read behind the counters
      // fails. Only the factor reads may reach the fail-closed state: that
      // state claims a PIN, and this user has none — no PIN pad they can
      // answer, no re-init on resume, force-quit as the only way out. The
      // counter is worth one cooldown tier, not the lock screen.
      when(() => storage.hasPin()).thenAnswer((_) async => false);
      when(() => storage.loadBiometricEnabled()).thenAnswer((_) async => true);
      when(
        () => storage.loadFailedPinAttempts(),
      ).thenThrow(PlatformException(code: 'read_failed'));

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      final state = bloc.state;
      expect(state, isA<AppLockStateLocked>());
      expect((state as AppLockStateLocked).hasPin, isFalse);
      expect(state.biometricEnabled, isTrue);
      // The tier the counter would have named is simply the first one.
      expect(state.failedAttempts, 0);

      await bloc.close();
    });

    test(
      'a cooldown read that throws does not become a PIN-only lock',
      () async {
        when(() => storage.hasPin()).thenAnswer((_) async => false);
        when(
          () => storage.loadBiometricEnabled(),
        ).thenAnswer((_) async => true);
        when(
          () => storage.loadPinCooldownUntil(),
        ).thenThrow(PlatformException(code: 'read_failed'));

        final bloc = buildBloc();
        bloc.add(const AppLockEvent.init());
        await settle();

        final state = bloc.state;
        expect(state, isA<AppLockStateLocked>());
        expect((state as AppLockStateLocked).biometricEnabled, isTrue);
        expect(state.hasPin, isFalse);
        // No deadline read means no deadline enforced — a cooldown the store
        // cannot produce must not lock the user out of the prompt as well.
        expect(state.cooldownUntil, isNull);

        await bloc.close();
      },
    );
  });

  // Unlocking reads the stored PIN hash out of the same vault, so it can throw
  // for the same reason. A handler that dies mid-attempt emits nothing, and
  // the lock screen is left holding a full PIN entry with no answer to it.
  group('AppLockBloc unlock with an unreadable store', () {
    test('a PIN read that throws leaves the app locked and answers the '
        'attempt', () async {
      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      when(
        () => storage.verifyPin(any()),
      ).thenThrow(PlatformException(code: 'read_failed'));

      bloc.add(const AppLockEvent.unlockWithPin(correctPin));
      await settle();

      final state = bloc.state;
      expect(state, isA<AppLockStateLocked>());
      expect((state as AppLockStateLocked).wrongPinAttempt, isTrue);
      // The PIN may well have been right — a store that cannot be read is no
      // evidence against the user, so the cooldown ladder must not advance.
      expect(state.failedAttempts, 0);
      verifyNever(() => storage.storeFailedPinAttempts(any()));

      await bloc.close();
    });

    test('a lockout clear that throws does not hold a biometric unlock '
        'hostage either', () async {
      // Same contract on the biometric path: the auth already succeeded, and
      // the user is behind the privacy blur with nothing but a retry button.
      // A refused counter delete leaves a stale count, which the next
      // successful unlock clears anyway.
      when(() => storage.hasPin()).thenAnswer((_) async => false);
      when(() => storage.loadBiometricEnabled()).thenAnswer((_) async => true);
      when(
        () => storage.clearPinLockout(),
      ).thenThrow(PlatformException(code: 'delete_failed'));
      when(
        () => biometric.authenticateToUnlock(),
      ).thenAnswer((_) async => BiometricAuthResult.success);

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();
      expect(bloc.state, isA<AppLockStateLocked>());

      bloc.add(const AppLockEvent.unlockWithBiometric());
      await settle();

      expect(bloc.state, isA<AppLockStateUnlocked>());
      expect((bloc.state as AppLockStateUnlocked).biometricEnabled, isTrue);

      await bloc.close();
    });

    test('a lockout clear that throws does not hold a correct PIN '
        'hostage', () async {
      when(
        () => storage.clearPinLockout(),
      ).thenThrow(PlatformException(code: 'delete_failed'));

      final bloc = buildBloc();
      bloc.add(const AppLockEvent.init());
      await settle();

      bloc.add(const AppLockEvent.unlockWithPin(correctPin));
      await settle();

      // The PIN verified. Failing to tidy the counter is not a reason to keep
      // the user out.
      expect(bloc.state, isA<AppLockStateUnlocked>());

      await bloc.close();
    });
  });
}
