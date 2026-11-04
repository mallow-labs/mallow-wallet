import 'dart:convert';

import '../crypto/bip39_english_wordlist.dart';

/// Conservative filtering for diagnostic text and structured telemetry.
///
/// This is defense in depth: callers must never deliberately supply secrets.
/// Unknown objects are discarded without invoking toString or toJson.
class SecretScrubber {
  const SecretScrubber._();

  static const redacted = '[REDACTED]';

  static final Set<String> _bip39Words = bip39EnglishWordlist.toSet();
  static final _letters = RegExp('[A-Za-z]+');

  /// Fewest wordlist words redacted as a phrase: one short of the shortest
  /// BIP39 mnemonic, so a 12-word phrase that lost a word, or carries one
  /// mistyped word, still counts.
  static const _minPhraseWords = 11;

  /// Shortest non-wordlist token that may sit inside a phrase without ending
  /// it, standing in for a mistyped word. One- and two-letter tokens never
  /// qualify: most of the function words that keep prose from reading as a
  /// phrase (`a`, `is`, `of`, `to`, `in`, `an`) are that short.
  static const _minStrayLetters = 3;

  /// Longest gap of non-letters that still joins two words of one phrase. It
  /// covers quotes, commas, newlines, JSON indentation and list numbering.
  static const _maxPhraseGap = 32;

  // No word boundaries: a secret glued to `_`, `l` or `0` must not escape.
  static final _hex = RegExp(r'(?:0[xX])?[a-fA-F0-9]{64,}');
  static final _evmAddress = RegExp(
    r'(?<![a-fA-F0-9])0[xX][a-fA-F0-9]{40}(?![a-fA-F0-9])',
  );
  static final _tezos = RegExp(
    r'(?<![A-Za-z0-9])(?:edsk|spsk|p2sk)[1-9A-HJ-NP-Za-km-z]+',
  );
  // A base58-encoded 32-byte seed can look exactly like a public address.
  static final _base58 = RegExp(
    r'(?<![1-9A-HJ-NP-Za-km-z])[1-9A-HJ-NP-Za-km-z]{32,}(?![1-9A-HJ-NP-Za-km-z])',
  );
  static final _base64 = RegExp(
    r'(?<![A-Za-z0-9+/_-])[A-Za-z0-9+/_-]{43,}={0,2}',
  );
  static final _bytes = RegExp(r'\[\s*\d{1,3}(?:\s*,\s*\d{1,3}){15,}\s*\]');
  // The same list without brackets, as `bytes.join(', ')` prints it: sixteen
  // or more byte values, decimal (0-255) or `0x`-prefixed. A decimal fraction
  // never starts or ends a match, so `1.5, 2.5, …` is left alone.
  static final _bareBytes = RegExp(
    r'(?<![\d.])(?:0[xX][0-9a-fA-F]{1,2}|25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)'
    r'(?:\s*,\s*(?:0[xX][0-9a-fA-F]{1,2}|25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){15,}'
    r'(?![\d.])',
  );
  // Hex bytes separated by spaces or colons (`de ad be ef`, `de:ad:be:ef`),
  // as a hex dump or a fingerprint-style formatter prints them. Sixteen bytes
  // or more: the entropy of a 12-word phrase.
  static final _spacedHex = RegExp(
    r'(?<![0-9A-Za-z])[0-9a-fA-F]{2}(?:[ :][0-9a-fA-F]{2}){15,}(?![0-9A-Za-z])',
  );
  static final _assignment = RegExp(
    r'''\b(?:mnemonic|seed(?:[ _+-]?phrase)?|recovery[ _+-]?phrase|priv(?:ate)?[ _+-]?key|api[ _+-]?key|access[ _+-]?key|key[ _+-]?pair|secret(?:[ _+-]?key)?|password|passcode|pin|token|authorization|bearer|jwt)\b["']?[\s+]*[:=]\s*.+''',
    caseSensitive: false,
    dotAll: true,
  );
  static final _bearer = RegExp(r'\bBearer[\s+]+\S+', caseSensitive: false);
  static final _percentRun = RegExp('(?:%[0-9A-Fa-f]{2})+');

