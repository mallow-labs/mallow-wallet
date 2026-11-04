import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/services/post_session_action_registry.dart';

class _MockLockBloc extends MockBloc<AppLockEvent, AppLockState>
    implements AppLockBloc {}

/// Stands in for `SessionInitializer`: attaches itself, listens for run
/// requests as the real one does, and reports ready on demand.
class _Runner extends StatefulWidget {
  const _Runner({required this.registry, super.key});

  final PostSessionActionRegistry registry;

  @override
  State<_Runner> createState() => _RunnerState();
}

class _RunnerState extends State<_Runner> implements PostSessionRunner {
  bool ready = false;

  @override
  BuildContext get runnerContext => context;

  @override
  bool get runnerReady => mounted && ready;

  @override
  void initState() {
    super.initState();
    widget.registry.attach(this);
    widget.registry.runRequests.addListener(_onRequest);
  }

  void _onRequest() {
    if (!ready || !mounted) return;
    widget.registry.dispatch(context, PostSessionTrigger.requested);
  }

  void markReady() {
    ready = true;
    widget.registry.sessionReady(this);
    widget.registry.dispatch(context, PostSessionTrigger.ready);
  }

  @override
  void dispose() {
    widget.registry.runRequests.removeListener(_onRequest);
    widget.registry.detach(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  late PostSessionActionRegistry registry;
  late _MockLockBloc lock;
  late StreamController<AppLockState> lockStates;
  late List<PostSessionTrigger> ran;
  final runnerKey = GlobalKey<_RunnerState>();

  setUp(() {
    registry = PostSessionActionRegistry();
    lock = _MockLockBloc();
    lockStates = StreamController<AppLockState>.broadcast();
    final mine = <PostSessionTrigger>[];
    ran = mine;
    var current = const AppLockState.unlocked();
    when(() => lock.state).thenAnswer((_) => current);
    when(() => lock.stream).thenAnswer((_) => lockStates.stream);
    // Captured, not read through `ran`: an earlier test's registry keeps its
    // lifecycle observer for the life of the binding.
    registry.register((context, trigger) => mine.add(trigger));
    addTearDown(lockStates.close);
    // Lets a test change what `lock.state` answers.
    _setLock = (s) {
      current = s;
      lockStates.add(s);
    };
  });

  Future<void> pumpApp(WidgetTester tester, {bool withRunner = true}) async {
    await tester.pumpWidget(
      BlocProvider<AppLockBloc>.value(
        value: lock,
        child: MaterialApp(
          navigatorKey: AppRoutes.rootNavigatorKey,
          home: withRunner
              ? _Runner(key: runnerKey, registry: registry)
              : const SizedBox(),
        ),
      ),
    );
  }

  testWidgets('runs actions with the ready trigger, after a frame', (
    tester,
  ) async {
    await pumpApp(tester);
    runnerKey.currentState!.markReady();
    expect(ran, isEmpty, reason: 'the lock decision is taken post-frame');
    await tester.pump();
    expect(ran, [PostSessionTrigger.ready]);
    expect(registry.sessionEverReady, isTrue);
  });

  testWidgets('a run requested before any session is ready waits for one', (
    tester,
  ) async {
    await pumpApp(tester);
    registry.requestRun();
    await tester.pump();
    expect(ran, isEmpty);

    runnerKey.currentState!.markReady();
    await tester.pump();
    expect(
      ran,
      containsAll([PostSessionTrigger.requested, PostSessionTrigger.ready]),
    );
    expect(ran.where((t) => t == PostSessionTrigger.requested), hasLength(1));
  });

  testWidgets('requestRun reaches a ready runner as requested', (tester) async {
    await pumpApp(tester);
    runnerKey.currentState!.markReady();
    await tester.pump();
    ran.clear();

    registry.requestRun();
    await tester.pump();
    expect(ran, [PostSessionTrigger.requested]);
  });

  testWidgets(
    'with no runner mounted it runs with the root navigator context',
    (tester) async {
      await pumpApp(tester);
      runnerKey.currentState!.markReady();
      await tester.pump();
      ran.clear();

      // Every tab page is gone, as after a notification tap's `go`.
      await tester.pumpWidget(
        BlocProvider<AppLockBloc>.value(
          value: lock,
          child: MaterialApp(
            navigatorKey: AppRoutes.rootNavigatorKey,
            home: const SizedBox(),
          ),
        ),
      );
      registry.requestRun();
      await tester.pump();
      expect(ran, [PostSessionTrigger.requested]);
    },
  );

  testWidgets('a resume with no runner mounted runs as resumed', (
    tester,
  ) async {
    await pumpApp(tester);
    runnerKey.currentState!.markReady();
    await tester.pump();
    await tester.pumpWidget(
      BlocProvider<AppLockBloc>.value(
        value: lock,
        child: MaterialApp(
          navigatorKey: AppRoutes.rootNavigatorKey,
          home: const SizedBox(),
        ),
      ),
    );
    ran.clear();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(ran, [PostSessionTrigger.resumed]);
  });

  testWidgets('while locked a run is deferred, then runs once as requested', (
    tester,
  ) async {
    await pumpApp(tester);
    runnerKey.currentState!.markReady();
    await tester.pump();
    ran.clear();

    _setLock(const AppLockState.locked());
    registry.requestRun();
    registry.requestRun();
    await tester.pump();
    expect(ran, isEmpty);

    _setLock(const AppLockState.unlocked());
    await tester.pump();
    await tester.pump();
    expect(ran, [PostSessionTrigger.requested]);
  });

  testWidgets('an uninitialized lock defers as well', (tester) async {
    _setLock(const AppLockState.uninitialized());
    await pumpApp(tester);
    runnerKey.currentState!.markReady();
    await tester.pump();
    expect(ran, isEmpty);

    _setLock(const AppLockState.noPinSet());
    await tester.pump();
    await tester.pump();
    expect(ran, [PostSessionTrigger.requested]);
  });

  testWidgets('the lock is read after the frame, not in the trigger', (
    tester,
  ) async {
    await pumpApp(tester);
    runnerKey.currentState!.markReady();
    await tester.pump();
    ran.clear();

    // The resume that locks: the trigger fires while the bloc still reads
    // unlocked, and the locked state lands before the frame ends.
    registry.dispatch(runnerKey.currentContext!, PostSessionTrigger.resumed);
    _setLock(const AppLockState.locked());
    await tester.pump();
    expect(ran, isEmpty);
  });

  testWidgets('reset forgets the session and tells its listeners', (
    tester,
  ) async {
    await pumpApp(tester);
    runnerKey.currentState!.markReady();
    await tester.pump();
    var resets = 0;
    registry.addResetListener(() => resets++);

    registry.reset();
    expect(resets, 1);
    expect(registry.sessionEverReady, isFalse);

    // After a reset a request waits for the next ready session again.
    ran.clear();
    registry.requestRun();
    await tester.pump();
    expect(ran, isEmpty);
  });

  testWidgets('an action that throws does not stop the others', (tester) async {
    registry.register((context, trigger) => throw StateError('boom'));
    var second = 0;
    registry.register((context, trigger) => second++);
    await pumpApp(tester);
    runnerKey.currentState!.markReady();
    await tester.pump();
    expect(second, 1);
  });
}

late void Function(AppLockState) _setLock;
