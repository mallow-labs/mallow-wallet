import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/features/cast/models/cast_overlay_config.dart';
import 'package:mallow_wallet/features/cast/models/cast_queue.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mallow_wallet/features/cast/services/cast_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeCastService service;
  late PreferencesService prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await PreferencesService.create();
    service = _FakeCastService();
  });

  tearDown(() async {
    await service.dispose();
  });

  CastQueueItem item(String mint, {String? artist}) => CastQueueItem(
    mintAccount: mint,
    title: 'Title $mint',
    imageUrl: 'https://example/$mint.png',
    artistName: artist,
  );

  CastDevice device(String id) =>
      CastDevice(id: id, name: 'Device $id', type: CastDeviceType.local);

  // Drives the bloc through discover → connecting → active so we can test
  // event handlers that only act in CastActive.
  Future<CastBloc> activatedBloc({CastQueueItem? pending}) async {
    final bloc = CastBloc(service, prefs);
    bloc.add(CastEvent.castArtwork(pending ?? item('A')));
    await Future<void>.delayed(Duration.zero);
    bloc.add(CastEvent.connectToDevice(device('d1')));
    await Future<void>.delayed(Duration.zero);
    service.emitSession(CastSessionState.connected);
    await Future<void>.delayed(Duration.zero);
    return bloc;
  }

  group('clearQueue', () {
    blocTest<CastBloc, CastState>(
      'empties the queue and returns to idle',
      build: () => CastBloc(service, prefs),
      act: (bloc) async {
        bloc.add(CastEvent.castArtwork(item('A')));
        await Future<void>.delayed(Duration.zero);
        bloc.add(CastEvent.connectToDevice(device('d1')));
        await Future<void>.delayed(Duration.zero);
        service.emitSession(CastSessionState.connected);
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CastEvent.clearQueue());
      },
      verify: (bloc) {
        expect(bloc.state, isA<CastIdle>());
      },
    );
  });

  group('toggleShuffle', () {
    test('shuffles items and persists prefs', () async {
      final bloc = await activatedBloc(pending: item('A'));
      bloc.add(CastEvent.addToQueue(item('B')));
      bloc.add(CastEvent.addToQueue(item('C')));
      bloc.add(CastEvent.addToQueue(item('D')));
      await Future<void>.delayed(Duration.zero);

      bloc.add(const CastEvent.toggleShuffle());
      await Future<void>.delayed(Duration.zero);

      final state = bloc.state as CastActive;
      expect(state.queue.isShuffled, isTrue);
      expect(state.queue.originalItems.length, 4);
      expect(prefs.castShuffle, isTrue);
      // The currently-playing item must remain the current item after shuffle.
      expect(state.queue.currentItem?.mintAccount, 'A');

      await bloc.close();
    });

    test('toggling off restores original order', () async {
      final bloc = await activatedBloc(pending: item('A'));
      bloc.add(CastEvent.addToQueue(item('B')));
      bloc.add(CastEvent.addToQueue(item('C')));
      await Future<void>.delayed(Duration.zero);

      bloc.add(const CastEvent.toggleShuffle());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const CastEvent.toggleShuffle());
      await Future<void>.delayed(Duration.zero);

      final state = bloc.state as CastActive;
      expect(state.queue.isShuffled, isFalse);
      expect(state.queue.items.map((i) => i.mintAccount).toList(), [
        'A',
        'B',
        'C',
      ]);
      expect(prefs.castShuffle, isFalse);

      await bloc.close();
    });

    test('without active session, just persists', () async {
      final bloc = CastBloc(service, prefs);
      bloc.add(const CastEvent.toggleShuffle());
      await Future<void>.delayed(Duration.zero);
      expect(prefs.castShuffle, isTrue);
      await bloc.close();
    });
  });

  group('initial queue from prefs', () {
    test('seeds interval, overlay, and shuffle on connect', () async {
      await prefs.setCastIntervalSeconds(45);
      await prefs.setCastShowQr(false);
      await prefs.setCastShowCaption(false);
      await prefs.setCastShuffle(true);

      final bloc = await activatedBloc(pending: item('A'));
      final queue = (bloc.state as CastActive).queue;

      expect(queue.slideshowIntervalSeconds, 45);
      expect(queue.showQr, isFalse);
      expect(queue.showCaption, isFalse);
      expect(queue.isShuffled, isTrue);

      await bloc.close();
    });
  });

  group('last device persistence', () {
    test('connect persists the device id', () async {
      final bloc = CastBloc(service, prefs);
      bloc.add(CastEvent.castArtwork(item('A')));
      await Future<void>.delayed(Duration.zero);
      bloc.add(CastEvent.connectToDevice(device('apple-tv-uuid')));
      await Future<void>.delayed(Duration.zero);
      expect(prefs.castLastDeviceId, 'apple-tv-uuid');
      await bloc.close();
    });
  });

  group('persistence on setInterval / setOverlay', () {
    test(
      'setInterval writes to prefs even outside an active session',
      () async {
        final bloc = CastBloc(service, prefs);
        bloc.add(const CastEvent.setInterval(60));
        await Future<void>.delayed(Duration.zero);
        expect(prefs.castIntervalSeconds, 60);
        await bloc.close();
      },
    );

    test('setOverlay writes to prefs', () async {
      final bloc = CastBloc(service, prefs);
      bloc.add(const CastEvent.setOverlay(showQr: false, showCaption: false));
      await Future<void>.delayed(Duration.zero);
      expect(prefs.castShowQr, isFalse);
      expect(prefs.castShowCaption, isFalse);
      await bloc.close();
    });
  });

  // Cast is a headline surface, and before these paths existed every failure
  // mode presented identically: an unhandled exception behind a sheet stuck on
  // "Connecting…". The bloc must always land on a state the UI can render.
  group('connect failures', () {
    Future<CastBloc> failedConnect(
      Object error, {
      CastQueueItem? pending,
    }) async {
      service.connectError = error;
      final bloc = CastBloc(service, prefs);
      bloc.add(CastEvent.castArtwork(pending ?? item('A')));
      await Future<void>.delayed(Duration.zero);
      bloc.add(CastEvent.connectToDevice(device('d1')));
      await Future<void>.delayed(Duration.zero);
      return bloc;
    }

    test(
      'a native connect failure ends on CastError, never CastConnecting',
      () async {
        final bloc = await failedConnect(
          PlatformException(code: 'DEVICE_NOT_FOUND', message: 'Device x'),
        );

        // The whole point of the fix: the user must not be left waiting on a
        // state that will never resolve.
        expect(bloc.state, isA<CastError>());
        await bloc.close();
      },
    );

    test('raw native codes never reach the user', () async {
      for (final code in [
        'NO_DISCOVERY',
        'DEVICE_NOT_FOUND',
        'SESSION_FAILED',
      ]) {
        final bloc = await failedConnect(PlatformException(code: code));
        final message = (bloc.state as CastError).message;
        // Copy is for a tester, not a log reader — the code and the
        // PlatformException wrapper must both be mapped away.
        expect(message, isNot(contains(code)));
        expect(message, isNot(contains('PlatformException')));
        // Naming the device makes the sentence an answer to the tap.
        expect(message, contains('Device d1'));
        await bloc.close();
      }
    });

    test("MultiCastService's no-backend StateError maps to copy too", () async {
      final bloc = await failedConnect(
        StateError('No backend for device d1 (CastDeviceType.local)'),
      );
      final message = (bloc.state as CastError).message;
      expect(message, isNot(contains('Bad state')));
      expect(message, contains('Device d1'));
      await bloc.close();
    });

    test('retry resumes the queue the failed connect was carrying', () async {
      final bloc = await failedConnect(
        PlatformException(code: 'SESSION_FAILED'),
        pending: item('A'),
      );
      service.connectError = null;

      bloc.add(const CastEvent.refreshDiscovery());
      await Future<void>.delayed(Duration.zero);

      // Retry must not walk the user into a connected-but-empty session —
      // that reads as another silent failure.
      final state = bloc.state as CastDiscovering;
      expect(state.pendingItems.map((i) => i.mintAccount), ['A']);
      await bloc.close();
    });
  });

  group('mid-session drop', () {
    test('surfaces a message and keeps the queue for retry', () async {
      final bloc = await activatedBloc(pending: item('A'));
      expect(bloc.state, isA<CastActive>());

      service.emitSession(CastSessionState.error);
      await Future<void>.delayed(Duration.zero);

      final error = bloc.state as CastError;
      expect(error.message, contains('Cast connection lost'));

      bloc.add(const CastEvent.refreshDiscovery());
      await Future<void>.delayed(Duration.zero);

      // The user was watching a queue; a drop must not silently discard it.
      final state = bloc.state as CastDiscovering;
      expect(state.pendingItems.map((i) => i.mintAccount), ['A']);
      await bloc.close();
    });
  });

  group('switching devices mid-session', () {
    test('carries the live queue onto the new screen', () async {
      final bloc = await activatedBloc(pending: item('A'));
      bloc.add(CastEvent.addToQueue(item('B')));
      await Future<void>.delayed(Duration.zero);

      // The device picker dispatches this straight from CastActive.
      bloc.add(CastEvent.connectToDevice(device('d2')));
      await Future<void>.delayed(Duration.zero);

      // The queue has to survive the hop, or the new session comes up empty:
      // the user picks a second screen and the slideshow they were watching
      // just stops, with nothing on screen to say why.
      final connecting = bloc.state as CastConnecting;
      expect(connecting.pendingItems.map((i) => i.mintAccount), ['A', 'B']);

      service.emitSession(CastSessionState.connected);
      await Future<void>.delayed(Duration.zero);

      final active = bloc.state as CastActive;
      expect(active.device.id, 'd2');
      expect(active.queue.items.map((i) => i.mintAccount), ['A', 'B']);
      await bloc.close();
    });
  });

  group('discovery failures', () {
    test('a failed scan surfaces instead of spinning forever', () async {
      service.discoveryError = PlatformException(code: 'CAST_UNAVAILABLE');
      final bloc = CastBloc(service, prefs);
      bloc.add(CastEvent.castArtwork(item('A')));
      await Future<void>.delayed(Duration.zero);

      // An empty device list is indistinguishable from "no devices on this
      // network" — the Play-services cause has to be stated.
      final state = bloc.state as CastError;
      expect(state.message, contains('Google Play services'));
      await bloc.close();
    });

    test('a failed background scan never tears down a live session', () async {
      final bloc = await activatedBloc(pending: item('A'));
      service.discoveryError = PlatformException(code: 'CAST_UNAVAILABLE');

      bloc.add(const CastEvent.refreshDiscovery());
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, isA<CastActive>());
      await bloc.close();
    });
  });
}

