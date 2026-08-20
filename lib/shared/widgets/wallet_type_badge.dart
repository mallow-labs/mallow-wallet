import 'package:flutter/material.dart';

import '../../core/models/account.dart';
import '../theme/mallow_colors.dart';
import 'mallow_svg_icon.dart';

/// Small provenance icon shown 8px to the right of a wallet/account name,
/// indicating where the wallet comes from: watch-only (eye), hardware (Ledger),
/// or a social provider (Google / Apple). Centralised so every name surface
/// renders the badge identically. Renders nothing for a plain HD/imported
/// account (a null [badge]).
class WalletTypeBadge extends StatelessWidget {
  const WalletTypeBadge(this.badge, {super.key, this.size = 14});

  final WalletBadge? badge;
  final double size;

  @override
  Widget build(BuildContext context) {
    final badge = this.badge;
    if (badge == null) return const SizedBox.shrink();

    // Google keeps its multi-colour brand mark; the rest are monochrome and
    // tint to the theme so they stay legible in light and dark mode. The icons
    // have different intrinsic aspect ratios and visual weight, so each carries
    // a scale factor to even out their perceived size at a shared [size].
    final (asset, color, scale) = switch (badge) {
      WalletBadge.watchOnly => (
        'assets/icons/watch.svg',
        context.mallowColors.textSecondary,
        0.6,
      ),
      WalletBadge.hardware => (
        'assets/icons/hardware_wallet.svg',
        context.mallowColors.textSecondary,
        1.3,
      ),
      WalletBadge.apple => (
        'assets/icons/apple.svg',
        context.mallowColors.textPrimary,
        1.0,
      ),
      WalletBadge.google => ('assets/icons/google.svg', null, 1.0),
    };

    final dimension = size * scale;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: MallowSvgIcon(
        asset,
        width: dimension,
        height: dimension,
        color: color,
        useOriginalColors: badge == WalletBadge.google,
      ),
    );
  }
}
