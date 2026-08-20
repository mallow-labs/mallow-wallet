import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/staking/data/epoch_progress.dart';

void main() {
  group('EpochProgress.fraction', () {
    test('returns 0 when at the start of the epoch', () {
      const p = EpochProgress(epoch: 600, slotIndex: 0, slotsInEpoch: 432000);
      expect(p.fraction, 0.0);
    });

    test('returns 1 at the last slot', () {
      const p = EpochProgress(
        epoch: 600,
        slotIndex: 432000,
        slotsInEpoch: 432000,
      );
      expect(p.fraction, 1.0);
    });

    test('returns ~0.5 at the midpoint', () {
      const p = EpochProgress(
        epoch: 600,
        slotIndex: 216000,
        slotsInEpoch: 432000,
      );
      expect(p.fraction, closeTo(0.5, 1e-9));
    });

    test('clamps above 1 when slotIndex exceeds slotsInEpoch', () {
      const p = EpochProgress(
        epoch: 600,
        slotIndex: 500000,
        slotsInEpoch: 432000,
      );
      expect(p.fraction, 1.0);
    });

    test(
      'returns 0 when slotsInEpoch is 0 (guard against division by zero)',
      () {
        const p = EpochProgress(epoch: 600, slotIndex: 100, slotsInEpoch: 0);
        expect(p.fraction, 0.0);
      },
    );
  });

  group('EpochProgress.timeRemaining', () {
    test('returns zero when all slots have elapsed', () {
      const p = EpochProgress(
        epoch: 600,
        slotIndex: 432000,
        slotsInEpoch: 432000,
      );
      expect(p.timeRemaining, Duration.zero);
    });

    test('returns zero when slotIndex exceeds slotsInEpoch', () {
      const p = EpochProgress(
        epoch: 600,
        slotIndex: 500000,
        slotsInEpoch: 432000,
      );
      expect(p.timeRemaining, Duration.zero);
    });

    test('full epoch remaining = 432 000 slots × 400 ms ≈ 2 days', () {
      const p = EpochProgress(epoch: 600, slotIndex: 0, slotsInEpoch: 432000);
      // 432 000 * 400 ms = 172 800 000 ms = 48 h = 2 days
      expect(p.timeRemaining, const Duration(milliseconds: 432000 * 400));
    });

    test('half epoch remaining', () {
      const p = EpochProgress(
        epoch: 600,
        slotIndex: 216000,
        slotsInEpoch: 432000,
      );
      expect(p.timeRemaining, const Duration(milliseconds: 216000 * 400));
    });

    test('single slot remaining = 400 ms', () {
      const p = EpochProgress(
        epoch: 600,
        slotIndex: 431999,
        slotsInEpoch: 432000,
      );
      expect(p.timeRemaining, const Duration(milliseconds: 400));
    });
  });
}
