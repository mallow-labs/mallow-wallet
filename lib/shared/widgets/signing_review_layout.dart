import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/utils/address_format.dart';
import '../theme/mallow_theme.dart';
import 'app_snack_bar.dart';
import 'hold_to_approve_button.dart';
import 'mallow_button.dart';
import 'mallow_sheet.dart';
import 'sheet_drag_handle.dart';

/// Monospace face for raw values: program errors, hex, digests, nonces. The
/// app bundles no mono family and google_fonts never fetches at runtime, so
/// this names the platform faces: Menlo on iOS, the `monospace` alias on
/// Android.
const TextStyle reviewMonoStyle = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Courier', 'monospace'],
  fontSize: 12,
  height: 1.45,
);

/// Chrome shared by the native approval sheets (transaction, message,
/// connection): drag handle, a scrolling body and a footer that stays pinned
/// while the body scrolls. Sized by its content up to the sheet height cap.
class SigningReviewLayout extends StatefulWidget {
  const SigningReviewLayout({
    required this.children,
    required this.footer,
    this.footerDivider = true,
    super.key,
  });

  final List<Widget> children;
  final Widget footer;

  /// Always draw the hairline above the footer. Without it the hairline still
  /// appears whenever the body is long enough to scroll under the footer.
  final bool footerDivider;

  @override
  State<SigningReviewLayout> createState() => _SigningReviewLayoutState();
}

class _SigningReviewLayoutState extends State<SigningReviewLayout> {
  bool _overflows = false;

  bool _onMetrics(ScrollMetricsNotification n) {
    final overflows = n.metrics.maxScrollExtent > 0;
    if (overflows != _overflows) setState(() => _overflows = overflows);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Material(
      color: colors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetDragHandle(bottomSpacing: 4),
          Flexible(
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: _onMetrics,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  MallowTheme.spacing20,
                  14,
                  MallowTheme.spacing20,
                  MallowTheme.spacing20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.children,
                ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: widget.footerDivider || _overflows
                      ? colors.dividerLight
                      : colors.bgSurface,
                ),
              ),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingMd,
                MallowTheme.spacing20,
                sheetBottomInset(context, gap: MallowTheme.spacingSm),
              ),
              child: widget.footer,
            ),
          ),
        ],
      ),
    );
  }
}

/// Reject / approve pair. Side by side, or stacked (primary first) once large
/// text would squeeze the labels. With [holdToApprove] the reject action takes
/// the primary style and approval needs a deliberate press-and-hold.
///
/// The tap-to-approve button is armed only [armDelay] after the enclosing
/// route's entrance animation completes. Until then a tap on it does nothing,
/// and so does a press that began before it was armed. A page can open a
/// review at a moment of its choosing, such as while the user taps rapidly in
/// a game, and the button would otherwise rise into a tap aimed at the page.
/// Reject is never delayed, and hold-to-approve needs no delay: the hold is
/// already deliberate.
class ReviewDecisionBar extends StatefulWidget {
  const ReviewDecisionBar({
    required this.onReject,
    required this.onApprove,
    required this.rejectKey,
    required this.approveKey,
    this.rejectLabel = 'Reject',
    this.approveLabel = 'Approve',
    this.holdToApprove = false,
    super.key,
  });

  /// How long Approve stays unresponsive after the sheet has settled. Browsers
  /// use a similar delay on their permission and download prompts.
  static const armDelay = Duration(milliseconds: 500);

  final VoidCallback onReject, onApprove;
  final Key rejectKey, approveKey;
  final String rejectLabel, approveLabel;
  final bool holdToApprove;

  @override
  State<ReviewDecisionBar> createState() => _ReviewDecisionBarState();
}

