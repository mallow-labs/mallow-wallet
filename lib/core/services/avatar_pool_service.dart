import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../observability/app_logger.dart';
import 'avatar_palette.dart';

const _tag = 'AvatarPoolService';

/// Number of candidate avatars shown in the "Select an account image" grid.
const int kAvatarPoolSize = 28;

/// Maintains the persistent pool of candidate avatar seeds shown in the account
/// image picker.
///
/// The pool is generated once (first time the picker opens) and reused across
/// sessions — it's stored as a JSON list in the app support dir, so the same 28
/// avatars come back on every launch rather than being re-rolled each time.
///
/// On each load the pool is reconciled against the seeds already assigned to
/// accounts: any candidate that has since been "chosen" (or duplicated) is
/// dropped and a fresh one is generated to take its place, keeping an even
/// distribution across the six [kAvatarPalette] hues. Generation runs in a
/// background isolate ([compute]) so rolling/topping-up the pool never blocks
/// the UI.
@lazySingleton
class AvatarPoolService {
  AvatarPoolService() : _cacheDirOverride = null, _useIsolate = true;

  /// Test seam: fixed cache dir and synchronous (no-isolate) generation.
  @visibleForTesting
  AvatarPoolService.forTest({Directory? cacheDir})
    : _cacheDirOverride = cacheDir,
      _useIsolate = false;

  final Directory? _cacheDirOverride;
  final bool _useIsolate;

  /// Serialises concurrent [candidates] calls so two picker opens can't both
  /// generate-and-overwrite the persisted pool.
  Future<List<String>>? _inFlight;

  /// The reconciled, persisted pool of [kAvatarPoolSize] candidate seeds.
  ///
  /// [inUse] is every `avatarSeed` currently assigned to an account; those are
  /// never offered as candidates and trigger replacement of any matching pool
  /// entry.
  Future<List<String>> candidates({required Set<String> inUse}) {
    final pending = _inFlight;
    if (pending != null) return pending;
    final run = _resolve(inUse)..whenComplete(() => _inFlight = null);
    _inFlight = run;
    return run;
  }

  Future<List<String>> _resolve(Set<String> inUse) async {
    final existing = await _loadPool();
    final input = _PoolGenInput(existing: existing, inUse: inUse.toList());
    final pool = _useIsolate
        ? await compute(_generatePool, input)
        : _generatePool(input);
    await _savePool(pool);
    return pool;
  }

  Future<List<String>> _loadPool() async {
    try {
      final file = await _poolFile();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList();
    } catch (e) {
      AppLogger.warn(_tag, 'failed to read avatar pool: $e');
      return const [];
    }
  }

  Future<void> _savePool(List<String> pool) async {
    try {
      final file = await _poolFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(pool), flush: true);
    } catch (e) {
      AppLogger.warn(_tag, 'failed to persist avatar pool: $e');
    }
  }

  Future<File> _poolFile() async {
    final dir = _cacheDirOverride ?? await getApplicationSupportDirectory();
    return File('${dir.path}/avatar_pool.json');
  }
}

/// Inputs handed across the isolate boundary; must be a simple sendable value.
class _PoolGenInput {
  const _PoolGenInput({required this.existing, required this.inUse});

  final List<String> existing;
  final List<String> inUse;
}

/// Per-colour candidate target so [kAvatarPoolSize] is split as evenly as
/// possible across the palette (28 over 6 → `[5, 5, 5, 5, 4, 4]`).
List<int> _bucketTargets() {
  final n = kAvatarPalette.length;
  final base = kAvatarPoolSize ~/ n;
  final remainder = kAvatarPoolSize % n;
  return [for (var i = 0; i < n; i++) base + (i < remainder ? 1 : 0)];
}

/// Pure pool generator (top-level so it can run under [compute]).
///
/// Keeps still-valid existing seeds, then rejection-samples fresh UUIDs to top
/// each colour bucket up to its target, then interleaves the buckets so the
/// grid shows colour variety per row instead of monochrome blocks.
List<String> _generatePool(_PoolGenInput input) {
  const uuid = Uuid();
  final inUse = input.inUse.toSet();
  final targets = _bucketTargets();
  final buckets = List.generate(kAvatarPalette.length, (_) => <String>[]);
  final seen = <String>{};

  // Retain existing candidates that are still free and not over-quota.
  for (final seed in input.existing) {
    if (seed.isEmpty || inUse.contains(seed) || !seen.add(seed)) continue;
    final bucket = avatarColorIndex(seed);
    if (buckets[bucket].length < targets[bucket]) buckets[bucket].add(seed);
  }

  // Top up each bucket to its target with fresh, distinctly-coloured seeds.
  for (var bucket = 0; bucket < buckets.length; bucket++) {
    while (buckets[bucket].length < targets[bucket]) {
      final seed = uuid.v4();
      if (inUse.contains(seed) || !seen.add(seed)) continue;
      if (avatarColorIndex(seed) != bucket) continue;
      buckets[bucket].add(seed);
    }
  }

  // Round-robin interleave across colours.
  final result = <String>[];
  for (var i = 0; result.length < kAvatarPoolSize; i++) {
    var advanced = false;
    for (final bucket in buckets) {
      if (i < bucket.length) {
        result.add(bucket[i]);
        advanced = true;
      }
    }
    if (!advanced) break;
  }
  return result;
}
