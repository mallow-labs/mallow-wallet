import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/security/biometric_auth.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/settings/screens/security_privacy_screen.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements AuthService {}

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockBiometrics extends Mock implements BiometricAuthService {}

class _MockPrefs extends Mock implements PreferencesService {}

void main() {
  late _MockAuth auth;
  late _MockStorage storage;
  late _MockBiometrics biometrics;
  late _MockPrefs prefs;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerSingleton<T>(instance);
  }

  setUp(() {
    auth = _MockAuth();
    storage = _MockStorage();
    biometrics = _MockBiometrics();
    prefs = _MockPrefs();

    register<AuthService>(auth);
    register<SecureWalletStorage>(storage);
    register<BiometricAuthService>(biometrics);
    register<PreferencesService>(prefs);

    when(() => storage.loadBiometricEnabled()).thenAnswer((_) async => false);
    when(
      () => storage.loadTransactionAuthEnabled(),
    ).thenAnswer((_) async => false);
    when(
      () => storage.loadTransactionAuthThresholdUsd(),
    ).thenAnswer((_) async => null);
    when(() => biometrics.isAvailable()).thenAnswer((_) async => false);
    when(() => biometrics.hasFaceId()).thenAnswer((_) async => false);
    when(() => biometrics.hasFingerprint()).thenAnswer((_) async => false);
    when(() => prefs.analyticsOptOut).thenReturn(false);
  });

  tearDown(() {
    sl.unregister<AuthService>();
    sl.unregister<SecureWalletStorage>();
    sl.unregister<BiometricAuthService>();
    sl.unregister<PreferencesService>();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SecurityPrivacyScreen()));
    await tester.pumpAndSettle();
  }

  // Product decision: with no profile there is nothing for
  // `POST /v2/user/delete` to remove, so the row is hidden rather than shown
  // and failing. Reset app must still be there — the two rows are adjacent and
  // only one of them depends on a profile.
  testWidgets('no username → no Delete profile row', (tester) async {
    when(() => auth.currentUser).thenReturn(const api.User());

    await pumpScreen(tester);

    expect(find.text('Delete profile'), findsNothing);
    expect(find.text('Reset app'), findsOneWidget);
  });

  testWidgets('username present → Delete profile row shows', (tester) async {
    when(() => auth.currentUser).thenReturn(const api.User(username: 'ada'));

    await pumpScreen(tester);

    expect(find.text('Delete profile'), findsOneWidget);
  });

  // The sibling moderation screen was routed but never linked from Settings;
  // an unreachable block-management surface is an App Review finding of its
  // own.
  testWidgets('Blocked accounts row is always present', (tester) async {
    when(() => auth.currentUser).thenReturn(const api.User());

    await pumpScreen(tester);

    expect(find.text('Blocked accounts'), findsOneWidget);
  });
}
