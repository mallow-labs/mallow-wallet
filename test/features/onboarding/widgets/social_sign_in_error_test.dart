import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/social_auth_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart'
    show DuplicateWalletException;
import 'package:mallow_wallet/features/onboarding/widgets/social_sign_in_menu.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/app_snack_bar.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';

/// The social sheet is the only surface between a failed Web3Auth login and the
/// user: `SocialAuthService` rethrows every non-cancel failure precisely so the
/// sheet can name a reason. Before this, the sheet caught and dropped them, so a
/// missing client id, an offline device, or an address already held by an
/// imported wallet all looked identical — the spinner stopped and nothing else
/// happened, with no account and no way to tell why.
///
/// Cancellation is the one case that must stay silent: the service returns null
/// for the user's own abort, and an error toast there would accuse the user of a
/// failure they chose.
void main() {
  const genericMessage =
      'Could not sign in. Check your connection and '
      'try again.';
  const duplicateMessage =
      'This wallet was already added with a recovery phrase, private key '
      'or hardware wallet. Use that account instead.';

  tearDown(AppSnackBar.dismiss);

  Future<void> pumpMenu(
    WidgetTester tester,
    Future<SocialAuthResult?> Function() onGoogleSignIn,
  ) async {
    // Wide enough that the test font (every glyph a fixed, oversized box)
    // doesn't overflow the button rows the way a real font wouldn't.
    tester.view.physicalSize = const Size(2400, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: SocialSignInMenu(
            title: const Text('Create a new wallet'),
            onGoogleSignIn: onGoogleSignIn,
            onAppleSignIn: () async => null,
            otherOptions: (_) => const <Widget>[],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Taps Google and lets the sign-in future settle plus the snack bar animate
  /// in. Explicit pumps rather than `pumpAndSettle` so an in-flight button
  /// spinner can never hang the test.
  Future<void> tapGoogle(WidgetTester tester) async {
    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// The Google button's live state — `isLoading` false is what lets the user
  /// retry, and what `PopScope` reads to re-enable dismissal.
  MallowButton googleButton(WidgetTester tester) => tester.widget<MallowButton>(
    find.ancestor(
      of: find.text('Continue with Google'),
      matching: find.byType(MallowButton),
    ),
  );

  testWidgets('a failed sign-in names a reason and stays retryable', (
    tester,
  ) async {
    await pumpMenu(
      tester,
      () async => throw StateError(
        'WEB3AUTH_CLIENT_ID is not configured — social sign-in cannot start.',
      ),
    );

    await tapGoogle(tester);

    expect(find.text(genericMessage), findsOneWidget);
    // The thrown reason carries build config and SDK internals, so it is
    // logged, never rendered.
    expect(find.textContaining('WEB3AUTH_CLIENT_ID'), findsNothing);
    expect(googleButton(tester).isLoading, isFalse);
  });

  testWidgets('a cross-wallet-type duplicate says the wallet is already here', (
    tester,
  ) async {
    // `addSocialAccount` throws this when the derived address is already an
    // hd/imported/ledger row. Retrying the same provider re-derives the same
    // address, so this failure is permanent — a "try again" would be a lie.
    await pumpMenu(
      tester,
      () async =>
          throw DuplicateWalletException('9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrr'),
    );

    await tapGoogle(tester);

    expect(find.text(duplicateMessage), findsOneWidget);
    expect(find.text(genericMessage), findsNothing);
  });

  testWidgets('a cancelled sign-in shows no error', (tester) async {
    // Null is cancellation only: `SocialAuthService._signIn` swallows the
    // browser/app abort and rethrows everything else.
    await pumpMenu(tester, () async => null);

    await tapGoogle(tester);

    expect(find.text(genericMessage), findsNothing);
    expect(find.text(duplicateMessage), findsNothing);
    expect(googleButton(tester).isLoading, isFalse);
  });
}
