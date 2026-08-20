import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../di.dart';
import '../config/environment.dart';
import '../utils/address_format.dart';
import 'preferences_service.dart';

/// Sentry error tracking service with sensitive data scrubbing.
///
/// SECURITY: This service is configured to scrub:
/// - Mnemonics and seed phrases
/// - Private keys
/// - PINs and passwords
/// - Auth tokens
/// - Wallet addresses (partially redacted)
///
/// Diagnostics share the single "Share usage analytics" opt-out with the
/// product-analytics pipeline — see [PreferencesService.analyticsOptOut].
class SentryService {
  SentryService._();

  static bool _initialized = false;
  static bool _analyticsEnabled = true;

  /// Whether Sentry reporting is currently active.
  static bool get isEnabled => _initialized && _analyticsEnabled;

  /// Whether the user has opted in to analytics (independent of SDK state).
  static bool get analyticsEnabled => _analyticsEnabled;

  /// Resolve the user's diagnostics choice from the one shared preference.
  ///
  /// POLARITY: the pref stores opt-**OUT** (on-by-default), so diagnostics are
  /// enabled exactly when it is `false`. Inverting this ships the opposite of
  /// what the user asked for, silently — hence [SentryService] never stores
  /// its own copy of the key.
  ///
  /// `main()` calls `configureDependencies()` before [init], so the injected
  /// [PreferencesService] is available by the time this runs. The registration
  /// guard covers callers that run without a DI container (tests, the cast
  /// receiver isolate) and fails *safe* toward the on-by-default posture.
  static bool _readAnalyticsEnabled() {
    if (!sl.isRegistered<PreferencesService>()) return true;
    return !sl<PreferencesService>().analyticsOptOut;
  }

  /// Initialize Sentry with the app.
  ///
  /// Call this in main() before runApp():
  /// ```dart
  /// await SentryService.init(
  ///   appRunner: () => runApp(const MallowApp()),
  /// );
  /// ```
  static Future<void> init({
    required FutureOr<void> Function() appRunner,
  }) async {
    if (_initialized) {
      await appRunner();
      return;
    }

    // Respect the user's analytics opt-out preference. Resolved before the DSN
    // check so the opted-out state is recorded either way.
    _analyticsEnabled = _readAnalyticsEnabled();
    if (!_analyticsEnabled) {
      debugPrint('Analytics disabled by user, skipping Sentry initialization');
      await appRunner();
      return;
    }

    final dsn = Config.sentryDsn;

    // Skip initialization if no DSN provided
    if (dsn.isEmpty) {
      debugPrint('Sentry DSN not provided, skipping initialization');
      await appRunner();
      return;
    }

    await SentryFlutter.init(_configureOptions(dsn), appRunner: appRunner);

    _initialized = true;
  }

  /// Bring the Sentry hub in line with the current value of
  /// [PreferencesService.analyticsOptOut], mid-session.
  ///
  /// The preference itself is written by the caller (Settings) — this only
  /// applies it: closing the hub on opt-out so nothing further leaves the
  /// device, and re-initialising on opt-in without re-running the app.
  static Future<void> applyAnalyticsPreference() async {
    _analyticsEnabled = _readAnalyticsEnabled();

    if (!_analyticsEnabled) {
      if (_initialized) {
        await Sentry.close();
        _initialized = false;
      }
      return;
    }

    if (_initialized) return;

    final dsn = Config.sentryDsn;
    if (dsn.isEmpty) return;

    await SentryFlutter.init(_configureOptions(dsn));
    _initialized = true;
  }

  /// The single options block, shared by the boot path and the mid-session
  /// re-init. Kept in one place deliberately: a drift between the two is how
  /// the scrubbers silently stop applying after a toggle.
  static FlutterOptionsConfiguration _configureOptions(String dsn) {
    return (options) {
      options.dsn = dsn;
      options.environment = Config.environment.name;
      options.debug = Config.isDevelopment;
      options.tracesSampleRate = Config.isProduction ? 0.1 : 1.0;
      options.attachScreenshot =
          false; // Don't capture screenshots (may contain sensitive info)
      // ignore: experimental_member_use
      options.attachViewHierarchy = false;

      // SECURITY: the SDK default (`true`) makes DebugPrintIntegration
      // reassign the global `debugPrint` in RELEASE builds so every call site
      // writes a Sentry breadcrumb. The app has hundreds of ungated
      // `debugPrint`s; none of them are consented telemetry.
      options.enablePrintBreadcrumbs = false;

      // Configure sensitive data scrubbing
      options.beforeSend = beforeSend;
      options.beforeBreadcrumb = beforeBreadcrumb;

      // Don't send PII by default
      options.sendDefaultPii = false;
    };
  }

