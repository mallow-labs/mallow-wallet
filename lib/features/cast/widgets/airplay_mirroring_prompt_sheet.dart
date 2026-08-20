import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../services/cast_bloc.dart';

/// Bottom sheet shown after the user taps AirPlay, while iOS Screen
/// Mirroring is not yet active.
///
/// iOS does not expose a public API to programmatically initiate screen
/// mirroring from inside an app — the only path is Control Center. This
/// sheet bridges that gap with explicit instructions and a waiting state,
/// then auto-dismisses the moment the external display scene attaches
/// (i.e. content can actually reach the TV).
///
/// Cancel dispatches [CastEvent.disconnect] so the bloc doesn't linger in a
/// half-active state. The sheet also auto-dismisses if the bloc leaves
/// [CastActive] for any other reason.
Future<void> showAirPlayMirroringPromptSheet(BuildContext context) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => BlocProvider.value(
      value: sl<CastBloc>(),
      child: const _AirPlayMirroringPromptSheet(),
    ),
  );
}

class _AirPlayMirroringPromptSheet extends StatefulWidget {
  const _AirPlayMirroringPromptSheet();

  @override
  State<_AirPlayMirroringPromptSheet> createState() =>
      _AirPlayMirroringPromptSheetState();
}

class _AirPlayMirroringPromptSheetState
    extends State<_AirPlayMirroringPromptSheet> {
  late final CastBloc _bloc = sl<CastBloc>();
  StreamSubscription<bool>? _mirrorSub;

  @override
  void initState() {
    super.initState();
    // Auto-pop the moment iOS attaches the external display scene — the
    // user has done what we asked, content is now live on the TV.
    _mirrorSub = _bloc.externalDisplayActiveStream.listen((active) {
      if (active && mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _mirrorSub?.cancel();
    super.dispose();
  }

  void _onCancel() {
    _bloc.add(const CastEvent.disconnect());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return BlocListener<CastBloc, CastState>(
      // If the session ends by any other path (error, native disconnect),
      // close the sheet so it doesn't linger over a non-casting app.
      listenWhen: (prev, curr) => prev is CastActive && curr is! CastActive,
      listener: (context, _) {
        if (mounted) Navigator.of(context).pop();
      },
      child: Container(
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Padding(
          padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              MallowTheme.spacing20,
              0,
              MallowTheme.spacing20,
              MallowTheme.spacingMd,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetDragHandle(),
                const SizedBox(height: MallowTheme.spacingSm),
                Text(
                  'Connect via AirPlay',
                  style: MallowTheme.uiBody.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: MallowTheme.spacingMd),
                Text(
                  'iOS requires you to start screen mirroring manually:',
                  style: MallowTheme.uiBody.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: MallowTheme.spacingMd),
                const _Step(
                  number: 1,
                  text: 'Swipe down to open Control Center',
                ),
                const _Step(number: 2, text: 'Tap Screen Mirroring'),
                const _Step(number: 3, text: 'Pick your Apple TV'),
                const SizedBox(height: MallowTheme.spacingLg),
                Row(
                  children: [
                    MallowLoader(size: 16, color: colors.textSecondary),
                    const SizedBox(width: MallowTheme.spacingMd),
                    Text(
                      'Waiting for mirror to start…',
                      style: MallowTheme.uiBody.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: MallowTheme.spacingLg),
                MallowButton(
                  label: 'Cancel',
                  variant: MallowButtonVariant.secondary,
                  isFullWidth: true,
                  onPressed: _onCancel,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$number.',
              style: MallowTheme.uiBody.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
