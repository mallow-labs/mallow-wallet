import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/remote_config.dart';
import '../theme/mallow_theme.dart';
import 'mallow_button.dart';

/// Play Store listing, keyed off the `applicationId` in
/// `android/app/build.gradle.kts`.
const _playStoreUrl =
    'https://play.google.com/store/apps/details?id=com.mallow.wallet.android';

/// App Store listing. The numeric id is not derivable from anything in this
/// repo — the release tooling works off the bundle id — so it is recorded
/// here rather than computed. This is the only button on a screen the
/// user cannot leave, so a wrong id is a dead end, not a cosmetic bug.
const _iosStoreUrl = 'https://apps.apple.com/app/id6758995397';

/// Copy shown when the backend requires an update but sent no message.
const forceUpgradeFallbackMessage =
    'A newer version of mallow is required to continue.';

/// The running build's semver (no `+build` suffix), or null when the platform
/// lookup fails.
///
/// Null is load-bearing: [forceUpgradeRequired] refuses to wall the user out
/// when the local version is unknown, so a broken lookup degrades to "app
/// keeps working" rather than "app is bricked". Same source as
/// `AppVersionInterceptor`, so the version the wall compares is the version
/// the backend judged.
Future<String?> readLocalAppVersion() async {
  try {
    return (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    return null;
  }
}

/// Whether the force-upgrade wall should be up.
///
/// [RemoteConfig.updateRequired] alone is **not** enough. It is the most
/// dangerous field in the payload: a fat-fingered `minimumVersion` or a
/// server-side comparison bug would lock every user out of the app until a
/// backend fix ships. AND-ing it with a local comparison bounds that blast
/// radius to clients that genuinely are below the minimum, while leaving the
/// rule itself server-side.
///
/// Fails open on anything it cannot establish — unknown [localVersion], absent
/// or unparseable [RemoteConfig.minimumVersion] — because a wall raised on a
/// guess is unrecoverable from the client.
bool forceUpgradeRequired(RemoteConfig config, String? localVersion) {
  if (!config.updateRequired) return false;
  final minimum = config.minimumVersion;
  if (minimum == null || localVersion == null) return false;
  final comparison = _compareVersions(localVersion, minimum);
  return comparison != null && comparison < 0;
}

/// `a` vs `b` as dotted-numeric versions, or null when either side isn't
/// parseable. Any `+build` / `-prerelease` suffix is dropped before the
/// comparison — the app's own version is `0.11.0+14`-shaped in pubspec, and
/// `PackageInfo.version` already strips the build, but the server's
/// `minimumVersion` is operator-typed and may not.
int? _compareVersions(String a, String b) {
  final parsedA = _parseVersion(a);
  final parsedB = _parseVersion(b);
  if (parsedA == null || parsedB == null) return null;
  for (var i = 0; i < parsedA.length; i++) {
    final delta = parsedA[i].compareTo(parsedB[i]);
    if (delta != 0) return delta;
  }
  return 0;
}

/// `major.minor.patch` as three ints, right-padded with zeros. Null for
/// anything that isn't one to three non-negative integers.
List<int>? _parseVersion(String version) {
  final core = version.split('+').first.split('-').first.trim();
  final parts = core.split('.');
  if (parts.isEmpty || parts.length > 3) return null;
  final out = <int>[0, 0, 0];
  for (var i = 0; i < parts.length; i++) {
    final value = int.tryParse(parts[i]);
    if (value == null || value < 0) return null;
    out[i] = value;
  }
  return out;
}

/// Full-screen, non-dismissable update wall.
///
/// Mounted above the router at the same layer as the privacy-blur overlay in
/// `app.dart`, which is the layer already proven to be un-routable-around.
/// Renders nothing at all until [forceUpgradeRequired] says otherwise, and
/// rebuilds off [config] so a `minimumVersion` bump appears on the next
/// foreground fetch rather than the next cold start.
class ForceUpgradeOverlay extends StatefulWidget {
  const ForceUpgradeOverlay({
    required this.config,
    super.key,
    this.localVersionLoader = readLocalAppVersion,
  });

  /// Live remote config — `RemoteConfigService.config`.
  final ValueListenable<RemoteConfig> config;

  /// Seam for the local-version lookup. Production reads `package_info_plus`;
  /// tests supply the version (or null) directly.
  @visibleForTesting
  final Future<String?> Function() localVersionLoader;

  @override
  State<ForceUpgradeOverlay> createState() => _ForceUpgradeOverlayState();
}

class _ForceUpgradeOverlayState extends State<ForceUpgradeOverlay> {
  /// Null both before the lookup resolves and when it failed. Either way the
  /// wall stays down — the cold-launch window is exactly when a spurious wall
  /// would be most confusing.
  String? _localVersion;

  @override
  void initState() {
    super.initState();
    _resolveLocalVersion();
  }

  Future<void> _resolveLocalVersion() async {
    final version = await widget.localVersionLoader();
    if (!mounted || version == null) return;
    setState(() => _localVersion = version);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RemoteConfig>(
      valueListenable: widget.config,
      builder: (context, config, _) {
        if (!forceUpgradeRequired(config, _localVersion)) {
          return const SizedBox.shrink();
        }
        return _UpgradeWall(message: config.updateMessage);
      },
    );
  }
}

/// The wall itself. Opaque [Material] over the whole viewport, so it both
/// hides and absorbs everything underneath — the same treatment [LockScreen]
/// uses one layer down. There is deliberately no dismiss affordance.
class _UpgradeWall extends StatelessWidget {
  const _UpgradeWall({required this.message});

  final String? message;

  Future<void> _openStore() async {
    final url = defaultTargetPlatform == TargetPlatform.android
        ? _playStoreUrl
        : _iosStoreUrl;
    // externalApplication, not the in-app browser the rest of the app uses:
    // the destination is a store listing, which only installs from the store
    // app itself.
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final body = (message == null || message!.trim().isEmpty)
        ? forceUpgradeFallbackMessage
        : message!;

    return Material(
      color: colors.bgPrimary,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(MallowTheme.spacingLg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Update required',
                style: MallowTheme.editorialSubhead.copyWith(
                  color: colors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: MallowTheme.spacingMd),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    body,
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: MallowTheme.spacingXl),
              MallowButton(
                label: 'Update',
                isFullWidth: true,
                onPressed: _openStore,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
