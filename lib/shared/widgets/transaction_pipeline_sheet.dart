import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../core/services/signing_copy.dart';
import '../../core/services/social_auth_service.dart';
import '../../core/utils/reduce_motion.dart';
import '../theme/mallow_theme.dart';
import 'mallow_sheet.dart';
import 'mallow_svg_icon.dart';
import 'striped_activity_panel.dart';
import 'success_ripple.dart';
import 'tappable.dart';

/// Coarse UI phase for [TransactionPipelineSheet]. Each feature bloc collapses
/// its own per-feature pipeline-status enum onto one of these — the sheet only
/// needs to know which body to render. Per-phase sub-copy (e.g. "Awaiting
/// wallet approval", "Approve on your Ledger device") rides on the [label]
/// and [sublabel] props.
enum TransactionPipelinePhase { progress, success, error }

/// Shortest a phase body may be. Every phase reserves it, so the sheet holds
/// its height as the pipeline moves between progress, success and error.
///
/// A *minimum*, not a fixed height: a body whose content needs more — a
/// failure message long enough to wrap several lines — grows past it and takes
/// the sheet with it, rather than overflowing. Growth stops at the sheet's own
/// [maxSheetHeight] cap, past which the message scrolls under a pinned footer.
const double _bodyMinHeight = 200;

/// Height of one [_SheetButton], and so of the footer row a phase body pins
/// below its content.
const double _buttonHeight = 48;