class _ReviewDecisionBarState extends State<ReviewDecisionBar>
    with SingleTickerProviderStateMixin {
  // A ticker, not a Timer: it is disposed with the sheet, and it is time the
  // frame clock owns, so a test's pumpAndSettle runs through it.
  late final AnimationController _arming = AnimationController(
    vsync: this,
    duration: ReviewDecisionBar.armDelay,
  );
  Animation<double>? _route;

  /// The last press on Approve began before the button was armed.
  bool _pressStartedEarly = false;

  bool get _armed => _arming.isCompleted;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)?.animation;
    if (identical(route, _route)) return;
    _route?.removeStatusListener(_onRouteStatus);
    _route = route?..addStatusListener(_onRouteStatus);
    _onRouteStatus(route?.status ?? AnimationStatus.completed);
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) {
      // Still entering, or leaving: the button may be moving under a finger.
      _arming.reset();
    } else if (!_arming.isAnimating && !_arming.isCompleted) {
      _arming.forward();
    }
  }

  void _onApprovePointerDown(PointerDownEvent _) {
    _pressStartedEarly = !_armed;
  }

  void _approve() {
    final early = _pressStartedEarly;
    // Consumed by this activation, so a later one (an accessibility action
    // has no pointer) is judged on its own.
    _pressStartedEarly = false;
    if (!_armed || early) return;
    widget.onApprove();
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_onRouteStatus);
    _arming.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    if (widget.holdToApprove) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MallowButton(
            key: widget.rejectKey,
            label: widget.rejectLabel,
            isFullWidth: true,
            onPressed: widget.onReject,
          ),
          const SizedBox(height: 10),
          HoldToApproveButton(
            key: widget.approveKey,
            label: 'Hold to approve anyway',
            accessibilityActionLabel: '${widget.approveLabel} anyway',
            onConfirmed: widget.onApprove,
          ),
        ],
      );
    }
    final reject = MallowButton(
      key: widget.rejectKey,
      label: widget.rejectLabel,
      variant: MallowButtonVariant.secondary,
      isFullWidth: true,
      onPressed: widget.onReject,
    );
    // Looks enabled throughout: a button that flickers from disabled to
    // enabled as the sheet lands would draw the eye for no reason.
    final approve = Listener(
      onPointerDown: _onApprovePointerDown,
      child: MallowButton(
        key: widget.approveKey,
        label: widget.approveLabel,
        isFullWidth: true,
        onPressed: _approve,
      ),
    );
    if (MediaQuery.textScalerOf(context).scale(15) > 20) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [approve, const SizedBox(height: 10), reject],
      );
    }
    return Row(
      children: [
        Expanded(child: reject),
        const SizedBox(width: MallowTheme.spacingMd),
        Expanded(child: approve),
      ],
    );
  }
}

/// Icons for the review sheets: the shared assets where one exists, and a
/// few stroke glyphs drawn inline that have no asset.
enum ReviewGlyph {
  lock.asset('assets/icons/lock.svg'),
  info.asset('assets/icons/info_circle.svg'),
  chevronDown.asset('assets/icons/chevron_down.svg'),
  link.asset('assets/icons/link.svg'),
  cross.asset('assets/icons/close.svg'),
  copy.asset('assets/icons/copy_outline.svg'),
  warning(
    '<path d="M12 9v4M12 17h.01"/><path d="M10.24 3.96L2.39 17.1A2 2 0 0 0 4.1 20h15.8a2 2 0 0 0 1.71-2.9L13.76 3.96a2 2 0 0 0-3.52 0z"/>',
    2,
  ),
  arrowDown('<path d="M12 5v14M18 13l-6 6-6-6"/>', 2.2),
  check('<path d="M5 12l5 5L20 7"/>', 2.4),
  eye(
    '<path d="M10 12a2 2 0 1 0 4 0 2 2 0 0 0-4 0"/><path d="M21 12c-2.4 4-5.4 6-9 6s-6.6-2-9-6c2.4-4 5.4-6 9-6s6.6 2 9 6"/>',
    1.9,
  ),
  pencil('<path d="M4 20h4L18.5 9.5a2.83 2.83 0 0 0-4-4L4 16v4"/>', 1.9),
  plus('<path d="M12 5v14M5 12h14"/>', 1.9),
  code('<path d="M7 8l-4 4 4 4M17 8l4 4-4 4M14 4l-4 16"/>', 1.9),
  globe(
    '<circle cx="12" cy="12" r="9"/><path d="M3.6 9h16.8M3.6 15h16.8"/><path d="M11.5 3a17 17 0 0 0 0 18M12.5 3a17 17 0 0 1 0 18"/>',
    1.8,
  ),
  image(
    '<path d="M15 8h.01"/><rect x="3" y="3" width="18" height="18" rx="3"/><path d="M3 16l5-5c.93-.9 2.07-.9 3 0l5 5"/><path d="M14 14l1-1c.93-.9 2.07-.9 3 0l3 3"/>',
    1.8,
  ),
  coin(
    '<circle cx="12" cy="12" r="9"/><path d="M14.8 9a2 2 0 0 0-1.8-1h-2a2 2 0 1 0 0 4h2a2 2 0 1 1 0 4h-2a2 2 0 0 1-1.8-1M12 6v2m0 8v2"/>',
    1.8,
  );

