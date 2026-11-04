import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/utils/reduce_motion.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sliver_overscroll_anchored.dart';
import '../../../shared/widgets/tappable.dart';
import '../models/browser_models.dart';
import '../services/browser_session.dart';
import 'browser_host_text.dart';
import 'browser_site_tile.dart';
import 'browser_tap.dart';

/// What the tab switcher pops: a tab id to show, [browserNewTab], or null
/// for Done.
const browserNewTab = '#new-tab';

/// The tab switcher over the live browser. A [PopupRoute], not a page: a
/// covering page route suspends the website and disposes its WebView, so
/// Done would reload the page. While it is up, the browser's native-overlay
/// count keeps the page from making wallet requests.
Route<String> browserTabSwitcherRoute({
  required BrowserSession session,
  required Set<String> connectedTabs,
  required ValueChanged<String> onClose,
}) => _TabSwitcherRoute(
  builder: (_) => BrowserTabSwitcher(
    session: session,
    connectedTabs: connectedTabs,
    onClose: onClose,
  ),
);

class _TabSwitcherRoute extends PopupRoute<String> {
  _TabSwitcherRoute({required this.builder});

  final WidgetBuilder builder;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => MallowTheme.sheetDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: MallowTheme.sheetCurve,
      reverseCurve: Curves.easeInCubic,
    );
    final fade = FadeTransition(opacity: curved, child: child);
    if (context.reduceMotion) return fade;
    return ScaleTransition(
      scale: Tween<double>(begin: 1.04, end: 1).animate(curved),
      child: fade,
    );
  }
}

/// A full-screen, two-column grid of the open tabs.
class BrowserTabSwitcher extends StatelessWidget {
  const BrowserTabSwitcher({
    required this.session,
    required this.connectedTabs,
    required this.onClose,
    super.key,
  });

  final BrowserSession session;

