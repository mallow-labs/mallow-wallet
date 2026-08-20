import 'package:flutter/material.dart';

import '../../../core/utils/address_format.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// Editorial step title with an optional back arrow.
class SendStepHeader extends StatelessWidget {
  const SendStepHeader({required this.title, this.onBack, super.key});

  final String title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      children: [
        if (onBack != null) ...[
          TapTargetExpander(
            child: GestureDetector(
              onTap: onBack,
              behavior: HitTestBehavior.opaque,
              child: MallowSvgIcon(
                'assets/icons/arrow_left.svg',
                width: 16,
                height: 16,
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: MallowTheme.spacingSm),
        ],
        Expanded(
          child: Text(
            title,
            style: MallowTheme.editorialSubhead.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Equal-width Cancel + primary CTA row pinned at the bottom of each step,
/// optionally preceded by the source-wallet "Your wallet / Switch" line.
class SendStepButtons extends StatelessWidget {
  const SendStepButtons({
    required this.primaryLabel,
    required this.onCancel,
    required this.onPrimary,
    this.isLoading = false,
    this.enabled = true,
    this.sourceAddress,
    this.onSwitch,
    super.key,
  });

  final String primaryLabel;
  final VoidCallback onCancel;
  final VoidCallback? onPrimary;
  final bool isLoading;
  final bool enabled;

  /// Active source wallet's address. When non-null, the "Your wallet" line is
  /// rendered above the buttons (send-wallet-select spec).
  final String? sourceAddress;

  /// Tap handler for "Switch". Null hides the Switch action — used when only
  /// one wallet qualifies, so the line still shows the source for context but
  /// offers nothing to switch to.
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) {
    final buttons = Row(
      children: [
        Expanded(
          child: MallowButton(
            label: 'Cancel',
            variant: MallowButtonVariant.secondary,
            onPressed: onCancel,
          ),
        ),
        const SizedBox(width: MallowTheme.spacingSm),
        Expanded(
          child: MallowButton(
            label: primaryLabel,
            isLoading: isLoading,
            enabled: enabled,
            onPressed: onPrimary,
          ),
        ),
      ],
    );

    if (sourceAddress == null) return buttons;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: MallowTheme.spacingLg),
        SendSourceLine(address: sourceAddress!, onSwitch: onSwitch),
        const SizedBox(height: MallowTheme.spacing12),
        buttons,
      ],
    );
  }
}

/// "Your wallet: `<addr>` · Switch" line shown above the bottom buttons on the
/// recipient, amount, and confirm steps (send-wallet-select spec).
class SendSourceLine extends StatelessWidget {
  const SendSourceLine({required this.address, this.onSwitch, super.key});

  final String address;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Your wallet: ',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                TextSpan(
                  text: truncateAddress(address),
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (onSwitch != null) ...[
          const SizedBox(width: MallowTheme.spacingSm),
          TapTargetExpander(
            child: GestureDetector(
              onTap: onSwitch,
              behavior: HitTestBehavior.opaque,
              child: Text(
                'Switch',
                style: MallowTheme.uiCaption.copyWith(color: colors.accent),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Recipient avatar: a resolved mallow pfp renders as a 4px-radius square
/// (matching artwork thumbnails); addresses without a profile fall back to
/// the circular generated identicon seeded by [seed] (normally the recipient
/// address — see `avatarSeedOf`).
class RecipientAvatar extends StatelessWidget {
  const RecipientAvatar({
    required this.size,
    this.imageUrl,
    this.seed = '',
    super.key,
  });

  final double size;
  final String? imageUrl;
  final String seed;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url != null && url.isNotEmpty) {
      return MallowNetworkImage(
        imageUrl: url,
        logicalSize: size,
        width: size,
        height: size,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
        errorBuilder: (_) => AccountAvatar(seed: seed, size: size),
      );
    }
    return AccountAvatar(seed: seed, size: size);
  }
}

/// Heading above a confirm-step [SendConfirmPill] ("Recipient", "Network fee").
///
/// Shared with the stake confirm sheet: the two sheets are meant to read as one
/// review surface, so a type or colour change here has to land on both.
class SendSectionLabel extends StatelessWidget {
  const SendSectionLabel({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: MallowTheme.uiMeta.copyWith(
        color: context.mallowColors.textPrimary,
      ),
    );
  }
}

/// The filled, fully-rounded row a confirm step states one fact in — the
/// address, the network, the fee, the swap output. Companion to
/// [SendSectionLabel]; see it for why both are shared.
class SendConfirmPill extends StatelessWidget {
  const SendConfirmPill({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 16, right: MallowTheme.spacingSm),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: context.mallowColors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
      ),
      child: child,
    );
  }
}

/// Outlined advisory notice: a warning-coloured hairline
/// box with a triangle glyph and caption copy, nothing filled.
///
/// Distinct on purpose from the filled `ConfirmationSimulationBanner` — that
/// one means "this transaction is expected to fail", this one means "look at
/// what you're sending to". Conflating them would either make advisories read
/// as failures or make failures read as dismissible.
class SendWarningNotice extends StatelessWidget {
  const SendWarningNotice({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final warning = context.mallowColors.warning;
    return Container(
      padding: const EdgeInsets.all(MallowTheme.spacing12),
      decoration: BoxDecoration(
        border: Border.all(color: warning),
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: Row(
        children: [
          MallowSvgIcon(
            'assets/icons/alert_triangle.svg',
            width: 16,
            height: 16,
            color: warning,
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          Expanded(
            child: Text(
              message,
              style: MallowTheme.uiCaption.copyWith(color: warning),
            ),
          ),
        ],
      ),
    );
  }
}
