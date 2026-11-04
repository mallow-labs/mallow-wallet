import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:solana/base58.dart';

/// Whether [signature] is a valid Ed25519 signature over [message] by the
/// Solana [address] (base58 public key).
///
/// The check every external signer's reply needs before it is used. A
/// signature that comes back from outside this process — a Keystone QR, a
/// dApp-facing hardware reply — says nothing about *which* key produced it, and
/// a device asked with the wrong path or fingerprint returns a perfectly valid
/// signature from a different address. Attaching the database address to the
/// returned bytes does not establish signer identity; this does.
///
/// Never throws: a malformed address or a signature of the wrong length is
/// simply not valid.
Future<bool> isValidEd25519Signature(
  List<int> message,
  List<int> signature,
  String address,
) async {
  if (signature.length != 64) return false;
  final List<int> publicKey;
  try {
    publicKey = base58decode(address);
  } catch (_) {
    return false;
  }
  if (publicKey.length != 32) return false;
  return cryptography.Ed25519().verify(
    message,
    signature: cryptography.Signature(
      signature,
      publicKey: cryptography.SimplePublicKey(
        publicKey,
        type: cryptography.KeyPairType.ed25519,
      ),
    ),
  );
}