/// Optional CTA pair shown in the success body. Mint passes "Done" /
/// "View artwork"; market actions usually leave this null and let the host
/// auto-dismiss after a short delay.
class TransactionSuccessAction {
  const TransactionSuccessAction({
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
}

/// Bottom-sheet body shared by every flow that signs and broadcasts a
/// transaction (mint, market actions, auction/fixed-price listings,
/// auto-confirm management actions).
///
/// The sheet stays mounted across the in-flight pipeline (progress →
/// success or error). The host opens it imperatively when the user
/// confirms an action and tears it down when the pipeline reaches a
/// terminal state.
///
/// Ledger device-prompts surface here too — when the active wallet is a
/// Ledger, the host bloc updates its `pipelineStage` to read "Approve on
/// your Ledger device" (driven by [LedgerService.signingState] piped into
/// `signSendConfirm`).
class TransactionPipelineSheet extends StatelessWidget {
  const TransactionPipelineSheet({
    required this.phase,
    required this.label,
    this.sublabel,
    this.sublabelCycle,
    this.sublabelCycleInterval = const Duration(seconds: 10),
    this.header,
    this.errorTitle = 'Transaction failed',
    this.errorSublabel,
    this.errorActionLabel,
    this.onErrorAction,
    this.successTitle,
    this.successSublabel,
    this.successAction,
    this.progressActionLabel,
    this.onProgressAction,
    this.onRetry,
    this.onClose,
    super.key,
  });

  final TransactionPipelinePhase phase;
  final String label;
  final String? sublabel;

  /// Reassurance lines swapped into the sublabel slot, one every
  /// [sublabelCycleInterval], while a single progress step runs long — a step
  /// that polls a backend (mint's finalize wait) can sit on one label for a
  /// minute with nothing on screen changing, which reads as stuck. The
  /// sequence restarts from [sublabel] whenever [label] changes, and holds on
  /// the last entry rather than looping back (returning to the opening copy
  /// reads as the wait starting over).
  ///
  /// Null — the default — derives the cycle from [sublabel] via
  /// [sublabelCycleFor], which is what every flow but mint wants: the
  /// reassurance is a property of the wait the subtitle describes, not of the
  /// host that started it, so a new pipeline flow gets it without opting in.
  /// Pass a list to override (mint's finalize step has its own, longer
  /// sequence), or `const []` to hold [sublabel] fixed for the whole step.
  final List<String>? sublabelCycle;
  final Duration sublabelCycleInterval;

  /// Optional context block rendered above the phase body — e.g. the
  /// artwork image + title for market actions, so the
  /// user keeps sight of what they're buying while the tx is in flight.
  final Widget? header;

  /// Headline shown in the success body. When null, [label] is used.
  final String? successTitle;

  /// Caption shown beneath [successTitle].
  final String? successSublabel;

  /// Optional success-state CTAs. When null, the sheet shows just the
  /// confirmation message and the host is expected to auto-dismiss.
  final TransactionSuccessAction? successAction;

  /// Optional early-exit affordance rendered under the in-flight body — e.g.
  /// "Done" once an EVM transaction is broadcast and something else (the
  /// pending-transaction tracker) owns its confirmation, so the user need not
  /// sit through the wait. Shown only while [phase] is
  /// [TransactionPipelinePhase.progress] and both fields are non-null; it
  /// occupies the same slot as the success CTAs, so the sheet keeps its height
  /// across the transition.
  final String? progressActionLabel;
  final VoidCallback? onProgressAction;

  final String errorTitle;

  /// Caption shown beneath [errorTitle] — the place for the failure message
  /// itself (`SomeError(:final message)`). Deliberately a separate prop
  /// rather than reusing [sublabel]: several hosts leave [sublabel] on their
  /// in-flight fallback copy when the phase flips to error, and rendering
  /// that under a failure headline would read as stale progress copy. Null
  /// keeps the error body title-only, the pre-existing behavior.
  final String? errorSublabel;

  /// Optional remedial link rendered under [errorSublabel] — for a failure
  /// the user can actually *do* something about, as opposed to retrying the
  /// same thing. A Solana transaction that expired unlanded uses it to offer
  /// "Increase priority fee", which is the only action that changes the
  /// outcome of the retry. Shown only when both fields are non-null.
  final String? errorActionLabel;
  final VoidCallback? onErrorAction;

  /// Tapped from the error body's "Try again" affordance. Should clear
  /// the error in the host bloc and re-trigger the action.
  final VoidCallback? onRetry;

  /// Tapped from the error body's "Back" affordance. Should clear the
  /// error in the host bloc; the host's listener pops the sheet.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final body = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: MallowTheme.spacing20,
          right: MallowTheme.spacing20,
          top: MallowTheme.spacing20,
          bottom: sheetBottomInset(context),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header != null) ...[
              header!,
              const SizedBox(height: MallowTheme.spacingLg),
            ],
            // Flexible rather than a fixed-height box: each phase body
            // reserves [_bodyMinHeight] itself and is free to grow past it,
            // so a long failure message makes the sheet taller instead of
            // overflowing a height pinned to the shortest phase.
            Flexible(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                // StackFit.passthrough hands each phase body the same
                // constraints the switcher got — full width, height free up
                // to whatever the sheet has left — so a body fills the width
                // during the cross-fade while still sizing to its own
                // content. The stack takes the taller of the two.
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  fit: StackFit.passthrough,
                  alignment: Alignment.center,
                  children: [...previousChildren, ?currentChild],
                ),
                child: switch (phase) {
                  TransactionPipelinePhase.progress =>
                    ValueListenableBuilder<bool>(
                      key: const ValueKey(TransactionPipelinePhase.progress),
                      valueListenable: _socialRequestPending(),
                      builder: (context, socialPending, _) {
                        // A social signature can block on an interactive
                        // re-login when the wallet's stored key is missing: the
                        // signature only exists once the OAuth tab comes back.
                        // Abandon that tab and this step spins forever, so the
                        // approval step gets a way out. A host that has already
                        // claimed this slot keeps it — its own early exit is
                        // more specific than a generic cancel.
                        final cancellable =
                            socialPending && progressActionLabel == null;
                        return _ProgressBody(
                          label: label,
                          sublabel: sublabel,
                          sublabelCycle:
                              sublabelCycle ?? sublabelCycleFor(sublabel),
                          sublabelCycleInterval: sublabelCycleInterval,
                          actionLabel: cancellable
                              ? 'Cancel'
                              : progressActionLabel,
                          onAction: cancellable
                              ? GetIt.instance<SocialAuthService>()
                                    .cancelPendingRequest
                              : onProgressAction,
                        );
                      },
                    ),
                  // Terminal bodies materialize in — a blur that resolves to
                  // sharp on top of the switcher's cross-fade — so the
                  // resolution reads as the result arriving rather than a
                  // plain opacity swap. The in-flight progress body is left
                  // to cross-fade alone.
                  TransactionPipelinePhase.success => _DeblurIn(
                    key: const ValueKey(TransactionPipelinePhase.success),
                    child: _SuccessBody(
                      title: successTitle ?? label,
                      sublabel: successSublabel ?? sublabel,
                      action: successAction,
                    ),
                  ),
                  TransactionPipelinePhase.error => _DeblurIn(
                    key: const ValueKey(TransactionPipelinePhase.error),
                    child: _ErrorBody(
                      title: errorTitle,
                      sublabel: errorSublabel,
                      actionLabel: errorActionLabel,
                      onAction: onErrorAction,
                      onRetry: onRetry,
                      onClose: onClose,
                    ),
                  ),
                },
              ),
            ),
          ],
        ),
      ),
    );

    return PopScope(
      canPop: phase == TransactionPipelinePhase.error,
      // Flutter's modal-sheet drag-to-dismiss calls Navigator.pop directly,
      // sidestepping the PopScope above (which only guards the system back
      // gesture). Swallow the swipe here too while the pipeline is in flight
      // or resolved to success so an accidental drag can't tear the sheet
      // down mid-transaction or before the user acts on the result; the error
      // state stays swipe-dismissible.
      child: _DragDismissGuard(
        enabled: phase != TransactionPipelinePhase.error,
        child: body,
      ),
    );
  }
}

