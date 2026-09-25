import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/router/auth_state_notifier.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/app_reset_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/features/onboarding/screens/wallet_recovery_screen.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockAuthNotifier extends Mock implements AuthStateNotifier {}

class _MockWalletRepo extends Mock implements WalletRepository {}

class _MockResetService extends Mock implements AppResetService {}

class _MockAppLockBloc extends MockBloc<AppLockEvent, AppLockState>
    implements AppLockBloc {}

/// The reinstall Restore screen is the one place a user can wipe the device
/// *before* proving they hold the phrase (AppLock is `noPinSet` here). It is
/// also where a user lands after a database quarantine they did not cause. So
/// "Start fresh" must never act on one tap, a restore that cannot read every
/// secret must write nothing and say so, and a successful restore must re-arm
/// the lock rather than treat restoring as authentication.
void main() {
  late _MockStorage storage;
  late _MockAuthNotifier authNotifier;
  late _MockWalletRepo walletRepo;
  late _MockResetService resetService;
  late _MockAppLockBloc appLock;
  final sl = GetIt.instance;

  setUpAll(() {
    registerFallbackValue(const AppLockEvent.init());
    registerFallbackValue(ResetReason.startFresh);
  });

  setUp(() {
    storage = _MockStorage();
    authNotifier = _MockAuthNotifier();
    walletRepo = _MockWalletRepo();
    resetService = _MockResetService();
    appLock = _MockAppLockBloc();
    whenListen(
      appLock,
      const Stream<AppLockState>.empty(),
      initialState: const AppLockState.noPinSet(),
    );

    for (final unregister in [
      () => sl.isRegistered<SecureWalletStorage>()
          ? sl.unregister<SecureWalletStorage>()
          : null,
      () => sl.isRegistered<AuthStateNotifier>()
          ? sl.unregister<AuthStateNotifier>()
          : null,
      () => sl.isRegistered<WalletRepository>()
          ? sl.unregister<WalletRepository>()
          : null,
    ]) {
      unregister();
    }
    sl.registerFactory<SecureWalletStorage>(() => storage);
    sl.registerFactory<AuthStateNotifier>(() => authNotifier);
    sl.registerFactory<WalletRepository>(() => walletRepo);

    when(() => authNotifier.clearStaleKeychain()).thenReturn(null);
    when(() => authNotifier.onWalletCreated()).thenReturn(null);
    when(() => authNotifier.onOnboardingCompleted()).thenAnswer((_) async {});
    when(() => authNotifier.onLogout()).thenAnswer((_) async {});
    when(
      () => resetService.resetApp(reason: any(named: 'reason')),
    ).thenAnswer((_) async => const []);
  });

  tearDown(() {
    sl.unregister<SecureWalletStorage>();
    sl.unregister<AuthStateNotifier>();
    sl.unregister<WalletRepository>();
  });

  Widget build({required List<String> visited}) {
    final router = GoRouter(
      initialLocation: '/wallet-recovery',
      routes: [
        GoRoute(
          path: '/wallet-recovery',
          builder: (_, _) => WalletRecoveryScreen(resetService: resetService),
        ),
        GoRoute(
          path: '/',
          builder: (_, _) {
            visited.add('/');
            return const Scaffold(body: Text('home'));
          },
        ),
        GoRoute(
          path: '/welcome',
          builder: (_, _) {
            visited.add('/welcome');
            return const Scaffold(body: Text('welcome'));
          },
        ),
      ],
    );
    return BlocProvider<AppLockBloc>.value(
      value: appLock,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  Finder eraseButton() => find.text('Erase and start fresh');

  testWidgets('Start fresh expands a gate; Erase stays inert until the '
      'checkbox is ticked, and Cancel collapses it', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final visited = <String>[];

    await tester.pumpWidget(build(visited: visited));
    await tester.pumpAndSettle();

    // Nothing destructive on the first screen.
    expect(eraseButton(), findsNothing);
    await tester.tap(find.text('Start fresh'));
    await tester.pumpAndSettle();
    expect(eraseButton(), findsOneWidget);
    expect(find.text('I have my recovery phrase saved'), findsOneWidget);

    // Tapping Erase before ticking the box does nothing.
    await tester.tap(eraseButton());
    await tester.pumpAndSettle();
    verifyNever(() => resetService.resetApp(reason: any(named: 'reason')));
    expect(visited, isEmpty);

    // Cancel returns to the two-button layout with the box cleared.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(eraseButton(), findsNothing);
    expect(find.text('Restore wallet'), findsOneWidget);
  });

  testWidgets('ticking the box arms Erase, which runs the reset and routes '
      'to Welcome', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final visited = <String>[];

    await tester.pumpWidget(build(visited: visited));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start fresh'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I have my recovery phrase saved'));
    await tester.pumpAndSettle();

    await tester.tap(eraseButton());
    await tester.pumpAndSettle();

    verify(
      () => resetService.resetApp(reason: ResetReason.startFresh),
    ).called(1);
    verify(() => authNotifier.onLogout()).called(1);
    // The wipe deleted the PIN hash the lock verifies against, so the live
    // bloc must stop reporting an unlocked-with-PIN session. Left in place it
    // raises the LockScreen overlay on the next background — over Welcome, on
    // a device where no PIN can dismiss it.
    verify(() => appLock.add(const AppLockEvent.reset())).called(1);
    expect(visited, ['/welcome']);
  });

  testWidgets('a partial wipe warns once and still routes to Welcome', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final visited = <String>[];
    when(() => resetService.resetApp(reason: any(named: 'reason'))).thenAnswer(
      (_) async => const [EraseFailure('secure.mnemonic', 'PlatformException')],
    );

    await tester.pumpWidget(build(visited: visited));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start fresh'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I have my recovery phrase saved'));
    await tester.pumpAndSettle();

    await tester.tap(eraseButton());
    await tester.pumpAndSettle();

    // Whatever survived the wipe, most of it is gone: staying here would offer
    // Restore over secrets that no longer exist, and the PIN hash the lock
    // verifies against was deleted either way.
    verify(() => appLock.add(const AppLockEvent.reset())).called(1);
    expect(visited, ['/welcome']);
    // Warned once, not twice — the logout is best-effort by contract and has
    // no failure of its own to add.
    expect(
      find.text('Some data could not be erased. Please try again.'),
      findsOneWidget,
    );
    // Without clearing the stale-Keychain flag first, the router reads the
    // leftover Keychain state and sends the user straight back to this screen.
    verifyInOrder([
      () => authNotifier.clearStaleKeychain(),
      () => authNotifier.onLogout(),
    ]);
  });

  testWidgets('an aborted restore writes nothing, shows why, and offers a '
      'retry', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final visited = <String>[];
    when(() => storage.loadAccountGraph()).thenAnswer((_) async => '{"v":3}');
    when(() => walletRepo.restoreFromGraph(any())).thenAnswer(
      (_) async => const RestoreAborted(
        missingSeedPhrases: 1,
        totalSeedPhrases: 2,
        missingImportedKeys: 0,
        totalImportedKeys: 0,
      ),
    );

    await tester.pumpWidget(build(visited: visited));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore wallet'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 of 2 seed phrases'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(visited, isEmpty);
    // Restoring did not complete onboarding or touch the lock.
    verifyNever(() => authNotifier.onOnboardingCompleted());
    verifyNever(() => appLock.add(any()));
  });

  // The abort is right by default, but it is also permanent: one entry whose
  // secret never reads again blocks every restore, and the only other action
  // on this screen erases the readable seeds' vault items too. So an abort
  // that still has something readable offers the partial restore — and one
  // that has nothing readable must not, because it would write no rows and
  // report success.
  testWidgets('an abort with readable data offers a partial restore that '
      'completes like any other', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final visited = <String>[];
    when(() => storage.loadAccountGraph()).thenAnswer((_) async => '{"v":3}');
    when(
      () => walletRepo.restoreFromGraph(
        any(),
        readableOnly: any(named: 'readableOnly'),
      ),
    ).thenAnswer(
      (inv) async => inv.namedArguments[#readableOnly] == true
          ? const RestoreRestored(
              seedPhrases: 1,
              wallets: 3,
              skippedSeedPhrases: 1,
            )
          : const RestoreAborted(
              missingSeedPhrases: 1,
              totalSeedPhrases: 2,
              missingImportedKeys: 0,
              totalImportedKeys: 0,
              readableWallets: 3,
            ),
    );

    await tester.pumpWidget(build(visited: visited));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore wallet'));
    await tester.pumpAndSettle();

    expect(find.text('Restore what can be read'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    // The copy names the button that is actually here.
    expect(
      find.textContaining('restore only what can be read'),
      findsOneWidget,
    );

    await tester.tap(find.text('Restore what can be read'));
    await tester.pumpAndSettle();

    verify(
      () => walletRepo.restoreFromGraph(any(), readableOnly: true),
    ).called(1);
    // A partial restore is still a restore: the lock is re-armed rather than
    // treating "I restored something" as authentication.
    verify(() => appLock.add(const AppLockEvent.init())).called(1);
    verify(() => authNotifier.onOnboardingCompleted()).called(1);
    expect(visited, ['/']);
  });

  testWidgets('an abort with nothing readable does not offer it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final visited = <String>[];
    when(() => storage.loadAccountGraph()).thenAnswer((_) async => '{"v":3}');
    when(
      () => walletRepo.restoreFromGraph(
        any(),
        readableOnly: any(named: 'readableOnly'),
      ),
    ).thenAnswer(
      (_) async => const RestoreAborted(
        missingSeedPhrases: 1,
        totalSeedPhrases: 1,
        missingImportedKeys: 0,
        totalImportedKeys: 0,
      ),
    );

    await tester.pumpWidget(build(visited: visited));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore wallet'));
    await tester.pumpAndSettle();

    expect(find.text('Restore what can be read'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Start fresh'), findsOneWidget);
    // And the copy does not send the user looking for it. Offering an action
    // the screen withholds reads as a bug in the screen, and the two actions
    // it does have are the ones that matter: try again, or erase.
    expect(find.textContaining('restore only what can be read'), findsNothing);
    expect(
      find.textContaining(
        'Try again, or start fresh and import your recovery phrase.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a successful restore re-arms the app lock and goes home', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final visited = <String>[];
    when(() => storage.loadAccountGraph()).thenAnswer((_) async => '{"v":3}');
    when(() => walletRepo.restoreFromGraph(any())).thenAnswer(
      (_) async => const RestoreRestored(seedPhrases: 1, wallets: 3),
    );

    await tester.pumpWidget(build(visited: visited));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore wallet'));
    await tester.pumpAndSettle();

    // Regression guard: without the re-init a reinstall left the session in
    // noPinSet, so anyone holding the phone could restore and spend without
    // the PIN/biometric that still exist in the Keychain.
    verify(() => appLock.add(const AppLockEvent.init())).called(1);
    verify(() => authNotifier.onOnboardingCompleted()).called(1);
    expect(visited, ['/']);
  });
}
