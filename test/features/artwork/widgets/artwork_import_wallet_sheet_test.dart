import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_import_wallet_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// The CTA must open the in-app add-wallet chooser. It used to push the
/// onboarding import route, which the router redirects to home for an
/// onboarded user, so the tap just dropped them on the home tab.
void main() {
  testWidgets('Import wallet opens the in-app add-wallet chooser', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(
            body: ArtworkImportWalletSheet(action: 'buy', watchOnly: true),
          ),
        ),
        GoRoute(
          path: AppRoutes.addWalletGlobal,
          builder: (_, _) => const Text('add wallet chooser'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: MallowTheme.lightTheme, routerConfig: router),
    );

    expect(
      find.text(
        'Your Solana wallet is watch-only. Import its private key to buy.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Import wallet'));
    await tester.pumpAndSettle();

    expect(find.text('add wallet chooser'), findsOneWidget);
  });
}
