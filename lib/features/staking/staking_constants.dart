import '../portfolio/models/token_balance.dart';

/// On-chain constants for the staking feature, mirrored from the webapp's
/// shared token constants.
class StakingConstants {
  const StakingConstants._();

  /// mallow's validator vote account — the delegation target for native stake.
  static const validatorVoteAddress =
      'mALLoAbdQrgsnm7kWJyPrhcQcmxfT73t8DaqEkpZNd6';

  /// Receives a 0-lamport transfer appended to every staking tx (native
  /// stake/unstake and liquid swaps) so the backend can attribute the action —
  /// exact parity with the webapp's fee-account marker.
  static const feeAccountAddress =
      'MFHHByMGfk84s3GZ8dZHaQQ3gbpQYc2NnQYPg2tRCSx';

  /// Liquid-staking token mint.
  static const mallowSolMint = 'MLLWWq9TLHK3oQznWqwPyqD7kH4LXTHSKXK4yLz7LjD';

  /// Season-reward token mint.
  static const smoresMint = 'smoEhMZMweWBnpd1QoU4ZjuVNBxMFchqy4NRMBbtW7V';

  /// Raw SMORES units per whole token — it has 6 decimals
  /// (`core/data/mallow_tokens.dart`). Season rewards are counted and claimed
  /// in raw units, and displayed as whole tokens.
  static const int smoresUnitsPerToken = 1000000;

  /// Native SOL mint (wrapped-SOL address).
  static const solMint = TokenBalance.solMint;

  /// Stake config sysvar-adjacent account required by `delegateStake`.
  static const stakeConfigAddress =
      'StakeConfig11111111111111111111111111111111';

  /// SOL the Max button leaves untouched (rent + fees headroom), matching the
  /// webapp's `balance - 4_000_000` lamports.
  static const int maxReserveLamports = 4000000;

  /// Minimum the user must request to create a native stake (1 SOL). Below this
  /// the form warns and blocks submit.
  static const int minNativeStakeLamports = 1000000000;

  /// Floor for the lamports a native stake tx actually sends (1.0023 SOL). The
  /// extra ~0.0023 SOL funds the new stake account's rent so the delegated
  /// amount clears the 1 SOL minimum. Larger requests are sent as typed.
  static const int minNativeStakeSendLamports = 1002300000;
}
