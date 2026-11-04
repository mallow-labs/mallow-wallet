import 'package:flutter/material.dart';

import '../../../core/models/account.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/utils/address_format.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/tappable.dart';
import 'browser_tap.dart';
import 'browser_wallet_avatar.dart';

/// "Connected as …" with a destructive Disconnect, in the page menu. Names the
/// wallet by its Account or Profile, never by the wallet's own label.
class BrowserConnectionCard extends StatelessWidget {
  const BrowserConnectionCard({
    required this.wallet,
    required this.connected,
    this.onDisconnect,
    this.onConnect,
    this.onTap,
    super.key,
  });

  final WalletInfo wallet;
  final bool connected;
  final VoidCallback? onDisconnect;
  final VoidCallback? onConnect;

  /// Opens the wallet picker from the page menu.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final address = truncateAddress(wallet.address, lead: 4, trail: 4);
    final detail = wallet.canSign
        ? '$address · ${wallet.chainEnum.label}'
        : 'View-only · $address';
    final action = connected ? onDisconnect : onConnect;
    final owner = sl.isRegistered<SessionManager>()
        ? sl<SessionManager>().ownerNameFor(wallet.address)
        : null;
    final name = owner ?? address;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          connected ? 'Connected as $name' : name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: MallowTheme.uiBody.copyWith(
            fontWeight: FontWeight.w500,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          connected ? detail : 'Not connected · $detail',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
        ),
      ],
    );
    final button = action == null
        ? null
        : _CardButton(
            key: Key(connected ? 'site-disconnect' : 'site-connect'),
            label: connected ? 'Disconnect' : 'Connect',
            color: connected ? colors.error : colors.textPrimary,
            onTap: action,
          );
    final avatar = BrowserWalletAvatar(
      wallet: wallet,
      size: 36,
      ring: connected ? colors.positive : null,
    );
    final body = Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: colors.bgPrimary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.dividerLight),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(1);
          // Narrow screens and large text put the button under the details
          // instead of squeezing the name to a letter.
          final stacked = constraints.maxWidth < 300 || scale > 1.3;
          final row = Row(
            children: [
              avatar,
              const SizedBox(width: MallowTheme.spacingMd),
              Expanded(child: text),
              if (button != null && !stacked) ...[
                const SizedBox(width: MallowTheme.spacingSm),
                button,
              ],
            ],
          );
          if (button == null || !stacked) return row;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row,
              const SizedBox(height: MallowTheme.spacingMd),
              button,
            ],
          );
        },
      ),
    );
    if (onTap == null) return body;
    return Tappable(
      onTap: onTap,
      semanticLabel: 'Site connection',
      pressedOpacity: 0.8,
      child: body,
    );
  }
}

class _CardButton extends StatelessWidget {
  const _CardButton({
    required this.label,
    required this.color,
    required this.onTap,
    super.key,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return BrowserTap(
      onTap: onTap,
      label: label,
      minHitSize: 44,
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          border: Border.all(color: colors.divider),
        ),
        child: Text(label, style: MallowTheme.uiLabel.copyWith(color: color)),
      ),
    );
  }
}
