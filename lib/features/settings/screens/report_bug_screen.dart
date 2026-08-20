import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/mallow_textarea_field.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../widgets/settings_page_scaffold.dart';

/// In-app bug report screen.
///
/// Generates a unique report ID and provides a text field for
/// the user to describe the issue they are experiencing.
class ReportBugScreen extends StatefulWidget {
  const ReportBugScreen({super.key});

  @override
  State<ReportBugScreen> createState() => _ReportBugScreenState();
}

class _ReportBugScreenState extends State<ReportBugScreen> {
  late final String _reportId;
  late final TextEditingController _descriptionController;
  late final FocusNode _focusNode;
  // Single read, shared by the on-screen version stamp and the report payload
  // — so what the tester quotes is exactly what the report is attributed to.
  late final Future<PackageInfo> _packageInfo;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _reportId = _generateReportId();
    _descriptionController = TextEditingController();
    _focusNode = FocusNode();
    _packageInfo = PackageInfo.fromPlatform();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  static String _generateReportId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = Random.secure();
    final code = List.generate(
      6,
      (_) => chars[rng.nextInt(chars.length)],
    ).join();
    final date = DateFormat('yyyyMMdd').format(DateTime.now());
    return 'RPT-$code-$date';
  }

  void _copyReportId() {
    HapticFeedback.lightImpact();
    Clipboard.setData(ClipboardData(text: _reportId));
    AppSnackBar.show(context, 'Report ID copied');
  }

  Future<void> _submit() async {
    final message = _descriptionController.text.trim();
    if (message.isEmpty) return;

    setState(() => _submitting = true);

    try {
      final api = sl<MallowApiClient>();
      final packageInfo = await _packageInfo;
      final deviceInfo = DeviceInfoPlugin();
      final device = Platform.isIOS
          ? (await deviceInfo.iosInfo).utsname.machine
          : (await deviceInfo.androidInfo).model;

      await api.submitBugReport({
        'reportId': _reportId,
        'message': message,
        'platform': Platform.isIOS ? 'iOS' : 'Android',
        'os': Platform.operatingSystemVersion,
        'appVersion': '${packageInfo.version}+${packageInfo.buildNumber}',
        'device': device,
      });

      if (!mounted) return;
      AppSnackBar.show(context, 'Bug report submitted. Thank you!');
      context.pop();
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.show(context, 'Failed to submit report. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return SettingsPageScaffold(
      title: 'Report a bug',
      showDivider: false,
      child: GestureDetector(
        onTap: () => _focusNode.unfocus(),
        behavior: HitTestBehavior.translucent,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 20,
                ),
                children: [
                  // Bug icon
                  Center(
                    child: SvgPicture.asset(
                      'assets/icons/bug_2.svg',
                      width: 72,
                      height: 72,
                    ),
                  ),
                  const SizedBox(height: 20),

                  const MallowSectionLabel(label: 'Report ID'),
                  const SizedBox(height: MallowTheme.spacingMd),

                  // Report ID value + copy button
                  TapTargetExpander(
                    child: GestureDetector(
                      onTap: _copyReportId,
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        children: [
                          Text(
                            _reportId,
                            style: MallowTheme.uiBody.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          SvgPicture.asset(
                            'assets/icons/copy.svg',
                            width: 16,
                            height: 16,
                            colorFilter: ColorFilter.mode(
                              colors.textPrimary,
                              BlendMode.srcIn,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),

                  // Version stamp: the report is only actionable if we know
                  // which build it came from, and the tester can quote it.
                  FutureBuilder<PackageInfo>(
                    future: _packageInfo,
                    builder: (context, snapshot) {
                      final info = snapshot.data;
                      return Text(
                        info == null
                            ? ''
                            : 'Version ${info.version} (${info.buildNumber})',
                        style: MallowTheme.uiCaption.copyWith(
                          color: colors.textSecondary,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),

                  const MallowSectionLabel(
                    label:
                        'Please give a detailed description of '
                        'the issue you are experiencing:',
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  MallowTextareaField(
                    controller: _descriptionController,
                    focusNode: _focusNode,
                    textCapitalization: TextCapitalization.sentences,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: MallowButton(
                label: _submitting ? 'Reporting...' : 'Report',
                onPressed: _submitting ? null : _submit,
                isFullWidth: true,
                isLoading: _submitting,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
