import 'dart:convert';

import 'package:bip32/bip32.dart' as bip32;
import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart' as crypto;
import 'package:ed25519_hd_key/ed25519_hd_key.dart';
import 'package:flutter/foundation.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:pointycastle/digests/blake2b.dart';
import 'package:solana/base58.dart' as base58;
import 'package:solana/solana.dart';
// web3dart 3.x folded its old `crypto.dart` into the root library, which now
// also exports bytesToHex/hexToBytes — hide them so the tezos_forge versions
// below stay the ones in scope. EthereumAddress/EtherAmount moved out to
// package:wallet, which web3dart imports but does not re-export.
import 'package:wallet/wallet.dart' show EthereumAddress;
import 'package:web3dart/web3dart.dart' hide bytesToHex, hexToBytes;

import 'tezos_forge.dart' show bytesToHex, hexToBytes;

/// Payload for [_batchDeriveSolanaInIsolate]. Top-level so [compute] can
/// ferry it across the isolate boundary.
class _BatchDeriveTask {
  const _BatchDeriveTask({required this.mnemonic, required this.indices});
  final String mnemonic;
  final List<int> indices;
}

/// Runs the heavy BIP39 PBKDF2-2048 expansion once, then derives one child
/// per requested account index. Intended to be called via [compute] so the
/// crypto work doesn't stutter the UI isolate.
Future<List<String>> _batchDeriveSolanaInIsolate(_BatchDeriveTask task) async {
  final seed = bip39.mnemonicToSeed(task.mnemonic);
  final addresses = <String>[];
  for (final index in task.indices) {
    final keypair = await Ed25519HDKeyPair.fromSeedWithHdPath(
      seed: seed,
      hdPath: "m/44'/501'/$index'/0'",
    );
    addresses.add(keypair.address);
  }
  return addresses;
}

/// Per-index addresses across chains, for the import-by-account picker.
///
/// One instance per derivation index. [solanaLegacy] / [solanaRoot] are only
/// populated when the legacy-derivation toggle is on (see import spec); root is
/// index-less so it appears only on index 0. [ethereum] / [tezos] are null when
/// the caller switched that chain off — the address was never derived, so it is
/// absent rather than empty.
@immutable
class AccountAddresses {
  const AccountAddresses({
    required this.index,
    required this.solanaStandard,
    this.ethereum,
    this.tezos,
    this.solanaLegacy,
    this.solanaRoot,
  });

  final int index;
  final String solanaStandard;
  final String? ethereum;
  final String? tezos;
  final String? solanaLegacy;
  final String? solanaRoot;
}

class _MultiChainTask {
  const _MultiChainTask({
    required this.mnemonic,
    required this.indices,
    required this.includeLegacyPaths,
    required this.deriveEthereum,
    required this.deriveTezos,
  });
  final String mnemonic;
  final List<int> indices;
  final bool includeLegacyPaths;
  final bool deriveEthereum;
  final bool deriveTezos;
}

/// Derives addresses for all chains at the requested indices, expanding the
/// BIP39 seed once. Top-level for [compute].
Future<List<AccountAddresses>> _batchDeriveMultiChainInIsolate(
  _MultiChainTask task,
) async {
  final seed = bip39.mnemonicToSeed(task.mnemonic);
  // Every Ethereum index hangs off the same chain node, so walk to it once.
  // Deriving the full path per index instead re-ran two secp256k1 point
  // multiplications per account, which dominated the batch.
  final ethChain = task.deriveEthereum
      ? bip32.BIP32.fromSeed(seed).derivePath(_ethChainPath)
      : null;
  final result = <AccountAddresses>[];

  for (final index in task.indices) {
    final solStandard = await Ed25519HDKeyPair.fromSeedWithHdPath(
      seed: seed,
      hdPath: "m/44'/501'/$index'/0'",
    );
    final eth = ethChain == null
        ? null
        : _ethAddressFromChainNode(ethChain, index);
    final tez = task.deriveTezos
        ? await _tezosAddressFromSeed(seed, index)
        : null;

    String? solLegacy;
    String? solRoot;
    if (task.includeLegacyPaths) {
      solLegacy = (await Ed25519HDKeyPair.fromSeedWithHdPath(
        seed: seed,
        hdPath: "m/44'/501'/$index'",
      )).address;
      // Root path is index-less — only meaningful once, on index 0.
      if (index == 0) {
        solRoot = (await Ed25519HDKeyPair.fromSeedWithHdPath(
          seed: seed,
          hdPath: "m/44'/501'",
        )).address;
      }
    }

    result.add(
      AccountAddresses(
        index: index,
        solanaStandard: solStandard.address,
        ethereum: eth,
        tezos: tez,
        solanaLegacy: solLegacy,
        solanaRoot: solRoot,
      ),
    );
  }
  return result;
}

