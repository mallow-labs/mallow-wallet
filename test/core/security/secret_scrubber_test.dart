import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/secret_scrubber.dart';

class _UnsafeObject {
  @override
  String toString() => throw StateError('must not stringify');
  Object toJson() => throw StateError('must not serialize');
}

// Public BIP39 test vectors and synthetic wordlist runs only.
const _vector12 =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon about';
const _vector24 =
    'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo '
    'zoo zoo zoo zoo zoo vote';
const _vector15 =
    'legal winner thank year wave sausage worth useful legal winner thank '
    'year wave sausage worth';

// Synthetic key material, never a real key.
final _hex64 = List.filled(64, 'a').join();
const _base58Key =
    '5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ5HueCGU8rMjx';
// A UUID-shaped API key. Interpolated rather than written next to a key
// label, so secret scanners do not read the test sample as a leaked key.
const _uuidSample = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';
const _solanaAddress = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
const _evmChecksummed = '0x742d35Cc6634C0532925a3b844Bc454e4438f44e';

void _expectRedacted(String sample) {
  final output = SecretScrubber.scrubString(sample);
  expect(output.contains(sample), isFalse, reason: sample);
  expect(output, contains('REDACTED'), reason: sample);
}

void main() {
  test('removes supported secret encodings and encoded representations', () {
    final words = _vector12.split(' ');
    final samples = [
      words.join(' '),
      jsonEncode(words),
      words.join('\n'),
      List.filled(128, '0').join(),
      '0X${List.filled(64, 'a').join()}',
      'edsk${List.filled(50, 'a').join()}',
      'edsk${List.filled(94, 'a').join()}',
      jsonEncode(List.generate(64, (i) => i)),
      base64Encode(List.generate(32, (i) => i)),
      base64UrlEncode(List.generate(64, (i) => i)),
      Uri.encodeComponent(words.join(' ')),
      Uri.encodeComponent(Uri.encodeComponent(words.join(' '))),
    ];
    for (final sample in samples) {
      _expectRedacted(sample);
    }
  });

  test(
    'drops whole labeled values including partial and multiline phrases',
    () {
      for (final label in [
        'mnemonic',
        'private_key',
        'seed phrase',
        'password',
        'PIN',
      ]) {
        final output = SecretScrubber.scrubString(
          '$label: first second\nthird fourth',
        );
        expect(output.contains('first'), isFalse);
        expect(output.contains('fourth'), isFalse);
      }
    },
  );

  test('handles typed bytes, untyped maps, unknown objects, and cycles', () {
    final cyclic = <String, dynamic>{};
    cyclic['self'] = cyclic;
    final clean = SecretScrubber.scrubMap({
      'bytes': Uint8List(32),
      'nested': <Object?, Object?>{'private-key': 'partial phrase'},
      'object': _UnsafeObject(),
      'cycle': cyclic,
      'ok': 42,
    });
    expect(() => jsonEncode(clean), returnsNormally);
    expect(jsonEncode(clean).contains('partial phrase'), isFalse);
    expect(clean['bytes'], ['[REDACTED_KEY]']);
    expect(clean['object'], SecretScrubber.redacted);
    expect(clean['ok'], 42);
  });

  test('preserves useful ordinary diagnostics', () {
    expect(
      SecretScrubber.scrubString('SocketException: connection refused (503)'),
      'SocketException: connection refused (503)',
    );
  });

  group('percent decoding', () {
    test('never throws and keeps ordinary text containing %', () {
      for (final message in [
        'progress 50% done',
        '%',
        'trailing %',
        'bad escape %zz',
        'half escape %4',
        'probe https://example.test/%2F → fallback',
        'café 100% → retry %E9',
        'lone surrogate-ish %ED%A0%80 bytes',
      ]) {
        expect(
          () => SecretScrubber.scrubString(message),
          returnsNormally,
          reason: message,
        );
        expect(SecretScrubber.scrubString(message), message, reason: message);
      }
    });

    test('keeps an encoded image URL readable', () {
      final url =
          'probe https://img.example.test/thumb?url='
          '${Uri.encodeComponent('https://gateway.example.test/ipfs/x.png')}'
          ' → fallback';
      expect(SecretScrubber.scrubString(url), url);
    });

    test('redacts single, double and plus encoded secrets', () {
      final words = _vector12.split(' ');
      for (final sample in [
        Uri.encodeQueryComponent(_vector12),
        words.join('+'),
        Uri.encodeComponent(words.join(', ')),
        Uri.encodeComponent(Uri.encodeComponent(jsonEncode(words))),
        'retry %2F → ${Uri.encodeComponent(_vector24)}',
        Uri.encodeComponent(_hex64),
        Uri.encodeComponent(Uri.encodeComponent(_base58Key)),
        'mnemonic%3D${words.first}',
        'token+%3D+abc',
        Uri.encodeQueryComponent('password = hunter2'),
        // A key split by escapes shows only once decoded.
        '5Hue%43GU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ',
      ]) {
        _expectRedacted(sample);
        expect(
          SecretScrubber.scrubString(sample).contains('abandon'),
          isFalse,
          reason: sample,
        );
      }
    });
  });

  group('mnemonic detection', () {
    test('preserves 12-word type errors and ordinary prose', () {
      for (final message in [
        "type 'Null' is not a subtype of type 'String' in type cast",
        "type 'List<dynamic>' is not a subtype of type 'Map<String, dynamic>'",
        "type '_Map<String, dynamic>' is not a subtype of type 'String' of "
            "'value' in type cast",
        'Failed to load the account balance for this wallet because the '
            'network request timed out after thirty seconds',
        'Bad state: No element when reading the list of tokens from the '
            'cached portfolio response',
      ]) {
        expect(SecretScrubber.scrubString(message), message, reason: message);
      }
    });

    test('redacts phrases in any case, quoting, separator and length', () {
      final words = _vector12.split(' ');
      for (final phrase in [
        _vector12,
        _vector12.toUpperCase(),
        _vector15,
        _vector24,
        List.filled(18, 'zoo').join(' '),
        List.filled(21, 'legal').join(' '),
        words.join(', '),
        words.join('_'),
        words.map((w) => "'$w'").join(','),
        const JsonEncoder.withIndent('        ').convert(words),
        [for (var i = 0; i < 12; i++) '${i + 1}. ${words[i]}'].join('\n'),
      ]) {
        final output = SecretScrubber.scrubString(phrase);
        expect(output.toLowerCase().contains('abandon'), isFalse);
        expect(output.toLowerCase().contains('zoo zoo'), isFalse);
        expect(output.toLowerCase().contains('winner'), isFalse);
        expect(output, contains('[REDACTED_MNEMONIC]'), reason: phrase);
      }
    });

    test('does not depend on a valid checksum', () {
      // Twelve wordlist words whose checksum is invalid.
      const invalid =
          'abandon abandon abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon abandon';
      expect(SecretScrubber.scrubString(invalid), '[REDACTED_MNEMONIC]');
    });

    test('redacts a phrase embedded in diagnostic prose', () {
      final output = SecretScrubber.scrubString(
        "FormatException: can't import $_vector12 (at character 12)",
      );
      expect(
        output,
        "FormatException: can't import [REDACTED_MNEMONIC] (at character 12)",
      );
    });

    test('redacts a list of words given one per element', () {
      final clean = SecretScrubber.scrubMap({
        'words': _vector24.split(' '),
        'upper': _vector12.toUpperCase().split(' '),
      });
      expect(clean['words'], ['[REDACTED_MNEMONIC]']);
      expect(clean['upper'], ['[REDACTED_MNEMONIC]']);
    });

    test('keeps a list of ordinary short strings', () {
      final names = [
        'home',
        'search',
        'profile',
        'settings',
        'activity',
        'wallet',
        'swap',
        'offers',
        'cast',
        'rewards',
        'scan',
        'stake',
      ];
      expect(SecretScrubber.scrubMap({'tabs': names})['tabs'], names);
    });
  });

  group('near-complete phrases', () {
    final words = _vector12.split(' ');

    void expectNoPhraseWords(String sample) {
      final output = SecretScrubber.scrubString(sample);
      expect(output, contains('[REDACTED_MNEMONIC]'), reason: sample);
      for (final word in ['abandon', 'about', 'zoo', 'vote']) {
        expect(output.contains(word), isFalse, reason: '$word in $output');
      }
    }

    test('redacts a phrase with one mistyped word', () {
      final typo = [...words]..[6] = 'abandxn';
      expectNoPhraseWords(typo.join(' '));
      expectNoPhraseWords(typo.join(', '));
      expectNoPhraseWords(jsonEncode(typo));
      // The stray word at either end of the phrase.
      expectNoPhraseWords((List.of(words)..[0] = 'abandxn').join(' '));
      expectNoPhraseWords((List.of(words)..[11] = 'abuot').join(' '));
    });

    test('redacts a phrase truncated by one word', () {
      expectNoPhraseWords(words.take(11).join(' '));
    });

    test('redacts both halves of a split 24-word phrase', () {
      final long = _vector24.split(' ');
      expectNoPhraseWords(
        'part1: ${long.take(11).join(' ')} | part2: ${long.skip(11).join(' ')}',
      );
      expectNoPhraseWords(
        '${long.take(11).join(' ')} xqzv ${long.skip(11).join(' ')}',
      );
    });

    test('a second stray token or a short one still ends the phrase', () {
      // Bounds what the tolerance may join, so prose keeps its words.
      for (final sample in [
        '${words.take(6).join(' ')} xqzv xqzw ${words.skip(6).join(' ')}',
        '${words.take(6).join(' ')} an ${words.skip(6).take(4).join(' ')}',
        '${words.take(5).join(' ')} xqzv ${words.skip(6).take(5).join(' ')}',
      ]) {
        expect(SecretScrubber.scrubString(sample), sample, reason: sample);
      }
    });

    test('keeps ordinary English sentences', () {
      for (final message in [
        'You can always receive into an address you can see on the '
            'receive screen of this wallet',
        'Unable to connect to the server because the network is not '
            'available right now, please try again later',
        'The swap quote expired before the transaction was signed, so a new '
            'quote was requested from the aggregator',
        'Wallet balance refresh failed after three attempts; showing the '
            'last cached value until the next pull to refresh',
      ]) {
        expect(SecretScrubber.scrubString(message), message, reason: message);
      }
    });

    test('redacts a near-complete phrase given one word per element', () {
      final typo = [...words]..[3] = 'abandxn';
      expect(SecretScrubber.scrubMap({'words': typo})['words'], [
        '[REDACTED_MNEMONIC]',
      ]);
      expect(
        SecretScrubber.scrubMap({'words': words.take(11).toList()})['words'],
        ['[REDACTED_MNEMONIC]'],
      );
    });
  });

  group('byte lists and separated hex', () {
    final values = List.generate(32, (i) => i * 7);

    test('redacts unbracketed byte lists', () {
      for (final sample in [
        values.join(', '),
        values.join(','),
        'seed bytes ${values.join(', ')} end',
        values
            .map((v) => '0x${v.toRadixString(16).padLeft(2, '0')}')
            .join(', '),
        List.filled(16, 255).join(', '),
      ]) {
        _expectRedacted(sample);
        expect(
          SecretScrubber.scrubString(sample).contains('217'),
          isFalse,
          reason: sample,
        );
      }
    });

    test('keeps short lists, fractions and out-of-range numbers', () {
      for (final sample in [
        values.take(15).join(', '),
        List.generate(20, (i) => '$i.5').join(', '),
        List.generate(20, (i) => 1000 + i).join(', '),
        'retry in 1, 2, 4 and 8 seconds',
      ]) {
        expect(SecretScrubber.scrubString(sample), sample, reason: sample);
      }
    });

    test('redacts hex bytes separated by spaces or colons', () {
      final hex = [
        for (var i = 0; i < 32; i++)
          ((i * 37 + 11) % 256).toRadixString(16).padLeft(2, '0'),
      ];
      for (final sample in [
        hex.join(' '),
        hex.join(':'),
        hex.join(':').toUpperCase(),
        'key=${hex.take(16).join(' ')}',
        'dump: ${hex.join(' ')} (32 bytes)',
      ]) {
        _expectRedacted(sample);
        expect(
          SecretScrubber.scrubString(sample).contains(hex[5]),
          isFalse,
          reason: sample,
        );
      }
    });

    test('stays fast on near-miss input at the size cap', () {
      // Each sample almost matches at every position. Backtracking patterns
      // would go quadratic here; the scan must not.
      final samples = [
        List.filled(
          1000,
          '1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15',
        ).join('; ').substring(0, 16000),
        List.filled(
          1400,
          'ab cd ef 01 02 03 04 05 06 07 08 09 0a 0b 0c',
        ).join(' x ').substring(0, 16000),
        List.filled(
          1400,
          'abandon abandon abandon abandon abandon xqzv xqzw',
        ).join(' ').substring(0, 16000),
      ];
      final watch = Stopwatch()..start();
      for (final sample in samples) {
        SecretScrubber.scrubString(sample);
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('keeps short separated hex such as a MAC address', () {
      for (final sample in [
        'device 3c:22:fb:8a:01:9e paired',
        'read ab cd ef 01 02 03 bytes',
        '12:30:45 build finished',
      ]) {
        expect(SecretScrubber.scrubString(sample), sample, reason: sample);
      }
    });
  });

  group('addresses', () {
    test('redacts EVM addresses in any case with 0x or 0X', () {
      for (final address in [
        _evmChecksummed,
        _evmChecksummed.toLowerCase(),
        '0X${_evmChecksummed.substring(2).toUpperCase()}',
      ]) {
        final output = SecretScrubber.scrubString('owner=$address, retry');
        expect(output, 'owner=[REDACTED_ADDRESS], retry');
      }
      expect(
        SecretScrubber.scrubString('wallet_$_evmChecksummed'),
        'wallet_[REDACTED_ADDRESS]',
      );
    });

    test('leaves short hex values alone', () {
      const message = 'frame at 0x0000000104a5b2c4, status 0x1f';
      expect(SecretScrubber.scrubString(message), message);
    });

    test('still redacts whole base58 keys and addresses', () {
      expect(
        SecretScrubber.scrubString('owner $_solanaAddress failed'),
        'owner [REDACTED_KEY] failed',
      );
      // Glued to characters outside the alphabet, which `\b` would miss. The
      // run is too short for the base64 rule, so base58 must catch it.
      final short = _base58Key.substring(0, 36);
      expect(SecretScrubber.scrubString('x_${short}l'), 'x_[REDACTED_KEY]l');
      // A longer glued run is taken whole by the base64 rule.
      expect(
        SecretScrubber.scrubString('seed_${_base58Key}l'),
        '[REDACTED_KEY]',
      );
    });
  });

  group('structural paths', () {
    test('keeps realistic Dart stack frames', () {
      for (final line in [
        'package:mallow_wallet/core/security/secret_scrubber.dart',
        '#0      SecretScrubber._scrub '
            '(package:mallow_wallet/core/security/secret_scrubber.dart:231:7)',
        '#4      _PortfolioScreenState._load (package:mallow_wallet/features/'
            'portfolio/screens/portfolio_screen.dart:88:12)',
        'package:mallow_wallet/core/observability/sentry_privacy_transport.dart',
        'file:///Users/dev/projects/mallow_wallet/lib/core/network/'
            'api_client.dart',
      ]) {
        expect(SecretScrubber.scrubString(line), line, reason: line);
      }
    });

    test('keeps native image paths and identifiers', () {
      const ios =
          '/private/var/containers/Bundle/Application/'
          '1A2B3C4D-5E6F-4A8B-9C0D-1E2F3A4B5C6D/Runner.app/Frameworks/'
          'App.framework/App';
      const simulator =
          '/Users/dev/Library/Developer/CoreSimulator/Devices/'
          '1A2B3C4D-5E6F-4A8B-9C0D-1E2F3A4B5C6D/data/Containers/Bundle/'
          'Application/6D5C4B3A-2F1E-4D0C-9B8A-7F6E5D4C3B2A/Runner.app/Runner';
      const android =
          '/data/app/~~Zm9vYmFy==/com.example.app-1/lib/arm64/'
          'libapp.so';
      final image = {
        'type': 'elf',
        'code_file': ios,
        'debug_file': simulator,
        'code_id': 'b680cb89f9e3c12a24b172d51dec73a9c4e5f6a7',
        'debug_id': 'b680cb89-f9e3-c12a-24b1-72d51dec73a9',
        'image_addr': '0x0000000104a5b000',
      };
      final clean = SecretScrubber.scrubMap({
        'debug_meta': {
          'images': [image],
        },
        'android': android,
      });
      expect((clean['debug_meta'] as Map)['images'], [image]);
      expect(clean['android'], android);
    });

    test('keeps unconditional patterns inside path-shaped values', () {
      for (final (value, leaked) in [
        ('package:$_hex64.dart', _hex64),
        ('package:mallow_wallet/$_hex64/x.dart', _hex64),
        ('package:mallow_$_hex64.dart', _hex64),
        ('package:$_base58Key/x.dart', _base58Key),
        ('file:///tmp/${_vector12.replaceAll(' ', '/')}.txt', 'abandon'),
        ('package:${_vector12.replaceAll(' ', '_')}.dart', 'abandon'),
        ('package:edsk${List.filled(50, 'a').join()}.dart', 'aaaaaaaaaa'),
        ('lib/$_evmChecksummed/x.dart', _evmChecksummed),
      ]) {
        final output = SecretScrubber.scrubString(value);
        expect(output.contains(leaked), isFalse, reason: value);
      }
    });

    test('secrets under frame and image keys are still redacted', () {
      final frame = {
        'function': _vector12,
        'abs_path': 'package:$_hex64.dart',
        'filename': _base58Key,
        'module': 'edsk${List.filled(50, 'a').join()}',
        'package': base64Encode(List.generate(32, (i) => i * 7)),
        'code_file': 'lib/${base64Encode(List.generate(48, (i) => i * 5))}',
        'code_id': _hex64,
        'debug_id': 'not-a-uuid $_base58Key',
        'instruction_addr': _evmChecksummed,
      };
      final encoded = jsonEncode(SecretScrubber.scrubMap({'frame': frame}));
      for (final value in frame.values) {
        expect(encoded.contains(value), isFalse, reason: value);
      }
      expect(encoded.contains('abandon'), isFalse);
      expect(encoded.contains(_base58Key), isFalse);
    });

    test('low-entropy and path-like base64 keys are still redacted', () {
      for (final bytes in [
        List.filled(32, 0),
        List.filled(32, 255),
        List.filled(33, 0xfb),
        List.generate(32, (i) => i),
      ]) {
        _expectRedacted(base64Encode(bytes));
        _expectRedacted(base64UrlEncode(bytes));
        _expectRedacted('package:mallow_wallet/${base64Encode(bytes)}');
      }
      _expectRedacted(List.filled(44, 'a').join());
    });

    test('random base64 keys never pass as paths', () {
      final random = Random(20260925);
      for (var i = 0; i < 20000; i++) {
        final bytes = List.generate(32 + i % 33, (_) => random.nextInt(256));
        for (final encoded in [base64Encode(bytes), base64UrlEncode(bytes)]) {
          final output = SecretScrubber.scrubString('key $encoded end');
          expect(output.contains(encoded), isFalse, reason: encoded);
        }
      }
    });
  });

  group('structured fields', () {
    test('keeps the reserved field names masked', () {
      final clean = SecretScrubber.scrubMap({
        'tokenMint': 'public',
        'seedPhraseId': 'public',
        'authority': 'public',
        'privateListing': 'public',
        'pin': '1234',
        'key': 'value',
        'mint': 'kept',
      });
      for (final key in [
        'tokenMint',
        'seedPhraseId',
        'authority',
        'privateListing',
        'pin',
        'key',
      ]) {
        expect(clean[key], SecretScrubber.redacted, reason: key);
      }
      expect(clean['mint'], 'kept');
    });

    test('masks key-like field names the doc lists', () {
      final names = [
        'apiKey',
        'api_key',
        'apiKeyName',
        'privKey',
        'priv_key',
        'signingKey',
        'cacheKey',
        'keypair',
        'keyPairBytes',
        'xprv',
        'sk',
        'SK',
      ];
      final clean = SecretScrubber.scrubMap({
        for (final name in names) name: _uuidSample,
        'kind': 'kept',
        'skipped': 3,
        'keyboardType': 'kept',
      });
      for (final name in names) {
        expect(clean[name], SecretScrubber.redacted, reason: name);
      }
      expect(clean['kind'], 'kept');
      expect(clean['skipped'], 3);
      expect(clean['keyboardType'], 'kept');
    });

    test('drops key-like labeled values in text', () {
      for (final sample in [
        'apiKey: $_uuidSample',
        'x-api-key=$_uuidSample',
        'priv_key = short',
        'access_key: short',
        'keypair: short',
      ]) {
        final output = SecretScrubber.scrubString(sample);
        expect(output.contains('3f2504e0'), isFalse, reason: sample);
        expect(output.contains('short'), isFalse, reason: sample);
      }
    });

    test('passes SDK identifiers only in their exact shape', () {
      final clean = SecretScrubber.scrubMap({
        'event_id': '0123456789abcdef0123456789abcdef',
        'trace_id': _hex64,
        'debug_id': _base58Key,
      });
      expect(clean['event_id'], '0123456789abcdef0123456789abcdef');
      expect(clean['trace_id'], '[REDACTED_KEY]');
      expect(clean['debug_id'], '[REDACTED_KEY]');
    });
  });
}
