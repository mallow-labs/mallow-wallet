import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/accounts/models/picker_account.dart';
import 'package:mallow_wallet/features/accounts/widgets/account_picker_card.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_svg_icon.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

PickerAccount _account({String? importedName}) => PickerAccount(
  index: 0,
  importedName: importedName,
  wallets: [
    PickerWallet(
      accountIndex: 0,
      chain: Chain.tezos, // not enrichable, so no shimmer to settle
      address: 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb',
      alreadyImported: importedName != null,
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester, {
  required PickerAccount account,
  required String displayName,
  ValueChanged<String>? onRename,
}) => tester.pumpWidget(
  MaterialApp(
    theme: MallowTheme.lightTheme,
    home: Scaffold(
      body: AccountPickerCard(
        account: account,
        displayName: displayName,
        selectedKeys: const {},
        onToggleWallet: (_) {},
        onToggleAccount: (_) {},
        onRename: onRename,
      ),
    ),
  ),
);

final _editIcon = find.byWidgetPredicate(
  (w) => w is MallowSvgIcon && w.semanticLabel == 'Edit account name',
);

void main() {
  // The header's AccountAvatar resolves AvatarService out of GetIt.
  setUpAll(() {
    if (!sl.isRegistered<AvatarService>()) {
      sl.registerLazySingleton<AvatarService>(
        () => AvatarService.forTest(Dio(), cacheDir: Directory.systemTemp),
      );
    }
  });

  testWidgets(
    'the edit icon turns the name into a field that commits on Done',
    (tester) async {
      final renames = <String>[];
      await _pump(
        tester,
        account: _account(),
        displayName: 'Account 03',
        onRename: renames.add,
      );
      expect(find.byType(TextField), findsNothing);

      await tester.tap(_editIcon);
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'Account 03');

      await tester.enterText(find.byType(TextField), 'Trading');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(renames, ['Trading']);
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets('caps the name at 32 characters', (tester) async {
    final renames = <String>[];
    await _pump(
      tester,
      account: _account(),
      displayName: 'Account',
      onRename: renames.add,
    );
    await tester.tap(_editIcon);
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'x' * 40);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(renames, ['x' * 32]);
  });

  testWidgets('confirming the name unchanged is not a rename', (tester) async {
    final renames = <String>[];
    await _pump(
      tester,
      account: _account(),
      displayName: 'Account 03',
      onRename: renames.add,
    );
    await tester.tap(_editIcon);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(renames, isEmpty);
  });

  testWidgets('no edit icon for an account that already exists', (
    tester,
  ) async {
    await _pump(
      tester,
      account: _account(importedName: 'Account 01'),
      displayName: 'Account 01',
      onRename: (_) {},
    );
    expect(_editIcon, findsNothing);
  });

  testWidgets('no edit icon without onRename', (tester) async {
    await _pump(tester, account: _account(), displayName: 'Account');
    expect(_editIcon, findsNothing);
  });
}
