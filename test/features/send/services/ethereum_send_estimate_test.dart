import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/send/services/ethereum_transfer_service.dart';

/// Helper: gwei → wei (same precision used in the production model).
BigInt _g(num gwei) => BigInt.from((gwei * 1e9).round());

EthereumSendEstimate _estimate({
  int gasLimit = 21000,
  BigInt? estimatedGasUsed,
  BigInt? maxFeePerGas,
  BigInt? maxPriorityFeePerGas,
  BigInt? effectiveGasPrice,
}) => EthereumSendEstimate(
  gasLimit: gasLimit,
  estimatedGasUsed: estimatedGasUsed ?? BigInt.from(21000),
  maxFeePerGas: maxFeePerGas ?? _g(24),
  maxPriorityFeePerGas: maxPriorityFeePerGas ?? _g(2),
  effectiveGasPrice: effectiveGasPrice ?? _g(13),
);

void main() {
  group('EthereumSendEstimate computed properties', () {
    test('feeWei = estimatedGasUsed × effectiveGasPrice', () {
      // 21 000 gas × 13 gwei = 273 000 gwei = 273 000 000 000 000 wei.
      final e = _estimate(
        estimatedGasUsed: BigInt.from(21000),
        effectiveGasPrice: _g(13),
      );
      expect(e.feeWei, BigInt.from(21000) * _g(13));
    });

    test('maxFeeWei = gasLimit × maxFeePerGas (worst case reserves)', () {
      // gasLimit padded 20% above estimate: 25 200 × 24 gwei.
      final e = _estimate(gasLimit: 25200, maxFeePerGas: _g(24));
      expect(e.maxFeeWei, BigInt.from(25200) * _g(24));
    });

    test('feeWei ≤ maxFeeWei when effectiveGasPrice ≤ maxFeePerGas', () {
      // Expected fee must never exceed the reserved worst case.
      final e = _estimate(
        gasLimit: 25200,
        estimatedGasUsed: BigInt.from(21000),
        maxFeePerGas: _g(24),
        effectiveGasPrice: _g(13),
      );
      expect(e.feeWei, lessThanOrEqualTo(e.maxFeeWei));
    });

    test('feeEth converts wei to whole ETH (÷ 1e18)', () {
      // 21 000 gas × 13 gwei = 273 000 gwei = 0.000 000 273 ETH.
      final e = _estimate(
        estimatedGasUsed: BigInt.from(21000),
        effectiveGasPrice: _g(13),
      );
      final expectedEth = (BigInt.from(21000) * _g(13)).toDouble() / 1e18;
      expect(e.feeEth, closeTo(expectedEth, 1e-18));
    });

    test(
      'priorityFeeGwei converts maxPriorityFeePerGas wei → gwei (÷ 1e9)',
      () {
        final e = _estimate(maxPriorityFeePerGas: _g(2));
        expect(e.priorityFeeGwei, closeTo(2.0, 1e-9));
      },
    );

    test('priorityFeeGwei reflects sub-gwei precision', () {
      // 1.5 gwei tip stored as wei round-trips cleanly.
      final e = _estimate(maxPriorityFeePerGas: _g(1.5));
      expect(e.priorityFeeGwei, closeTo(1.5, 1e-6));
    });

    test(
      'feeEth is zero when estimatedGasUsed is zero (empty estimate guard)',
      () {
        final e = _estimate(estimatedGasUsed: BigInt.zero);
        expect(e.feeEth, 0.0);
      },
    );

    test('maxFeeWei is zero when gasLimit is zero', () {
      final e = _estimate(gasLimit: 0);
      expect(e.maxFeeWei, BigInt.zero);
    });

    test(
      'large ERC-20 token transfer gas (65 000) produces plausible fees',
      () {
        // ERC-20 transfers typically use ~45–65 k gas.
        final e = _estimate(
          gasLimit: 80000,
          estimatedGasUsed: BigInt.from(65000),
          maxFeePerGas: _g(30),
          effectiveGasPrice: _g(16),
        );
        // feeWei = 65 000 × 16 gwei = 1 040 000 gwei.
        expect(e.feeWei, BigInt.from(65000) * _g(16));
        // maxFeeWei = 80 000 × 30 gwei = 2 400 000 gwei.
        expect(e.maxFeeWei, BigInt.from(80000) * _g(30));
        // feeEth must be smaller than maxFeeEth.
        final maxFeeEth = e.maxFeeWei.toDouble() / 1e18;
        expect(e.feeEth, lessThan(maxFeeEth));
      },
    );
  });
}
