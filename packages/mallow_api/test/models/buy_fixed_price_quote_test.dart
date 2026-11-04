import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  group('native creator rent quote', () {
    test('Given a decimal quote, decoding and encoding preserve every digit', () {
      const amount = '18446744073709551615';
      final response = BuyFixedPriceTxResponse.fromJson({
        'tx': 'compiled-transaction',
        'creatorRentTopUpLamports': amount,
      });
      expect(response.creatorRentTopUpLamports, amount);
      expect(response.toJson()['creatorRentTopUpLamports'], amount);
    });

    test('Given an older response, decoding leaves the optional quote absent', () {
      final response = BuyFixedPriceTxResponse.fromJson({'tx': 'compiled-transaction'});
      expect(response.creatorRentTopUpLamports, isNull);
      expect(response.tx, 'compiled-transaction');
    });

    test('Given a zero quote, decoding preserves zero separately from absence', () {
      final response = BuyFixedPriceTxResponse.fromJson({
        'tx': 'compiled-transaction',
        'creatorRentTopUpLamports': '0',
      });
      expect(response.creatorRentTopUpLamports, '0');
    });
  });
}
