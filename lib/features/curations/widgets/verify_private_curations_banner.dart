import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';

/// In-tab CTA shown above the Curations list when the active wallet is a
/// Ledger that hasn't yet signed in (no valid `wallet-sig` session), so the
/// backend is only returning public curations.
///
/// Tapping [onVerify] should trigger the wallet verification / signing flow;
/// on success the hosting bloc refetches curations and private ones appear.
/// Presentational only — the screen owns the verify behaviour and the
/// [isVerifying] flag.
class VerifyPrivateCurationsBanner extends StatelessWidget {
  const VerifyPrivateCurationsBanner({
    required this.onVerify,
    this.isVerifying = false,
    super.key,
  });

  final VoidCallback onVerify;
  final bool isVerifying;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        MallowTheme.spacing20,
        0,
        MallowTheme.spacing20,
        MallowTheme.spacingMd,
      ),
      padding: const EdgeInsets.all(MallowTheme.spacingMd),
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: BorderRadius.circular(MallowTheme.radiusMd),
        border: Border.all(color: colors.dividerLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Verify wallet to see private curations',
            style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          MallowButton(
            label: 'Verify wallet',
            size: MallowButtonSize.small,
            isLoading: isVerifying,
            onPressed: onVerify,
          ),
        ],
      ),
    );
  }
}
