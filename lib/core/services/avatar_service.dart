import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:path_provider/path_provider.dart';

import '../../shared/utils/chain.dart' show isEthereumAddress;
import '../config/environment.dart';
import '../observability/app_logger.dart';
import 'avatar_palette.dart';

const _tag = 'AvatarService';

/// Canonical seed for a generated fallback avatar: the username when we have
/// one, else the address, else the backend user id. Returns '' when none is
/// available (the avatar widget then renders the anon glyph).
///
/// Username comes first because a profile's identity outlives any single
/// wallet: surfaces that only know the profile (the drawer header, the profile
/// switcher) can't seed by address, so an address-first order would render a
/// different identicon there than on the profile page for the same user.
String avatarSeedOf({String? address, String? username, String? id}) {
  if (username != null && username.isNotEmpty) return username;
  if (address != null && address.isNotEmpty) {
    return normalizeAvatarSeed(address);
  }
  if (id != null && id.isNotEmpty) return id;
  return '';
}

/// Normalise [seed] so one identity always renders one identicon.
///
/// EVM addresses reach the app in two forms for the same account: EIP-55
/// checksummed (locally derived wallets, see `derivation.dart`) and lowercased
/// (backend rows, see `apiOwnerAddress`). The identicon and its `rowColor` are
/// hashes of the seed *string*, so the two forms would draw two different
/// avatars for one address. Lowercase EVM addresses; every other seed — account
/// UUIDs, usernames, base58 Solana and Tezos addresses — is case-sensitive and
/// passes through untouched.
///
/// Applied inside [AvatarService] as well as [avatarSeedOf], so surfaces that
/// seed an avatar directly from an address get the same normalisation.
String normalizeAvatarSeed(String seed) =>
    isEthereumAddress(seed) ? seed.toLowerCase() : seed;

/// On-disk cache subdir. Versioned (`_v2`) because the avatar URL now pins the
/// identicon foreground via `rowColor` — SVGs cached before that carry the old
/// seed-random colour and must be re-fetched.
const _cacheSubdir = 'account_avatars_v2';

/// Fetches and on-disk-caches auto-generated avatars (DiceBear `identicon`)
/// served by the configured identicon service, keyed by a stable seed string.
///
/// Two kinds of seed flow through here:
/// - **Account** avatars use the account's persisted `avatarSeed` — a random
///   UUID, or the Solana address for a social account.
/// - **Fallback** avatars for users/profiles without an uploaded picture use
///   [avatarSeedOf] (username → address → id) — all public identifiers.
///
/// Nothing private is ever sent to the avatar host; for the same reason this
/// uses a bare [Dio] with no auth interceptors/cookies rather than the app's
/// authenticated client.
///
/// Avatars are deterministic in the seed and immutable, so the first fetch
/// writes an SVG to the app support dir and every later load reads from disk
/// (no network). Renaming an account or adding/removing wallets does not change
/// the seed, so the avatar is stable across those.
@lazySingleton
class AvatarService {
  AvatarService() : _dio = Dio();

  /// Test seam: inject a [Dio] (and optionally a fixed [cacheDir]).
  @visibleForTesting
  AvatarService.forTest(this._dio, {Directory? cacheDir})
    : _cacheDirOverride = cacheDir;

  final Dio _dio;
  Directory? _cacheDirOverride;

  /// In-memory seed → file map so repeated reads in a session skip even the
  /// disk stat. Bounded by the number of distinct accounts (small).
  final Map<String, File> _memo = {};

  /// Coalesces concurrent fetches for the same seed into one network call.
  final Map<String, Future<File?>> _inFlight = {};

  // ---------------------------------------------------------------------------
  // URL contract
  // ---------------------------------------------------------------------------

  /// Build the avatar URL for [seed].
  ///
  /// [Config.avatarServiceUrl] is a DiceBear v10 `identicon` endpoint —
  /// DiceBear's public API by default, or a proxy of it (verified:
  /// `GET /10.x/identicon/svg?seed=…` → `200 image/svg+xml`). Kept isolated
  /// here so the version/style is a one-line change.
  ///
  /// `rowColor` pins the identicon foreground to one of the six brand hues,
  /// derived from the seed ([avatarRowColor]) so the colour is reproducible
  /// everywhere from just the persisted `avatarSeed`.
  static String _trimSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  Uri avatarUrl(String rawSeed) {
    final seed = normalizeAvatarSeed(rawSeed);
    return Uri.parse(
      '${_trimSlash(Config.avatarServiceUrl)}/10.x/identicon/svg'
      '?seed=${Uri.encodeComponent(seed)}'
      '&rowColor=${avatarRowColor(seed)}',
    );
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Return the on-disk SVG file for [seed], fetching+caching on first use.
  /// Returns null if [seed] is empty or the fetch fails (caller shows a
  /// placeholder).
  Future<File?> avatarFile(String rawSeed) {
    final seed = normalizeAvatarSeed(rawSeed);
    if (seed.isEmpty) return Future<File?>.value();

    final memoed = _memo[seed];
    if (memoed != null) return Future.value(memoed);

    return _inFlight.putIfAbsent(seed, () => _resolve(seed))
      ..whenComplete(() => _inFlight.remove(seed));
  }

  /// Synchronously return the in-memory cached file for [seed], or null if it
  /// hasn't been resolved yet this session. Lets callers paint a cached avatar
  /// on the first frame (no placeholder flash) while [avatarFile] still backs
  /// the genuine first fetch.
  File? cachedFile(String seed) => _memo[normalizeAvatarSeed(seed)];

  Future<File?> _resolve(String seed) async {
    try {
      final file = await _fileForSeed(seed);
      if (await file.exists() && await file.length() > 0) {
        _memo[seed] = file;
        return file;
      }

      final response = await _dio.getUri<List<int>>(
        avatarUrl(seed),
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        AppLogger.warn(_tag, 'empty avatar response for seed $seed');
        return null;
      }

      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      _memo[seed] = file;
      return file;
    } catch (e) {
      AppLogger.warn(_tag, 'avatar fetch failed for seed $seed: $e');
      return null;
    }
  }

  Future<File> _fileForSeed(String seed) async {
    final dir = _cacheDirOverride ?? await getApplicationSupportDirectory();
    return File('${dir.path}/$_cacheSubdir/${_cacheKey(seed)}.svg');
  }

  /// Filename-safe cache key. Account seeds are UUIDs and pass through
  /// unchanged; address/username seeds may carry path-unsafe characters, so
  /// those are replaced and a seed hash is appended to keep distinct seeds
  /// from colliding after sanitisation.
  static String _cacheKey(String seed) {
    final safe = seed.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe == seed) return seed;
    return '${safe}_${avatarSeedHash(seed).toRadixString(16)}';
  }
}
