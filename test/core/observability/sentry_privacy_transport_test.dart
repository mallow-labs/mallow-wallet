import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/observability/sentry_privacy_transport.dart';
import 'package:mallow_wallet/core/services/sentry_service.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

class _RecordingTransport implements Transport {
  final envelopes = <SentryEnvelope>[];
  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    envelopes.add(envelope);
    return envelope.header.eventId;
  }
}

void main() {
  test('drops malformed serialized envelopes before delegation', () async {
    final recorded = _RecordingTransport();
    final transport = SentryPrivacyTransport(recorded);
    final envelope = SentryEnvelope.fromEvent(
      SentryEvent(),
      SdkVersion(name: 'test', version: '1'),
    );
    final header = envelope.items.single.header;
    envelope.items
      ..clear()
      ..add(SentryEnvelopeItem(header, () => utf8.encode('invalid JSON')));
    expect(await transport.send(envelope), isNull);
    expect(recorded.envelopes, isEmpty);
  });

  // Unit-level: a bare Hub with the integration applied by hand. The real
  // SentryFlutter.init path is covered by sentry_service_init_test.dart.
  test(
    'wrapper filters scopes, attachments, and transaction spans on a bare hub',
    () async {
      final recorded = _RecordingTransport();
      final options = SentryFlutterOptions()
        ..dsn = 'https://public@example.test/1'
        ..tracesSampleRate = 1
        ..beforeSend = SentryService.beforeSend
        ..transport = recorded;
      final hub = Hub(options);
      SentryPrivacyIntegration().call(hub, options);
      final synthetic = List.filled(64, 'a').join();
      await hub.configureScope((scope) {
        scope.setContexts('late', {'privateKey': 'short sensitive input'});
        scope.addAttachment(
          SentryAttachment.fromIntList(
            utf8.encode('synthetic attachment'),
            'secret.txt',
            addToTransactions: true,
          ),
        );
      });
      final tracer = hub.startTransaction(synthetic, 'test', bindToScope: true);
      tracer.setData('privateKey', 'short sensitive input');
      final child = tracer.startChild('sign', description: synthetic);
      child.setData('words', [...List.filled(11, 'abandon'), 'about']);
      child.setTag('detail', synthetic);
      child.setData('object', _UnsafeObject());
      await child.finish();
      await hub.captureException(
        StateError('failure'),
        stackTrace: StackTrace.current,
      );
      await tracer.finish();
      expect(recorded.envelopes, hasLength(2));
      for (final envelope in recorded.envelopes) {
        expect(envelope.header.traceContext, isNull);
        expect(
          envelope.items.any((i) => i.header.type == 'attachment'),
          isFalse,
        );
        for (final item in envelope.items) {
          final wire = utf8.decode(await item.dataFactory());
          expect(wire.contains(synthetic), isFalse);
          expect(wire.contains('short sensitive input'), isFalse);
          expect(wire.contains('abandon'), isFalse);
          expect(wire.contains('synthetic attachment'), isFalse);
          if (item.header.type == 'transaction') {
            final json = jsonDecode(wire) as Map<String, dynamic>;
            expect(json['spans'], hasLength(1));
            expect(json['start_timestamp'], isNotNull);
            expect(json['timestamp'], isNotNull);
          }
        }
      }
      await hub.close();
    },
  );
}

class _UnsafeObject {
  Object toJson() => throw StateError('must not serialize');
}