  // A path segment: a UUID, or `_`/`-`-joined words that are lowercase,
  // camelCase or CamelCase, each optionally followed by digits.
  static final _uuid = RegExp(
    r'^[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$',
  );
  static final _pathWord = RegExp(
    r'^(?:[0-9]+|[a-z]+[0-9]*(?:[A-Z][a-z]+[0-9]*)*|(?:[A-Z][a-z]+[0-9]*)+)$',
  );

  static final _protocolId = RegExp(r'^[a-fA-F0-9]{16,32}$');
  // Build IDs (up to 20 bytes) and UUID debug IDs with an optional age. Too
  // short to hold a 32-byte key in any encoding this class recognises.
  static final _nativeId = RegExp(
    r'^(?:[0-9a-fA-F]{8,40}|[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}(?:-[0-9a-fA-F]{1,8})?)$',
  );

  /// SDK identifiers needed to deserialize, group or symbolicate an event,
  /// passed through only when the value has the identifier's exact shape.
  static final _structuralIds = <String, RegExp>{
    'event_id': _protocolId,
    'trace_id': _protocolId,
    'span_id': _protocolId,
    'parent_span_id': _protocolId,
    'debug_id': _nativeId,
    'code_id': _nativeId,
  };

  static String scrubString(String input) {
    if (input.length > 16384) return redacted;
    try {
      final output = _scrubPlain(input);
      // Percent encoding must not conceal secrets in URLs or exception
      // messages. Scrubbing has to commute with decoding: if the decoded input
      // scrubs differently from the decoded output, the encoding hid something
      // the plain pass could not see, so the whole message goes. Bounded
      // rounds cover double-encoded query parameters.
      var decodedInput = input;
      var decodedOutput = output;
      for (var round = 0; round < 3; round++) {
        final next = _percentDecode(decodedInput);
        if (next == decodedInput) break;
        decodedInput = next;
        decodedOutput = _percentDecode(decodedOutput);
        if (_scrubPlain(decodedInput) != decodedOutput) return redacted;
      }
      return output;
    } catch (_) {
      // Never fall back to the unscrubbed input.
      return redacted;
    }
  }

  /// Decodes only well-formed `%XX` runs, so a bare `%`, `%zz` or non-ASCII
  /// text beside an escape stays as written instead of failing the message.
  /// `+` is left alone: the patterns below accept it as a separator.
  static String _percentDecode(String input) {
    if (!input.contains('%')) return input;
    return input.replaceAllMapped(_percentRun, (match) {
      final run = match[0]!;
      return utf8.decode([
        for (var i = 0; i < run.length; i += 3)
          int.parse(run.substring(i + 1, i + 3), radix: 16),
      ], allowMalformed: true);
    });
  }

  static String _scrubPlain(String input) => _replaceMnemonics(input)
      .replaceAll(_hex, '[REDACTED_KEY]')
      .replaceAll(_spacedHex, '[REDACTED_KEY]')
      .replaceAll(_evmAddress, '[REDACTED_ADDRESS]')
      .replaceAll(_tezos, '[REDACTED_KEY]')
      // Before base58, which would otherwise cut a base64 key into
      // fragments too short for this rule.
      .replaceAllMapped(
        _base64,
        (m) => _isStructuralPath(m[0]!) ? m[0]! : '[REDACTED_KEY]',
      )
      .replaceAll(_base58, '[REDACTED_KEY]')
      .replaceAll(_bytes, '[REDACTED_KEY]')
      .replaceAll(_bareBytes, '[REDACTED_KEY]')
      .replaceAll(_bearer, '[REDACTED_TOKEN]')
      // Drop the entire assignment tail: a short/invalid phrase, a multiline
      // value or a partly formatted key must not survive as trailing words.
      .replaceAll(_assignment, redacted);

