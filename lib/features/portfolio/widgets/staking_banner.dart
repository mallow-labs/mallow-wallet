import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/dismissible_banner.dart';
import '../../staking/widgets/staking_sheet.dart';

const _kDismissedStakingBannerKey = 'dismissed_staking_banner';

class StakingBanner extends StatefulWidget {
  const StakingBanner({super.key});

  @override
  State<StakingBanner> createState() => _StakingBannerState();
}

class _StakingBannerState extends State<StakingBanner> {
  bool _dismissed = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadDismissed();
  }

  Future<void> _loadDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool(_kDismissedStakingBannerKey) ?? false;
    if (mounted) {
      setState(() {
        _dismissed = dismissed;
        _loaded = true;
      });
    }
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDismissedStakingBannerKey, true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _dismissed) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: GestureDetector(
        onTap: () => showStakeSheet(context),
        behavior: HitTestBehavior.opaque,
        child: DismissibleBanner(
          message: "Stake your SOL and earn APY with mallow's validator!",
          iconAsset: 'assets/icons/diamond.svg',
          onDismiss: _dismiss,
        ),
      ),
    );
  }
}
