import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../observability/app_logger.dart';
import '../router/app_router.dart';
import '../security/app_lock_bloc.dart';

const _tag = 'PostSessionActionRegistry';

/// Why an action is being run.
enum PostSessionTrigger {
  /// A session has just become ready.
  ready,

  /// The app came back to the foreground.
  resumed,

  /// A Solana wallet that can sign has entered the session's wallets.
  signingSolanaWalletAdded,

  /// Someone called [PostSessionActionRegistry.requestRun], or a run that was
  /// held back by the app lock is being released.
  requested,
}

/// Work to do once a session is up, at the moments [PostSessionTrigger] names.
///
/// Called with a context that is mounted at the time. Do not keep it: the
/// registry hands over a fresh one on every run, and it can belong to any of
/// several mounted sessions, so an action must tolerate being run more than once
/// for the same moment.
typedef PostSessionAction =
    void Function(BuildContext context, PostSessionTrigger trigger);

/// A mounted owner of a session that can run post-session actions.
///
/// Implemented by `SessionInitializer`'s state.
abstract interface class PostSessionRunner {
  /// The context actions run with.
  BuildContext get runnerContext;

  /// True once this runner's session is ready and the runner is still mounted.
  bool get runnerReady;
}

/// Extension point for work that must run once the session is ready, and not
/// while the app is locked.
///
/// Inert until an action registers. `SessionInitializer` fires the triggers and
/// listens for [runRequests]; this class owns everything those need to agree on:
/// the lock gate, the deferral, and the fallback for the stretch where no
/// `SessionInitializer` is mounted.
@lazySingleton
class PostSessionActionRegistry {
  final List<PostSessionAction> _actions = [];
  final List<VoidCallback> _resetListeners = [];
  final Set<PostSessionRunner> _runners = {};
  final ValueNotifier<int> _runRequests = ValueNotifier<int>(0);

  bool _sessionEverReady = false;
  bool _requestedBeforeReady = false;
  StreamSubscription<AppLockState>? _lockSub;
  _ResumeObserver? _observer;

  /// Bumped by [requestRun] when a mounted, ready runner can take it.
  /// `SessionInitializer` listens, as it listens to `pendingDeepLink`, and runs
  /// the actions with its own context.
  Listenable get runRequests => _runRequests;

  /// True once any session has been ready in this process, until [reset].
  bool get sessionEverReady => _sessionEverReady;

  /// Adds [action].
  void register(PostSessionAction action) => _actions.add(action);

  /// Removes [action]. For tests.
  void unregister(PostSessionAction action) => _actions.remove(action);

  /// Calls [listener] when [reset] runs: a logout or an app reset. A feature
  /// holding per-user state drops it here.
  void addResetListener(VoidCallback listener) => _resetListeners.add(listener);

  /// Removes [listener]. For tests.
  void removeResetListener(VoidCallback listener) =>
      _resetListeners.remove(listener);

  /// Records a mounted runner. It takes runs once it reports ready.
  void attach(PostSessionRunner runner) => _runners.add(runner);

  /// Forgets [runner]. Call when it is disposed.
  void detach(PostSessionRunner runner) => _runners.remove(runner);

  /// Called by a runner when its session becomes ready. Records that a session
  /// has been ready in this process, and releases a run that was requested
  /// before any session was.
  void sessionReady(PostSessionRunner runner) {
    _sessionEverReady = true;
    _observer ??= _ResumeObserver(this)..start();
    if (_requestedBeforeReady) {
      _requestedBeforeReady = false;
      dispatch(runner.runnerContext, PostSessionTrigger.requested);
    }
  }

  /// Clears the "a session has been ready" record, as a logout or app reset
  /// must, and tells the reset listeners.
  void reset() {
    _sessionEverReady = false;
    _requestedBeforeReady = false;
    _lockSub?.cancel();
    _lockSub = null;
    for (final listener in List.of(_resetListeners)) {
      try {
        listener();
      } catch (e) {
        AppLogger.error(_tag, 'Reset listener threw', e);
      }
    }
  }

