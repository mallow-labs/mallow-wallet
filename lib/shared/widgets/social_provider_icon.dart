import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import '../utils/social_wallet_copy.dart';
import 'mallow_svg_icon.dart';

/// The Google or Apple mark shown as a wallet's type, with the small mark of
/// the older sign-in at its bottom right when [legacy] is set.
///
/// The one place that draws either. A wallet made by the current sign-in (a
/// social vault wallet) shows the plain provider mark; one made by the older
/// sign-in, the one run by Web3Auth, carries the extra mark, so the two are
/// never mistaken for each other. Pass `WalletInfo.isLegacySocialWallet` (or
/// `Account.isLegacySocial`) as [legacy]; nothing else decides it.
class SocialProviderIcon extends StatelessWidget {
  const SocialProviderIcon({
    required this.provider,
    this.legacy = false,
    this.size = 20,
    super.key,
  });

  /// `apple` draws the Apple mark; anything else (a social wallet with no
  /// recorded provider included) draws Google's.
  final String? provider;

  /// Whether this is a wallet from the older sign-in.
  final bool legacy;

  /// Side of the provider mark, in logical pixels.
  final double size;

  /// The mark of the older sign-in: Web3Auth's logo, white on transparent.
  ///
  /// It is Web3Auth's trademark, drawn as supplied (never tinted or redrawn)
  /// and only to say which service made the wallet. THIRD_PARTY_NOTICES.md
  /// records where the file came from.
  static const legacyMarkAsset = 'assets/icons/web3auth_mark.png';

  /// Web3Auth's brand blue, the plate behind its mark: a third-party brand
  /// colour, the same in light and dark, so it is not a theme token.
  static const _web3AuthBlue = Color(0xFF0364FF);

  /// How far the legacy mark's plate reaches past the provider mark, as a
  /// fraction of [size]. The widget grows by this much (right and bottom)
  /// when [legacy] is set, so the plate is never clipped by a tight row.
  static const _overhang = 0.25;

  /// Diameter of the legacy mark's plate, as a fraction of [size].
  static const _plate = 0.62;

  /// Side of the legacy mark's image, as a fraction of the plate. The W's top
  /// corners sit 1.14 half-sides from the image's centre, so at 0.6 they stop
  /// about a third of the plate's radius short of its edge: clear of the
  /// ring, with padding left over.
  static const _glyph = 0.6;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final apple = provider == 'apple';
    final mark = MallowSvgIcon(
      apple ? 'assets/icons/apple.svg' : 'assets/icons/google.svg',
      width: size,
      height: size,
      // Google keeps its multi-colour brand mark; Apple's fill is near-black
      // and tints to the theme so it stays legible in dark mode.
      useOriginalColors: !apple,
      color: apple ? colors.textPrimary : null,
    );
    if (!legacy) return mark;

    final plate = size * _plate;
    return Semantics(
      label: 'Older sign-in',
      child: SizedBox(
        width: size * (1 + _overhang),
        height: size * (1 + _overhang),
        child: Stack(
          children: [
            Positioned(left: 0, top: 0, child: mark),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                key: const ValueKey('legacy-sign-in-mark'),
                width: plate,
                height: plate,
                decoration: BoxDecoration(
                  color: _web3AuthBlue,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.bgPrimary),
                ),
                alignment: Alignment.center,
                child: Image.asset(
                  legacyMarkAsset,
                  width: plate * _glyph,
                  height: plate * _glyph,
                  // The plate's `Semantics` label already says what it is.
                  excludeFromSemantics: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// [legacySocialSentence] beside the marked provider icon: the note a
/// wallet's detail screens show for a wallet from the older sign-in.
class LegacySocialNote extends StatelessWidget {
  const LegacySocialNote({required this.provider, super.key});

  /// `google` or `apple`.
  final String? provider;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SocialProviderIcon(provider: provider, legacy: true),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            legacySocialSentence(provider == 'apple' ? 'Apple' : 'Google'),
            style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}