/// Minimal CastService stand-in. Streams are broadcast so the bloc can
/// listen, and method calls are no-op except for emitting connected on
/// connectToDevice when explicitly requested via [emitSession].
class _FakeCastService implements CastService {
  final _devicesController = StreamController<List<CastDevice>>.broadcast();
  final _sessionController = StreamController<CastSessionState>.broadcast();

  /// When set, [connectToDevice] / [startDiscovery] throw it — the native
  /// backends surface every failure as a thrown [PlatformException].
  Object? connectError;
  Object? discoveryError;

  void emitSession(CastSessionState state) => _sessionController.add(state);

  Future<void> dispose() async {
    await _devicesController.close();
    await _sessionController.close();
  }

  @override
  Stream<List<CastDevice>> get deviceStream => _devicesController.stream;

  @override
  Stream<CastSessionState> get sessionStream => _sessionController.stream;

  @override
  Stream<bool> get externalDisplayActiveStream => Stream.value(true);

  @override
  Future<void> startDiscovery() async {
    final error = discoveryError;
    if (error != null) throw error;
  }

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<void> connectToDevice(CastDevice device) async {
    final error = connectError;
    if (error != null) throw error;
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> sendMedia(
    CastQueueItem item, {
    required CastOverlayConfig overlay,
    String? resolvedUrl,
  }) async {}

  @override
  Future<void> updateOverlay(CastOverlayConfig config) async {}

  @override
  Future<void> preloadItems(List<CastQueueItem> items) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}
}