/// Constant "nothing in flight", used when [SocialAuthService] isn't in the
/// service locator — widget tests pump this sheet in isolation, and the cancel
/// affordance is not what they are exercising.
final ValueNotifier<bool> _noPendingRequest = ValueNotifier<bool>(false);

/// The social-signing in-flight flag, or [_noPendingRequest] when the service
/// isn't registered.
ValueListenable<bool> _socialRequestPending() =>
    GetIt.instance.isRegistered<SocialAuthService>()
    ? GetIt.instance<SocialAuthService>().requestPending
    : _noPendingRequest;

/// One phase's body: [content] over an optional pinned [footer] row, keeping
/// the body at least [_bodyMinHeight] tall so the sheet doesn't resize on
/// every phase change.
///
/// The minimum is charged to the content region less whatever the footer
/// costs, so content and footer together still measure [_bodyMinHeight] when
/// the content is short. Content that needs more room grows the body; content
/// taller than the sheet can ever be scrolls, with the footer still pinned
/// below it.
class _PhaseBody extends StatelessWidget {
  const _PhaseBody({required this.content, this.footer, this.footerGap = 0});

  final Widget content;

  /// Button row pinned below [content]. Assumed to be [_buttonHeight] tall.
  final Widget? footer;

  /// Space between [content] and [footer].
  final double footerGap;

  @override
  Widget build(BuildContext context) {
    final pinned = footer;
    final reserved = pinned == null ? 0.0 : _buttonHeight + footerGap;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: _bodyMinHeight - reserved),
              child: content,
            ),
          ),
        ),
        if (pinned != null) ...[SizedBox(height: footerGap), pinned],
      ],
    );
  }
}

/// Swallows vertical drags over [child] while [enabled] so the enclosing modal
/// bottom sheet's drag-to-dismiss can't fire. The sheet's drag lives on an
/// ancestor [GestureDetector]; the one here is a descendant, so it wins the
/// gesture arena for vertical drags that start on the sheet body and the outer
/// recognizer never sees them. Taps (buttons) and the barrier are unaffected.
class _DragDismissGuard extends StatelessWidget {
  const _DragDismissGuard({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) {},
      onVerticalDragUpdate: (_) {},
      onVerticalDragEnd: (_) {},
      child: child,
    );
  }
}

/// Materializes [child] on mount: a Gaussian blur that resolves from soft to
/// sharp, so the terminal success/error body reads as the result coming into
/// focus rather than a flat fade. Runs once when the widget is inserted (the
/// switcher keys each phase body, so this mounts fresh on the phase change).
class _DeblurIn extends StatefulWidget {
  const _DeblurIn({required this.child, super.key});

  final Widget child;

  @override
  State<_DeblurIn> createState() => _DeblurInState();
}

