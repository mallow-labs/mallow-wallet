import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Pretty HTTP logging interceptor for development.
///
/// Logs:
/// - All requests: method, path, and a compact (truncated) body
/// - Success responses: status code, path, timing, and a result-count
///   summary — a 200 with zero results must be distinguishable from a 200
///   with a full page, or a wrong-but-accepted request (bad filter value,
///   wrong casing) is invisible in the logs
/// - Error responses: status code + full request/response bodies
///
/// Only active in debug mode.
class PrettyLoggingInterceptor extends Interceptor {
  PrettyLoggingInterceptor({this.showRequestBody = false});

  /// Whether to pretty-print full request bodies (compact one-liners are
  /// always logged; this expands them to indented multi-line JSON).
  final bool showRequestBody;

  final _stopwatches = <String, Stopwatch>{};

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!kDebugMode) {
      handler.next(options);
      return;
    }

    final requestId = _generateRequestId(options);
    _stopwatches[requestId] = Stopwatch()..start();

    final method = options.method.toUpperCase();
    final path = _formatPath(options);

    debugPrint('→ $method $path');

    // Request bodies are opt-in only. The main API Dio carries challenge
    // signatures (POST /v0/authToken/verify) and serialized signed
    // transactions (v1/v2 tx-relay), so bodies must stay off by default even
    // in debug — leaving them out of device logs unless explicitly enabled.
    if (showRequestBody && options.data != null) {
      debugPrint('  Body: ${_formatBody(options.data)}');
    }

    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    if (!kDebugMode) {
      handler.next(response);
      return;
    }

    final requestId = _generateRequestId(response.requestOptions);
    final elapsed = _stopwatches.remove(requestId)?.elapsedMilliseconds ?? 0;

    final status = response.statusCode;
    final statusText = _getStatusText(status);
    final path = _formatPath(response.requestOptions);
    final summary = _summarizeResponse(response.data);

    debugPrint(
      '← $status $statusText $path (${elapsed}ms)'
      '${summary == null ? '' : ' · $summary'}',
    );

    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (!kDebugMode) {
      handler.next(err);
      return;
    }

    final requestId = _generateRequestId(err.requestOptions);
    final elapsed = _stopwatches.remove(requestId)?.elapsedMilliseconds ?? 0;

    final status = err.response?.statusCode ?? 0;
    final statusText = _getStatusText(status);

    debugPrint(
      '← $status $statusText ${_formatPath(err.requestOptions)} (${elapsed}ms)',
    );

    // Log request body for POST errors to aid debugging
    if (err.requestOptions.method.toUpperCase() == 'POST' &&
        err.requestOptions.data != null) {
      debugPrint('  Request body: ${_formatBody(err.requestOptions.data)}');
    }

    // Log full response body for errors
    if (err.response?.data != null) {
      debugPrint('  Response: ${_formatBody(err.response?.data)}');
    } else if (err.message != null) {
      debugPrint('  Error: ${err.message}');
    }

    handler.next(err);
  }

  String _generateRequestId(RequestOptions options) {
    return '${options.method}:${options.uri}:${options.hashCode}';
  }

  String _formatPath(RequestOptions options) {
    final uri = options.uri;

    // For relative URLs (same base), show just path + query
    if (uri.host.isEmpty || uri.toString().startsWith(options.baseUrl)) {
      final pathWithQuery = uri.query.isNotEmpty
          ? '${uri.path}?${uri.query}'
          : uri.path;
      return pathWithQuery.isEmpty ? '/' : pathWithQuery;
    }

    // For different hosts (e.g., Helius), show full URL but redact API keys
    var fullUrl = uri.toString();
    fullUrl = fullUrl.replaceAll(RegExp(r'api-key=[^&]+'), 'api-key=***');
    fullUrl = fullUrl.replaceAll(RegExp(r'apiKey=[^&]+'), 'apiKey=***');
    return fullUrl;
  }

  /// Compact summary of a success payload so an empty-but-200 response is
  /// distinguishable from a full one. Recognizes the standard
  /// `{result: [...]}` envelope and bare list bodies.
  String? _summarizeResponse(dynamic data) {
    if (data is Map && data['result'] is List) {
      final count = (data['result'] as List).length;
      final total = data['total'];
      return total is num ? '$count results (total $total)' : '$count results';
    }
    if (data is List) return '${data.length} items';
    return null;
  }

  String _formatBody(dynamic data) {
    if (data == null) return 'null';

    final safe = _redactSensitive(data);
    try {
      if (safe is Map || safe is List) {
        const encoder = JsonEncoder.withIndent('  ');
        return encoder.convert(safe);
      }
      return safe.toString();
    } catch (e) {
      return safe.toString();
    }
  }

  /// Keys whose values are signing material — never log their contents.
  static const _sensitiveKeys = {
    'signature',
    'signedTransaction',
    'transaction',
  };

  /// Recursively replaces sensitive values with a redaction marker so signed
  /// payloads never reach the log even when bodies are explicitly enabled.
  dynamic _redactSensitive(dynamic data) {
    if (data is Map) {
      return {
        for (final entry in data.entries)
          entry.key: _sensitiveKeys.contains(entry.key)
              ? '***redacted***'
              : _redactSensitive(entry.value),
      };
    }
    if (data is List) return data.map(_redactSensitive).toList();
    return data;
  }

  String _getStatusText(int? status) {
    if (status == null) return 'Unknown';

    return switch (status) {
      200 => 'OK',
      201 => 'Created',
      204 => 'No Content',
      400 => 'Bad Request',
      401 => 'Unauthorized',
      403 => 'Forbidden',
      404 => 'Not Found',
      422 => 'Unprocessable Entity',
      429 => 'Too Many Requests',
      500 => 'Internal Server Error',
      502 => 'Bad Gateway',
      503 => 'Service Unavailable',
      _ => 'Status $status',
    };
  }
}
