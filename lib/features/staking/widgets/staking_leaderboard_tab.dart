import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../core/router/app_router.dart';
import '../../../core/utils/address_format.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/tappable.dart';
import '../staking_format.dart';
import 'staking_stat_card.dart';

/// Leaderboard tab: estimated-prize + SP/day cards, the user's own pinned row,
/// then the ranked list. Matches the Figma spec.
class StakingLeaderboardTab extends StatelessWidget {
  const StakingLeaderboardTab({
    required this.data,
    required this.myAddress,
    super.key,
  });

  final StakingDataResponse data;
  final String? myAddress;

  StakingLeaderboardEntry? get _myEntry {
    final addr = myAddress;
    if (addr == null) return null;
    for (final e in data.leaderboard) {
      if (e.address == addr) return e;
    }
    return null;
  }

  double get _estimatedPrize {
    final mine = _myEntry;
    if (mine == null || data.totalSeasonPoints <= 0) return 0;
    return (mine.points /
            data.totalSeasonPoints *
            data.currentSeason.rewardPool)
        .floorToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final mine = _myEntry;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: StakingStatCard(
                label: 'Estimated SMORES prize',
                value: '${StakingFormat.withCommas(_estimatedPrize)} SMORES',
              ),
            ),
            const SizedBox(width: MallowTheme.spacing12),
            Expanded(
              child: StakingStatCard(
                label: 'Staking points / day',
                value: '${StakingFormat.sp(data.userData.spPerDay)} SP',
              ),
            ),
          ],
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        Expanded(
          child: ListView(
            padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
            children: [
              if (mine != null) ...[
                _LeaderboardRow(entry: mine, isYou: true),
                const SizedBox(height: MallowTheme.spacingSm),
                Divider(height: 1, color: context.mallowColors.dividerLight),
                const SizedBox(height: MallowTheme.spacingSm),
              ],
              // Skip the user's own entry here — it is already pinned above with
              // the "You" badge, otherwise it renders twice.
              for (final entry in data.leaderboard)
                if (mine == null || entry.address != mine.address)
                  Padding(
                    padding: const EdgeInsets.only(
                      bottom: MallowTheme.spacingSm,
                    ),
                    child: _LeaderboardRow(entry: entry),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LeaderboardRow extends StatelessWidget {
  const _LeaderboardRow({required this.entry, this.isYou = false});

  final StakingLeaderboardEntry entry;
  final bool isYou;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final name = entry.username?.isNotEmpty == true
        ? entry.username!
        : truncateAddress(entry.address);
    return Tappable(
      onTap: () => context.goToProfile(entry.address),
      child: Row(
        children: [
          // Fixed width so single- and triple-digit ranks align and the badge
          // never reflows as ranks grow.
          _Chip(text: '${entry.rank}', minWidth: 40),
          const SizedBox(width: MallowTheme.spacingSm),
          _Avatar(url: entry.imageUrl, address: entry.address),
          const SizedBox(width: MallowTheme.spacingSm),
          // Leading group eats the slack so the trailing SOL/SP values are
          // flush-right across every row.
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                if (isYou) ...[
                  const SizedBox(width: MallowTheme.spacingSm),
                  const _Chip(text: 'You'),
                ],
              ],
            ),
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          Text(
            '${StakingFormat.sol(entry.stakedAmountSol)} SOL',
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          _Chip(text: '${StakingFormat.sp(entry.points)} SP'),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.minWidth});

  final String text;

  /// When set, the chip reserves at least this width and centres its text —
  /// used for rank badges so they accommodate up to three digits.
  final double? minWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      constraints: minWidth == null
          ? null
          : BoxConstraints(minWidth: minWidth!),
      alignment: minWidth == null ? null : Alignment.center,
      padding: const EdgeInsets.symmetric(
        horizontal: MallowTheme.spacingSm,
        vertical: MallowTheme.spacingXs,
      ),
      decoration: BoxDecoration(
        color: colors.dividerLight,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.address});

  final String? url;
  final String address;

  static const double _size = 24;

  @override
  Widget build(BuildContext context) {
    // No uploaded image: derive a deterministic identicon from the address.
    // AccountAvatar is already circular (ClipOval).
    if (url == null || url!.isEmpty) {
      return AccountAvatar(seed: address, size: _size);
    }
    return ClipOval(
      child: MallowNetworkImage(
        imageUrl: url!,
        logicalSize: _size,
        width: _size,
        height: _size,
        borderRadius: BorderRadius.circular(_size / 2),
        errorBuilder: (_) => AccountAvatar(seed: address, size: _size),
      ),
    );
  }
}