  /// Asks for every action to run again with [PostSessionTrigger.requested].
  ///
  /// - Before any session has been ready, the request is kept and the next
  ///   runner to become ready runs it once.
  /// - With a mounted, ready runner, it is handed to that runner through
  ///   [runRequests].
  /// - With none, the actions run with the root navigator's context.
  void requestRun() {
    if (!_sessionEverReady) {
      _requestedBeforeReady = true;
      return;
    }
    if (_readyRunners.isNotEmpty) {
      _runRequests.value = _runRequests.value + 1;
      return;
    }
    final context = AppRoutes.rootNavigatorKey.currentContext;
    if (context == null) return;
    dispatch(context, PostSessionTrigger.requested);
  }

  /// Runs the actions for [trigger] with [context], after the next frame and
  /// only when the app is not locked.
  ///
  /// The lock decision is taken in a post-frame callback, never in the trigger
  /// itself. The app locks a resume by adding an event to `AppLockBloc` from its
  /// own `resumed` handler, and the bloc emits the locked state a microtask
  /// later, so a synchronous read in the same dispatch still sees "unlocked".
  void dispatch(BuildContext context, PostSessionTrigger trigger) {
    _afterFrame(() {
      if (!context.mounted) return;
      _decide(context, trigger);
    });
  }

  Iterable<PostSessionRunner> get _readyRunners =>
      _runners.where((r) => r.runnerReady);

  void _decide(BuildContext context, PostSessionTrigger trigger) {
    final lock = _lockState(context);
    if (lock is AppLockStateLocked || lock is AppLockStateUninitialized) {
      _deferUntilUnlocked(context);
      return;
    }
    _runActions(context, trigger);
  }

  AppLockState? _lockState(BuildContext context) {
    try {
      return context.read<AppLockBloc>().state;
    } catch (_) {
      // No lock bloc above this context: nothing can be locked.
      return null;
    }
  }

  /// Holds a run until the lock bloc leaves locked / uninitialized, then runs it
  /// once with [PostSessionTrigger.requested]. A second deferral while one is
  /// waiting is the same run.
  void _deferUntilUnlocked(BuildContext context) {
    if (_lockSub != null) return;
    final AppLockBloc bloc;
    try {
      bloc = context.read<AppLockBloc>();
    } catch (_) {
      return;
    }
    _lockSub = bloc.stream.listen((state) {
      if (state is AppLockStateLocked || state is AppLockStateUninitialized) {
        return;
      }
      _lockSub?.cancel();
      _lockSub = null;
      _afterFrame(() {
        final target = _liveContext(context);
        if (target != null) _decide(target, PostSessionTrigger.requested);
      });
    });
  }

  /// A mounted context to run a released deferral with: a ready runner's, else
  /// the root navigator's, else [preferred] when it is still mounted.
  BuildContext? _liveContext(BuildContext preferred) {
    for (final runner in _readyRunners) {
      final context = runner.runnerContext;
      if (context.mounted) return context;
    }
    final root = AppRoutes.rootNavigatorKey.currentContext;
    if (root != null && root.mounted) return root;
    return preferred.mounted ? preferred : null;
  }

  void _runActions(BuildContext context, PostSessionTrigger trigger) {
    for (final action in List.of(_actions)) {
      try {
        action(context, trigger);
      } catch (e, st) {
        AppLogger.error(_tag, 'Post-session action threw', e, st);
      }
    }
  }

  void _afterFrame(VoidCallback callback) {
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) => callback());
    binding.scheduleFrame();
  }

  /// The resume fallback for the stretch where no `SessionInitializer` is
  /// mounted (a notification tap lands on a top-level route and removes every
  /// tab page).
  void _onResumed() {
    if (!_sessionEverReady || _actions.isEmpty) return;
    if (_readyRunners.isNotEmpty) return;
    final context = AppRoutes.rootNavigatorKey.currentContext;
    if (context == null) return;
    dispatch(context, PostSessionTrigger.resumed);
  }
}

class _ResumeObserver with WidgetsBindingObserver {
  _ResumeObserver(this._registry);

  final PostSessionActionRegistry _registry;

  void start() => WidgetsBinding.instance.addObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _registry._onResumed();
  }
}