/// BIP44 chain node every Ethereum account index descends from. Shared across a
/// batch so only the final `.derive(index)` step is per-index.
const _ethChainPath = "m/44'/60'/0'/0";

/// EIP-55 Ethereum address at [index] from a shared secp256k1 BIP32 node at
/// [_ethChainPath].
String _ethAddressFromChainNode(bip32.BIP32 chain, int index) {
  final node = chain.derive(index);
  final priv = node.privateKey;
  if (priv == null) {
    throw StateError('Failed to derive Ethereum private key at index $index');
  }
  return EthPrivateKey(priv).address.eip55With0x;
}

/// tz1 (Ed25519) Tezos address at [index] from a shared BIP39 seed.
///
/// SLIP-0010 ed25519 derivation at m/44'/1729'/[index]'/0', then
/// Base58Check(prefix `tz1` + Blake2b-160(pubkey)).
Future<String> _tezosAddressFromSeed(List<int> seed, int index) async {
  final data = await ED25519_HD_KEY.derivePath("m/44'/1729'/$index'/0'", seed);
  final pubKey = await ED25519_HD_KEY.getPublicKey(data.key, false);
  return MultiChainDerivation.tezosAddressFromPublicKey(
    Uint8List.fromList(pubKey),
  );
}

/// Bitcoin-style Base58Check: base58(prefix+payload + sha256d[:4]).
String _base58CheckEncode(List<int> prefix, List<int> payload) {
  final data = <int>[...prefix, ...payload];
  final checksum = crypto.sha256
      .convert(crypto.sha256.convert(data).bytes)
      .bytes
      .sublist(0, 4);
  return base58.base58encode(Uint8List.fromList([...data, ...checksum]));
}

/// Multi-chain key derivation utilities.
///
/// Handles BIP44 HD key derivation for supported blockchains:
///  - Solana (Ed25519) — full support, incl. legacy/root derivation schemes.
///  - Ethereum (secp256k1) — derive, message signing (EIP-191), tx signing.
///  - Tezos (Ed25519, tz1) — derive + display only.
class MultiChainDerivation {
  const MultiChainDerivation._();

  /// Solana derivation path (BIP44 standard).
  /// m / purpose' / coin_type' / account' / change'
  /// 501 is the coin type for Solana
  static const solanaPath = "m/44'/501'/0'/0'";

  /// Ethereum derivation path (for future use).
  /// m / purpose' / coin_type' / account' / change / address_index
  /// 60 is the coin type for Ethereum
  static const ethereumPath = "m/44'/60'/0'/0/0";

  /// Derive a Solana keypair from a mnemonic.
  ///
  /// Uses Ed25519 curve with BIP44 derivation.
  /// Path: m/44'/501'/0'/0' (matches Phantom, Solflare, and browser wallets).
  /// Returns an [Ed25519HDKeyPair] that can sign transactions.
  static Future<Ed25519HDKeyPair> deriveSolana(String mnemonic) {
    return Ed25519HDKeyPair.fromMnemonic(
      mnemonic.trim().toLowerCase(),
      account: 0,
      change: 0,
    );
  }

  /// Derive a Solana keypair with custom account index.
  ///
  /// Useful for deriving multiple addresses from the same seed.
  /// Path: m/44'/501'/[account]'/0' (matches Phantom, Solflare, and browser wallets).
  static Future<Ed25519HDKeyPair> deriveSolanaWithAccount(
    String mnemonic, {
    required int account,
  }) {
    return Ed25519HDKeyPair.fromMnemonic(
      mnemonic.trim().toLowerCase(),
      account: account,
      change: 0,
    );
  }

  /// Get the Solana address from a mnemonic without holding the keypair.
  ///
  /// SECURITY: This still derives the full keypair internally.
  /// The keypair goes out of scope after this method returns.
  static Future<String> getSolanaAddress(String mnemonic) async {
    final keypair = await deriveSolana(mnemonic);
    return keypair.address;
  }

  /// Get the Solana public key from a mnemonic.
  static Future<Ed25519HDPublicKey> getSolanaPublicKey(String mnemonic) async {
    final keypair = await deriveSolana(mnemonic);
    return keypair.publicKey;
  }

