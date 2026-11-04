import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/services/browser_transaction_tracker.dart';

void main() {
  testWidgets('Ethereum confirms after the Solana polling window', (
    tester,
  ) async {
    final tracker = BrowserTransactionTracker();
    addTearDown(tracker.dispose);
    var calls = 0;
    var mined = false;
    tracker.start(
      signature: 'hash',
      chain: 'eip155:1',
      lookup: (_, _) async {
        calls++;
        return {
          'value': [
            if (mined)
              {'err': null, 'confirmationStatus': 'confirmed', 'slot': 123}
            else
              null,
          ],
        };
      },
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
    expect(tracker.records.single.status, BrowserTransactionStatus.pending);
    expect(calls, 10);
    for (var i = 10; i < 14; i++) {
      await tester.pump(const Duration(seconds: 12));
    }
    mined = true;
    await tester.pump(const Duration(seconds: 12));
    expect(tracker.records.single.status, BrowserTransactionStatus.confirmed);
    expect(tracker.records.single.slot, 123);
    await tester.pump(const Duration(hours: 1));
    expect(calls, 15);
  });

  testWidgets('Ethereum polling stops uncertain after one hour', (
    tester,
  ) async {
    final tracker = BrowserTransactionTracker();
    addTearDown(tracker.dispose);
    var calls = 0;
    tracker.start(
      signature: 'hash',
      chain: 'eip155:1',
      lookup: (_, _) async {
        calls++;
        return {
          'value': [null],
        };
      },
    );
    for (var i = 0; i < 299; i++) {
      await tester.pump(const Duration(seconds: 12));
    }
    expect(calls, 299);
    expect(tracker.records.single.status, BrowserTransactionStatus.pending);
    await tester.pump(const Duration(seconds: 12));
    expect(calls, 300);
    expect(tracker.records.single.status, BrowserTransactionStatus.uncertain);
    await tester.pump(const Duration(hours: 1));
    expect(calls, 300);
  });

  testWidgets('Solana retains its three-second forty-poll budget', (
    tester,
  ) async {
    final tracker = BrowserTransactionTracker();
    addTearDown(tracker.dispose);
    var calls = 0;
    tracker.start(
      signature: 'signature',
      chain: 'solana:mainnet',
      lookup: (_, _) async {
        calls++;
        return {
          'value': [null],
        };
      },
    );
    for (var i = 0; i < 39; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
    expect(calls, 39);
    expect(tracker.records.single.status, BrowserTransactionStatus.pending);
    await tester.pump(const Duration(seconds: 3));
    expect(tracker.records.single.status, BrowserTransactionStatus.uncertain);
    await tester.pump(const Duration(hours: 1));
    expect(calls, 40);
  });

  testWidgets('uncertain broadcast remains tracked and later confirms', (
    tester,
  ) async {
    final tracker = BrowserTransactionTracker(
      interval: const Duration(seconds: 1),
    );
    addTearDown(tracker.dispose);
    var calls = 0;
    final seen = <String>[];
    tracker.start(
      signature: 'signature',
      chain: 'solana:mainnet',
      lookup: (chain, signature) async {
        seen.addAll([chain, signature]);
        calls++;
        return {
          'value': [
            {'err': null, 'confirmationStatus': 'confirmed', 'slot': 123},
          ],
        };
      },
    );
    tracker.markUncertain('solana:mainnet', 'signature');
    expect(tracker.records.single.status, BrowserTransactionStatus.uncertain);
    await tester.pump(const Duration(seconds: 1));
    expect(seen, ['solana:mainnet', 'signature']);
    expect(calls, 1);
    expect(tracker.records.single.status, BrowserTransactionStatus.confirmed);
    expect(tracker.records.single.slot, 123);
  });
  testWidgets('exhausted status polling means uncertain, not failed', (
    tester,
  ) async {
    final tracker = BrowserTransactionTracker(
      interval: const Duration(seconds: 1),
      maxPolls: 2,
    );
    addTearDown(tracker.dispose);
    var calls = 0;
    tracker.start(
      signature: 'signature',
      chain: 'solana:devnet',
      lookup: (_, _) async {
        calls++;
        return {
          'value': [null],
        };
      },
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(tracker.records.single.status, BrowserTransactionStatus.uncertain);
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 2);
  });
  testWidgets(
    'clear browsing data prevents outstanding reads restoring records',
    (tester) async {
      final tracker = BrowserTransactionTracker(
        interval: const Duration(seconds: 1),
      );
      addTearDown(tracker.dispose);
      tracker.start(
        signature: 'signature',
        chain: 'solana:mainnet',
        lookup: (_, _) async => {
          'value': [
            {'err': 'failure'},
          ],
        },
      );
      tracker.clear();
      await tester.pump(const Duration(seconds: 2));
      expect(tracker.records, isEmpty);
    },
  );
  testWidgets('a signed transaction is listed once the network sees it', (
    tester,
  ) async {
    final tracker = BrowserTransactionTracker(
      interval: const Duration(seconds: 1),
    );
    addTearDown(tracker.dispose);
    var landed = false;
    tracker.watchSigned(
      signature: 'signature',
      chain: 'solana:mainnet',
      lookup: (_, _) async => {
        'value': [
          if (landed)
            {'err': null, 'confirmationStatus': 'confirmed', 'slot': 9}
          else
            null,
        ],
      },
    );
    expect(tracker.records, isEmpty, reason: 'not broadcast yet');
    await tester.pump(const Duration(seconds: 1));
    expect(tracker.records, isEmpty);
    landed = true;
    await tester.pump(const Duration(seconds: 1));
    expect(tracker.records.single.status, BrowserTransactionStatus.confirmed);
  });
  testWidgets('a signed transaction never sent leaves no record', (
    tester,
  ) async {
    final tracker = BrowserTransactionTracker(
      interval: const Duration(seconds: 1),
      maxPolls: 2,
    );
    addTearDown(tracker.dispose);
    tracker.watchSigned(
      signature: 'signature',
      chain: 'solana:mainnet',
      lookup: (_, _) async => {
        'value': [null],
      },
    );
    await tester.pump(const Duration(seconds: 5));
    expect(tracker.records, isEmpty);
  });
}
