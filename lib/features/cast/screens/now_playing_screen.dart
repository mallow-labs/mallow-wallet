import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:share_plus/share_plus.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/tappable.dart';
import '../../../shared/widgets/user_handle_text.dart';
import '../../../shared/widgets/verified_badge.dart';
import '../models/cast_queue.dart';
import '../services/cast_bloc.dart';
import '../widgets/cast_configuration_sheet.dart';
import '../widgets/cast_device_picker_sheet.dart';
import '../widgets/cast_error_view.dart';
import '../widgets/cast_queue_sheet.dart';
import '../widgets/now_casting_bar.dart';
import '../widgets/now_playing_kebab_sheet.dart';

/// Opens [NowPlayingScreen] as a full-screen modal sheet — the cast bar's
/// full-screen takeover.
Future<void> showNowPlayingSheet(BuildContext context) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const NowPlayingScreen(),
  );
}

/// Music-player-style sheet for an active cast session. Opens from the
/// `NowCastingBar` via [showNowPlayingSheet]. While mounted, drives
/// [NowCastingBar.suppressed] so the persistent strip in `app.dart` hides
/// itself.
///
/// Auto-pops when the cast session ends or the queue empties.
class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  @override
  void initState() {
    super.initState();
    NowCastingBar.setSuppressed(true);
  }

  @override
  void dispose() {
    NowCastingBar.setSuppressed(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      height: maxSheetHeight(context),
      decoration: BoxDecoration(
        color: colors.bgPrimary,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Column(
        children: [
          const SheetDragHandle(),
          Expanded(
            child: BlocConsumer<CastBloc, CastState>(
              // Pop when the session ends or the queue empties — avoids
              // dead-end UI.
              listenWhen: (prev, curr) {
                final wasActive =
                    prev is CastActive && prev.queue.currentItem != null;
                final isActive =
                    curr is CastActive && curr.queue.currentItem != null;
                // A dropped session is NOT a dead end to pop away from — it is
                // the one moment the user needs to be told what happened, so
                // stay mounted and let the builder render the failure.
                if (curr is CastError) return false;
                return wasActive && !isActive;
              },
              listener: (context, state) {
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
              // Rebuild when any visible aspect of the active session changes.
              buildWhen: (prev, curr) {
                if (prev.runtimeType != curr.runtimeType) return true;
                if (prev is CastActive && curr is CastActive) {
                  return prev.queue != curr.queue;
                }
                return false;
              },
              builder: (context, state) {
                if (state is CastError) {
                  return Center(
                    child: SingleChildScrollView(
                      child: CastErrorView(
                        message: state.message,
                        // Retry re-enters discovery with the dropped session's
                        // queue; app.dart auto-opens the configuration sheet on
                        // that transition, so this sheet gets out of its way.
                        onRetry: () {
                          if (Navigator.of(context).canPop()) {
                            Navigator.of(context).pop();
                          }
                        },
                        onDismiss: () {
                          context.read<CastBloc>().add(
                            const CastEvent.disconnect(),
                          );
                          if (Navigator.of(context).canPop()) {
                            Navigator.of(context).pop();
                          }
                        },
                      ),
                    ),
                  );
                }
                if (state is! CastActive) {
                  // Transient — the listener will pop on the next frame.
                  // Render an empty surface so we don't flash the previous
                  // frame's content.
                  return const SizedBox.shrink();
                }
                final item = state.queue.currentItem;
                if (item == null) return const SizedBox.shrink();
                return _NowPlayingBody(state: state, item: item);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NowPlayingBody extends StatefulWidget {
  const _NowPlayingBody({required this.state, required this.item});

  final CastActive state;
  final CastQueueItem item;

  @override
  State<_NowPlayingBody> createState() => _NowPlayingBodyState();
}

class _NowPlayingBodyState extends State<_NowPlayingBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress;

  @override
  void initState() {
    super.initState();
    final queue = widget.state.queue;
    _progress = AnimationController(
      vsync: this,
      duration: Duration(seconds: queue.slideshowIntervalSeconds),
    );
    if (!queue.isPaused) _progress.forward();
  }

  @override
  void didUpdateWidget(_NowPlayingBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final prev = oldWidget.state.queue;
    final curr = widget.state.queue;

    final itemChanged =
        prev.currentItem?.mintAccount != curr.currentItem?.mintAccount;
    final intervalChanged =
        prev.slideshowIntervalSeconds != curr.slideshowIntervalSeconds;
    if (itemChanged || intervalChanged) {
      _progress.duration = Duration(seconds: curr.slideshowIntervalSeconds);
      _progress
        ..reset()
        ..forward();
    }

    if (prev.isPaused != curr.isPaused) {
      if (curr.isPaused) {
        _progress.stop();
      } else {
        _progress.forward();
      }
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final state = widget.state;
    final item = widget.item;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Column(
        children: [
          _Header(item: item),
          const SizedBox(height: MallowTheme.spacingXl + 20),
          _ArtworkContainer(item: item, colors: colors),
          const SizedBox(height: MallowTheme.spacingXl + 20),
          _TitleAndArtist(item: item, colors: colors),
          const SizedBox(height: MallowTheme.spacingLg),
          _ProgressBar(
            progress: _progress,
            intervalSeconds: state.queue.slideshowIntervalSeconds,
            colors: colors,
          ),
          const Spacer(),
          _PlaybackControls(state: state, colors: colors),
          const Spacer(),
          _BottomActions(item: item, colors: colors),
          SizedBox(height: MediaQuery.viewPaddingOf(context).bottom),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.item});

  final CastQueueItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          // Spacer matching the kebab so the title stays centered on screen.
          const SizedBox(width: 16, height: 16),
          Expanded(
            child: Center(
              child: Text(
                'Now playing',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
          ),
          Tappable(
            onTap: () => showNowPlayingKebabSheet(context, item),
            child: SvgPicture.asset(
              'assets/icons/dots_vertical.svg',
              width: 16,
              height: 16,
              colorFilter: ColorFilter.mode(
                colors.textPrimary,
                BlendMode.srcIn,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtworkContainer extends StatelessWidget {
  const _ArtworkContainer({required this.item, required this.colors});

  final CastQueueItem item;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: colors.bgSurface,
          border: Border.all(color: colors.divider),
        ),
        clipBehavior: Clip.hardEdge,
        child: MallowNetworkImage(
          imageUrl: item.imageUrl,
          logicalSize: 400,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

class _TitleAndArtist extends StatelessWidget {
  const _TitleAndArtist({required this.item, required this.colors});

  final CastQueueItem item;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    final username = item.artistUsername;
    final hasUsername = username != null && username.isNotEmpty;
    final bylineStyle = MallowTheme.uiMeta.copyWith(
      color: colors.textSecondary,
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            item.title,
            style: MallowTheme.editorialSection.copyWith(
              color: colors.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: MallowTheme.spacingXs),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: hasUsername
                    ? UserHandleText(
                        username: username,
                        address: null,
                        style: bylineStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : Text(
                        item.artistName ?? '',
                        style: bylineStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              if (item.isVerified || item.isAdmin) ...[
                const SizedBox(width: MallowTheme.spacingXs),
                VerifiedBadge(size: 16, isAdmin: item.isAdmin),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.progress,
    required this.intervalSeconds,
    required this.colors,
  });

  final AnimationController progress;
  final int intervalSeconds;
  final MallowColors colors;

  String _format(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedBuilder(
          animation: progress,
          builder: (context, _) {
            return SizedBox(
              height: 2,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: colors.surfaceMuted),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: progress.value.clamp(0.0, 1.0),
                      heightFactor: 1,
                      child: ColoredBox(color: colors.accent),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        AnimatedBuilder(
          animation: progress,
          builder: (context, _) {
            final elapsed = (intervalSeconds * progress.value).round();
            final remaining = intervalSeconds - elapsed;
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _format(elapsed),
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  '-${_format(remaining)}',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({required this.state, required this.colors});

  final CastActive state;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    final queue = state.queue;
    final bloc = context.read<CastBloc>();
    final activeColor = colors.accent;
    final inactiveColor = colors.textTertiary;
    final primary = colors.textPrimary;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _IconButton(
          assetPath: 'assets/icons/shuffle.svg',
          color: queue.isShuffled ? activeColor : primary,
          onTap: () => bloc.add(const CastEvent.toggleShuffle()),
        ),
        _SkipButton(
          enabled: queue.canSkipPrevious,
          mirrored: true,
          color: primary,
          onTap: () => bloc.add(const CastEvent.skipPrevious()),
        ),
        _PlayPauseButton(
          isPaused: queue.isPaused,
          onTap: () => bloc.add(const CastEvent.togglePause()),
          colors: colors,
        ),
        _SkipButton(
          enabled: queue.canSkipNext,
          mirrored: false,
          color: primary,
          onTap: () => bloc.add(const CastEvent.skipNext()),
        ),
        _RepeatButton(
          mode: queue.repeatMode,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
          onTap: () => bloc.add(const CastEvent.cycleRepeatMode()),
        ),
      ],
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.assetPath,
    required this.color,
    required this.onTap,
  });

  final String assetPath;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tappable(
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: SvgPicture.asset(
            assetPath,
            width: 24,
            height: 24,
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          ),
        ),
      ),
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({
    required this.enabled,
    required this.mirrored,
    required this.color,
    required this.onTap,
  });

  final bool enabled;
  final bool mirrored;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = SvgPicture.asset(
      'assets/icons/skip.svg',
      width: 24,
      height: 24,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
    return Tappable(
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Center(
            child: mirrored ? Transform.flip(flipX: true, child: icon) : icon,
          ),
        ),
      ),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.isPaused,
    required this.onTap,
    required this.colors,
  });

  final bool isPaused;
  final VoidCallback onTap;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return Tappable(
      onTap: onTap,
      child: Container(
        width: 60,
        height: 60,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.textPrimary,
          shape: BoxShape.circle,
        ),
        child: MallowSvgIcon(
          isPaused ? 'assets/icons/play.svg' : 'assets/icons/pause.svg',
          color: colors.bgPrimary,
        ),
      ),
    );
  }
}

class _RepeatButton extends StatelessWidget {
  const _RepeatButton({
    required this.mode,
    required this.activeColor,
    required this.inactiveColor,
    required this.onTap,
  });

  final CastRepeatMode mode;
  final Color activeColor;
  final Color inactiveColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isActive = mode != CastRepeatMode.off;
    final color = isActive ? activeColor : inactiveColor;
    return Tappable(
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SvgPicture.asset(
              'assets/icons/repeat.svg',
              width: 24,
              height: 24,
              colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
            ),
            if (mode == CastRepeatMode.one)
              Positioned(
                right: 0,
                bottom: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: context.mallowColors.bgPrimary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    '1',
                    style: TextStyle(
                      fontFamily: 'Geist',
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      height: 1,
                      color: color,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BottomActions extends StatelessWidget {
  const _BottomActions({required this.item, required this.colors});

  final CastQueueItem item;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionIcon(
              assetPath: 'assets/icons/settings.svg',
              colors: colors,
              onTap: () => showCastConfigurationSheet(context),
            ),
            const SizedBox(width: MallowTheme.spacing12),
            _ActionIcon(
              assetPath: 'assets/icons/screen.svg',
              colors: colors,
              onTap: () => showCastDevicePickerSheet(context),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionIcon(
              assetPath: 'assets/icons/share.svg',
              colors: colors,
              onTap: () => _shareArtwork(item),
            ),
            const SizedBox(width: MallowTheme.spacing12),
            _ActionIcon(
              assetPath: 'assets/icons/queue.svg',
              colors: colors,
              onTap: () => _showQueueSheet(context),
            ),
          ],
        ),
      ],
    );
  }

  void _shareArtwork(CastQueueItem item) {
    final url = 'https://mallow.art/artwork/${item.mintAccount}';
    SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
  }

  void _showQueueSheet(BuildContext context) {
    showCastQueueSheet(context);
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.assetPath,
    required this.colors,
    required this.onTap,
  });

  final String assetPath;
  final MallowColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tappable(
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: SvgPicture.asset(
            assetPath,
            width: 24,
            height: 24,
            colorFilter: ColorFilter.mode(colors.textPrimary, BlendMode.srcIn),
          ),
        ),
      ),
    );
  }
}
