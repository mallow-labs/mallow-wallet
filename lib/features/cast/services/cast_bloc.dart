import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/services/preferences_service.dart';
import '../models/cast_display_type.dart';
import '../models/cast_overlay_config.dart';
import '../models/cast_queue.dart';
import 'cast_failure.dart';
import 'cast_service.dart';

part 'cast_bloc.freezed.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

@freezed
sealed class CastEvent with _$CastEvent {
  /// Initiate casting a single artwork. Opens device picker if not connected.
  const factory CastEvent.castArtwork(CastQueueItem item) = CastArtwork;

  /// Initiate casting a list of artworks. Opens device picker if not connected
  /// and seeds the queue with [items] so the user can preview/edit them
  /// before connecting.
  const factory CastEvent.castArtworks(List<CastQueueItem> items) =
      CastArtworks;

  /// Add an artwork to the queue without immediately casting.
  const factory CastEvent.addToQueue(CastQueueItem item) = CastAddToQueue;

  /// Add multiple artworks to the queue without immediately casting.
  /// Duplicates (by mintAccount) are skipped so users can re-trigger
  /// "Add to cast" on overlapping collections without padding the queue.
  const factory CastEvent.addItemsToQueue(List<CastQueueItem> items) =
      CastAddItemsToQueue;

  /// Remove the item at [index] from the queue.
  const factory CastEvent.removeFromQueue(int index) = CastRemoveFromQueue;

  /// Reorder the queue by moving [oldIndex] to [newIndex].
  const factory CastEvent.reorderQueue(int oldIndex, int newIndex) =
      CastReorderQueue;

  /// Skip to a specific [index] in the queue.
  const factory CastEvent.skipToIndex(int index) = CastSkipToIndex;

  /// Advance to the next item in the queue.
  const factory CastEvent.skipNext() = CastSkipNext;

  /// Go back to the previous item in the queue.
  const factory CastEvent.skipPrevious() = CastSkipPrevious;

  /// Toggle play/pause on the slideshow timer.
  const factory CastEvent.togglePause() = CastTogglePause;

  /// Change the automatic slideshow interval (in seconds).
  const factory CastEvent.setInterval(int seconds) = CastSetInterval;

  /// Toggle one or both overlay layers on the receiver. Null leaves a layer
  /// unchanged, allowing callers to flip a single switch without needing the
  /// other's current value.
  const factory CastEvent.setOverlay({bool? showQr, bool? showCaption}) =
      CastSetOverlay;

  /// Change how the receiver fits the artwork above the bottom info bar.
  /// Persists to prefs and live-updates the active session.
  const factory CastEvent.setDisplayType(CastDisplayType type) =
      CastSetDisplayType;

  /// Toggle shuffled playback. When turning on, captures the current queue
  /// order; when turning off, restores it.
  const factory CastEvent.toggleShuffle() = CastToggleShuffle;

  /// Cycle repeat mode: off → all → one → off. Persists across sessions.
  const factory CastEvent.cycleRepeatMode() = CastCycleRepeatMode;

  /// Clear the queue and end the session — destructive "Clear" action.
  const factory CastEvent.clearQueue() = CastClearQueue;

  /// Connect to a specific device.
  const factory CastEvent.connectToDevice(CastDevice device) =
      CastConnectToDevice;

  /// Disconnect from the current device and end the session.
  const factory CastEvent.disconnect() = CastDisconnect;

  /// Open the device picker / refresh discovery without a pending artwork.
  /// No-op when connecting. When active, runs a background scan that fills
  /// [CastActive.availableDevices] without leaving the session.
  const factory CastEvent.refreshDiscovery() = CastRefreshDiscovery;

  /// Stop the background scan started by [CastEvent.refreshDiscovery] while
  /// active, and clear [CastActive.availableDevices]. No-op outside of an
  /// active session.
  const factory CastEvent.stopBackgroundDiscovery() =
      CastStopBackgroundDiscovery;

  /// Internal: device list updated by [CastService.deviceStream].
  const factory CastEvent.deviceListUpdated(List<CastDevice> devices) =
      CastDeviceListUpdated;

  /// Internal: session state changed by [CastService.sessionStream].
  const factory CastEvent.sessionStateChanged(CastSessionState state) =
      CastSessionStateChanged;
}

