import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/account.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/wallet_type_badge.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import 'chain_visuals.dart';
import 'receive_sheet.dart';

/// Opens the receive sheet scoped to the current session's wallets — the same
/// surface as the drawer header's QR button. A Profile session surfaces only
/// that profile's linked wallets, while an Account session shows the account's
/// wallets (see [SessionManager.sessionWallets]). Falls back to the default
/// [showReceiveSheet] when the session has no wallets.
Future<void> showSessionReceiveSheet(BuildContext context) {
  final wallets = sl<SessionManager>().sessionWallets;
  if (wallets.isNotEmpty) {
    return showWalletsReceiveSheet(context, wallets: wallets);
  }
  return showReceiveSheet(context);
}

/// Shows the per-account/profile "wallet menu" sheet: one row per [wallets]
/// entry, each with its chain, address, and inline QR + copy actions. Tapping a
/// row's QR opens the full [showReceiveSheet] for that specific address.
///
/// With a single wallet there's nothing to pick, so this jumps straight to that
/// address's QR via [showReceiveSheet] instead of showing the one-row picker.
Future<void> showWalletsReceiveSheet(
  BuildContext context, {
  required List<WalletInfo> wallets,
}) {
  if (wallets.length == 1) {
    final wallet = wallets.first;
    return showReceiveSheet(
      context,
      address: wallet.address,
      chain: wallet.chainEnum,
    );
  }
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _WalletsReceiveSheet(wallets: wallets),
  );
}

class _WalletsReceiveSheet extends StatelessWidget {
  const _WalletsReceiveSheet({required this.wallets});

  final List<WalletInfo> wallets;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final bottomPad = sheetBottomInset(context);

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
          Padding(
            padding: EdgeInsets.fromLTRB(
              MallowTheme.spacing20,
              MallowTheme.spacing12,
              MallowTheme.spacing20,
              bottomPad,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < wallets.length; i++) ...[
                  if (i > 0) const SizedBox(height: 16),
                  _ChainRow(wallet: wallets[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChainRow extends StatelessWidget {
  const _ChainRow({required this.wallet});

  final WalletInfo wallet;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      children: [
        ChainGlyph(chain: wallet.chainEnum, color: colors.textPrimary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                wallet.chainEnum.label,
                style: MallowTheme.uiBody,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      truncateAddress(wallet.address),
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  WalletTypeBadge(wallet.badge, size: 12),
                ],
              ),
            ],
          ),
        ),
        _RowIconButton(
          asset: 'assets/icons/qr.svg',
          label: 'Show QR code',
          onTap: () => showReceiveSheet(
            context,
            address: wallet.address,
            chain: wallet.chainEnum,
          ),
        ),
        const SizedBox(width: 12),
        _RowIconButton(
          asset: 'assets/icons/copy.svg',
          label: 'Copy address',
          onTap: () => _copyAddress(context),
        ),
      ],
    );
  }

  void _copyAddress(BuildContext context) {
    unawaited(Clipboard.setData(ClipboardData(text: wallet.address)));
    unawaited(HapticFeedback.lightImpact());
    AppSnackBar.show(
      context,
      '${truncateAddress(wallet.address)} copied to clipboard',
      type: AppSnackBarType.success,
      duration: const Duration(seconds: 2),
    );
  }
}

class _RowIconButton extends StatelessWidget {
  const _RowIconButton({
    required this.asset,
    required this.label,
    required this.onTap,
  });

  final String asset;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: TapTargetExpander(
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: MallowSvgIcon(
            asset,
            width: 24,
            height: 24,
            color: context.mallowColors.textPrimary,
          ),
        ),
      ),
    );
  }
}
