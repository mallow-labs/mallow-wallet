import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/social_auth_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/social_vault/platform_backup_guard.dart';
import 'package:mallow_wallet/core/social_vault/platform_slot_store.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_api.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/settings/screens/show_secrets_screen.dart';
import 'package:mallow_wallet/features/social_vault/screens/sign_in_keys_screen.dart';
import 'package:mallow_wallet/features/social_vault/services/sign_in_key_label.dart';
import 'package:mallow_wallet/features/social_vault/services/social_vault_attention.dart';
import 'package:mallow_wallet/features/social_vault/widgets/social_vault_attention_banner.dart';
import 'package:mallow_wallet/features/social_vault/widgets/social_vault_notices.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/social_wallet_copy.dart';
import 'package:mallow_wallet/shared/widgets/social_provider_icon.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements WalletRepository {}

class _MockVaults extends Mock implements SocialVaultService {}

class _MockPlatform extends Mock implements PlatformSlotStore {}

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockPrefs extends Mock implements PreferencesService {}

class _MockDio extends Mock implements Dio {}

class _MockSocialAuth extends Mock implements SocialAuthService {}

WalletInfo _row(
  String chain,
  String address, {
  String? vaultId,
  bool legacy = false,
}) => WalletInfo(
  id: 'w-$chain-${vaultId ?? 'none'}',
  address: address,
  name: 'Google Wallet',
  walletType: WalletType.social,
  chain: chain,
  socialProvider: 'google',
  socialVaultId: vaultId,
  legacySocial: legacy,
);

/// The small mark a wallet from the older sign-in carries on its icon.
final _legacyMark = find.byKey(const ValueKey('legacy-sign-in-mark'));

api.SocialVaultSlot _slot(String id, api.SocialVaultSlotKind kind, String l) =>
    api.SocialVaultSlot(
      createdAt: '',
      slotId: id,
      kind: kind,
      nonce: 'AAAA',
      wrappedKey: 'AAAA',
      label: l,
    );

api.SocialVault _vault(List<api.SocialVaultSlot> slots) => api.SocialVault(
  vaultId: 'vault-1',
  revision: 3,
  payloadNonce: '',
  payloadCiphertext: '',
  vaultPublicKey: 'PK',
  slots: slots,
  pendingDeletion: null,
  createdAt: '',
  updatedAt: '',
);

