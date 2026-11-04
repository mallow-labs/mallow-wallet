import 'package:flutter/material.dart';

import '../../../core/utils/address_format.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tappable.dart';
import '../../settings/widgets/settings_menu_item.dart';
import '../services/dapp_permission_service.dart';
import 'browser_site_tile.dart';

/// Section heading and optional explanation, in the settings screens' type.
class BrowserSettingsSection extends StatelessWidget {
  const BrowserSettingsSection({required this.title, this.caption, super.key});
  final String title;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: MallowTheme.editorialSubhead.copyWith(
              color: context.mallowColors.textPrimary,
            ),
          ),
        ),
        if (caption case final caption?) ...[
          const SizedBox(height: MallowTheme.spacingXs),
          BrowserSettingsCaption(caption),
        ],
      ],
    );
  }
}

/// Explanatory text under a settings heading, or at the top of a screen.
class BrowserSettingsCaption extends StatelessWidget {
  const BrowserSettingsCaption(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: MallowTheme.uiCaption.copyWith(
      color: context.mallowColors.textSecondary,
    ),
  );
}

/// What a settings list shows in place of its rows: empty, or not loaded.
class BrowserSettingsPlaceholder extends StatelessWidget {
  const BrowserSettingsPlaceholder(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingSm),
    child: Text(
      text,
      style: MallowTheme.uiBody.copyWith(
        color: context.mallowColors.textSecondary,
      ),
    ),
  );
}

/// A settings row: 24 dp icon, label and an optional trailing value or
/// count pill, matching the app's 36 dp settings menu rows but free to grow
/// with large text.
class BrowserSettingsRow extends StatelessWidget {
  const BrowserSettingsRow({
    required this.iconAsset,
    required this.label,
    this.value,
    this.badge,
    this.onTap,
    this.destructive = false,
    this.trailing,
    super.key,
  });
  final String iconAsset;
  final String label;
  final String? value;

  /// A count or summary in the settings menu's pill. Null shows none.
  final String? badge;
  final VoidCallback? onTap;
  final bool destructive;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final ink = destructive ? colors.error : colors.textPrimary;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 36),
      child: Row(
        children: [
          MallowSvgIcon(iconAsset, width: 24, height: 24, color: ink),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: MallowTheme.uiBody.copyWith(color: ink)),
          ),
          if (value case final value?) ...[
            const SizedBox(width: MallowTheme.spacingSm),
            Text(
              value,
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
          if (badge case final badge?) ...[
            const SizedBox(width: MallowTheme.spacingSm),
            SettingsBadgePill(text: badge),
          ],
          ?trailing,
        ],
      ),
    );
    if (onTap == null) return MergeSemantics(child: row);
    return Tappable(onTap: onTap, semanticLabel: label, child: row);
  }
}

/// A connected site: its tile, host, the wallet it can see (its Account's
/// name and short address) and a disconnect control. The host is parsed from
/// the stored grant origin.
class ConnectedSiteRow extends StatelessWidget {
  const ConnectedSiteRow({
    required this.grant,
    required this.onDisconnect,
    this.accountName,
    super.key,
  });
  final DappGrant grant;
  final String? accountName;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final host = Uri.parse(grant.origin).host;
    final wallet = [
      ?accountName,
      truncateAddress(grant.address, lead: 4, trail: 4),
    ].join(' · ');
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          BrowserSiteTile(host: host, size: 36),
          const SizedBox(width: MallowTheme.spacingMd),
          Expanded(
            child: MergeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    wallet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: MallowTheme.uiMeta.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Tappable(
            onTap: onDisconnect,
            semanticLabel: 'Disconnect $host',
            child: SizedBox.square(
              dimension: 44,
              child: Center(
                child: MallowSvgIcon(
                  'assets/icons/close.svg',
                  width: 20,
                  height: 20,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
