import 'package:flutter/foundation.dart';

/// A value whose [toString] never reveals what it wraps.
///
/// SECURITY: freezed generates `toString()` on every *concrete* union member
/// and interpolates each field, so an `@override toString()` written in the
/// abstract class body does not take effect. A raw `String` mnemonic or
/// private key sitting in a bloc event/state is therefore one registered
/// `BlocObserver` — or one `print(state)` while debugging — away from a log
/// line, a Sentry breadcrumb, or a crash report.
///
/// Declaring the field as `Redacted<String>` closes that at the type: the
/// generated interpolation prints [_mask] instead of the secret, and every
/// deliberate read has to say `.value` at the call site.
///
/// Equality and hashing delegate to the wrapped value so freezed's generated
/// `==`/`hashCode` (and bloc test expectations) keep working.
@immutable
class Redacted<T> {
  const Redacted(this.value);

  static const _mask = '***';

  /// The secret. Only read this where the value is actually needed.
  final T value;

  @override
  String toString() => _mask;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Redacted<T> && other.value == value);

  @override
  int get hashCode => value.hashCode;
}