// ---------------------------------------------------------------------------
// States
// ---------------------------------------------------------------------------

@freezed
sealed class CastState with _$CastState {
  /// No cast session in progress.
  const factory CastState.idle() = CastIdle;

  /// Discovering devices. [pendingItems] is the queue waiting to be cast
  /// once connected — empty when discovery was opened from the now-casting
  /// bar without a target artwork.
  const factory CastState.discovering({
    @Default([]) List<CastDevice> devices,
    @Default([]) List<CastQueueItem> pendingItems,
  }) = CastDiscovering;

  /// Connecting to [device].
  const factory CastState.connecting({
    required CastDevice device,
    @Default([]) List<CastQueueItem> pendingItems,
  }) = CastConnecting;

  /// Active cast session. [availableDevices] is populated only while the
  /// user has the device picker open and we're scanning in the background;
  /// it lets the picker show other reachable devices without leaving the
  /// session.
  const factory CastState.active({
    required CastDevice device,
    required CastQueue queue,
    @Default(CastSessionState.connected) CastSessionState sessionState,
    @Default([]) List<CastDevice> availableDevices,
  }) = CastActive;

  /// An error occurred. [message] describes what went wrong.
  const factory CastState.error({required String message}) = CastError;
}

// ---------------------------------------------------------------------------
// Bloc
// ---------------------------------------------------------------------------

/// Manages cast sessions, device discovery, and slideshow progression.
///
/// Registered as a lazySingleton in [RegisterModule] so the same instance is
/// shared across all routes — necessary for the "Now Casting" mini bar to
/// remain visible during navigation.
class CastBloc extends Bloc<CastEvent, CastState> {
  CastBloc(this._castService, this._prefs) : super(const CastState.idle()) {
    on<CastArtwork>(_onCastArtwork);
    on<CastArtworks>(_onCastArtworks);
    on<CastAddToQueue>(_onAddToQueue);
    on<CastAddItemsToQueue>(_onAddItemsToQueue);
    on<CastRemoveFromQueue>(_onRemoveFromQueue);
    on<CastReorderQueue>(_onReorderQueue);
    on<CastSkipToIndex>(_onSkipToIndex);
    on<CastSkipNext>(_onSkipNext);
    on<CastSkipPrevious>(_onSkipPrevious);
    on<CastTogglePause>(_onTogglePause);
    on<CastSetInterval>(_onSetInterval);
    on<CastSetOverlay>(_onSetOverlay);
    on<CastSetDisplayType>(_onSetDisplayType);
    on<CastToggleShuffle>(_onToggleShuffle);
    on<CastCycleRepeatMode>(_onCycleRepeatMode);
    on<CastClearQueue>(_onClearQueue);
    on<CastConnectToDevice>(_onConnectToDevice);
    on<CastDisconnect>(_onDisconnect);
    on<CastRefreshDiscovery>(_onRefreshDiscovery);
    on<CastStopBackgroundDiscovery>(_onStopBackgroundDiscovery);
    on<CastDeviceListUpdated>(_onDeviceListUpdated);
    on<CastSessionStateChanged>(_onSessionStateChanged);

    _deviceSub = _castService.deviceStream.listen((devices) {
      debugPrint(
        '[Cast] device stream → ${devices.length}: '
        '${devices.map((d) => d.name).join(', ')}',
      );
      add(CastEvent.deviceListUpdated(devices));
    });
    _sessionSub = _castService.sessionStream.listen((state) {
      debugPrint('[Cast] session stream → ${state.name}');
      add(CastEvent.sessionStateChanged(state));
    });
    _mirrorSub = _castService.externalDisplayActiveStream.listen((active) {
      debugPrint('[Cast] mirror stream → active=$active');
      _externalDisplayActive = active;
      _externalDisplayController.add(active);
    });
  }

  final CastService _castService;
  final PreferencesService _prefs;

  StreamSubscription<List<CastDevice>>? _deviceSub;
  StreamSubscription<CastSessionState>? _sessionSub;
  StreamSubscription<bool>? _mirrorSub;
  Timer? _slideshowTimer;

