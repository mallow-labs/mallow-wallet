import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:public_suffix/public_suffix.dart';

/// The bundled public suffix rules include private hosting domains. Until the
/// asset is ready, keep the full host visible and allow only exact-host icons.
class BrowserDomainPolicy {
  BrowserDomainPolicy._();

  static SuffixRules? _rules;
  static Future<void>? _loading;

  static Future<void> initialize() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      _rules = SuffixRules.fromString(
        await rootBundle.loadString('assets/data/public_suffix_list.dat'),
      );
    } catch (_) {
      _rules = null;
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _rules = null;
    _loading = null;
  }

  static String registrableDomain(String host) {
    final normalized = host.toLowerCase().replaceAll(RegExp(r'\.+$'), '');
    final rules = _rules;
    if (normalized.isEmpty || rules == null) return normalized;
    try {
      final parsed = PublicSuffix(
        url: Uri(scheme: 'https', host: normalized),
        suffixRules: rules,
      );
      if (!parsed.hasKnownSuffix() || parsed.domain == null) return normalized;
      // PublicSuffix decodes punycode; retain the spelling of the native host
      // that the address bar and WebView use while taking its label count.
      final labels = normalized.split('.');
      final count = parsed.domain!.split('.').length;
      return labels.sublist(labels.length - count).join('.');
    } catch (_) {
      return normalized;
    }
  }
}
