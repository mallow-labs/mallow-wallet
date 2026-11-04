import 'package:flutter/foundation.dart';

import '../security/secret_scrubber.dart';

/// Thin logging facade for security-sensitive modules.
///
/// SECURITY: `debugPrint` is NOT a no-op in release — output still reaches
/// `logcat` (Android) and `OSLog` (iOS). Any process holding `READ_LOGS` on
/// Android (root, OEM bloatware) can read those lines. `AppLogger` drops
/// non-error events in release builds so wallet identifiers, addresses, JWTs,
/// are omitted from routine release logs. Error messages are filtered below.
///
/// Use this everywhere in `core/crypto`, `core/security`, and
/// `core/network/auth_service.dart`. Errors are still emitted in release so
/// crash diagnosis remains possible. Messages are scrubbed and error objects
/// contribute only their type. Callers must still avoid supplying secrets.
class AppLogger {
  const AppLogger._();

  /// Debug-level log. Dropped entirely in release builds.
  ///
  /// Use for routine flow tracing (e.g. "switching wallet", "cache hit").
  /// Safe to include wallet IDs / addresses because nothing reaches the
  /// platform log pipe in release.
  static void debug(String tag, String message) {
    if (!kDebugMode) return;
    debugPrint(SecretScrubber.scrubString('[$tag] $message'));
  }

  /// Info-level log. Dropped in release.
  ///
  /// Use for milestone events that are useful while developing but not in
  /// production logs.
  static void info(String tag, String message) {
    if (!kDebugMode) return;
    debugPrint(SecretScrubber.scrubString('[$tag] $message'));
  }

  /// Warning-level log. Dropped in release.
  ///
  /// Use for recoverable-but-suspicious situations (e.g. expired JWT, retry).
  /// Same release-drop policy as [debug] — promote to [error] if the event
  /// must survive in production.
  static void warn(String tag, String message) {
    if (!kDebugMode) return;
    debugPrint(SecretScrubber.scrubString('[$tag] $message'));
  }

  /// Error-level log. Emitted in both debug AND release.
  ///
  /// Use ONLY for genuine failures that need to surface in production
  /// diagnostics. Callers MUST NOT pass wallet IDs, addresses, mnemonics,
  /// private keys, JWTs, or any other identifier verbatim — pass a scrubbed
  /// description. Pattern filtering is defense in depth, not permission to
  /// log secrets.
  ///
  /// [stackTrace] is printed in debug builds only, reduced to recognised
  /// frames (member and source location) with each frame scrubbed. Release
  /// builds log the message and the error's type, never a stack.
  static void error(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    // Never invoke an arbitrary exception's toString: it may embed input.
    final suffix = error == null ? '' : ': ${error.runtimeType}';
    final line = SecretScrubber.scrubString('[$tag] $message$suffix');
    if (!kDebugMode || stackTrace == null) {
      debugPrint(line);
      return;
    }
    debugPrint([line, ..._stackFrames(stackTrace)].join('\n'));
  }

  static const _maxStackFrames = 30;

  // `#3      Foo.bar (package:app/foo.dart:12:5)`, the VM's frame format.
  static final _vmFrame = RegExp(
    r'^#\d+\s+(\S.*?)\s+\(([^()\s]+:\d+(?::\d+)?)\)$',
  );

  // `package:app/foo.dart 12:5  Foo.bar`, package:stack_trace's terse format.
  static final _terseFrame = RegExp(r'^(\S+:\S+) (\d+(?::\d+)?)\s+(\S.*)$');

  /// Keeps only lines shaped like a stack frame. A trace built with
  /// `StackTrace.fromString`, or a custom [StackTrace], can carry arbitrary
  /// text, so everything else is counted, not printed.
  static List<String> _stackFrames(StackTrace stackTrace) {
    final String raw;
    try {
      raw = stackTrace.toString();
    } catch (_) {
      return const ['  (stack trace unavailable)'];
    }
    final frames = <String>[];
    var omitted = 0;
    for (final rawLine in raw.split('\n')) {
      final text = rawLine.trim();
      if (text.isEmpty) continue;
      final String? frame;
      if (text == '<asynchronous suspension>') {
        frame = text;
      } else if (_vmFrame.firstMatch(text) case final m?) {
        frame = '${m[1]} (${m[2]})';
      } else if (_terseFrame.firstMatch(text) case final m?) {
        frame = '${m[3]} (${m[1]}:${m[2]})';
      } else {
        frame = null;
      }
      if (frame == null || frames.length >= _maxStackFrames) {
        omitted++;
        continue;
      }
      // Scrub per frame so a match can never span two frames.
      frames.add('  ${SecretScrubber.scrubString(frame)}');
    }
    if (omitted > 0) frames.add('  ($omitted more lines omitted)');
    return frames;
  }
}
