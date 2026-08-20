import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/widgets.dart';

import 'confirm_sheet.dart';

/// An OS permission mallow can be permanently denied, where the only way back
/// is the device's own settings app.
enum AppPermission {
  camera(
    title: 'Camera access needed',
    message: 'mallow needs camera access to scan QR codes.',
    settingsType: AppSettingsType.settings,
    androidHint: 'Turn it on in Settings › Apps › mallow › Permissions.',
    iosHint: 'Turn it on in Settings › mallow › Camera.',
  ),
  notifications(
    title: 'Notifications are off',
    message:
        "Notifications are turned off for mallow, so you won't hear about "
        'offers, sales or mints.',
    settingsType: AppSettingsType.notification,
    androidHint: 'Turn them on in Settings › Apps › mallow › Notifications.',
    iosHint: 'Turn them on in Settings › Notifications › mallow.',
  );

  const AppPermission({
    required this.title,
    required this.message,
    required this.settingsType,
    required this.androidHint,
    required this.iosHint,
  });

  /// Sheet heading.
  final String title;

  /// What the app can't do without the permission.
  final String message;

  /// Which OS settings screen to hand the user to.
  ///
  /// [AppSettingsType.notification] resolves to the app's own notification
  /// page (Android `ACTION_APP_NOTIFICATION_SETTINGS`, iOS 15.4+
  /// `openNotificationSettingsURLString`). Everything else falls back to the
  /// app detail page, which is where per-permission switches like camera live.
  final AppSettingsType settingsType;

  /// Where to find the switch, for when the deep link can't be opened.
  final String androidHint;

  /// iOS wording for [androidHint] — the settings path differs per platform.
  final String iosHint;

  /// The manual path text for the current platform.
  String get manualHint => Platform.isIOS ? iosHint : androidHint;
}

/// Explain a denied OS [permission] and offer the user a way back.
///
/// Both platforms deep-link straight into mallow's own settings page via the
/// `app_settings` plugin — an `ACTION_APPLICATION_DETAILS_SETTINGS` intent on
/// Android, `UIApplication.openSettingsURLString` on iOS. `url_launcher` can't
/// do this on Android: its Android implementation only ever issues
/// `ACTION_VIEW`, so no URL reaches the settings app.
///
/// If the hand-off fails we fall back to spelling out where the switch lives,
/// so the sheet never leaves the user with a dead button.
///
/// Returns true when the user was actually sent to the OS settings app —
/// callers can use that to re-check the permission when the app resumes.
Future<bool> showPermissionSettingsSheet(
  BuildContext context,
  AppPermission permission,
) async {
  final confirmed = await showConfirmSheet(
    context,
    title: permission.title,
    message: '${permission.message} Enable it for mallow in Settings.',
    confirmLabel: 'Open Settings',
    cancelLabel: 'Not now',
  );

  if (confirmed != true) return false;

  try {
    await AppSettings.openAppSettings(type: permission.settingsType);
    return true;
  } catch (_) {
    // The OS refused the intent — fall through to the manual instructions.
  }

  if (!context.mounted) return false;
  await showConfirmSheet(
    context,
    title: permission.title,
    message: '${permission.message} ${permission.manualHint}',
    confirmLabel: 'OK',
    cancelLabel: null,
  );
  return false;
}
