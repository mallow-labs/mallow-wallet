import 'package:flutter/material.dart';
import 'package:mallow_wallet/core/services/social_auth_service.dart';
import 'package:mallow_wallet/features/onboarding/widgets/social_sign_in_menu.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mallow_wallet/shared/widgets/mallow_sheet.dart';

class ImportWalletMenu extends StatelessWidget {
  const ImportWalletMenu({
    required this.onGoogleSignIn,
    required this.onAppleSignIn,
    required this.onPrivateKeyTap,
    required this.onHardwareWalletTap,
    required this.onRecoveryPhraseTap,
    this.onSeedVaultTap,
    super.key,
  });

  /// Runs the Google social sign-in and resolves with its result, or null when
  /// the user cancels. Any other failure must *throw* — [SocialSignInMenu]
  /// renders it as an error snack bar. The sheet stays open with a spinner
  /// until this completes, then closes — so the user isn't left on a blank
  /// screen while the SDK launches the browser.
  final Future<SocialAuthResult?> Function() onGoogleSignIn;
  final Future<SocialAuthResult?> Function() onAppleSignIn;
  final VoidCallback onPrivateKeyTap;
  final VoidCallback onHardwareWalletTap;
  final VoidCallback onRecoveryPhraseTap;

  /// Seed Vault import. Null on every device without a Seed Vault
  /// implementation — which is every iPhone and every Android phone that is not
  /// a Solana Mobile device — and the row is then not rendered at all. The
  /// caller owns that check, so this widget never probes the platform itself.
  final VoidCallback? onSeedVaultTap;

  /// Shows the menu and resolves with the [SocialAuthResult] when the user
  /// completes a social sign-in, or null if they dismiss / pick another path.
  static Future<SocialAuthResult?> show(
    BuildContext context, {
    required Future<SocialAuthResult?> Function() onGoogleSignIn,
    required Future<SocialAuthResult?> Function() onAppleSignIn,
    required VoidCallback onPrivateKeyTap,
    required VoidCallback onHardwareWalletTap,
    required VoidCallback onRecoveryPhraseTap,
    VoidCallback? onSeedVaultTap,
  }) {
    return showMallowSheet<SocialAuthResult?>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ImportWalletMenu(
        onGoogleSignIn: onGoogleSignIn,
        onAppleSignIn: onAppleSignIn,
        onPrivateKeyTap: onPrivateKeyTap,
        onHardwareWalletTap: onHardwareWalletTap,
        onRecoveryPhraseTap: onRecoveryPhraseTap,
        onSeedVaultTap: onSeedVaultTap,
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
            const TextSpan(text: 'I already have a '),
            TextSpan(text: 'wallet', style: MallowTheme.editorialSubhead),
          ],
        ),
      ),
      onGoogleSignIn: onGoogleSignIn,
      onAppleSignIn: onAppleSignIn,
      otherOptions: (busy) => [
        // Private key button (outline)
        MallowButton(
          label: 'Use a private key',
          variant: MallowButtonVariant.secondary,
          enabled: !busy,
          onPressed: onPrivateKeyTap,
          isFullWidth: true,
        ),
        const SizedBox(height: 12),
        // Hardware wallet button (outline)
        MallowButton(
          label: 'Use a hardware wallet',
          variant: MallowButtonVariant.secondary,
          enabled: !busy,
          onPressed: onHardwareWalletTap,
          isFullWidth: true,
        ),
        // Seed Vault button (outline) — only on a device that has one.
        if (onSeedVaultTap case final onTap?) ...[
          const SizedBox(height: 12),
          MallowButton(
            label: 'Use Seed Vault',
            variant: MallowButtonVariant.secondary,
            enabled: !busy,
            onPressed: onTap,
            isFullWidth: true,
          ),
        ],
        const SizedBox(height: 12),
        // Recovery phrase button (primary)
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
