import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/push_notification_service.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';

/// Asks whether to turn push notifications on, as the last screen of the
/// first run.
///
/// The OS permission dialog can only be shown once per install, and the only
/// thing that spent it used to be the first visit to the Notifications screen
/// — reachable only through the menu drawer, so most users never met the
/// question at all. Asking in-app first keeps that one shot for a user who
/// has said yes.
///
/// Onboarding is already recorded as complete when this mounts (the PIN is
/// stored, `onOnboardingCompleted` has run), so both buttons just leave for
/// home and nothing here can strand a half-set-up wallet. That is also why
/// the route is excluded from `isOnboarding` in the router redirect.
class PushSetupScreen extends StatefulWidget {
  const PushSetupScreen({super.key});

  @override
  State<PushSetupScreen> createState() => _PushSetupScreenState();
}

class _PushSetupScreenState extends State<PushSetupScreen> {
  bool _isRequesting = false;

  Future<void> _enablePush() async {
    if (_isRequesting) return;
    setState(() => _isRequesting = true);
    try {
      // A refusal here answers the question this screen just asked — it is not
      // a permission stuck off — so no "open Settings" recovery sheet. Settings
      // and the Notifications banner still offer that route later.
      await enablePushFromUserAction(context, offerSettingsOnDenial: false);
    } catch (e) {
      // Firebase can be absent (a device where init failed, a hermetic test
      // build). Onboarding must not dead-end on an optional extra.
      debugPrint('[PushSetup] Enable failed: $e');
    }
    if (mounted) context.go(AppRoutes.home);
  }

  void _skip() => context.go(AppRoutes.home);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              const SizedBox(height: 8),
              SizedBox(
                height: 40,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Turn on notifications',
                    style: MallowTheme.editorialSection,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Divider(color: context.mallowColors.dividerLight),
              const Spacer(),
              MallowSvgIcon(
                'assets/icons/bell.svg',
                width: 92,
                height: 92,
                color: context.mallowColors.textPrimary,
              ),
              const SizedBox(height: 24),
              Text('Know the moment it happens', style: MallowTheme.uiBody),
              const SizedBox(height: 8),
              Text(
                'Bids, offers, sales, and drops from the artists you follow.',
                textAlign: TextAlign.center,
                style: MallowTheme.uiMeta.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
              const Spacer(),
              MallowButton(
                label: 'Turn on notifications',
                onPressed: _enablePush,
                isLoading: _isRequesting,
                isFullWidth: true,
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _isRequesting ? null : _skip,
                style: TextButton.styleFrom(
                  minimumSize: const Size(40, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Not now',
                  style: MallowTheme.uiIdentity.copyWith(
                    color: context.mallowColors.accent,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'You can change this anytime in settings',
                style: MallowTheme.uiCaption.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
