import 'package:crypto/crypto.dart' as crypto;
import 'package:solana/base58.dart' as base58;

/// Tezos address validation via Base58Check.
///
/// The prefix-only checks in `chain.dart` (`isTezosAddress`) are enough to
/// *route* an address to the Tezos explorer, but sending funds needs a real
/// recipient check: a truncated or mistyped `tz1…` must be rejected before we
/// forge and sign a transfer. This verifies the 3-byte version prefix, the
/// 20-byte public-key-hash / contract-hash payload, and the Base58Check
/// (double-SHA256) checksum — the same guarantees a Tezos node applies when it
/// parses an operation's `source`/`destination`.
///
/// See the Tezos base58 prefix table (`src/lib_crypto/base58.ml`).
enum TezosAddressKind {
  /// `tz1` — Ed25519 implicit account (the only kind mallow derives today).
  tz1,

  /// `tz2` — secp256k1 implicit account.
  tz2,

  /// `tz3` — P-256 implicit account.
  tz3,

  /// `KT1` — originated contract (FA1.2 / FA2 token contracts, multisigs).
  kt1,
}

/// Base58 version-prefix bytes for each supported Tezos address kind. Every
/// payload is a 20-byte hash, so the decoded body is always `prefix(3) +
/// hash(20)` before the 4-byte checksum.
const Map<TezosAddressKind, List<int>> _tezosAddressPrefixes = {
  TezosAddressKind.tz1: [6, 161, 159],
  TezosAddressKind.tz2: [6, 161, 161],
  TezosAddressKind.tz3: [6, 161, 164],
  TezosAddressKind.kt1: [2, 90, 121],
};

const int _tezosHashLength = 20;

/// Classify [address], returning its [TezosAddressKind] when it is a fully
/// valid Tezos address (correct prefix, 20-byte hash, valid checksum), or
/// `null` when it is not a Tezos address or fails verification.
TezosAddressKind? tezosAddressKind(String address) {
  final List<int> decoded;
  try {
    decoded = base58.base58decode(address);
  } catch (_) {
    // Non-base58 characters (e.g. an EVM `0x…` address) — not Tezos.
    return null;
  }

  // prefix(3) + hash(20) + checksum(4)
  if (decoded.length != 3 + _tezosHashLength + 4) return null;

  final body = decoded.sublist(0, decoded.length - 4);
  final checksum = decoded.sublist(decoded.length - 4);
  final expected = crypto.sha256
      .convert(crypto.sha256.convert(body).bytes)
      .bytes
      .sublist(0, 4);
  if (!_bytesEqual(checksum, expected)) return null;

  final prefix = body.sublist(0, 3);
  for (final entry in _tezosAddressPrefixes.entries) {
    if (_bytesEqual(prefix, entry.value)) return entry.key;
  }
  return null;
}

/// True when [address] is any valid Tezos address — an implicit account
/// (`tz1`/`tz2`/`tz3`) or an originated contract (`KT1`). Use this to validate
/// a transfer recipient: XTZ and FA1.2/FA2 tokens can be sent to either.
bool isValidTezosAddress(String address) => tezosAddressKind(address) != null;

/// True when [address] is a valid Tezos implicit account (`tz1`/`tz2`/`tz3`).
/// A token contract origination (`KT1`) is not a valid transaction *fee payer*
/// or implicit destination, so flows that require an implicit account (e.g. the
/// active wallet) should use this stricter check.
bool isValidTezosImplicitAddress(String address) {
  final kind = tezosAddressKind(address);
  return kind != null && kind != TezosAddressKind.kt1;
}

/// The token contract + FA2 `token_id` a Tezos FA holding is identified by.
///
/// `GET /v2/tezos/balances` reuses the EVM holding shape, so a Tezos FA row
/// carries both halves of its identity in the single `contractAddress` field
/// (mapped onto `TokenBalance.mint`): the bare `KT1…` when the token id is 0 —
/// the FA1.2 case and the common FA2 one — and `{KT1…}-{tokenId}` for an FA2
/// multitoken. Base58 has no `-`, so the split is unambiguous.
class TezosTokenRef {
  const TezosTokenRef({required this.contract, required this.tokenId});

  /// The `KT1…` token contract, case-exact. Base58Check is case-*significant*:
  /// a lower-cased `KT1` no longer decodes, so it can never be forged against.
  final String contract;

  /// FA2 `token_id`; always zero for FA1.2, which has no token ids.
  final BigInt tokenId;

  @override
  bool operator ==(Object other) =>
      other is TezosTokenRef &&
      other.contract == contract &&
      other.tokenId == tokenId;

  @override
  int get hashCode => Object.hash(contract, tokenId);

  @override
  String toString() => tokenId == BigInt.zero ? contract : '$contract-$tokenId';
}

/// Parse a Tezos FA holding's [mint] into its contract + token id, or null when
/// [mint] is not one — the native-XTZ sentinel, a Solana/EVM mint, or a `KT1`
/// that fails Base58Check (notably a row cached before the balance mapper
/// stopped lower-casing Tezos contracts, which is unrecoverable from the string
/// alone and has to come back from the network).
TezosTokenRef? parseTezosTokenRef(String mint) {
  final trimmed = mint.trim();
  if (trimmed.isEmpty) return null;

  final dash = trimmed.lastIndexOf('-');
  final contract = dash == -1 ? trimmed : trimmed.substring(0, dash);
  final idPart = dash == -1 ? '0' : trimmed.substring(dash + 1);

  if (tezosAddressKind(contract) != TezosAddressKind.kt1) return null;
  final tokenId = BigInt.tryParse(idPart);
  if (tokenId == null || tokenId.isNegative) return null;
  return TezosTokenRef(contract: contract, tokenId: tokenId);
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
