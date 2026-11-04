import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/chooser_type_row.dart';
import '../../../shared/widgets/mallow_header.dart';

/// Opens hardware-wallet import from any entry point: the onboarding import
/// sheet, Add account and Import wallet.
void openHardwareWalletImport(BuildContext context) {
  context.push(AppRoutes.hardwareWalletImport);
}

/// Picks which hardware wallet to import from. Laid out like the other
/// "pick a type" choosers (mint type, sell type), one [ChooserTypeRow] per
/// device, with the device's own mark as the icon.
class HardwareWalletChooserScreen extends StatelessWidget {
  const HardwareWalletChooserScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Scaffold(
      backgroundColor: colors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          // Header sits above the scroll view so a pull past the top moves
          // only the content, never the nav bar.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const MallowHeader(title: 'Hardware wallet'),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: IntrinsicHeight(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: MallowTheme.spacing20),
                              Text(
                                'Choose your device',
                                style: MallowTheme.uiLabel.copyWith(
                                  color: colors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: MallowTheme.spacing20),
                              ChooserTypeRow(
                                svgAsset: 'assets/icons/brand_ledger_mark.svg',
                                title: 'Ledger',
                                subtitle: 'Connect over Bluetooth',
                                onTap: () => context.push(AppRoutes.ledgerScan),
                              ),
                              const SizedBox(height: MallowTheme.spacing20),
                              ChooserTypeRow(
                                svgAsset: 'assets/icons/brand_keystone.svg',
                                title: 'Keystone',
                                subtitle: 'Scan QR codes, fully offline',
                                onTap: () =>
                                    context.push(AppRoutes.keystoneImport),
                              ),
                              const Spacer(),
                              Text(
                                'Please note:\nYour keys stay on the device. '
                                'mallow only reads your public addresses and '
                                'asks the device to approve each signature.',
                                style: MallowTheme.uiCaption.copyWith(
                                  color: colors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: MallowTheme.spacingXl),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
