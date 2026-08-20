import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/avatar_service.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// One row in the artwork History / Offers tabs: actor avatar +
/// "{name} {action}" with the amount and age on the right.
///
/// When [username] or [address] is set, tapping the avatar or name opens
/// the actor's profile — by username when present, otherwise by address
/// (same routing as `UserHandleText`).
class ActivityListRow extends StatelessWidget {
  const ActivityListRow({
    required this.name,
    required this.action,
    super.key,
    this.avatarUrl,
    this.amount,
    this.amountWidget,
    this.age,
    this.username,
    this.address,
    this.avatarSeed,
    this.actionLinkLabel,
    this.onActionLinkTap,
    this.trailing,
    this.avatarSize = 32,
    this.circularAvatar = false,
    this.textStyle,
    this.amountStruckThrough = false,
    this.ageWidth,
    this.verticalPadding = MallowTheme.spacingSm,
  });

  final String name;
  final String action;
  final String? avatarUrl;
  final String? amount;

  /// Replaces the [amount] text with a widget. Used only for currencies whose
  /// symbol/decimals have to be resolved at runtime — the amount is then a
  /// three-state thing (shimmer / figure / "Unknown token") that a `String?`
  /// can't carry. Registry currencies keep the plain-text path so their
  /// rendering, baseline alignment, and struck-through styling are unchanged.
  final Widget? amountWidget;

  final String? age;
  final String? username;
  final String? address;

  /// Generated-identicon seed for the missing-image avatar. Defaults to
  /// `avatarSeedOf(address, username)`; pass explicitly when those fields are
  /// intentionally nulled (e.g. inert "You" rows keep their own seed).
  final String? avatarSeed;

  /// Tappable tail appended after [action] — the History tab's
  /// "collected Edition #12", which the webapp links to that print's own
  /// artwork page (`EventDescription`). A print is a different mint
  /// from the master whose provenance list the row appears in, so without the
  /// link there is no route to the edition that actually changed hands.
  /// Rendered in the primary text colour to read as a link; inert when
  /// [onActionLinkTap] is null.
  final String? actionLinkLabel;
  final VoidCallback? onActionLinkTap;

  /// Optional trailing widget rendered after the amount/age (e.g. the Offers
  /// screen's "View" pill). Null on the artwork-page tabs.
  final Widget? trailing;

  /// Avatar edge in logical px. The Offers auction-bid card uses 24; the
  /// artwork-page tabs keep the 32 default.
  final double avatarSize;

  /// Fully round the avatar (circle) instead of the default rounded square.
  /// The History tab, Offers inbox rows, and auction-bid rows all opt in.
  final bool circularAvatar;

  /// Base style for the name/action/amount text. Defaults to
  /// [MallowTheme.uiMeta]; the auction-bid card passes [MallowTheme.uiCaption].
  final TextStyle? textStyle;

  /// Renders the amount struck-through in [MallowColors.textSecondary] — the
  /// auction-bid card's "your bid was outbid" treatment.
  final bool amountStruckThrough;

  /// When set, the age renders right-aligned in a fixed-width column instead
  /// of inline after the amount, so trailing pills align across rows.
  final double? ageWidth;

  /// Vertical padding around the row. The auction-bid card passes 0 and
  /// spaces rows with explicit gaps.
  final double verticalPadding;

  bool get _hasProfileTarget =>
      (username != null && username!.isNotEmpty) ||
      (address != null && address!.isNotEmpty);

  void _openProfile(BuildContext context) {
    final u = username;
    if (u != null && u.isNotEmpty) {
      context.push(AppRoutes.profileByUsernamePath(u));
      return;
    }
    final a = address;
    if (a != null && a.isNotEmpty) {
      context.push(AppRoutes.profilePath(a));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final avatar = avatarUrl;
    final amount = this.amount;
    final age = this.age;
    final linkable = _hasProfileTarget;
    final baseStyle = textStyle ?? MallowTheme.uiMeta;
    final nameStyle = baseStyle.copyWith(color: colors.textPrimary);
    final amountStyle = amountStruckThrough
        ? baseStyle.copyWith(
            color: colors.textSecondary,
            decoration: TextDecoration.lineThrough,
          )
        : baseStyle.copyWith(color: colors.textPrimary);
    final ageStyle = MallowTheme.uiCaption.copyWith(
      color: colors.textSecondary,
    );

    final avatarRadius = BorderRadius.circular(
      circularAvatar ? avatarSize / 2 : MallowTheme.radiusPrimary,
    );
    final avatarWidget = ClipRRect(
      borderRadius: avatarRadius,
      child: avatar != null && avatar.isNotEmpty
          ? MallowNetworkImage(
              imageUrl: avatar,
              logicalSize: avatarSize,
              width: avatarSize,
              height: avatarSize,
              errorBuilder: (_) => _defaultAvatar(colors, avatarRadius),
            )
          : _defaultAvatar(colors, avatarRadius),
    );

    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPadding),
      child: Row(
        children: [
          if (linkable)
            TapTargetExpander(
              child: GestureDetector(
                onTap: () => _openProfile(context),
                child: avatarWidget,
              ),
            )
          else
            avatarWidget,
          const SizedBox(width: MallowTheme.spacingSm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (linkable)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: TapTargetExpander(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _openProfile(context),
                          child: Text(name, style: nameStyle),
                        ),
                      ),
                    )
                  else
                    TextSpan(text: name, style: nameStyle),
                  TextSpan(
                    text: ' $action',
                    style: baseStyle.copyWith(color: colors.textSecondary),
                  ),
                  if (actionLinkLabel != null)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: TapTargetExpander(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onActionLinkTap,
                          child: Text(' $actionLinkLabel', style: nameStyle),
                        ),
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          if (ageWidth == null)
            Text.rich(
              TextSpan(
                children: [
                  if (amountWidget != null)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: DefaultTextStyle.merge(
                        style: amountStyle,
                        child: amountWidget!,
                      ),
                    )
                  else if (amount != null)
                    TextSpan(text: amount, style: amountStyle),
                  if (age != null)
                    TextSpan(
                      text: (amount != null || amountWidget != null)
                          ? '  $age'
                          : age,
                      style: ageStyle,
                    ),
                ],
              ),
            )
          else ...[
            if (amountWidget != null)
              DefaultTextStyle.merge(style: amountStyle, child: amountWidget!)
            else if (amount != null)
              Text(amount, style: amountStyle),
            if (age != null) ...[
              const SizedBox(width: MallowTheme.spacingSm),
              SizedBox(
                width: ageWidth,
                child: Text(
                  age,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: ageStyle,
                ),
              ),
            ],
          ],
          if (trailing != null) ...[
            const SizedBox(width: MallowTheme.spacingSm),
            trailing!,
          ],
        ],
      ),
    );
  }

  Widget _defaultAvatar(MallowColors colors, BorderRadius radius) =>
      AccountAvatar(
        seed: avatarSeed ?? avatarSeedOf(address: address, username: username),
        size: avatarSize,
        borderRadius: radius,
      );
}
