import '../../core/crypto/derivation.dart';
import '../../core/security/security_utils.dart';
import 'tezos_address.dart';

/// Supported blockchains — the single `Chain` type for the app.
///
/// Solana is fully transactional; Ethereum (native ETH + ERC-20) and Tezos
/// (native XTZ) support client-side sends (see derivation/session specs).
///
/// The enum's [toDbString] values double as the wire values, which mirror the
/// webapp's `Chain` enum in the web client's shared chain type. Wire and
/// DB data arrives as `String` (e.g. `NftDetail.chain`), so convert at the
/// boundary — [fromDbString] for trusted DB rows and [tryParse] for wire data,
/// which reports an unmodelled chain as null instead of silently claiming it is
/// Solana.
enum Chain {
  solana,
  ethereum,
  tezos;

  /// Database / wire string representation.
  String toDbString() => switch (this) {
    Chain.solana => 'solana',
    Chain.ethereum => 'ethereum',
    Chain.tezos => 'tezos',
  };

  /// Parse from a database/wire string, defaulting to Solana for unknown
  /// values. Suited to DB columns the app itself wrote; prefer [tryParse] for
  /// server data, where an unrecognised chain is real and must not be mistaken
  /// for Solana.
  static Chain fromDbString(String value) => tryParse(value) ?? Chain.solana;

  /// Strict parse of a wire/DB chain value — null for null, empty, or any chain
  /// this app does not model.
  static Chain? tryParse(String? value) => switch (value) {
    'solana' => Chain.solana,
    'ethereum' => Chain.ethereum,
    'tezos' => Chain.tezos,
    _ => null,
  };

  /// Best-effort chain inference from an address shape: EVM (`0x…`) and Tezos
  /// (`tz1/2/3`, `KT1`) have recognizable prefixes; everything else (base58)
  /// defaults to Solana.
  static Chain fromAddress(String address) {
    if (isEthereumAddress(address)) return Chain.ethereum;
    if (isTezosAddress(address)) return Chain.tezos;
    return Chain.solana;
  }

  /// Whether [address] is a well-formed address on this chain.
  ///
  /// Uses the same validators the recipient fields gate on, **not**
  /// [Chain.fromAddress]: that one treats every non-EVM, non-Tezos string as
  /// Solana, so it would wave through anything.
  ///
  /// 🛑 Not enough on its own to accept an EVM **recipient** the user typed —
  /// the Ethereum arm is [isEthereumAddress], which is shape-only and verifies
  /// no EIP-55 checksum. Those sites call [evmRecipientError] instead and are
  /// deliberately stricter than this; do not collapse them into this check.
  bool isValidAddress(String address) => switch (this) {
    Chain.solana => SecurityUtils.isValidSolanaAddress(address),
    Chain.ethereum => isEthereumAddress(address),
    Chain.tezos => isValidTezosAddress(address),
  };

  /// Human-readable name of the chain (and its Ledger app).
  String get label => switch (this) {
    Chain.solana => 'Solana',
    Chain.ethereum => 'Ethereum',
    Chain.tezos => 'Tezos',
  };

  /// Asset path for this chain's badge icon, used to overlay a chain badge on
  /// non-Solana token logos in the portfolio. See [paddedIconAsset] for the
  /// variant that sizes consistently beside the other two marks.
  String get iconAsset => switch (this) {
    Chain.solana => 'assets/icons/solana.svg',
    Chain.ethereum => 'assets/icons/ethereum.svg',
    Chain.tezos => 'assets/icons/tezos.svg',
  };

  /// Asset path for this chain's logo when the three chains are rendered at a
  /// matched size (the receive sheets).
  ///
  /// Solana differs from [iconAsset] here: `solana_padded.svg` pads the mark to
  /// the same ~58% of its square viewBox as ethereum/tezos, whereas the raw
  /// `solana.svg` is a full-bleed 15×11 mark that renders ~1.7× larger at an
  /// equal box size.
  String get paddedIconAsset => switch (this) {
    Chain.solana => 'assets/icons/solana_padded.svg',
    Chain.ethereum || Chain.tezos => iconAsset,
  };
}

/// Display label for a raw wire chain value, for surfaces that render whatever
/// the server sent. Matches the webapp's `ChainLabel` map: falls back to the
/// raw value when unknown so the row never renders empty, and to Solana when
/// absent. Prefer [Chain.label] wherever the chain is already typed.
String chainLabel(String? chain) =>
    Chain.tryParse(chain)?.label ?? chain ?? Chain.solana.label;

/// Compiled once: [isEthereumAddress] is called per address inside profile /
/// session loops, and Dart recompiles a `RegExp` literal on every evaluation.
final RegExp _ethereumAddressPattern = RegExp(r'^0x[a-fA-F0-9]{40}$');

/// True when [address] is a bare Ethereum address (`0x` + 40 hex chars).
///
/// Shape only — deliberately case-insensitive, because it classifies addresses
/// from every source (API rows come back lowercased, local wallets are EIP-55
/// checksummed). Do NOT use it to validate a **recipient** the user typed:
/// see [evmRecipientError].
bool isEthereumAddress(String address) =>
    _ethereumAddressPattern.hasMatch(address);

