import 'package:flutter/material.dart';
import 'package:mallow_wallet/core/services/social_auth_service.dart';
import 'package:mallow_wallet/features/onboarding/widgets/social_sign_in_menu.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mallow_wallet/shared/widgets/mallow_sheet.dart';

class CreateWalletMenu extends StatelessWidget {
  const CreateWalletMenu({
    required this.onGoogleSignIn,
    required this.onAppleSignIn,
    required this.onRecoveryPhraseTap,
    super.key,
  });

  /// Runs the Google social sign-in and resolves with its result, or null when
  /// the user cancels. Any other failure must *throw* — [SocialSignInMenu]
  /// renders it as an error snack bar. The sheet stays open with a spinner
  /// until this completes, then closes — so the user isn't left on a blank
  /// screen while the SDK launches the browser.
  final Future<SocialAuthResult?> Function() onGoogleSignIn;
  final Future<SocialAuthResult?> Function() onAppleSignIn;
  final VoidCallback onRecoveryPhraseTap;

  /// Shows the menu and resolves with the [SocialAuthResult] when the user
  /// completes a social sign-in, or null if they dismiss / pick another path.
  static Future<SocialAuthResult?> show(
    BuildContext context, {
    required Future<SocialAuthResult?> Function() onGoogleSignIn,
    required Future<SocialAuthResult?> Function() onAppleSignIn,
    required VoidCallback onRecoveryPhraseTap,
  }) {
    return showMallowSheet<SocialAuthResult?>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CreateWalletMenu(
        onGoogleSignIn: onGoogleSignIn,
        onAppleSignIn: onAppleSignIn,
        onRecoveryPhraseTap: onRecoveryPhraseTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SocialSignInMenu(
      title: RichText(
        text: TextSpan(
          style: MallowTheme.uiBody,
          children: [
            const TextSpan(text: 'Create a new '),
            TextSpan(text: 'wallet', style: MallowTheme.editorialSubhead),
          ],
        ),
      ),
      onGoogleSignIn: onGoogleSignIn,
      onAppleSignIn: onAppleSignIn,
      otherOptions: (busy) => [
        MallowButton(
          label: 'Use a recovery phrase',
          enabled: !busy,
          onPressed: onRecoveryPhraseTap,
          isFullWidth: true,
        ),
      ],
    );
  }
}