  /// Queue captured at the moment a session failed. [CastError] carries only a
  /// message, so without this the "Try again" affordance on the error surfaces
  /// would drop the user into a *successfully connected but empty* session —
  /// the same silent dead end as switching devices mid-session. Restored as
  /// `pendingItems` when the user re-enters discovery from the error state, and
  /// cleared as soon as it is consumed (or the user disconnects) so a stale
  /// queue can never resurrect into an unrelated session.
  List<CastQueueItem> _itemsBeforeError = const [];

  /// Mirror / external-display readiness, forwarded from the active
  /// [CastService]. Kept outside [CastState] to avoid coupling — only the
  /// AirPlay prompt UI consumes this. Chromecast/local backends emit `true`
  /// once and stay there; AirPlay tracks iOS Screen Mirroring attach/detach.
  bool _externalDisplayActive = true;
  late final StreamController<bool> _externalDisplayController =
      StreamController<bool>.broadcast(
        onListen: () => _externalDisplayController.add(_externalDisplayActive),
      );

  /// Latest mirror readiness — synchronous accessor for code that needs to
  /// branch immediately rather than await a stream emission.
  bool get isExternalDisplayActive => _externalDisplayActive;

  /// Stream of mirror-readiness changes. Replays the current value on
  /// subscribe so callers don't have to coordinate with the underlying
  /// platform-channel timing.
  Stream<bool> get externalDisplayActiveStream =>
      _externalDisplayController.stream;

  /// Build a fresh queue using the user's persisted cast preferences. If
  /// the queue is being created with [pendingItems], shuffle is applied via
  /// the helper so [originalItems] stays in sync.
  CastQueue _initialQueue({List<CastQueueItem> pendingItems = const []}) {
    final base = CastQueue(
      items: pendingItems,
      slideshowIntervalSeconds: _prefs.castIntervalSeconds,
      showQr: _prefs.castShowQr,
      showCaption: _prefs.castShowCaption,
      repeatMode: _prefs.castRepeatMode,
      displayType: _prefs.castDisplayType,
    );
    return _prefs.castShuffle ? base.withShuffleOn() : base;
  }

  /// Items to warm on the receiver after [queue]'s current item — the next
  /// [count], honouring [CastRepeatMode.all] wrap. Skips repeat-one (the same
  /// item plays in place; nothing to preload).
  List<CastQueueItem> _lookahead(CastQueue queue, {int count = 2}) {
    if (queue.items.isEmpty || queue.repeatMode == CastRepeatMode.one) {
      return const [];
    }
    final out = <CastQueueItem>[];
    final total = queue.items.length;
    for (var i = 1; i <= count; i++) {
      var idx = queue.currentIndex + i;
      if (idx >= total) {
        if (queue.repeatMode != CastRepeatMode.all) break;
        idx %= total;
      }
      // Don't double-preload the current item if the queue is shorter than count.
      if (idx == queue.currentIndex) break;
      out.add(queue.items[idx]);
    }
    return out;
  }

  Future<void> _preloadLookahead(CastQueue queue) async {
    final next = _lookahead(queue);
    if (next.isEmpty) return;
    try {
      await _castService.preloadItems(next);
    } catch (e) {
      debugPrint('[Cast] preloadItems failed (non-fatal): $e');
    }
  }

  /// Move to [CastError] with user-facing [message], snapshotting whatever
  /// queue was in flight so a retry can resume it. Every failure path routes
  /// through here — the slideshow timer must stop or it keeps firing
  /// `skipNext` against a dead session.
  void _emitFailure(Emitter<CastState> emit, String message) {
    _stopSlideshowTimer();
    _itemsBeforeError = switch (state) {
      CastActive(:final queue) => queue.items,
      CastDiscovering(:final pendingItems) => pendingItems,
      CastConnecting(:final pendingItems) => pendingItems,
      _ => _itemsBeforeError,
    };
    emit(CastState.error(message: message));
  }

  /// Start a native scan without letting a platform failure escape as an
  /// unhandled bloc exception (which leaves the UI spinning on "Searching…"
  /// forever). When [fatal] the failure becomes [CastError]; a background scan
  /// during an active session is best-effort and only logs.
  Future<void> _startDiscovery(
    Emitter<CastState> emit, {
    bool fatal = true,
  }) async {
    try {
      await _castService.startDiscovery();
    } catch (e) {
      debugPrint('[Cast] startDiscovery failed: $e');
      if (fatal) _emitFailure(emit, castDiscoveryFailureMessage(e));
    }
  }

