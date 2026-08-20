import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:package_info_plus/package_info_plus.dart';

/// The route pattern the user is looking at (e.g. `/artwork/:mint`), used as
/// the report's `screen`. The *pattern*, not the resolved path — the target id
/// is already its own field and repeating it here would just be noise.
///
/// Falls back to `'unknown'` outside a router (widget tests), never throws.
String currentScreenName(BuildContext context) {
  try {
    return GoRouterState.of(context).matchedLocation;
  } catch (_) {
    return 'unknown';
  }
}

/// Builds the `context` object attached to every report — what the triager
/// needs to reproduce what the reporter was looking at, and nothing more.
///
/// Deliberately no addresses, no device id, no free-form diagnostics: the
/// report already carries `reporterAddress` server-side from the login cookie,
/// and anything else here would be user data travelling to a moderation queue.
///
/// Never throws — a failed `PackageInfo` read drops the version key rather
/// than blocking the report.
Future<api.ReportContext> buildReportContext({required String screen}) async {
  final platform = Platform.operatingSystem;
  String? appVersion;
  try {
    final info = await PackageInfo.fromPlatform();
    appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {
    appVersion = null;
  }
  return api.ReportContext(
    screen: screen,
    platform: platform,
    appVersion: appVersion,
  );
}
