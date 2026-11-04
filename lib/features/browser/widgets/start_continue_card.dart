import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tappable.dart';
import '../models/browser_models.dart';
import 'browser_host_text.dart';
import 'browser_site_tile.dart';

/// The active tab on the start page: its in-memory screenshot, title and
/// host, the connection state and the tab count. The host comes from the
/// tab's stored address, never from the page. The card resumes the active
/// tab; the tab count, when [onTabs] is set, is its own button.
class StartContinueCard extends StatelessWidget {
  const StartContinueCard({
    required this.tab,
    required this.tabCount,
    required this.onTap,
    this.onTabs,
    this.thumbnail,
    this.connectedWallet,
    super.key,
  });
  final BrowserTab tab;
  final int tabCount;
  final Uint8List? thumbnail;

  /// Name of the wallet this site is connected with; null when it is not.
  final String? connectedWallet;
  final VoidCallback onTap;

  /// Opens the tab switcher; null leaves the count as plain text.
  final VoidCallback? onTabs;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final host = tab.url?.host;
    final title = tab.title.trim();
    final tabs = tabCount == 1 ? '1 tab' : '$tabCount tabs';
    final connection = connectedWallet == null
        ? null
        : 'Connected with $connectedWallet';
    final compact = MediaQuery.textScalerOf(context).scale(15) > 22;
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Continue browsing',
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 3),
        _TitleLine(title: title, host: host),
        if (connection != null) ...[
          const SizedBox(height: 3),
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: colors.positive,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  connection,
                  maxLines: compact ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.uiMeta.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: colors.divider),
        borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
      ),
      child: Text(
        tabs,
        style: MallowTheme.uiCaption.copyWith(
          color: colors.textPrimary,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
        ),
      ),
    );
    final onTabs = this.onTabs;
    // Its own semantics node, so it stays a separate button inside the card.
    final count = onTabs == null
        ? ExcludeSemantics(child: pill)
        : Semantics(
            container: true,
            child: Tappable(
              key: const Key('start-continue-tabs'),
              onTap: onTabs,
              semanticLabel: tabCount == 1
                  ? '1 open tab'
                  : '$tabCount open tabs',
              pressedOpacity: 0.7,
              child: ExcludeSemantics(child: pill),
            ),
          );
    return Semantics(
      button: true,
      label: [
        'Continue browsing',
        if (title.isNotEmpty && title != host) title,
        host ?? 'New tab',
        ?connection,
        if (onTabs == null) tabs,
      ].join(', '),
      child: Tappable(
        onTap: onTap,
        semanticButton: false,
        pressedOpacity: 0.7,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
          decoration: BoxDecoration(
            color: colors.bgSurface,
            border: Border.all(color: colors.dividerLight),
            borderRadius: BorderRadius.circular(MallowTheme.radiusLg),
          ),
          // Large text needs the full width for the words, so the preview
          // gives way and the tab count moves under the text.
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(child: details),
                    const SizedBox(height: MallowTheme.spacingSm),
                    count,
                  ],
                )
              : Row(
                  children: [
                    ExcludeSemantics(
                      child: _Thumbnail(tab: tab, bytes: thumbnail),
                    ),
                    const SizedBox(width: 14),
                    Expanded(child: ExcludeSemantics(child: details)),
                    const SizedBox(width: MallowTheme.spacingSm),
                    count,
                  ],
                ),
        ),
      ),
    );
  }
}

/// "host · title" on one line, the same as the tab switcher: the host
/// leads and keeps the end of its domain in view; the page title only gets
/// what is left.
class _TitleLine extends StatelessWidget {
  const _TitleLine({required this.title, required this.host});
  final String title;
  final String? host;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final style = MallowTheme.uiBody.copyWith(
      color: colors.textPrimary,
      fontWeight: FontWeight.w500,
    );
    final host = this.host;
    if (host == null) return Text('New tab', style: style);
    return BrowserHostText(
      host,
      detail: title == host ? null : title,
      detailStyle: TextStyle(color: colors.textSecondary),
      style: style,
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.tab, required this.bytes});
  final BrowserTab tab;
  final Uint8List? bytes;

  static const _width = 56.0;
  static const _height = 72.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final bytes = this.bytes;
    final host = tab.url?.host;
    return Container(
      width: _width,
      height: _height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        border: Border.all(color: colors.dividerLight),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: bytes != null
          ? Image.memory(
              bytes,
              width: _width,
              height: _height,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              gaplessPlayback: true,
              // No cacheWidth: the capture is already at most 360 px wide,
              // and a plain MemoryImage key is what the session evicts when
              // the screenshot is dropped.
            )
          : host != null
          ? BrowserSiteTile(host: host, iconUrl: tab.iconUrl, size: 28)
          : MallowSvgIcon(
              'assets/icons/compass.svg',
              width: 22,
              height: 22,
              color: colors.textSecondary,
            ),
    );
  }
}
