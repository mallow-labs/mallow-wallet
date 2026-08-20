import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/tappable.dart';
import '../services/cast_bloc.dart';

/// Renders a [CastError] — the message plus a "Try again" affordance.
///
/// [CastError] used to render nowhere: a failed connect or a mid-session drop
/// produced a blank sheet, which reads exactly like a hang. Every cast surface
/// that can be on screen when the bloc errors (configuration sheet, device
/// picker, queue sheet, Now Playing) builds this instead of an empty box.
///
/// "Try again" dispatches [CastEvent.refreshDiscovery], which re-enters
/// discovery carrying whatever queue the failed session held, so the retry
/// lands the user back where they were rather than in an empty session.
///
/// Every instance registers itself while mounted ([isPresenting]) so the
/// global error toast — the surface for a drop with *no* cast UI open — can
/// stand down when the error is already on screen. Registering here rather
/// than in each host sheet means the suppression tracks the thing it is
/// actually suppressing: a new cast surface that renders this view silences
/// the toast automatically, and one that stops rendering it gets the toast
/// back, with nothing to keep in sync.
class CastErrorView extends StatefulWidget {
  const CastErrorView({
    required this.message,
    this.onRetry,
    this.onDismiss,
    super.key,
  });

  final String message;

  /// Called *after* the retry event is dispatched — sheets that are stacked on
  /// top of the recovery flow (Now Playing) use it to pop themselves.
  final VoidCallback? onRetry;

  /// When non-null, renders a secondary "Dismiss" action.
  final VoidCallback? onDismiss;

  static int _mounted = 0;

  /// True while at least one [CastErrorView] is in the tree, i.e. some cast
  /// surface is already showing the failure inline.
  static bool get isPresenting => _mounted > 0;

  @override
  State<CastErrorView> createState() => _CastErrorViewState();
}

class _CastErrorViewState extends State<CastErrorView> {
  @override
  void initState() {
    super.initState();
    CastErrorView._mounted++;
  }

  @override
  void dispose() {
    CastErrorView._mounted--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MallowTheme.spacing20,
        vertical: MallowTheme.spacingLg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MallowSvgIcon(
            'assets/icons/alert_triangle.svg',
            width: 22,
            height: 22,
            color: colors.error,
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          Text(
            widget.message,
            textAlign: TextAlign.center,
            style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: MallowTheme.spacingLg),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.onDismiss != null) ...[
                _CastErrorAction(
                  label: 'Dismiss',
                  onTap: widget.onDismiss!,
                  borderColor: colors.textTertiary,
                  textColor: colors.textSecondary,
                ),
                const SizedBox(width: MallowTheme.spacingSm),
              ],
              _CastErrorAction(
                label: 'Try again',
                onTap: () {
                  context.read<CastBloc>().add(
                    const CastEvent.refreshDiscovery(),
                  );
                  widget.onRetry?.call();
                },
                borderColor: colors.accent,
                textColor: colors.accent,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Pill button matching the queue sheet's "Clear" affordance — the cast
/// sheets use outlined pills rather than the app-wide filled button.
class _CastErrorAction extends StatelessWidget {
  const _CastErrorAction({
    required this.label,
    required this.onTap,
    required this.borderColor,
    required this.textColor,
  });

  final String label;
  final VoidCallback onTap;
  final Color borderColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: Tappable(
        onTap: onTap,
        semanticLabel: label,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacingLg,
            vertical: MallowTheme.spacingSm,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          ),
          child: Text(
            label,
            style: MallowTheme.uiCaption.copyWith(
              color: textColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
