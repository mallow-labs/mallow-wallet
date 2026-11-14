import 'dart:math' as math;

import '../observability/app_logger.dart';
import 'secure_storage.dart';

/// Wrong PINs tolerated before the cooldown ladder starts.
const int kMaxFailedPinAttempts = 5;

/// The cooldown ladder. Every failure from [kMaxFailedPinAttempts] on arms a
/// cooldown, and each further [kMaxFailedPinAttempts] failures move it up a
/// tier, stopping at the last.
const List<Duration> kPinCooldownTiers = [
  Duration(seconds: 30),
  Duration(seconds: 60),
  Duration(minutes: 5),
  Duration(minutes: 15),
  Duration(minutes: 30),
];

/// How long the [failedAttempts]th consecutive failure locks PIN entry for, or
/// null when it is still below the threshold.
Duration? pinCooldownAfter(int failedAttempts) {
  if (failedAttempts < kMaxFailedPinAttempts) return null;
  final round =
      (failedAttempts - kMaxFailedPinAttempts) ~/ kMaxFailedPinAttempts;
  return kPinCooldownTiers[round.clamp(0, kPinCooldownTiers.length - 1)];
}

/// The one way the app words an active cooldown, on every PIN surface.
String pinCooldownMessage(DateTime cooldownUntil) {
  final remaining = cooldownUntil.difference(DateTime.now());
  if (remaining.isNegative) return 'You can try again now.';

  if (remaining.inMinutes >= 1) {
    final mins = remaining.inMinutes;
    final secs = remaining.inSeconds % 60;
    return 'Too many failed attempts.\nTry again in ${mins}m ${secs}s.';
  }
  return 'Too many failed attempts.\nTry again in ${remaining.inSeconds}s.';
}

/// What became of one PIN attempt.
sealed class PinAttemptResult {
  const PinAttemptResult();
}

/// The PIN is correct. The lockout has been cleared.
class PinVerified extends PinAttemptResult {
  const PinVerified();
}

/// The PIN is wrong, and the failure has been counted.
class PinRejected extends PinAttemptResult {
  const PinRejected({required this.failedAttempts, this.cooldownUntil});

  final int failedAttempts;

  /// Set when this failure armed a cooldown.
  final DateTime? cooldownUntil;
}

/// A cooldown is running, so the PIN was neither checked nor counted.
class PinCoolingDown extends PinAttemptResult {
  const PinCoolingDown({required this.failedAttempts, required this.until});

  final int failedAttempts;
  final DateTime until;
}

/// The store could not answer. The PIN is not verified, but a broken store is
/// no evidence against the user, so nothing was counted either.
class PinCheckUnavailable extends PinAttemptResult {
  const PinCheckUnavailable();
}

/// Every check of the app PIN goes through here, so that all of them spend one
/// attempt budget.
///
/// The PIN is six digits, and the hash check itself has no memory. A surface
/// that called [SecureWalletStorage.verifyPin] directly would be a free oracle
/// for the same PIN the lock screen protects: anyone holding the unlocked app
/// could reopen it and keep guessing, and a correct guess reaches the recovery
/// phrases. The counter and the deadline therefore live in the store and are
/// read on every attempt. A count held by one screen would reset when that
/// screen is reopened.
///
/// Holds no state, so it is safe to construct per use.
class PinAttemptVerifier {
  const PinAttemptVerifier(this._storage);

  static const _tag = 'PinAttemptVerifier';

  final SecureWalletStorage _storage;

  /// The cooldown running now, if any, for a surface to show before the user
  /// types. Display only: [verify] and [verifyForUnlock] enforce it themselves.
  Future<DateTime?> activeCooldown() async {
    try {
      return await _activeBounded(await _storage.loadPinCooldownUntil());
    } catch (e) {
      AppLogger.error(_tag, 'could not read the PIN cooldown', e);
      return null;
    }
  }

  /// [until], pulled back to the top tier from now if it lies further ahead,
  /// and the store corrected to match.
  ///
  /// The ladder never arms more than the top tier, so a deadline beyond it can
  /// only come from a clock that has since moved back: set forward before the
  /// failures and restored after, or simply wrong at the time. Honoured as
  /// written, it would freeze the pad for as long as the clock was off, on the
  /// lock screen and on the prompts guarding Show secrets and Reset app alike,
  /// and nothing would tell the owner that moving the clock is the way out.
  /// Rewriting it keeps a real cooldown running, and only once: the next read
  /// finds it within bounds, so it runs out rather than rolling forward.
  Future<DateTime> boundCooldown(DateTime until) async {
    final latest = DateTime.now().add(kPinCooldownTiers.last);
    if (!until.isAfter(latest)) return until;
    await _bestEffort(
      'pull back the PIN cooldown',
      () => _storage.storePinCooldownUntil(latest),
    );
    return latest;
  }

