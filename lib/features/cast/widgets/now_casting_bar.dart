import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/router/app_router.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../models/cast_queue.dart';
import '../screens/now_playing_screen.dart';
import '../services/cast_bloc.dart';

/// Persistent "Now Casting" strip pinned to the bottom of the app.
///
/// Renders whenever [CastBloc] is [CastActive] with a current item. The
/// nav bar pill above offsets up by [contentHeight] + [gapAboveNavBar]
/// while this bar is showing.
class NowCastingBar extends StatelessWidget {
  const NowCastingBar({super.key});

  /// Fixed height of the bar's visible chrome (progress + content row).
  /// Excludes the device home-indicator inset, which is owned by the
  /// bar's own [SafeArea].
  static const double contentHeight = 50;

  /// Gap rendered between the bar's top edge and the nav bar pill above
  /// it when both are visible. Matches the Figma spec.
  static const double gapAboveNavBar = 9;

  /// Driven by [NowPlayingScreen]'s lifecycle to suppress the bar while
  /// its full-screen takeover is on top. Lifecycle-driven rather than
  /// route-URL-driven because go_router's `currentConfiguration.uri`
  /// does not reflect imperative `push()` matches (see
  /// [RouteMatchList.uri] docs in go_router 17), so a path-equality
  /// check would never fire while Now Playing is mounted.
  ///
  /// Write via [setSuppressed], which defers the notification to the
  /// next frame when called mid-build (e.g. from a route's `initState`
  /// during a router rebuild) to avoid setState-during-build in the
  /// listening `ValueListenableBuilder`.
  static final ValueNotifier<bool> suppressed = ValueNotifier<bool>(false);

  static void setSuppressed(bool value) {
    if (suppressed.value == value) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        suppressed.value = value;
      });
    } else {
      suppressed.value = value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CastBloc, CastState>(
      buildWhen: (prev, curr) {
        final prevActive = prev is CastActive;
        final currActive = curr is CastActive;
        if (prevActive != currActive) return true;
        if (curr is CastActive && prev is CastActive) {
          return curr.queue != prev.queue || curr.device != prev.device;
        }
        return false;
      },
      builder: (context, state) {
        final shouldShow =
            state is CastActive && state.queue.currentItem != null;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          reverseDuration: const Duration(milliseconds: 180),
          transitionBuilder: (child, animation) {
            final slide =
                Tween<Offset>(
                  begin: const Offset(0, 1),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                    reverseCurve: Curves.easeInCubic,
                  ),
                );
            return SlideTransition(
              position: slide,
              child: FadeTransition(opacity: animation, child: child),
            );
          },
          child: shouldShow
              ? _CastingBar(key: const ValueKey('bar'), state: state)
              : const SizedBox.shrink(key: ValueKey('empty')),
        );
      },
    );
  }

  /// True when [NowCastingBar] is currently rendering its chrome — i.e. an
  /// active cast session with a current item. Mirrors the `shouldShow` gate
  /// used inside [build].
  static bool isVisible(CastState state) =>
      state is CastActive && state.queue.currentItem != null;
}

/// Rebuilds [builder] with `inset` set to [NowCastingBar.contentHeight] while
/// the cast bar is showing and `0` otherwise, so sticky bottom chrome (action
/// bars, [Positioned] sheets, footer buttons) can offset itself to clear the
/// bar. Reads [CastBloc] directly from [sl] so it works inside modal sheets
/// that don't see the root [BlocProvider].
class CastBarBottomInsetBuilder extends StatelessWidget {
  const CastBarBottomInsetBuilder({required this.builder, super.key});

  final Widget Function(BuildContext context, double inset) builder;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CastBloc, CastState>(
      bloc: sl<CastBloc>(),
      buildWhen: (prev, curr) =>
          NowCastingBar.isVisible(prev) != NowCastingBar.isVisible(curr),
      builder: (context, state) {
        final inset = NowCastingBar.isVisible(state)
            ? NowCastingBar.contentHeight
            : 0.0;
        return builder(context, inset);
      },
    );
  }
}

/// Extends the child's [MediaQuery.padding] bottom inset by
/// [NowCastingBar.contentHeight] while the cast bar is showing, so any
/// descendant that already reads `MediaQuery.padding.bottom` (e.g. a
/// `SafeArea` or a bottom `Padding`) lifts above the bar without code
/// changes. Applied once at the root of the routed Navigator so every
/// screen sees the inflated value — individual screens should NOT wrap
/// again or padding will double up.
class CastBarMediaQueryInset extends StatelessWidget {
  const CastBarMediaQueryInset({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CastBarBottomInsetBuilder(
      builder: (context, inset) {
        if (inset == 0) return child;
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            padding: media.padding.copyWith(
              bottom: media.padding.bottom + inset,
            ),
          ),
          child: child,
        );
      },
    );
  }
}