  // ---------------------------------------------------------------------------
  // Event handlers
  // ---------------------------------------------------------------------------

  Future<void> _onCastArtwork(
    CastArtwork event,
    Emitter<CastState> emit,
  ) async {
    final currentState = state;

    if (currentState is CastActive) {
      // Already connected — replace queue or cast immediately. Carry the
      // current session's overlay/interval/shuffle/repeat so changing
      // artwork doesn't reset the user's choices.
      final base = CastQueue(
        items: [event.item],
        slideshowIntervalSeconds: currentState.queue.slideshowIntervalSeconds,
        showQr: currentState.queue.showQr,
        showCaption: currentState.queue.showCaption,
        repeatMode: currentState.queue.repeatMode,
        displayType: currentState.queue.displayType,
      );
      final newQueue = currentState.queue.isShuffled
          ? base.withShuffleOn()
          : base;
      await _castService.sendMedia(
        event.item,
        overlay: CastOverlayConfigFromQueue.from(newQueue, event.item),
      );
      emit(currentState.copyWith(queue: newQueue));
      _restartSlideshowTimer(newQueue.slideshowIntervalSeconds);
      unawaited(_preloadLookahead(newQueue));
      return;
    }

    // Not connected — start discovery and remember the pending item.
    debugPrint('[Cast] castArtwork → starting discovery');
    // A fresh cast intent supersedes any queue held for an error retry.
    _itemsBeforeError = const [];
    emit(CastState.discovering(pendingItems: [event.item]));
    await _startDiscovery(emit);
  }

  Future<void> _onCastArtworks(
    CastArtworks event,
    Emitter<CastState> emit,
  ) async {
    if (event.items.isEmpty) return;
    final currentState = state;

    if (currentState is CastActive) {
      // Already connected — replace the queue with the new items, carrying
      // forward overlay/interval/shuffle/repeat so changing artwork doesn't
      // reset the user's session-level choices.
      final base = CastQueue(
        items: event.items,
        slideshowIntervalSeconds: currentState.queue.slideshowIntervalSeconds,
        showQr: currentState.queue.showQr,
        showCaption: currentState.queue.showCaption,
        repeatMode: currentState.queue.repeatMode,
        displayType: currentState.queue.displayType,
      );
      final newQueue = currentState.queue.isShuffled
          ? base.withShuffleOn()
          : base;
      final first = newQueue.currentItem;
      if (first != null) {
        await _castService.sendMedia(
          first,
          overlay: CastOverlayConfigFromQueue.from(newQueue, first),
        );
      }
      emit(currentState.copyWith(queue: newQueue));
      _restartSlideshowTimer(newQueue.slideshowIntervalSeconds);
      unawaited(_preloadLookahead(newQueue));
      return;
    }

    // Not connected — start discovery and seed the pending queue with the
    // full list so the user can preview it via "View Queue" before
    // committing to cast.
    debugPrint(
      '[Cast] castArtworks → starting discovery (${event.items.length} items)',
    );
    // A fresh cast intent supersedes any queue held for an error retry.
    _itemsBeforeError = const [];
    emit(CastState.discovering(pendingItems: event.items));
    await _startDiscovery(emit);
  }

  Future<void> _onAddToQueue(
    CastAddToQueue event,
    Emitter<CastState> emit,
  ) async {
    final currentState = state;

    if (currentState is CastActive) {
      final newQueue = currentState.queue.withItemAdded(event.item);
      emit(currentState.copyWith(queue: newQueue));

      // If this is the only item now (queue was empty), cast it immediately.
      if (newQueue.items.length == 1) {
        await _castService.sendMedia(
          event.item,
          overlay: CastOverlayConfigFromQueue.from(newQueue, event.item),
        );
        _restartSlideshowTimer(newQueue.slideshowIntervalSeconds);
      }
      return;
    }

    if (currentState is CastDiscovering) {
      emit(
        currentState.copyWith(
          pendingItems: [...currentState.pendingItems, event.item],
        ),
      );
      return;
    }

    if (currentState is CastConnecting) {
      emit(
        currentState.copyWith(
          pendingItems: [...currentState.pendingItems, event.item],
        ),
      );
      return;
    }

    // Idle/error — nothing to attach the item to.
  }

