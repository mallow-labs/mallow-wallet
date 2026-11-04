import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DappGrant {
  const DappGrant({
    required this.origin,
    required this.address,
    required this.createdAt,
    this.scopes,
  });
  final String origin;
  final String address;
  final DateTime createdAt;
  final List<String>? scopes;
  Map<String, Object?> toJson() => {
    'origin': origin,
    'address': address,
    'createdAt': createdAt.toIso8601String(),
    if (scopes != null) 'scopes': scopes,
  };
}

/// Device-local grants are stored in the OS secure store, never browsing metadata.
class DappPermissionService {
  DappPermissionService({
    FlutterSecureStorage? storage,
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
  }) {
    final secure =
        storage ??
        const FlutterSecureStorage(
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.unlocked_this_device,
            accountName: 'mallow_wallet',
          ),
        );
    _read = read ?? () => secure.read(key: _key);
    _write = write ?? (value) => secure.write(key: _key, value: value);
  }
  static const _key = 'browser.dapp_grants.v1';
  late final Future<String?> Function() _read;
  late final Future<void> Function(String) _write;
  final _changes = StreamController<void>.broadcast(sync: true);
  Future<void> _tail = Future.value();
  int _revocationRevision = 0;
  int get revocationRevision => _revocationRevision;
  Stream<void> get changes => _changes.stream;

  Future<List<DappGrant>> list() async {
    await _tail;
    return _load();
  }

  Future<List<DappGrant>> _load() async {
    final encoded = await _read();
    if (encoded == null) return [];
    try {
      final rows = jsonDecode(encoded) as List;
      return rows
          .map(
            (row) => DappGrant(
              origin: row['origin'] as String,
              address: row['address'] as String,
              createdAt: DateTime.parse(row['createdAt'] as String),
              scopes: (row['scopes'] as List?)?.cast<String>(),
            ),
          )
          .where((grant) => Uri.tryParse(grant.origin)?.scheme == 'https')
          .toList();
    } on FormatException {
      return [];
    } on TypeError {
      return [];
    }
  }

  Future<bool> isGranted(String origin, String address) async => (await list())
      .any((grant) => grant.origin == origin && grant.address == address);

  Future<bool> hasScope(String origin, String address, String scope) async =>
      (await list()).any(
        (grant) =>
            grant.origin == origin &&
            grant.address == address &&
            (grant.scopes?.contains(scope) ?? false),
      );

  Future<void> grant(
    String origin,
    String address, {
    void Function()? ensureActive,
    List<String>? scopes,
  }) => _mutate((grants) {
    final uri = Uri.parse(origin);
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.origin != origin) {
      throw ArgumentError('A canonical HTTPS origin is required');
    }
    if (scopes != null) {
      grants.removeWhere(
        (grant) => grant.origin == origin && grant.address == address,
      );
    }
    if (!grants.any(
      (grant) => grant.origin == origin && grant.address == address,
    )) {
      grants.add(
        DappGrant(
          origin: origin,
          address: address,
          createdAt: DateTime.now().toUtc(),
          scopes: scopes == null ? null : List.unmodifiable(scopes),
        ),
      );
    }
  }, ensureActive: ensureActive);
  Future<void> revoke(String origin, String address) {
    _revocationRevision++;
    return _mutate(
      (grants) => grants.removeWhere(
        (grant) => grant.origin == origin && grant.address == address,
      ),
    );
  }

  /// Revokes [origin]'s grants for every one of [addresses] in one write, so
  /// listeners see a single revocation rather than one per chain.
  Future<void> revokeAll(String origin, Set<String> addresses) {
    _revocationRevision++;
    return _mutate(
      (grants) => grants.removeWhere(
        (grant) => grant.origin == origin && addresses.contains(grant.address),
      ),
    );
  }

  Future<void> clear() {
    _revocationRevision++;
    return _mutate((grants) => grants.clear());
  }

  Future<void> _mutate(
    void Function(List<DappGrant>) change, {
    void Function()? ensureActive,
  }) {
    final result = _tail.then((_) async {
      final grants = await _load();
      final previous = jsonEncode(
        grants.map((grant) => grant.toJson()).toList(),
      );
      ensureActive?.call();
      change(grants);
      await _write(jsonEncode(grants.map((grant) => grant.toJson()).toList()));
      try {
        ensureActive?.call();
      } catch (_) {
        // Restore within the same serialized write lane, before another mutation.
        await _write(previous);
        rethrow;
      }
      _changes.add(null);
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> dispose() => _changes.close();
}
