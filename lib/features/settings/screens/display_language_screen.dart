import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/services/preferences_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../widgets/settings_page_scaffold.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// A language option shown in the list.
class _Language {
  const _Language({
    required this.code,
    required this.iconAsset,
    required this.label,
  });
  final String code;
  final String iconAsset;
  final String label;
}

const _languages = [
  _Language(
    code: 'ar',
    iconAsset: 'assets/icons/lang_ar.svg',
    label: 'Arabic (العربية)',
  ),
  _Language(
    code: 'zh_CN',
    iconAsset: 'assets/icons/lang_zh.svg',
    label: 'Chinese Simplified (中文简体)',
  ),
  _Language(
    code: 'en_GB',
    iconAsset: 'assets/icons/lang_gb.svg',
    label: 'English (UK)',
  ),
  _Language(
    code: 'en_US',
    iconAsset: 'assets/icons/lang_us.svg',
    label: 'English (US)',
  ),
  _Language(
    code: 'fr',
    iconAsset: 'assets/icons/lang_fr.svg',
    label: 'French (Français)',
  ),
  _Language(
    code: 'de',
    iconAsset: 'assets/icons/lang_de.svg',
    label: 'German (Deutsch)',
  ),
  _Language(
    code: 'ja',
    iconAsset: 'assets/icons/lang_jp.svg',
    label: 'Japanese (日本語)',
  ),
  _Language(
    code: 'ko',
    iconAsset: 'assets/icons/lang_kr.svg',
    label: 'Korean (한국어)',
  ),
  _Language(
    code: 'pt',
    iconAsset: 'assets/icons/lang_pt.svg',
    label: 'Portuguese (Português)',
  ),
  _Language(
    code: 'ru',
    iconAsset: 'assets/icons/lang_ru.svg',
    label: 'Russian (Русский)',
  ),
  _Language(
    code: 'es',
    iconAsset: 'assets/icons/lang_es.svg',
    label: 'Spanish (Español)',
  ),
  _Language(
    code: 'th',
    iconAsset: 'assets/icons/lang_th.svg',
    label: 'Thai (ภาษาไทย)',
  ),
];

/// Display Language picker screen.
///
/// Shows a scrollable list of supported languages. Tapping one saves the
/// selection via [PreferencesService] and checks it with a trailing checkmark.
class DisplayLanguageScreen extends StatefulWidget {
  const DisplayLanguageScreen({super.key});

  @override
  State<DisplayLanguageScreen> createState() => _DisplayLanguageScreenState();
}

class _DisplayLanguageScreenState extends State<DisplayLanguageScreen> {
  late String _selected;

  @override
  void initState() {
    super.initState();
    _selected = sl<PreferencesService>().language;
  }

  Future<void> _select(String code) async {
    await sl<PreferencesService>().setLanguage(code);
    if (!mounted) return;
    setState(() => _selected = code);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Display Language',
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        itemCount: _languages.length,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final lang = _languages[index];
          final isSelected = lang.code == _selected;
          return _LanguageRow(
            language: lang,
            isSelected: isSelected,
            onTap: () => _select(lang.code),
          );
        },
      ),
    );
  }
}

class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.language,
    required this.isSelected,
    required this.onTap,
  });

  final _Language language;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              SvgPicture.asset(language.iconAsset, width: 24, height: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  language.label,
                  style: MallowTheme.uiBody.copyWith(
                    color: isSelected
                        ? context.mallowColors.accent
                        : context.mallowColors.textPrimary,
                  ),
                ),
              ),
              if (isSelected) _Checkmark(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Checkmark extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MallowSvgIcon(
      'assets/icons/checkmark.svg',
      width: 16,
      height: 16,
      color: context.mallowColors.accent,
    );
  }
}
