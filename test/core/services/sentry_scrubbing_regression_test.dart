import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/observability/sentry_privacy_transport.dart';
import 'package:mallow_wallet/core/services/sentry_service.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Wire-level regressions for the diagnostic scrubber: ordinary diagnostics
/// must reach the transport intact, and secrets must not, including when they
/// sit under frame and image fields that are otherwise preserved.
class _RecordingTransport implements Transport {
  final envelopes = <SentryEnvelope>[];
  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    envelopes.add(envelope);
    return envelope.header.eventId;
  }
}

// Public BIP39 test vector and synthetic key material only.
const _mnemonic =
    'legal winner thank year wave sausage worth useful legal winner thank '
    'yellow';
final _hexKey = List.filled(64, 'b').join();
const _evmAddress = '0x742d35Cc6634C0532925a3b844Bc454e4438f44e';

const _typeError = "type 'Null' is not a subtype of type 'String' in type cast";
const _dartPath = 'package:mallow_wallet/core/security/secret_scrubber.dart';
const _screenPath =
    'package:mallow_wallet/features/portfolio/screens/portfolio_screen.dart';
const _iosCodeFile =
    '/private/var/containers/Bundle/Application/'
    '1A2B3C4D-5E6F-4A8B-9C0D-1E2F3A4B5C6D/Runner.app/Frameworks/'
    'App.framework/App';
const _debugId = 'b680cb89-f9e3-c12a-24b1-72d51dec73a9';
const _codeId = 'b680cb89f9e3c12a24b172d51dec73a9c4e5f6a7';

Future<(_RecordingTransport, Hub)> _hub() async {
  final recorded = _RecordingTransport();
  final options = SentryFlutterOptions()
    ..dsn = 'https://public@example.test/1'
    ..beforeSend = SentryService.beforeSend
    ..transport = recorded;
  final hub = Hub(options);
  SentryPrivacyIntegration().call(hub, options);
  return (recorded, hub);
}

Future<String> _wire(_RecordingTransport recorded) async {
  expect(recorded.envelopes, hasLength(1));
  final item = recorded.envelopes.single.items.single;
  return utf8.decode(await item.dataFactory());
}

void main() {
  test('messages containing % reach the transport unchanged', () async {
    for (final message in [
      'upload progress 50%',
      'probe https://example.test/%2F → fallback',
      'bad escape %zz and trailing %',
    ]) {
      final (recorded, hub) = await _hub();
      await hub.captureMessage(message);
      final event = jsonDecode(await _wire(recorded)) as Map<String, dynamic>;
      expect((event['message'] as Map<String, dynamic>)['formatted'], message);
    }
  });

  test('TypeError text, stack paths and native images survive', () async {
    final (recorded, hub) = await _hub();
    await hub.captureEvent(
      SentryEvent(
        exceptions: [
          SentryException(
            type: '_TypeError',
            value: _typeError,
            stackTrace: SentryStackTrace(
              frames: [
                SentryStackFrame(
                  absPath: _screenPath,
                  fileName: 'portfolio_screen.dart',
                  function: '_PortfolioScreenState._load',
                  package: 'mallow_wallet',
                  lineNo: 88,
                  colNo: 12,
                  inApp: true,
                ),
                SentryStackFrame(
                  absPath: _dartPath,
                  fileName: 'secret_scrubber.dart',
                  function: 'SecretScrubber.scrubString',
                  package: 'mallow_wallet',
                  lineNo: 90,
                  colNo: 7,
                  inApp: true,
                ),
              ],
            ),
          ),
        ],
        debugMeta: DebugMeta(
          images: [
            DebugImage(
              type: 'macho',
              codeFile: _iosCodeFile,
              debugId: _debugId,
              codeId: _codeId,
              imageAddr: '0x0000000104a5b000',
            ),
          ],
        ),
      ),
    );
    final wire = await _wire(recorded);
    for (final kept in [
      _typeError,
      _dartPath,
      _screenPath,
      '_PortfolioScreenState._load',
      _iosCodeFile,
      _debugId,
      _codeId,
      '0x0000000104a5b000',
    ]) {
      expect(wire, contains(jsonEncode(kept)), reason: kept);
    }
    expect(wire.contains('REDACTED'), isFalse);
  });

  test('secrets under preserved frame and image fields are removed', () async {
    final (recorded, hub) = await _hub();
    await hub.captureEvent(
      SentryEvent(
        message: SentryMessage('import failed near $_evmAddress'),
        exceptions: [
          SentryException(
            type: 'FormatException',
            value: Uri.encodeComponent('rejected $_mnemonic'),
            stackTrace: SentryStackTrace(
              frames: [
                SentryStackFrame(
                  absPath: 'package:$_hexKey.dart',
                  fileName: '${_mnemonic.replaceAll(' ', '_')}.dart',
                  function: _mnemonic,
                  module: 'mallow_$_hexKey',
                ),
              ],
            ),
          ),
        ],
        debugMeta: DebugMeta(
          images: [
            DebugImage(
              type: 'macho',
              codeFile: 'lib/$_hexKey/App',
              debugId: _hexKey,
              codeId: _evmAddress,
            ),
          ],
        ),
      ),
    );
    final wire = await _wire(recorded);
    expect(wire.contains(_hexKey), isFalse);
    expect(wire.contains(_evmAddress), isFalse);
    expect(wire.contains('winner'), isFalse);
    expect(wire.contains('sausage'), isFalse);
    expect(wire, contains('import failed near [REDACTED_ADDRESS]'));
  });
}