  Future<void> _onAddItemsToQueue(
    CastAddItemsToQueue event,
    Emitter<CastState> emit,
  ) async {
    if (event.items.isEmpty) return;
    final currentState = state;

    if (currentState is CastActive) {
      final wasEmpty = currentState.queue.items.isEmpty;
      final newQueue = currentState.queue.withItemsAdded(event.items);
      // No new items survived dedup — leave state alone.
      if (newQueue.items.length == currentState.queue.items.length) return;
      emit(currentState.copyWith(queue: newQueue));

      // Match _onAddToQueue: if the queue was empty before, the first new
      // item needs to be sent to the receiver and the slideshow started.
      if (wasEmpty) {
        final first = newQueue.currentItem;
        if (first != null) {
          await _castService.sendMedia(
            first,
            overlay: CastOverlayConfigFromQueue.from(newQueue, first),
          );
          _restartSlideshowTimer(newQueue.slideshowIntervalSeconds);
        }
      }
      unawaited(_preloadLookahead(newQueue));
      return;
    }

    List<CastQueueItem> mergePending(List<CastQueueItem> existing) {
      final seen = existing.map((it) => it.mintAccount).toSet();
      final out = List<CastQueueItem>.of(existing);
      for (final item in event.items) {
        if (seen.add(item.mintAccount)) out.add(item);
      }
      return out;
    }

    if (currentState is CastDiscovering) {
      emit(
        currentState.copyWith(
          pendingItems: mergePending(currentState.pendingItems),
        ),
      );
      return;
    }

    if (currentState is CastConnecting) {
      emit(
        currentState.copyWith(
          pendingItems: mergePending(currentState.pendingItems),
        ),
      );
      return;
    }

    // Idle/error — nothing to attach the items to.
  }

  void _onRemoveFromQueue(CastRemoveFromQueue event, Emitter<CastState> emit) {
    final currentState = state;

    if (currentState is CastActive) {
      final newQueue = currentState.queue.withItemRemoved(event.index);
      emit(currentState.copyWith(queue: newQueue));

      if (newQueue.items.isEmpty) {
        _stopSlideshowTimer();
      }
      return;
    }

    if (currentState is CastDiscovering) {
      if (event.index < 0 || event.index >= currentState.pendingItems.length) {
        return;
      }
      final next = List<CastQueueItem>.of(currentState.pendingItems)
        ..removeAt(event.index);
      emit(currentState.copyWith(pendingItems: next));
      return;
    }

    if (currentState is CastConnecting) {
      if (event.index < 0 || event.index >= currentState.pendingItems.length) {
        return;
      }
      final next = List<CastQueueItem>.of(currentState.pendingItems)
        ..removeAt(event.index);
      emit(currentState.copyWith(pendingItems: next));
      return;
    }
  }

  void _onReorderQueue(CastReorderQueue event, Emitter<CastState> emit) {
    final currentState = state;

    if (currentState is CastActive) {
      final newQueue = currentState.queue.withItemReordered(
        event.oldIndex,
        event.newIndex,
      );
      emit(currentState.copyWith(queue: newQueue));
      return;
    }

    List<CastQueueItem> reorder(List<CastQueueItem> items) {
      final next = List<CastQueueItem>.of(items);
      final item = next.removeAt(event.oldIndex);
      next.insert(event.newIndex, item);
      return next;
    }

    if (currentState is CastDiscovering) {
      emit(
        currentState.copyWith(pendingItems: reorder(currentState.pendingItems)),
      );
      return;
    }

    if (currentState is CastConnecting) {
      emit(
        currentState.copyWith(pendingItems: reorder(currentState.pendingItems)),
      );
      return;
    }
  }

  Future<void> _onSkipToIndex(
    CastSkipToIndex event,
    Emitter<CastState> emit,
  ) async {
    final currentState = state;
    if (currentState is! CastActive) return;

    final newQueue = currentState.queue.copyWith(currentIndex: event.index);
    final item = newQueue.currentItem;
    if (item == null) return;

    await _castService.sendMedia(
      item,
      overlay: CastOverlayConfigFromQueue.from(newQueue, item),
    );
    emit(currentState.copyWith(queue: newQueue));
    _restartSlideshowTimer(newQueue.slideshowIntervalSeconds);
    unawaited(_preloadLookahead(newQueue));
  }

