import 'package:flutter/material.dart';

import '../../../core/config/store_build.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../artwork/services/artwork_action_state.dart';
import '../../artwork/services/artwork_bloc.dart';
import '../../artwork/widgets/sheets/artwork_sheet_frame.dart';

/// Opens a live purchase quote before the buyer approves any payment.
class OpenSeaListingSheet extends StatelessWidget {
  const OpenSeaListingSheet({
    required this.artwork,
    required this.onBuy,
    this.block,
    super.key,
  });
  final ArtworkDetails artwork;
  final VoidCallback onBuy;
  final ArtworkBuyBlock? block;

  @override
  Widget build(BuildContext context) {
    final c = context.mallowColors;
    final label = switch (block) {
      ArtworkBuyBlock.notStarted => 'Sale has not started',
      ArtworkBuyBlock.ended => 'Sale ended',
      ArtworkBuyBlock.unknownCurrency => 'Payment currency unavailable',
      null => 'Buy',
    };
    return ArtworkSheetFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Listed on OpenSea',
            style: MallowTheme.uiTitle.copyWith(color: c.textPrimary),
          ),
          const SizedBox(height: MallowTheme.spacingSm),
          Text(
            artwork.tokenStandard == 'erc1155'
                ? 'Buy one copy with ETH. Review the current price and fees before approving.'
                : 'Pay with ETH. Review the current price and fees before approving.',
            style: MallowTheme.uiCaption.copyWith(color: c.textSecondary),
          ),
          if (showNftCommerce) ...[
            const SizedBox(height: MallowTheme.spacingMd),
            MallowButton(
              label: label,
              onPressed: block == null ? onBuy : null,
              isFullWidth: true,
            ),
          ],
        ],
      ),
    );
  }
}
