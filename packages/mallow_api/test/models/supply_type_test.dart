import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  group('SupplyTypeX.supplyTitle', () {
    // Encodes the artwork-screen supply label contract (webapp parity):
    // each supply type maps to its exact user-facing string, and the
    // limited-edition / edition-print variants fold in the count.
    test('one-of-one reads "1 / 1 Artwork"', () {
      expect(SupplyType.oneOfOne.supplyTitle(), '1 / 1 Artwork');
    });

    test('open edition reads "Open Edition"', () {
      expect(SupplyType.openEdition.supplyTitle(), 'Open Edition');
    });

    test('limited edition folds in maxSupply', () {
      expect(SupplyType.limitedEdition.supplyTitle(maxSupply: 14), 'Limited Edition of 14');
    });

    test('edition print folds in editionNumber', () {
      expect(SupplyType.editionPrint.supplyTitle(editionNumber: 4), 'Edition #4');
    });
  });
}
