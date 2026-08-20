import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_checkbox.dart';
import '../widgets/settings_page_scaffold.dart';

/// "Before you proceed" warning shown before revealing a raw private key.
///
/// Receives the private key via route [extra] as a `String`. On "Continue" it
/// replaces itself with the key-reveal screen so backing out of the reveal
/// skips this screen entirely.
class PrivateKeyWarningScreen extends StatefulWidget {
  const PrivateKeyWarningScreen({required this.privateKey, super.key});

  final String privateKey;

  @override
  State<PrivateKeyWarningScreen> createState() =>
      _PrivateKeyWarningScreenState();
}

class _PrivateKeyWarningScreenState extends State<PrivateKeyWarningScreen> {
  bool _understood = false;

  void _onContinue() {
    if (!_understood) return;
    context.pushReplacement(
      AppRoutes.privateKeyReveal,
      extra: widget.privateKey,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Your private key',
      onBack: () {
        if (context.canPop()) context.pop();
      },
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
            ..._kWarnings.map(
              (w) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    SvgPicture.asset(
                      w.svgAsset,
                      width: 48,
                      height: 48,
                      colorFilter: ColorFilter.mode(
                        context.mallowColors.error,
                        BlendMode.srcIn,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        w.text,
                        style: MallowTheme.editorialQuote.copyWith(
                          color: context.mallowColors.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Divider(color: context.mallowColors.dividerLight),
            const SizedBox(height: 20),
            Text(
              'mallow will never ask you for your private key',
              textAlign: TextAlign.center,
              style: MallowTheme.uiMeta.copyWith(
                color: context.mallowColors.textPrimary,
              ),
            ),
            const Spacer(),
            MallowCheckbox(
              value: _understood,
              onChanged: (v) => setState(() => _understood = v),
              label: 'I understand the dangers of sharing my private key',
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _understood ? _onContinue : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 48,
                decoration: BoxDecoration(
                  color: _understood
                      ? context.mallowColors.error
                      : context.mallowColors.error.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusCircular,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Continue',
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

class _Warning {
  const _Warning({required this.svgAsset, required this.text});
  final String svgAsset;
  final String text;
}

const _kWarnings = [
  _Warning(
    svgAsset: 'assets/icons/invisible_lg.svg',
    text:
        'Never share your private key with anyone. No app, platform or person',
  ),
  _Warning(
    svgAsset: 'assets/icons/shield.svg',
    text:
        'If someone is asking you for your private key, they are attempting to scam you',
  ),
  _Warning(
    svgAsset: 'assets/icons/incognito.svg',
    text: 'Ensure no-one can see your screen',
  ),
  _Warning(
    svgAsset: 'assets/icons/padlock.svg',
    text:
        'Anyone with your private key has full control of this wallet and can steal all its assets',
  ),
];
