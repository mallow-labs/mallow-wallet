import 'package:flutter/material.dart';

import '../../../core/models/account.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/sheet_menu_row.dart';
import 'browser_connection_card.dart';
import 'browser_host_text.dart';
import 'browser_site_tile.dart';
import 'browser_tap.dart';

/// Everything the page menu can ask the browser to do.
enum BrowserMenuAction {
  bookmark,
  share,
  reload,
  stop,
  newTab,
  copyLink,
  scanPageCode,
  settings,
  close,
  disconnect,
  wallet,
}

/// The ⋯ page menu. [url] is the natively committed URL (never a page-supplied
/// one) and null on the start page, which disables the page actions. [title]
/// is the page's own title: decoration beside the committed origin only.
class BrowserPageMenu extends StatelessWidget {
  const BrowserPageMenu({
    required this.url,
    required this.title,
    required this.bookmarked,
    required this.loading,
    required this.wallet,
    required this.connected,
    this.iconUrl,
    this.notSecure = false,
    this.canScanCode = false,
    super.key,
  });

  final Uri? url;
  final String title;
  final Uri? iconUrl;
  final bool bookmarked;
  final bool loading;
  final WalletInfo? wallet;
  final bool connected;

  /// The user overrode a certificate warning on this site, so its identity
  /// is unverified.
  final bool notSecure;

  /// Offers to read a WalletConnect code shown on the page, for a build with
  /// WalletConnect.
  final bool canScanCode;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final url = this.url;
    final wallet = this.wallet;
    void pick(BrowserMenuAction action) => Navigator.pop(context, action);
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetDragHandle(),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MallowTheme.spacing20,
                    MallowTheme.spacingSm,
                    MallowTheme.spacing20,
                    0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SiteHeader(
                        url: url,
                        title: title,
                        iconUrl: iconUrl,
                        notSecure: notSecure,
                      ),
                      if (url != null && wallet != null && connected) ...[
                        const SizedBox(height: MallowTheme.spacing12 + 4),
                        BrowserConnectionCard(
                          wallet: wallet,
                          connected: true,
                          onDisconnect: () =>
                              pick(BrowserMenuAction.disconnect),
                          onTap: () => pick(BrowserMenuAction.wallet),
                        ),
                      ],
                      const SizedBox(height: MallowTheme.spacing12 + 4),
                      _QuickTiles(
                        tiles: [
                          _QuickTile(
                            asset: bookmarked
                                ? 'assets/icons/bookmark_filled.svg'
                                : 'assets/icons/bookmark.svg',
                            label: bookmarked ? 'Saved' : 'Bookmark',
                            semanticLabel: bookmarked
                                ? 'Remove bookmark'
                                : 'Bookmark this page',
                            accent: bookmarked,
                            onTap: url == null
                                ? null
                                : () => pick(BrowserMenuAction.bookmark),
                          ),
                          _QuickTile(
                            asset: 'assets/icons/share_up.svg',
                            label: 'Share',
                            onTap: url == null
                                ? null
                                : () => pick(BrowserMenuAction.share),
                          ),
                          _QuickTile(
                            asset: loading
                                ? 'assets/icons/close.svg'
                                : 'assets/icons/reload.svg',
                            label: loading ? 'Stop' : 'Reload',
                            semanticLabel: loading ? 'Stop loading' : 'Reload',
                            onTap: url == null
                                ? null
                                : () => pick(
                                    loading
                                        ? BrowserMenuAction.stop
                                        : BrowserMenuAction.reload,
                                  ),
                          ),
                          _QuickTile(
                            asset: 'assets/icons/plus_large.svg',
                            label: 'New tab',
                            onTap: () => pick(BrowserMenuAction.newTab),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
                _Row(
                  asset: 'assets/icons/copy_outline.svg',
                  label: 'Copy link',
                  enabled: url != null,
                  onTap: () => pick(BrowserMenuAction.copyLink),
                ),
                if (canScanCode)
                  _Row(
                    asset: 'assets/icons/qr.svg',
                    label: 'Scan QR code on page',
                    enabled: url != null,
                    onTap: () => pick(BrowserMenuAction.scanPageCode),
                  ),
                if (!connected)
                  _Row(
                    asset: 'assets/icons/wallet.svg',
                    label: 'Switch wallet',
                    onTap: () => pick(BrowserMenuAction.wallet),
                  ),
                _Row(
                  asset: 'assets/icons/settings.svg',
                  label: 'Browser settings',
                  onTap: () => pick(BrowserMenuAction.settings),
                ),
                _Row(
                  asset: 'assets/icons/close.svg',
                  label: 'Close tab',
                  divider: false,
                  onTap: () => pick(BrowserMenuAction.close),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SiteHeader extends StatelessWidget {
  const _SiteHeader({
    required this.url,
    required this.title,
    required this.iconUrl,
    required this.notSecure,
  });

  final Uri? url;
  final String title;
  final Uri? iconUrl;
  final bool notSecure;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final url = this.url;
    if (url == null) {
      return Text(
        'New tab',
        style: MallowTheme.editorialSection.copyWith(color: colors.textPrimary),
      );
    }
    // The committed host leads, so a long or deceptive page title can only
    // ever trail it, never push it out of view.
    final pageTitle = title.trim();
    final path = url.hasQuery ? '${url.path}?${url.query}' : url.path;
    return Row(
      children: [
        BrowserSiteTile(host: url.host, iconUrl: iconUrl, size: 44),
        const SizedBox(width: MallowTheme.spacingMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BrowserHostText(
                url.host,
                detail: pageTitle == url.host ? null : pageTitle,
                detailStyle: TextStyle(color: colors.textSecondary),
                style: MallowTheme.uiIdentity.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  MallowSvgIcon(
                    notSecure
                        ? 'assets/icons/alert_triangle.svg'
                        : 'assets/icons/lock.svg',
                    width: 11,
                    height: 11,
                    color: notSecure ? colors.warning : colors.textSecondary,
                  ),
                  const SizedBox(width: 5),
                  if (notSecure) ...[
                    Text(
                      'Not secure',
                      key: const Key('browser-menu-not-secure'),
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.warning,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(width: 5),
                  ],
                  // Host then path: the path gives way, the host's end
                  // never does.
                  Flexible(
                    child: BrowserHostText(
                      url.host,
                      detail: path == '/' ? null : path,
                      separator: '',
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.textSecondary,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Four quick actions in a row, or two by two when the labels would not fit.
class _QuickTiles extends StatelessWidget {
  const _QuickTiles({required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 10.0;
      final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.3);
      final columns = (constraints.maxWidth - gap * 3) / 4 >= 60 * scale
          ? 4
          : 2;
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final tile in tiles) SizedBox(width: width, child: tile),
          ],
        ),
      );
    },
  );
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({
    required this.asset,
    required this.label,
    required this.onTap,
    this.semanticLabel,
    this.accent = false,
  });

  final String asset;
  final String label;
  final String? semanticLabel;
  final bool accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final enabled = onTap != null;
    final ink = enabled ? colors.textPrimary : colors.textTertiary;
    final tile = Container(
      constraints: const BoxConstraints(minHeight: 76),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          MallowSvgIcon(
            asset,
            width: 22,
            height: 22,
            color: accent && enabled ? colors.accent : ink,
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: MallowTheme.uiLabel.copyWith(fontSize: 12, color: ink),
            ),
          ),
        ],
      ),
    );
    return enabled
        ? BrowserTap(onTap: onTap, label: semanticLabel ?? label, child: tile)
        : Semantics(
            button: true,
            enabled: false,
            label: semanticLabel ?? label,
            excludeSemantics: true,
            child: tile,
          );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.asset,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.divider = true,
  });

  final String asset;
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool divider;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SheetMenuRow(
        label: label,
        assetPath: asset,
        enabled: enabled,
        onTap: onTap,
      ),
      if (divider)
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Divider(
            height: 1,
            thickness: 1,
            color: context.mallowColors.dividerLight,
          ),
        ),
    ],
  );
}

