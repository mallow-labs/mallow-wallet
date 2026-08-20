/// Snapshot of the current Solana epoch's progress, computed from
/// `getEpochInfo`. Drives the unstake tab's epoch-progress and claim-countdown
/// cards: native stake deactivates at the epoch boundary, so the time left in
/// the current epoch is our estimate of when deactivating funds become
/// claimable.
class EpochProgress {
  const EpochProgress({
    required this.epoch,
    required this.slotIndex,
    required this.slotsInEpoch,
  });

  final int epoch;
  final int slotIndex;
  final int slotsInEpoch;

  /// Solana's target slot time. Epochs are ~432k slots ≈ 2 days.
  static const Duration _slotDuration = Duration(milliseconds: 400);

  /// Progress through the current epoch, 0..1.
  double get fraction {
    if (slotsInEpoch <= 0) return 0;
    return (slotIndex / slotsInEpoch).clamp(0.0, 1.0);
  }

  /// Estimated time until the epoch ends.
  Duration get timeRemaining {
    final slotsLeft = slotsInEpoch - slotIndex;
    if (slotsLeft <= 0) return Duration.zero;
    return _slotDuration * slotsLeft;
  }
}
