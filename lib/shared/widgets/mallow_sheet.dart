import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';

/// The top safe-area inset in logical pixels, read directly from the platform
/// view. [MediaQuery] can report 0 when a [Scaffold] or route has already
/// consumed the padding, but the raw view padding is always accurate.
double get _topSafeArea {
  final view = ui.PlatformDispatcher.instance.views.first;
  return view.viewPadding.top / view.devicePixelRatio;
}

/// Gap left between the top of a full-height sheet and the safe area, so the
/// page behind still peeks through.
const double _sheetTopPeek = 20;

/// Tallest a modal sheet may grow: the screen minus the top safe area and a
/// [_sheetTopPeek] sliver of the page behind — the height [FullScreenSheet]
/// pins itself to.
///
/// Every sheet opened via [showMallowSheet] is capped here, so a sheet whose
/// content grows (a simulation warning appearing, a long error, an expanded
/// breakdown) keeps growing until it fills the screen and only then has to
/// scroll. Sheet content is therefore expected to be height-flexible —
/// shrink-wrapped with its scrollable region in a [Flexible] — rather than
/// pinned to a fixed height, and does not need to restate this cap itself.
///
/// Call it directly only to pin an exact height ([FullScreenSheet]). A sheet
/// that should stop short of full screen — a picker that must still read as a
/// sheet rather than a page — sets its own smaller [BoxConstraints] instead;
/// that is a deliberate size choice, not a cap.
double maxSheetHeight(BuildContext context) =>
    MediaQuery.sizeOf(context).height - _topSafeArea - _sheetTopPeek;

/// Bottom inset for modal-sheet content so action buttons clear both the
/// keyboard (when open) and the home-indicator safe area (when closed), with a
/// consistent [gap] of breathing room above whichever is in play.
///
/// Use as the `bottom` of the single `EdgeInsets.only`/`SizedBox` that sits
/// below a sheet's content (or buttons). Every sheet opened via
/// [showMallowSheet] should route its bottom spacing through this so the gap
/// above the safe area is identical app-wide.
///
/// Reads `viewPadding` — not `padding` — for the safe-area component: the
/// keyboard zeroes `padding.bottom`, but `viewPadding.bottom` always reports the
/// physical home-indicator inset, so the safe area survives keyboard transitions.
///
/// Pass `includeKeyboard: false` when the sheet already shifts its scrollable
/// region up by `viewInsets.bottom` elsewhere (the two-part keyboard sheets):
/// the button row then only needs the safe-area gap, and folding the keyboard in
/// here too would double-count it. That caller-side lift also covers the home
/// indicator, so the safe-area term shrinks by the keyboard height and reaches
/// zero once the keyboard is taller than it — leaving just [gap].
double sheetBottomInset(
  BuildContext context, {
  double gap = MallowTheme.spacing20,
  bool includeKeyboard = true,
}) {
  final media = MediaQuery.of(context);
  final base = includeKeyboard
      ? math.max(media.viewInsets.bottom, media.viewPadding.bottom)
      // The caller has already lifted the content by `viewInsets.bottom`, and
      // that lift clears the home indicator too — so only the part of the safe
      // area the keyboard doesn't already cover is still owed. Without the
      // subtraction the buttons float a home-indicator's height too high while
      // the keyboard is open.
      : math.max(0, media.viewPadding.bottom - media.viewInsets.bottom);
  return base + gap;
}

/// Short settle buffer after the entrance animation completes before taps are
/// accepted again, so a tap begun right as the sheet snaps into place is still
/// swallowed. Deliberately much shorter than the old fixed window — the guard
/// now keys off when the animation actually finishes rather than a flat 500ms.
const Duration _sheetSettleBuffer = Duration(milliseconds: 100);

