// Hand-rolled (not swagger/freezed) for the same reason as prices.dart: the
// `GET /v1/staking` payload nests several plain objects (userData.nativeStake,
// currentSeason, leaderboard[].user) that swagger_dart_code_generator would
// emit as field-less classes, silently dropping data on fromJson. We mirror
// the webapp `StakingData` type (stakingData) and
// consume this model directly in the staking feature.

double _asDouble(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

int _asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

/// Response for `GET /v1/staking` (wrapped in `ApiResponse`).
class StakingDataResponse {
  const StakingDataResponse({
    required this.nativeApy,
    required this.liquidApy,
    required this.solPerMallowSol,
    required this.totalSolStakedLamports,
    required this.totalStakers,
    required this.totalSeasonPoints,
    required this.userData,
    required this.currentSeason,
    required this.leaderboard,
  });

  /// Native-staking APY as a fraction (e.g. 0.0574 → 5.74%).
  final double nativeApy;

  /// Liquid-staking APY as a fraction.
  final double liquidApy;

  /// Exchange rate: how many SOL one mallowSOL is worth.
  final double solPerMallowSol;

  /// Total SOL staked across the protocol, in **lamports** (string-encoded
  /// on the wire to avoid precision loss).
  final String totalSolStakedLamports;

  final int totalStakers;

  /// Sum of points across all stakers this season (denominator for the
  /// estimated-prize calculation).
  final double totalSeasonPoints;

  /// Signed-in user's staking position. Zero-filled when signed out.
  final StakingUserData userData;

  final StakingSeason currentSeason;

  final List<StakingLeaderboardEntry> leaderboard;

  factory StakingDataResponse.fromJson(Map<String, dynamic> json) {
    final user = json['userData'] as Map<String, dynamic>?;
    final season = json['currentSeason'] as Map<String, dynamic>?;
    final board = (json['leaderboard'] as List?) ?? const [];
    return StakingDataResponse(
      nativeApy: _asDouble(json['nativeApy']),
      liquidApy: _asDouble(json['liquidApy']),
      solPerMallowSol: _asDouble(json['solPerMallowSol']),
      totalSolStakedLamports: '${json['totalSolStaked'] ?? '0'}',
      totalStakers: _asInt(json['totalStakers']),
      totalSeasonPoints: _asDouble(json['totalSeasonPoints']),
      userData: StakingUserData.fromJson(user ?? const {}),
      currentSeason: StakingSeason.fromJson(season ?? const {}),
      leaderboard: board
          .whereType<Map<String, dynamic>>()
          .map(StakingLeaderboardEntry.fromJson)
          .toList(growable: false),
    );
  }
}

/// Per-user staking position (`StakingData.userData`).
class StakingUserData {
  const StakingUserData({
    required this.spPerDay,
    required this.nativeStake,
    required this.liquidStakeLamports,
  });

  /// Staking points accrued per day.
  final double spPerDay;

  final NativeStakeBreakdown nativeStake;

  /// Value of the user's mallowSOL holdings in SOL equivalent, in lamports.
  final int liquidStakeLamports;

  factory StakingUserData.fromJson(Map<String, dynamic> json) {
    final native = json['nativeStake'] as Map<String, dynamic>?;
    return StakingUserData(
      spPerDay: _asDouble(json['spPerDay']),
      nativeStake: NativeStakeBreakdown.fromJson(native ?? const {}),
      liquidStakeLamports: _asInt(json['liquidStake']),
    );
  }
}

/// Native stake amounts by lifecycle state, all in **lamports**.
class NativeStakeBreakdown {
  const NativeStakeBreakdown({
    required this.activeLamports,
    required this.inactiveLamports,
    required this.activatingLamports,
    required this.deactivatingLamports,
  });

  /// Currently earning rewards.
  final int activeLamports;

  /// Deactivated and ready to withdraw (claimable).
  final int inactiveLamports;

  /// Waiting to become active (next epoch).
  final int activatingLamports;

  /// Waiting to fully deactivate before it can be withdrawn.
  final int deactivatingLamports;

  factory NativeStakeBreakdown.fromJson(Map<String, dynamic> json) => NativeStakeBreakdown(
    activeLamports: _asInt(json['active']),
    inactiveLamports: _asInt(json['inactive']),
    activatingLamports: _asInt(json['activating']),
    deactivatingLamports: _asInt(json['deactivating']),
  );
}

/// Current season metadata (`StakingData.currentSeason`).
class StakingSeason {
  const StakingSeason({
    required this.season,
    required this.label,
    required this.endsAt,
    required this.rewardPool,
    required this.rewardsSentAt,
  });

  final int season;

  /// e.g. "Season 3".
  final String label;

  /// When the season ends.
  final DateTime? endsAt;

  /// Total SMORES in the prize pool.
  final double rewardPool;

  /// Null until rewards are distributed.
  final DateTime? rewardsSentAt;

  factory StakingSeason.fromJson(Map<String, dynamic> json) => StakingSeason(
    season: _asInt(json['season']),
    label: '${json['label'] ?? ''}',
    endsAt: DateTime.tryParse('${json['endsAt']}'),
    rewardPool: _asDouble(json['rewardPool']),
    rewardsSentAt: json['rewardsSentAt'] == null
        ? null
        : DateTime.tryParse('${json['rewardsSentAt']}'),
  );
}

/// A single leaderboard row (`StakingData.leaderboard[]`).
class StakingLeaderboardEntry {
  const StakingLeaderboardEntry({
    required this.address,
    required this.points,
    required this.stakedAmountSol,
    required this.rank,
    required this.username,
    required this.imageUrl,
  });

  final String address;

  /// Staking points (SP).
  final double points;

  /// Total staked, in **SOL** (already converted on the backend).
  final double stakedAmountSol;

  final int rank;

  /// Display name, if the user has one.
  final String? username;

  /// Avatar URL, if set.
  final String? imageUrl;

  factory StakingLeaderboardEntry.fromJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>?;
    return StakingLeaderboardEntry(
      address: '${json['address'] ?? ''}',
      points: _asDouble(json['points']),
      stakedAmountSol: _asDouble(json['stakedAmount']),
      rank: _asInt(json['rank']),
      username: user?['username'] as String?,
      imageUrl: user?['imageUrl'] as String?,
    );
  }
}

/// Result of `POST /v1/staking/getClaimTx` (wrapped in `ApiResponse`).
///
/// Hand-rolled for the same reason as the rest of this file: the spec types the
/// response body inline, and its `latestBlockhashAndContext` is a free-form
/// passthrough the app has no use for — the transaction executor fetches its
/// own blockhash. Only [tx] is consumed.
class StakingClaimTxResponse {
  const StakingClaimTxResponse({required this.tx});

  /// base64-encoded unsigned **v0** transaction that decompresses the caller's
  /// compressed SMORES into their associated token account.
  final String tx;

  factory StakingClaimTxResponse.fromJson(Map<String, dynamic> json) =>
      StakingClaimTxResponse(tx: '${json['tx'] ?? ''}');
}
