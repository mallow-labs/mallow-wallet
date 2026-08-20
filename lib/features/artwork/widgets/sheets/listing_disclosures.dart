import 'package:flutter/material.dart';

import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/widgets/mallow_network_image.dart';
import '../../../../shared/widgets/mallow_svg_icon.dart';
import '../../services/artwork_bloc.dart';

/// Which disclosure is currently expanded. Only one is open at a time —
/// expanding one collapses the other.
enum _DisclosureKind { none, physical, rewards }

/// "Physical available" / "Rewards included" disclosures for the listed
/// bottom sheets. Reads the seller-supplied [ArtworkDetails.rewardsInfo] and
/// renders a collapsible row per available extra. Renders nothing when the
/// listing carries neither.
///
/// Behaviour mirrors the webapp's artwork extras: only one disclosure is
/// open at a time (opening one collapses the other), each expands its
/// "Message from the seller:" body + a responsibility disclaimer. The
/// expand/collapse uses the same 200ms easeOutCubic crossfade + `+`/`−`
/// glyph switcher as [FeeDetailsDisclosure], so the sheet height animates
/// consistently with the rest of the app.
class ListingDisclosures extends StatefulWidget {
  const ListingDisclosures({required this.artwork, super.key});

  final ArtworkDetails artwork;

  @override
  State<ListingDisclosures> createState() => _ListingDisclosuresState();
}

class _ListingDisclosuresState extends State<ListingDisclosures> {
  _DisclosureKind _open = _DisclosureKind.none;

  void _toggle(_DisclosureKind kind) {
    setState(() {
      _open = _open == kind ? _DisclosureKind.none : kind;
    });
  }

  @override
  Widget build(BuildContext context) {
    final artwork = widget.artwork;
    final hasPhysical = artwork.hasPhysical;
    final hasRewards = artwork.hasRewards;
    if (!hasPhysical && !hasRewards) return const SizedBox.shrink();

    // Empty/whitespace copy is normalized to null by `_DisclosureTile`'s own
    // guard, so pass the trimmed strings straight through.
    final physicalDescription = artwork
        .rewardsInfo
        ?.physicalDetails
        ?.description
        .trim();
    final rewardsDescription = artwork.rewardsInfo?.rewardsDescription?.trim();

    // The seller opted into collecting a shipping address at checkout
    // (`rewardsDescription.askForShippingAddress`, the same flag mobile's own
    // listing forms write). The webapp gates the buy behind its shipping form
    // and threads the generated order id into an `order:<id>` memo; mobile has
    // no shipping form and sends no `orderId`, so the purchase completes with
    // no order record and the seller has nothing to ship to. The buy is
    // deliberately still allowed — this disclosure is what keeps it honest, so
    // the buyer knows to reach the seller themselves.
    final asksForShipping = artwork.rewardsInfo?.askForShippingAddress ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: MallowTheme.spacingMd),
        if (hasPhysical)
          _DisclosureTile(
            leading: _PhysicalThumbnail(imageUrl: artwork.imageUrl),
            label: 'Physical available',
            expanded: _open == _DisclosureKind.physical,
            onTap: () => _toggle(_DisclosureKind.physical),
            description: physicalDescription,
            disclaimer:
                'Physicals are the responsibility of the seller to '
                'distribute. No disputes will be resolved by mallow.'
                '${asksForShipping ? ' This app cannot collect a shipping '
                          'address yet, so none is sent with your purchase — '
                          'contact the seller to arrange delivery, or buy on '
                          'mallow.art to enter your address at checkout.' : ''}',
          ),
        if (hasPhysical && hasRewards)
          const SizedBox(height: MallowTheme.spacingSm),
        if (hasRewards)
          _DisclosureTile(
            leading: const _RewardsThumbnail(),
            label: 'Rewards included',
            expanded: _open == _DisclosureKind.rewards,
            onTap: () => _toggle(_DisclosureKind.rewards),
            description: rewardsDescription,
            disclaimer:
                'Rewards are the responsibility of the seller to '
                'distribute. No disputes will be resolved by mallow.',
          ),
      ],
    );
  }
}

/// 32×32 rounded artwork thumbnail shown beside the "Physical available"
/// row. Falls back to a muted box when the listing has no image URL.
class _PhysicalThumbnail extends StatelessWidget {
  const _PhysicalThumbnail({required this.imageUrl});

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(MallowTheme.radiusPrimary);
    if (imageUrl.isEmpty) {
      return Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: context.mallowColors.bgPrimary,
          borderRadius: radius,
        ),
      );
    }
    return MallowNetworkImage(
      imageUrl: imageUrl,
      logicalSize: 32,
      width: 32,
      height: 32,
      borderRadius: radius,
    );
  }
}

/// 32×32 box with the gift icon shown beside the "Rewards included" row.
class _RewardsThumbnail extends StatelessWidget {
  const _RewardsThumbnail();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.mallowColors.bgPrimary,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: const MallowSvgIcon(
        'assets/icons/rewards.svg',
        width: 20,
        height: 20,
      ),
    );
  }
}

/// A single collapsible disclosure row: a tappable header with a `+`/`−`
/// glyph and an [AnimatedCrossFade] body. Mirrors [FeeDetailsDisclosure]'s
/// animation timing so disclosures read identically across the app.
class _DisclosureTile extends StatelessWidget {
  const _DisclosureTile({
    required this.leading,
    required this.label,
    required this.expanded,
    required this.onTap,
    required this.disclaimer,
    this.description,
  });

  /// 32×32 thumbnail rendered at the start of the header row.
  final Widget leading;
  final String label;
  final bool expanded;
  final VoidCallback onTap;
  final String disclaimer;

  /// Seller's message shown when expanded. Null when the listing flagged the
  /// extra without supplying copy — the disclaimer still renders.
  final String? description;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final headerStyle = MallowTheme.uiCaption.copyWith(
      color: colors.textPrimary,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: MallowTheme.spacingXs,
            ),
            child: Row(
              children: [
                leading,
                const SizedBox(width: MallowTheme.spacingMd),
                Expanded(child: Text(label, style: headerStyle)),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    expanded ? '−' : '+',
                    key: ValueKey(expanded),
                    style: headerStyle,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.only(bottom: MallowTheme.spacingMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (description != null && description!.isNotEmpty) ...[
                  Text(
                    'Message from the seller:',
                    style: MallowTheme.uiMeta.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingXs),
                  Text(
                    description!,
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                ],
                Text(
                  'Please note: $disclaimer',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          crossFadeState: expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
          sizeCurve: Curves.easeOutCubic,
        ),
      ],
    );
  }
}