  const ReviewGlyph(String this.paths, double this.strokeWidth) : asset = null;
  const ReviewGlyph.asset(String this.asset) : paths = null, strokeWidth = null;

  final String? asset;
  final String? paths;
  final double? strokeWidth;

  String get svg =>
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="$strokeWidth" stroke-linecap="round" stroke-linejoin="round">$paths</svg>';
}

class ReviewIcon extends StatelessWidget {
  const ReviewIcon(this.glyph, {required this.size, this.color, super.key});

  final ReviewGlyph glyph;
  final double size;

  /// Defaults to `textPrimary`.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final filter = ColorFilter.mode(
      color ?? context.mallowColors.textPrimary,
      BlendMode.srcIn,
    );
    final asset = glyph.asset;
    return asset != null
        ? SvgPicture.asset(
            asset,
            width: size,
            height: size,
            colorFilter: filter,
          )
        : SvgPicture.string(
            glyph.svg,
            width: size,
            height: size,
            colorFilter: filter,
          );
  }
}

/// The requesting site as the native layer committed it: icon, authority and
/// a lock for HTTPS. The authority is never ellipsized, since a truncated host
/// is exactly how a look-alike domain hides; it wraps instead.
class ReviewOriginChip extends StatelessWidget {
  const ReviewOriginChip({required this.origin, this.icon, super.key});

  /// A serialized origin (`https://jup.ag`), from native state only.
  final String origin;