  /// Derive multiple Solana addresses from the same seed.
  ///
  /// Useful for account discovery or supporting multiple accounts.
  static Future<List<String>> deriveSolanaAddresses(
    String mnemonic, {
    int count = 5,
  }) async {
    final addresses = <String>[];
    for (var i = 0; i < count; i++) {
      final keypair = await deriveSolanaWithAccount(mnemonic, account: i);
      addresses.add(keypair.address);
    }
    return addresses;
  }

  /// Get the Solana address at a specific account index.
  ///
  /// Path: m/44'/501'/[accountIndex]'/0'
  /// Used for multi-wallet support where user can switch between derived accounts.
  static Future<String> getSolanaAddressAtIndex(
    String mnemonic,
    int accountIndex,
  ) async {
    final keypair = await deriveSolanaWithAccount(
      mnemonic,
      account: accountIndex,
    );
    return keypair.address;
  }

  /// Derive Solana addresses for many account indices off the main isolate,
  /// reusing a single PBKDF2-2048 seed expansion. Use this when batch-deriving
  /// (e.g. HD picker, multi-wallet import) — avoids freezing the UI.
  static Future<List<String>> getSolanaAddressesAtIndices(
    String mnemonic,
    List<int> indices,
  ) {
    return compute(
      _batchDeriveSolanaInIsolate,
      _BatchDeriveTask(
        mnemonic: mnemonic.trim().toLowerCase(),
        indices: indices,
      ),
    );
  }

  /// Solana HD path for a given account [index] + derivation [scheme].
  /// Root is index-less.
  static String solanaHdPath(int index, SolanaDerivationScheme scheme) =>
      switch (scheme) {
        SolanaDerivationScheme.standard => "m/44'/501'/$index'/0'",
        SolanaDerivationScheme.legacy => "m/44'/501'/$index'",
        SolanaDerivationScheme.root => "m/44'/501'",
      };

  /// Solana keypair at [index] for a specific derivation [scheme]
  /// (standard / legacy / root). Used to sign with legacy-path wallets — the
  /// keypair must match the address stored at import (see [solanaHdPath]).
  static Future<Ed25519HDKeyPair> deriveSolanaWithScheme(
    String mnemonic,
    int index,
    SolanaDerivationScheme scheme,
  ) async {
    final seed = bip39.mnemonicToSeed(mnemonic.trim().toLowerCase());
    return Ed25519HDKeyPair.fromSeedWithHdPath(
      seed: seed,
      hdPath: solanaHdPath(index, scheme),
    );
  }

  /// Solana address at [index] for a specific derivation [scheme]
  /// (standard / legacy / root). Used by the legacy-path import options.
  static Future<String> getSolanaAddressForScheme(
    String mnemonic,
    int index,
    SolanaDerivationScheme scheme,
  ) async {
    final seed = bip39.mnemonicToSeed(mnemonic.trim().toLowerCase());
    final keypair = await Ed25519HDKeyPair.fromSeedWithHdPath(
      seed: seed,
      hdPath: solanaHdPath(index, scheme),
    );
    return keypair.address;
  }

  // ---------------------------------------------------------------------------
  // Ethereum (secp256k1) — derive, message signing, transaction signing
  // ---------------------------------------------------------------------------

  /// Ethereum HD path for account [index].
  ///
  /// Composed from the same [_ethChainPath] the batch address derivation walks,
  /// so the key a signature is made with and the address the picker displays
  /// derive from one source. Two independent literals would drift silently:
  /// a valid signature from a different address, not an error.
  static String ethereumHdPath(int index) => '$_ethChainPath/$index';

  /// Ethereum address (EIP-55 checksummed) at [index].
  /// Path: m/44'/60'/0'/0/[index].
  static Future<String> getEthereumAddressAtIndex(
    String mnemonic,
    int index,
  ) async {
    final seed = bip39.mnemonicToSeed(mnemonic.trim().toLowerCase());
    return _ethAddressFromChainNode(
      bip32.BIP32.fromSeed(seed).derivePath(_ethChainPath),
      index,
    );
  }

  /// EIP-55 checksum an Ethereum address (e.g. the lowercase hex a Ledger
  /// device returns), so it displays identically to mnemonic-derived addresses.
  static String checksumEthereumAddress(String address) =>
      EthereumAddress.fromHex(address).eip55With0x;

  /// EIP-55 address for a raw 32-byte secp256k1 private key (imported-key path).
  static String ethereumAddressFromPrivateKey(Uint8List privateKey) =>
      EthPrivateKey(privateKey).address.eip55With0x;

