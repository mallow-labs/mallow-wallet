/// Direct-gateway fallback for failed image-CDN loads
/// (original-serving spec decision 26).
///
/// Once every asset request goes through one domain, that domain being
/// unreachable would black out every image in the app — so a failed load gets
/// exactly one retry against the asset's own gateway. But an image widget's
/// error callback never sees a status code, and the fallback URL points at
/// this deployment's *own* mirrors (the configured IPFS and Arweave
/// gateways): swapping blindly would serve takedown-blacklisted bytes off our
/// infrastructure the
/// moment the CDN started returning 410. So the verdict is fetched explicitly
/// with a HEAD before anything is swapped.
///
/// The probe follows redirects, so *who answered* decides what the status
/// means: a miss on `/original/` 307s to a third-party gateway, and that
/// gateway's 404 is a statement about the gateway, not a mallow verdict. Only a
/// 4xx that comes back from the image CDN itself is final.
library;

import 'package:dio/dio.dart';

import '../config/environment.dart';
import '../observability/app_logger.dart';
import 'asset_url.dart';
import 'canonical_asset_url.dart';

class ImageFallback {
  ImageFallback._();

  static const String _tag = 'ImageFallback';

  static const Duration _timeout = Duration(seconds: 5);

  /// One client for every probe. Probes fire precisely during a CDN outage,
  /// when every visible image fails at once — a fresh [Dio] (and connection
  /// pool) per broken tile is the last thing the app needs in that moment.
  static final Dio _sharedClient = Dio();

  static String get _imagesHost => Uri.parse(Config.imageCdnBaseUrl).host;

