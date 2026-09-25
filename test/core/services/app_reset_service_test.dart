import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/app_reset_service.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements AuthService {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockAnalytics extends Mock implements AnalyticsService {}

/// The teardown behind Reset app / Start fresh must run every step even when
/// one fails, and must report rather than throw — a wipe that stopped at the
/// first error left some keys gone and the session intact, which is the worst
/// of both: the user looks signed in on a device that can no longer sign.
void main() {
  late _MockAuth auth;
  late _MockWalletManager walletManager;
  late _MockAnalytics analytics;
  late AppResetService service;

  setUp(() {
    auth = _MockAuth();
    walletManager = _MockWalletManager();
    analytics = _MockAnalytics();
    service = AppResetService(
      authService: auth,
      walletManager: walletManager,
      analytics: analytics,
    );
    when(() => auth.logout()).thenAnswer((_) async {});
    when(() => walletManager.deleteWallet()).thenAnswer((_) async => const []);
    when(() => analytics.resetDeviceIdentity()).thenAnswer((_) async {});
  });

  test('runs session, storage and analytics teardown in order', () async {
    final failures = await service.resetApp(reason: ResetReason.resetApp);

    expect(failures, isEmpty);
    verifyInOrder([
      () => auth.logout(),
      () => walletManager.deleteWallet(),
      () => analytics.resetDeviceIdentity(),
    ]);
  });

  test('a failing logout does not stop the storage wipe', () async {
    when(() => auth.logout()).thenThrow(StateError('no session'));

    final failures = await service.resetApp(reason: ResetReason.startFresh);

    verify(() => walletManager.deleteWallet()).called(1);
    verify(() => analytics.resetDeviceIdentity()).called(1);
    expect(failures.map((f) => f.step), ['auth.logout']);
  });

  test('storage failures are passed through alongside later ones', () async {
    when(() => walletManager.deleteWallet()).thenAnswer(
      (_) async => const [EraseFailure('vault.delete', 'write_failed')],
    );
    when(() => analytics.resetDeviceIdentity()).thenThrow(Exception('x'));

    final failures = await service.resetApp(reason: ResetReason.resetApp);

    expect(failures.map((f) => f.step), ['vault.delete', 'analytics.reset']);
  });
}
