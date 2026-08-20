import 'package:dio/dio.dart';

import '../config/environment.dart';

/// Adds the `x-api-key` header ([Config.mallowApiKey]) to requests bound for
/// the backend this build is configured against, and nowhere else.
///
/// The header exists so a reader who holds a mallow-issued key can run the app
/// against a mallow-operated backend instead of standing one up first. It is
/// the `ApiKeyAuth` scheme the vendored OpenAPI contract already declares, so a
/// fork implementing that contract sees the same mechanism.
///
/// 🛑 **The host gate is [Config.sessionHosts], never
/// [Config.firstPartyHosts].** The shared `Dio` this rides on also carries
/// third-party traffic — Jupiter's public API backs token search, the rewards
/// CDN reads through it — and, more subtly, `FIRST_PARTY_HOSTS` lets a build
/// *declare* extra hosts first-party so they receive the client-id header.
/// That header identifies a build; this key is a spendable credential for one
/// backend. Gating it on the widened set would let a line of build config hand
/// a working key to a declared RPC or IPFS proxy. The session `Cookie` is
/// pinned to the narrow set for exactly this reason, and so is this.
///
/// The gate itself lives in [Config.apiKeyHeadersFor] rather than in a host set
/// passed at construction: there is then one expression in the codebase that
/// decides where this credential may travel, and no way to wire the
/// interceptor up with the wrong set.
///
/// The value is read per request, so an unconfigured build sends no header at
/// all rather than an empty one — an empty header value is a different request
/// on the wire and a gateway may reject it as malformed.
class ApiKeyInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers.addAll(Config.apiKeyHeadersFor(options.uri));
    handler.next(options);
  }
}
