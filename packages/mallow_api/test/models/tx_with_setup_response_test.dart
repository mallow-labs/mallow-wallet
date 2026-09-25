import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  group('UnsignedTxWithSetupResponse decoding', () {
    test('keeps responses without a setup transaction backward-compatible', () {
      final response = ApiResponse<UnsignedTxWithSetupResponse>.fromJson({
        'result': {'tx': 'MAIN_TX'},
      }, (json) => UnsignedTxWithSetupResponse.fromJson(json! as Map<String, dynamic>));

      expect(response.result.tx, 'MAIN_TX');
      expect(response.result.setupTx, isNull);
    });

    test('retains the prerequisite transaction beside the main transaction', () {
      final response = ApiResponse<UnsignedTxWithSetupResponse>.fromJson({
        'result': {'tx': 'MAIN_TX', 'setupTx': 'SETUP_TX'},
      }, (json) => UnsignedTxWithSetupResponse.fromJson(json! as Map<String, dynamic>));

      expect(response.result.tx, 'MAIN_TX');
      expect(response.result.setupTx, 'SETUP_TX');
    });
  });

  group('BuyFixedPriceTxResponse decoding', () {
    test('retains the LUT prerequisite for a compressed NFT purchase', () {
      final response = ApiResponse<BuyFixedPriceTxResponse>.fromJson({
        'result': {'tx': 'MAIN_TX', 'setupTx': 'SETUP_TX'},
      }, (json) => BuyFixedPriceTxResponse.fromJson(json! as Map<String, dynamic>));

      expect(response.result.tx, 'MAIN_TX');
      expect(response.result.setupTx, 'SETUP_TX');
      expect(response.result.swapTx, isNull);
    });

    test('retains the existing split-swap response without a setup transaction', () {
      final response = ApiResponse<BuyFixedPriceTxResponse>.fromJson({
        'result': {'swapTx': 'SWAP_TX'},
      }, (json) => BuyFixedPriceTxResponse.fromJson(json! as Map<String, dynamic>));

      expect(response.result.tx, isNull);
      expect(response.result.setupTx, isNull);
      expect(response.result.swapTx, 'SWAP_TX');
    });
  });
}
