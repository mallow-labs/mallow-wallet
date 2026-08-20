import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/accounts/models/picker_account.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

/// Builds a single-Solana-wallet card at derivation [index]. Its selection key
/// is `"$index:solana:"` (the standard-scheme key).
PickerAccount _card(int index, {String? importedName, bool imported = false}) =>
    PickerAccount(
      index: index,
      importedName: importedName,
      wallets: [
        PickerWallet(
          accountIndex: index,
          chain: Chain.solana,
          address: 'addr-$index',
          alreadyImported: imported,
        ),
      ],
    );

String _key(int index) => '$index:solana:';

void main() {
  group('previewAccountNames', () {
    test('numbers selected cards sequentially from the base counter', () {
      // Fresh install: counter at 1, all three cards selected.
      final names = previewAccountNames(
        accounts: [_card(0), _card(1), _card(2)],
        selectedKeys: {_key(0), _key(1), _key(2)},
        baseCounter: 1,
      );
      expect(names, {0: 'Account 01', 1: 'Account 02', 2: 'Account 03'});
    });

    test(
      'already-imported card keeps its stored name and consumes no number',
      () {
        // 5 accounts already exist (counter = 6); idx0 was imported & renamed.
        final names = previewAccountNames(
          accounts: [
            _card(0, importedName: 'Custom Name', imported: true),
            _card(1),
            _card(2),
          ],
          selectedKeys: {_key(1), _key(2)},
          baseCounter: 6,
        );
        // idx0 surfaces the stored name; the next selected cards continue the
        // global sequence from 6 — the imported card did not take a number.
        expect(names, {0: 'Custom Name', 1: 'Account 06', 2: 'Account 07'});
      },
    );

    test('unselected, not-yet-imported cards show a bare "Account"', () {
      final names = previewAccountNames(
        accounts: [_card(0), _card(1), _card(2), _card(3)],
        selectedKeys: {_key(1), _key(3)},
        baseCounter: 6,
      );
      expect(names, {
        0: 'Account', // unselected -> no number
        1: 'Account 06',
        2: 'Account', // unselected -> no number
        3: 'Account 07',
      });
    });

    test(
      'numbers ascend by derivation index regardless of selection order',
      () {
        // Selection-set membership carries no order; the ascending walk decides
        // which selected card gets the lower number.
        final names = previewAccountNames(
          accounts: [_card(2), _card(4)],
          selectedKeys: {_key(4), _key(2)},
          baseCounter: 6,
        );
        expect(names, {2: 'Account 06', 4: 'Account 07'});
      },
    );
  });
}
