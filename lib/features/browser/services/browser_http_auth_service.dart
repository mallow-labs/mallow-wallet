import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/security/secure_storage.dart';
import '../../../di.dart';
import '../models/browser_http_credentials.dart';

typedef BrowserHttpAuthPrompt =
    Future<BrowserHttpCredentials?> Function({
      required bool failed,
      String? username,
    });

/// Remembers HTTP sign-in details in secure storage until browsing data is
/// cleared. Credentials belong to one HTTPS host, port and authentication realm.
class BrowserHttpAuthService {
  BrowserHttpAuthService({
    Future<String?> Function()? read,
    Future<void> Function(String?)? write,
  }) : _read =
           read ??
           (() => sl<SecureWalletStorage>().loadBrowserHttpCredentials()),
       _write =
           write ??
           ((value) => value == null
               ? sl<SecureWalletStorage>().deleteBrowserHttpCredentials()
               : sl<SecureWalletStorage>().storeBrowserHttpCredentials(value));

  static final instance = BrowserHttpAuthService();

  final Future<String?> Function() _read;
  final Future<void> Function(String?) _write;
  Future<void> _tail = Future.value();
  int _revision = 0;

  static String? protectionSpaceKey(URLProtectionSpace space) {
    final protocol = space.protocol?.toLowerCase();
    if (space.host.isEmpty || (protocol != null && protocol != 'https')) {
      return null;
    }
    final port = space.port;
    return jsonEncode([
      'https',
      space.host.toLowerCase(),
      port == null || port <= 0 ? 443 : port,
      space.realm,
      space.authenticationMethod?.toNativeValue(),
    ]);
  }

  /// Reuses saved details once, then asks again when the server rejects them.
  /// Cancelling a retry leaves the saved details intact.
  ///
  /// With [autofill] false the saved details are never sent unasked: the
  /// prompt opens with the saved username, and the user types the password.
  /// That is for a server whose identity is unverified, such as one whose
  /// certificate the user chose to trust despite a warning.
  Future<BrowserHttpCredentials?> resolve({
    required URLProtectionSpace protectionSpace,
    required bool failed,
    required BrowserHttpAuthPrompt prompt,
    required bool Function() isActive,
    String? proposedUsername,
    bool autofill = true,
  }) async {
    final key = protectionSpaceKey(protectionSpace);
    if (key == null || !isActive()) return null;
    final revision = _revision;
    bool active() => revision == _revision && isActive();

    BrowserHttpCredentials? saved;
    try {
      saved = await _enqueue(() async => (await _load())[key]);
    } catch (_) {
      // An unavailable secure store must not stop a manual sign-in.
    }
    if (!active()) return null;
    if (!failed && autofill && saved != null) return saved;

    final entered = await prompt(
      failed: failed,
      username: saved?.username ?? proposedUsername,
    );
    if (entered == null || !active()) return null;
    try {
      await _enqueue(() async {
        if (!active()) return;
        final entries = await _load();
        if (!active()) return;
        entries[key] = entered;
        await _write(
          jsonEncode(
            entries.map(
              (key, value) => MapEntry(key, {
                'username': value.username,
                'password': value.password,
              }),
            ),
          ),
        );
      });
    } catch (_) {
      // Persistence is best effort; never expose credential-bearing errors.
    }
    return active() ? entered : null;
  }

  Future<Map<String, BrowserHttpCredentials>> _load() async {
    final encoded = await _read();
    if (encoded == null) return {};
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid HTTP credential store');
    }
    final entries = <String, BrowserHttpCredentials>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (value is Map &&
          value['username'] is String &&
          value['password'] is String) {
        entries[entry.key] = (
          username: value['username'] as String,
          password: value['password'] as String,
        );
      }
    }
    return entries;
  }

  /// Invalidates pending reads and prompts before deleting the encrypted entry.
  Future<void> clear() {
    _revision++;
    return _enqueue(() => _write(null));
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