  /// Check [pin] on a surface behind an unlocked session: a re-auth prompt, the
  /// signing fallback, the Change PIN step.
  ///
  /// Fails closed. Refusing here costs the user a retry, and the lock screen
  /// remains their way back in. So an attempt that cannot be counted is not
  /// evaluated, and the count is written before the hash is checked: a store
  /// that refuses writes must not turn into unlimited guesses.
  Future<PinAttemptResult> verify(String pin) async {
    final int failed;
    final DateTime? cooldown;
    try {
      failed = await _storage.loadFailedPinAttempts();
      cooldown = await _activeBounded(await _storage.loadPinCooldownUntil());
    } catch (e) {
      AppLogger.error(_tag, 'could not read the PIN lockout', e);
      return const PinCheckUnavailable();
    }
    if (cooldown != null) {
      return PinCoolingDown(failedAttempts: failed, until: cooldown);
    }

    final attempt = failed + 1;
    try {
      await _storage.storeFailedPinAttempts(attempt);
    } catch (e) {
      AppLogger.error(_tag, 'could not count the PIN attempt', e);
      return const PinCheckUnavailable();
    }

    final bool verified;
    try {
      verified = await _storage.verifyPin(pin);
    } catch (e) {
      AppLogger.error(_tag, 'could not read the stored PIN', e);
      await _bestEffort(
        'take back the uncounted PIN attempt',
        () => _storage.storeFailedPinAttempts(failed),
      );
      return const PinCheckUnavailable();
    }
    if (verified) {
      await _bestEffort('clear the PIN lockout', _storage.clearPinLockout);
      return const PinVerified();
    }
    return PinRejected(
      failedAttempts: attempt,
      cooldownUntil: await _armCooldown(attempt),
    );
  }

  /// Check [pin] on the lock screen.
  ///
  /// The same counter and ladder as [verify], but the bookkeeping is
  /// best-effort: this is the one surface with nothing behind it, so a refused
  /// counter read or write must not stop a correct PIN from opening the app.
  /// [knownFailedAttempts] is the caller's in-memory count, which keeps the
  /// ladder climbing through a session whose store refuses the counter.
  Future<PinAttemptResult> verifyForUnlock(
    String pin, {
    required int knownFailedAttempts,
  }) async {
    final persisted = await _bestEffortRead(
      'read the failed-PIN counter',
      _storage.loadFailedPinAttempts,
      0,
    );
    final failed = math.max(persisted, knownFailedAttempts);
    final cooldown = await _activeBounded(
      await _bestEffortRead<DateTime?>(
        'read the PIN cooldown',
        _storage.loadPinCooldownUntil,
        null,
      ),
    );
    if (cooldown != null) {
      return PinCoolingDown(failedAttempts: failed, until: cooldown);
    }

    final bool verified;
    try {
      verified = await _storage.verifyPin(pin);
    } catch (e) {
      AppLogger.error(_tag, 'could not read the stored PIN', e);
      return const PinCheckUnavailable();
    }
    if (verified) {
      await _bestEffort('clear the PIN lockout', _storage.clearPinLockout);
      return const PinVerified();
    }

    final attempt = failed + 1;
    await _bestEffort(
      'store the failed-PIN counter',
      () => _storage.storeFailedPinAttempts(attempt),
    );
    return PinRejected(
      failedAttempts: attempt,
      cooldownUntil: await _armCooldown(attempt),
    );
  }

  Future<DateTime?> _activeBounded(DateTime? until) async =>
      until != null && until.isAfter(DateTime.now())
      ? boundCooldown(until)
      : null;

  /// Persist the cooldown [failedAttempts] earned, if any. Best-effort: the
  /// deadline is still returned, so the surface in front of the user enforces
  /// it for as long as it stays open.
  Future<DateTime?> _armCooldown(int failedAttempts) async {
    final cooldown = pinCooldownAfter(failedAttempts);
    if (cooldown == null) return null;
    final until = DateTime.now().add(cooldown);
    await _bestEffort(
      'store the PIN cooldown',
      () => _storage.storePinCooldownUntil(until),
    );
    return until;
  }

  Future<void> _bestEffort(String what, Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      AppLogger.error(_tag, 'could not $what', e);
    }
  }

  Future<T> _bestEffortRead<T>(
    String what,
    Future<T> Function() read,
    T fallback,
  ) async {
    try {
      return await read();
    } catch (e) {
      AppLogger.error(_tag, 'could not $what', e);
      return fallback;
    }
  }
}