void main() {
  late _MockRepo repo;
  late _MockVaults vaults;
  late _MockPlatform platform;
  late _MockStorage storage;
  late ValueNotifier<PlatformBackupStatus> backup;

  /// What a check of the phone's backup found for `vault-1`.
  PlatformBackupStatus backupStatus({
    bool encrypted = true,
    bool exposed = false,
  }) => PlatformBackupStatus(
    encrypted: encrypted,
    pausedVaultIds: encrypted ? const {} : const {'vault-1'},
    pausedSince: encrypted ? null : DateTime.utc(2026, 11, 10),
    exposedVaultIds: exposed ? const {'vault-1'} : const {},
    exposedSince: exposed ? DateTime.utc(2026, 11, 10) : null,
    replacementOffered: exposed,
    cloudBacked: {'vault-1.p1': encrypted},
  );

  final linked = Account(
    id: 'linked',
    name: 'Account 02',
    kind: AccountKind.social,
    wallets: [
      _row('solana', 'SolLinked', vaultId: 'vault-1'),
      _row('ethereum', '0xlinked', vaultId: 'vault-1'),
    ],
  );
  // A wallet from the older sign-in: no vault, and marked as such.
  final older = Account(
    id: 'older',
    name: 'Account 03',
    kind: AccountKind.social,
    wallets: [
      _row('solana', 'SolOld', legacy: true),
      _row('ethereum', '0xold', legacy: true),
      _row('tezos', 'tz1old', legacy: true),
    ],
  );
  // A vault wallet whose backup was deleted: no vault either, but not marked.
  final backupDeleted = Account(
    id: 'backup-deleted',
    name: 'Account 05',
    kind: AccountKind.social,
    wallets: [_row('solana', 'SolGone'), _row('ethereum', '0xgone')],
  );

  // `planRemoval` takes a vault; mocktail needs a stand-in to match it.
  setUpAll(() {
    registerFallbackValue(_vault(const []));
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(
      SocialVaultRemovalPlan(
        removing: _slot('x', api.SocialVaultSlotKind.platform, ''),
        newPlatformSlot: false,
        passkeysToConfirm: const [],
        dropped: const [],
      ),
    );
  });

  setUp(() {
    repo = _MockRepo();
    vaults = _MockVaults();
    platform = _MockPlatform();
    storage = _MockStorage();
    sl
      ..registerSingleton<WalletRepository>(repo)
      ..registerSingleton<SocialVaultService>(vaults)
      ..registerSingleton<PlatformSlotStore>(platform)
      ..registerSingleton<SecureWalletStorage>(storage);
    // The secrets rows draw account avatars, which resolve this from GetIt.
    sl.registerLazySingleton<AvatarService>(
      () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
    );
    when(() => repo.getAccountViews()).thenAnswer((_) async => [linked, older]);
    when(() => vaults.passkeysAvailable()).thenAnswer((_) async => true);
    backup = ValueNotifier(PlatformBackupStatus.protected);
    when(() => vaults.platformBackup).thenReturn(backup);
    when(
      () => vaults.loadDataKey('vault-1'),
    ).thenAnswer((_) async => Uint8List(32));
    when(
      () => vaults.hasUsableDataKey('vault-1'),
    ).thenAnswer((_) async => true);
    when(
      () => vaults.localPlatformSlotIds('vault-1'),
    ).thenAnswer((_) async => {'p1'});
    when(
      () => storage.loadSocialAccountMnemonic(any()),
    ).thenAnswer((_) async => null);
    // A wallet from the older sign-in: one secp256k1 key behind Ethereum and
    // Tezos.
    when(
      () => storage.loadPrivateKey(any()),
    ).thenAnswer((_) async => 'same-key');
    final prefs = _MockPrefs();
    when(() => prefs.socialVaultPlatformOnlyAcknowledged).thenReturn({});
    sl.registerSingleton<PreferencesService>(prefs);
  });

  tearDown(() async => sl.reset());

  Future<void> pump(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: MallowTheme.lightTheme, home: screen),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists each vault key and marks this device', (tester) async {
    when(() => vaults.cached('vault-1')).thenAnswer(
      (_) async => CachedSocialVault(
        vault: _vault([
          _slot('p1', api.SocialVaultSlotKind.platform, 'iCloud Keychain'),
          _slot('k1', api.SocialVaultSlotKind.passkeyPrf, 'Passkey · Pixel'),
        ]),
        provider: 'google',
        emailHint: 'person@example.test',
      ),
    );
    await pump(tester, const SignInKeysScreen(preAuthenticated: true));

    expect(find.text('person@example.test'), findsOneWidget);
    expect(find.text('iCloud Keychain'), findsOneWidget);
    expect(
      find.text('Device backup · available on this device'),
      findsOneWidget,
    );
    expect(find.text('Passkey · Pixel'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsNWidgets(2));
    expect(find.text('Add a passkey'), findsOneWidget);
    // The wallet from the older sign-in is listed, marked, and told what it
    // is. It is offered no backup and nothing calls it protected.
    expect(_legacyMark, findsOneWidget);
    expect(
      find.textContaining(
        'Older sign-in, run by Web3Auth: your Google account alone can open '
        'this wallet.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('older sign-in on the mallow website'),
      findsOne,
    );
    expect(find.textContaining('Back up'), findsNothing);
    // The footer speaks for wallets with sign-in keys only.
    expect(
      find.textContaining('A wallet with sign-in keys opens with'),
      findsOneWidget,
    );
  });

  testWidgets('with only a wallet from the older sign-in, nothing says a '
      'Google account cannot open it', (tester) async {
    when(() => repo.getAccountViews()).thenAnswer((_) async => [older]);
    await pump(tester, const SignInKeysScreen(preAuthenticated: true));

    expect(_legacyMark, findsOneWidget);
    expect(find.textContaining('alone can open this wallet'), findsOneWidget);
    expect(find.textContaining('encrypted copy it cannot open'), findsNothing);
    expect(find.textContaining('can never open'), findsNothing);
    expect(find.text('Add a passkey'), findsNothing);
  });

  testWidgets('a vault wallet whose backup was deleted is not shown as one '
      'from the older sign-in', (tester) async {
    when(() => repo.getAccountViews()).thenAnswer((_) async => [backupDeleted]);
    await pump(tester, const SignInKeysScreen(preAuthenticated: true));

    expect(_legacyMark, findsNothing);
    expect(find.textContaining('Web3Auth'), findsNothing);
    expect(find.textContaining('older sign-in'), findsNothing);
    expect(
      find.textContaining('This wallet’s backup was deleted'),
      findsOneWidget,
    );
    // It is a wallet with a recovery phrase and nothing else: no vault
    // action is offered.
    expect(find.text('Add a passkey'), findsNothing);
    expect(find.text('Delete wallet backup'), findsNothing);
    expect(find.byTooltip('Remove'), findsNothing);
  });

  group('the screen is gated on entry', () {
    setUp(() {
      when(() => vaults.cached('vault-1')).thenAnswer(
        (_) async => CachedSocialVault(
          vault: _vault([
            _slot('p1', api.SocialVaultSlotKind.platform, 'iCloud Keychain'),
          ]),
          provider: 'google',
          emailHint: 'person@example.test',
        ),
      );
    });

    testWidgets('an entry that is not pre-authenticated is challenged before '
        'anything is listed', (tester) async {
      // The store cannot say what the lock is: the gate denies.
      when(() => storage.loadAuthFactors()).thenThrow(StateError('keystore'));
      await pump(tester, const SignInKeysScreen());

      verify(() => storage.loadAuthFactors()).called(1);
      expect(find.text('iCloud Keychain'), findsNothing);
      expect(find.text('person@example.test'), findsNothing);
      verifyNever(() => repo.getAccountViews());
      verifyNever(() => vaults.cached(any()));
    });

    testWidgets('and lists the keys once the challenge is cleared', (
      tester,
    ) async {
      when(
        () => storage.loadAuthFactors(),
      ).thenAnswer((_) async => (hasPin: false, biometricEnabled: false));
      await pump(tester, const SignInKeysScreen());

      verify(() => storage.loadAuthFactors()).called(1);
      expect(find.text('iCloud Keychain'), findsOneWidget);
    });

    testWidgets('the Security & Privacy row, already behind the gate, is not '
        'challenged twice', (tester) async {
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      verifyNever(() => storage.loadAuthFactors());
      expect(find.text('iCloud Keychain'), findsOneWidget);
    });
  });

  group('Delete wallet backup', () {
    late _MockSocialAuth socialAuth;

    /// While an action runs the screen's buttons spin, so nothing "settles":
    /// pump through the sheet's transition instead.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    setUp(() {
      socialAuth = _MockSocialAuth();
      sl.registerSingleton<SocialAuthService>(socialAuth);
      when(() => socialAuth.deleteWalletBackup(any())).thenAnswer((_) async {});
      when(
        () => storage.loadAuthFactors(),
      ).thenAnswer((_) async => (hasPin: false, biometricEnabled: false));
      when(() => vaults.cached('vault-1')).thenAnswer(
        (_) async => CachedSocialVault(
          vault: _vault([
            _slot('p1', api.SocialVaultSlotKind.platform, 'iCloud Keychain'),
          ]),
          provider: 'google',
          emailHint: null,
        ),
      );
    });

    testWidgets('re-authenticates, says what is lost, offers the phrase '
        'first, then deletes', (tester) async {
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      await tester.tap(find.text('Delete wallet backup'));
      await settle(tester);

      verify(() => storage.loadAuthFactors()).called(1);
      expect(find.text('Delete wallet backup?'), findsOneWidget);
      expect(find.text(deleteWalletBackupMessage), findsOneWidget);
      expect(
        deleteWalletBackupMessage,
        allOf(
          contains('no longer be able to recover this wallet on a new device'),
          contains('stays on this phone'),
          contains('recovery phrase becomes the only backup'),
        ),
      );
      expect(find.text('View recovery phrase'), findsOneWidget);
      verifyNever(() => socialAuth.deleteWalletBackup(any()));

      // The sheet's own button, not the row that opened it.
      await tester.tap(find.text('Delete wallet backup').last);
      await settle(tester);
      verify(() => socialAuth.deleteWalletBackup('linked')).called(1);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('a failed re-authentication opens no confirmation', (
      tester,
    ) async {
      when(() => storage.loadAuthFactors()).thenThrow(StateError('keystore'));
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      await tester.tap(find.text('Delete wallet backup'));
      await settle(tester);
      expect(find.text('Delete wallet backup?'), findsNothing);
      verifyNever(() => socialAuth.deleteWalletBackup(any()));
    });

    testWidgets('cancelling deletes nothing', (tester) async {
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      await tester.tap(find.text('Delete wallet backup'));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      verifyNever(() => socialAuth.deleteWalletBackup(any()));
    });

    testWidgets('a wrong clock is said as such', (tester) async {
      when(() => socialAuth.deleteWalletBackup(any())).thenThrow(
        const SocialVaultApiException(
          SocialVaultApiError.staleTimestamp,
          status: 401,
        ),
      );
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      await tester.tap(find.text('Delete wallet backup'));
      await settle(tester);
      await tester.tap(find.text('Delete wallet backup').last);
      await settle(tester);
      expect(find.text(socialVaultClockMessage), findsOneWidget);
      expect(
        socialVaultClockMessage,
        'Check this device’s date and time, then try again.',
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('is not offered by a device that cannot sign for the '
        'vault', (tester) async {
      when(
        () => vaults.hasUsableDataKey('vault-1'),
      ).thenAnswer((_) async => false);
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      expect(find.text('Delete wallet backup'), findsNothing);
    });
  });

  group('the phone backup of this device’s key', () {
    setUp(() {
      when(() => vaults.cached('vault-1')).thenAnswer(
        (_) async => CachedSocialVault(
          vault: _vault([
            _slot('p1', api.SocialVaultSlotKind.platform, 'Android phone'),
          ]),
          provider: 'google',
          emailHint: null,
        ),
      );
    });

    testWidgets('says nothing while the backup is protected', (tester) async {
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      expect(find.text(backupPausedTitle), findsNothing);
      expect(find.text(replaceSignInKeysLabel), findsNothing);
    });

    testWidgets('a paused backup is said on the screen, and when it '
        'changes', (tester) async {
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      // The check runs whenever the app comes forward, this screen open.
      backup.value = backupStatus(encrypted: false);
      await tester.pumpAndSettle();

      expect(find.text(backupPausedTitle), findsOneWidget);
      expect(find.textContaining('Set a screen lock'), findsWidgets);

      backup.value = backupStatus();
      await tester.pumpAndSettle();
      expect(find.text(backupPausedTitle), findsNothing);
    });

    testWidgets('an exposed vault offers a replacement, and Dismiss drops '
        'the advice', (tester) async {
      backup.value = backupStatus(exposed: true);
      when(() => vaults.dismissBackupExposure('vault-1')).thenAnswer((_) async {
        backup.value = backupStatus();
      });
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));

      expect(find.text(backupWasUnprotectedMessage), findsOneWidget);
      expect(find.text(replaceSignInKeysLabel), findsOneWidget);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();

      verify(() => vaults.dismissBackupExposure('vault-1')).called(1);
      expect(find.text(backupWasUnprotectedMessage), findsNothing);
      verifyNever(() => vaults.planRemoval(any(), any()));
    });

    testWidgets('a replacement is refused while the phone still has no '
        'screen lock', (tester) async {
      backup.value = backupStatus(encrypted: false, exposed: true);
      when(
        () => vaults.checkPlatformBackup(),
      ).thenAnswer((_) async => backup.value);
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));

      await tester.tap(find.text(replaceSignInKeysLabel));
      await tester.pump();
      await tester.pump();

      expect(find.text(replaceNeedsScreenLockMessage), findsOneWidget);
      verifyNever(() => vaults.planRemoval(any(), any()));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('a replacement runs the rotation from this phone’s own '
        'key', (tester) async {
      backup.value = backupStatus(exposed: true);
      when(
        () => vaults.checkPlatformBackup(),
      ).thenAnswer((_) async => backup.value);
      final own = _slot(
        'p1',
        api.SocialVaultSlotKind.platform,
        'Android phone',
      );
      when(() => vaults.planRemoval(any(), 'p1')).thenAnswer(
        (_) async => SocialVaultRemovalPlan(
          removing: own,
          newPlatformSlot: true,
          passkeysToConfirm: const [],
          dropped: [own],
        ),
      );
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));

      await tester.tap(find.text(replaceSignInKeysLabel));
      // Not pumpAndSettle: the button spins for as long as the sheet is up.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // The same confirmation a removal shows, under its own title.
      expect(find.text('Replace sign-in keys?'), findsOneWidget);
      expect(find.textContaining('Removed: Android phone.'), findsOneWidget);
      verify(() => vaults.planRemoval(any(), 'p1')).called(1);

      // Backing out changes nothing.
      Navigator.of(
        tester.element(find.text('Replace sign-in keys?')),
      ).pop(false);
      await tester.pumpAndSettle();
      expect(find.text('Replace sign-in keys?'), findsNothing);
      verifyNever(
        () => vaults.rotateRemoving(
          vault: any(named: 'vault'),
          dataKey: any(named: 'dataKey'),
          plan: any(named: 'plan'),
        ),
      );
    });

    test('the line under a key never claims a Google backup it is not '
        'in', () {
      final platform = _slot('p1', api.SocialVaultSlotKind.platform, 'x');
      final passkey = _slot('k1', api.SocialVaultSlotKind.passkeyPrf, 'x');

      expect(signInKeyKind(passkey, onThisDevice: false), 'Passkey');
      expect(signInKeyKind(platform, onThisDevice: false), 'Device backup');
      expect(
        signInKeyKind(platform, onThisDevice: true),
        'Device backup · available on this device',
      );
      expect(
        signInKeyKind(platform, onThisDevice: true, cloudBacked: true),
        contains('encrypted Google backup'),
      );
      final paused = signInKeyKind(
        platform,
        onThisDevice: true,
        cloudBacked: false,
      );
      expect(paused, contains('On this phone only'));
      expect(paused, isNot(contains('Google')));
      expect(paused, isNot(contains('Device backup')));
    });

    test('the caveat of a paused backup does not describe a backup the key '
        'is not in', () {
      final paused = platformBackupCaveat(ios: false, paused: true);
      expect(paused, backupPausedMessage);
      expect(paused, isNot(contains('lives in Google’s backup')));
      expect(
        platformBackupCaveat(ios: false),
        contains('lives in Google’s backup'),
      );
      // iOS has no such state.
      expect(
        platformBackupCaveat(ios: true, paused: true),
        platformBackupCaveat(ios: true),
      );
    });
  });

  test('iOS device backup keys are said to be readable by every device on '
      'the Apple ID', () {
    final ios = platformBackupCaveat(ios: true);
    expect(ios, contains('Every device signed in to the same Apple ID'));
    expect(ios, contains('remove that device from your Apple ID'));
    expect(platformBackupCaveat(ios: false), isNot(contains('Apple ID')));
  });

  group('renaming a passkey', () {
    final passkeyVault = _vault([
      _slot('p1', api.SocialVaultSlotKind.platform, 'iCloud Keychain'),
      _slot('k1', api.SocialVaultSlotKind.passkeyPrf, 'Passkey · Pixel'),
    ]);

    /// While an action runs the screen's buttons spin, so nothing "settles":
    /// pump through the sheet's transition instead.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    final field = find.byKey(const ValueKey('rename-sign-in-key-field'));

    setUp(() {
      when(() => vaults.cached('vault-1')).thenAnswer(
        (_) async => CachedSocialVault(
          vault: passkeyVault,
          provider: 'google',
          emailHint: null,
        ),
      );
      when(
        () => vaults.renameSlot(any(), any(), any(), any()),
      ).thenAnswer((_) async => passkeyVault);
    });

    testWidgets('is offered for passkeys only, without the re-auth gate, and '
        'sends the new name', (tester) async {
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      // The passkey row has one; the device backup's label is the app's.
      expect(find.byTooltip('Rename'), findsOneWidget);

      await tester.tap(find.byTooltip('Rename'));
      await settle(tester);
      expect(find.text('Rename passkey'), findsOneWidget);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Passkey · Pixel',
      );
      await tester.enterText(field, 'Work phone');
      await tester.tap(find.text('Save'));
      await settle(tester);

      verify(
        () => vaults.renameSlot(passkeyVault, any(), 'k1', 'Work phone'),
      ).called(1);
      verifyNever(() => storage.loadAuthFactors());
      expect(find.text('Passkey renamed.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('Cancel, or an unchanged name, sends nothing', (tester) async {
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      await tester.tap(find.byTooltip('Rename'));
      await settle(tester);
      await tester.enterText(field, 'Work phone');
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      await tester.tap(find.byTooltip('Rename'));
      await settle(tester);
      await tester.tap(find.text('Save'));
      await settle(tester);

      verifyNever(() => vaults.renameSlot(any(), any(), any(), any()));
    });

    testWidgets('a wrong clock is said as such', (tester) async {
      when(() => vaults.renameSlot(any(), any(), any(), any())).thenThrow(
        const SocialVaultApiException(
          SocialVaultApiError.staleTimestamp,
          status: 401,
        ),
      );
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      await tester.tap(find.byTooltip('Rename'));
      await settle(tester);
      await tester.enterText(field, 'Work phone');
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(find.text(socialVaultClockMessage), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('is not offered by a device that cannot sign for the vault', (
      tester,
    ) async {
      when(
        () => vaults.hasUsableDataKey('vault-1'),
      ).thenAnswer((_) async => false);
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      expect(find.text('Passkey · Pixel'), findsOneWidget);
      expect(find.byTooltip('Rename'), findsNothing);
    });

    /// Opens the sheet, enters [typed] and saves; returns what was sent.
    Future<String> rename(WidgetTester tester, String typed) async {
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      await tester.tap(find.byTooltip('Rename'));
      await settle(tester);
      await tester.enterText(field, typed);
      await tester.tap(find.text('Save'));
      await settle(tester);
      final sent =
          verify(
                () => vaults.renameSlot(any(), any(), 'k1', captureAny()),
              ).captured.single
              as String;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      return sent;
    }

    testWidgets('the field keeps as many code points as the service takes, '
        'however many characters a reader counts', (tester) async {
      // One family emoji is seven code points and one character on screen:
      // ten of them are within a limit counted in characters and over the
      // service's, which counts code points.
      const family = '👨‍👩‍👧‍👦';
      expect(family.runes.length, 7);
      final sent = await rename(tester, family * 10);

      expect(sent, family * 9, reason: 'cut between characters, not in one');
      expect(
        sent.runes.length,
        lessThanOrEqualTo(SocialVaultService.maxSlotLabelLength),
      );
    });

    testWidgets('a long plain name is cut at the limit', (tester) async {
      final sent = await rename(tester, 'a' * 80);
      expect(sent, 'a' * SocialVaultService.maxSlotLabelLength);
    });

    testWidgets('control and direction characters are not kept, and a line '
        'break becomes a space', (tester) async {
      final sent = await rename(
        tester,
        '  Work\u2028phone\u202E\u2066\u200F\u061C\u0007\u009F\u2069\tx ',
      );
      expect(sent, 'Work phone x');
    });

    testWidgets('a name the service refuses is said as such, not as a lost '
        'connection', (tester) async {
      when(
        () => vaults.renameSlot(any(), any(), any(), any()),
      ).thenThrow(const SocialVaultLabelException(80));
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));
      await tester.tap(find.byTooltip('Rename'));
      await settle(tester);
      await tester.enterText(field, 'Work phone');
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(find.text(signInKeyNameTooLongMessage), findsOneWidget);
      expect(find.textContaining('connection'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('a name written elsewhere with line breaks is listed on one '
        'line, and prefilled as this app would keep it', (tester) async {
      when(() => vaults.cached('vault-1')).thenAnswer(
        (_) async => CachedSocialVault(
          vault: _vault([
            _slot('p1', api.SocialVaultSlotKind.platform, 'iCloud Keychain'),
            _slot(
              'k1',
              api.SocialVaultSlotKind.passkeyPrf,
              'Mine\n\n\u202EREMOVED\u202C',
            ),
          ]),
          provider: 'google',
          emailHint: null,
        ),
      );
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));

      final row = tester.widget<Text>(find.text('Mine REMOVED'));
      expect(row.maxLines, 1);
      expect(row.overflow, TextOverflow.ellipsis);

      await tester.tap(find.byTooltip('Rename'));
      await settle(tester);
      expect(tester.widget<TextField>(field).controller!.text, 'Mine  REMOVED');
      await tester.tap(find.text('Cancel'));
      await settle(tester);
    });
  });

  group('a key’s name inside a sentence', () {
    final long = _slot('k1', api.SocialVaultSlotKind.passkeyPrf, 'n' * 64);

    test('is one line, cut with an ellipsis', () {
      expect(signInKeyTitle(long), 'n' * 64);
      expect(signInKeyInlineTitle(long), '${'n' * 40}…');
      expect(
        signInKeyInlineTitle(
          _slot('k2', api.SocialVaultSlotKind.passkeyPrf, 'A\r\nB\u2028C'),
        ),
        'A B C',
      );
      // A name that is nothing but controls reads as the key's kind.
      expect(
        signInKeyTitle(
          _slot('k3', api.SocialVaultSlotKind.passkeyPrf, '\u202E\n'),
        ),
        'Passkey',
      );
    });

    test('a cut never splits a character', () {
      const family = '👨‍👩‍👧‍👦';
      expect(ellipsizeSignInKeyLabel(family * 3, 2), '${family * 2}…');
      expect(ellipsizeSignInKeyLabel('short', 40), 'short');
    });

    test('the removal confirmation names keys that way', () {
      final plan = SocialVaultRemovalPlan(
        removing: long,
        newPlatformSlot: false,
        passkeysToConfirm: [
          _slot('k2', api.SocialVaultSlotKind.passkeyPrf, 'Lap\ntop'),
        ],
        dropped: [long],
      );
      final text = signInKeyRemovalMessage(plan, false);
      expect(text, contains('Removed: ${'n' * 40}….\n'));
      expect(text, contains('Kept: Lap top (you confirm it next'));
    });

    testWidgets('the removal title names the key that way', (tester) async {
      when(() => vaults.cached('vault-1')).thenAnswer(
        (_) async => CachedSocialVault(
          vault: _vault([
            _slot('p1', api.SocialVaultSlotKind.platform, 'iCloud Keychain'),
            long,
          ]),
          provider: 'google',
          emailHint: null,
        ),
      );
      when(() => vaults.planRemoval(any(), 'k1')).thenAnswer(
        (_) async => SocialVaultRemovalPlan(
          removing: long,
          newPlatformSlot: true,
          passkeysToConfirm: const [],
          dropped: [long],
        ),
      );
      await pump(tester, const SignInKeysScreen(preAuthenticated: true));

      await tester.tap(find.byTooltip('Remove').last);
      // Not pumpAndSettle: the buttons spin for as long as the sheet is up.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Remove “${'n' * 40}…”?'), findsOneWidget);
      Navigator.of(tester.element(find.textContaining('Remove “'))).pop(false);
      await tester.pumpAndSettle();
    });
  });

  // Where no passkey can be added, the advice is acknowledged on the Sign-in
  // keys screen — which Settings opens too, not only the banner on Home.
  testWidgets('"I understand" on Sign-in keys takes the Home banner down '
      'without a restart', (tester) async {
    when(() => vaults.passkeysAvailable()).thenAnswer((_) async => false);
    when(() => vaults.changes).thenReturn(ValueNotifier<int>(0));
    when(() => vaults.cached('vault-1')).thenAnswer(
      (_) async => CachedSocialVault(
        vault: _vault([
          _slot('p1', api.SocialVaultSlotKind.platform, 'iCloud Keychain'),
        ]),
        provider: 'google',
        emailHint: null,
      ),
    );
    when(() => repo.getAccountViews()).thenAnswer((_) async => [linked]);
    final prefs = sl<PreferencesService>();
    final acknowledged = <String>{};
    when(
      () => prefs.socialVaultPlatformOnlyAcknowledged,
    ).thenAnswer((_) => {...acknowledged});
    when(() => prefs.acknowledgeSocialVaultPlatformOnly(any())).thenAnswer((
      invocation,
    ) async {
      acknowledged.add(invocation.positionalArguments.single as String);
    });

    // Home's banner, with the screen beside it as Settings would open it:
    // not through the banner's own tap, which reloads on its return.
    await pump(
      tester,
      const Column(
        children: [
          SocialVaultAttentionBanner(),
          Expanded(child: SignInKeysScreen(preAuthenticated: true)),
        ],
      ),
    );
    const bannerTitle = 'Add a passkey to your Google wallet';
    expect(find.text(bannerTitle), findsOneWidget);

    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();

    verify(() => prefs.acknowledgeSocialVaultPlatformOnly('vault-1')).called(1);
    expect(find.text(bannerTitle), findsNothing);
    expect(find.text('I understand'), findsNothing);
  });

  testWidgets('the last key cannot be removed', (tester) async {
    when(() => vaults.cached('vault-1')).thenAnswer(
      (_) async => CachedSocialVault(
        vault: _vault([
          _slot('p1', api.SocialVaultSlotKind.platform, 'Google backup'),
        ]),
        provider: 'google',
        emailHint: null,
      ),
    );
    await pump(tester, const SignInKeysScreen(preAuthenticated: true));
    expect(find.text('Google backup'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsNothing);
  });

  testWidgets('Your secrets lists a vault phrase and a legacy wallet\'s keys', (
    tester,
  ) async {
    when(
      () => storage.loadSocialVaultMnemonic('vault-1'),
    ).thenAnswer((_) async => 'abandon abandon about');
    await pump(tester, const ShowSecretsScreen(preAuthenticated: true));

    expect(find.text('Recovery phrases'), findsOneWidget);
    expect(find.text('Account 02 · Google'), findsOneWidget);
    expect(find.text('Private keys'), findsOneWidget);
    expect(find.text('Account 03 · Google · Solana'), findsOneWidget);
    expect(
      find.text('Account 03 · Google · Ethereum and Tezos'),
      findsOneWidget,
    );
    // Both key rows of the wallet from the older sign-in carry its mark; the
    // vault wallet's phrase row shows the plain Google icon.
    expect(_legacyMark, findsNWidgets(2));
    expect(find.byType(SocialProviderIcon), findsNWidgets(3));
  });

  test('the removal confirmation says what goes and what it cannot do', () {
    final plan = SocialVaultRemovalPlan(
      removing: _slot('k1', api.SocialVaultSlotKind.passkeyPrf, 'Old phone'),
      newPlatformSlot: true,
      passkeysToConfirm: [
        _slot('k2', api.SocialVaultSlotKind.passkeyPrf, 'Laptop'),
      ],
      dropped: [
        _slot('k1', api.SocialVaultSlotKind.passkeyPrf, 'Old phone'),
        _slot('p9', api.SocialVaultSlotKind.platform, 'Google backup · Pixel'),
      ],
    );
    final text = signInKeyRemovalMessage(plan, false);
    expect(text, contains('Removed: Old phone, Google backup · Pixel.'));
    expect(text, contains('Laptop (you confirm it next'));
    expect(text, contains('already unlocked this wallet keeps its keys'));
    expect(text, contains('move your funds to a new wallet'));
  });

  testWidgets('a phrase wallet without its phrase lists separate keys', (
    tester,
  ) async {
    when(
      () => storage.loadSocialVaultMnemonic('vault-1'),
    ).thenAnswer((_) async => null);
    when(
      () => storage.loadPrivateKey(any()),
    ).thenAnswer((i) async => 'key-${i.positionalArguments.first}');
    final phraseless = Account(
      id: 'phraseless',
      name: 'Account 04',
      kind: AccountKind.social,
      wallets: [
        _row('solana', 'SolP', vaultId: 'vault-1'),
        _row('ethereum', '0xp', vaultId: 'vault-1'),
        _row('tezos', 'tz1p', vaultId: 'vault-1'),
      ],
    );
    when(() => repo.getAccountViews()).thenAnswer((_) async => [phraseless]);
    await pump(tester, const ShowSecretsScreen(preAuthenticated: true));
    expect(find.text('Account 04 · Google · Ethereum'), findsOneWidget);
    expect(find.text('Account 04 · Google · Tezos'), findsOneWidget);
    expect(find.textContaining('Ethereum and Tezos'), findsNothing);
  });

  group('attention', () {
    test('lists a vault wallet without a passkey, and no wallet without a '
        'vault', () async {
      when(
        () => repo.getAccountViews(),
      ).thenAnswer((_) async => [linked, older, backupDeleted]);
      when(() => vaults.cached('vault-1')).thenAnswer(
        (_) async => CachedSocialVault(
          vault: _vault([
            _slot('p1', api.SocialVaultSlotKind.platform, 'iCloud Keychain'),
          ]),
          provider: 'google',
          emailHint: null,
        ),
      );
      final items = await loadSocialVaultAttention();
      expect(
        {for (final i in items) i.accountId: i.kind},
        {'linked': SocialVaultAttentionKind.noPasskey},
        reason:
            'a wallet from the older sign-in gets its one-time notice, never '
            'a banner',
      );
    });

    test('a paused phone backup comes first, and stays beside the passkey '
        'notice', () async {
      when(() => vaults.cached('vault-1')).thenAnswer((_) async => null);
      backup.value = backupStatus(encrypted: false);
      final items = await loadSocialVaultAttention();
      expect(items.map((i) => i.kind), [
        SocialVaultAttentionKind.backupPaused,
        SocialVaultAttentionKind.noPasskey,
      ]);

      // A passkey does not end a pause; a screen lock does.
      when(() => vaults.cached('vault-1')).thenAnswer(
        (_) async => CachedSocialVault(
          vault: _vault([
            _slot('k1', api.SocialVaultSlotKind.passkeyPrf, 'Passkey'),
          ]),
          provider: 'google',
          emailHint: null,
        ),
      );
      expect((await loadSocialVaultAttention()).map((i) => i.kind), [
        SocialVaultAttentionKind.backupPaused,
      ]);
      backup.value = backupStatus();
      expect(await loadSocialVaultAttention(), isEmpty);
    });

    test('a wallet this device has no record of is listed, not assumed to '
        'have a passkey', () async {
      when(() => vaults.cached('vault-1')).thenAnswer((_) async => null);
      final items = await loadSocialVaultAttention();
      expect(items.map((i) => i.accountId), ['linked']);
    });

    test('a passkey or an acknowledgement clears the passkey notice', () async {
      when(() => vaults.cached('vault-1')).thenAnswer(
        (_) async => CachedSocialVault(
          vault: _vault([
            _slot('k1', api.SocialVaultSlotKind.passkeyPrf, 'Passkey'),
          ]),
          provider: 'google',
          emailHint: null,
        ),
      );
      expect(await loadSocialVaultAttention(), isEmpty);

      when(() => vaults.cached('vault-1')).thenAnswer(
        (_) async => CachedSocialVault(
          vault: _vault([
            _slot('p1', api.SocialVaultSlotKind.platform, 'Backup'),
          ]),
          provider: 'google',
          emailHint: null,
        ),
      );
      when(
        () => sl<PreferencesService>().socialVaultPlatformOnlyAcknowledged,
      ).thenReturn({'vault-1'});
      expect(await loadSocialVaultAttention(), isEmpty);
    });
  });

  testWidgets('a device whose key no longer signs asks to sign in again', (
    tester,
  ) async {
    when(
      () => vaults.hasUsableDataKey('vault-1'),
    ).thenAnswer((_) async => false);
    when(() => vaults.cached('vault-1')).thenAnswer(
      (_) async => CachedSocialVault(
        vault: _vault([
          _slot('p1', api.SocialVaultSlotKind.platform, 'iCloud Keychain'),
          _slot('k1', api.SocialVaultSlotKind.passkeyPrf, 'Passkey'),
        ]),
        provider: 'google',
        emailHint: null,
      ),
    );
    await pump(tester, const SignInKeysScreen(preAuthenticated: true));
    expect(
      find.text(
        'Sign in again with Google on this device to manage these keys.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Remove'), findsNothing);
    expect(find.text('Add a passkey'), findsNothing);
  });

  testWidgets('two missing keys are not shown as one shared key', (
    tester,
  ) async {
    when(() => storage.loadPrivateKey(any())).thenAnswer((_) async => null);
    when(
      () => storage.loadSocialVaultMnemonic(any()),
    ).thenAnswer((_) async => null);
    await pump(tester, const ShowSecretsScreen(preAuthenticated: true));
    expect(find.textContaining('Ethereum and Tezos'), findsNothing);
    expect(find.text('Account 03 · Google · Ethereum'), findsOneWidget);
    expect(find.text('Account 03 · Google · Tezos'), findsOneWidget);
  });
}
