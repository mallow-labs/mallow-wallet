import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/services/twitter_connect_notifier.dart';
import 'package:mallow_wallet/di.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answers every request with [status] and [body], recording what was sent.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The backend's completion token shape: 32 lowercase hex characters.
/// A repeated word on purpose: a random-looking value reads as a leaked
/// credential to secret scanners.
const _token = 'feedfacefeedfacefeedfacefeedface';

DioException _refusal(int status) => DioException(
  requestOptions: RequestOptions(path: '/twitter/complete'),
  response: Response<dynamic>(
    requestOptions: RequestOptions(path: '/twitter/complete'),
    statusCode: status,
  ),
);

/// Records a connect started on this install, as tapping Connect X does.
Future<void> _startConnect() =>
    TwitterConnectNotifier.withCompleter((_) async {}).markConnectStarted();

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _startConnect();
  });

  group('TwitterConnectNotifier.emitFromCallback', () {
    late TwitterConnectNotifier notifier;

    setUp(() => notifier = TwitterConnectNotifier());

    // The backend redirect carries the outcome as a `twitter=` query value;
    // mapping it wrong would either suppress the success refresh or show the
    // wrong toast, so each documented value must land on its status.
    test('maps success', () {
      expectLater(notifier.results, emits(TwitterConnectStatus.success));
      notifier.emitFromCallback('success');
    });

    test('maps error_user_exists to userExists', () {
      expectLater(notifier.results, emits(TwitterConnectStatus.userExists));
      notifier.emitFromCallback('error_user_exists');
    });

    test('maps explicit error', () {
      expectLater(notifier.results, emits(TwitterConnectStatus.error));
      notifier.emitFromCallback('error');
    });

    test('maps unrecognised values to error (fail closed)', () {
      expectLater(notifier.results, emits(TwitterConnectStatus.error));
      notifier.emitFromCallback('something_unexpected');
    });
  });

  // The callback does not link: it redirects with `twitter=confirm&token=…`
  // and the app finishes on the signed POST /v2/twitter/complete, so only the
  // wallet that started the connect can complete it.
  group('TwitterConnectNotifier confirm', () {
    late List<String> sent;

    TwitterConnectNotifier notifierAnswering(Object? Function() outcome) {
      sent = [];
      return TwitterConnectNotifier.withCompleter((token) async {
        sent.add(token);
        final result = outcome();
        if (result != null) throw result;
      });
    }

    test('sends the token and reports success on 200', () async {
      final notifier = notifierAnswering(() => null);
      final emitted = expectLater(
        notifier.results,
        emits(TwitterConnectStatus.success),
      );

      await notifier.emitFromCallback('confirm', token: _token);

      await emitted;
      expect(sent, [_token]);
    });

    for (final (status, expected) in [
      (403, TwitterConnectStatus.otherWallet),
      (400, TwitterConnectStatus.expired),
      (409, TwitterConnectStatus.userExists),
      (500, TwitterConnectStatus.error),
    ]) {
      test('maps a $status from complete to ${expected.name}', () async {
        final notifier = notifierAnswering(() => _refusal(status));
        final emitted = expectLater(notifier.results, emits(expected));

        await notifier.emitFromCallback('confirm', token: _token);

        await emitted;
      });
    }

    test('a failure with no response is an error', () async {
      final notifier = notifierAnswering(() => Exception('offline'));
      final emitted = expectLater(
        notifier.results,
        emits(TwitterConnectStatus.error),
      );

      await notifier.emitFromCallback('confirm', token: _token);

      await emitted;
    });

    test('confirm without a token is an error and sends nothing', () async {
      final notifier = notifierAnswering(() => null);
      final emitted = expectLater(
        notifier.results,
        emits(TwitterConnectStatus.error),
      );

      await notifier.emitFromCallback('confirm');

      await emitted;
      expect(sent, isEmpty);
    });

    // A completion token is 32 lowercase hex characters. Anything else
    // cannot be one, so it is not worth a signed call (or a signature).
    for (final bad in [
      'abc123',
      'FEEDFACEFEEDFACEFEEDFACEFEEDFACE',
      'feedfacefeedfacefeedfacefeedface0',
      '../feedfacefeedfacefeedfacefeedf',
    ]) {
      test('a token shaped "$bad" is an error and sends nothing', () async {
        final notifier = notifierAnswering(() => null);
        final emitted = expectLater(
          notifier.results,
          emits(TwitterConnectStatus.error),
        );

        await notifier.emitFromCallback('confirm', token: bad);

        await emitted;
        expect(sent, isEmpty);
      });
    }

    // The screen shows the X row busy while the link is being made.
    test('completing is true only while complete is in flight', () async {
      final release = Completer<void>();
      final notifier = TwitterConnectNotifier.withCompleter(
        (_) => release.future,
      );
      final states = <bool>[];
      notifier.completing.addListener(
        () => states.add(notifier.completing.value),
      );

      final done = notifier.emitFromCallback('confirm', token: _token);
      await pumpEventQueue();
      expect(notifier.completing.value, isTrue);

      release.complete();
      await done;
      expect(notifier.completing.value, isFalse);
      expect(states, [true, false]);
    });

    // The OS replays a cold-start link. The token is single-use, so a second
    // send would come back 400 and toast "expired" over the success.
    test('the same token is sent once', () async {
      final notifier = notifierAnswering(() => null);
      final statuses = <TwitterConnectStatus>[];
      final sub = notifier.results.listen(statuses.add);

      await notifier.emitFromCallback('confirm', token: _token);
      await notifier.emitFromCallback('confirm', token: _token);
      await pumpEventQueue();
      await sub.cancel();

      expect(sent, [_token]);
      expect(statuses, [TwitterConnectStatus.success]);
    });
  });

  // Any page can open the callback link. Without a connect the user started
  // here, `confirm` would make the app send a signed request — on a hardware
  // wallet, ask for a signature — for nobody's connect.
  group('TwitterConnectNotifier and the pending connect', () {
    late List<String> sent;
    late List<TwitterConnectStatus> statuses;
    late TwitterConnectNotifier notifier;
    late Object? Function() outcome;

    setUp(() {
      sent = [];
      statuses = [];
      outcome = () => null;
      notifier = TwitterConnectNotifier.withCompleter((token) async {
        sent.add(token);
        final result = outcome();
        if (result != null) throw result;
      });
      notifier.results.listen(statuses.add);
    });

    test('with no connect started here, confirm sends nothing and says '
        'nothing', () async {
      SharedPreferences.setMockInitialValues({});

      await notifier.emitFromCallback('confirm', token: _token);
      await pumpEventQueue();

      expect(sent, isEmpty);
      expect(statuses, isEmpty);
    });

    // X's sign-in pages take the user's own time, and the completion token
    // then lives 10 minutes: 10 minutes from the tap was too short.
    test('a started connect stays pending for 30 minutes', () async {
      SharedPreferences.setMockInitialValues({});
      final before = DateTime.now();
      await notifier.markConnectStarted();
      final until = DateTime.fromMillisecondsSinceEpoch(
        (await SharedPreferences.getInstance()).getInt(
          'x_connect_pending_until',
        )!,
      );

      expect(until.difference(before).inMinutes, inInclusiveRange(29, 30));
    });

    // The browser never opened, so a link arriving later was not started here.
    test('a withdrawn connect is not completed', () async {
      await notifier.cancelConnectStarted();

      await notifier.emitFromCallback('confirm', token: _token);
      await pumpEventQueue();

      expect(sent, isEmpty);
      expect(statuses, isEmpty);
    });

    test('a connect whose window has passed no longer counts', () async {
      SharedPreferences.setMockInitialValues({
        'x_connect_pending_until': DateTime.now()
            .subtract(const Duration(seconds: 1))
            .millisecondsSinceEpoch,
      });

      await notifier.emitFromCallback('confirm', token: _token);

      expect(sent, isEmpty);
    });

    test('a final outcome ends the pending connect', () async {
      await notifier.emitFromCallback('confirm', token: _token);
      await notifier.emitFromCallback(
        'confirm',
        token: 'ffffffffffffffffffffffffffffffff',
      );
      await pumpEventQueue();

      expect(sent, [_token]);
      expect(statuses, [TwitterConnectStatus.success]);
    });

    test('an error redirect ends the pending connect', () async {
      await notifier.emitFromCallback('error');
      await notifier.emitFromCallback('confirm', token: _token);
      await pumpEventQueue();

      expect(sent, isEmpty);
      expect(statuses, [TwitterConnectStatus.error]);
    });

    // A 401 is refused before the backend's handler runs, and a failure with
    // no response may never have reached it: either way the token is unspent,
    // so the same link must work again, and the connect is still pending.
    for (final (name, failure) in [
      ('a 401', () => _refusal(401)),
      (
        'a failure with no response',
        () => DioException(
          requestOptions: RequestOptions(path: '/twitter/complete'),
        ),
      ),
    ]) {
      test('after $name the same link can be retried', () async {
        outcome = failure;
        await notifier.emitFromCallback('confirm', token: _token);

        outcome = () => null;
        await notifier.emitFromCallback('confirm', token: _token);
        await pumpEventQueue();

        expect(sent, [_token, _token]);
        expect(statuses, [
          TwitterConnectStatus.error,
          TwitterConnectStatus.success,
        ]);
      });
    }

    test('a spent token is not sent again', () async {
      outcome = () => _refusal(400);
      await notifier.emitFromCallback('confirm', token: _token);
      await _startConnect();
      await notifier.emitFromCallback('confirm', token: _token);
      await pumpEventQueue();

      expect(sent, [_token]);
    });
  });

  // The browser round trip can outlive the app, and the link then starts it
  // cold: handled as the router boots, before the app is unlocked and a wallet
  // logged in, with no screen open. The complete call used to go out at once,
  // with no login, and fail; the failure went to a stream nobody was listening
  // to; and nothing tried again before the token died.
  group('TwitterConnectNotifier on a cold start', () {
    late List<String> events;
    late Completer<bool> login;
    late Duration? waitedFor;
    late Object? Function() outcome;
    late TwitterConnectNotifier notifier;

    setUp(() {
      events = [];
      login = Completer<bool>();
      waitedFor = null;
      outcome = () => null;
      notifier = TwitterConnectNotifier.withCompleter(
        (token) async {
          events.add('complete');
          final result = outcome();
          if (result != null) throw result;
        },
        sessionReady: (limit) async {
          waitedFor = limit;
          events.add('wait for login');
          final landed = await login.future;
          events.add(landed ? 'logged in' : 'gave up');
          return landed;
        },
      );
    });

    test('the complete call waits for the login', () async {
      final done = notifier.emitFromCallback('confirm', token: _token);
      await pumpEventQueue();

      expect(events, ['wait for login'], reason: 'nothing sent with no login');
      expect(notifier.completing.value, isTrue);

      login.complete(true);
      await done;

      expect(events, ['wait for login', 'logged in', 'complete']);
      expect(notifier.completing.value, isFalse);
    });

    test('it waits no longer than the completion token lives', () async {
      final done = notifier.emitFromCallback('confirm', token: _token);
      await pumpEventQueue();
      expect(waitedFor, const Duration(minutes: 10));
      expect(
        waitedFor,
        lessThan(TwitterConnectNotifier.pendingWindow),
        reason: 'the wait must end while the started connect still counts',
      );

      login.complete(false);
      await done;

      // The token is dead by now: nothing is sent, and the user is told to
      // start again rather than left with X silently unlinked.
      expect(events, ['wait for login', 'gave up']);
      expect(notifier.completing.value, isFalse);
      await expectLater(notifier.results, emits(TwitterConnectStatus.expired));
    });

    test('the OS replay of the link does not start a second wait', () async {
      final first = notifier.emitFromCallback('confirm', token: _token);
      await pumpEventQueue();
      await notifier.emitFromCallback('confirm', token: _token);

      login.complete(true);
      await first;

      expect(events, ['wait for login', 'logged in', 'complete']);
    });

    test('a success with no screen open reaches the screen when it '
        'opens', () async {
      login.complete(true);
      await notifier.emitFromCallback('confirm', token: _token);

      // The user opens the profile editor some time later.
      final statuses = <TwitterConnectStatus>[];
      final sub = notifier.results.listen(statuses.add);
      await pumpEventQueue();

      expect(statuses, [TwitterConnectStatus.success]);
      await sub.cancel();
    });

    for (final (status, expected) in [
      (403, TwitterConnectStatus.otherWallet),
      (400, TwitterConnectStatus.expired),
      (409, TwitterConnectStatus.userExists),
      (401, TwitterConnectStatus.error),
    ]) {
      test('a $status with no screen open is shown when it opens', () async {
        outcome = () => _refusal(status);
        login.complete(true);
        await notifier.emitFromCallback('confirm', token: _token);

        await expectLater(notifier.results, emits(expected));
      });
    }

    test('a held outcome is shown once', () async {
      login.complete(true);
      await notifier.emitFromCallback('confirm', token: _token);

      final first = <TwitterConnectStatus>[];
      final sub = notifier.results.listen(first.add);
      await pumpEventQueue();
      await sub.cancel();

      // Leaving the screen and coming back does not repeat the message.
      final second = <TwitterConnectStatus>[];
      final again = notifier.results.listen(second.add);
      await pumpEventQueue();
      await again.cancel();

      expect(first, [TwitterConnectStatus.success]);
      expect(second, isEmpty);
    });

    test('starting a new connect forgets the last one\'s outcome', () async {
      outcome = () => _refusal(400);
      login.complete(true);
      await notifier.emitFromCallback('confirm', token: _token);

      await notifier.markConnectStarted();

      final statuses = <TwitterConnectStatus>[];
      final sub = notifier.results.listen(statuses.add);
      await pumpEventQueue();
      await sub.cancel();

      expect(statuses, isEmpty);
    });

    // Any page can open the link. One this install never asked for must not
    // become a failure message the next time the user opens their profile.
    test('a link nobody here started is not held either', () async {
      SharedPreferences.setMockInitialValues({});

      await notifier.emitFromCallback('error');
      await notifier.emitFromCallback('error_user_exists');

      final statuses = <TwitterConnectStatus>[];
      final sub = notifier.results.listen(statuses.add);
      await pumpEventQueue();
      await sub.cancel();

      expect(statuses, isEmpty);
    });

    test('with the screen open the outcome is delivered, not held', () async {
      final statuses = <TwitterConnectStatus>[];
      final sub = notifier.results.listen(statuses.add);
      login.complete(true);

      await notifier.emitFromCallback('confirm', token: _token);
      await pumpEventQueue();
      await sub.cancel();

      final later = <TwitterConnectStatus>[];
      final again = notifier.results.listen(later.add);
      await pumpEventQueue();
      await again.cancel();

      expect(statuses, [TwitterConnectStatus.success]);
      expect(later, isEmpty);
    });
  });

  // The default completer, over the real API client: the exact request the
  // backend's complete route expects, and its refusal envelope.
  group('TwitterConnectNotifier complete request', () {
    late _RecordingAdapter adapter;

    void registerApi(int status, Map<String, dynamic> body) {
      adapter = _RecordingAdapter(status, body);
      final dio = Dio()..httpClientAdapter = adapter;
      if (sl.isRegistered<api.MallowApiV2Client>()) {
        sl.unregister<api.MallowApiV2Client>();
      }
      sl.registerSingleton<api.MallowApiV2Client>(
        api.MallowApiV2Client(dio, baseUrl: 'https://api.test/v2'),
      );
    }

    tearDown(() {
      if (sl.isRegistered<api.MallowApiV2Client>()) {
        sl.unregister<api.MallowApiV2Client>();
      }
    });

    test('POSTs {"token"} to /v2/twitter/complete', () async {
      registerApi(200, {
        'result': {'username': 'ada'},
      });
      final notifier = TwitterConnectNotifier();
      final emitted = expectLater(
        notifier.results,
        emits(TwitterConnectStatus.success),
      );

      await notifier.emitFromCallback('confirm', token: _token);

      await emitted;
      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.toString(), 'https://api.test/v2/twitter/complete');
      expect(request.data, {'token': _token});
    });

    test('a 403 refusal reads as another wallet', () async {
      registerApi(403, {
        'error': {'message': 'This X sign-in was started by another wallet'},
      });
      final notifier = TwitterConnectNotifier();
      final emitted = expectLater(
        notifier.results,
        emits(TwitterConnectStatus.otherWallet),
      );

      await notifier.emitFromCallback('confirm', token: _token);

      await emitted;
    });
  });
}
