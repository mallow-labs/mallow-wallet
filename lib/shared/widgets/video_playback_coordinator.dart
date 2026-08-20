import 'package:flutter/foundation.dart';

/// Caps how many inline artwork videos play at once.
///
/// Grids of NFTs (portfolio, curation, explore …) can bring dozens of video
/// tiles on-screen at once. Decoding every one of them simultaneously blows the
/// same memory budget the CDN decode-cap protects against and trips the iOS
/// watchdog on scroll. This coordinator hands out a small, fixed number of
/// "play" slots on an LRU basis: when a newly-visible tile asks to play and all
/// slots are taken, the least-recently-activated tile is evicted (paused/freed,
/// falling back to its still poster) to make room.
///
/// Off-screen tiles must [release] their slot so visible ones can claim it.
class VideoPlaybackCoordinator {
  VideoPlaybackCoordinator._();

  /// Shared instance — playback is a global, cross-screen resource.
  static final VideoPlaybackCoordinator instance = VideoPlaybackCoordinator._();

  /// Max concurrent inline players. Kept small so a scroll-heavy grid never
  /// holds more than a handful of live decoders at once.
  static const int maxConcurrent = 3;

  /// Active holders, oldest-activated first (LRU eviction pops the front).
  final List<_Slot> _active = <_Slot>[];

  /// Requests a play slot for [token]. If the pool is full, the oldest holder
  /// is evicted first (its [onEvict] runs synchronously). Re-acquiring with a
  /// token that already holds a slot just refreshes its recency.
  void acquire(Object token, VoidCallback onEvict) {
    _active.removeWhere((s) => s.token == token);
    _active.add(_Slot(token, onEvict));
    while (_active.length > maxConcurrent) {
      final evicted = _active.removeAt(0);
      evicted.onEvict();
    }
  }

  /// Releases [token]'s slot without evicting anyone else. Safe to call for a
  /// token that holds no slot.
  void release(Object token) {
    _active.removeWhere((s) => s.token == token);
  }
}

class _Slot {
  _Slot(this.token, this.onEvict);

  final Object token;
  final VoidCallback onEvict;
}