  Future<void> _onSkipNext(CastSkipNext event, Emitter<CastState> emit) async {
    final currentState = state;
    if (currentState is! CastActive) return;

    final newQueue = currentState.queue.withNextIndex();
    final item = newQueue.currentItem;
    if (item == null) return;

    await _castService.sendMedia(
      item,
      overlay: CastOverlayConfigFromQueue.from(newQueue, item),
    );
    emit(currentState.copyWith(queue: newQueue));
    _restartSlideshowTimer(newQueue.slideshowIntervalSeconds);
    unawaited(_preloadLookahead(newQueue));
  }

  Future<void> _onSkipPrevious(
    CastSkipPrevious event,
    Emitter<CastState> emit,
  ) async {
    final currentState = state;
    if (currentState is! CastActive) return;

    final newQueue = currentState.queue.withPreviousIndex();
    final item = newQueue.currentItem;
    if (item == null) return;

    await _castService.sendMedia(
      item,
      overlay: CastOverlayConfigFromQueue.from(newQueue, item),
    );
    emit(currentState.copyWith(queue: newQueue));
    _restartSlideshowTimer(newQueue.slideshowIntervalSeconds);
    unawaited(_preloadLookahead(newQueue));
  }

  void _onTogglePause(CastTogglePause event, Emitter<CastState> emit) {
    final currentState = state;
    if (currentState is! CastActive) return;

    final newPaused = !currentState.queue.isPaused;
    final newQueue = currentState.queue.copyWith(isPaused: newPaused);
    emit(currentState.copyWith(queue: newQueue));

    if (newPaused) {
      _stopSlideshowTimer();
      _castService.pause();
    } else {
      _castService.resume();
      _restartSlideshowTimer(newQueue.slideshowIntervalSeconds);
    }
  }

  void _onSetInterval(CastSetInterval event, Emitter<CastState> emit) {
    unawaited(_prefs.setCastIntervalSeconds(event.seconds));

    final currentState = state;
    if (currentState is! CastActive) return;

    final newQueue = currentState.queue.copyWith(
      slideshowIntervalSeconds: event.seconds,
    );
    emit(currentState.copyWith(queue: newQueue));

    if (!newQueue.isPaused) {
      _restartSlideshowTimer(event.seconds);
    }
  }

  void _onSetOverlay(CastSetOverlay event, Emitter<CastState> emit) {
    if (event.showQr != null) {
      unawaited(_prefs.setCastShowQr(event.showQr!));
    }
    if (event.showCaption != null) {
      unawaited(_prefs.setCastShowCaption(event.showCaption!));
    }

    final currentState = state;
    if (currentState is! CastActive) return;

    final newQueue = currentState.queue.copyWith(
      showQr: event.showQr ?? currentState.queue.showQr,
      showCaption: event.showCaption ?? currentState.queue.showCaption,
    );
    emit(currentState.copyWith(queue: newQueue));

    final currentItem = newQueue.currentItem;
    if (currentItem != null) {
      _castService.updateOverlay(
        CastOverlayConfigFromQueue.from(newQueue, currentItem),
      );
    }
  }

  void _onSetDisplayType(CastSetDisplayType event, Emitter<CastState> emit) {
    unawaited(_prefs.setCastDisplayType(event.type));

    final currentState = state;
    if (currentState is! CastActive) return;

    final newQueue = currentState.queue.copyWith(displayType: event.type);
    emit(currentState.copyWith(queue: newQueue));

    final currentItem = newQueue.currentItem;
    if (currentItem != null) {
      _castService.updateOverlay(
        CastOverlayConfigFromQueue.from(newQueue, currentItem),
      );
    }
  }

  void _onToggleShuffle(CastToggleShuffle event, Emitter<CastState> emit) {
    final currentState = state;
    if (currentState is! CastActive) {
      // No active session — still persist the preference so the next session
      // honors it.
      unawaited(_prefs.setCastShuffle(!_prefs.castShuffle));
      return;
    }

    final newQueue = currentState.queue.isShuffled
        ? currentState.queue.withShuffleOff()
        : currentState.queue.withShuffleOn();
    unawaited(_prefs.setCastShuffle(newQueue.isShuffled));
    emit(currentState.copyWith(queue: newQueue));
  }

