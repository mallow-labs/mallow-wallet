import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/app_version.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/features/moderation/services/report_context.dart';
import 'package:package_info_plus/package_info_plus.dart';

PackageInfo _info() => PackageInfo(
  appName: 'mallow',
  packageName: 'com.example.wallet',
  version: '0.18.0',
  buildNumber: '57',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'mallow',
      packageName: 'com.example.wallet',
      version: '0.18.0',
      buildNumber: '57',
      buildSignature: '',
    ),
  );
  tearDown(Config.debugOverrides.clear);

  group('displayAppVersion', () {
    test('a release build shows the version alone', () {
      expect(displayAppVersion(_info()), '0.18.0 (57)');
    });

    test('a preview build appends the build label', () {
      Config.debugOverrides['BUILD_LABEL'] = 'preview dev@1a2b3c4d';
      expect(displayAppVersion(_info()), '0.18.0 (57) · preview dev@1a2b3c4d');
    });

    test('a whitespace-only label counts as unset', () {
      Config.debugOverrides['BUILD_LABEL'] = '  ';
      expect(displayAppVersion(_info()), '0.18.0 (57)');
    });
  });

  group('buildReportContext', () {
    test('omits buildLabel on a release build', () async {
      final json = (await buildReportContext(screen: '/home')).toJson();
      expect(json['appVersion'], '0.18.0+57');
      expect(json.containsKey('buildLabel'), isFalse);
    });

    test('carries the build label on a preview build', () async {
      Config.debugOverrides['BUILD_LABEL'] = 'preview dev@1a2b3c4d';
      final json = (await buildReportContext(screen: '/home')).toJson();
      expect(json['buildLabel'], 'preview dev@1a2b3c4d');
    });
  });
}
