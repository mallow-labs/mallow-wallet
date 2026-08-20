import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:solana/dto.dart';
import 'package:solana/solana.dart';

import '../config/environment.dart';
import '../observability/app_logger.dart';

/// Outcome of the offline half of SNS resolution — everything that can be
/// decided from the four fetched accounts alone.
sealed class SnsResolution {
  const SnsResolution();
}

/// The domain resolves to [address].
class SnsResolvedAddress extends SnsResolution {
  const SnsResolvedAddress(this.address);

  final String address;
}

/// The domain is wrapped as an NFT: its registry owner is the tokenizer PDA,
/// so the real owner is whoever currently holds [nftMint].
class SnsTokenizedDomain extends SnsResolution {
  const SnsTokenizedDomain(this.nftMint);

  final String nftMint;
}

/// The domain does not exist, or resolves to something we must not pay
/// (unverified record, PDA owner). Fails closed — never falls back to a guess.
class SnsUnresolvable extends SnsResolution {
  const SnsUnresolvable();
}

/// The four accounts SNS resolution reads for a domain.
@immutable
class SnsAccountKeys {
  const SnsAccountKeys({
    required this.registry,
    required this.nftRecord,
    required this.solRecordV1,
    required this.solRecordV2,
  });

  /// The domain's own name-registry account.
  final Ed25519HDPublicKey registry;

  /// Name-tokenizer NFT record for the domain (present only if it was ever
  /// wrapped as an NFT).
  final Ed25519HDPublicKey nftRecord;

  /// Legacy signed `SOL` record.
  final Ed25519HDPublicKey solRecordV1;

  /// SNS-IP-5 `SOL` record.
  final Ed25519HDPublicKey solRecordV2;

  List<String> get all => [
    nftRecord.toBase58(),
    solRecordV1.toBase58(),
    solRecordV2.toBase58(),
    registry.toBase58(),
  ];
}

/// Resolves `.sol` SNS (Solana Name Service) domains to Solana addresses.
///
/// Reads the registry straight off mainnet through the mallow RPC proxy —
/// there is no third-party resolution API in the path. (The Bonfida
/// `sns-sdk-proxy` worker this used to call went dark and 404s every request,
/// which made every lookup fail.)
///
/// Mirrors the reference `@bonfida/sns-sdk` `resolve()` order, because each
/// step exists to stop a send going to the wrong place:
///
/// 1. **Tokenized domain** — a domain wrapped as an NFT has its registry owner
///    set to the tokenizer's NFT-record PDA, which is *off-curve and unspendable*.
///    ~24k mainnet domains are in this state, so this check is what stops a
///    transfer being burned.
/// 2. **SNS-IP-5 `SOL` record (V2)** — honoured only when both validations are
///    Solana, the staleness id still matches the current registry owner (i.e.
///    the record was not orphaned by a domain transfer), and the right-of-
///    association id matches the content.
/// 3. **Legacy `SOL` record (V1)** — honoured only when its ed25519 signature
///    verifies against the *current* registry owner. Real records routinely
///    fail this after the domain changes hands; those fall through by design.
/// 4. **Registry owner** — but only if it is on-curve. An off-curve owner is a
///    program address that cannot sign, so resolution fails instead.
class SnsResolver {
  const SnsResolver._();

  /// SPL Name Service — owns every `.sol` registry account.
  static const _nameProgramId = 'namesLPneVptA9Z5rqUDD9tMTWEJwofgaYwp8cawRkX';

  /// The `.sol` TLD account, parent of every second-level domain.
  static const _rootDomainAccount =
      '58PwtjSDuFHuUkYjH9BYnnQKHfwo9reZhC2zMJv9JPkx';

  /// SNS Name Tokenizer — the program that wraps domains as NFTs.
  static const _nameTokenizerId = 'nftD3vbNkNqfj2Sd3HZwbpw4BxxKWr4AjGb9X38JeZk';

  /// Name class of every SNS-IP-5 record V2 account.
  static const _recordsCentralState =
      '2pMnqHvei2N5oDcVGCRdZx48gqti199wr5CsyTTafsbo';

  static const _hashPrefix = 'SPL Name Service';

  /// `parentName(32) | owner(32) | class(32)` — every name account starts here.
  static const _headerLen = 96;

  /// `NftRecord::Tag::ActiveRecord`. Any other tag means the domain was
  /// unwrapped and the registry owner is authoritative again.
  static const _nftTagActiveRecord = 2;

  /// `Validation::Solana` — the only validation kind we accept on a V2 record.
  static const _validationSolana = 1;

  /// Byte length of a `Validation::Solana` id.
  static const _validationSolanaLen = 32;

  static final List<int> _zero32 = List<int>.filled(32, 0);

  /// `.sol` domains only exist on mainnet, so resolution is pinned there even
  /// on devnet builds — the same reasoning as `SolanaRpcService.mainnet`.
  static final String _rpcUrl = Config.solanaMainnetRpcUrl;

