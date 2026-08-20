import 'package:flutter/material.dart';

import '../../core/utils/address_format.dart';
import '../theme/mallow_theme.dart';
import 'artwork_sheet_image.dart';
import 'mallow_svg_icon.dart';

/// Centered artwork preview + `Title / @username` headline used at the
/// top of action bottom sheets (buy/offer/bid/update/burn confirmations,
/// make-offer, update-listing). Matches the Figma spec.
///
/// Secondary label resolution (creator-focused — never the artwork mint):
/// `@username` when [username] is set, otherwise the verbatim
/// [artistName] (no `@`), otherwise the truncated [creatorAddress] (the
/// update authority / signer for the asset). When none are available,
/// the secondary fragment is omitted entirely.
class ArtworkPreviewHeader extends StatelessWidget {
  const ArtworkPreviewHeader({
    super.key,
    this.title,
    this.imageUrl,
    this.username,
    this.artistName,
    this.creatorAddress,
    this.imageSize = 180,
    this.nsfw = false,
  });

  final String? title;
  final String? imageUrl;
  final String? username;
  final String? artistName;
  final String? creatorAddress;
  final double imageSize;

  /// Moderation flag: blurs the preview (with an eye-icon reveal) unless the
  /// viewer's show-NSFW setting is on.
  final bool nsfw;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final secondary = _resolveSecondary();
    final hasSecondary = secondary.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (imageUrl != null)
          ArtworkSheetImage(
            imageUrl: imageUrl!,
            nsfw: nsfw,
            height: imageSize,
            borderRadius: BorderRadius.circular(MallowTheme.radiusSm),
            errorBuilder: (_) => _Fallback(size: imageSize),
          )
        else
          Center(child: _Fallback(size: imageSize)),
        const SizedBox(height: MallowTheme.spacingLg),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: title ?? 'Artwork',
                style: MallowTheme.editorialSubhead.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              if (hasSecondary) ...[
                TextSpan(
                  text: ' / ',
                  style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                ),
                TextSpan(
                  text: secondary,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.left,
        ),
      ],
    );
  }

  String _resolveSecondary() {
    final handle = username?.trim();
    if (handle != null && handle.isNotEmpty) return '@$handle';
    final name = artistName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final addr = creatorAddress?.trim();
    if (addr != null && addr.isNotEmpty) return truncateAddress(addr);
    return '';
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: context.mallowColors.divider,
        borderRadius: BorderRadius.circular(MallowTheme.radiusSm),
      ),
      alignment: Alignment.center,
      child: MallowSvgIcon(
        'assets/icons/stamp.svg',
        color: context.mallowColors.textSecondary,
        width: 32,
        height: 32,
      ),
    );
  }
}
