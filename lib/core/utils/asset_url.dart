/// Reachability / fallback handling for *original* artwork asset links.
///
/// Video sources and full-resolution images are fetched straight from origin
/// (IPFS gateways, Arweave) rather than the image CDN, and those origins
/// periodically reject a direct fetch. The worst offender is `arweave.net`,
/// whose CDN returns 403 for specific clients/regions even for data it serves
/// fine everywhere else. Such a block cannot be detected by probing — a HEAD or
/// GET from one client says nothing about another — so the only reliable signal
/// is the asset's own load failing on *this* device.
///
/// [AssetUrl.assetSourceCandidates] returns an ordered list of URLs to try: the
/// natural gateway first, then mirrors/alternates. The caller loads each in turn
/// and advances only when one fails to initialise. This mirrors the web
/// client's gateway transform plus its reactive arweave-403 mirror, collapsed
/// into a single retry list, since `video_player` gives us
/// an init failure to react to rather than a live element `onError` event.
///
/// The list used to be produced by a shared resolver service; that service is
/// retired (original-serving spec, decision 4), so the local
/// transform list — its old degraded-mode fallback — is the only path left.
///
/// [AssetUrl.videoSourceCandidates] is what players actually call: it puts the
/// images service's `/original/` route in front of that list, so the
/// R2-cached original is tried before any public gateway.
library;

import '../config/environment.dart';
import 'canonical_asset_url.dart';
import 'mux.dart';

class AssetUrl {
  AssetUrl._();

  /// This deployment's Arweave gateway — the mirror used when the public
  /// gateway 403s. From `ARWEAVE_GATEWAY_URL`; defaults to `arweave.net`, which
  /// makes the mirror step a no-op rather than a second host to trust.
  ///
  /// The **whole** base URL, trailing slash trimmed: scheme, optional port and
  /// optional path prefix included, exactly as `toDirectUrl` reads the same
  /// variable. Reducing it to a bare host and rebuilding on `https://` threw
  /// the other three away, so any gateway not served from the root of an https
  /// origin — a local one on a port, a proxy under a path prefix — turned every
  /// rung of the ladder into a connection to a host that was never configured.
  static String get mallowArweaveBase =>
      _baseOr(Config.arweaveGatewayUrl, 'https://$_arweaveHost');

  /// This deployment's IPFS gateway, preferred for Solana assets. From
  /// `IPFS_GATEWAY_URL`; defaults to the public `ipfs.io`. A full base URL,
  /// like [mallowArweaveBase].
  static String get mallowIpfsBase =>
      _baseOr(Config.ipfsGatewayUrl, _publicIpfsBase);

  /// The public IPFS gateway [mallowIpfsBase] is swapped with. These two are
  /// the only gateways the mirror order treats as interchangeable — any other
  /// gateway in a source URL is that asset's own, not one of ours. When no
  /// gateway is configured the two are the same base and the swap collapses,
  /// which [assetSourceCandidates]'s de-duplication already absorbs.
  static const String publicIpfsHost = 'ipfs.io';
  static const String _publicIpfsBase = 'https://$publicIpfsHost';

  /// [url] with any trailing slash removed, or [fallback] when it is empty.
  static String _baseOr(String url, String fallback) {
    final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    return base.isEmpty ? fallback : base;
  }

  /// [url] with the [from] base swapped for [to], or `null` when [url] is not
  /// served by [from]. Prefix-based, so a base carrying a port or a path prefix
  /// survives the swap intact.
  static String? _rebase(String url, String from, String to) =>
      url.startsWith(from) ? '$to${url.substring(from.length)}' : null;

  /// Last-resort IPFS gateway, tried only after both gateways above have
  /// failed.
  ///
  /// Neither of those is a complete index: a CID that was never pinned on
  /// [mallowIpfsBase] 404s there permanently, and `ipfs.io` 504s while it
  /// cold-fetches a large object it does not already hold. That pair failing
  /// together is not rare — it is what an old artwork whose original is not in
  /// R2 looks like, and it took the whole ladder down with it. `dweb.link`
  /// resolves from the wider DHT and answered such assets in ~300ms.
  static const String lastResortIpfsHost = 'dweb.link';
  static const String _lastResortIpfsBase = 'https://$lastResortIpfsHost';

