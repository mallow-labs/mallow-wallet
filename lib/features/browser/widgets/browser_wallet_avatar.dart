import 'package:flutter/material.dart';

import '../../../core/models/account.dart';
import '../../../core/services/avatar_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';

/// A wallet's identicon, optionally inside a status [ring] (positive
/// for "connected to this site"). With no [wallet] it draws the wallet glyph
/// on a muted disc, the "choose a wallet" state.
class BrowserWalletAvatar extends StatelessWidget {
  const BrowserWalletAvatar({
    required this.wallet,
    required this.size,
    this.ring,
    super.key,
  });

  final WalletInfo? wallet;

  /// Outer diameter, ring included.
  final double size;
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final inner = ring == null ? size : size - 8;
    final wallet = this.wallet;
    final Widget face = wallet == null
        ? Container(
            width: inner,
            height: inner,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              shape: BoxShape.circle,
            ),
            child: MallowSvgIcon(
              'assets/icons/wallet.svg',
              width: inner * 0.55,
              height: inner * 0.55,
              color: colors.textSecondary,
            ),
          )
        // Widget tests and previews run without DI; they get the initials
        // disc that AccountAvatar would otherwise replace. Seeded from the
        // address: a wallet's stored name is an internal label.
        : sl.isRegistered<AvatarService>()
        ? AccountAvatar(
            seed: avatarSeedOf(address: wallet.address),
            size: inner,
          )
        : _Initials(name: wallet.address, size: inner);
    if (ring == null) return ExcludeSemantics(child: face);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: ring!, width: 2),
        ),
        child: face,
      ),
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final words = name.trim().split(RegExp(r'\s+'));
    final initials = words
        .where((word) => word.isNotEmpty)
        .take(2)
        .map((word) => word.characters.first.toUpperCase())
        .join();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colors.accent, shape: BoxShape.circle),
      child: Text(
        initials,
        textScaler: TextScaler.noScaling,
        style: MallowTheme.uiLabel.copyWith(
          fontSize: size * 0.36,
          fontWeight: FontWeight.w600,
          color: colors.textOnAccent,
        ),
      ),
    );
  }
}
