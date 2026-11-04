import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A main-frame load the platform refused because the server's certificate
/// is not trusted.
class BrowserCertificateFailure {
  const BrowserCertificateFailure({
    required this.url,
    required this.fingerprint,
    required this.overridable,
    required this.reason,
  });

  /// The page that failed. An exception is granted for its origin together
  /// with [fingerprint].
  final Uri url;

  /// SHA-256 of the leaf certificate's DER encoding, or null when the
  /// platform did not supply the certificate. Without it there is nothing
  /// to pin an exception to, so the failure cannot be bypassed.
  final String? fingerprint;

  /// Whether the user may proceed. Failures the platform marks as fatal, and
  /// those without a certificate, can never be bypassed.
  final bool overridable;

  /// A short, Chrome-style error name shown in the warning's details.
  final String reason;

  String get origin => url.origin;
}

/// Certificates the user chose to trust despite a failed check, per site.
///
/// An exception pins one origin to the leaf certificate the user saw on the
/// warning (its SHA-256 [BrowserCertificateFailure.fingerprint]). The same
/// certificate opens without a warning from then on; any other one, as an
/// attacker intercepting the connection would present, warns again. The
/// exceptions are kept in the OS secure store beside the wallet's site grants
/// and last until "Clear browsing data" or an app reset. Failures the
/// platform marks as fatal still stop the load.
///
/// A page on an origin with an exception never counts as verified: the
/// address bar marks it not secure, saved HTTP sign-in details are not sent
/// to it unasked, and it cannot connect a wallet or request a signature on
/// an old grant. See `DappFrameContext.certificateException`.
class BrowserCertificateExceptions extends ChangeNotifier {
  BrowserCertificateExceptions({
    FlutterSecureStorage? storage,
    Future<String?> Function()? read,
    Future<void> Function(String?)? write,
    Future<void> Function()? deleteLegacy,
  }) {
    final secure =
        storage ??
        const FlutterSecureStorage(
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.unlocked_this_device,
            accountName: 'mallow_wallet',
          ),
        );
    _read = read ?? () => secure.read(key: storageKey);
    _write =
        write ??
        (value) => value == null
            ? secure.delete(key: storageKey)
            : secure.write(key: storageKey, value: value);
    _deleteLegacy =
        deleteLegacy ??
        (read == null
            ? () => secure.delete(key: legacyStorageKey)
            : () async {});
  }

  static final instance = BrowserCertificateExceptions();

  /// `{origin: [fingerprint, ...]}`.
  static const storageKey = 'browser.certificate_exceptions.v2';

  /// The first format: a list of origins, each trusted with any certificate.
  /// Those exceptions name no certificate to pin, so they are dropped and
  /// each site warns again once.
  static const legacyStorageKey = 'browser.certificate_exceptions.v1';

  /// A server that rotates its certificate keeps a few accepted ones; the
  /// oldest goes first.
  static const maxCertificatesPerOrigin = 4;

  late final Future<String?> Function() _read;
  late final Future<void> Function(String?) _write;
  late final Future<void> Function() _deleteLegacy;

  final Map<String, List<String>> _allowed = {};
  Future<void>? _loaded;
  Future<void> _tail = Future.value();

  /// Bumped by [clear], so a read that started before it cannot bring the
  /// cleared origins back.
  int _revision = 0;

  /// Reads the saved exceptions once. Never throws: an unreadable store
  /// leaves none, so the warning shows again.
  Future<void> load() => _loaded ??= _restore();

  Future<void> _restore() async {
    final revision = _revision;
    try {
      await _deleteLegacy();
    } catch (_) {
      // Never read, so a leftover legacy row trusts nothing.
    }
    try {
      final encoded = await _read();
      if (encoded == null || revision != _revision) return;
      final rows = jsonDecode(encoded);
      if (rows is! Map) return;
      var changed = false;
      for (final MapEntry(:key, :value) in rows.entries) {
        if (key is! String || !_isOrigin(key) || value is! List) continue;
        for (final fingerprint in value.whereType<String>()) {
          if (_isFingerprint(fingerprint)) {
            changed = _add(key, fingerprint) || changed;
          }
        }
      }
      if (changed) notifyListeners();
    } catch (_) {
      // Fails closed: the site warns again.
    }
  }

  static bool _isOrigin(String origin) {
    final uri = Uri.tryParse(origin);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.origin == origin;
  }

  static final _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

  static bool _isFingerprint(String fingerprint) =>
      _fingerprintPattern.hasMatch(fingerprint);

  bool _add(String origin, String fingerprint) {
    final certificates = _allowed.putIfAbsent(origin, () => []);
    if (certificates.contains(fingerprint)) return false;
    certificates.add(fingerprint);
    while (certificates.length > maxCertificatesPerOrigin) {
      certificates.removeAt(0);
    }
    return true;
  }

  /// Opens [origin] without a warning from now on, while it presents the
  /// certificate with [fingerprint]. The exception applies at once; saving
  /// it is best effort, so a failed write only means the site warns again
  /// after a restart.
  Future<void> allow(String origin, String fingerprint) async {
    if (!_isOrigin(origin) || !_isFingerprint(fingerprint)) return;
    if (!_add(origin, fingerprint)) return;
    notifyListeners();
    try {
      await _persist();
    } catch (_) {
      // The in-memory exception still holds for this run.
    }
  }

  /// Whether the user accepted the certificate with [fingerprint] on
  /// [origin]. Accurate once [load] has finished; the trust callback awaits
  /// it before any page on the origin can load.
  bool allows(String origin, String fingerprint) =>
      _allowed[origin]?.contains(fingerprint) ?? false;

  /// Whether [origin] has any exception, so a document from it may have been
  /// loaded with an unverified identity. Which certificate a committed page
  /// used is not reported by every platform, so this errs toward unverified.
  bool covers(String origin) => _allowed[origin]?.isNotEmpty ?? false;

  /// [covers] for any port of [host]. Android reports some challenges with
  /// the page's port rather than the server's.
  bool coversHost(String host) {
    final wanted = host.toLowerCase();
    return _allowed.entries.any(
      (entry) =>
          entry.value.isNotEmpty &&
          Uri.tryParse(entry.key)?.host.toLowerCase() == wanted,
    );
  }

  /// Forgets every exception. Android's WebView also remembers each proceed
  /// on its own, for the life of the process, and only a live WebView can
  /// clear that, so the next one does: see [syncPlatform].
  Future<void> clear() async {
    final had = _allowed.isNotEmpty;
    _platformStale = _platformStale || had;
    _allowed.clear();
    _revision++;
    // Nothing saved before now may come back, so skip a read not yet begun.
    _loaded ??= Future.value();
    if (had) notifyListeners();
    try {
      await _deleteLegacy();
    } catch (_) {
      // Never read, so a leftover legacy row trusts nothing.
    }
    await _persist();
  }

  /// Writes the current set, after the saved one was merged in and behind
  /// any earlier write.
  Future<void> _persist() {
    final result = _tail.then((_) async {
      await load();
      final origins =
          _allowed.keys.where((origin) => _allowed[origin]!.isNotEmpty).toList()
            ..sort();
      await _write(
        origins.isEmpty
            ? null
            : jsonEncode({
                for (final origin in origins) origin: _allowed[origin],
              }),
      );
    });
    _tail = result.catchError((_) {});
    return result;
  }

  bool _platformStale = false;

  /// Drops the WebView's remembered proceeds once exceptions were cleared.
  /// Call before a new WebView loads anything.
  Future<void> syncPlatform(InAppWebViewController controller) async {
    if (!_platformStale || !Platform.isAndroid) return;
    await controller.clearSslPreferences();
    _platformStale = false;
  }

  @visibleForTesting
  void reset() {
    _allowed.clear();
    _loaded = null;
    _tail = Future.value();
    _revision++;
    _platformStale = false;
  }
}

