import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/ed25519_curve.dart';
import 'package:solana/solana.dart';

void main() {
  test('a keypair\'s address is on the curve, not a program address', () async {
    final pair = await Ed25519HDKeyPair.fromSeedWithHdPath(
      seed: List.filled(32, 7),
      hdPath: "m/44'/501'/0'/0'",
    );
    expect(isOnEd25519Curve(pair.publicKey.bytes), isTrue);
    expect(isSolanaProgramAddress(pair.address), isFalse);
  });

  test('a derived program address is off the curve', () async {
    final pda = await Ed25519HDPublicKey.findProgramAddress(
      seeds: ['listing'.codeUnits],
      programId: Ed25519HDPublicKey.fromBase58(
        'TCMPhJdwDryooaGtiocG1u3xcYbRpiJzb283XfCZsDp',
      ),
    );
    expect(isOnEd25519Curve(pda.bytes), isFalse);
    expect(isSolanaProgramAddress(pda.toBase58()), isTrue);
  });

  test('input that is not a 32-byte address is never a program address', () {
    expect(isSolanaProgramAddress(''), isFalse);
    expect(isSolanaProgramAddress('not base58!'), isFalse);
    expect(isSolanaProgramAddress('1111'), isFalse);
    expect(isOnEd25519Curve(List.filled(31, 1)), isFalse);
  });
}
