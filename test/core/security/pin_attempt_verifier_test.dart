import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/pin_attempt_verifier.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements SecureWalletStorage {}

void main() {
  const correctPin = '135790';
  const wrongPin = '000000';

  late _MockStorage storage;
  late PinAttemptVerifier verifier;
  late int failed;
  late DateTime? until;

  setUpAll(() => registerFallbackValue(DateTime(2000)));

  setUp(() {
    storage = _MockStorage();
    verifier = PinAttemptVerifier(storage);
    failed = 0;
    until = null;

    when(() => storage.loadFailedPinAttempts()).thenAnswer((_) async => failed);
    when(() => storage.loadPinCooldownUntil()).thenAnswer((_) async => until);
    when(() => storage.storeFailedPinAttempts(any())).thenAnswer((inv) async {
      failed = inv.positionalArguments.first as int;
    });
    when(() => storage.storePinCooldownUntil(any())).thenAnswer((inv) async {
      until = inv.positionalArguments.first as DateTime;
    });
    when(() => storage.clearPinLockout()).thenAnswer((_) async {
      failed = 0;
      until = null;
    });
    when(
      () => storage.verifyPin(any()),
    ).thenAnswer((inv) async => inv.positionalArguments.first == correctPin);
  });

  group('the ladder', () {
    test('five failures are free of a cooldown only up to the fourth', () {
      expect(pinCooldownAfter(1), isNull);
      expect(pinCooldownAfter(4), isNull);
      expect(pinCooldownAfter(5), const Duration(seconds: 30));
    });

    test('every failure past the threshold arms a cooldown, one tier per '
        'further block of five, stopping at the last', () {
      expect(pinCooldownAfter(9), const Duration(seconds: 30));
      expect(pinCooldownAfter(10), const Duration(seconds: 60));
      expect(pinCooldownAfter(15), const Duration(minutes: 5));
      expect(pinCooldownAfter(20), const Duration(minutes: 15));
      expect(pinCooldownAfter(25), const Duration(minutes: 30));
      expect(pinCooldownAfter(10000), const Duration(minutes: 30));
    });
  });

  group('verify', () {
    test('counts a wrong PIN in the store, not in the verifier', () async {
      final result = await verifier.verify(wrongPin);

      expect(result, isA<PinRejected>());
      expect((result as PinRejected).failedAttempts, 1);
      expect(result.cooldownUntil, isNull);
      expect(failed, 1);

      // A fresh instance is a reopened surface. It must inherit the count.
      final next = await PinAttemptVerifier(storage).verify(wrongPin);
      expect((next as PinRejected).failedAttempts, 2);
    });

    test('the fifth failure arms the first tier in the store', () async {
      failed = 4;

      final result = await verifier.verify(wrongPin) as PinRejected;

      expect(result.failedAttempts, 5);
      expect(result.cooldownUntil, isNotNull);
      expect(until, result.cooldownUntil);
      final left = until!.difference(DateTime.now()).inSeconds;
      expect(left, inInclusiveRange(28, 30));
    });

    test('during a cooldown even the correct PIN is neither checked nor '
        'counted', () async {
      failed = 5;
      until = DateTime.now().add(const Duration(seconds: 30));

      final result = await verifier.verify(correctPin);

      expect(result, isA<PinCoolingDown>());
      verifyNever(() => storage.verifyPin(any()));
      expect(failed, 5);
    });

    test('an elapsed cooldown lets the attempt through, and the counter it '
        'left behind picks the next tier', () async {
      failed = 9;
      until = DateTime.now().subtract(const Duration(seconds: 1));

      final result = await verifier.verify(wrongPin) as PinRejected;

      expect(result.failedAttempts, 10);
      final left = result.cooldownUntil!.difference(DateTime.now()).inSeconds;
      expect(left, inInclusiveRange(58, 60));
    });

    test('a correct PIN clears the lockout', () async {
      failed = 3;

      expect(await verifier.verify(correctPin), isA<PinVerified>());

      expect(failed, 0);
    });

    test('a counter that cannot be read refuses without checking the PIN, so a '
        'broken store is not an unthrottled oracle', () async {
      when(() => storage.loadFailedPinAttempts()).thenThrow(StateError('down'));

      expect(await verifier.verify(correctPin), isA<PinCheckUnavailable>());

      verifyNever(() => storage.verifyPin(any()));
    });

    test('a cooldown that cannot be read refuses the same way', () async {
      when(() => storage.loadPinCooldownUntil()).thenThrow(StateError('down'));

      expect(await verifier.verify(correctPin), isA<PinCheckUnavailable>());

      verifyNever(() => storage.verifyPin(any()));
    });

    test('an attempt that cannot be counted is not evaluated', () async {
      when(
        () => storage.storeFailedPinAttempts(any()),
      ).thenThrow(StateError('refused'));

      expect(await verifier.verify(correctPin), isA<PinCheckUnavailable>());

      verifyNever(() => storage.verifyPin(any()));
    });

    test('an unreadable PIN hash refuses and takes the count back', () async {
      failed = 2;
      when(() => storage.verifyPin(any())).thenThrow(StateError('vault down'));

      expect(await verifier.verify(correctPin), isA<PinCheckUnavailable>());

      expect(failed, 2);
    });
  });

  group('a deadline further ahead than the ladder can arm', () {
    final farAhead = DateTime.utc(2040);

    void expectAboutTopTierAhead(DateTime deadline) {
      final left = deadline.difference(DateTime.now()).inSeconds;
      expect(left, inInclusiveRange(1790, 1800));
    }

    setUp(() {
      failed = 5;
      until = farAhead;
    });

    test(
      'verify refuses, but for the top tier rather than until 2040',
      () async {
        final result = await verifier.verify(correctPin) as PinCoolingDown;

        expectAboutTopTierAhead(result.until);
        expectAboutTopTierAhead(until!);
        verifyNever(() => storage.verifyPin(any()));
        expect(failed, 5);
      },
    );

    test('verifyForUnlock does the same', () async {
      final result =
          await verifier.verifyForUnlock(correctPin, knownFailedAttempts: 0)
              as PinCoolingDown;

      expectAboutTopTierAhead(result.until);
      expectAboutTopTierAhead(until!);
      verifyNever(() => storage.verifyPin(any()));
    });

    test('activeCooldown does the same', () async {
      expectAboutTopTierAhead((await verifier.activeCooldown())!);
      expectAboutTopTierAhead(until!);
    });

    test('the pull-back happens once, so the cooldown runs out instead of '
        'rolling forward', () async {
      final first = await verifier.activeCooldown();
      final second = await verifier.activeCooldown();

      expect(second, first);
      verify(() => storage.storePinCooldownUntil(any())).called(1);
    });

    test('a store refusing the rewrite still refuses the attempt', () async {
      when(
        () => storage.storePinCooldownUntil(any()),
      ).thenThrow(StateError('refused'));

      final result = await verifier.verify(correctPin) as PinCoolingDown;

      expectAboutTopTierAhead(result.until);
      verifyNever(() => storage.verifyPin(any()));
    });

    test('a deadline the ladder could have armed is left alone', () async {
      final armed = DateTime.now().add(const Duration(minutes: 29));
      until = armed;

      expect(await verifier.activeCooldown(), armed);

      verifyNever(() => storage.storePinCooldownUntil(any()));
    });
  });

  group('verifyForUnlock', () {
    test('climbs from the store when it is ahead of the caller', () async {
      failed = 4;

      final result =
          await verifier.verifyForUnlock(wrongPin, knownFailedAttempts: 0)
              as PinRejected;

      expect(result.failedAttempts, 5);
      expect(result.cooldownUntil, isNotNull);
    });

    test('climbs from the caller when the store lost the count', () async {
      final result =
          await verifier.verifyForUnlock(wrongPin, knownFailedAttempts: 9)
              as PinRejected;

      expect(result.failedAttempts, 10);
      expect(failed, 10);
    });

    test('honours a cooldown a re-auth prompt armed', () async {
      failed = 5;
      until = DateTime.now().add(const Duration(minutes: 1));

      final result = await verifier.verifyForUnlock(
        correctPin,
        knownFailedAttempts: 0,
      );

      expect(result, isA<PinCoolingDown>());
      verifyNever(() => storage.verifyPin(any()));
    });

    test(
      'a store refusing the bookkeeping does not stop a correct PIN',
      () async {
        when(
          () => storage.loadFailedPinAttempts(),
        ).thenThrow(StateError('down'));
        when(
          () => storage.loadPinCooldownUntil(),
        ).thenThrow(StateError('down'));
        when(() => storage.clearPinLockout()).thenThrow(StateError('refused'));

        expect(
          await verifier.verifyForUnlock(correctPin, knownFailedAttempts: 0),
          isA<PinVerified>(),
        );
      },
    );

    test(
      'a refused counter write still answers with the climbed count',
      () async {
        when(
          () => storage.storeFailedPinAttempts(any()),
        ).thenThrow(StateError('refused'));

        final result =
            await verifier.verifyForUnlock(wrongPin, knownFailedAttempts: 4)
                as PinRejected;

        expect(result.failedAttempts, 5);
        expect(result.cooldownUntil, isNotNull);
      },
    );
  });

  test('one verifier is the only caller of the raw PIN check', () {
    // A direct call is a free oracle for the PIN: it spends no attempts. Adding
    // a surface that checks the PIN means going through [PinAttemptVerifier].
    final callers = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart') ||
          entity.path.endsWith('.freezed.dart') ||
          entity.path.endsWith('.config.dart')) {
        continue;
      }
      final source = entity.readAsStringSync();
      if (RegExp(r'\.verifyPin\(').hasMatch(source)) callers.add(entity.path);
    }
    expect(callers, ['lib/core/security/pin_attempt_verifier.dart']);
  });
}
