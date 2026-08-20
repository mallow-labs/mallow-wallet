import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/router/app_router.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../models/cast_queue.dart';
import '../services/cast_bloc.dart';

/// Overflow menu shown from the Now Playing screen's kebab icon. Two
/// actions: open the artwork's marketplace page, or end the cast session.
Future<void> showNowPlayingKebabSheet(
  BuildContext context,
  CastQueueItem item,
) {
  return runGuardedSheet<void>(
    'nowPlayingKebab',
    () => showMallowSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => BlocProvider.value(
        value: sl<CastBloc>(),
        child: _NowPlayingKebabSheet(item: item),
      ),
    ),
  );
}

class _NowPlayingKebabSheet extends StatelessWidget {
  const _NowPlayingKebabSheet({required this.item});

  final CastQueueItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetDragHandle(),
          _KebabRow(
            iconAsset: 'assets/icons/export.svg',
            label: 'View on marketplace',
            colors: colors,
            onTap: () {
              Navigator.of(context).pop();
              final navContext = AppRoutes.rootNavigatorKey.currentContext;
              if (navContext == null) return;
              // Pop the Now Playing screen so back from the artwork
              // returns to whatever was underneath it.
              Navigator.of(navContext).pop();
              navContext.goToArtwork(item.mintAccount);
            },
          ),
          _KebabRow(
            iconAsset: 'assets/icons/cast.svg',
            label: 'Disconnect',
            colors: colors,
            isDestructive: true,
            onTap: () {
              context.read<CastBloc>().add(const CastEvent.disconnect());
              Navigator.of(context).pop();
              // Disconnect transitions the bloc to idle; the Now Playing
              // screen's BlocListener will pop itself on the next frame.
            },
          ),
          SizedBox(height: sheetBottomInset(context)),
        ],
      ),
    );
  }
}

class _KebabRow extends StatelessWidget {
  const _KebabRow({
    required this.iconAsset,
    required this.label,
    required this.colors,
    required this.onTap,
    this.isDestructive = false,
  });

  final String iconAsset;
  final String label;
  final MallowColors colors;
  final VoidCallback onTap;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final color = isDestructive ? colors.error : colors.textPrimary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacing20,
          vertical: MallowTheme.spacingMd,
        ),
        child: Row(
          children: [
            MallowSvgIcon(iconAsset, width: 20, height: 20, color: color),
            const SizedBox(width: MallowTheme.spacingMd),
            Expanded(
              child: Text(
                label,
                style: MallowTheme.uiBody.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