/// User-facing copy for a mixed-case EVM address whose EIP-55 checksum does
/// not match. Kept as a constant so the form gate and the tests agree.
const String kEvmChecksumFailedMessage =
    'Checksum failed — this address may be mistyped';

/// The reason [address] must not be used as an EVM **recipient**, or null when
/// it is safe to send to.
///
/// [isEthereumAddress] alone is not enough for a recipient. It is the only
/// check on the ETH send path and nothing downstream can catch a typo: the
/// calldata assertion compares the backend's calldata against the same typed
/// string (a typo matches itself) and the Alchemy simulation only checks the
/// amount. A single mistyped hex character is unrecoverable loss.
///
/// EIP-55 semantics, matching ethers/viem:
///  * all-lowercase or all-uppercase hex carries no checksum information —
///    accept it, since rejecting would break every lowercased address the
///    ecosystem (and our own backend) hands out;
///  * mixed case **is** a checksum over `keccak256(lowercase hex)` — require
///    an exact match, which is what catches a mistyped character.
///
/// The checksum is re-derived through
/// `MultiChainDerivation.checksumEthereumAddress` — the same keccak path that
/// derives our own EVM addresses — from the lowercased input.
///
/// 🛑 This function is the ONLY checksum enforcement left; there is no upstream
/// backstop. web3dart 2.x's `EthereumAddress.fromHex` threw on a mixed-case
/// address whose EIP-55 checksum did not match, even with `enforceEip55: false`.
/// web3dart 3.x re-homed that type in `package:wallet`, whose version only
/// checks the checksum when `enforceEip55: true` (it defaults to false) and
/// whose shape regex is missing its trailing `$`, so it also accepts a valid
/// address with hex garbage appended — building a >20-byte address, guarded
/// only by an `assert` that release builds strip. Both are verified-accepted
/// upstream behaviours, not hypotheticals.
///
/// So neither [isEthereumAddress] nor this function may be reimplemented in
/// terms of `EthereumAddress.fromHex`, and the checksum/length cases in
/// `test/shared/utils/chain_test.dart` are the regression net for both.
String? evmRecipientError(String address) {
  if (!isEthereumAddress(address)) return 'Invalid Ethereum address';
  final hex = address.substring(2);
  if (hex == hex.toLowerCase() || hex == hex.toUpperCase()) return null;
  final expected = MultiChainDerivation.checksumEthereumAddress(
    address.toLowerCase(),
  );
  return address == expected ? null : kEvmChecksumFailedMessage;
}

/// Normalise an [address] for use as a backend owner/address query key.
///
/// EVM addresses are derived and stored EIP-55 **checksummed** (mixed case, see
/// `derivation.dart`), but the backend stores and matches owners **lowercased**
/// — a checksummed address sent verbatim never matches, so owner-keyed reads
/// (e.g. `/v2/portfolio/*`) silently return nothing. Lowercase EVM addresses;
/// Solana (base58) and Tezos addresses are case-sensitive and pass through
/// untouched.
String apiOwnerAddress(String address) =>
    isEthereumAddress(address) ? address.toLowerCase() : address;

/// True when [address] is a Tezos account/contract address
/// (`tz1`/`tz2`/`tz3` implicit accounts or `KT1` originated contracts).
bool isTezosAddress(String address) =>
    address.startsWith('tz1') ||
    address.startsWith('tz2') ||
    address.startsWith('tz3') ||
    address.startsWith('KT1');

/// True when [mintAccount] is a full Ethereum NFT id of the form
/// `<contract>-<tokenId>` (e.g. `0xabc…-42`).
bool isEthereumAsset(String mintAccount) =>
    RegExp(r'^0x[a-fA-F0-9]{40}-\d+$').hasMatch(mintAccount);

/// True when [address] is a Tezos asset/contract address (starts with `KT1`).
bool isTezosAsset(String address) => address.startsWith('KT1');

/// True when the mint account shape or the [chain] field indicate this
/// artwork lives on Ethereum or Tezos rather than Solana. Mirrors the
/// webapp's `ArtworkDetails` branch.
bool isEvmOrTezosArtwork({required String mintAccount, String? chain}) {
  final parsed = Chain.tryParse(chain);
  if (parsed == Chain.ethereum || parsed == Chain.tezos) return true;
  if (isTezosAsset(mintAccount)) return true;
  final parts = mintAccount.split('-');
  return parts.isNotEmpty && isEthereumAddress(parts.first);
}

/// True when the mint account shape or the [chain] field indicate this artwork
/// lives on Ethereum. The single routing predicate for the EVM (ERC-721/1155)
/// artwork path — the transfer flow's kill-switch cell, its recipient
/// validation/resolution and the DAS-lookup bypass all branch on it, so they
/// must never drift apart.
///
/// [chain] is the artwork model's raw wire chain value (`Chain.toDbString()`),
/// null when the model didn't carry one and unparseable when the server names a
/// chain the app doesn't model — the mint-account shape is the only signal in
/// both cases.
bool isEthereumArtwork({required String mintAccount, String? chain}) =>
    Chain.tryParse(chain) == Chain.ethereum || isEthereumAsset(mintAccount);