  static const String _arweaveHost = 'arweave.net';
  static const String _permagateHost = 'permagate.io';

  /// Ordered source URLs to attempt for [url], most-preferred first, with
  /// duplicates removed. Returns an empty list for an empty or blacklisted
  /// (`shdw-drive`) source so the caller can skip playback and keep the poster.
  ///
  /// [chain] selects the IPFS gateway: Solana — and any unknown/unspecified
  /// chain — prefer the configured [mallowIpfsBase]; other chains stay on
  /// `ipfs.io`, matching the web client's own gateway rule.
  static List<String> assetSourceCandidates(String url, {String? chain}) {
    if (!_isPlayable(url)) return const [];

    final candidates = <String>[];
    void add(String? candidate) {
      if (candidate != null &&
          candidate.isNotEmpty &&
          !candidates.contains(candidate)) {
        candidates.add(candidate);
      }
    }

    final primary = _primaryGateway(url, chain);
    add(primary);
    // arweave.net (etc.) → the configured mirror — the 403 recovery.
    add(mallowArweaveUrl(primary));
    // ipfs.io ↔ the configured gateway — fall through if one is down.
    add(_altIpfsGateway(primary));
    // Both of ours exhausted — dweb.link as the last word on whether the CID
    // is reachable at all. Always last: it is a third party with no mallow
    // relationship, so it must never displace a gateway we control.
    add(_lastResortIpfsGateway(primary));
    return candidates;
  }

  /// Sources that can never play: empty, or `shdw-drive` (a dead host). An empty
  /// candidate list tells the caller to skip playback and keep the poster.
  static bool _isPlayable(String url) =>
      url.isNotEmpty && !url.contains('shdw-drive');

  /// Ordered video source URLs for [url]: the `/original/` URL always leads
  /// (original-serving spec), then the direct gateway ladder.
  ///
  /// The images service serves the mint-time bytes from R2 when it has them —
  /// much faster than the public gateways — and 307s to the best live gateway
  /// when it doesn't, so gateway *choice* moves server-side and `video_player`
  /// follows the redirect. The direct gateway candidates still follow it,
  /// because the host that redirect lands on can 404/403 the player — decision
  /// 24's "fall back to the direct gateway URL" is what keeps that from ending
  /// playback, using the retry ladder the caller already walks.
  ///
  /// [playbackId] puts the artwork's Mux HLS stream ahead of the whole ladder,
  /// so a transcoded artwork plays without pulling a multi-megabyte original
  /// off a gateway. Pass it wherever one is known: the transcode is not a
  /// lower-fidelity preview to be upgraded away from later, it is *the* source
  /// for an artwork that has one, and fullscreen continues the player it opened
  /// rather than reopening the asset. An original is reached only when there is
  /// no playback id — or when Mux fails, since the originals stay behind it.
  ///
  /// Unplayable sources still yield `[]` — unless [playbackId] is set, in which
  /// case the transcode is the one source left and leads a list of its own. A
  /// dead `shdw-drive` original says nothing about Mux's copy of the bytes.
  static Future<List<String>> videoSourceCandidates(
    String url, {
    String? chain,
    String? playbackId,
  }) async {
    final id = playbackId?.trim();
    final mux = (id == null || id.isEmpty) ? null : Mux.streamUrl(id);
    final candidates = assetSourceCandidates(url, chain: chain);
    if (candidates.isEmpty) return mux == null ? candidates : [mux];
    final original = getOriginalAssetUrl(url);
    return [?mux, original, ...candidates.where((c) => c != original)];
  }

