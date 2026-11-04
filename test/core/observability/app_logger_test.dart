import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/observability/app_logger.dart';

class _SensitiveError {
  @override
  String toString() => throw StateError('must never stringify');
}

/// Routes [debugPrint] into a list for the current test only.
List<String> _captureLogs() {
  final messages = <String>[];
  final original = debugPrint;
  addTearDown(() => debugPrint = original);
  debugPrint = (String? message, {int? wrapWidth}) =>
      messages.add(message ?? '');
  return messages;
}

// Kept out of line so its name appears as a frame in the real stack.
@pragma('vm:never-inline')
StackTrace _stackFromNamedHelper() => StackTrace.current;

void main() {
  final originalDebugPrint = debugPrint;

  test('logs only the error type and scrubs text at every level', () {
    final messages = _captureLogs();
    AppLogger.error('test', 'failure', _SensitiveError());
    expect(messages.single, contains('_SensitiveError'));
    final synthetic = List.filled(64, 'a').join();
    AppLogger.debug('test', synthetic);
    AppLogger.info('test', synthetic);
    AppLogger.warn('test', synthetic);
    AppLogger.error(synthetic, synthetic);
    expect(messages.join().contains(synthetic), isFalse);
  });

  test('prints the frames of a real stack in debug builds', () {
    final messages = _captureLogs();
    AppLogger.error(
      'test',
      'failure',
      _SensitiveError(),
      _stackFromNamedHelper(),
    );
    final output = messages.single;
    expect(output, startsWith('[test] failure: _SensitiveError\n'));
    // The checkout's absolute path varies by machine, so assert the member
    // and its line:column rather than the file URI.
    expect(
      output,
      matches(RegExp(r'\n  _stackFromNamedHelper \(\S+\.dart:\d+:\d+\)\n')),
    );
  });

  test('keeps realistic app and SDK locations readable', () {
    final messages = _captureLogs();
    AppLogger.error(
      'test',
      'failure',
      _SensitiveError(),
      StackTrace.fromString(
        '#0      PortfolioScreen._load '
        '(package:mallow_wallet/features/portfolio/screens/portfolio_screen.dart:88:13)\n'
        '<asynchronous suspension>\n'
        '#1      _rootRun (dart:async/zone.dart:1525:13)\n'
        'package:mallow_wallet/core/security/secret_scrubber.dart 42:7  '
        'SecretScrubber.scrubString\n',
      ),
    );
    expect(
      messages.single,
      [
        '[test] failure: _SensitiveError',
        '  PortfolioScreen._load '
            '(package:mallow_wallet/features/portfolio/screens/portfolio_screen.dart:88:13)',
        '  <asynchronous suspension>',
        '  _rootRun (dart:async/zone.dart:1525:13)',
        '  SecretScrubber.scrubString '
            '(package:mallow_wallet/core/security/secret_scrubber.dart:42:7)',
      ].join('\n'),
    );
  });

  test('scrubs secrets in frames and drops lines that are not frames', () {
    final messages = _captureLogs();
    const hexKey =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const phrase =
        'abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon abandon abandon about';
    AppLogger.error(
      'test',
      'failure',
      _SensitiveError(),
      StackTrace.fromString(
        '#0      load (package:app/$hexKey.dart:1:2)\n'
        '#1      $phrase (package:app/a.dart:3:4)\n'
        'password=synthetic-password-value\n'
        '#2      main (package:app/main.dart:5:6)\n',
      ),
    );
    final output = messages.single;
    expect(output, isNot(contains(hexKey)));
    expect(output, isNot(contains('abandon')));
    expect(output, isNot(contains('synthetic-password-value')));
    expect(output, contains('main (package:app/main.dart:5:6)'));
    expect(output, contains('(1 more lines omitted)'));
  });

  test('restores the original debugPrint after each test', () {
    expect(identical(debugPrint, originalDebugPrint), isTrue);
  });
}
