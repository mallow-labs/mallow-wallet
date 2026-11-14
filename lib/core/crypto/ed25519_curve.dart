import 'package:solana/base58.dart';

final BigInt _fieldP = (BigInt.one << 255) - BigInt.from(19);
final BigInt _curveD =
    (BigInt.from(-121665) * BigInt.from(121666).modInverse(_fieldP)) % _fieldP;

/// Whether [bytes] decodes to a point on the ed25519 curve — i.e. whether it
/// is a public key someone can hold the private key for, as opposed to a
/// program-derived address.
bool isOnEd25519Curve(List<int> bytes) {
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

/// Whether [address] is a well-formed Solana address no private key exists
/// for: a program-derived address, which only its program can sign for.
/// Anything malformed is not one, so a caller that relaxes a warning for
/// program addresses keeps it for input it cannot read.
bool isSolanaProgramAddress(String address) {
  final List<int> bytes;
  try {
    bytes = base58decode(address);
  } catch (_) {
    return false;
  }
  return bytes.length == 32 && !isOnEd25519Curve(bytes);
}
