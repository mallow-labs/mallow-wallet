import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// How long an idle connection stays pooled. `HttpClient` drops one after
/// 15 seconds by default, so a call made after any longer pause paid for a new
/// TCP and TLS handshake: two extra round trips, before its own. One minute
/// sits below the keep-alive timeouts of the servers these clients reach, and
/// above the interval the in-app browser re-warms them at.
const keptAliveIdleTimeout = Duration(seconds: 60);

/// An `HttpClient` that keeps idle connections for [keptAliveIdleTimeout].
HttpClient keptAliveHttpClient() =>
    HttpClient()..idleTimeout = keptAliveIdleTimeout;

/// A Dio whose connections stay pooled for [keptAliveIdleTimeout].
Dio keptAliveDio(BaseOptions options) => Dio(options)
  ..httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: keptAliveHttpClient,
  );

/// Opens [connections] connections to [url]'s host at once, so that many
/// parallel calls find one ready. Any answer will do, error statuses
/// included; a failure is retried once, because the first attempt may only
/// have found a socket the OS closed while the app was away.
Future<void> openConnections(
  Future<void> Function(String url) head,
  String url, {
  int connections = 1,
}) => Future.wait([
  for (var i = 0; i < connections; i++)
    () async {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          await head(url);
          return;
        } catch (_) {
          // Warming is best effort; the review's own call reports failures.
        }
      }
    }(),
]);

/// A HEAD through [dio] that accepts any status.
Future<void> Function(String url) dioHead(Dio dio) =>
    (url) => dio.head<void>(url, options: Options(validateStatus: (_) => true));
