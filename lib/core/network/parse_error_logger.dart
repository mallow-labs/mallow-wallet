import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:retrofit/error_logger.dart';

import '../observability/app_logger.dart';
import '../services/sentry_service.dart';

/// Surfaces `json_serializable`/freezed parse failures from retrofit-generated
/// clients. Without this, a single malformed item silently rejects the whole
/// response and callers see an opaque future error ("Failed to load …") with no
/// hint at which field broke.
///
/// Logs in ALL build modes: a 2xx response we can't parse is exactly when we
/// most need the detail, and that often only reproduces on profile/TestFlight
/// builds where `debugPrint` alone is invisible. The endpoint and the error
/// (the Dart type error names the failing field's type, e.g. `'Null' is not a
/// subtype of 'num'`) go to the console AND to Sentry. The raw payload is
/// dumped to the console in debug only — it can carry wallet addresses and
/// usernames, which must never reach analytics/error tracking (security rule).
class NetworkParseErrorLogger implements ParseErrorLogger {
  const NetworkParseErrorLogger();

  static const _payloadLimit = 4000;

  @override
  void logError(
    Object error,
    StackTrace stackTrace,
    RequestOptions options, {
    Response<dynamic>? response,
  }) {
    final method = options.method.toUpperCase();
    // Path only — the query string can contain wallet addresses.
    final endpoint = '$method ${options.uri.path}';

    // Emitted in debug AND release so production parse failures are diagnosable.
    AppLogger.error('Network', 'Parse failure: $endpoint', error);

    // Capture the exception + stack for production triage. The payload is NOT
    // attached — it can contain addresses/usernames; the type error and stack
    // are enough to pinpoint the field, and Sentry never sees on-chain data.
    unawaited(
      SentryService.captureException(
        error,
        stackTrace: stackTrace,
        message: 'Parse failure: $endpoint',
      ),
    );

    // Debug console only: dump the truncated payload so the offending field /
    // key is identifiable locally.
    if (kDebugMode) {
      debugPrint('✗ Parse failure: $endpoint');
      debugPrint('  Error: $error');
      if (response?.data != null) {
        debugPrint('  Payload: ${_preview(response!.data)}');
      }
      debugPrintStack(stackTrace: stackTrace, label: 'parse-error');
    }
  }

  String _preview(dynamic data) {
    String raw;
    try {
      raw = data is String ? data : jsonEncode(data);
    } catch (_) {
      raw = data.toString();
    }
    return raw.length > _payloadLimit
        ? '${raw.substring(0, _payloadLimit)}…(${raw.length - _payloadLimit} more)'
        : raw;
  }
}
