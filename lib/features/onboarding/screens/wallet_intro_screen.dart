import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mallow_wallet/shared/widgets/mallow_header.dart';
import 'package:mallow_wallet/shared/widgets/mallow_svg_icon.dart';

class WalletIntroScreen extends StatelessWidget {
  const WalletIntroScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              const MallowHeader(title: 'Create your wallet'),
              const SizedBox(height: 60),
              const SizedBox(height: 20),
              Divider(color: context.mallowColors.dividerLight),
              const SizedBox(height: 20),
              // Info rows
              _buildInfoRow(
                context: context,
                iconPath: 'assets/icons/padlock.svg',
                title: 'Your keys, your art',
                subtitle: 'Only you have access to your recovery phrase',
              ),
              const SizedBox(height: 12),
              _buildInfoRow(
                context: context,
                iconPath: 'assets/icons/invisible_padded.svg',
                title: 'Never share your recovery phrase',
                subtitle: 'mallow will never ask for your recovery phrase',
              ),
              const SizedBox(height: 12),
              _buildInfoRow(
                context: context,
                iconPath: 'assets/icons/shield.svg',
                title: 'Store it securely',
                subtitle: "If it's lost, your wallet can't be recovered",
              ),
              const SizedBox(height: 20),
              Divider(color: context.mallowColors.dividerLight),
              const SizedBox(height: 20),
              // Explanation text
              Text(
                "We'll generate a unique recovery phrase on your device. We never store it or have access to it.",
                textAlign: TextAlign.center,
                style: MallowTheme.uiLabel.copyWith(
                  color: context.mallowColors.textPrimary,
                ),
              ),
              const Spacer(),
              // Button
              MallowButton(
                label: 'Generate recovery phrase',
                onPressed: () => context.push('/onboarding/seed-phrase'),
                isFullWidth: true,
              ),
              const SizedBox(height: 20),
              Center(
                child: Text(
                  "You'll confirm your phrase on the next step",
                  style: MallowTheme.uiCaption.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow({
    required BuildContext context,
    required String iconPath,
    required String title,
    required String subtitle,
  }) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          child: MallowSvgIcon(
            iconPath,
            width: 48,
            height: 48,
            color: context.mallowColors.textSecondary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.newsreader(
                  fontSize: 15,
                  fontStyle: FontStyle.italic,
                  color: context.mallowColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: MallowTheme.uiCaption.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