  /// EIP-191 `personal_sign` of [message] with a raw secp256k1 private key.
  ///
  /// Mirrors [signEthereumPersonalMessage] but signs with an imported key
  /// directly instead of deriving from a mnemonic. Returns the 65-byte
  /// `r‖s‖v` (v = 27/28) signature as `0x`-prefixed hex.
  static Future<String> signEthereumPersonalMessageWithKey(
    Uint8List privateKey,
    List<int> message,
  ) async {
    final sig = EthPrivateKey(
      privateKey,
    ).signPersonalMessageToUint8List(Uint8List.fromList(message));
    return '0x${bytesToHex(sig)}';
  }

  /// Decode a hex-encoded raw private key (no `0x` prefix), as stored for
  /// imported Ethereum/Tezos keys, back to bytes.
  static Uint8List privateKeyBytesFromHex(String hex) => hexToBytes(hex);

  /// EIP-191 `personal_sign` of [message] with the secp256k1 key at [index].
  ///
  /// Matches the reference web client's wagmi/viem `signMessage`: the
  /// `\x19Ethereum Signed Message:\n` + length prefix is applied,
  /// keccak256-hashed, then signed. Returns the 65-byte `r‖s‖v` (v = 27/28)
  /// signature as `0x`-prefixed hex — the form the backend's viem
  /// `verifyMessage` recovers the signer from.
  static Future<String> signEthereumPersonalMessage(
    String mnemonic,
    int index,
    List<int> message,
  ) async {
    final seed = bip39.mnemonicToSeed(mnemonic.trim().toLowerCase());
    final node = bip32.BIP32.fromSeed(seed).derivePath(ethereumHdPath(index));
    final priv = node.privateKey;
    if (priv == null) {
      throw StateError('Failed to derive Ethereum private key at index $index');
    }
    final sig = EthPrivateKey(
      priv,
    ).signPersonalMessageToUint8List(Uint8List.fromList(message));
    return '0x${bytesToHex(sig)}';
  }

  /// Sign a fully-populated Ethereum [transaction] with the secp256k1 key at
  /// [index] (HD path), returning the raw signed bytes for
  /// `eth_sendRawTransaction`.
  ///
  /// The [transaction] MUST already carry its nonce, gas limit, and EIP-1559
  /// fees (the send flow fetches those from the node first); this only derives
  /// the key, RLP-signs over [chainId] (EIP-155), and prepends the `0x02`
  /// type byte for EIP-1559 txs — the same post-processing
  /// `Web3Client.sendTransaction` applies internally.
  static Future<Uint8List> signEthereumTransaction(
    String mnemonic,
    int index,
    Transaction transaction,
    int chainId,
  ) async {
    final seed = bip39.mnemonicToSeed(mnemonic.trim().toLowerCase());
    final node = bip32.BIP32.fromSeed(seed).derivePath(ethereumHdPath(index));
    final priv = node.privateKey;
    if (priv == null) {
      throw StateError('Failed to derive Ethereum private key at index $index');
    }
    return _signEthereumTx(EthPrivateKey(priv), transaction, chainId);
  }

  /// Sign a fully-populated Ethereum [transaction] with an imported raw 32-byte
  /// secp256k1 private key. Mirrors [signEthereumTransaction] without the HD
  /// derivation step.
  static Future<Uint8List> signEthereumTransactionWithKey(
    Uint8List privateKey,
    Transaction transaction,
    int chainId,
  ) async {
    return _signEthereumTx(EthPrivateKey(privateKey), transaction, chainId);
  }

  static Uint8List _signEthereumTx(
    EthPrivateKey key,
    Transaction transaction,
    int chainId,
  ) {
    // A native-ETH transfer carries no calldata, but web3dart's RLP encoder
    // writes `transaction.data` verbatim and throws "null cannot be rlp-encoded"
    // on a null. `Web3Client.sendTransaction` avoids this by defaulting data to
    // an empty list in `_fillMissingData`; we sign offline (bypassing that
    // path), so normalize it here so every caller is safe.
    final tx = transaction.data == null
        ? transaction.copyWith(data: Uint8List(0))
        : transaction;
    // An EIP-1559 (type-2) tx is broadcast with a leading `0x02` type byte,
    // which `sendRawTransaction` expects. web3dart 2.x returned the bare RLP
    // here, so we prepended the byte ourselves; 3.x prepends it inside
    // `signTransactionRaw` (its "fix EIP-1559 signed transaction prefix"), so
    // doing it again produced a double-`0x02` payload every node would reject.
    // The Ledger reassembly in [encodeSignedEip1559Transaction] still prepends
    // its own, and the two are asserted byte-identical in derivation_test.dart.
    return signTransactionRaw(tx, key, chainId: chainId);
  }

