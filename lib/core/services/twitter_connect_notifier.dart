import 'dart:async';

import 'package:dio/dio.dart' show DioException;
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:shared_preferences/shared_preferences.dart';

import '../../di.dart';
import '../network/auth_service.dart';

/// Outcome of an X (Twitter) connect round trip, parsed from the
/// `https://mallow.art/auth/callback?twitter=…` app-link redirect and, for
/// `twitter=confirm`, from the `POST /v2/twitter/complete` that follows it.
enum TwitterConnectStatus {
  /// Account linked successfully.
  success,

  /// The X account is already linked to a different mallow account.
  userExists,

  /// The connect was started by a different wallet than the one signed in
  /// now (`403` from complete). Only that wallet can finish it.
  otherWallet,

  /// The completion token is unknown or expired (`400` from complete).
  expired,

  /// Any other failure (`twitter=error`, an unrecognised value, or a complete
  /// call that failed for another reason).
  error,
}

/// Finishes a connect: `POST /v2/twitter/complete` with the callback's token.
/// Throws what the API client throws.
typedef TwitterConnectCompleter = Future<void> Function(String token);

/// Completes with true once a wallet is logged in, or with false when none is
/// after [limit].
typedef TwitterConnectSessionGate = Future<bool> Function(Duration limit);

/// Bridges the X connect app-link callback to whatever screen started the flow.
///
/// Connecting leaves the app for the system browser and returns via the
/// `/auth/callback?twitter=…` app link, which [DeepLinkService] captures. That
/// handler has no reference to the open EditProfileScreen, so it publishes the
/// parsed outcome here; the screen subscribes while mounted to refresh its
/// linked-account state and surface a toast.
///
/// The backend callback does not link the account. It redirects with
/// `twitter=confirm&token=…`, and this class finishes the link on the signed
/// `POST /v2/twitter/complete`, which links only for the wallet that started
/// the flow. The call is made here, not in the screen, so the link still
/// completes when the screen is gone.
///
/// Gone can mean the whole process: the browser round trip can outlive the
/// app, and the link then starts it cold. Two things follow, and both are
/// handled here rather than in the link handler, which has no session to wait
/// on and no screen to tell:
///
/// * The link is handled as the router boots, before the app is unlocked and
///   the wallet logged in. The complete call needs that login, so it waits for
///   it ([_sessionReady]) instead of going out unauthenticated and failing.
/// * Nobody is listening to [results] yet. The outcome is held and handed to
///   the next listener — the screen that started the connect, when the user
///   next opens it — so a failure is not silent and a success still refreshes
///   the linked handle.
@lazySingleton
class TwitterConnectNotifier {
  TwitterConnectNotifier()
    : _complete = _completeViaApi,
      _sessionReady = _sessionViaAuth;

  /// [sessionReady] defaults to "already logged in".
  @visibleForTesting
  TwitterConnectNotifier.withCompleter(
    this._complete, {
    TwitterConnectSessionGate? sessionReady,
  }) : _sessionReady = sessionReady ?? ((_) async => true);

  final TwitterConnectCompleter _complete;
  final TwitterConnectSessionGate _sessionReady;

  late final _controller = StreamController<TwitterConnectStatus>.broadcast(
    onListen: _deliverHeldOutcome,
  );

  /// The outcome of a connect that finished while nothing was listening to
  /// [results], kept for the next listener. In memory only: it describes this
  /// run's connect, and a restart has nothing left to report.
  TwitterConnectStatus? _heldOutcome;

  /// The shape of a completion token: 32 lowercase hex characters. Anything
  /// else cannot be one, so it is never sent.
  static final _tokenShape = RegExp(r'^[0-9a-f]{32}$');

  /// True while a callback link is being finished — the wait for a login, if
  /// there is one, then `POST /v2/twitter/complete` — so the screen that
  /// started the connect can show it is busy.
  final ValueNotifier<bool> completing = ValueNotifier(false);

  /// Completion tokens already sent. A token is single-use server-side, so a
  /// second delivery of the same link (the OS replays a cold-start link) would
  /// come back `400` and show "expired" over the success it just reported.
  /// A `401` or a failure with no response leaves the token unspent, so those
  /// drop it again and the same link can be retried.
  final Set<String> _sentTokens = {};

  /// Until when (epoch ms) a connect the user started on this install may
  /// still come back. Persisted, because the browser round trip can outlive
  /// the process.
  static const _pendingKey = 'x_connect_pending_until';

  /// How long a started connect waits for its link: the user's own time on
  /// X's sign-in and consent pages, then [completionTokenLifetime] after the
  /// callback, with room to spare.
  static const pendingWindow = Duration(minutes: 30);

  /// How long a completion token is worth sending after its callback. A link
  /// that waits longer than this for a login is dropped.
  static const completionTokenLifetime = Duration(minutes: 10);

