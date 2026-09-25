/// Canonical asset-URL contract (original-serving spec) — the Dart member of
/// a three-language set, alongside the image-resizing service (Rust) and the
/// web client (TypeScript). All three are pinned by the shared vector file
/// `canonical_url_tests.json`, copied into this repo at
/// `test/assets/canonical_url_tests.json`; change the contract there first.
///
/// String operations only — URL parsers normalise differently across the three
/// languages ([Uri.parse] decodes percent-escapes in paths, JS's `URL`
/// re-encodes them), which would silently fork the R2 and Cloudflare cache keys
/// these strings ARE. The verbatim branch must return the input byte-identical
/// minus everything from the first `#`.
///
/// Recognising a shape as content-addressed is what makes the server store and
/// long-cache it, so the set is deliberately broad: path gateways, subdomain
/// gateways, the bare-CID legacy gateways in [_bareCidHosts], and every host in
/// [_arweaveHosts]. Anything unrecognised falls through to the verbatim branch,
/// which is the safe direction.
library;

import '../config/environment.dart';

final RegExp _cidRegex = RegExp(
  r'^(Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{50,})$',
);
final RegExp _txidRegex = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// Arweave is host-gated (unlike IPFS, which is path-addressed on any gateway):
/// only these families carry bare tx ids at the path root.
///
/// `gateway.irys.xyz` is deliberately absent: Irys data items live on its own
/// data chain now, so a data-item id is NOT an Arweave tx id and resolves on no
/// arweave gateway. Canonicalising one to `ar://` sent every fetch to an arweave
/// mirror that answers 404 while the bytes sit on irys. Irys URLs stay verbatim
/// https and are fetched from the host in the URL. Must stay in step with
/// `ARWEAVE_GATEWAYS` in the image resizer — the server both canonicalises and
/// fetch-falls-back over that list.
/// The public Arweave families, recognised by every implementation of this
/// contract. A deployment's own mirror is added on top from
/// `ARWEAVE_GATEWAY_URL` — see [_arweaveHosts] — rather than being written in
/// here: one language quietly growing a host is how the three implementations'
/// cache keys diverge.
const Set<String> _publicArweaveHosts = {'permagate.io', 'arweave.net'};

/// Legacy gateways that serve a CID at the path root, with no `/ipfs/` segment:
/// `https://<host>/<CID>[/path]`. Pinned by the contract's `bareCidHosts`.
///
/// Host-gated on purpose, and this is the one IPFS rule that is. A bare first
/// segment is not self-describing the way `/ipfs/<CID>` is — on an arbitrary
/// host a path that happens to look like a CID is far more likely to be a
/// filename, and canonicalising it would move real bytes to a key nothing
/// serves. On these six it is always a CID, because that is the only route they
/// ever had.
///
/// Recognising them is what makes those assets storable and long-cacheable
/// under one key with the same bytes fetched through any other gateway; several
/// of the hosts are dead or dying (`cloudflare-ipfs.com` shut down in 2024), so
/// the canonical form is also what lets a live gateway serve them at all. Never
/// add one of these as a fetch target. The web client's alt-storage rewriter
/// has recognised the same six for longer; this closes the gap.
///
/// A `*.` entry matches any host with at least one label in front of the
/// suffix. The apex does not match: `mypinata.cloud` is Pinata's own site, not
/// a customer's dedicated gateway.
const List<String> _bareCidHosts = [
  'gateway.pinata.cloud',
  '*.mypinata.cloud',
  'nftstorage.link',
  'cloudflare-ipfs.com',
  'gateway.pinit.io',
  'gateway.lighthouse.storage',
];

/// Whether [host] — already lower-cased and `www.`-stripped — is in
/// [_bareCidHosts].
bool _isBareCidHost(String host) {
  for (final entry in _bareCidHosts) {
    if (entry.startsWith('*.')) {
      final suffix = entry.substring(1);
      if (host.length > suffix.length && host.endsWith(suffix)) return true;
    } else if (host == entry) {
      return true;
    }
  }
  return false;
}

/// Hosts whose bare-txid paths canonicalise to `ar://`: the public families
/// plus this deployment's mirror, when it runs one.
///
/// 🛑 Must stay in step with the server's `ARWEAVE_GATEWAYS`. A mirror the
/// client fails to recognise produces a *different canonical form* for the same
/// bytes, which is a different R2 object and a different edge cache key — a
/// cache miss on every request, with nothing failing to show for it.
Set<String> get _arweaveHosts => {
  ..._publicArweaveHosts,
  ?_hostOf(Config.arweaveGatewayUrl),
};

/// Bare host of [url], or `null` when it has none. String-only, like the rest
/// of this library.
String? _hostOf(String url) {
  final schemeEnd = url.indexOf('://');
  if (schemeEnd == -1) return null;
  final afterScheme = url.substring(schemeEnd + '://'.length);
  final slash = afterScheme.indexOf('/');
  final authority = slash == -1 ? afterScheme : afterScheme.substring(0, slash);
  final host = _stripQuery(authority).toLowerCase();
  return host.isEmpty ? null : host;
}

String _stripFragment(String url) {
  final i = url.indexOf('#');
  return i == -1 ? url : url.substring(0, i);
}

String _stripQuery(String s) {
  final i = s.indexOf('?');
  return i == -1 ? s : s.substring(0, i);
}

String _firstSegment(String s) {
  final i = s.indexOf('/');
  return i == -1 ? s : s.substring(0, i);
}

