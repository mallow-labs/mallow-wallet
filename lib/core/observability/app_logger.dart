import 'package:flutter/foundation.dart';

/// Thin logging facade for security-sensitive modules.
///
/// SECURITY: `debugPrint` is NOT a no-op in release — output still reaches
/// `logcat` (Android) and `OSLog` (iOS). Any process holding `READ_LOGS` on
/// Android (root, OEM bloatware) can read those lines. `AppLogger` drops
/// non-error events in release builds so wallet identifiers, addresses, JWTs,
/// and other secrets never reach platform logs under normal operation.
///
/// Use this everywhere in `core/crypto`, `core/security`, and
/// `core/network/auth_service.dart`. Errors are still emitted in release so
/// crash diagnosis remains possible — callers MUST scrub identifiers before
/// passing them in.
class AppLogger {
  const AppLogger._();

  /// Debug-level log. Dropped entirely in release builds.
  ///
  /// Use for routine flow tracing (e.g. "switching wallet", "cache hit").
  /// Safe to include wallet IDs / addresses because nothing reaches the
  /// platform log pipe in release.
  static void debug(String tag, String message) {
    if (!kDebugMode) return;
    debugPrint('[$tag] $message');
  }

  /// Info-level log. Dropped in release.
  ///
  /// Use for milestone events that are useful while developing but not in
  /// production logs.
  static void info(String tag, String message) {
    if (!kDebugMode) return;
    debugPrint('[$tag] $message');
  }

  /// Warning-level log. Dropped in release.
  ///
  /// Use for recoverable-but-suspicious situations (e.g. expired JWT, retry).
  /// Same release-drop policy as [debug] — promote to [error] if the event
  /// must survive in production.
  static void warn(String tag, String message) {
    if (!kDebugMode) return;
    debugPrint('[$tag] $message');
  }

  /// Error-level log. Emitted in both debug AND release.
  ///
  /// Use ONLY for genuine failures that need to surface in production
  /// diagnostics. Callers MUST NOT pass wallet IDs, addresses, mnemonics,
  /// private keys, JWTs, or any other identifier verbatim — pass a scrubbed
  /// description or route through Sentry (which does its own scrubbing).
  static void error(String tag, String message, [Object? error]) {
    final suffix = error == null ? '' : ': $error';
    debugPrint('[$tag] $message$suffix');
  }
}