  /// Raw `RpcClient`, so the client-id header is host-gated here rather than
  /// by the shared Dio's interceptor. The mainnet endpoint may well be a
  /// public node, which must not receive the credential.
  static final RpcClient _client = RpcClient(
    _rpcUrl,
    customHeaders: Config.clientIdHeadersFor(Uri.parse(_rpcUrl)),
  );

  /// Check if an input looks like a .sol domain.
  static bool isSolDomain(String input) {
    final trimmed = input.trim().toLowerCase();
    return trimmed.endsWith('.sol') && trimmed.length > 4;
  }

  /// Resolve a .sol domain to a Solana address.
  ///
  /// Returns the address, or null if the domain does not exist or cannot be
  /// resolved safely.
  static Future<String?> resolve(String domain) async {
    try {
      final keys = await deriveAccountKeys(domain);
      if (keys == null) return null;

      final accounts = await _client.getMultipleAccounts(
        keys.all,
        encoding: Encoding.base64,
        commitment: Commitment.confirmed,
      );
      final values = accounts.value;
      if (values.length != 4) return null;

      final resolution = await resolveFromAccounts(
        keys: keys,
        nftRecord: _binaryData(values[0]),
        solRecordV1: _binaryData(values[1]),
        solRecordV2: _binaryData(values[2]),
        registry: _binaryData(values[3]),
      );

      return switch (resolution) {
        SnsResolvedAddress(:final address) => address,
        SnsTokenizedDomain(:final nftMint) => await _nftHolder(nftMint),
        SnsUnresolvable() => null,
      };
    } catch (e) {
      AppLogger.warn('SnsResolver', 'Failed to resolve $domain: $e');
      return null;
    }
  }

  /// Derive the accounts resolution reads for [domain]. Returns null when the
  /// domain is malformed (empty label, or nested deeper than one subdomain).
  @visibleForTesting
  static Future<SnsAccountKeys?> deriveAccountKeys(String domain) async {
    final trimmed = domain.trim().toLowerCase();
    final name = trimmed.endsWith('.sol')
        ? trimmed.substring(0, trimmed.length - 4)
        : trimmed;

    final labels = name.split('.');
    if (labels.length > 2 || labels.any((label) => label.isEmpty)) return null;

    final root = Ed25519HDPublicKey.fromBase58(_rootDomainAccount);
    var registry = await _nameAccount(_hashName(labels.last), parent: root);
    if (labels.length == 2) {
      // Subdomains hang off the parent domain under a `\0` label prefix.
      registry = await _nameAccount(
        _hashName('\u0000${labels.first}'),
        parent: registry,
      );
    }

    return SnsAccountKeys(
      registry: registry,
      nftRecord: await Ed25519HDPublicKey.findProgramAddress(
        seeds: [utf8.encode('nft_record'), registry.bytes],
        programId: Ed25519HDPublicKey.fromBase58(_nameTokenizerId),
      ),
      solRecordV1: await _nameAccount(_hashName('\u0001SOL'), parent: registry),
      solRecordV2: await _nameAccount(
        _hashName('\u0002SOL'),
        parent: registry,
        nameClass: Ed25519HDPublicKey.fromBase58(_recordsCentralState),
      ),
    );
  }

  /// Pick the address [registry] and its records resolve to. Pure apart from
  /// the ed25519 verification of a V1 record.
  @visibleForTesting
  static Future<SnsResolution> resolveFromAccounts({
    required SnsAccountKeys keys,
    required List<int>? registry,
    required List<int>? nftRecord,
    required List<int>? solRecordV1,
    required List<int>? solRecordV2,
  }) async {
    // The domain must exist. Records without a registry are meaningless.
    if (registry == null || registry.length < _headerLen) {
      return const SnsUnresolvable();
    }
    final owner = registry.sublist(32, 64);

    // 1. Tokenized: the NFT holder owns the domain, not the registry owner.
    if (nftRecord != null && nftRecord.length >= 98) {
      if (nftRecord[0] == _nftTagActiveRecord) {
        return SnsTokenizedDomain(
          Ed25519HDPublicKey(nftRecord.sublist(66, 98)).toBase58(),
        );
      }
    }

    // 2. SNS-IP-5 SOL record.
    final v2 = _resolveRecordV2(solRecordV2, owner);
    if (v2 != null) return v2;

    // 3. Legacy signed SOL record.
    if (solRecordV1 != null && solRecordV1.length >= _headerLen + 96) {
      final content = solRecordV1.sublist(_headerLen, _headerLen + 32);
      final signature = solRecordV1.sublist(_headerLen + 32, _headerLen + 96);
      // The signed payload is the *hex string* of `content | recordKey`, not
      // those bytes — signing the raw bytes verifies as invalid.
      final message = utf8.encode(
        _hex([...content, ...keys.solRecordV1.bytes]),
      );
      final valid = await verifySignature(
        message: message,
        signature: signature,
        publicKey: Ed25519HDPublicKey(owner),
      );
      if (valid) {
        return SnsResolvedAddress(Ed25519HDPublicKey(content).toBase58());
      }
    }

    // 4. Registry owner — only if it can actually sign for the funds.
    if (!_isOnCurve(owner)) return const SnsUnresolvable();
    return SnsResolvedAddress(Ed25519HDPublicKey(owner).toBase58());
  }

