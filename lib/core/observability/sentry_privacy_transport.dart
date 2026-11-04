import 'dart:convert';

import 'package:sentry_flutter/sentry_flutter.dart';
// The public envelope API exposes this type but the SDK does not export it.
// Rebuild the header to omit trace baggage added after beforeSend.
// ignore: implementation_imports
import 'package:sentry/src/sentry_envelope_header.dart';
// The item header is likewise exposed only through an internal import.
// ignore: implementation_imports
import 'package:sentry/src/sentry_envelope_item_header.dart';

import '../security/secret_scrubber.dart';

/// Last boundary before the SDK writes an envelope to disk or the network.
/// Scope attachments and trace baggage are added after beforeSend; filtering
/// only events cannot cover those channels.
class SentryPrivacyTransport implements Transport {
  SentryPrivacyTransport(this._delegate);

  final Transport _delegate;

  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    final items = <SentryEnvelopeItem>[];
    try {
      for (final item in envelope.items) {
        // No binary attachments, profiles, replay, or independent log payloads.
        if (!const {
          'event',
          'transaction',
          'client_report',
        }.contains(item.header.type)) {
          continue;
        }
        // Scrub arbitrary context/span objects before JSON serialization can
        // invoke their toJson methods. Encoded SDK items get the same policy.
        final source = item.originalObject;
        final decoded = source is SentryEvent
            ? source.toJson()
            : jsonDecode(utf8.decode(await item.dataFactory()));
        if (decoded is! Map<String, dynamic>) return null;
        final clean = SecretScrubber.scrubMap(decoded);
        final bytes = utf8.encode(jsonEncode(clean));
        items.add(
          SentryEnvelopeItem(
            SentryEnvelopeItemHeader(
              item.header.type,
              contentType: 'application/json',
            ),
            () => bytes,
          ),
        );
      }
    } catch (_) {
      // Never forward the original on a parsing/scrubbing failure.
      return null;
    }
    if (items.isEmpty) return null;
    return _delegate.send(
      SentryEnvelope(
        SentryEnvelopeHeader(
          envelope.header.eventId,
          envelope.header.sdkVersion,
          dsn: envelope.header.dsn,
          sentAt: envelope.header.sentAt,
        ),
        items,
        containsUnhandledException: envelope.containsUnhandledException,
      ),
    );
  }
}

/// Installed after client creation, so the native or HTTP transport is already
/// selected. This preserves the SDK's platform-specific delivery and caching.
class SentryPrivacyIntegration implements Integration<SentryFlutterOptions> {
  @override
  void call(Hub hub, SentryFlutterOptions options) {
    options.transport = SentryPrivacyTransport(options.transport);
  }

  @override
  void close() {}
}