  /// The gateway URL to retry [rawUrl] on after [failedUrl] failed to load, or
  /// `null` when falling back is not allowed and the caller must render its
  /// placeholder.
  ///
  /// HEADs [failedUrl], follows any redirect, and maps the answer by status
  /// *and* by the host that produced it:
  ///   * unreachable / timed out, or **5xx** → the service is degraded; retry
  ///     against the asset's own gateway.
  ///   * **4xx** answered by the image CDN (notably the **410** a takedown
  ///     returns) → `null`. This is the whole reason for the probe: the
  ///     fallback must never route around a blacklist verdict, because it
  ///     targets mallow's own mirrors.
  ///   * **4xx** answered by another host — the gateway `/original/`'s
  ///     miss-redirect landed on — → that gateway is broken, not the asset;
  ///     retry, preferring a gateway other than the one that just answered.
  ///   * **2xx/3xx** → `null`. The CDN is healthy, so the failure was local
  ///     (decode error, cache write) and refetching the same bytes elsewhere
  ///     fixes nothing.
  ///
  /// Also returns `null` for URLs that aren't on the image CDN, and when there
  /// is no untried gateway left (an https asset already fetched verbatim has
  /// nowhere else to go). Exactly one fallback is offered per surface; the
  /// caller's attempt guard turns a second failure into the placeholder.
  ///
  /// [client] is injectable for tests; production shares [_sharedClient]. Never
  /// throws — a probe failure must not replace a broken image with a crash.
  static Future<String?> directUrlFor(
    String rawUrl, {
    required String failedUrl,
    Dio? client,
  }) async {
    final cdnOrigin = Config.imageCdnBaseUrl;
    // With no CDN configured nothing is ever served from one, so there is no
    // CDN verdict to respect and no mirror to fall back to.
    if (rawUrl.isEmpty ||
        cdnOrigin.isEmpty ||
        !failedUrl.startsWith(cdnOrigin)) {
      AppLogger.debug(
        _tag,
        'no probe — $failedUrl is not on the image CDN, nothing to fall back '
        'from',
      );
      return null;
    }

    final dio = client ?? _sharedClient;
    String? answeredBy;
    try {
      final response = await dio.head<void>(
        failedUrl,
        options: Options(
          sendTimeout: _timeout,
          receiveTimeout: _timeout,
          // The 307 miss-redirect is a normal answer, not a failure — follow it
          // so the status below is attributed to whoever actually served it.
          followRedirects: true,
          // Read the status instead of throwing on it — 4xx and 5xx are
          // different verdicts here, and a thrown 410 must not be mistaken for
          // the network being down.
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode ?? 0;
      // `realUri` is the request URI unless the adapter recorded redirects; a
      // relative Location leaves the host empty, which still means our origin.
      final host = response.realUri.host;
      final fromCdn = host.isEmpty || host == _imagesHost;
      final answeredByLabel = fromCdn ? _imagesHost : host;
      if (status < 400) {
        AppLogger.debug(
          _tag,
          'probe $failedUrl → $status from $answeredByLabel — CDN is healthy, '
          'the failure was local (decode/cache); no retry',
        );
        return null;
      }
      if (status < 500 && fromCdn) {
        AppLogger.debug(
          _tag,
          'probe $failedUrl → $status from $answeredByLabel — asset is refused '
          '(takedown/missing); no retry',
        );
        return null;
      }
      // A broken server rather than a refused asset: a 5xx, or a 4xx from the
      // third-party gateway the miss-redirect landed on. Retry elsewhere — and
      // not on the host that just answered.
      answeredBy = fromCdn ? null : host;
      AppLogger.debug(
        _tag,
        'probe $failedUrl → $status from $answeredByLabel — '
        '${fromCdn ? 'CDN is degraded' : 'that gateway is broken'}; retrying '
        'elsewhere',
      );
    } catch (e) {
      // Unreachable, timed out, DNS failure — the degraded case the fallback
      // exists for. Fall through to the direct URL.
      AppLogger.debug(
        _tag,
        'probe $failedUrl failed to complete ($e) — CDN unreachable; retrying '
        'elsewhere',
      );
    }

    final retry = _retryUrl(rawUrl, failedUrl: failedUrl, skipHost: answeredBy);
    AppLogger.debug(
      _tag,
      retry == null
          ? 'no untried source left for $rawUrl'
          : 'retrying $rawUrl at $retry',
    );
    return retry;
  }

  /// Where to retry [rawUrl]: the first entry of [_candidates] that is neither
  /// [failedUrl] nor on [skipHost] — the gateway that just failed. `null` when
  /// every candidate is one of those.
  ///
  /// When [skipHost] is set — a *downstream* gateway answered, so our own CDN
  /// is up — the `/original/` route goes first: it can serve the R2-cached
  /// original even though the live gateway that just answered is broken, and
  /// R2 is much faster than a gateway walk. When the CDN itself is the thing
  /// that failed ([skipHost] null), `/original/` lives on that same dead host,
  /// so the gateway ladder is all that is left.
  static String? _retryUrl(
    String rawUrl, {
    required String failedUrl,
    required String? skipHost,
  }) {
    if (skipHost != null) {
      final original = getOriginalAssetUrl(rawUrl);
      if (original != failedUrl) return original;
    }

    for (final candidate in _candidates(rawUrl)) {
      if (candidate == failedUrl || !candidate.startsWith('https://')) continue;
      if (Uri.tryParse(candidate)?.host == skipHost) continue;
      return candidate;
    }
    return null;
  }

  /// Retry order for [rawUrl]: the gateway the source URL names itself, then
  /// the mirror `toDirectUrl` picks, then [AssetUrl.assetSourceCandidates]'
  /// order.
  ///
  /// Canonicalisation is host-agnostic on purpose: `/ipfs/<CID>` on *any*
  /// gateway collapses to `ipfs://<CID>`, and a bare txid on any Arweave family
  /// host to `ar://<txid>` — after which `toDirectUrl` points the retry at
  /// mallow's own mirror. That is right for a scheme-form source, which names
  /// no host at all. It is the wrong bet when the source URL *did* name a
  /// gateway (nftstorage.link, dweb.link, w3s.link, a dedicated Pinata gateway,
  /// arweave.net, permagate.io): a surface gets exactly one retry, and the host
  /// written into the URL is the one that demonstrably served the asset at mint
  /// time, while the mirror is a stand-in that has to resolve the CID/txid for
  /// itself. Spend the retry on the host we know had it; the mirror stays right
  /// behind it for callers that walk further down the ladder.
  ///
  /// [AssetUrl.publicIpfsHost] is the one host excluded. `ipfs.io` is not the
  /// asset's own gateway in any meaningful sense — it is the host
  /// [AssetUrl.mallowIpfsBase] is defined to stand in for — so the mirror keeps
  /// the lead there.
  static Iterable<String> _candidates(String rawUrl) sync* {
    final ownGateway = _ownGatewayUrl(rawUrl);
    if (ownGateway != null) yield ownGateway;
    yield toDirectUrl(canonicalizeAssetUrl(rawUrl));
    yield* AssetUrl.assetSourceCandidates(rawUrl);
  }

  /// [rawUrl] itself when it is an https URL whose host canonicalisation would
  /// otherwise discard in favour of a mallow mirror, excluding
  /// [AssetUrl.publicIpfsHost]; `null` otherwise, which leaves the mirror in
  /// front. An https URL that canonicalises verbatim has no mirror to lose, so
  /// it is left to the ladder below.
  static String? _ownGatewayUrl(String rawUrl) {
    if (!rawUrl.startsWith('https://')) return null;
    final canonical = canonicalizeAssetUrl(rawUrl);
    if (!canonical.startsWith('ipfs://') && !canonical.startsWith('ar://')) {
      return null;
    }
    final host = Uri.tryParse(rawUrl)?.host.toLowerCase();
    return (host == null || host == AssetUrl.publicIpfsHost) ? null : rawUrl;
  }
}
