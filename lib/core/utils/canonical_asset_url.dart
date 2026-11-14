/// Canonical asset-URL contract — the Dart member of
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
///
/// A CID in another multibase keeps its spelling in the canonical form, and is
/// respelled here as lower-case base32, the one spelling every gateway serves.
String toDirectUrl(String canonical) {
  if (canonical.startsWith('ipfs://')) {
    return '${_trimSlash(Config.ipfsGatewayUrl)}/ipfs/'
        '${_gatewayPath(canonical.substring('ipfs://'.length))}';
  }
  if (canonical.startsWith('ar://')) {
    return '${_trimSlash(Config.arweaveGatewayUrl)}/'
        '${canonical.substring('ar://'.length)}';
  }
  return canonical;
}

String _gatewayPath(String rest) {
  // The URL parser removes these wherever they are, so `%2<LF>F` is a separator too.
  final cleaned = rest.replaceAll(RegExp(r'[\t\r\n]'), '');
  // A non-CID spelling keeps its query in the canonical form, so unlike
  // `_firstSegment`'s callers this one can see it. The CID also ends at what the URL
  // parser or the gateway will read as a separator, or the path after it would be
  // dropped with the padding the respelling removes.
  final end = cleaned.indexOf(RegExp(r'[/\\?#]|%2[fF]'));
  final segment = end == -1 ? cleaned : cleaned.substring(0, end);
  // A CID names its bytes, so nothing after the path can matter except to change them: a
  // gateway reads `?uri=` as a redirect and `?format=` as another encoding.
  final path = cleaned.substring(segment.length).split(RegExp('[?#]')).first;
  if (_cidRegex.hasMatch(segment)) return '$segment$path';
  final cid = _cidBytes(
    segment.replaceAllMapped(
      RegExp('%[0-9a-fA-F]{2}'),
      (hex) => String.fromCharCode(int.parse(hex[0]!.substring(1), radix: 16)),
    ),
  );
  if (cid == null || !_namesMultihash(cid)) return rest;
  return 'b${_base32Lower(cid)}$path';
}

const _base32 = 'abcdefghijklmnopqrstuvwxyz234567';
const _base32Hex = '0123456789abcdefghijklmnopqrstuv';
const _base36 = '0123456789abcdefghijklmnopqrstuvwxyz';
const _base58Btc = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const _base58Flickr =
    '123456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ';
const _base64 =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const _base64Url =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

/// Multibase prefix to alphabet: the set a gateway decodes. Padded and unpadded
/// variants share an alphabet, since padding is trimmed before decoding.
const _multibases = <String, String>{
  '0': '01',
  '7': '01234567',
  '9': '0123456789',
  'f': '0123456789abcdef',
  'F': '0123456789abcdef',
  'b': _base32,
  'B': _base32,
  'c': _base32,
  'C': _base32,
  'v': _base32Hex,
  'V': _base32Hex,
  't': _base32Hex,
  'T': _base32Hex,
  'h': 'ybndrfg8ejkmcpqxot1uwisza345h769',
  'k': _base36,
  'K': _base36,
  'z': _base58Btc,
  'Z': _base58Flickr,
  'm': _base64,
  'M': _base64,
  'u': _base64Url,
  'U': _base64Url,
};

/// Alphabets where upper and lower case are different digits.
const _caseSensitive = {_base58Btc, _base58Flickr, _base64, _base64Url};

/// The radix decode is quadratic, and base2 of a 512-bit CID still fits.
const _maxCidLength = 1024;

/// A shorter digest is an inline (identity) CID or noise that decoded by chance.
const _minDigestLength = 16;