/// Entrance tap-guard state shared by the sheet reveals. Only *taps* are
/// guarded, and only until the entrance animation has finished
/// ([markAnimationDone]) plus a short [_sheetSettleBuffer] has elapsed, so an
/// option can't be tapped while the sheet slides in or right as it settles.
/// Scrolls and drags are never guarded (see [_EntranceTapBarrier]). One-shot —
/// once [revealed] flips true it never blocks again.
mixin _TapGuardReveal<T extends StatefulWidget> on State<T> {
  Timer? _settleTimer;
  bool _animationDone = false;
  bool _revealed = false;

  /// Whether taps are now accepted. Drive [_EntranceTapBarrier.active] off
  /// `!revealed`.
  bool get revealed => _revealed;

  /// Whether the entrance-animation gate has been satisfied.
  bool get animationDone => _animationDone;

  /// Marks the entrance animation complete and arms the short settle buffer,
  /// after which taps are accepted again.
  void markAnimationDone() {
    if (_animationDone) return;
    _animationDone = true;
    _settleTimer = Timer(_sheetSettleBuffer, () {
      if (mounted) setState(() => _revealed = true);
    });
  }

  /// Cancels the pending timer. Call from [dispose].
  void cancelTapGuard() => _settleTimer?.cancel();
}

/// Overlays a translucent tap-only barrier over [child] while [active], so a
/// tap that lands during the sheet's entrance is swallowed while scrolls and
/// drags still reach the content underneath.
///
/// The barrier is a sibling painted in front of [child] rather than an
/// [AbsorbPointer] over the subtree: with [HitTestBehavior.translucent] the
/// content behind still receives the pointer, so any drag/scroll recognizer
/// there beats the barrier's tap recognizer in the gesture arena and passes
/// straight through. Only a settled tap resolves to the barrier's no-op
/// handler, preserving the accidental-double-tap protection.
class _EntranceTapBarrier extends StatelessWidget {
  const _EntranceTapBarrier({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (active)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              excludeFromSemantics: true,
              onTap: () {},
            ),
          ),
      ],
    );
  }
}

/// Slides [child] up from the bottom on first mount using
/// [MallowTheme.sheetCurve] and [MallowTheme.sheetDuration].
///
/// Use for sheets that are conditionally rendered in a [Stack]
/// (e.g. ArtworkBuySheet) — sheets opened via [showMallowSheet] do not need
/// this wrapper because the route animates them already.
class AnimatedSheetReveal extends StatefulWidget {
  const AnimatedSheetReveal({required this.child, super.key});

  final Widget child;

  @override
  State<AnimatedSheetReveal> createState() => _AnimatedSheetRevealState();
}

class _AnimatedSheetRevealState extends State<AnimatedSheetReveal>
    with SingleTickerProviderStateMixin, _TapGuardReveal {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: MallowTheme.sheetDuration,
  );

  late final Animation<Offset> _offset =
      Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(
        CurvedAnimation(parent: _controller, curve: MallowTheme.sheetCurve),
      );

  @override
  void initState() {
    super.initState();
    _controller.forward().whenCompleteOrCancel(markAnimationDone);
  }

  @override
  void dispose() {
    cancelTapGuard();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _offset,
      child: _EntranceTapBarrier(active: !revealed, child: widget.child),
    );
  }
}

/// Swallows accidental *taps* on sheet content until the enclosing route's
/// entrance animation has completed and a short [_sheetSettleBuffer] has
/// elapsed, so buttons can't be tapped while the sheet is still sliding in or
/// right as it settles. Scrolls and drags pass through immediately (see
/// [_EntranceTapBarrier]). One-shot: once revealed, never blocks again (drags
/// that rewind the route animation don't re-disable the content).
class _SheetEntranceTapGuard extends StatefulWidget {
  const _SheetEntranceTapGuard({required this.child});

  final Widget child;

  @override
  State<_SheetEntranceTapGuard> createState() => _SheetEntranceTapGuardState();
}

class _SheetEntranceTapGuardState extends State<_SheetEntranceTapGuard>
    with _TapGuardReveal {
  Animation<double>? _animation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (animationDone || _animation != null) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      markAnimationDone();
    } else {
      _animation = animation..addStatusListener(_onStatus);
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _detach();
      markAnimationDone();
    }
  }

  void _detach() {
    _animation?.removeStatusListener(_onStatus);
    _animation = null;
  }

  @override
  void dispose() {
    cancelTapGuard();
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _EntranceTapBarrier(active: !revealed, child: widget.child);
  }
}

