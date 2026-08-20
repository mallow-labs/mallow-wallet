import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/social_auth_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../widgets/artwork_ring_3d.dart';
import '../widgets/create_wallet_menu.dart';
import '../widgets/import_wallet_menu.dart';

/// Welcome/splash screen for new users.
///
/// Entry point for onboarding flow. Presents options to:
/// - Create a new wallet
/// - Import an existing wallet
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(
            left: MallowTheme.spacingLg,
            right: MallowTheme.spacingLg,
            top: MallowTheme.spacingLg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              // 3D Artwork Ring
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.35,
                child: const PerspectiveCarousel3D(
                  assetPaths: kDefaultCarouselAssets,
                  artworkInfos: kDefaultCarouselArtworks,
                ),
              ),
              const SizedBox(height: 20),
              // Logo
              _buildLogo(context),
              const SizedBox(height: 20),
              // Welcome text with mixed typography
              RichText(
                textAlign: TextAlign.left,
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: 'your ',
                      style: MallowTheme.uiIdentity.copyWith(
                        color: context.mallowColors.textPrimary,
                      ),
                    ),
                    TextSpan(
                      text: 'art wallet',
                      style: GoogleFonts.newsreader(
                        fontSize: 20,
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w500,
                        color: context.mallowColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: MallowTheme.spacingMd),
              // Description - line 1 (Bodoni Moda Italic)
              Text(
                'Collect, curate & display',
                style: GoogleFonts.newsreader(
                  fontSize: 17,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w400,
                  color: context.mallowColors.textSecondary,
                ),
                textAlign: TextAlign.left,
              ),
              const SizedBox(height: 0),
              // Description - line 2 (Inter Regular)
              Text(
                'digital artwork across Solana, Tezos and Ethereum',
                style: MallowTheme.uiBody.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
                textAlign: TextAlign.left,
              ),
              const SizedBox(height: MallowTheme.spacingMd),
              // Self-custodial line
              Text(
                'Self-custodial · No email required',
                style: MallowTheme.uiCaption.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
                textAlign: TextAlign.left,
              ),
              const Spacer(flex: 2),
              // Select option text
              Center(
                child: Text(
                  'Select an option below to get started',
                  style: MallowTheme.uiMeta.copyWith(
                    color: context.mallowColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: MallowTheme.spacing20),
              // Action buttons
              MallowButton(
                label: 'Create a new wallet',
                onPressed: () => _showCreateWalletMenu(context),
                isFullWidth: true,
              ),
              const SizedBox(height: 12),
              MallowButton(
                label: 'I already have a wallet',
                onPressed: () => _showImportWalletMenu(context),
                variant: MallowButtonVariant.secondary,
                isFullWidth: true,
              ),
              SizedBox(height: 32 + MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCreateWalletMenu(BuildContext context) async {
    // Social sign-in results are handled by the top-level listener in
    // `app.dart` (which persists the wallet and navigates), so it survives the
    // OAuth round-trip even when this sheet/screen is torn down on resume.
    await CreateWalletMenu.show(
      context,
      onGoogleSignIn: () => sl<SocialAuthService>().signInWithGoogle(),
      onAppleSignIn: () => sl<SocialAuthService>().signInWithApple(),
      onRecoveryPhraseTap: () {
        Navigator.pop(context);
        context.push('/onboarding/wallet-intro');
      },
    );
  }

  Future<void> _showImportWalletMenu(BuildContext context) async {
    await ImportWalletMenu.show(
      context,
      onGoogleSignIn: () => sl<SocialAuthService>().signInWithGoogle(),
      onAppleSignIn: () => sl<SocialAuthService>().signInWithApple(),
      onPrivateKeyTap: () {
        Navigator.pop(context);
        context.push(AppRoutes.importPrivateKeyGlobal);
      },
      onHardwareWalletTap: () {
        Navigator.pop(context);
        context.push(AppRoutes.ledgerScan);
      },
      onRecoveryPhraseTap: () {
        Navigator.pop(context);
        context.push(AppRoutes.importWallet);
      },
    );
  }

  Widget _buildLogo(BuildContext context) {
    return SvgPicture.asset(
      'assets/icons/mallow_icon.svg',
      width: 41,
      colorFilter: ColorFilter.mode(
        context.mallowColors.textPrimary,
        BlendMode.srcIn,
      ),
    );
  }
}