/// `SizedBox` that reserves [base] pixels at the bottom of a scrollable
/// for the persistent nav bar pill, expanding by the cast bar's visible
/// height plus its gap-above-nav-bar when the bar is showing — so the
/// reserved space tracks the nav bar's actual on-screen position.
///
/// Drop in as the last child of a sliver list (wrap in
/// [SliverToBoxAdapter]) or a `Column`.
class NavBarBottomReserve extends StatelessWidget {
  const NavBarBottomReserve({this.base = 140, super.key});

  final double base;

  @override
  Widget build(BuildContext context) {
    return CastBarBottomInsetBuilder(
      builder: (_, inset) => SizedBox(
        height: inset == 0 ? base : base + inset + NowCastingBar.gapAboveNavBar,
      ),
    );
  }
}

class _CastingBar extends StatefulWidget {
  const _CastingBar({required this.state, super.key});

  final CastActive state;

  @override
  State<_CastingBar> createState() => _CastingBarState();
}

class _CastingBarState extends State<_CastingBar>
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
  void didUpdateWidget(_CastingBar oldWidget) {
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
    final item = state.queue.currentItem;
    if (item == null) return const SizedBox.shrink();

    final byline =
        (item.artistUsername != null && item.artistUsername!.isNotEmpty)
        ? '@${item.artistUsername}'
        : (item.artistName ?? '');
    final title = byline.isEmpty ? item.title : '${item.title} • $byline';
    final deviceName = state.device.name.isEmpty ? 'device' : state.device.name;

    // Bar is mounted as a Positioned sibling outside the routed Scaffold,
    // so descendants have no Material ancestor — Text would otherwise
    // show Flutter's yellow debug underline.
    return Material(
      type: MaterialType.transparency,
      child: ColoredBox(
        color: colors.bgPrimary,
        child: SafeArea(
          top: false,
          left: false,
          right: false,
          child: SizedBox(
            height: NowCastingBar.contentHeight,
            child: Stack(
              children: [
                // Two-segment progress underline pinned to the TOP edge.
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 2,
                  child: AnimatedBuilder(
                    animation: _progress,
                    builder: (context, _) {
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(color: colors.textTertiary),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: _progress.value.clamp(0.0, 1.0),
                              heightFactor: 1,
                              child: ColoredBox(color: colors.textPrimary),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 2,
                  bottom: 0,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        // Tap target for opening Now Playing — covers the
                        // artwork, title, device row, and the cast-status
                        // icon. Play/pause is a separate sibling so its
                        // tap doesn't get swallowed.
                        Expanded(
                          child: TapTargetExpander(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                final navContext =
                                    AppRoutes.rootNavigatorKey.currentContext;
                                if (navContext == null) return;
                                showNowPlayingSheet(navContext);
                              },
                              child: Row(
                                children: [
                                  MallowNetworkImage(
                                    imageUrl: item.imageUrl,
                                    logicalSize: 32,
                                    width: 32,
                                    height: 32,
                                    borderRadius: BorderRadius.circular(3.2),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          title,
                                          style: MallowTheme.uiCaption.copyWith(
                                            color: colors.textPrimary,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            MallowSvgIcon(
                                              'assets/icons/cast.svg',
                                              width: 16,
                                              height: 16,
                                              color:
                                                  context.mallowColors.warning,
                                            ),
                                            const SizedBox(width: 4),
                                            Flexible(
                                              child: Text(
                                                deviceName,
                                                style: MallowTheme.uiCaption
                                                    .copyWith(
                                                      color: context
                                                          .mallowColors
                                                          .warning,
                                                    ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Cast icon — visual indicator only; the
                                  // surrounding tap target opens Now Playing.
                                  SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: Center(
                                      child: SvgPicture.asset(
                                        'assets/icons/cast.svg',
                                        width: 20,
                                        height: 20,
                                        colorFilter: ColorFilter.mode(
                                          colors.textPrimary,
                                          BlendMode.srcIn,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TapTargetExpander(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => context.read<CastBloc>().add(
                              const CastEvent.togglePause(),
                            ),
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: MallowSvgIcon(
                                state.queue.isPaused
                                    ? 'assets/icons/play.svg'
                                    : 'assets/icons/pause.svg',
                                width: 22,
                                height: 22,
                                color: colors.textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