  /// The exact unsigned payload an off-device signer (e.g. a Ledger) must hash
  /// and sign for an EIP-1559 (type-2) [transaction]: the `0x02`-prefixed RLP of
  /// the unsigned fields, over [chainId].
  ///
  /// Normalizes a null `data` to an empty list first — web3dart's RLP encoder
  /// throws "null cannot be rlp-encoded" on a native transfer's null calldata
  /// (offline signing bypasses the client default), the same guard
  /// [_signEthereumTx] applies. Keeping this beside [encodeSignedEip1559Transaction]
  /// guarantees the bytes signed and the bytes reassembled agree on `data`.
  static Uint8List unsignedEip1559Payload(
    Transaction transaction,
    int chainId,
  ) {
    final tx = transaction.data == null
        ? transaction.copyWith(data: Uint8List(0))
        : transaction;
    return tx.getUnsignedSerialized(chainId: chainId);
  }

  /// Reassemble the broadcast-ready signed bytes for an EIP-1559 (type-2)
  /// [transaction] from a signature produced off-device (e.g. a Ledger), given
  /// the raw recovery byte [v] and the 32-byte big-endian components [r]/[s].
  ///
  /// This is the Ledger counterpart of [_signEthereumTx]: the device already
  /// keccak256-hashed and signed `transaction.getUnsignedSerialized(chainId:)`,
  /// so all that remains is to append the signature and prepend the `0x02` type
  /// byte. The RLP field order mirrors web3dart's internal `_encodeEIP1559ToRlp`
  /// exactly so the bytes are identical to a locally-signed tx. For type-2 the
  /// signature `v` is the recovery parity {0, 1} — the device may return it as
  /// {27, 28}, so normalize.
  static Uint8List encodeSignedEip1559Transaction(
    Transaction transaction,
    int chainId, {
    required int v,
    required Uint8List r,
    required Uint8List s,
  }) {
    final nonce = transaction.nonce;
    final maxGas = transaction.maxGas;
    final maxPriorityFeePerGas = transaction.maxPriorityFeePerGas;
    final maxFeePerGas = transaction.maxFeePerGas;
    if (nonce == null ||
        maxGas == null ||
        maxPriorityFeePerGas == null ||
        maxFeePerGas == null) {
      throw StateError(
        'EIP-1559 transaction is missing nonce/gas/fee fields required for '
        'signing',
      );
    }

    final yParity = v >= 27 ? v - 27 : v;
    final fields = <dynamic>[
      BigInt.from(chainId),
      nonce,
      maxPriorityFeePerGas.getInWei,
      maxFeePerGas.getInWei,
      maxGas,
      transaction.to != null ? transaction.to!.value : '',
      transaction.value?.getInWei,
      transaction.data ?? Uint8List(0),
      <dynamic>[], // access list
      BigInt.from(yParity),
      _bytesToBigInt(r),
      _bytesToBigInt(s),
    ];

    return prependTransactionType(0x02, uint8ListFromList(encode(fields)));
  }

  /// Big-endian bytes → unsigned [BigInt]. Leading zeros collapse naturally,
  /// matching how RLP integer-encodes the `r`/`s` signature components.
  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Tezos (Ed25519) — derive + display only
  // ---------------------------------------------------------------------------

  /// Tezos `tz1` address at [index].
  /// Path: m/44'/1729'/[index]'/0' (SLIP-0010 ed25519).
  static Future<String> getTezosAddressAtIndex(
    String mnemonic,
    int index,
  ) async {
    final seed = bip39.mnemonicToSeed(mnemonic.trim().toLowerCase());
    return _tezosAddressFromSeed(seed, index);
  }