/// The raw bytes of a CID in any version or multibase, or null if it isn't one.
List<int>? _cidBytes(String segment) {
  if (segment.isEmpty) return null;
  // Line breaks don't count: the decoders skip them, and so does the gateway, which has
  // no such limit. What this bounds is the radix decoders' work on the characters they keep.
  final kept = segment.replaceAll(RegExp(r'[\r\n]'), '').length;
  if (kept > _maxCidLength) return null;
  if (segment.length == 46 && segment.startsWith('Qm')) {
    return _decodeDigits(segment, _base58Btc);
  }
  final alphabet = _multibases[segment[0]];
  if (alphabet == null) return null;
  // The gateway's decoders skip line breaks, and stop reading at padding whatever
  // follows it.
  final body = segment
      .substring(1)
      .replaceAll(RegExp(r'[\r\n]'), '')
      .split('=')[0];
  if (segment[0] == '0') return _decodeBase2(body);
  return _decodeDigits(
    _caseSensitive.contains(alphabet) ? body : body.toLowerCase(),
    alphabet,
  );
}

/// The gateway's base2: zeros on the left to whole bytes, then each 8 characters
/// through `ParseInt`, so one can carry a sign and a negative one wraps.
List<int>? _decodeBase2(String body) {
  final padded = '0' * ((8 - body.length % 8) % 8) + body;
  final chunk = RegExp(r'^([+-]?)([01]+)$');
  final out = <int>[];
  for (var i = 0; i < padded.length; i += 8) {
    final match = chunk.firstMatch(padded.substring(i, i + 8));
    if (match == null) return null;
    final value = int.parse(match[2]!, radix: 2);
    out.add(match[1] == '-' ? -value & 0xff : value);
  }
  return out;
}

List<int>? _decodeDigits(String body, String alphabet) {
  final digits = <int>[];
  for (var i = 0; i < body.length; i++) {
    final digit = alphabet.indexOf(body[i]);
    if (digit < 0) return null;
    digits.add(digit);
  }
  final radix = alphabet.length;
  if (radix & (radix - 1) == 0) {
    // A power of two: leftover bits at the end are padding, whatever they hold.
    final width = radix.bitLength - 1;
    final out = <int>[];
    var accumulator = 0;
    var held = 0;
    for (final digit in digits) {
      accumulator = (accumulator << width) | digit;
      held += width;
      if (held >= 8) {
        held -= 8;
        out.add((accumulator >> held) & 0xff);
        accumulator &= (1 << held) - 1;
      }
    }
    return out;
  }
  final littleEndian = <int>[];
  for (final digit in digits) {
    var carry = digit;
    for (var i = 0; i < littleEndian.length; i++) {
      carry += littleEndian[i] * radix;
      littleEndian[i] = carry & 0xff;
      carry >>= 8;
    }
    while (carry > 0) {
      littleEndian.add(carry & 0xff);
      carry >>= 8;
    }
  }
  for (final digit in digits) {
    if (digit != 0) break;
    littleEndian.add(0);
  }
  return littleEndian.reversed.toList();
}

/// Offset just past the varint at [start], or null if there isn't one.
int? _skipVarint(List<int> bytes, int start) {
  for (var i = start; i < bytes.length && i < start + 9; i++) {
    if (bytes[i] & 0x80 == 0) return i + 1;
  }
  return null;
}

/// Whether [cid] holds a multihash. A bare sha2-256 multihash counts: gateways read
/// it as a CIDv0, so `zQm…` and `bciq…` resolve.
bool _namesMultihash(List<int> cid) {
  if (cid.length == 34 && cid[0] == 0x12 && cid[1] == 0x20) return true;
  if (cid.isEmpty || cid[0] != 0x01) return false;
  final multihash = _skipVarint(cid, 1);
  if (multihash == null) return false;
  final digestLength = _skipVarint(cid, multihash);
  if (digestLength == null) return false;
  final digest = _skipVarint(cid, digestLength);
  if (digest == null || digest != digestLength + 1) return false;
  final length = cid[digestLength];
  return length >= _minDigestLength && cid.length - digest >= length;
}

String _base32Lower(List<int> bytes) {
  final out = StringBuffer();
  var accumulator = 0;
  var held = 0;
  for (final byte in bytes) {
    accumulator = (accumulator << 8) | byte;
    held += 8;
    while (held >= 5) {
      held -= 5;
      out.write(_base32[(accumulator >> held) & 31]);
    }
    accumulator &= (1 << held) - 1;
  }
  if (held > 0) out.write(_base32[(accumulator << (5 - held)) & 31]);
  return out.toString();
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
