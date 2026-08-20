import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tappable.dart';

/// "N offers hidden from blocked accounts" — the disclosure the offers inbox
/// owes the viewer whenever the backend filters offers out of the feed.
///
/// Blocked offers are filtered, never silently invisible. An offer is money on
/// the viewer's own artwork; a block that quietly swallows the highest bid is a
/// support ticket, not a feature. The row states the count unconditionally and
/// expands to explain what to do about it.
///
/// The withheld offers themselves are not in the response — the backend
/// excludes them and sends only the count — so expanding reveals the *route
/// back*: unblocking in Settings restores them on the next load.
///
/// The count is for the whole merged unpaged feed, not the current page, and
/// it is deliberately not a claim about auction figures: the backend does not
/// blank `auction.recentBids` / `highestBid` for blocked bidders, so the
/// numbers a seller prices against are complete. The expanded copy says so.
class OffersBlockedDisclosure extends StatefulWidget {
  const OffersBlockedDisclosure({required this.count, super.key});

  final int count;

  @override
  State<OffersBlockedDisclosure> createState() =>
      _OffersBlockedDisclosureState();
}

class _OffersBlockedDisclosureState extends State<OffersBlockedDisclosure> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final plural = widget.count == 1 ? 'offer' : 'offers';

    return Container(
      margin: const EdgeInsets.only(bottom: MallowTheme.spacingLg),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Tappable(
            onTap: () => setState(() => _expanded = !_expanded),
            semanticLabel:
                '${widget.count} $plural hidden from blocked accounts',
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MallowTheme.spacingMd,
                vertical: 14,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.count} $plural hidden from blocked accounts',
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: MallowTheme.spacingSm),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: MallowSvgIcon(
                      'assets/icons/arrow_down.svg',
                      width: 14,
                      height: 14,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacingMd,
                0,
                MallowTheme.spacingMd,
                MallowTheme.spacingMd,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'These offers are still live on-chain — blocking only '
                    'changes what is listed here, it does not cancel or '
                    'reject anything. Auction bid history and the current '
                    'high bid still include them, so the numbers you price '
                    'against are unaffected. Unblock the account to see the '
                    'offers listed again.',
                    style: MallowTheme.uiMeta.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: MallowButton(
                      label: 'Blocked accounts',
                      onPressed: () => context.push(AppRoutes.blockedAccounts),
                      variant: MallowButtonVariant.secondary,
                      size: MallowButtonSize.small,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
