import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/services/preferences_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../widgets/settings_page_scaffold.dart';
import '../../../shared/widgets/tap_target_expander.dart';

class _Currency {
  const _Currency({
    required this.code,
    required this.symbol,
    required this.name,
  });
  final String code;
  final String symbol;
  final String name;
}

/// Full currency list from Figma design.
const _currencies = [
  _Currency(
    code: 'AED',
    symbol: 'د.إ',
    name: 'AED - United Arab Emirates Dirham',
  ),
  _Currency(code: 'ARS', symbol: 'AR\$', name: 'ARS - Argentine Peso'),
  _Currency(code: 'BGN', symbol: 'лв', name: 'BGN - Bulgarian Lev'),
  _Currency(code: 'BRL', symbol: 'R\$', name: 'BRL - Brazilian Real'),
  _Currency(code: 'CAD', symbol: 'CA\$', name: 'CAD - Canadian Dollar'),
  _Currency(code: 'CHF', symbol: 'CHF', name: 'CHF - Swiss Franc'),
  _Currency(code: 'CNY', symbol: '¥', name: 'CNY - Chinese Renminbi Yuan'),
  _Currency(code: 'COP', symbol: '\$', name: 'COP - Colombian Peso'),
  _Currency(code: 'CZK', symbol: 'Kč', name: 'CZK - Czech Koruna'),
  _Currency(code: 'DKK', symbol: 'kr', name: 'DKK - Danish Krone'),
  _Currency(code: 'DOP', symbol: 'RD\$', name: 'DOP - Dominican Peso'),
  _Currency(code: 'DZD', symbol: 'د.ج', name: 'DZD - Algerian Dinar'),
  _Currency(code: 'EGP', symbol: 'E£', name: 'EGP - Egyptian Pound'),
  _Currency(code: 'ETB', symbol: 'Br', name: 'ETB - Ethiopian Birr'),
  _Currency(code: 'EUR', symbol: '€', name: 'EUR - Euro'),
  _Currency(code: 'GBP', symbol: '£', name: 'GBP - British Pound'),
  _Currency(code: 'HKD', symbol: 'HK\$', name: 'HKD - Hong Kong Dollar'),
  _Currency(code: 'HUF', symbol: 'Ft', name: 'HUF - Hungarian Forint'),
  _Currency(code: 'IDR', symbol: 'Rp', name: 'IDR - Indonesian Rupiah'),
  _Currency(code: 'ILS', symbol: '₪', name: 'ILS - Israeli New Sheqel'),
  _Currency(code: 'INR', symbol: '₹', name: 'INR - Indian Rupee'),
  _Currency(code: 'JPY', symbol: '¥', name: 'JPY - Japanese Yen'),
  _Currency(code: 'KRW', symbol: '₩', name: 'KRW - South Korean Won'),
  _Currency(code: 'MXN', symbol: 'MX\$', name: 'MXN - Mexican Peso'),
  _Currency(code: 'MYR', symbol: 'RM', name: 'MYR - Malaysian Ringgit'),
  _Currency(code: 'NGN', symbol: '₦', name: 'NGN - Nigerian Naira'),
  _Currency(code: 'NOK', symbol: 'kr', name: 'NOK - Norwegian Krone'),
  _Currency(code: 'NZD', symbol: 'NZ\$', name: 'NZD - New Zealand Dollar'),
  _Currency(code: 'PHP', symbol: '₱', name: 'PHP - Philippine Peso'),
  _Currency(code: 'PKR', symbol: '₨', name: 'PKR - Pakistani Rupee'),
  _Currency(code: 'PLN', symbol: 'zł', name: 'PLN - Polish Zloty'),
  _Currency(code: 'RON', symbol: 'lei', name: 'RON - Romanian Leu'),
  _Currency(code: 'RUB', symbol: '₽', name: 'RUB - Russian Ruble'),
  _Currency(code: 'SAR', symbol: '﷼', name: 'SAR - Saudi Riyal'),
  _Currency(code: 'SEK', symbol: 'kr', name: 'SEK - Swedish Krona'),
  _Currency(code: 'SGD', symbol: 'S\$', name: 'SGD - Singapore Dollar'),
  _Currency(code: 'THB', symbol: '฿', name: 'THB - Thai Baht'),
  _Currency(code: 'TRY', symbol: '₺', name: 'TRY - Turkish Lira'),
  _Currency(code: 'TWD', symbol: 'NT\$', name: 'TWD - New Taiwan Dollar'),
  _Currency(code: 'UAH', symbol: '₴', name: 'UAH - Ukrainian Hryvnia'),
  _Currency(code: 'USD', symbol: '\$', name: 'USD - US Dollar'),
  _Currency(code: 'VND', symbol: '₫', name: 'VND - Vietnamese Dong'),
  _Currency(code: 'ZAR', symbol: 'R', name: 'ZAR - South African Rand'),
];

/// Currency picker screen.
///
/// Shows a scrollable list of currencies. Left column shows the symbol in
/// secondary text; right column shows the full name. Selection is persisted
/// via [PreferencesService].
class CurrencyScreen extends StatefulWidget {
  const CurrencyScreen({super.key});

  @override
  State<CurrencyScreen> createState() => _CurrencyScreenState();
}

class _CurrencyScreenState extends State<CurrencyScreen> {
  late String _selected;

  @override
  void initState() {
    super.initState();
    _selected = sl<PreferencesService>().currency;
  }

  Future<void> _select(String code) async {
    await sl<PreferencesService>().setCurrency(code);
    unawaited(
      sl<AnalyticsService>().track(
        AnalyticsEvent.currencyChanged,
        properties: {AnalyticsProp.currency: code},
      ),
    );
    if (!mounted) return;
    setState(() => _selected = code);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Currency',
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        itemCount: _currencies.length,
        itemBuilder: (context, index) {
          final currency = _currencies[index];
          final isSelected = currency.code == _selected;
          return _CurrencyRow(
            currency: currency,
            isSelected: isSelected,
            onTap: () => _select(currency.code),
          );
        },
      ),
    );
  }
}

class _CurrencyRow extends StatelessWidget {
  const _CurrencyRow({
    required this.currency,
    required this.isSelected,
    required this.onTap,
  });

  final _Currency currency;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              // Symbol column (fixed width, secondary colour)
              SizedBox(
                width: 24,
                child: Text(
                  currency.symbol,
                  style: MallowTheme.uiBody.copyWith(
                    color: isSelected
                        ? context.mallowColors.accent
                        : context.mallowColors.textSecondary,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.clip,
                  maxLines: 1,
                ),
              ),
              const SizedBox(width: 12),
              // Full name
              Expanded(
                child: Text(
                  currency.name,
                  style: MallowTheme.uiBody.copyWith(
                    color: isSelected
                        ? context.mallowColors.accent
                        : context.mallowColors.textPrimary,
                  ),
                ),
              ),
              if (isSelected)
                MallowSvgIcon(
                  'assets/icons/checkmark.svg',
                  width: 16,
                  height: 16,
                  color: context.mallowColors.accent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