String browserCertificateFingerprint(Uint8List der) =>
    sha256.convert(der).toString();

/// The certificate problem in a server-trust [challenge], or null when the
/// certificate is valid and the platform's own validation should run.
///
/// Android reports this callback only for certificate errors. iOS reports
/// every HTTPS connection and evaluates the trust itself: a valid certificate
/// comes back as no error or `UNSPECIFIED` (trusted without explicit user
/// intent), and only `RECOVERABLE_TRUST_FAILURE` is one a user may override.
BrowserCertificateFailure? browserCertificateFailure(
  URLAuthenticationChallenge challenge, {
  required Uri url,
  required bool isIOS,
}) {
  final space = challenge.protectionSpace;
  final code = space.sslError?.code;
  if (isIOS && (code == null || code == SslErrorType.UNSPECIFIED)) {
    return null;
  }
  final der = space.sslCertificate?.x509Certificate?.encoded;
  final fingerprint = der == null || der.isEmpty
      ? null
      : browserCertificateFingerprint(der);
  final overridable =
      fingerprint != null &&
      (isIOS ? code == SslErrorType.RECOVERABLE_TRUST_FAILURE : true);
  return BrowserCertificateFailure(
    url: url,
    fingerprint: fingerprint,
    overridable: overridable,
    reason: _reason(code, isIOS: isIOS),
  );
}

String _reason(SslErrorType? code, {required bool isIOS}) {
  if (isIOS) {
    return code == SslErrorType.RECOVERABLE_TRUST_FAILURE
        ? 'ERR_CERT_NOT_TRUSTED'
        : 'ERR_CERT_INVALID';
  }
  if (code == SslErrorType.UNTRUSTED) return 'ERR_CERT_AUTHORITY_INVALID';
  if (code == SslErrorType.IDMISMATCH) return 'ERR_CERT_COMMON_NAME_INVALID';
  if (code == SslErrorType.EXPIRED ||
      code == SslErrorType.NOT_YET_VALID ||
      code == SslErrorType.DATE_INVALID) {
    return 'ERR_CERT_DATE_INVALID';
  }
  return 'ERR_CERT_INVALID';
}
