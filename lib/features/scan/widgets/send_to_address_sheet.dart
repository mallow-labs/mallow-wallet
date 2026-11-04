import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/sheet_menu_row.dart';
import '../../../shared/widgets/view_only_prompt.dart';
import '../../send/models/recipient_address.dart';
import '../../send/widgets/send_sheet.dart';
import '../../send/widgets/send_sheet_widgets.dart';

/// What the user chose to send to a scanned address.
enum SendToAddressChoice { tokens, artwork }

/// Asks what to send to [recipient], a wallet address read from a QR code,
/// and opens that flow: the send sheet for tokens, or the artwork chooser for
/// a transfer. Either one starts with the address in its recipient field and
/// offers only what can go to the address's chain.
Future<void> showSendToAddressSheet(
  BuildContext context,
  RecipientAddress recipient,
) async {
  final choice = await showMallowSheet<SendToAddressChoice>(
    context: context,
    builder: (_) => SendToAddressSheet(recipient: recipient),
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case SendToAddressChoice.tokens:
      // The sheet runs the signer gate for the recipient's chain itself.
      await showSendSheet(context, recipient: recipient);
    case SendToAddressChoice.artwork:
      // The chain is known, so ask whether a wallet on it can sign a
      // transfer, rather than whether the active wallet can. An Ethereum
      // artwork is signed by an Ethereum wallet whatever the selection is.
      if (await guardCannotSend(context, chain: recipient.chain)) return;
      if (!context.mounted) return;
      unawaited(context.push(AppRoutes.transferChooser, extra: recipient));
  }
}

/// The two things a wallet address can be sent: tokens or an artwork.
///
/// An artwork transfer to a chain this build cannot transfer artworks on is
/// still listed, disabled with the reason, so the choice does not seem to
/// have gone missing.
class SendToAddressSheet extends StatelessWidget {
  const SendToAddressSheet({required this.recipient, super.key});

  final RecipientAddress recipient;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final chain = recipient.chain;
    final canTransferArtwork = AppFlow.nftTransfer.chains.contains(chain);
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
            padding: const EdgeInsets.fromLTRB(
              MallowTheme.spacing20,
              0,
              MallowTheme.spacing20,
              MallowTheme.spacingMd,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The send sheet's own title, so the two read as one flow.
                const SendStepHeader(title: 'Send'),
                const SizedBox(height: MallowTheme.spacingSm),
                Row(
                  children: [
                    MallowSvgIcon(
                      chain.iconAsset,
                      width: 14,
                      height: 14,
                      color: colors.textSecondary,
                    ),
                    const SizedBox(width: MallowTheme.spacingXs),
                    Flexible(
                      child: Text(
                        'To ${truncateAddress(recipient.address)} '
                        'on ${chain.label}',
                        style: MallowTheme.uiMeta.copyWith(
                          color: colors.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SheetMenuRow(
            assetPath: 'assets/icons/coin.svg',
            label: 'Send tokens',
            onTap: () => Navigator.of(context).pop(SendToAddressChoice.tokens),
          ),
          SheetMenuRow(
            assetPath: 'assets/icons/my_art.svg',
            label: 'Transfer artwork',
            enabled: canTransferArtwork,
            subtitle: canTransferArtwork
                ? null
                : "${chain.label} artworks can't be transferred from the "
                      'app yet',
            onTap: () => Navigator.of(context).pop(SendToAddressChoice.artwork),
          ),
          SizedBox(height: sheetBottomInset(context)),
        ],
      ),
    );
  }
}