  /// 22 dp site icon; a neutral globe tile when null.
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final uri = Uri.tryParse(origin);
    final authority = uri != null && uri.authority.isNotEmpty
        ? uri.authority
        : origin;
    final secure = uri?.scheme == 'https';
    return Center(
      child: Semantics(
        label: 'Request from $origin',
        excludeSemantics: true,
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.fromLTRB(5, 4, 12, 4),
          decoration: BoxDecoration(
            border: Border.all(color: colors.dividerLight),
            borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 22,
                child:
                    icon ??
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.surfaceMuted,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Center(
                        child: ReviewIcon(
                          ReviewGlyph.globe,
                          size: 14,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  authority,
                  style: MallowTheme.uiLabel.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (secure) ...[
                const SizedBox(width: 6),
                ReviewIcon(
                  ReviewGlyph.lock,
                  size: 11,
                  color: colors.textSecondary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Newsreader title centred at the top of a review sheet.
class ReviewTitle extends StatelessWidget {
  const ReviewTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: MallowTheme.editorialSection.copyWith(
        color: context.mallowColors.textPrimary,
      ),
    ),
  );
}

/// Label / value row with a hairline below, as used for fee, wallet and
/// network. Values wrap rather than truncate.
class ReviewKvRow extends StatelessWidget {
  const ReviewKvRow({
    required this.label,
    this.value,
    this.valueWidget,
    this.valueColor,
    this.divider = true,
    this.dense = false,
    super.key,
  }) : assert((value == null) != (valueWidget == null));

  final String label;
  final String? value;
  final Widget? valueWidget;
  final Color? valueColor;
  final bool divider;

  /// 14 px rows for the message card.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final base = dense
        ? MallowTheme.uiBody.copyWith(fontSize: 14)
        : MallowTheme.uiBody;
    return Container(
      constraints: BoxConstraints(minHeight: dense ? 44 : 46),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: divider
            ? Border(bottom: BorderSide(color: colors.dividerLight))
            : null,
      ),
      child: Row(
        children: [
          Text(label, style: base.copyWith(color: colors.textSecondary)),
          const SizedBox(width: MallowTheme.spacingMd),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child:
                  valueWidget ??
                  Text(
                    value!,
                    textAlign: TextAlign.right,
                    style: base.copyWith(
                      color: valueColor ?? colors.textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A 13 px secondary label above a group of rows.
class ReviewSectionLabel extends StatelessWidget {
  const ReviewSectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: MallowTheme.spacing20, bottom: 8),
    child: Text(
      text,
      style: MallowTheme.uiLabel.copyWith(
        color: context.mallowColors.textSecondary,
      ),
    ),
  );
}

/// One quiet caption with an info glyph.
class ReviewInfoLine extends StatelessWidget {
  const ReviewInfoLine(this.text, {this.iconColor, super.key});
  final String text;

  /// Defaults to textSecondary; a caution passes the warning color.
  final Color? iconColor;
  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: ReviewIcon(
            ReviewGlyph.info,
            size: 14,
            color: iconColor ?? colors.textSecondary,
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: MallowTheme.uiMeta.copyWith(
              fontSize: 12,
              height: 1.4,
              letterSpacing: 0,
              color: colors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Caution-tier card: a warning glyph, an optional bold [title], one or more
/// [messages] and an optional raw [detail] in the monospace face.
class ReviewCautionCard extends StatelessWidget {
  const ReviewCautionCard({
    this.title,
    this.messages = const [],
    this.detail,
    super.key,
  });

  final String? title;
  final List<String> messages;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final body = MallowTheme.uiMeta.copyWith(
      height: 1.4,
      letterSpacing: 0,
      color: colors.textPrimary,
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReviewIcon(ReviewGlyph.warning, size: 22, color: colors.warning),
          const SizedBox(width: MallowTheme.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1, bottom: 4),
                    child: Text(
                      title!,
                      style: MallowTheme.uiBody.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                for (final (i, message) in messages.indexed)
                  Padding(
                    padding: EdgeInsets.only(
                      top: i == 0 ? (title == null ? 2 : 0) : 6,
                    ),
                    child: Text(message, style: body),
                  ),
                if (detail != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText(
                      detail!,
                      style: reviewMonoStyle.copyWith(
                        color: colors.textSecondary,
                      ),
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

/// An address elided to its first and last six characters on a muted chip,
/// with a copy glyph: one tap copies the full value. Used for every
/// counterparty the review names (destinations, spenders, authorities) and
/// every program it calls.
class ReviewAddress extends StatelessWidget {
  const ReviewAddress(this.address, {super.key});

  final String address;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Semantics(
      button: true,
      label: 'Address $address',
      hint: 'Copies the full address',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => copyReviewValue(context, address, 'Address copied'),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 1, 5, 1),
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  truncateAddress(address, lead: 6, trail: 6),
                  style: reviewMonoStyle.copyWith(
                    fontSize: 13,
                    height: 1.3,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              ReviewIcon(
                ReviewGlyph.copy,
                size: 12,
                color: colors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Copies [value] from a review, with a light haptic and a brief [message].
void copyReviewValue(BuildContext context, String value, String message) {
  Clipboard.setData(ClipboardData(text: value));
  HapticFeedback.lightImpact();
  AppSnackBar.show(context, message, duration: const Duration(seconds: 2));
}

/// [ReviewAddress] inline in running text.
WidgetSpan reviewAddressSpan(BuildContext context, String address) =>
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: ReviewAddress(address),
    );

/// Collapsed-by-default disclosure row ("Program calls", "View full
/// message"). The chevron turns; the body appears without animation when the
/// platform asks for reduced motion.
class ReviewDisclosure extends StatefulWidget {
  const ReviewDisclosure({
    required this.label,
    required this.child,
    this.dense = false,
    super.key,
  });

  final String label;
  final Widget child;
  final bool dense;

  @override
  State<ReviewDisclosure> createState() => _ReviewDisclosureState();
}

class _ReviewDisclosureState extends State<ReviewDisclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final still = MediaQuery.disableAnimationsOf(context);
    final duration = still ? Duration.zero : MallowTheme.sheetDuration;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: widget.dense ? 44 : 46),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: MallowTheme.uiBody.copyWith(
                        fontSize: widget.dense ? 14 : 15,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: duration,
                    curve: MallowTheme.sheetCurve,
                    child: const ReviewIcon(ReviewGlyph.chevronDown, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: duration,
          curve: MallowTheme.sheetCurve,
          alignment: Alignment.topCenter,
          child: _open
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: widget.child,
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
