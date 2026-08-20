import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Adds the `App-Version` header (the app semver, e.g. `0.10.0`) to mallow
/// backend requests only.
///
/// Mirrors the reference web client, which sends `App-Version` on all API calls so the
/// backend can key version-gated behavior off the requesting client. The
/// value is the plain semver from [PackageInfo] (no `+build` suffix) so it
/// parses as a valid version server-side; it is resolved once and cached for
/// the lifetime of the client.
///
/// The shared Dio singleton this rides on also carries cross-origin traffic —
/// the public rewards CDN reads through it today, and any
/// request-level URL override could target a non-mallow host tomorrow. A
/// backend-only version marker has no business on those requests, and a
/// CORS-strict third party can reject the unexpected header outright, so the
/// header is attached only when the request host is one of [mallowHosts] (the
/// v1/v2 mallow API hosts, supplied at construction from `Config`).
class AppVersionInterceptor extends Interceptor {
  AppVersionInterceptor({required this.mallowHosts});

  /// Hosts (the configured API hosts, plus `FIRST_PARTY_HOSTS`) the
  /// `App-Version` header may be sent to.
  /// Requests to any other host are left untouched.
  final Set<String> mallowHosts;

  /// The in-flight (then completed) version lookup. Caching the *future* — not
  /// just the resolved string — matters at cold start: `PackageInfo` only
  /// memoises itself once it completes, so the burst of requests that fire in
  /// parallel on launch would otherwise each make their own platform-channel
  /// round trip before any of them resolved.
  Future<String>? _version;

  /// Set once [_version] resolves, so steady-state requests attach the header
  /// synchronously instead of paying an async hop per request.
  String? _resolvedVersion;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (mallowHosts.contains(options.uri.host)) {
      final version = _resolvedVersion ??= await _resolve();
      if (version != null) {
        options.headers['App-Version'] = version;
      }
    }
    handler.next(options);
  }

  /// The shared lookup, joined by every caller that arrives while it is still
  /// in flight.
  ///
  /// Returns `null` if the platform call fails, and drops the memo so a later
  /// request retries rather than replaying the failure for the rest of the
  /// process. The request itself still goes out — unheadered, exactly as an
  /// older client's would — because letting the error escape [onRequest] would
  /// leave `handler` uncalled and hang every mallow request forever.
  Future<String?> _resolve() async {
    final pending = _version ??= PackageInfo.fromPlatform().then(
      (info) => info.version,
    );
    try {
      return await pending;
    } catch (_) {
      if (identical(_version, pending)) _version = null;
      return null;
    }
  }
}
