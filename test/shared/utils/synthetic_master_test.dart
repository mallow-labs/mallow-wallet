import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/synthetic_master.dart';

void main() {
  const master =
      'cnft-master-5tzFkiKscXHK5ZXCGbXZxdw7gTjjD1mBwuoFbhUvuAi9-0123456789abcdef0123456789abcdef';
  const realPrint = 'So11111111111111111111111111111111111111112';

  test('neutral and compatibility names recognize the legacy prefix', () {
    expect(syntheticSolanaMasterPrefix, syntheticCnftMasterPrefix);
    expect(isSyntheticSolanaMaster(master), isTrue);
    expect(isSyntheticCnftMaster(master), isTrue);
    expect(isSyntheticSolanaMaster(realPrint), isFalse);
  });

  test('synthetic master hides explorer address and standard details', () {
    expect(assetMintForDisplay(master), isNull);
    expect(assetTokenStandardForDisplay(master, 'unknown'), isNull);
  });

  test('real prints retain their own actionable standards', () {
    for (final standard in ['nft', 'pnft', 'core', 'cnft', 'cnft-v2']) {
      expect(assetMintForDisplay(realPrint), realPrint);
      expect(assetTokenStandardForDisplay(realPrint, standard), standard);
    }
  });
}
