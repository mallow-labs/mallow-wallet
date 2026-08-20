import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../shared/widgets/loading_indicator.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_checkbox.dart';
import '../widgets/settings_page_scaffold.dart';

/// Full-screen "Reset app" confirmation screen.
///
/// Mirrors the "Before you proceed" pattern from recovery phrase, with
/// a checkbox gate and destructive action button.
class ResetAppScreen extends StatefulWidget {
  const ResetAppScreen({super.key});

  @override
  State<ResetAppScreen> createState() => _ResetAppScreenState();
}

class _ResetAppScreenState extends State<ResetAppScreen> {
  bool _confirmed = false;
  bool _resetting = false;

  Future<void> _resetApp() async {
    if (_resetting) return;
    setState(() => _resetting = true);

    try {
      await sl<WalletManager>().deleteWallet();
      if (!mounted) return;
      await sl<AuthStateNotifier>().onLogout();
    } catch (_) {
      if (!mounted) return;
      setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Reset app',
      showDivider: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          children: [
            const SizedBox(height: 20),
            SvgPicture.asset(
              'assets/icons/shield_alert.svg',
              width: 72,
              height: 72,
              colorFilter: ColorFilter.mode(
                context.mallowColors.error,
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Before you proceed',
                style: MallowTheme.editorialSection,
              ),
            ),
            const SizedBox(height: 20),
            Divider(color: context.mallowColors.dividerLight),
            const SizedBox(height: 12),
            Text(
              'Resetting your app will remove all wallets',
              textAlign: TextAlign.center,
              style: MallowTheme.editorialQuote.copyWith(
                color: context.mallowColors.error,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Please ensure you have saved your recovery phrase, '
              'you will not be able to access it again',
              textAlign: TextAlign.center,
              style: MallowTheme.editorialQuote.copyWith(
                color: context.mallowColors.error,
              ),
            ),
            const SizedBox(height: 12),
            Divider(color: context.mallowColors.dividerLight),
            const Spacer(),
            MallowCheckbox(
              value: _confirmed,
              onChanged: (v) => setState(() => _confirmed = v),
              label: 'I have my recovery phrase saved',
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _confirmed && !_resetting ? _resetApp : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 48,
                decoration: BoxDecoration(
                  color: _confirmed
                      ? context.mallowColors.error
                      : context.mallowColors.error.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusCircular,
                  ),
                ),
                alignment: Alignment.center,
                child: _resetting
                    ? MallowLoader(
                        size: 20,
                        color: context.mallowColors.textOnAccent,
                      )
                    : Text(
                        'Reset app',
                        style: MallowTheme.uiBody.copyWith(
                          color: context.mallowColors.textOnAccent,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