  void _onCycleRepeatMode(CastCycleRepeatMode event, Emitter<CastState> emit) {
    final currentState = state;
    final current = currentState is CastActive
        ? currentState.queue.repeatMode
        : _prefs.castRepeatMode;
    final next = switch (current) {
      CastRepeatMode.off => CastRepeatMode.all,
      CastRepeatMode.all => CastRepeatMode.one,
      CastRepeatMode.one => CastRepeatMode.off,
    };
    unawaited(_prefs.setCastRepeatMode(next));
    if (currentState is CastActive) {
      emit(
        currentState.copyWith(
          queue: currentState.queue.copyWith(repeatMode: next),
        ),
      );
    }
  }

  Future<void> _onClearQueue(
    CastClearQueue event,
    Emitter<CastState> emit,
  ) async {
    // "Clear" is destructive — empty the queue and end the session, mirroring
    // the design's lone Clear action.
    await _onDisconnect(const CastDisconnect(), emit);
  }

  Future<void> _onConnectToDevice(
    CastConnectToDevice event,
    Emitter<CastState> emit,
  ) async {
    final pendingItems = switch (state) {
      CastDiscovering(:final pendingItems) => pendingItems,
      // Switching screens mid-session: the picker dispatches this straight
      // from [CastActive], so the live queue has to ride along or the new
      // session comes up empty and the slideshow silently ends. Only the items
      // are carried — every session-level setting (interval, overlays,
      // shuffle, repeat, display type) is persisted to prefs as it changes and
      // is rebuilt by [_initialQueue].
      CastActive(:final queue) => queue.items,
      _ => const <CastQueueItem>[],
    };

    // Persist now so it sticks even if the connect attempt fails partway —
    // the user's intent was to use this device.
    unawaited(_prefs.setCastLastDeviceId(event.device.id));

    emit(
      CastState.connecting(device: event.device, pendingItems: pendingItems),
    );
    try {
      await _castService.connectToDevice(event.device);
    } catch (e) {
      // Every native connect failure lands here (NO_DISCOVERY,
      // DEVICE_NOT_FOUND, SESSION_FAILED, MultiCastService's "no backend"
      // StateError). Without this the exception escapes the handler and the
      // UI sits on "Connecting…" forever with nothing to tell the user why.
      debugPrint('[Cast] connectToDevice(${event.device.id}) failed: $e');
      _emitFailure(
        emit,
        castConnectFailureMessage(e, deviceName: event.device.name),
      );
      return;
    }
    // State will transition to active via _onSessionStateChanged when
    // CastSessionState.connected arrives.
  }

  Future<void> _onDisconnect(
    CastDisconnect event,
    Emitter<CastState> emit,
  ) async {
    debugPrint('[Cast] disconnect → stopping discovery + session');
    _stopSlideshowTimer();
    // Explicit user intent to end — nothing left to resume on a later retry.
    _itemsBeforeError = const [];
    // Teardown is best-effort: a native failure here must still land the bloc
    // on idle, or the UI stays stuck on a session the user already ended.
    try {
      await _castService.disconnect();
      await _castService.stopDiscovery();
    } catch (e) {
      debugPrint('[Cast] disconnect teardown failed (ignored): $e');
    }
    emit(const CastState.idle());
  }

  Future<void> _onRefreshDiscovery(
    CastRefreshDiscovery event,
    Emitter<CastState> emit,
  ) async {
    final currentState = state;

    // Mid-connect — discovery is unrelated to the user's current intent;
    // let the connect flow finish.
    if (currentState is CastConnecting) return;

    // Active session — the user opened the device picker to switch screens.
    // Scan in the background without disturbing the session; discovered
    // devices land on [CastActive.availableDevices] via _onDeviceListUpdated.
    if (currentState is CastActive) {
      debugPrint('[Cast] refreshDiscovery → background scan (active)');
      // Best-effort: a failed background scan must not tear down a session the
      // user is happily watching.
      await _startDiscovery(emit, fatal: false);
      return;
    }

    // Already discovering — preserve the device list and pendingItems; just
    // nudge the native layer to scan again so stale entries get refreshed.
    if (currentState is CastDiscovering) {
      debugPrint('[Cast] refreshDiscovery → re-scan (already discovering)');
      await _startDiscovery(emit);
      return;
    }

    // Idle/error — enter discovery. This is also the "Try again" path off the
    // error surfaces, so resume the queue the failed session was carrying.
    final resume = _itemsBeforeError;
    _itemsBeforeError = const [];
    debugPrint(
      '[Cast] refreshDiscovery → entering discovery '
      '(resuming ${resume.length} item(s))',
    );
    emit(CastState.discovering(pendingItems: resume));
    await _startDiscovery(emit);
  }

