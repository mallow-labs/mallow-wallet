import 'package:flutter/material.dart';

import '../../core/models/account.dart';
import '../theme/mallow_colors.dart';
import 'mallow_svg_icon.dart';
import 'social_provider_icon.dart';

/// Small provenance icon shown 8px to the right of a wallet/account name,
/// indicating where the wallet comes from: watch-only (eye), Ledger (the
/// Ledger mark), Seed Vault (a half shield), Keystone (the Keystone mark), or a
/// social provider (Google / Apple). Centralised so every name surface renders the badge
/// identically. Renders nothing for a plain HD/imported account (a null
/// [badge]).
///
/// A Google or Apple wallet from the older sign-in
/// (`WalletBadge.googleLegacy` / `appleLegacy`) is drawn by the same
/// [SocialProviderIcon] with its legacy mark, so every surface that shows this
/// badge marks such a wallet without knowing about it.
class WalletTypeBadge extends StatelessWidget {
  const WalletTypeBadge(this.badge, {super.key, this.size = 14});

  final WalletBadge? badge;
  final double size;

  @override
  Widget build(BuildContext context) {
    final badge = this.badge;
    if (badge == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: switch (badge) {
        // The monochrome marks have different intrinsic aspect ratios and
        // visual weight, so each carries a scale factor to even out their
        // perceived size at a shared [size].
        WalletBadge.watchOnly => _mono(context, 'assets/icons/watch.svg', 0.6),
        WalletBadge.ledger => _mono(
          context,
          'assets/icons/brand_ledger.svg',
          1.0,
        ),
        WalletBadge.seedVault => _mono(
          context,
          'assets/icons/shield_half.svg',
          1.0,
        ),
        WalletBadge.keystone => _mono(
          context,
          'assets/icons/brand_keystone.svg',
          0.9,
        ),
        WalletBadge.google => SocialProviderIcon(
          provider: 'google',
          size: size,
        ),
        WalletBadge.googleLegacy => SocialProviderIcon(
          provider: 'google',
          legacy: true,
          size: size,
        ),
        WalletBadge.apple => SocialProviderIcon(provider: 'apple', size: size),
        WalletBadge.appleLegacy => SocialProviderIcon(
          provider: 'apple',
          legacy: true,
          size: size,
        ),
      },
    );
  }

  /// A monochrome mark, tinted to the theme so it stays legible in light and
  /// dark mode.
  Widget _mono(BuildContext context, String asset, double scale) =>
      MallowSvgIcon(
        asset,
        width: size * scale,
        height: size * scale,
        color: context.mallowColors.textSecondary,
      );
}
