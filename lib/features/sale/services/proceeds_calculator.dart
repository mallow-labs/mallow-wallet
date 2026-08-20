import '../../artwork/services/artwork_bloc.dart' show ArtworkRoyaltySplit;

/// Marketplace fee recipient. Doubles as the
/// unique key in the per-recipient proceeds map; collisions with creator
/// addresses are impossible because this is mallow's controlled fee account.
const kMallowFeeAddress = 'MFHHByMGfk84s3GZ8dZHaQQ3gbpQYc2NnQYPg2tRCSx';

/// Recipient label for proceeds rows.
enum ProceedsLabel { you, creator, mallow }

/// One row in the proceeds breakdown.
class ProceedsSplit {
  const ProceedsSplit({
    required this.label,
    required this.address,
    required this.proceedsPct,
    required this.amountRaw,
  });

  /// Display label — `'You'`, `'Creator'`, or `'mallow'`.
  final ProceedsLabel label;

  /// Recipient base58 address. For the marketplace fee row this is
  /// [kMallowFeeAddress] — a real pubkey, so it renders normally.
  final String address;

  /// 0..100.
  final double proceedsPct;

  /// `priceRaw * proceedsPct / 100`, rounded to nearest int.
  final int amountRaw;
}

/// Faithful Dart port of webapp's `getProceedsSplits`
/// (`listing`).
///
/// Returns the per-recipient splits sorted by proceeds descending, with
/// raw token amounts pre-computed from [priceRaw]. When [priceRaw] is 0
/// the amount column is also 0; callers render `—` in that case.
List<ProceedsSplit> computeProceedsSplits({
  required String seller,
  required int priceRaw,
  required bool isSecondary,
  required List<ArtworkRoyaltySplit> royaltyShares,
  required int royaltyBps,
  required int primaryFeeBps,
  required int secondaryFeeBps,
  bool disablePrimarySplit = false,
}) {
  final byAddress = <String, double>{};

  // 1. Marketplace fee.
  final mktFeePct =
      ((isSecondary ? secondaryFeeBps : primaryFeeBps).toDouble()) / 100.0;
  byAddress[kMallowFeeAddress] = mktFeePct;

  var remaining = 100.0 - mktFeePct;

  // 2. Royalty distribution.
  if (isSecondary || disablePrimarySplit || royaltyShares.isEmpty) {
    final royaltyPct = royaltyBps / 100.0;
    _populateRoyalties(byAddress, royaltyPct, royaltyShares);
    remaining -= royaltyPct;
    byAddress[seller] = (byAddress[seller] ?? 0) + remaining;
  } else {
    // Primary market with splits enabled: ALL remaining proceeds (after
    // the marketplace fee) go to creators by their share. The seller may
    // also be one of the creators — addressed via the byAddress map.
    _populateRoyalties(byAddress, remaining, royaltyShares);
  }

  // 3. Sort descending and convert percentages to raw amounts.
  final entries = byAddress.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  return entries
      .map((e) {
        final amount = priceRaw <= 0 ? 0 : (priceRaw * e.value / 100.0).round();
        return ProceedsSplit(
          label: _labelFor(address: e.key, seller: seller),
          address: e.key,
          proceedsPct: e.value,
          amountRaw: amount,
        );
      })
      .toList(growable: false);
}

void _populateRoyalties(
  Map<String, double> byAddress,
  double totalPct,
  List<ArtworkRoyaltySplit> creators,
) {
  for (final c in creators) {
    final share = (c.sharePercent / 100.0) * totalPct;
    byAddress[c.address] = (byAddress[c.address] ?? 0) + share;
  }
}

ProceedsLabel _labelFor({required String address, required String seller}) {
  if (address == kMallowFeeAddress) return ProceedsLabel.mallow;
  if (address == seller) return ProceedsLabel.you;
  return ProceedsLabel.creator;
}
