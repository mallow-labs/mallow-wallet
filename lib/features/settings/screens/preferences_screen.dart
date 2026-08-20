import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/priority_fee_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/nsfw_setting.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_toggle.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../widgets/settings_menu_item.dart';
import '../widgets/settings_page_scaffold.dart';

/// Preferences hub screen.
///
/// Shows the Preferred Explorer, App Theme and Priority Fee menu rows, which
/// navigate to their own sub-screens, and the NSFW blur toggle. The Display
/// Language and Currency rows are hidden for now.
class PreferencesScreen extends StatelessWidget {
  const PreferencesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Preferences',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: ListView(
          padding: const EdgeInsets.only(top: 20),
          children: [
            SettingsMenuItem(
              iconAsset: 'assets/icons/app_window.svg',
              label: 'Preferred Explorer',
              onTap: () => context.push(AppRoutes.preferredExplorer),
            ),
            const SizedBox(height: 8),
            SettingsMenuItem(
              iconAsset: 'assets/icons/app_theme.svg',
              label: 'App Theme',
              onTap: () => context.push(AppRoutes.appTheme),
            ),
            const SizedBox(height: 8),
            // Rebuilds from the service's notifier rather than reading it once:
            // the value is edited on a pushed sub-screen, so a plain read would
            // show the pre-edit selection when that screen pops back.
            ValueListenableBuilder<int?>(
              valueListenable: sl<PriorityFeeService>().selection,
              builder: (context, lamports, _) => SettingsMenuItem(
                iconAsset: 'assets/icons/solana_padded.svg',
                label: 'Priority Fee',
                trailingValue: priorityFeeLabel(lamports),
                onTap: () => context.push(AppRoutes.priorityFee),
              ),
            ),
            const SizedBox(height: 8),
            const _NsfwBlurRow(),
          ],
        ),
      ),
    );
  }
}

/// "NSFW blur" toggle (webapp user-menu parity): ON = NSFW artwork stays
/// blurred, i.e. the inverse of the stored show-NSFW flag. Rebuilds from
/// [PreferencesService.showNsfwNotifier] so it stays in sync when the
/// setting is changed elsewhere (e.g. the first-reveal warning sheet).
class _NsfwBlurRow extends StatelessWidget {
  const _NsfwBlurRow();

  Future<void> _setBlur(BuildContext context, bool blurOn) async {
    final error = await applyShowNsfwSetting(!blurOn);
    if (error != null && context.mounted) {
      AppSnackBar.show(context, error, type: AppSnackBarType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: sl<PreferencesService>().showNsfwNotifier,
      builder: (context, showNsfw, _) {
        final blurOn = !showNsfw;
        return TapTargetExpander(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _setBlur(context, !blurOn),
            child: SizedBox(
              height: 36,
              child: Row(
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: MallowSvgIcon(
                      'assets/icons/eye.svg',
                      width: 24,
                      height: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('NSFW blur', style: MallowTheme.uiBody),
                  ),
                  MallowToggle(
                    value: blurOn,
                    onChanged: (next) => _setBlur(context, next),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