  /// `tz1` address for a raw 32-byte Ed25519 seed (imported `edsk` path).
  ///
  /// The seed an `edsk` key encodes is the Ed25519 secret directly (no HD
  /// derivation), so the keypair is built from it as-is and reduced to its
  /// `tz1` address via [tezosAddressFromPublicKey] — same as the seed-phrase
  /// path, just without the SLIP-0010 derivation step.
  static Future<String> tezosAddressFromSeed(Uint8List seed) async {
    final keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: seed,
    );
    return tezosAddressFromPublicKey(
      Uint8List.fromList(keypair.publicKey.bytes),
    );
  }

  /// `tz1` address from a 32-byte Ed25519 public key.
  ///
  /// Blake2b-160(pubkey) then Base58Check with the `tz1` prefix. Shared by the
  /// mnemonic seed path ([getTezosAddressAtIndex]) and the Ledger import path,
  /// which strips the device's leading curve-tag byte before calling this — so
  /// both produce identical addresses for the same key.
  static String tezosAddressFromPublicKey(Uint8List ed25519PublicKey) {
    final digest = Blake2bDigest(digestSize: 20);
    digest.update(ed25519PublicKey, 0, ed25519PublicKey.length);
    final pkh = Uint8List(20);
    digest.doFinal(pkh, 0);
    return _base58CheckEncode(const [6, 161, 159], pkh); // tz1 prefix
  }

  /// Base58Check prefix for an Ed25519 signature (`edsig…`).
  static const _edsigPrefix = [9, 245, 205, 134, 18];

  /// Base58Check prefix for an Ed25519 public key (`edpk…`).
  static const _edpkPrefix = [13, 15, 37, 217];

  /// The exact off-chain message string every Tezos signing path (seed phrase
  /// and Ledger) must produce byte-for-byte. The backend rebuilds it from the
  /// `timestamp` the client sends and re-verifies, so this is the single source
  /// of truth — both paths call it to avoid drift.
  static String formatTezosSignedMessage(
    String messageToSign,
    String timestamp,
  ) => 'Tezos Signed Message: mallow.art $timestamp $messageToSign';

  /// Micheline-pack [formattedInput] into the bytes a Tezos signer hashes
  /// (Blake2b-256) and signs: `05 01 <4-byte big-endian len> <utf8-hex>`. Must
  /// match the reference web client `tezosHelpers` and the backend byte-for-byte (each hex
  /// byte is two chars, so len = hex/2).
  ///
  /// The seed path hashes these bytes locally; the Ledger path streams them to
  /// the device, which Blake2b-256-hashes and Ed25519-signs internally — both
  /// produce the same signature over the same digest.
  static Uint8List packTezosMicheline(String formattedInput) {
    final messageHex = bytesToHex(utf8.encode(formattedInput));
    final lenHex = (messageHex.length ~/ 2).toRadixString(16).padLeft(8, '0');
    return hexToBytes('0501$lenHex$messageHex');
  }

  /// Base58Check-encode a raw 64-byte Ed25519 signature as an `edsig…` string.
  static String encodeTezosEdsig(List<int> signature) =>
      _base58CheckEncode(_edsigPrefix, signature);

  /// Base58Check-encode a raw 32-byte Ed25519 public key as an `edpk…` string.
  static String encodeTezosEdpk(List<int> publicKey) =>
      _base58CheckEncode(_edpkPrefix, publicKey);

  /// Sign [formattedInput] as a Tezos MICHELINE off-chain message at [index].
  ///
  /// Replicates Beacon/Taquito `requestSignPayload(MICHELINE)` (and the
  /// backend's `@taquito/utils` `verifySignature`): pack the string as Micheline
  /// bytes (`05 01 <4-byte big-endian len> <utf8-hex>`), Blake2b-256 the packed
  /// bytes, then Ed25519-sign the digest. Returns the `edsig…` signature plus
  /// the `edpk…` public key the backend needs to verify and to re-derive the
  /// `tz1` address.
  static Future<({String signature, String publicKey})> signTezosMicheline(
    String mnemonic,
    int index,
    String formattedInput,
  ) async {
    final seed = bip39.mnemonicToSeed(mnemonic.trim().toLowerCase());
    final node = await ED25519_HD_KEY.derivePath(
      "m/44'/1729'/$index'/0'",
      seed,
    );
    final keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: node.key,
    );

    final packed = packTezosMicheline(formattedInput);
    final digest = Blake2bDigest(digestSize: 32);
    digest.update(packed, 0, packed.length);
    final hash = Uint8List(32);
    digest.doFinal(hash, 0);

    final sig = await keypair.sign(hash);
    return (
      signature: encodeTezosEdsig(sig.bytes),
      publicKey: encodeTezosEdpk(keypair.publicKey.bytes),
    );
  }

  /// Sign [formattedInput] as a Tezos MICHELINE off-chain message with a raw
  /// 32-byte Ed25519 seed (imported `edsk` path).
  ///
  /// Mirrors [signTezosMicheline] but builds the keypair from the imported seed
  /// directly instead of deriving from a mnemonic — the pack / Blake2b-256 /
  /// Ed25519-sign steps are identical, so the backend verifies it the same way.
  static Future<({String signature, String publicKey})>
  signTezosMichelineWithSeed(Uint8List seed, String formattedInput) async {
    final keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: seed,
    );

    final packed = packTezosMicheline(formattedInput);
    final digest = Blake2bDigest(digestSize: 32);
    digest.update(packed, 0, packed.length);
    final hash = Uint8List(32);
    digest.doFinal(hash, 0);

    final sig = await keypair.sign(hash);
    return (
      signature: encodeTezosEdsig(sig.bytes),
      publicKey: encodeTezosEdpk(keypair.publicKey.bytes),
    );
  }

  /// Watermark byte hashed before a Tezos *operation* signature (`0x03`).
  /// Off-chain messages use the Micheline `05` pack instead (see
  /// [packTezosMicheline]); an operation must never be signed with the message
  /// watermark or vice versa.
  static const int _tezosOperationWatermark = 0x03;

  /// The `edpk…` Ed25519 public key for the Tezos account at [index] (HD path).
  ///
  /// Needed to build a `reveal` content for an account that has never revealed
  /// its manager key. Complements [getTezosAddressAtIndex], which only yields
  /// the `tz1` hash.
  static Future<String> getTezosPublicKeyAtIndex(
    String mnemonic,
    int index,
  ) async {
    final seed = bip39.mnemonicToSeed(mnemonic.trim().toLowerCase());
    final node = await ED25519_HD_KEY.derivePath(
      "m/44'/1729'/$index'/0'",
      seed,
    );
    final keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: node.key,
    );
    return encodeTezosEdpk(keypair.publicKey.bytes);
  }

  /// The `edpk…` Ed25519 public key for an imported raw 32-byte Ed25519 seed
  /// (imported `edsk` path).
  static Future<String> tezosPublicKeyFromSeed(Uint8List seed) async {
    final keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: seed,
    );
    return encodeTezosEdpk(keypair.publicKey.bytes);
  }

  /// Sign a locally-forged Tezos operation group ([forgedHex] from
  /// `forgeOperationGroup`) with the Ed25519 key at [index] (HD path).
  ///
  /// Tezos operation signing: Blake2b-256 over (`0x03` watermark ++ forged
  /// bytes), then Ed25519-sign the 32-byte digest. Returns the `edsig…`
  /// signature and `signedOperationHex` (`forgedHex ++ raw-signature-hex`), the
  /// payload `/injection/operation` expects.
  static Future<({String signature, String signedOperationHex})>
  signTezosOperation(String mnemonic, int index, String forgedHex) async {
    final seed = bip39.mnemonicToSeed(mnemonic.trim().toLowerCase());
    final node = await ED25519_HD_KEY.derivePath(
      "m/44'/1729'/$index'/0'",
      seed,
    );
    final keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: node.key,
    );
    return _signTezosForgedBytes(keypair, forgedHex);
  }

  /// Sign a forged Tezos operation with a raw 32-byte Ed25519 seed (imported
  /// `edsk` path). Mirrors [signTezosOperation] without the HD derivation step.
  static Future<({String signature, String signedOperationHex})>
  signTezosOperationWithSeed(Uint8List seed, String forgedHex) async {
    final keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: seed,
    );
    return _signTezosForgedBytes(keypair, forgedHex);
  }

  static Future<({String signature, String signedOperationHex})>
  _signTezosForgedBytes(Ed25519HDKeyPair keypair, String forgedHex) async {
    final forged = hexToBytes(forgedHex);
    final watermarked = Uint8List(forged.length + 1)
      ..[0] = _tezosOperationWatermark
      ..setRange(1, forged.length + 1, forged);
    final digest = Blake2bDigest(digestSize: 32);
    digest.update(watermarked, 0, watermarked.length);
    final hash = Uint8List(32);
    digest.doFinal(hash, 0);
    final sig = await keypair.sign(hash);
    return (
      signature: encodeTezosEdsig(sig.bytes),
      signedOperationHex: forgedHex + bytesToHex(sig.bytes),
    );
  }

  // ---------------------------------------------------------------------------
  // Social (Web3Auth) key material — hex in, chain address / stored key out
  // ---------------------------------------------------------------------------

  /// Hex-string validator for the social key inputs below.
  static final _keyHexPattern = RegExp(r'^[0-9a-fA-F]+$');

  /// Decode a private-key [hex] string (optional `0x` prefix) that must be
  /// exactly [expectedBytes] long.
  ///
  /// The thrown [ArgumentError] deliberately carries no value — an
  /// `ArgumentError.value` here would embed the private key in a string that
  /// reaches logs and crash reporting.
  static Uint8List _decodeKeyHex(String hex, int expectedBytes, String label) {
    final trimmed = hex.trim();
    final body = (trimmed.startsWith('0x') || trimmed.startsWith('0X'))
        ? trimmed.substring(2)
        : trimmed;
    if (body.length != expectedBytes * 2 || !_keyHexPattern.hasMatch(body)) {
      throw ArgumentError(
        'Expected a $expectedBytes-byte $label as ${expectedBytes * 2} hex '
        'characters, got ${body.length}',
      );
    }
    return hexToBytes(body);
  }

  /// Solana address for a 64-byte Ed25519 keypair hex — the form
  /// `Web3AuthFlutter.getEd25519PrivKey()` returns: 32-byte seed ‖ 32-byte
  /// public key.
  ///
  /// The address is the trailing public half, base58-encoded. Seed-first byte
  /// order is the one place a silent wrong-key bug can hide (a signature would
  /// still be valid, just for a different address), so it is pinned by test
  /// against [Ed25519HDKeyPair.fromPrivateKeyBytes] over the leading half.
  static String solanaAddressFromEd25519KeyHex(String hex) {
    final bytes = _decodeKeyHex(hex, 64, 'Ed25519 keypair');
    return base58.base58encode(bytes.sublist(32));
  }

  /// Secure-storage form of a 64-byte Ed25519 keypair hex for a Solana wallet
  /// row: base58 of all 64 bytes.
  ///
  /// This is byte-for-byte the encoding imported Solana keys use
  /// (`PrivateKeyParser`), so `WalletManager._loadImportedSolanaSecretKey` —
  /// `base58decode(stored).sublist(0, 32)` — recovers the seed and social rows
  /// sign through the existing imported-key path.
  static String solanaStoredKeyFromEd25519KeyHex(String hex) =>
      base58.base58encode(_decodeKeyHex(hex, 64, 'Ed25519 keypair'));

  /// EIP-55 Ethereum address for a 32-byte secp256k1 private key hex — the form
  /// `Web3AuthFlutter.getPrivKey()` returns.
  ///
  /// Same derivation as the imported-key path
  /// ([ethereumAddressFromPrivateKey]); only the hex decode is added.
  static String ethereumAddressFromPrivateKeyHex(String hex) =>
      ethereumAddressFromPrivateKey(
        _decodeKeyHex(hex, 32, 'secp256k1 private key'),
      );

  /// `tz1` address for a 32-byte Ed25519 seed given as hex.
  ///
  /// Web3Auth's Tezos convention feeds the `getPrivKey()` bytes in as an
  /// Ed25519 seed, so this is [tezosAddressFromSeed] with a hex decode in
  /// front — the same keypair [signTezosOperationWithSeed] builds from the
  /// stored key, which is what makes the stored seed sign for this address.
  static Future<String> tezosAddressFromSeedHex(String hex) =>
      tezosAddressFromSeed(_decodeKeyHex(hex, 32, 'Ed25519 seed'));

  // ---------------------------------------------------------------------------
  // Multi-chain batch discovery (import-by-account picker)
  // ---------------------------------------------------------------------------

  /// Derive addresses for all supported chains at the given account [indices],
  /// off the UI isolate, reusing a single BIP39 seed expansion.
  ///
  /// When [includeLegacyPaths] is true, also derives the legacy Solana path per
  /// index and the root Solana path (index 0 only).
  ///
  /// Pass [deriveEthereum] / [deriveTezos] as false for a chain the caller will
  /// not show (e.g. switched off in Active Networks) — its field comes back null
  /// and the derivation is skipped entirely. Ethereum is the most expensive
  /// chain per index, so skipping it is worth real time on the picker.
  static Future<List<AccountAddresses>> getMultiChainAddressesAtIndices(
    String mnemonic,
    List<int> indices, {
    bool includeLegacyPaths = false,
    bool deriveEthereum = true,
    bool deriveTezos = true,
  }) {
    return compute(
      _batchDeriveMultiChainInIsolate,
      _MultiChainTask(
        mnemonic: mnemonic.trim().toLowerCase(),
        indices: indices,
        includeLegacyPaths: includeLegacyPaths,
        deriveEthereum: deriveEthereum,
        deriveTezos: deriveTezos,
      ),
    );
  }
}
