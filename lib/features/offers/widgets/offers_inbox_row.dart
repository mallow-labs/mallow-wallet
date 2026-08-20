import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/services/avatar_service.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/mallow_pill_chip.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../artwork/widgets/activity_list_row.dart';

/// One offer/bid row on the Offers screen. Reuses the artwork-page
/// [ActivityListRow] (actor avatar + "{name} {verb}" + amount + age) and adds
/// the Figma "View" pill, whose tap is dispatched by the screen per
/// (direction, kind).
class OffersInboxRow extends StatelessWidget {
  const OffersInboxRow({required this.item, required this.onView, super.key});

  final api.OffersInboxItem item;
  final VoidCallback onView;

  bool get _isPlaced => item.direction == api.OffersInboxDirection.placed;

  /// "Cancel" for an offer you placed (View opens the cancel flow); "View"
  /// otherwise — received offer (accept), or any bid (deep-links to artwork).
  String get _actionLabel =>
      _isPlaced && item.kind == api.OffersInboxKind.offer ? 'Cancel' : 'View';

  String _name() {
    if (_isPlaced) return 'You';
    return item.actor?.username ??
        item.actor?.displayName ??
        truncateAddress(item.actorAddress);
  }

  String _verb() => switch (item.kind) {
    api.OffersInboxKind.offer => 'made an offer',
    api.OffersInboxKind.bid => 'placed a bid',
  };

  @override
  Widget build(BuildContext context) {
    return ActivityListRow(
      name: _name(),
      action: _verb(),
      circularAvatar: true,
      avatarUrl: item.actor?.avatarUrl,
      // Only received rows linkify to the counterparty's profile; "You" rows
      // stay inert.
      username: _isPlaced ? null : item.actor?.username,
      address: _isPlaced ? null : item.actorAddress,
      // The identicon seed keeps the actor's identity even on inert rows.
      avatarSeed: avatarSeedOf(
        address: item.actorAddress,
        username: item.actor?.username,
      ),
      amount: PriceFormatter.formatRawAmountWithSymbol(
        item.rawAmount,
        item.currencyMint,
      ),
      age: item.date == null ? null : formatLastUpdated(item.date),
      trailing: TapTargetExpander(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onView,
          child: MallowPillChip(_actionLabel),
        ),
      ),
    );
  }
}
