import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/fee_config.dart';

void main() {
  group('FeeConfig constants', () {
    // These two values are the centralized source of truth for fee math.
    // A future edit that changes them would silently shift every
    // server-built tx's priority fee and every UI fee estimate — pin them so
    // such a change can't land without updating this test on purpose.
    test('kDefaultPriorityFeeLamports is 50000', () {
      expect(kDefaultPriorityFeeLamports, 50000);
    });

    test('kBaseSolanaTxFeeLamports is 5000', () {
      expect(kBaseSolanaTxFeeLamports, 5000);
    });
  });

  group('FeeConfig getters', () {
    const config = FeeConfig();

    test('priorityFeeLamports reads the canonical constant', () {
      expect(config.priorityFeeLamports, kDefaultPriorityFeeLamports);
      expect(config.priorityFeeLamports, 50000);
    });

    test('baseTxFeeLamports reads the canonical constant', () {
      expect(config.baseTxFeeLamports, kBaseSolanaTxFeeLamports);
      expect(config.baseTxFeeLamports, 5000);
    });

    test('totalDefaultTxFeeLamports sums base + priority', () {
      expect(config.totalDefaultTxFeeLamports, 55000);
      expect(
        config.totalDefaultTxFeeLamports,
        config.baseTxFeeLamports + config.priorityFeeLamports,
      );
    });
  });
}
