import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/utils/canonical_asset_url.dart';

/// The canonical asset-URL form is not a formatting preference — it IS the
/// Cloudflare edge and R2 cache key for every artwork byte the deployment
/// serves. The Rust resizer, the TypeScript web
/// client and this Dart port must agree byte-for-byte: if they drift, the same
/// asset fragments across cache entries, takedown purges by prefix miss, and
/// the source store grows a duplicate object per client platform.
///
/// So these tests read the SHARED contract file rather than restating
/// expectations locally — `test/assets/canonical_url_tests.json` is a copy of
/// the image-resizing service's vector file. A contract change must happen
/// there first and land in all three languages; a stale copy fails here.
///
/// The gateway hosts in that file are placeholders, because they are
/// configuration rather than contract: the vectors drive [Config] here instead
/// of the other way round, so this suite proves the *rules* hold for whatever
/// hosts a deployment sets — including the ones a fork sets.
void main() {
  final contract =
      jsonDecode(
            File('test/assets/canonical_url_tests.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final cases = (contract['cases'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final originalBase = contract['originalBase'] as String;
  final gateways = contract['directGateways'] as Map<String, dynamic>;

  setUp(() {
    // `originalBase` is '<origin>/original/'; the CDN origin is what Config
    // holds. The gateway entries carry their '/ipfs/' and trailing '/' path
    // parts, which Config does not, so trim to the origin for both.
    Config.debugOverrides.addAll({
      'IMAGE_CDN_BASE_URL': _origin(originalBase),
      'IPFS_GATEWAY_URL': _origin(gateways['ipfs'] as String),
      'ARWEAVE_GATEWAY_URL': _origin(gateways['arweave'] as String),
    });
  });

  tearDown(Config.debugOverrides.clear);

  test('the vector file was actually loaded (guards a silent empty suite)', () {
    expect(cases, isNotEmpty);
  });

  group('shared contract vectors', () {
    for (final vector in cases) {
      final name = vector['name'] as String;
      final input = vector['input'] as String;
      final canonical = vector['canonical'] as String;

      test(name, () {
        expect(
          canonicalizeAssetUrl(input),
          canonical,
          reason: 'canonical form of $input',
        );
        expect(
          toDirectUrl(canonical),
          vector['direct'] as String,
          reason: 'direct-gateway mapping of $canonical',
        );
        expect(
          buildOriginalPath(input),
          vector['originalPath'] as String,
          reason: 'percent-encoded /original/ path for $input',
        );
        expect(
          getOriginalAssetUrl(input),
          originalBase.substring(0, originalBase.length - '/original/'.length) +
              (vector['originalPath'] as String),
          reason: 'absolute originals URL for $input',
        );
      });
    }
  });

  group('idempotence', () {
    // The server 301-normalises non-canonical encodings, so a client that
    // canonicalises an already-canonical URL (e.g. a URL that round-tripped
    // through the API) must not shift it again — a second pass that changed the
    // string would put two cache keys on the same bytes.
    for (final vector in cases) {
      final canonical = vector['canonical'] as String;
      test('canonicalize(${vector['name']}) is a fixed point', () {
        expect(canonicalizeAssetUrl(canonical), canonical);
        expect(buildOriginalPath(canonical), vector['originalPath'] as String);
      });
    }
  });

  group('percent-encoding table', () {
    // The embedded segment must encode exactly like JavaScript's
    // encodeURIComponent, the contract's reference encoder — the resizer keys
    // R2/CF on the raw string, so a single extra or missing escape forks the
    // cache between platforms. This pins the unreserved set so an SDK change to
    // Uri.encodeComponent fails loudly here instead of silently on the edge.
    test('leaves exactly the encodeURIComponent unreserved set unescaped', () {
      const unreserved =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*\'()';
      expect(buildOriginalPath(unreserved), '/original/$unreserved');
    });

    test('escapes reserved ASCII with upper-case hex', () {
      expect(
        buildOriginalPath(':/?#[]@\$&+,;= "'),
        // `#` and everything after it is dropped as a fragment before encoding.
        '/original/%3A%2F%3F',
      );
      expect(
        buildOriginalPath('a[]@\$&+,;= "b'),
        '/original/a%5B%5D%40%24%26%2B%2C%3B%3D%20%22b',
      );
    });

    test('encodes non-ASCII as UTF-8 bytes', () {
      expect(buildOriginalPath('é☃'), '/original/%C3%A9%E2%98%83');
    });
  });

  group('edge cases outside the vector file', () {
    test('empty input stays empty (callers guard on it, never encode it)', () {
      expect(canonicalizeAssetUrl(''), '');
      expect(toDirectUrl(''), '');
    });

    test('a bare fragment collapses to the empty string', () {
      expect(canonicalizeAssetUrl('#frag'), '');
    });

    // A host-only URL reaches the Arweave branch with an empty path, where
    // `''.substring(1)` throws a RangeError — so this asserts "returns verbatim"
    // rather than "does not classify", and guards the throw.
    test('host-only https URLs stay verbatim without throwing', () {
      expect(
        canonicalizeAssetUrl('https://arweave.net'),
        'https://arweave.net',
      );
      expect(
        canonicalizeAssetUrl('https://arweave.example.com'),
        'https://arweave.example.com',
      );
      expect(
        canonicalizeAssetUrl('https://example.com?a=1'),
        'https://example.com?a=1',
      );
    });
  });
}

/// Scheme + host of [url], dropping any path — the form [Config] holds.
String _origin(String url) {
  final u = Uri.parse(url);
  return '${u.scheme}://${u.host}';
}
