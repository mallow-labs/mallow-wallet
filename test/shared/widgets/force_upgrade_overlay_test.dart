import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/shared/widgets/force_upgrade_overlay.dart';

const _message = 'Update to keep sending on Ethereum.';

/// Config the server would return to a client it considers too old.
const _updateRequired = RemoteConfig(
  minimumVersion: '0.12.0',
  updateRequired: true,
  updateMessage: _message,
);

Future<ValueNotifier<RemoteConfig>> _pumpOverlay(
  WidgetTester tester, {
  required RemoteConfig config,
  required String? localVersion,
}) async {
  final notifier = ValueNotifier<RemoteConfig>(config);
  addTearDown(notifier.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: ForceUpgradeOverlay(
        config: notifier,
        localVersionLoader: () async => localVersion,
      ),
    ),
  );
  // Let the local-version lookup resolve.
  await tester.pumpAndSettle();
  return notifier;
}

void main() {
  testWidgets('walls the app when the local build is below the minimum', (
    tester,
  ) async {
    await _pumpOverlay(tester, config: _updateRequired, localVersion: '0.11.0');

    expect(find.text('Update required'), findsOneWidget);
    expect(find.text(_message), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);
  });

  testWidgets('stays down when updateRequired is true but local >= minimum', (
    tester,
  ) async {
    // THE test that matters. `updateRequired` is server-computed from the
    // App-Version header, which makes it the most dangerous field in the
    // payload: a fat-fingered `minimumVersion`, or a comparison bug in the
    // handler, would otherwise wall EVERY user out of the app — including
    // users already on the newest build, who have no way to recover — until a
    // backend fix ships. The client-side comparison bounds that blast radius
    // to clients that genuinely are behind. If this test starts failing, the
    // sanity bound has been dropped and a bad config edit is now able to
    // brick the install base.
    await _pumpOverlay(tester, config: _updateRequired, localVersion: '0.12.0');

    expect(find.text('Update required'), findsNothing);
  });

  testWidgets('stays down when the local version cannot be determined', (
    tester,
  ) async {
    // Fail-open: a broken PackageInfo lookup must degrade to "app keeps
    // working", never to an unrecoverable wall.
    await _pumpOverlay(tester, config: _updateRequired, localVersion: null);

    expect(find.text('Update required'), findsNothing);
  });

  testWidgets('stays down when the server does not require an update', (
    tester,
  ) async {
    await _pumpOverlay(
      tester,
      config: RemoteConfig.permissive,
      localVersion: '0.1.0',
    );

    expect(find.text('Update required'), findsNothing);
  });

  testWidgets('appears on a later config emission without a remount', (
    tester,
  ) async {
    // The wall is driven off RemoteConfigService.config so a minimumVersion
    // bump lands on the next foreground fetch rather than the next cold start.
    final notifier = await _pumpOverlay(
      tester,
      config: RemoteConfig.permissive,
      localVersion: '0.11.0',
    );
    expect(find.text('Update required'), findsNothing);

    notifier.value = _updateRequired;
    await tester.pumpAndSettle();

    expect(find.text('Update required'), findsOneWidget);
  });

  group('forceUpgradeRequired', () {
    test('needs both the server verdict and the local comparison', () {
      expect(forceUpgradeRequired(_updateRequired, '0.11.9'), isTrue);
      expect(forceUpgradeRequired(_updateRequired, '0.12.0'), isFalse);
      expect(forceUpgradeRequired(_updateRequired, '1.0.0'), isFalse);
      // Server says no: never wall, whatever the versions say.
      expect(
        forceUpgradeRequired(
          const RemoteConfig(minimumVersion: '0.12.0'),
          '0.1.0',
        ),
        isFalse,
      );
    });

    test('fails open on anything it cannot compare', () {
      expect(forceUpgradeRequired(_updateRequired, null), isFalse);
      expect(forceUpgradeRequired(_updateRequired, 'not-a-version'), isFalse);
      expect(
        forceUpgradeRequired(const RemoteConfig(updateRequired: true), '0.1.0'),
        isFalse,
      );
      expect(
        forceUpgradeRequired(
          const RemoteConfig(updateRequired: true, minimumVersion: 'latest'),
          '0.1.0',
        ),
        isFalse,
      );
    });

    test('ignores build and pre-release suffixes', () {
      // pubspec carries `0.11.0+14`; an operator may type `0.12.0-rc.1`.
      expect(forceUpgradeRequired(_updateRequired, '0.11.0+14'), isTrue);
      expect(forceUpgradeRequired(_updateRequired, '0.12.0+1'), isFalse);
      expect(
        forceUpgradeRequired(
          const RemoteConfig(updateRequired: true, minimumVersion: '0.12.0-rc'),
          '0.11.0',
        ),
        isTrue,
      );
    });

    test('compares numerically, not lexicographically', () {
      // '0.9.0' > '0.10.0' as strings — the trap a naive compareTo falls into.
      expect(
        forceUpgradeRequired(
          const RemoteConfig(updateRequired: true, minimumVersion: '0.10.0'),
          '0.9.0',
        ),
        isTrue,
      );
      expect(
        forceUpgradeRequired(
          const RemoteConfig(updateRequired: true, minimumVersion: '0.9.0'),
          '0.10.0',
        ),
        isFalse,
      );
    });

    test('treats a short version as zero-padded', () {
      expect(
        forceUpgradeRequired(
          const RemoteConfig(updateRequired: true, minimumVersion: '1'),
          '0.99.99',
        ),
        isTrue,
      );
    });
  });
}
