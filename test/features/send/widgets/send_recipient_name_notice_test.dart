import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/send/widgets/recipient_search_dropdown.dart';
import 'package:mallow_wallet/features/send/widgets/send_recipient_step.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

/// A `.sol` name is read from the SNS registry as its `.sns` twin, which the
/// new `.sol` registry may assign to someone else — so the resolved address
/// carries a caution naming the `.sns` it came from.
void main() {
  const resolved = 'Fw1ETanDZafof7xEULsnq9UY6o71Tpds89tNwPkWLb1v';

  Future<void> pump(WidgetTester tester, String input, Chain chain) async {
    final controller = TextEditingController(text: input);
    final focusNode = FocusNode();
    final search = RecipientSearchController();
    addTearDown(() {
      controller.dispose();
      focusNode.dispose();
      search.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: SendRecipientStep(
            controller: controller,
            focusNode: focusNode,
            chain: chain,
            errorText: null,
            isResolving: false,
            resolvedAddress: resolved,
            recents: const [],
            onChanged: (_) {},
            onPaste: () {},
            onScan: () {},
            onRecentTap: (_) {},
            searchController: search,
            onSuggestionPicked: (_) {},
            onBack: null,
            onCancel: () {},
            onNext: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('a resolved .sol name shows the .sns it was read as', (
    tester,
  ) async {
    await pump(tester, 'bonfida.sol', Chain.solana);
    expect(find.text(resolved), findsOneWidget);
    expect(find.textContaining('Resolved as bonfida.sns'), findsOneWidget);
  });

  testWidgets('.sns and .skr names carry no caution', (tester) async {
    await pump(tester, 'bonfida.sns', Chain.solana);
    expect(find.textContaining('Resolved as'), findsNothing);

    await pump(tester, 'alice.skr', Chain.solana);
    expect(find.textContaining('Resolved as'), findsNothing);
  });
}
