import 'dart:typed_data';

import 'package:bip32/bip32.dart' as bip32;
import 'package:bip39/bip39.dart' as bip39;
import 'package:ed25519_hd_key/ed25519_hd_key.dart';
import 'package:ledger_solana/ledger_solana.dart' show SolanaDerivationScheme;
import 'package:solana/base58.dart' as base58;
import 'package:solana/solana.dart' show Ed25519HDKeyPair;

import '../crypto/derivation.dart';
import 'social_vault_crypto.dart';

/// The three chain keys of a social vault wallet, in exactly the formats the
/// imported-key signing paths already read — so a wallet opened from a social
/// vault signs through the same code as any imported key.
///
/// | Chain | Stored as | Derived at |
/// | --- | --- | --- |
/// | Solana | base58 of the 64-byte Ed25519 keypair | `m/44'/501'/0'/0'` |
/// | Ethereum | 32-byte secp256k1 key, hex | `m/44'/60'/0'/0/0` |
/// | Tezos | 32-byte Ed25519 seed, hex | `m/44'/1729'/0'/0'` (SLIP-0010) |
///
/// Index 0 with the standard Solana scheme is what any other wallet derives
/// from the same phrase, so an exported phrase restores the same addresses
/// elsewhere. The shared vectors pin all three.
///
/// Hand-written with a redacted [toString]: three of its fields are private
/// keys.
class SocialWalletKeys {
  const SocialWalletKeys({
    required this.solanaAddress,
    required this.solanaStoredKey,
    required this.ethereumAddress,
    required this.ethereumKeyHex,
    required this.tezosAddress,
    required this.tezosSeedHex,
  });

  final String solanaAddress;
  final String solanaStoredKey;
  final String ethereumAddress;
  final String ethereumKeyHex;
  final String tezosAddress;
  final String tezosSeedHex;

  /// Derive the keys a payload holds.
  static Future<SocialWalletKeys> fromPayload(SocialVaultPayload payload) =>
      _fromMnemonic(payload.mnemonic);

  /// Whether these keys are the wallet already at [solana], [ethereum] and
  /// [tezos]. Ethereum is compared case-insensitively (checksum casing is
  /// presentation); base58 and tz1 are case-sensitive.
  bool matches({
    required String? solana,
    required String? ethereum,
    required String? tezos,
  }) =>
      (solana == null || solana == solanaAddress) &&
      (ethereum == null ||
          ethereum.toLowerCase() == ethereumAddress.toLowerCase()) &&
      (tezos == null || tezos == tezosAddress);

  static Future<SocialWalletKeys> _fromMnemonic(String mnemonic) async {
    // The same spelling the phrase is sealed and read in: BIP39 hashes the
    // text, so any other would derive another wallet.
    final normalized = SocialVaultCrypto.normalizeMnemonic(mnemonic);
    if (!bip39.validateMnemonic(normalized)) {
      throw const SocialVaultCryptoException('bip39 payload is not a phrase');
    }
    final seed = bip39.mnemonicToSeed(normalized);

    final solana = await Ed25519HDKeyPair.fromSeedWithHdPath(
      seed: seed,
      hdPath: MultiChainDerivation.solanaHdPath(
        0,
        SolanaDerivationScheme.standard,
      ),
    );
    final solanaSeed = (await solana.extract()).bytes;
    final solanaKeypair = Uint8List.fromList([
      ...solanaSeed,
      ...solana.publicKey.bytes,
    ]);

    final eth = bip32.BIP32
        .fromSeed(seed)
        .derivePath(MultiChainDerivation.ethereumHdPath(0));
    final ethKey = eth.privateKey;
    if (ethKey == null) {
      throw StateError('Ethereum key derivation produced no private key');
    }
    final ethKeyHex = _hex(ethKey);

    final tezos = await ED25519_HD_KEY.derivePath("m/44'/1729'/0'/0'", seed);
    final tezosSeedHex = _hex(tezos.key);

    return SocialWalletKeys(
      solanaAddress: solana.address,
      solanaStoredKey: base58.base58encode(solanaKeypair),
      ethereumAddress: MultiChainDerivation.ethereumAddressFromPrivateKeyHex(
        ethKeyHex,
      ),
      ethereumKeyHex: ethKeyHex,
      tezosAddress: await MultiChainDerivation.tezosAddressFromSeedHex(
        tezosSeedHex,
      ),
      tezosSeedHex: tezosSeedHex,
    );
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String toString() =>
      'SocialWalletKeys(solana: $solanaAddress, ethereum: $ethereumAddress, '
      'tezos: $tezosAddress, keys: <redacted>)';
}