  /// Capture an exception with optional context.
  static Future<void> captureException(
    dynamic exception, {
    dynamic stackTrace,
    String? message,
    Map<String, dynamic>? extras,
  }) async {
    if (!isEnabled) return;

    await Sentry.captureException(
      exception,
      stackTrace: stackTrace,
      withScope: (scope) {
        if (message != null) {
          scope.setContexts('info', {'message': message});
        }
        if (extras != null) {
          // Scrub extras before adding
          final scrubbedExtras = _scrubMap(extras);
          scope.setContexts('extras', scrubbedExtras);
        }
      },
    );
  }

  /// Capture a message for logging.
  static Future<void> captureMessage(
    String message, {
    SentryLevel level = SentryLevel.info,
    Map<String, dynamic>? extras,
  }) async {
    if (!isEnabled) return;

    // Scrub the message
    final scrubbedMessage = scrubString(message);

    await Sentry.captureMessage(
      scrubbedMessage,
      level: level,
      withScope: (scope) {
        if (extras != null) {
          scope.setContexts('extras', _scrubMap(extras));
        }
      },
    );
  }

  /// Add a breadcrumb for debugging.
  static void addBreadcrumb({
    required String message,
    String? category,
    Map<String, dynamic>? data,
    SentryLevel level = SentryLevel.info,
  }) {
    if (!isEnabled) return;

    Sentry.addBreadcrumb(
      Breadcrumb(
        message: scrubString(message),
        category: category,
        data: data != null ? _scrubMap(data) : null,
        level: level,
      ),
    );
  }

  /// Set user context (wallet address, redacted).
  static void setUser(String? walletAddress) {
    if (!isEnabled) return;

    if (walletAddress == null) {
      Sentry.configureScope((scope) => scope.setUser(null));
      return;
    }

    // Redact wallet address: show first 4 and last 4 chars
    final redactedAddress = _redactAddress(walletAddress);

    Sentry.configureScope((scope) {
      scope.setUser(SentryUser(id: redactedAddress));
    });
  }

  // ============ Private Scrubbing Methods ============

  /// Scrub sensitive data before sending to Sentry.
  @visibleForTesting
  static SentryEvent? beforeSend(SentryEvent event, Hint hint) {
    // Scrub the message (v9.x: direct property assignment)
    if (event.message != null) {
      event.message = SentryMessage(scrubString(event.message!.formatted));
    }

    // Scrub exception values (v9.x: direct property assignment)
    if (event.exceptions != null) {
      final scrubbedExceptions = event.exceptions!.map((ex) {
        return SentryException(
          type: ex.type,
          value: ex.value != null ? scrubString(ex.value!) : null,
          module: ex.module,
          stackTrace: ex.stackTrace,
          mechanism: ex.mechanism,
          threadId: ex.threadId,
        );
      }).toList();

      event.exceptions = scrubbedExceptions;
    }

    return event;
  }

  /// Scrub breadcrumbs before adding.
  @visibleForTesting
  static Breadcrumb? beforeBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
    if (breadcrumb == null) return null;

