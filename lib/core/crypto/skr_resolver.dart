import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:solana/dto.dart';
import 'package:solana/solana.dart';

import '../config/environment.dart';
import '../observability/app_logger.dart';
import 'ed25519_curve.dart';

/// Resolves `.skr` names — the AllDomains (ANS) names Seeker phones ship
/// with — to Solana addresses.
///
/// Mirrors Solana Mobile's `@solana-mobile/skr-domain` `resolveSkrDomain`: one
/// `getAccountInfo` of the name account, read straight off mainnet. A name
/// resolves to its registry owner only when:
///
/// 1. the account's parent is the `.skr` TLD (the PDA's seeds already pin it,
///    so this guards a malformed account rather than another TLD);
/// 2. it has not expired — ANS names lapse with no grace period, and a lapsed
///    name can be re-registered by anyone;
/// 3. the owner is on-curve. A name wrapped as an NFT is owned by the Name
///    House NFT-record PDA, which cannot sign; the reference resolver refuses
///    those outright, and this fails closed the same way.
class SkrResolver {
  const SkrResolver._();

  /// AllDomains name service — owns every `.skr` name account.
  static const _ansProgramId = 'ALTNSZ46uaAUU7XUV6awvdorLGqAsPwa9shm7h4uP2FK';

  /// Parent name account of every `.skr` name.
  static const _skrParent = 'F3A8kuikEiu6k2399oSJ1PWfcJYDHqpwoQ2e8psSDNuF';

  static const _hashPrefix = 'ALT Name Service';

  static const _suffix = '.skr';

  /// `discriminator(8) | parentName(32) | owner(32) | class(32) |
  /// expiresAt(8) | createdAt(8) | nonTransferable(1) | padding`.
  static const _headerLen = 200;
  static const _parentOffset = 8;
  static const _ownerOffset = 40;
  static const _expiresAtOffset = 104;

  static final List<int> _zero32 = List<int>.filled(32, 0);

  /// `.skr` names exist only on mainnet — see `SnsResolver._rpcUrl`.
  static final String _rpcUrl = Config.solanaMainnetRpcUrl;

  /// Raw `RpcClient`, so the client-id header is host-gated here rather than
  /// by the shared Dio's interceptor — see `SnsResolver._client`.
  static final RpcClient _client = RpcClient(
    _rpcUrl,
    customHeaders: Config.clientIdHeadersFor(Uri.parse(_rpcUrl)),
  );

  /// Check if an input looks like a .skr name.
  static bool isSkrDomain(String input) {
    final trimmed = input.trim().toLowerCase();
    return trimmed.endsWith(_suffix) && trimmed.length > _suffix.length;
  }

  /// Resolve a .skr name to a Solana address.
  ///
  /// Returns the address, or null if the name does not exist, has expired, or
  /// cannot be resolved safely.
  static Future<String?> resolve(String domain) async {
    try {
      final nameAccount = await deriveNameAccount(domain);
      if (nameAccount == null) return null;

      final account = await _client.getAccountInfo(
        nameAccount.toBase58(),
        encoding: Encoding.base64,
        commitment: Commitment.confirmed,
      );
      final data = account.value?.data;
      return resolveFromAccount(
        data is BinaryAccountData ? data.data : null,
        nowSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
    } catch (e) {
      AppLogger.warn('SkrResolver', 'Failed to resolve $domain: $e');
      return null;
    }
  }

  /// The name account of [domain]. Returns null unless it is a single label:
  /// `.skr` has no subdomains.
  @visibleForTesting
  static Future<Ed25519HDPublicKey?> deriveNameAccount(String domain) async {
    final trimmed = domain.trim().toLowerCase();
    final label = trimmed.endsWith(_suffix)
        ? trimmed.substring(0, trimmed.length - _suffix.length)
        : trimmed;
    if (label.isEmpty || label.contains('.')) return null;

    return Ed25519HDPublicKey.findProgramAddress(
      seeds: [
        sha256.convert(utf8.encode('$_hashPrefix$label')).bytes,
        _zero32,
        Ed25519HDPublicKey.fromBase58(_skrParent).bytes,
      ],
      programId: Ed25519HDPublicKey.fromBase58(_ansProgramId),
    );
  }

  /// The address a name account's [data] resolves to as of [nowSeconds], or
  /// null when it must not be paid.
  @visibleForTesting
  static String? resolveFromAccount(
    List<int>? data, {
    required int nowSeconds,
  }) {
    if (data == null || data.length < _headerLen) return null;

    final parent = data.sublist(_parentOffset, _parentOffset + 32);
    if (Ed25519HDPublicKey(parent).toBase58() != _skrParent) return null;

    // 0 means the name never expires.
    final expiresAt = ByteData.sublistView(
      Uint8List.fromList(data),
      _expiresAtOffset,
      _expiresAtOffset + 8,
    ).getUint64(0, Endian.little);
    if (expiresAt != 0 && expiresAt < nowSeconds) return null;

    final owner = data.sublist(_ownerOffset, _ownerOffset + 32);
    if (!isOnEd25519Curve(owner)) return null;
    return Ed25519HDPublicKey(owner).toBase58();
  }
}