class _DeblurInState extends State<_DeblurIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// Starting blur radius; lerps to 0 as the body settles.
  static const double _maxSigma = 16;
  static const Curve _curve = Curves.easeOutCubic;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce Motion: skip the blur and show the body sharp immediately.
    // Kicked off here (not initState) because it reads the ambient MediaQuery.
    if (_controller.value != 0 || _controller.isAnimating) return;
    if (context.reduceMotion) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final sigma = (1 - _curve.transform(_controller.value)) * _maxSigma;
        // Toggle the filter via `enabled` rather than swapping [ImageFiltered]
        // out for the bare child once it settles: dropping the wrapper would
        // reparent [child] and remount it, restarting any one-shot entrance
        // effect inside (e.g. the success ripple). `enabled: false` keeps the
        // element in place and, per the framework, is the cheap way to disable
        // a filter — so the settled body still pays no blur cost.
        final active = sigma >= 0.3;
        return ImageFiltered(
          enabled: active,
          imageFilter: ImageFilter.blur(
            sigmaX: active ? sigma : 0,
            sigmaY: active ? sigma : 0,
            tileMode: TileMode.decal,
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// In-flight body: the striped activity panel, plus an optional early-exit
/// button laid out exactly like the success CTAs so the sheet doesn't resize
/// when the pipeline resolves.
///
/// Owns the [TransactionPipelineSheet.sublabelCycle] timer. This body stays
/// mounted for the whole progress phase (the switcher keys it by phase), so
/// the cycle survives the label changes between steps and has to reset itself
/// on each one.
class _ProgressBody extends StatefulWidget {
  const _ProgressBody({
    required this.label,
    required this.sublabel,
    required this.sublabelCycle,
    required this.sublabelCycleInterval,
    required this.actionLabel,
    required this.onAction,
    super.key,
  });

  final String label;
  final String? sublabel;
  final List<String> sublabelCycle;
  final Duration sublabelCycleInterval;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  State<_ProgressBody> createState() => _ProgressBodyState();
}

class _ProgressBodyState extends State<_ProgressBody> {
  Timer? _timer;

  /// 0 = [widget.sublabel]; n = `sublabelCycle[n - 1]`.
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _restartCycle();
  }

  @override
  void didUpdateWidget(covariant _ProgressBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new step starts its own wait: without this reset a step reached after
    // a slow predecessor would open on "still working on it" copy that has
    // nothing to do with it.
    if (oldWidget.label != widget.label ||
        oldWidget.sublabelCycleInterval != widget.sublabelCycleInterval ||
        !listEquals(oldWidget.sublabelCycle, widget.sublabelCycle)) {
      _restartCycle();
    }
  }

  void _restartCycle() {
    _timer?.cancel();
    _timer = null;
    _index = 0;
    if (widget.sublabelCycle.isEmpty) return;
    _timer = Timer.periodic(widget.sublabelCycleInterval, (timer) {
      setState(() => _index++);
      if (_index >= widget.sublabelCycle.length) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final panel = StripedActivityPanel(
      label: widget.label,
      sublabel: _index == 0
          ? widget.sublabel
          : widget.sublabelCycle[_index - 1],
    );
    final action = widget.actionLabel;
    if (action == null || widget.onAction == null) {
      return _PhaseBody(content: panel);
    }
    return _PhaseBody(
      content: panel,
      footerGap: MallowTheme.spacingMd,
      footer: _SheetButton(
        label: action,
        filled: false,
        onPressed: widget.onAction,
      ),
    );
  }
}

class _SuccessBody extends StatelessWidget {
  const _SuccessBody({
    required this.title,
    required this.sublabel,
    required this.action,
    super.key,
  });

  final String title;
  final String? sublabel;
  final TransactionSuccessAction? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final sub = sublabel;
    // Green-outlined panel per the Figma spec — the success message
    // sits inside a positive-bordered frame with the same footprint as the
    // in-flight striped panel, so the phase transition reads as the panel
    // "resolving" rather than the layout changing.
    final message = Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(color: colors.positive),
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      // Centered rather than left to the stack's top-start default: the frame
      // is only min-height constrained now, so the copy is shorter than it
      // whenever the message is a line or two.
      child: Stack(
        alignment: Alignment.center,
        children: [
          // One-shot green ripple, fired when the pipeline resolves to
          // success. Sits behind the copy and is clipped to the green frame's
          // rounded corners by the Container above.
          Positioned.fill(child: SuccessRipple(color: colors.positive)),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: MallowTheme.editorialSection.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              if (sub != null) ...[
                const SizedBox(height: MallowTheme.spacingSm),
                Text(
                  sub,
                  textAlign: TextAlign.center,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
    final cta = action;
    if (cta == null) {
      return _PhaseBody(content: message);
    }
    return _PhaseBody(
      content: message,
      footerGap: MallowTheme.spacingMd,
      footer: Row(
        children: [
          if (cta.secondaryLabel != null)
            Expanded(
              child: _SheetButton(
                label: cta.secondaryLabel!,
                filled: false,
                onPressed: cta.onSecondary,
              ),
            ),
          if (cta.secondaryLabel != null)
            const SizedBox(width: MallowTheme.spacingMd),
          Expanded(
            child: _SheetButton(
              label: cta.primaryLabel,
              filled: true,
              onPressed: cta.onPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBody extends StatefulWidget {
  const _ErrorBody({
    required this.title,
    required this.sublabel,
    required this.actionLabel,
    required this.onAction,
    required this.onRetry,
    required this.onClose,
    super.key,
  });

  final String title;
  final String? sublabel;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;

  @override
  State<_ErrorBody> createState() => _ErrorBodyState();
}

class _ErrorBodyState extends State<_ErrorBody> {
  @override
  void initState() {
    super.initState();
    // Error-channel haptic, mirroring the success ripple's paired buzz.
    // The AnimatedSwitcher keys each phase body by its phase, so this
    // widget mounts fresh only on the progress/success → error transition
    // — initState is the causal one-shot. Parent rebuilds that stay in the
    // error phase reuse this State without re-firing.
    HapticFeedback.heavyImpact();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final message = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MallowSvgIcon(
          'assets/icons/alert_triangle.svg',
          width: 40,
          height: 40,
          color: colors.error,
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        Text(
          widget.title,
          textAlign: TextAlign.center,
          style: MallowTheme.editorialSection.copyWith(
            color: colors.textPrimary,
          ),
        ),
        if (widget.sublabel case final sub?) ...[
          const SizedBox(height: MallowTheme.spacingSm),
          Text(
            sub,
            textAlign: TextAlign.center,
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
        ],
        if (widget.actionLabel case final label?)
          if (widget.onAction case final onAction?) ...[
            const SizedBox(height: MallowTheme.spacingSm),
            Tappable(
              onTap: onAction,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.accent,
                  decoration: TextDecoration.underline,
                  decorationColor: colors.accent,
                ),
              ),
            ),
          ],
      ],
    );
    return _PhaseBody(
      // The failure reason is the one piece of copy here with no length bound
      // — an operator message or a raw chain error can run several lines — so
      // this is the body that has to be free to push the sheet taller.
      content: Center(child: message),
      footer: Row(
        children: [
          Expanded(
            child: _SheetButton(
              label: 'Back',
              filled: false,
              onPressed: widget.onClose,
            ),
          ),
          const SizedBox(width: MallowTheme.spacingMd),
          Expanded(
            child: _SheetButton(
              label: 'Try again',
              filled: true,
              onPressed: widget.onRetry,
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({
    required this.label,
    required this.filled,
    required this.onPressed,
  });

  final String label;
  final bool filled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final disabled = onPressed == null;
    return SizedBox(
      height: _buttonHeight,
      child: Material(
        color: filled
            ? (disabled ? colors.textTertiary : colors.accent)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          side: filled ? BorderSide.none : BorderSide(color: colors.divider),
        ),
        child: Tappable(
          onTap: disabled ? null : onPressed,
          child: Center(
            child: Text(
              label,
              style: MallowTheme.uiBody.copyWith(
                color: filled ? colors.textOnAccent : colors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the [TransactionPipelineSheet]. Barrier-tap and drag-down dismissal
/// are enabled at the route level; the sheet's internal [PopScope] still
/// blocks dismissal during the in-flight pipeline and only releases it once
/// the bloc emits an error state.
///
/// Hosts pass a [builder] that wires a feature bloc into the sheet props —
/// the helper centralizes the `showMallowSheet` boilerplate every flow
/// duplicates today.
Future<void> showTransactionPipelineSheet({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: builder,
  );
}