  /// The configured Arweave mirror of [url] in path form, or `null` when
  /// [url] is not served by an Arweave gateway. Handles the bare `arweave.net` /
  /// `permagate.io` hosts as well as per-tx `<base32>.arweave.net` sandbox
  /// subdomains. Mirrors the web client's equivalent helper.
  static String? mallowArweaveUrl(String url) {
    // Already served by the configured base: it is its own mirror, and the
    // rebuild below would repeat the base's own path prefix. Recognised by the
    // whole base rather than by its host, so a second gateway on that same host
    // under a different prefix — how the e2e harness serves both — is not
    // mistaken for this one.
    if (url.startsWith(mallowArweaveBase)) return url;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    final isArweave =
        host == _arweaveHost ||
        host.endsWith('.$_arweaveHost') ||
        host == _permagateHost;
    if (!isArweave) return null;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    return '$mallowArweaveBase${uri.path}$query';
  }

  /// The preferred gateway URL for [url] — [_primaryGateway] exposed for
  /// callers that only need the first choice, not the whole fallback list
  /// (e.g. `MallowImage` normalising `ipfs://` before handing the URL to the
  /// image CDN).
  static String primaryGatewayUrl(String url, {String? chain}) =>
      _primaryGateway(url, chain);

  static bool _isSolana(String? chain) =>
      chain == null || chain.toLowerCase() == 'solana';

  /// Natural first-choice gateway for [url]: resolves the `ipfs://` scheme
  /// (absorbing the redundant `ipfs://ipfs/<cid>` form) onto the **public**
  /// gateway, then rewrites `ipfs.io` to this deployment's gateway for Solana.
  /// http(s) origins — including Arweave — pass through unchanged, matching the
  /// web client, which only swaps to the Arweave mirror on an actual load
  /// failure.
  ///
  /// 🛑 **`ipfs://` resolves to `ipfs.io`, not to the deployment's gateway, and
  /// the two branches below are deliberately asymmetric.** This string is the
  /// source embedded in the image CDN's resize path, which means it IS the
  /// resizer's cache key and the R2 object key. The web client resolves the
  /// same scheme through the public gateway, so sending our own host here
  /// forked every `ipfs://` asset across two cache entries — one warmed by the
  /// backend (which follows the web client) and one the app requested and never
  /// hit. Nothing failed; images were simply always cold. Keep this in step
  /// with the web client's `getAltStorageUrl`, whose first branch is
  /// unconditional in exactly the same way.
  static String _primaryGateway(String url, String? chain) {
    final ipfsScheme = RegExp(r'^ipfs://(?:ipfs/)?');
    if (ipfsScheme.hasMatch(url)) {
      return 'https://$publicIpfsHost/ipfs/'
          '${url.replaceFirst(ipfsScheme, '')}';
    }
    if (_isSolana(chain)) {
      return _rebase(url, _publicIpfsBase, mallowIpfsBase) ?? url;
    }
    return url;
  }

  /// [url] on [lastResortIpfsHost], or `null` when it is on neither of our two
  /// IPFS hosts — a URL naming some other gateway is the asset's own, and
  /// rehosting it elsewhere is [_altIpfsGateway]'s bet to make, not this one's.
  static String? _lastResortIpfsGateway(String url) {
    for (final base in [mallowIpfsBase, _publicIpfsBase]) {
      final rebased = _rebase(url, base, _lastResortIpfsBase);
      if (rebased != null) return rebased;
    }
    return null;
  }

  /// The alternate IPFS gateway for a resolved [url]: swaps
  /// the configured gateway ↔ `ipfs.io` so an outage falls through to the
  /// other. Returns `null` when [url] is on neither. The configured base is
  /// tried first: it can itself sit on `ipfs.io` under a path prefix, and the
  /// more specific base must win that overlap.
  static String? _altIpfsGateway(String url) =>
      _rebase(url, mallowIpfsBase, _publicIpfsBase) ??
      _rebase(url, _publicIpfsBase, mallowIpfsBase);
}
