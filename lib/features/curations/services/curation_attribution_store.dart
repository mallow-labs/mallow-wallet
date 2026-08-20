import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:injectable/injectable.dart';

import '../../../core/services/preferences_service.dart';

/// Device-local memory of which curation surfaced an artwork, so a later
/// purchase can be attributed to that curator.
///
/// [record] is called at curation tap-through (`CurationScreen`), and
/// [shareSlugFor] at buy time (`MarketBloc` stamps the slug onto the v2 buy
/// request, which the backend writes as a `curation:<SLUG>` memo and joins to
/// the sale when it indexes it). Attribution is **last-touch per mint**: the
/// most recent curation the artwork was opened from wins, whatever surface the
/// buy itself happens on.
///
/// Only the 8-letter share slug is kept — the curator wallet is resolved
/// server-side at stamp time, so no curator address ever lands in device
/// storage. Entries expire after [ttl] and the map is capped at [maxEntries],
/// oldest evicted. Persisted as one JSON blob through [PreferencesService], so
/// the app-reset wipe (`PreferencesService.clearAll`) clears it along with
/// every other preference.
@lazySingleton
class CurationAttributionStore {
  CurationAttributionStore(this._prefs) {
    _hydrate();
  }

  /// How long a view stays attributable. Beyond it a purchase is no longer
  /// plausibly driven by the curation, so the entry is dropped rather than
  /// credited.
  static const Duration ttl = Duration(days: 7);

  /// Ceiling on remembered mints. SharedPreferences is parsed into memory
  /// whole at startup, so this is a bounded cache, not a browse history —
  /// forgetting the oldest view only costs one attribution.
  static const int maxEntries = 200;

  /// Injected clock so TTL expiry is testable without waiting 7 days.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  final PreferencesService _prefs;

  /// mint → most recent view. Insertion-ordered (oldest first), so eviction is
  /// `keys.first`; [record] re-inserts a re-viewed mint at the end.
  final Map<String, _Attribution> _entries = {};

  /// Remember that [mintAccount] was opened from the curation [shareSlug].
  /// Last touch wins. Fire-and-forget — the write is not awaited, and a failed
  /// persist only costs the attribution.
  void record({required String mintAccount, required String shareSlug}) {
    final now = clock();
    _entries
      ..remove(mintAccount)
      ..[mintAccount] = _Attribution(shareSlug, now);
    _prune(now);
    unawaited(_persist());
  }

  /// The curation to credit a purchase of [mintAccount] to, or null when the
  /// mint was never opened from a curation or the view has aged past [ttl].
  String? shareSlugFor(String mintAccount) {
    final entry = _entries[mintAccount];
    if (entry == null) return null;
    if (clock().difference(entry.viewedAt) >= ttl) {
      _entries.remove(mintAccount);
      unawaited(_persist());
      return null;
    }
    return entry.shareSlug;
  }

  /// Drop expired entries, then the oldest survivors until the map fits
  /// [maxEntries].
  void _prune(DateTime now) {
    _entries.removeWhere((_, e) => now.difference(e.viewedAt) >= ttl);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void _hydrate() {
    final raw = _prefs.curationAttributions;
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      decoded.forEach((mint, value) {
        if (value is! Map<String, dynamic>) return;
        final entry = _Attribution.fromJson(value);
        if (entry != null) _entries[mint] = entry;
      });
    } catch (_) {
      // A corrupt blob is a cache miss, never a startup failure.
    }
  }

  Future<void> _persist() => _prefs.setCurationAttributions(
    jsonEncode({for (final e in _entries.entries) e.key: e.value.toJson()}),
  );
}

/// One remembered view: the curation's share slug and when it happened.
class _Attribution {
  const _Attribution(this.shareSlug, this.viewedAt);

  static _Attribution? fromJson(Map<String, dynamic> json) {
    final slug = json['slug'];
    final at = json['at'];
    if (slug is! String || slug.isEmpty || at is! int) return null;
    return _Attribution(slug, DateTime.fromMillisecondsSinceEpoch(at));
  }

  final String shareSlug;
  final DateTime viewedAt;

  Map<String, dynamic> toJson() => {
    'slug': shareSlug,
    'at': viewedAt.millisecondsSinceEpoch,
  };
}
