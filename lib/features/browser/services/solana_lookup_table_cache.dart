import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:solana/base58.dart';

/// Address lookup tables the browser has read, kept across launches: most
/// websites reuse the same few tables, so their next transaction skips the
/// read.
///
/// Reusing an entry is safe because a table only grows. An address written at
/// an index stays there for the table's life, and a closed table's address
/// cannot be created again: it is derived from a slot that must be recent
/// when the table is created, and closing waits until that slot is no longer
/// recent. An entry therefore answers any lookup whose indexes it covers; a
/// lookup past its end is read again.
///
/// Bounded by [maxTables] entries and [maxBytes] of addresses, the least
/// recently used going first. Tables are public chain data, but which ones a
/// wallet used says where it has been, so clearing browsing data clears them.
class SolanaLookupTableCache {
  SolanaLookupTableCache({
    Future<File> Function()? file,
    this.maxTables = 64,
    this.maxBytes = 512 * 1024,
  }) : _file = file ?? _defaultFile;

  static final instance = SolanaLookupTableCache();

  /// A table holds at most 256 addresses.
  static const _maxAddresses = 256;

  final Future<File> Function() _file;
  final int maxTables;
  final int maxBytes;

  /// Raw 32-byte addresses by `chain table`, least recently used first.
  final _tables = <String, Uint8List>{};
  int _bytes = 0;
  Future<void>? _loading;
  Future<void> _writing = Future.value();
  var _writeQueued = false;

  /// Bumped by [clear], so a load or write already running cannot bring back
  /// what it removed.
  var _generation = 0;

  /// Completes once every write queued so far has finished.
  @visibleForTesting
  Future<void> get idle => _writing;

  static Future<File> _defaultFile() async => File(
    '${(await getApplicationCacheDirectory()).path}/browser_lookup_tables.json',
  );

  /// Reads the saved tables once. A missing or unreadable file is an empty
  /// cache.
  Future<void> load() => _loading ??= _load();

  /// The addresses of [table] on [chain], when the cached entry holds at
  /// least [covering] of them.
  List<String>? addresses(String chain, String table, {required int covering}) {
    final key = _key(chain, table);
    final bytes = _tables.remove(key);
    if (bytes == null) return null;
    // Recency is saved with the next table stored, not on every hit.
    _tables[key] = bytes;
    if (bytes.length ~/ 32 < covering) return null;
    return [
      for (var i = 0; i < bytes.length; i += 32)
        base58encode(bytes.sublist(i, i + 32)),
    ];
  }

  /// Keeps [addresses], as read from [table] on [chain].
  void store(String chain, String table, List<String> addresses) {
    if (addresses.length > _maxAddresses) return;
    final bytes = Uint8List(addresses.length * 32);
    for (var i = 0; i < addresses.length; i++) {
      final key = base58decode(addresses[i]);
      if (key.length != 32) return;
      bytes.setRange(i * 32, i * 32 + 32, key);
    }
    _put(_key(chain, table), bytes);
    _persist();
  }

  /// Drops [table] on [chain], whose cached addresses a node contradicted.
  void forget(String chain, String table) {
    final bytes = _tables.remove(_key(chain, table));
    if (bytes == null) return;
    _bytes -= bytes.length;
    _persist();
  }

  Future<void> clear() async {
    _generation++;
    _tables.clear();
    _bytes = 0;
    _loading = Future.value();
    await _writing;
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Nothing was saved, or the store is unavailable.
    }
  }

  static String _key(String chain, String table) => '$chain $table';

  void _put(String key, Uint8List bytes) {
    final old = _tables.remove(key);
    if (old != null) _bytes -= old.length;
    _tables[key] = bytes;
    _bytes += bytes.length;
    while (_tables.length > maxTables || _bytes > maxBytes) {
      final oldest = _tables.keys.first;
      _bytes -= _tables.remove(oldest)!.length;
    }
  }

  Future<void> _load() async {
    final generation = _generation;
    final saved = <String, Uint8List>{};
    try {
      final file = await _file();
      if (!await file.exists()) return;
      // Base64 in JSON stays well under twice the bytes it holds; a larger
      // file is not one this cache wrote.
      if (await file.length() > maxBytes * 2) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded case {'version': 1, 'tables': final List<Object?> tables}) {
        for (final entry in tables) {
          if (entry case {
            'key': final String key,
            'addresses': final String raw,
          } when key.contains(' ')) {
            final bytes = base64Decode(raw);
            if (bytes.isNotEmpty &&
                bytes.length % 32 == 0 &&
                bytes.length <= _maxAddresses * 32) {
              saved[key] = bytes;
            }
          }
        }
      }
    } catch (_) {
      // A damaged file is an empty cache; the next write replaces it.
      return;
    }
    if (generation != _generation) return;
    // Saved oldest first. Tables stored since launch are newer than any of
    // them, so they go last.
    final current = Map.of(_tables);
    _tables.clear();
    _bytes = 0;
    for (final MapEntry(:key, :value) in {...saved, ...current}.entries) {
      _put(key, value);
    }
  }

  void _persist() {
    if (_writeQueued) return;
    _writeQueued = true;
    final generation = _generation;
    _writing = _writing.then((_) async {
      _writeQueued = false;
      if (generation != _generation) return;
      final encoded = jsonEncode({
        'version': 1,
        'tables': [
          for (final MapEntry(:key, :value) in _tables.entries)
            {'key': key, 'addresses': base64Encode(value)},
        ],
      });
      try {
        final file = await _file();
        final partial = File('${file.path}.tmp');
        await partial.writeAsString(encoded, flush: true);
        if (generation != _generation) {
          await partial.delete();
          return;
        }
        await partial.rename(file.path);
      } catch (_) {
        // The cache still works in memory; a later write may succeed.
      }
    });
  }
}
