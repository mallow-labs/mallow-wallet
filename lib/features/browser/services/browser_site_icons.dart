import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

/// Site icons the WebView drew for itself, keyed by the icon URL they came
/// from. The page renders them with its own cookies, certificate exception
/// and network route, so they exist where the image CDN cannot fetch the URL:
/// behind a bot checkpoint, on a private address, or with a self-signed
/// certificate.
///
/// Also kept as files in the app's cache directory, so a restored tab, the
/// "Continue browsing" card and the tab switcher show the icon before the
/// page loads again; a cache purge only costs that head start. Memory and
/// files are dropped on "Clear browsing data" and on app reset.
class BrowserSiteIcons extends ChangeNotifier {
  BrowserSiteIcons._();
  static final instance = BrowserSiteIcons._();

  static const _capacity = 64;

  /// Icons kept on disk, matching the sites the browser remembers.
  static const _storedCapacity = 100;
  final _icons = LinkedHashMap<String, Uint8List>();

  /// Icons already looked for on disk since the last clear.
  final _looked = <String>{};
  int _generation = 0;

  /// The last queued file write or delete, while one is pending. Not kept
  /// once idle: a completed future belongs to the zone that made it, and a
  /// widget test's fake clock would never run an await on it from elsewhere.
  Future<void>? _diskTail;

  /// Where the icon files live. Null keeps icons in memory only, which is
  /// the default so tests never wait on disk; [useCacheDirectory] sets it at
  /// app start.
  static Future<Directory> Function()? directory;

  static void useCacheDirectory() => directory = () async => Directory(
    '${(await getApplicationCacheDirectory()).path}/browser_site_icons',
  );

  /// The drawn icon for [icon], or null. A miss looks for a stored one once
  /// and notifies listeners if it turns up.
  Uint8List? operator [](Uri? icon) {
    if (icon == null) return null;
    final key = icon.toString();
    final drawn = _icons[key];
    if (drawn == null && directory != null && _looked.add(key)) {
      unawaited(_restore(key));
    }
    return drawn;
  }

  /// Reads the stored icons for [icons] into memory, for the tabs about to
  /// be shown.
  Future<void> preload(Iterable<Uri?> icons) => Future.wait([
    if (directory != null)
      for (final icon in icons)
        if (icon != null && _looked.add(icon.toString()))
          _restore(icon.toString()),
  ]);

  void put(Uri icon, Uint8List bytes) {
    final key = icon.toString();
    _looked.add(key);
    _remember(key, bytes);
    if (directory != null) _queue(() => _store(key, bytes));
  }

  void _remember(String key, Uint8List bytes) {
    final previous = _icons.remove(key);
    if (previous != null) _evict(previous);
    _icons[key] = bytes;
    while (_icons.length > _capacity) {
      _evict(_icons.remove(_icons.keys.first)!);
    }
    notifyListeners();
  }

  /// Drops the icons in memory; [stored] also deletes the files, as clearing
  /// browsing data does. Closing tabs keeps them.
  Future<void> clear({bool stored = false}) {
    _generation++;
    _looked.clear();
    if (_icons.isNotEmpty) {
      _icons.values.forEach(_evict);
      _icons.clear();
      notifyListeners();
    }
    if (stored && directory != null) _queue(_deleteAll);
    return settled;
  }

  /// Completes once every queued file write and delete has finished.
  Future<void> get settled => _diskTail ?? Future.value();

  void _queue(Future<void> Function() task) {
    late final Future<void> tail;
    tail = _diskTail = settled.then((_) async {
      try {
        await task();
      } catch (_) {
        // Icons are cosmetic: without the file the page draws it again.
      }
      if (identical(_diskTail, tail)) _diskTail = null;
    });
  }

  static Future<File> _file(Directory dir, String key) async =>
      File('${dir.path}/${sha256.convert(utf8.encode(key))}.png');

  Future<void> _restore(String key) async {
    final generation = _generation;
    try {
      // After pending writes and deletes, so a clear cannot be undone by a
      // read that started before it.
      await settled;
      final dir = await directory?.call();
      if (dir == null) return;
      final file = await _file(dir, key);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      if (generation != _generation || _icons.containsKey(key)) return;
      if (!isBrowserIconPng(bytes)) return;
      _remember(key, bytes);
    } catch (_) {
      // An unreadable file: as if nothing were stored.
    }
  }

  Future<void> _store(String key, Uint8List bytes) async {
    final generation = _generation;
    final dir = await directory?.call();
    if (dir == null || generation != _generation) return;
    await dir.create(recursive: true);
    await (await _file(dir, key)).writeAsBytes(bytes, flush: true);
    final files = await dir
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();
    if (files.length <= _storedCapacity) return;
    final dated = [
      for (final file in files) (file: file, at: await file.lastModified()),
    ]..sort((a, b) => a.at.compareTo(b.at));
    for (final old in dated.take(files.length - _storedCapacity)) {
      await old.file.delete();
    }
  }

  Future<void> _deleteAll() async {
    final dir = await directory?.call();
    if (dir != null && await dir.exists()) await dir.delete(recursive: true);
  }

  static void _evict(Uint8List bytes) {
    try {
      PaintingBinding.instance.imageCache.evict(MemoryImage(bytes));
    } catch (_) {
      // No painting binding (pure unit tests): nothing was decoded.
    }
  }
}

/// The largest edge, in pixels, that a captured icon may declare: the
/// largest site tile (64 dp) at 3x.
const browserIconCaptureSize = 192;

/// Validates the page's capture result: a base64 PNG data URL, bounded in
/// length, whose header declares at most a [browserIconCaptureSize] square.
/// The page can return any string here, so the header is checked before the
/// image decoder ever sees the bytes.
Uint8List? decodeBrowserIconCapture(Object? value) {
  const prefix = 'data:image/png;base64,';
  if (value is! String ||
      !value.startsWith(prefix) ||
      value.length > 256 * 1024) {
    return null;
  }
  final Uint8List bytes;
  try {
    bytes = base64Decode(value.substring(prefix.length));
  } catch (_) {
    return null;
  }
  return isBrowserIconPng(bytes) ? bytes : null;
}

/// Whether [bytes] start like a PNG whose header declares at most a
/// [browserIconCaptureSize] square.
bool isBrowserIconPng(Uint8List bytes) {
  const header = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82];
  if (bytes.length < 24) return false;
  for (var i = 0; i < header.length; i++) {
    if (bytes[i] != header[i]) return false;
  }
  final data = ByteData.sublistView(bytes);
  final width = data.getUint32(16), height = data.getUint32(20);
  if (width == 0 || height == 0) return false;
  return width <= browserIconCaptureSize && height <= browserIconCaptureSize;
}
