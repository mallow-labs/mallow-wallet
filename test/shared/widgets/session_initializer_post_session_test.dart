import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show LoginResult, User;
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/services/post_session_action_registry.dart';
import 'package:mallow_wallet/core/services/push_notification_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/session_initializer.dart';
import 'package:mocktail/mocktail.dart';

class _MockSession extends Mock implements SessionManager {}

class _MockAuth extends Mock implements AuthService {}

class _MockPush extends Mock implements PushNotificationService {}

const _loginResult = LoginResult(user: User());

class _MockCast extends MockBloc<CastEvent, CastState> implements CastBloc {}

class _MockLock extends MockBloc<AppLockEvent, AppLockState>
    implements AppLockBloc {}

WalletInfo _wallet(String id, String address, {String chain = 'solana'}) =>
    WalletInfo(
      id: id,
      address: address,
      name: id,
      walletType: WalletType.hd,
      chain: chain,
    );

void main() {
  late _MockSession session;
  late _MockAuth auth;
  late _MockPush push;
  late _MockLock lock;
  late _MockCast cast;
  late PostSessionActionRegistry registry;
  late List<VoidCallback> sessionListeners;
  late List<WalletInfo> wallets;
  late List<PostSessionTrigger> ran;

  setUp(() async {
    await sl.reset();
    session = _MockSession();
    auth = _MockAuth();
    push = _MockPush();
    lock = _MockLock();
    registry = PostSessionActionRegistry();
    cast = _MockCast();
    when(() => cast.state).thenReturn(const CastState.idle());
    when(() => cast.stream).thenAnswer((_) => const Stream.empty());
    sessionListeners = [];
    wallets = [_wallet('w1', 'SolOne')];
    ran = [];

    when(() => session.restore()).thenAnswer((_) async {});
    when(() => session.restoreActiveProfile()).thenAnswer((_) async {});
    when(() => session.warmProfileLookup()).thenAnswer((_) async {});
    when(() => session.sessionWallets).thenAnswer((_) => wallets);
    when(() => session.addListener(any())).thenAnswer(
      (i) => sessionListeners.add(i.positionalArguments.first as VoidCallback),
    );
    when(
      () => session.removeListener(any()),
    ).thenAnswer((i) => sessionListeners.remove(i.positionalArguments.first));
    when(() => auth.initializeSession()).thenAnswer((_) async => _loginResult);
    when(() => push.pendingDeepLink).thenReturn(ValueNotifier<String?>(null));
    when(() => push.initialize()).thenAnswer((_) async {});
    when(() => lock.state).thenReturn(const AppLockState.unlocked());
    when(() => lock.stream).thenAnswer((_) => const Stream.empty());

    sl
      ..registerSingleton<SessionManager>(session)
      ..registerSingleton<AuthService>(auth)
      ..registerSingleton<PushNotificationService>(push)
      ..registerSingleton<PostSessionActionRegistry>(registry)
      ..registerSingleton<CastBloc>(cast);
    final mine = ran;
    registry.register((context, trigger) => mine.add(trigger));
  });

  tearDown(() async {
    await sl.reset();
  });

  Future<void> pumpInitializer(WidgetTester tester) => tester.pumpWidget(
    BlocProvider<AppLockBloc>.value(
      value: lock,
      child: MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const SessionInitializer(child: Text('child')),
      ),
    ),
  );

  void notifySession() {
    for (final l in List.of(sessionListeners)) {
      l();
    }
  }

  testWidgets('fires ready once the session is up, and not before', (
    tester,
  ) async {
    await pumpInitializer(tester);
    expect(ran, isEmpty);
    await tester.pump();
    await tester.pump();
    expect(find.text('child'), findsOneWidget);
    expect(ran, [PostSessionTrigger.ready]);
    expect(registry.sessionEverReady, isTrue);
  });

  testWidgets('a resume fires resumed', (tester) async {
    await pumpInitializer(tester);
    await tester.pump();
    await tester.pump();
    ran.clear();

    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
    expect(ran, [PostSessionTrigger.resumed]);
  });

  testWidgets(
    'a signing Solana wallet joining the session fires the wallet trigger',
    (tester) async {
      await pumpInitializer(tester);
      await tester.pump();
      await tester.pump();
      ran.clear();

      // A repeat notification with the same wallets is nothing.
      notifySession();
      await tester.pump();
      expect(ran, isEmpty);

      wallets = [...wallets, _wallet('w2', 'SolTwo')];
      notifySession();
      await tester.pump();
      expect(ran, [PostSessionTrigger.signingSolanaWalletAdded]);

      // Non-Solana and view-only wallets do not count.
      ran.clear();
      wallets = [
        ...wallets,
        _wallet('e1', '0xabc', chain: 'ethereum'),
        const WalletInfo(
          id: 'v1',
          address: 'ViewOnly',
          name: 'v',
          walletType: WalletType.viewOnly,
          chain: 'solana',
        ),
      ];
      notifySession();
      await tester.pump();
      expect(ran, isEmpty);
    },
  );

  testWidgets('requestRun reaches the mounted initializer as requested', (
    tester,
  ) async {
    await pumpInitializer(tester);
    await tester.pump();
    await tester.pump();
    ran.clear();

    registry.requestRun();
    await tester.pump();
    expect(ran, [PostSessionTrigger.requested]);
  });

  testWidgets('a run requested before the session was ready runs once it is', (
    tester,
  ) async {
    registry.requestRun();
    await pumpInitializer(tester);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(ran.where((t) => t == PostSessionTrigger.requested), hasLength(1));
  });

  testWidgets('disposing detaches it from the registry and the session', (
    tester,
  ) async {
    await pumpInitializer(tester);
    await tester.pump();
    await tester.pump();
    expect(sessionListeners, hasLength(1));

    await tester.pumpWidget(const SizedBox());
    expect(sessionListeners, isEmpty);
  });
}