  /// Records that the user just opened the X authorize page from this install.
  /// Only then is a `twitter=confirm` link acted on.
  Future<void> markConnectStarted() async {
    // A new attempt: what the last one came to is no longer news.
    _heldOutcome = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _pendingKey,
      DateTime.now().add(pendingWindow).millisecondsSinceEpoch,
    );
  }

  Future<bool> _hasPendingConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt(_pendingKey);
    return until != null && DateTime.now().millisecondsSinceEpoch < until;
  }

  /// Withdraws a [markConnectStarted] whose browser never opened, so no
  /// later link is taken for it.
  Future<void> cancelConnectStarted() => _clearPendingConnect();

  Future<void> _clearPendingConnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingKey);
  }

  /// Outcomes emitted as connect round trips complete.
  ///
  /// An outcome that arrived while nothing was listening is delivered to the
  /// first listener to subscribe after it, once.
  Stream<TwitterConnectStatus> get results => _controller.stream;

  /// Publish [status] to the listening screen, or hold it for the next one.
  ///
  /// Held only when [startedHere]: any page can open a `?twitter=error` link,
  /// and one this install never asked for must not turn into a failure message
  /// the next time the user opens their profile.
  void _publish(TwitterConnectStatus status, {required bool startedHere}) {
    if (_controller.isClosed) return;
    if (_controller.hasListener) {
      _heldOutcome = null;
      _controller.add(status);
    } else if (startedHere) {
      _heldOutcome = status;
    }
  }

  void _deliverHeldOutcome() {
    final held = _heldOutcome;
    if (held == null) return;
    _heldOutcome = null;
    _controller.add(held);
  }

  /// Map the raw `twitter` query value to a status and publish it.
  ///
  /// `confirm` carries [token], the one-time completion token. It is sent to
  /// `POST /v2/twitter/complete` and the response decides the status. The
  /// signature that call needs is handled by the shared 401 re-sign; the login
  /// it needs is waited for, up to [completionTokenLifetime], because a link
  /// that started the app arrives before any wallet is logged in. A wait that
  /// runs out reports [TwitterConnectStatus.expired] without sending: the
  /// token is dead by then.
  ///
  /// 🛑 `confirm` is acted on only while this install has a connect the user
  /// started ([markConnectStarted], within [pendingWindow]). Any page can open
  /// the link, and without that check it would make the app send a signed
  /// request — and on a hardware wallet ask for a signature — for a connect
  /// nobody here started. Otherwise the link is ignored: no request, no
  /// status. Every final outcome clears the pending connect.
  Future<void> emitFromCallback(String rawValue, {String? token}) async {
    final startedHere = await _hasPendingConnect();
    final TwitterConnectStatus status;
    var finished = true;
    switch (rawValue) {
      case 'confirm':
        if (!startedHere) return;
        if (token == null || !_tokenShape.hasMatch(token)) {
          // Not the backend's token: nothing was spent, so the connect the
          // user started can still finish.
          status = TwitterConnectStatus.error;
          finished = false;
        } else if (!_sentTokens.add(token)) {
          // Also the replay of a link still waiting for its login below.
          return;
        } else {
          completing.value = true;
          try {
            if (await _sessionReady(completionTokenLifetime)) {
              final (outcome, spent) = await _completeWith(token);
              status = outcome;
              finished = spent;
              if (!spent) _sentTokens.remove(token);
            } else {
              // Nobody logged in while the token lived. It stays in
              // [_sentTokens]: a replay must not start a second wait for it.
              status = TwitterConnectStatus.expired;
            }
          } finally {
            completing.value = false;
          }
        }
      case 'success':
        status = TwitterConnectStatus.success;
      case 'error_user_exists':
        status = TwitterConnectStatus.userExists;
      default:
        status = TwitterConnectStatus.error;
    }
    _publish(status, startedHere: startedHere);
    if (finished) await _clearPendingConnect();
  }

  /// The outcome, and whether the backend spent the token. It spends it on
  /// every answer except a `401` (refused before the handler ran); a failure
  /// with no response may never have reached it.
  Future<(TwitterConnectStatus, bool)> _completeWith(String token) async {
    try {
      await _complete(token);
      return (TwitterConnectStatus.success, true);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      debugPrint('[TwitterConnect] complete failed: $status');
      return (
        switch (status) {
          403 => TwitterConnectStatus.otherWallet,
          400 => TwitterConnectStatus.expired,
          409 => TwitterConnectStatus.userExists,
          _ => TwitterConnectStatus.error,
        },
        status != null && status != 401,
      );
    } catch (e) {
      debugPrint('[TwitterConnect] complete failed: ${e.runtimeType}');
      return (TwitterConnectStatus.error, false);
    }
  }

  static Future<void> _completeViaApi(String token) =>
      sl<api.MallowApiV2Client>().completeTwitterConnect({'token': token});

  /// True as soon as a wallet is logged in; false if none is after [limit].
  ///
  /// The login is the app's own: it runs once the app is unlocked, and this
  /// only waits for it. With no [AuthService] to ask there is nothing to wait
  /// for.
  static Future<bool> _sessionViaAuth(Duration limit) async {
    if (!sl.isRegistered<AuthService>()) return true;
    final auth = sl<AuthService>();
    if (auth.hasSession) return true;

    final landed = Completer<bool>();
    void onChange() {
      if (auth.hasSession && !landed.isCompleted) landed.complete(true);
    }

    auth.addListener(onChange);
    final timer = Timer(limit, () {
      if (!landed.isCompleted) landed.complete(false);
    });
    try {
      return await landed.future;
    } finally {
      timer.cancel();
      auth.removeListener(onChange);
    }
  }
}
