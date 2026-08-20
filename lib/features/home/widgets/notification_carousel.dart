import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/dismissible_banner.dart';

const _kDismissedNotificationsKey = 'home_dismissed_notifications';

const _kNotifications = [
  _NotificationDef(
    id: 'add_eth_tezos_wallets',
    message:
        'Add your Ethereum and Tezos wallets to see your entire portfolio!',
    iconAsset: 'assets/icons/bell.svg',
  ),
];

class _NotificationDef {
  const _NotificationDef({
    required this.id,
    required this.message,
    required this.iconAsset,
  });

  final String id;
  final String message;
  final String iconAsset;
}

class HomeNotificationCarousel extends StatefulWidget {
  const HomeNotificationCarousel({super.key});

  @override
  State<HomeNotificationCarousel> createState() =>
      _HomeNotificationCarouselState();
}

class _HomeNotificationCarouselState extends State<HomeNotificationCarousel> {
  Set<String> _dismissed = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadDismissed();
  }

  Future<void> _loadDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_kDismissedNotificationsKey) ?? [];
    if (mounted) {
      setState(() {
        _dismissed = ids.toSet();
        _loaded = true;
      });
    }
  }

  Future<void> _dismiss(String id) async {
    setState(() => _dismissed = {..._dismissed, id});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kDismissedNotificationsKey, _dismissed.toList());
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();

    final visible = _kNotifications
        .where((n) => !_dismissed.contains(n.id))
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(
        top: MallowTheme.spacing26,
        left: MallowTheme.spacing20,
        right: MallowTheme.spacing20,
      ),
      child: Column(
        children: visible
            .map(
              (n) => DismissibleBanner(
                message: n.message,
                iconAsset: n.iconAsset,
                onDismiss: () => _dismiss(n.id),
              ),
            )
            .toList(),
      ),
    );
  }
}