  /// Replaces every phrase of at least [_minPhraseWords] BIP39 English words,
  /// in any case, separated only by short non-letter gaps.
  ///
  /// The checksum is deliberately not consulted: a mistyped or truncated
  /// phrase is still a secret. So a phrase may also carry one stray
  /// non-wordlist token of [_minStrayLetters] or more letters (a typo), and
  /// the words on both sides of it count together. A second stray token, a
  /// shorter one, or a gap over [_maxPhraseGap] ends the phrase.
  ///
  /// Prose rarely gets there, because common function words (`a`, `is`, `of`,
  /// `the`, `in`, `not`) are not in the list: a sentence needs eleven
  /// wordlist words around at most one long outsider.
  static String _replaceMnemonics(String input) {
    final spans = _mnemonicSpans(input);
    if (spans.isEmpty) return input;
    final out = StringBuffer();
    var cursor = 0;
    for (final (start, end) in spans) {
      out
        ..write(input.substring(cursor, start))
        ..write('[REDACTED_MNEMONIC]');
      cursor = end;
    }
    out.write(input.substring(cursor));
    return out.toString();
  }

  /// One pass over the letter runs. A phrase is a run of wordlist words, or
  /// two runs joined by one stray token; each run is judged alone and with
  /// the run before it, so the work stays linear in the input.
  static List<(int, int)> _mnemonicSpans(String input) {
    final spans = <(int, int)>[];
    void add(int start, int end) {
      // Spans arrive with non-decreasing starts, so only the last can overlap
      // (a run counted both with its predecessor and with its successor).
      if (spans.isNotEmpty && start <= spans.last.$2) {
        final (lastStart, lastEnd) = spans.last;
        spans.last = (
          start < lastStart ? start : lastStart,
          end > lastEnd ? end : lastEnd,
        );
      } else {
        spans.add((start, end));
      }
    }

    // The run in progress, and the run before it when exactly one stray
    // token separates the two.
    var runStart = 0;
    var runEnd = 0;
    var runWords = 0;
    int? prevStart;
    var prevWords = 0;
    var lastEnd = -1;

    // Ends the current run. [joinable] is whether it ended on a stray token
    // the next run may join across.
    void close({required bool joinable}) {
      if (runWords > 0) {
        // The joined span first: it starts earlier, keeping starts ordered.
        if (prevStart != null && prevWords + runWords >= _minPhraseWords) {
          add(prevStart!, runEnd);
        }
        if (runWords >= _minPhraseWords) add(runStart, runEnd);
      }
      if (joinable && runWords > 0) {
        prevStart = runStart;
        prevWords = runWords;
      } else {
        prevStart = null;
        prevWords = 0;
      }
      runWords = 0;
    }

    for (final match in _letters.allMatches(input)) {
      if (lastEnd >= 0 && match.start - lastEnd > _maxPhraseGap) {
        close(joinable: false);
      }
      lastEnd = match.end;
      final token = match[0]!;
      if (!_bip39Words.contains(token.toLowerCase())) {
        close(joinable: token.length >= _minStrayLetters);
        continue;
      }
      if (runWords == 0) runStart = match.start;
      runEnd = match.end;
      runWords++;
    }
    close(joinable: false);
    return spans;
  }