  /// Resolve an SNS-IP-5 `SOL` record. Returns null to fall through to the
  /// older resolution steps, or an [SnsUnresolvable] when the record exists but
  /// must not be trusted.
  static SnsResolution? _resolveRecordV2(List<int>? account, List<int> owner) {
    if (account == null || account.length < _headerLen + 8) return null;

    final body = Uint8List.fromList(account.sublist(_headerLen));
    final header = ByteData.sublistView(body, 0, 8);
    final stalenessValidation = header.getUint16(0, Endian.little);
    final roaValidation = header.getUint16(2, Endian.little);

    // Only Solana-validated records carry the ids we check below; anything
    // else (unset, Ethereum, unverified) is not proof of where to send.
    if (stalenessValidation != _validationSolana ||
        roaValidation != _validationSolana) {
      return const SnsUnresolvable();
    }

    const idsEnd = 8 + 2 * _validationSolanaLen;
    if (body.length < idsEnd + 32) return const SnsUnresolvable();

    final stalenessId = body.sublist(8, 8 + _validationSolanaLen);
    final roaId = body.sublist(8 + _validationSolanaLen, idsEnd);
    final content = body.sublist(idsEnd);
    if (content.length != 32) return const SnsUnresolvable();

    // Stale record: the domain changed hands after this was written, so it says
    // nothing about the current owner's intent. Fall through.
    if (!_bytesEqual(stalenessId, owner)) return null;

    // Right of association: the destination must have agreed to be pointed at.
    if (!_bytesEqual(roaId, content)) return const SnsUnresolvable();

    return SnsResolvedAddress(Ed25519HDPublicKey(content).toBase58());
  }

  /// Current holder of a tokenized domain's NFT.
  static Future<String?> _nftHolder(String mint) async {
    final largest = await _client.getTokenLargestAccounts(mint);
    final accounts = largest.value;
    if (accounts.isEmpty) return null;

    // A domain NFT has supply 1; anything else means it is not held.
    final top = accounts.first;
    if (top.amount != '1') return null;

    final account = await _client.getAccountInfo(
      top.address,
      encoding: Encoding.base64,
      commitment: Commitment.confirmed,
    );
    final data = _binaryData(account.value);
    // SPL token account: mint(32) | owner(32) | amount(8) | ...
    if (data == null || data.length < 64) return null;
    return Ed25519HDPublicKey(data.sublist(32, 64)).toBase58();
  }

  static List<int>? _binaryData(Account? account) {
    final data = account?.data;
    return data is BinaryAccountData ? data.data : null;
  }

  static List<int> _hashName(String name) =>
      sha256.convert(utf8.encode('$_hashPrefix$name')).bytes;

  static Future<Ed25519HDPublicKey> _nameAccount(
    List<int> hashedName, {
    required Ed25519HDPublicKey parent,
    Ed25519HDPublicKey? nameClass,
  }) => Ed25519HDPublicKey.findProgramAddress(
    seeds: [hashedName, nameClass?.bytes ?? _zero32, parent.bytes],
    programId: Ed25519HDPublicKey.fromBase58(_nameProgramId),
  );

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static final BigInt _fieldP = (BigInt.one << 255) - BigInt.from(19);
  static final BigInt _curveD =
      (BigInt.from(-121665) * BigInt.from(121666).modInverse(_fieldP)) %
      _fieldP;

  /// Whether [bytes] decodes to a point on the ed25519 curve — i.e. whether it
  /// is a public key someone can hold the private key for, as opposed to a
  /// program-derived address. Sending to a PDA is unrecoverable, so this gates
  /// step 4 of [resolveFromAccounts].
  static bool _isOnCurve(List<int> bytes) {
    if (bytes.length != 32) return false;

    var y = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      y = (y << 8) | BigInt.from(bytes[i]);
    }
    final sign = (y >> 255) & BigInt.one;
    y &= (BigInt.one << 255) - BigInt.one;
    if (y >= _fieldP) return false;

    // Recover x from the curve equation: x² = (y² - 1) / (d·y² + 1).
    final y2 = (y * y) % _fieldP;
    final u = (y2 - BigInt.one) % _fieldP;
    final v = (_curveD * y2 + BigInt.one) % _fieldP;
    final uv3 = (u * v.modPow(BigInt.from(3), _fieldP)) % _fieldP;
    final uv7 = (u * v.modPow(BigInt.from(7), _fieldP)) % _fieldP;
    var x =
        (uv3 *
            uv7.modPow((_fieldP - BigInt.from(5)) ~/ BigInt.from(8), _fieldP)) %
        _fieldP;

    final vxx = (v * x % _fieldP * x) % _fieldP;
    if ((vxx - u) % _fieldP != BigInt.zero) {
      if ((vxx + u) % _fieldP != BigInt.zero) return false;
      // x is off by a factor of sqrt(-1).
      x =
          (x *
              BigInt.two.modPow(
                (_fieldP - BigInt.one) ~/ BigInt.from(4),
                _fieldP,
              )) %
          _fieldP;
    }
    if (x == BigInt.zero && sign == BigInt.one) return false;
    return true;
  }
}
