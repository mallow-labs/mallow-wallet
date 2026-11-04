import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/widgets/mallow_button.dart';
import 'artwork_sheet_frame.dart';

/// Bottom sheet shown in place of a Solana signing CTA when the session holds
/// no Solana key — e.g. a profile whose only imported wallet is Tezos, with its
/// Solana wallets linked watch-only. The CTA opens the in-app add-wallet
/// chooser ([AppRoutes.addWalletGlobal]); the detail screen listens to the
/// session, so the import re-resolves the sheet.
///
/// Not [AppRoutes.importWallet]: that is an `/onboarding/*` route, and the
/// router's redirect sends an onboarded user on one straight to home.
class ArtworkImportWalletSheet extends StatelessWidget {
  const ArtworkImportWalletSheet({
    required this.action,
    required this.watchOnly,
    super.key,
  });

  /// What importing unlocks ("buy", "place a bid"), or null for generic copy.
  final String? action;

  /// The session links a Solana wallet but holds no key for it.
  final bool watchOnly;

  String get _message {
    final doing = action ?? 'sign for this artwork';
    return watchOnly
        ? 'Your Solana wallet is watch-only. Import its private key to $doing.'
        : 'This account has no Solana wallet that can sign. '
              'Import one to $doing.';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return ArtworkSheetFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _message,
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: MallowTheme.spacingSm),
          MallowButton(
            label: 'Import wallet',
            onPressed: () => context.push(AppRoutes.addWalletGlobal),
            isFullWidth: true,
          ),
        ],
      ),
    );
  }
}
