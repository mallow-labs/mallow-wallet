import 'package:dio/dio.dart';

import '../config/environment.dart';

/// Adds the build's first-party identification header
/// ([Config.clientIdHeaders]) to mallow backend requests only.
///
/// 🛑 This header is a credential, not a marker: the backend accepts it in
/// place of an API key on the open `/v2` routes, and the RPC/pinning proxies
/// authorize on it too. The shared Dio singleton it rides on also carries
/// third-party traffic — Jupiter's public API backs token search and the
/// rewards CDN reads through it — so putting the
/// header in the client's `BaseOptions` would hand our credential to every one
/// of those hosts on every request. It is therefore attached only when the
/// request host is one of [mallowHosts], the same guard (and the same host
/// set) `AppVersionInterceptor` uses.
///
/// This covers only the traffic that rides this Dio. Requests built on a raw
/// `RpcClient`, a per-service `Dio` or `package:http` never reach any
/// interceptor, so they apply the identical gate themselves through
/// `Config.clientIdHeadersFor` — which reads the same host set.
///
/// The value is read per request rather than captured at construction so an
/// unconfigured build keeps sending nothing at all: [Config.clientIdHeaders]
/// is empty unless both the header name and the platform value are configured,
/// and an empty map adds no header — an empty header value is a different
/// request on the wire and a gateway may reject it as malformed instead of
/// treating it as an anonymous caller.
class ClientIdInterceptor extends Interceptor {
  ClientIdInterceptor({required this.mallowHosts});

  /// Hosts (the configured API hosts, plus `FIRST_PARTY_HOSTS`) the client-id
  /// header may be sent to, supplied at construction from `Config`. Requests
  /// to any other host are left untouched.
  final Set<String> mallowHosts;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (mallowHosts.contains(options.uri.host)) {
      options.headers.addAll(Config.clientIdHeaders);
    }
    handler.next(options);
  }
}