/// Cross-fades and resizes between the sequential steps of a single-route
/// sheet flow (e.g. amount entry → confirm → in-flight pipeline), so advancing
/// morphs *in place* instead of dismissing one sheet and presenting another.
///
/// [child] is the active step. Give each step a distinct [Key] (e.g.
/// `ValueKey('confirm')` / `ValueKey('pipeline')`) so swapping animates;
/// rebuilding the same step with the same key updates it in place without a
/// transition. Each step brings its own sheet chrome (handle/padding/
/// background) — they already share `bgSurface`/`popupRadius` across the app,
/// so the cross-fade has no visible seam.
class SheetStepSwitcher extends StatelessWidget {
  const SheetStepSwitcher({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: MallowTheme.sheetDuration,
      curve: MallowTheme.sheetCurve,
      alignment: Alignment.bottomCenter,
      child: AnimatedSwitcher(
        duration: MallowTheme.sheetDuration,
        switchInCurve: MallowTheme.sheetCurve,
        switchOutCurve: Curves.easeInCubic,
        // Bottom-align so a shorter step stays pinned to the sheet edge while
        // the taller one fades, instead of floating centred.
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.bottomCenter,
          children: [...previousChildren, ?currentChild],
        ),
        child: child,
      ),
    );
  }
}

/// Keys for options/context-menu sheets currently being presented.
/// See [runGuardedSheet].
final Set<Object> _guardedSheetKeys = <Object>{};

/// Runs [open] under a re-entrancy guard keyed by [key], so only one
/// options/context-menu sheet with that [key] can be presented at a time.
///
/// Rapidly tapping several kebab buttons would otherwise stack overlapping
/// sheets, since each tap pushes its own modal route. While a sheet with [key]
/// is in flight, further calls return null instead of opening a second sheet.
///
/// Wrap only the present-and-await-dismissal portion of a launcher — including
/// any async gap *before* [showMallowSheet], which is the widest part of the
/// double-tap race. The guard releases as soon as [open] completes, so any
/// post-sheet navigation runs unguarded.
Future<T?> runGuardedSheet<T>(Object key, Future<T?> Function() open) async {
  if (_guardedSheetKeys.contains(key)) return null;
  _guardedSheetKeys.add(key);
  try {
    return await open();
  } finally {
    _guardedSheetKeys.remove(key);
  }
}

/// Drop-in replacement for [showModalBottomSheet] that pins the route
/// transition to [MallowTheme.sheetDuration] so every modal sheet animates
/// over the same window. Flutter's underlying decelerate-cubic curve
/// matches the character of [AnimatedSheetReveal]'s ease-out cubic.
Future<T?> showMallowSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  Color? backgroundColor = Colors.transparent,
  ShapeBorder? shape,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    // Use the design-system scrim (dark ~0x99) instead of Flutter's default
    // Colors.black54. Resolved from the caller's context so it adapts to theme.
    barrierColor: context.mallowColors.scrim,
    backgroundColor: backgroundColor,
    shape: shape,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    sheetAnimationStyle: const AnimationStyle(
      duration: MallowTheme.sheetDuration,
      reverseDuration: MallowTheme.sheetDuration,
    ),
    builder: (context) => _SheetEntranceTapGuard(
      // A scroll-controlled sheet is otherwise free to run the full height of
      // the screen, including under the status bar. Capping here lets growing
      // content push any sheet taller up to the full-screen height and no
      // further, so no sheet has to restate the bound itself. (Flutter already
      // holds a non-scroll-controlled sheet to a tighter 9/16, which makes
      // this a no-op there.) Read inside the builder so a metrics change
      // re-resolves it.
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetHeight(context)),
        // A tap on any bare patch of the sheet dismisses the keyboard.
        // Interactive children win their own hit areas, so only taps that land
        // on nothing reach this. It is the fallback for sheets that don't
        // scroll — the price / bid / offer / gas sheets have no drag to make,
        // so [MallowScrollBehavior]'s drag-to-dismiss can't fire, and the
        // decimal numpad they open has no return key on iOS.
        //
        // `deferToChild`, not `opaque`: a sheet that leaves transparent margin
        // around its card still lets taps there fall through to the barrier and
        // close the sheet, which is the behaviour those sheets have today.
        child: GestureDetector(
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: builder(context),
        ),
      ),
    ),
  );
}
