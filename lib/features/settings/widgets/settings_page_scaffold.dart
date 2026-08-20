import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_header.dart';

/// Shared scaffold for all settings sub-screens.
///
/// Provides a back arrow, italic title, horizontal divider, and content area.
class SettingsPageScaffold extends StatelessWidget {
  const SettingsPageScaffold({
    required this.title,
    required this.child,
    this.onBack,
    this.actions,
    this.showDivider = true,
    super.key,
  });

  final String title;
  final Widget child;
  final VoidCallback? onBack;
  final List<Widget>? actions;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: MallowHeader(
                title: title,
                onBack: onBack,
                actions: actions,
              ),
            ),
            const SizedBox(height: 28),
            if (showDivider)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: context.mallowColors.dividerLight,
                ),
              ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