  Future<void> _onStopBackgroundDiscovery(
    CastStopBackgroundDiscovery event,
    Emitter<CastState> emit,
  ) async {
    final currentState = state;
    if (currentState is! CastActive) return;
    try {
      await _castService.stopDiscovery();
    } catch (e) {
      debugPrint('[Cast] stopDiscovery failed (ignored): $e');
    }
    if (currentState.availableDevices.isNotEmpty) {
      emit(currentState.copyWith(availableDevices: const []));
    }
  }

  void _onDeviceListUpdated(
    CastDeviceListUpdated event,
    Emitter<CastState> emit,
  ) {
    final currentState = state;
    if (currentState is CastDiscovering) {
      emit(
        CastDiscovering(
          devices: event.devices,
          pendingItems: currentState.pendingItems,
        ),
      );
    } else if (currentState is CastActive) {
      emit(currentState.copyWith(availableDevices: event.devices));
    }
  }

  Future<void> _onSessionStateChanged(
    CastSessionStateChanged event,
    Emitter<CastState> emit,
  ) async {
    switch (event.state) {
      case CastSessionState.connected:
        final currentState = state;
        // A live session supersedes any snapshot kept for retry.
        _itemsBeforeError = const [];
        if (currentState is CastConnecting) {
          final pendingItems = currentState.pendingItems;
          final initialQueue = _initialQueue(pendingItems: pendingItems);

          emit(CastActive(device: currentState.device, queue: initialQueue));

          final first = initialQueue.currentItem;
          if (first != null) {
            await _castService.sendMedia(
              first,
              overlay: CastOverlayConfigFromQueue.from(initialQueue, first),
            );
            _restartSlideshowTimer(initialQueue.slideshowIntervalSeconds);
            unawaited(_preloadLookahead(initialQueue));
          }
        } else if (currentState is CastActive) {
          emit(currentState.copyWith(sessionState: CastSessionState.connected));
        }

      case CastSessionState.disconnected:
        _stopSlideshowTimer();
        emit(const CastState.idle());

      case CastSessionState.error:
        // Mid-session drop (receiver slept, left the network, or another
        // sender took it over). Keep the queue for the retry path.
        _emitFailure(
          emit,
          'Cast connection lost. The screen may have gone to sleep or left '
          'the network.',
        );

      case CastSessionState.connecting:
        // Handled by connectToDevice — no state change needed here.
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Slideshow timer
  // ---------------------------------------------------------------------------

  void _restartSlideshowTimer(int intervalSeconds) {
    _stopSlideshowTimer();
    if (intervalSeconds <= 0) return;

    _slideshowTimer = Timer.periodic(Duration(seconds: intervalSeconds), (_) {
      final currentState = state;
      if (currentState is! CastActive || currentState.queue.isPaused) return;
      final queue = currentState.queue;
      switch (queue.repeatMode) {
        case CastRepeatMode.one:
          // Re-send the same item to refresh the slide on the receiver.
          add(CastEvent.skipToIndex(queue.currentIndex));
        case CastRepeatMode.all:
          if (queue.hasNext) {
            add(const CastEvent.skipNext());
          } else {
            add(const CastEvent.skipToIndex(0));
          }
        case CastRepeatMode.off:
          if (queue.hasNext) {
            add(const CastEvent.skipNext());
          }
        // At end with repeat off: stop advancing. The current item stays.
      }
    });
  }

  void _stopSlideshowTimer() {
    _slideshowTimer?.cancel();
    _slideshowTimer = null;
  }

  @override
  Future<void> close() async {
    _stopSlideshowTimer();
    await _deviceSub?.cancel();
    await _sessionSub?.cancel();
    await _mirrorSub?.cancel();
    await _externalDisplayController.close();
    return super.close();
  }
}
