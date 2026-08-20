import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/system_status.dart';
import '../../core/config/system_status_service.dart';
import '../../di.dart';
import '../theme/mallow_theme.dart';
import 'mallow_svg_icon.dart';
import 'tap_target_expander.dart';

/// Human-readable duration of a maintenance window, rounded to hours the way
/// the webapp does — "2 hours", or "a short maintenance period" under 30
/// minutes. Users plan around hours, not minutes.
String maintenanceDurationText(MaintenanceWindow window) {
  final hours = (window.endsAt.difference(window.startsAt).inMinutes / 60)
      .round();
  if (hours == 0) return 'a short maintenance period';
  return '$hours hour${hours == 1 ? '' : 's'}';
}

/// Banner copy for a scheduled window, in the user's local time. The webapp
/// renders the same sentence — a tester comparing the two clients during an
/// incident should read the same thing.
String maintenanceBannerText(MaintenanceWindow window) {
  final day = DateFormat('EEE, MMM d').format(window.startsAt);
  final time = DateFormat('h:mm a').format(window.startsAt);
  return 'mallow will be down for maintenance on $day at $time for '
      '${maintenanceDurationText(window)}.';
}

/// App-wide operator announcement strip: scheduled maintenance (up to two
/// days ahead) or a free-form broadcast, whichever applies.
///
/// Without it, a mobile tester hitting a planned outage sees only unexplained
/// failures — operators have no way to say anything outside a killed flow's
/// sheet, and the webapp's users got two days' warning for the same event.
///
/// Renders nothing when there is nothing to announce, so it is safe to mount
/// unconditionally.
class SystemStatusBanner extends StatelessWidget {
  const SystemStatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SystemBanner?>(
      valueListenable: sl<SystemStatusService>().banner,
      builder: (context, banner, _) {
        if (banner == null) return const SizedBox.shrink();
        return _Banner(banner: banner);
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.banner});

  final SystemBanner banner;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final spans = switch (banner) {
      MaintenanceBanner(:final window) => [
        NoticeSpan(maintenanceBannerText(window)),
      ],
      NoticeBanner(:final notice) => parseNoticeSpans(notice.message),
    };

    return Material(
      color: colors.accent,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            MallowTheme.spacing20,
            MallowTheme.spacingSm,
            MallowTheme.spacingSm,
            MallowTheme.spacingSm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      for (final span in spans)
                        TextSpan(
                          text: span.text,
                          style: span.isLink
                              ? const TextStyle(
                                  decoration: TextDecoration.underline,
                                )
                              : null,
                          recognizer: span.isLink
                              ? (TapGestureRecognizerFactory.build(span.url!))
                              : null,
                        ),
                    ],
                  ),
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textOnAccent,
                  ),
                ),
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              TapTargetExpander(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      unawaited(sl<SystemStatusService>().dismiss(banner)),
                  child: Padding(
                    padding: const EdgeInsets.all(MallowTheme.spacingXs),
                    child: MallowSvgIcon(
                      'assets/icons/x.svg',
                      width: 14,
                      height: 14,
                      color: colors.textOnAccent,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Builds (and leaks-by-design) a tap recognizer for a link run.
///
/// `TextSpan` recognizers normally have to be disposed by a `StatefulWidget`.
/// This banner is a rare, short-lived, at-most-one-per-app surface whose spans
/// come from an operator-authored string, so a recognizer per link run for the
/// life of the banner is bounded and not worth the state machinery.
abstract final class TapGestureRecognizerFactory {
  static TapGestureRecognizer build(String url) =>
      TapGestureRecognizer()..onTap = () => unawaited(_open(url));

  static Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