/// Asks before handing the committed [url] to the system share sheet; pops
/// true to share.
class BrowserShareSheet extends StatelessWidget {
  const BrowserShareSheet({required this.url, super.key});

  final Uri url;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        MallowTheme.spacing20,
        0,
        MallowTheme.spacing20,
        sheetBottomInset(context),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetDragHandle(),
          const SizedBox(height: MallowTheme.spacingSm),
          Text(
            'Share this page?',
            style: MallowTheme.editorialSection.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: MallowTheme.spacingSm),
          Text(
            'The full address is shared, including anything after the domain.',
            style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          Container(
            padding: const EdgeInsets.all(MallowTheme.spacingMd),
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: BorderRadius.circular(MallowTheme.radiusMd),
            ),
            constraints: const BoxConstraints(maxHeight: 120),
            child: SingleChildScrollView(
              child: SelectableText(
                url.toString(),
                style: MallowTheme.uiMeta.copyWith(
                  color: colors.textPrimary,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
          const SizedBox(height: MallowTheme.spacingLg),
          Row(
            children: [
              Expanded(
                child: MallowButton(
                  label: 'Cancel',
                  variant: MallowButtonVariant.secondary,
                  isFullWidth: true,
                  onPressed: () => Navigator.pop(context, false),
                ),
              ),
              const SizedBox(width: MallowTheme.spacingMd),
              Expanded(
                child: MallowButton(
                  key: const Key('confirm-share'),
                  label: 'Share',
                  isFullWidth: true,
                  onPressed: () => Navigator.pop(context, true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