  /// Whether a base64-alphabet run is lexically a file or package path, such
  /// as `mallow_wallet/core/security/secret_scrubber` in a stack frame or an
  /// app container path in a native image list.
  ///
  /// Only the base64 rule consults this. Hex, base58, Tezos and mnemonic
  /// patterns have already been replaced by the time it runs, whatever the
  /// surrounding text looks like. A random key almost never survives the
  /// grammar: standard base64 contains no `_` or `-`, URL-safe base64 contains
  /// no `/`, and every `/`-delimited segment of a random run would have to
  /// read as words or a UUID. Low-entropy keys (all `A`, all `/`) fail it too.
  static bool _isStructuralPath(String run) {
    if (run.contains('+') || run.contains('=') || !run.contains('/')) {
      return false;
    }
    final segments = run.replaceFirst(RegExp('^/{1,3}'), '').split('/');
    if (segments.last.isEmpty) segments.removeLast();
    if (segments.length < 2) return false;
    for (final segment in segments) {
      if (_uuid.hasMatch(segment)) continue;
      if (!segment.split(RegExp('[_-]')).every(_pathWord.hasMatch)) {
        return false;
      }
    }
    return true;
  }

  /// Field names whose value is replaced wholesale, whatever it holds.
  ///
  /// The match is deliberately broad: it tests whether the letters of the key
  /// *contain* a sensitive word. Ordinary wallet vocabulary is swallowed with
  /// it — `tokenMint`, `tokenSymbol`, `tokenAccount`, `seedPhraseId`,
  /// `privateListing`, `authority`, `authorAddress`, `apiKeyName` and
  /// `cacheKey` all arrive as `[REDACTED]`. Any name that ends in `key`
  /// (`apiKey`, `privKey`, `signingKey`) or holds `apikey`, `priv` or
  /// `keypair` is caught, as are `pin`, `sk` and `xprv` alone. Treat these
  /// words as reserved in diagnostic field names and rename the field
  /// (`mint`, `symbol`, `listingVisibility`) rather than relax this matcher:
  /// a secret sent under a benign-looking name cannot be recalled.
  static bool _sensitiveKey(String key) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    return const [
          'mnemonic',
          'seed',
          'priv',
          'xprv',
          'secret',
          'password',
          'passcode',
          'token',
          'auth',
          'credential',
          'recoveryphrase',
          'apikey',
          'keypair',
        ].any(normalized.contains) ||
        normalized.endsWith('key') ||
        normalized == 'pin' ||
        normalized == 'sk';
  }

  /// Values whose arbitrary content adds more exposure than diagnostic value.
  static const _excluded = {
    'request',
    'response',
    'user',
    'flutter_error_details',
    'vars',
    'registers',
    'pre_context',
    'post_context',
    'context_line',
    'headers',
    'cookies',
    'query_string',
    'body',
    'body_bytes',
  };

  static Map<String, dynamic> scrubMap(Map<dynamic, dynamic> input) =>
      _scrub(input, 0) as Map<String, dynamic>;

  static Object? _scrub(Object? value, int depth) {
    // Bound cyclic/deep inputs, without calling arbitrary object serializers.
    if (depth > 20) return redacted;
    if (value == null || value is bool || value is int) return value;
    if (value is double) return value.isFinite ? value : redacted;
    if (value is String) return scrubString(value);
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        if (entry.key is! String) continue;
        final key = entry.key as String;
        if (_excluded.contains(key.toLowerCase())) continue;
        final safeKey = scrubString(key);
        final idShape = _structuralIds[key];
        if (_sensitiveKey(key)) {
          result[safeKey] = redacted;
        } else if (idShape != null &&
            entry.value is String &&
            idShape.hasMatch(entry.value as String)) {
          result[safeKey] = entry.value;
        } else {
          result[safeKey] = _scrub(entry.value, depth + 1);
        }
      }
      return result;
    }
    if (value is List) {
      // One word per element escapes the per-string phrase check, so judge
      // the string elements together, in order.
      final strings = value.whereType<String>();
      if (strings.length >= _minPhraseWords &&
          _mnemonicSpans(strings.join(' ')).isNotEmpty) {
        return const ['[REDACTED_MNEMONIC]'];
      }
      if (value.length >= 16 &&
          value.every((item) => item is int && item >= 0 && item <= 255)) {
        return const ['[REDACTED_KEY]'];
      }
      return value.map((item) => _scrub(item, depth + 1)).toList();
    }
    return redacted;
  }
}