    return Breadcrumb(
      message: scrubString(breadcrumb.message ?? ''),
      category: breadcrumb.category,
      data: breadcrumb.data != null ? _scrubMap(breadcrumb.data!) : null,
      level: breadcrumb.level,
      timestamp: breadcrumb.timestamp,
      type: breadcrumb.type,
    );
  }

  // Scrub patterns, compiled once — [beforeBreadcrumb] runs [scrubString]
  // over every string in every auto-breadcrumb (navigation, http), and Dart
  // does not cache `RegExp(...)`.

  // Mnemonic/seed phrases (12-24 words). The separator class covers both a
  // plain phrase ("abandon abandon …") and a stringified Dart list
  // ("[abandon, abandon, …]") — the latter is how a `List<String>` mnemonic
  // reaches a log line.
  static final _mnemonicPhrase = RegExp(
    r'\b([a-z]+[,\s]+){11,23}[a-z]+\b',
    caseSensitive: false,
  );

  // `0x`-prefixed private keys. The bare-hex rule below cannot see these:
  // there is no word boundary between the `x` and the first hex digit, so
  // `\b[a-fA-F0-9]{64}\b` never matches them.
  static final _hexKey0x = RegExp(r'0x[a-fA-F0-9]{64}\b');

  // Private keys (64 hex chars).
  static final _hexKey = RegExp(r'\b[a-fA-F0-9]{64}\b');

  // Base58 secret keys. A 64-byte Solana keypair encodes to ~87-88 base58
  // chars — far longer than the 32-44 an address occupies, so these are
  // redacted whole rather than truncated: no key material may survive.
  static final _base58Secret = RegExp(r'\b[1-9A-HJ-NP-Za-km-z]{60,}\b');

  // Solana addresses (32-44 base58 chars).
  static final _base58Address = RegExp(r'\b[1-9A-HJ-NP-Za-km-z]{32,44}\b');

  // PINs (4-6 digits).
  static final _pin = RegExp(r'(?:pin|PIN|passcode)[\s:=]*(\d{4,6})');
  static final _digit = RegExp(r'\d');

  // Tokens/auth.
  static final _authToken = RegExp(
    r'(?:token|auth|bearer|jwt)[\s:=]*["\x27]?([A-Za-z0-9._-]{20,})["\x27]?',
    caseSensitive: false,
  );

  // Common sensitive key names. The negative lookbehind stops this pass from
  // eating the markers the earlier rules just wrote: without it
  // `[REDACTED_MNEMONIC]` matches `mnemonic` and degrades to
  // `[REDACTED_mnemonic: [REDACTED]`.
  static final List<(String, RegExp)> _sensitiveKeys = [
    for (final key in [
      'mnemonic',
      'seed',
      'private_key',
      'privateKey',
      'secret',
      'password',
    ])
      (
        key,
        RegExp(
          '(?<!\\[REDACTED_)$key[\\s:=]*["\']?([^"\'\\s,}]+)["\']?',
          caseSensitive: false,
        ),
      ),
  ];

  /// Scrub a string for sensitive data.
  @visibleForTesting
  static String scrubString(String input) {
    var result = input;

    result = result.replaceAllMapped(
      _mnemonicPhrase,
      (match) => '[REDACTED_MNEMONIC]',
    );
    result = result.replaceAllMapped(_hexKey0x, (match) => '[REDACTED_KEY]');
    result = result.replaceAllMapped(_hexKey, (match) => '[REDACTED_KEY]');
    result = result.replaceAllMapped(
      _base58Secret,
      (match) => '[REDACTED_KEY]',
    );
    result = result.replaceAllMapped(
      _base58Address,
      (match) => _redactAddress(match.group(0)!),
    );
    result = result.replaceAllMapped(
      _pin,
      (match) => '${match.group(0)?.replaceAll(_digit, '*')}',
    );
    result = result.replaceAllMapped(_authToken, (match) => '[REDACTED_TOKEN]');
    for (final (key, pattern) in _sensitiveKeys) {
      result = result.replaceAllMapped(pattern, (match) => '$key: [REDACTED]');
    }

    return result;
  }

  /// Scrub a map recursively.
  static Map<String, dynamic> _scrubMap(Map<String, dynamic> input) {
    final result = <String, dynamic>{};

    for (final entry in input.entries) {
      final key = entry.key.toLowerCase();

      // Check if this is a sensitive key
      if (_isSensitiveKey(key)) {
        result[entry.key] = '[REDACTED]';
        continue;
      }

      // Process the value
      final value = entry.value;
      if (value is String) {
        result[entry.key] = scrubString(value);
      } else if (value is Map<String, dynamic>) {
        result[entry.key] = _scrubMap(value);
      } else if (value is List) {
        result[entry.key] = _scrubList(value);
      } else {
        result[entry.key] = value;
      }
    }

    return result;
  }

  /// Scrub a list recursively.
  static List<dynamic> _scrubList(List<dynamic> input) {
    // A mnemonic carried as `List<String>` survives per-entry scrubbing —
    // every individual word is innocuous. Catch the shape before recursing.
    if (_looksLikeMnemonicList(input)) return const ['[REDACTED_MNEMONIC]'];

    return input.map((item) {
      if (item is String) {
        return scrubString(item);
      } else if (item is Map<String, dynamic>) {
        return _scrubMap(item);
      } else if (item is List) {
        return _scrubList(item);
      } else {
        return item;
      }
    }).toList();
  }

  /// Whether [input] has the shape of a BIP-39 phrase split into one word per
  /// entry: 12-24 items, each a short all-lowercase word.
  static bool _looksLikeMnemonicList(List<dynamic> input) {
    if (input.length < 12 || input.length > 24) return false;
    return input.every((e) => e is String && _bip39Word.hasMatch(e));
  }

  /// BIP-39 words are 3-8 lowercase ASCII letters.
  static final _bip39Word = RegExp(r'^[a-z]{3,8}$');

  /// Check if a key name suggests sensitive data.
  static bool _isSensitiveKey(String key) {
    const sensitivePatterns = [
      'mnemonic',
      'seed',
      'private',
      'secret',
      'password',
      'pin',
      'passcode',
      'token',
      'auth',
      'key',
      'credential',
    ];

    for (final pattern in sensitivePatterns) {
      if (key.contains(pattern)) return true;
    }

    return false;
  }

  /// Redact an address to show only first and last 4 characters.
  static String _redactAddress(String address) {
    if (address.length <= 8) return '[REDACTED_ADDR]';
    return truncateAddress(address, lead: 4, trail: 4);
  }
}