  /// Tabs whose website is connected to the current wallet; decoration only.
  final Set<String> connectedTabs;
  final ValueChanged<String> onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final safe = MediaQuery.paddingOf(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.5);
    final bottomGap = safe.bottom > 0 ? safe.bottom : MallowTheme.spacing20;
    return Scaffold(
      backgroundColor: colors.surfaceMuted,
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final tabs = session.tabs;
          final count = tabs.length;
          return Stack(
            children: [
              CustomScrollView(
                slivers: [
                  // Safe-area inset lives inside the anchored sliver: a
                  // SliverPadding would hide the overscroll from it.
                  SliverOverscrollAnchored(
                    child: Padding(
                      padding: EdgeInsets.only(top: safe.top),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 6, 8, 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Semantics(
                                header: true,
                                child: Text(
                                  count == 1 ? '1 tab' : '$count tabs',
                                  style: MallowTheme.editorialSection.copyWith(
                                    color: colors.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                            BrowserTap(
                              key: const Key('tab-switcher-done'),
                              onTap: () => Navigator.pop(context),
                              label: 'Done',
                              child: Container(
                                constraints: const BoxConstraints(
                                  minHeight: 44,
                                  minWidth: 44,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  'Done',
                                  style: MallowTheme.uiBody.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: colors.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      8,
                      16,
                      bottomGap + 52 + 32,
                    ),
                    sliver: SliverLayoutBuilder(
                      builder: (context, constraints) {
                        final width = (constraints.crossAxisExtent - 14) / 2;
                        return SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 14,
                                crossAxisSpacing: 14,
                                mainAxisExtent:
                                    width * 1.2 + _TabCard.header * textScale,
                              ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final tab = tabs[index];
                              return _TabCard(
                                key: ValueKey(tab.id),
                                tab: tab,
                                index: index,
                                count: count,
                                active: tab.id == session.activeId,
                                connected: connectedTabs.contains(tab.id),
                                thumbnail: session.thumbnail(tab.id),
                                headerHeight: _TabCard.header * textScale,
                                onTap: () => Navigator.pop(context, tab.id),
                                onClose: () => onClose(tab.id),
                              );
                            },
                            childCount: count,
                            addAutomaticKeepAlives: false,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: bottomGap,
                child: Center(
                  child: BrowserTap(
                    key: const Key('tab-switcher-new-tab'),
                    onTap: () => Navigator.pop(context, browserNewTab),
                    label: 'New tab',
                    child: Container(
                      height: 52,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      decoration: BoxDecoration(
                        color: colors.accent,
                        borderRadius: BorderRadius.circular(
                          MallowTheme.radiusFull,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: colors.accent.withValues(alpha: 0.35),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MallowSvgIcon(
                            'assets/icons/plus_large.svg',
                            width: 18,
                            height: 18,
                            color: colors.textOnAccent,
                          ),
                          const SizedBox(width: 8),
                          MediaQuery.withClampedTextScaling(
                            maxScaleFactor: 1.5,
                            child: Text(
                              'New tab',
                              style: MallowTheme.uiBody.copyWith(
                                fontWeight: FontWeight.w600,
                                color: colors.textOnAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TabCard extends StatelessWidget {
  const _TabCard({
    required this.tab,
    required this.index,
    required this.count,
    required this.active,
    required this.connected,
    required this.thumbnail,
    required this.headerHeight,
    required this.onTap,
    required this.onClose,
    super.key,
  });

  static const double header = 44;

  final BrowserTab tab;
  final int index;
  final int count;
  final bool active;
  final bool connected;
  final Uint8List? thumbnail;
  final double headerHeight;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final url = tab.url;
    final host = url?.host;
    final title = tab.title.trim();
    final label = host == null
        ? 'New tab'
        : title.isEmpty || title == host
        ? host
        : '$host, $title';
    final thumbnail = this.thumbnail;
    final radius = BorderRadius.circular(18);
    return Semantics(
      selected: active,
      label: '$label, tab ${index + 1} of $count',
      child: Container(
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: radius,
          boxShadow: [
            if (active) BoxShadow(color: colors.accent, spreadRadius: 2),
            BoxShadow(
              color: colors.shadow.withValues(alpha: active ? 0.14 : 0.10),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The site and its close button head the card.
              SizedBox(
                height: headerHeight,
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.5,
                  child: Row(
                    children: [
                      Expanded(
                        child: Tappable(
                          onTap: onTap,
                          semanticButton: false,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: Row(
                              children: [
                                if (host != null)
                                  BrowserSiteTile(
                                    host: host,
                                    iconUrl: tab.iconUrl,
                                    size: 20,
                                    connected: connected,
                                  )
                                else
                                  MallowSvgIcon(
                                    'assets/icons/compass.svg',
                                    width: 18,
                                    height: 18,
                                    color: colors.textSecondary,
                                  ),
                                const SizedBox(width: 8),
                                Expanded(
                                  // Host first: a page title only trails it.
                                  child: host == null
                                      ? Text(
                                          'New tab',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: MallowTheme.uiLabel.copyWith(
                                            color: colors.textPrimary,
                                          ),
                                        )
                                      : BrowserHostText(
                                          host,
                                          detail: title == host ? null : title,
                                          detailStyle: TextStyle(
                                            color: colors.textSecondary,
                                          ),
                                          style: MallowTheme.uiLabel.copyWith(
                                            color: colors.textPrimary,
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      BrowserTap(
                        onTap: onClose,
                        label: 'Close $label',
                        child: SizedBox(
                          width: 40,
                          height: headerHeight,
                          child: Center(
                            child: MallowSvgIcon(
                              'assets/icons/close.svg',
                              width: 15,
                              height: 15,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: BrowserTap(
                  onTap: onTap,
                  label: 'Show $label',
                  pressedOpacity: 0.8,
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: colors.dividerLight),
                      ),
                    ),
                    child: thumbnail != null
                        ? Image.memory(
                            thumbnail,
                            fit: BoxFit.cover,
                            alignment: Alignment.topCenter,
                            gaplessPlayback: true,
                            excludeFromSemantics: true,
                            errorBuilder: (context, _, _) =>
                                _Placeholder(host: host, iconUrl: tab.iconUrl),
                          )
                        : _Placeholder(host: host, iconUrl: tab.iconUrl),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.host, required this.iconUrl});

  final String? host;
  final Uri? iconUrl;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final host = this.host;
    return ColoredBox(
      color: colors.bgPrimary,
      child: Center(
        child: host == null
            ? MallowSvgIcon(
                'assets/icons/compass.svg',
                width: 32,
                height: 32,
                color: colors.textTertiary,
              )
            : BrowserSiteTile(host: host, iconUrl: iconUrl, size: 44),
      ),
    );
  }
}