/// Collapses an asset URL to its canonical form: scheme-native
/// `ipfs://CID[/path]` / `ar://TXID[/path]` for content-addressed sources (query
/// dropped — the id names the bytes), verbatim-minus-fragment for everything
/// else. Embedded percent-encoding in kept path segments is preserved untouched.
String canonicalizeAssetUrl(String raw) {
  final input = _stripFragment(raw);

  if (input.startsWith('ipfs://')) {
    var rest = input.substring('ipfs://'.length);
    if (rest.startsWith('ipfs/')) {
      // Malformed-but-seen-in-the-wild ipfs://ipfs/CID variant.
      rest = rest.substring('ipfs/'.length);
    }
    rest = _stripQuery(rest);
    return _cidRegex.hasMatch(_firstSegment(rest)) ? 'ipfs://$rest' : input;
  }

  if (input.startsWith('ar://')) {
    final rest = _stripQuery(input.substring('ar://'.length));
    return _txidRegex.hasMatch(_firstSegment(rest)) ? 'ar://$rest' : input;
  }

  final schemeEnd = input.indexOf('://');
  if (schemeEnd == -1) return input;
  final scheme = input.substring(0, schemeEnd).toLowerCase();
  if (scheme != 'http' && scheme != 'https') return input;

  final afterScheme = input.substring(schemeEnd + '://'.length);
  // A subdomain gateway carries the CID in the authority, so the path may be
  // empty — `https://<cid>.ipfs.dweb.link` still names bytes.
  final slash = afterScheme.indexOf('/');
  final authority = slash == -1
      ? _stripQuery(afterScheme)
      : afterScheme.substring(0, slash);
  final path = slash == -1 ? '' : _stripQuery(afterScheme.substring(slash));
  var host = authority.toLowerCase();
  if (host.startsWith('www.')) host = host.substring('www.'.length);

  // IPFS is path-addressed: /ipfs/<CID>[/...] on ANY gateway host.
  if (path.startsWith('/ipfs/')) {
    final rest = path.substring('/ipfs/'.length);
    if (_cidRegex.hasMatch(_firstSegment(rest))) return 'ipfs://$rest';
  }

  // Subdomain gateways (dweb.link, nftstorage.link, w3s.link, Pinata dedicated
  // gateways) put the CID in the leftmost label: <cid>.ipfs.<host>[:port]. Origin
  // isolation forces CIDv1 here — a base58 CIDv0 is case-sensitive and can't be a
  // DNS label — so the CID regex does the whole job, and requiring the `.ipfs.`
  // marker keeps a plain `gateway.ipfs.io` host out of this branch.
  final marker = host.indexOf('.ipfs.');
  if (marker != -1) {
    final label = host.substring(0, marker);
    if (_cidRegex.hasMatch(label)) return 'ipfs://$label$path';
  }

  // Bare-CID legacy gateways: the CID is the first path segment, with no
  // `/ipfs/` marker to key on, so the host list above is the whole gate. It
  // runs after both rules above because those hosts also serve the standard
  // shapes, and `/ipfs/<CID>` must win: on `gateway.pinata.cloud/ipfs/<CID>`
  // this branch would otherwise read `ipfs` as the first segment, fail the CID
  // regex, and drop a recognised URL to verbatim.
  if (_isBareCidHost(host) && path.startsWith('/')) {
    final rest = path.substring(1);
    if (_cidRegex.hasMatch(_firstSegment(rest))) return 'ipfs://$rest';
  }

  // Arweave: known family hosts only, and the first segment must be a bare tx
  // id — non-tx routes like /raw/... stay verbatim https. The startsWith guard
  // matters here: `''.substring(1)` throws a RangeError for a URL with no path.
  if (_arweaveHosts.contains(host) && path.startsWith('/')) {
    final rest = path.substring(1);
    if (_txidRegex.hasMatch(_firstSegment(rest))) return 'ar://$rest';
  }

  return input;
}

/// Maps a canonical form to the preferred public mirror — the client fallback
/// target when the image CDN is unreachable or 5xxing. Https forms return
/// verbatim. Never use this to route around a 410 takedown verdict (see
/// `ImageFallback.directUrlFor`, which HEAD-checks first).
String toDirectUrl(String canonical) {
  if (canonical.startsWith('ipfs://')) {
    return '${_trimSlash(Config.ipfsGatewayUrl)}/ipfs/'
        '${canonical.substring('ipfs://'.length)}';
  }
  if (canonical.startsWith('ar://')) {
    return '${_trimSlash(Config.arweaveGatewayUrl)}/'
        '${canonical.substring('ar://'.length)}';
  }
  return canonical;
}

String _trimSlash(String url) =>
    url.endsWith('/') ? url.substring(0, url.length - 1) : url;

/// Path for the originals endpoint. The canonical form is embedded as ONE
/// percent-encoded path segment — same convention as the resize path — so the
/// byte-exact output here is also the Cloudflare edge cache key contract.
///
/// [Uri.encodeComponent] is used deliberately: it escapes everything outside
/// `A-Za-z0-9-_.!~*'()` as UTF-8 with upper-case hex, which is byte-for-byte
/// what JavaScript's `encodeURIComponent` (the contract's reference encoder)
/// produces — verified over the whole ASCII range plus multi-byte code points,
/// and pinned by `canonical_url_tests.json`. Do NOT swap in
/// `Uri.encodeQueryComponent` or `Uri.encodeFull`, which use different tables.
String buildOriginalPath(String url) =>
    '/original/${Uri.encodeComponent(canonicalizeAssetUrl(url))}';

/// Absolute originals URL on the image CDN, or the asset's own gateway URL
/// when no CDN is configured ([Config.imageCdnBaseUrl] empty) — there is no
/// originals route to send the caller to, and the raw asset is the answer.
String getOriginalAssetUrl(String url) {
  final origin = Config.imageCdnBaseUrl;
  if (origin.isEmpty) return toDirectUrl(canonicalizeAssetUrl(url));
  return _trimSlash(origin) + buildOriginalPath(url);
}
