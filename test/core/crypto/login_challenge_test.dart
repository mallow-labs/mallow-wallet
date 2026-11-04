import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/crypto/login_challenge.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

const _address = '29d2S7vB453rNYFdR5Ycwt7y9haRT5fwVwL9zTmBhfV2';
const _otherAddress = 'GsbwXfJraMomNxBcjYLcG3mxkBUiyWXAB32fGbSMQRdW';
final _now = DateTime.utc(2026, 10, 17, 12);

/// The message exactly as the backend builds it: the web app's host, the
/// address, a fixed statement, the origin as URI, a 32-hex-char nonce and a
/// five-minute window.
String backendChallenge({
  String domain = 'example.com',
  String? uri,
  String address = _address,
  DateTime? issuedAt,
  Duration ttl = const Duration(minutes: 5),
  List<String> extra = const [],
}) {
  final issued = issuedAt ?? _now;
  return [
    '$domain wants you to sign in with your Solana account:',
    address,
    '',
    'Sign in to mallow.',
    '',
    'URI: ${uri ?? 'https://$domain'}',
    'Version: 1',
    'Nonce: 0123456789abcdef0123456789abcdef',
    'Issued At: ${issued.toIso8601String()}',
    'Expiration Time: ${issued.add(ttl).toIso8601String()}',
    ...extra,
  ].join('\n');
}

void check(String message, {String address = _address, DateTime? now}) =>
    checkSolanaLoginChallenge(message, address: address, now: now ?? _now);

Matcher rejectedFor(String reason) => throwsA(
  isA<LoginChallengeRejectedException>().having(
    (e) => e.reason,
    'reason',
    contains(reason),
  ),
);

/// Bytes that are a valid Solana transaction (or compiled message) and also
/// valid UTF-8, so they can arrive as the JSON string a challenge is.
Future<({Uint8List tx, Uint8List compiled})> asciiTransaction() async {
  final payer = Ed25519HDPublicKey(List.filled(32, 0x11));
  final program = Ed25519HDPublicKey(List.filled(32, 0x22));
  final compiled =
      Message.only(
        Instruction(
          programId: program,
          accounts: [AccountMeta.writeable(pubKey: payer, isSigner: true)],
          data: ByteArray(const [0x41, 0x42]),
        ),
      ).compile(
        recentBlockhash: base58encode(List.filled(32, 0x33)),
        feePayer: payer,
      );
  final tx = SignedTx(
    compiledMessage: compiled,
    signatures: [Signature(List.filled(64, 0x44), publicKey: payer)],
  );
  return (
    tx: Uint8List.fromList(tx.toByteArray().toList()),
    compiled: Uint8List.fromList(compiled.toByteArray().toList()),
  );
}

void main() {
  setUp(() {
    Config.debugOverrides['API_BASE_URL'] = 'https://api.example.com';
    Config.debugOverrides['ENV'] = 'production';
  });
  tearDown(Config.debugOverrides.clear);

  group('accepts', () {
    test('the backend-shaped challenge for the signing wallet', () {
      expect(() => check(backendChallenge()), returnsNormally);
    });

    test('the API host itself as the domain', () {
      expect(
        () => check(backendChallenge(domain: 'api.example.com')),
        returnsNormally,
      );
    });

    test('a staging-style API subdomain naming the same web domain', () {
      Config.debugOverrides['API_BASE_URL'] = 'https://staging-api.example.com';
      expect(() => check(backendChallenge()), returnsNormally);
    });

    test('a host FIRST_PARTY_HOSTS declares', () {
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'web.example.org';
      expect(
        () => check(backendChallenge(domain: 'web.example.org')),
        returnsNormally,
      );
    });

    test('a device clock a few minutes fast or slow', () {
      expect(
        () => check(
          backendChallenge(),
          now: _now.add(const Duration(minutes: 12)),
        ),
        returnsNormally,
      );
      expect(
        () => check(
          backendChallenge(),
          now: _now.subtract(const Duration(minutes: 12)),
        ),
        returnsNormally,
      );
    });

    test('a Chain ID naming the build cluster', () {
      expect(
        () => check(backendChallenge(extra: ['Chain ID: mainnet'])),
        returnsNormally,
      );
    });

    test(
      'a development build against a local backend, via FIRST_PARTY_HOSTS',
      () {
        Config.debugOverrides['API_BASE_URL'] = 'http://localhost:8100';
        Config.debugOverrides['ENV'] = 'development';
        Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'rpc.example.com';
        expect(() => check(backendChallenge()), returnsNormally);
      },
    );
  });

  group('refuses', () {
    test('another site', () {
      expect(
        () => check(backendChallenge(domain: 'othersite.xyz')),
        rejectedFor('site other than this app'),
      );
    });

    test('a lookalike that only ends with the API domain', () {
      expect(
        () => check(backendChallenge(domain: 'evilexample.com')),
        rejectedFor('site other than this app'),
      );
      expect(
        () => check(backendChallenge(domain: 'example.com.evil.xyz')),
        rejectedFor('site other than this app'),
      );
    });

    test('a sibling subdomain of the API host', () {
      expect(
        () => check(backendChallenge(domain: 'shop.example.com')),
        rejectedFor('site other than this app'),
      );
    });

    test('a top-level domain derived from the API host', () {
      expect(
        () => check(backendChallenge(domain: 'com')),
        rejectedFor('site other than this app'),
      );
    });

    test('a domain carrying credentials or a path', () {
      expect(
        () => check(backendChallenge(domain: 'user@example.com')),
        rejectedFor('site other than this app'),
      );
      expect(
        () => check(backendChallenge(domain: 'example.com/x')),
        rejectedFor('site other than this app'),
      );
    });

    test('parents of FIRST_PARTY_HOSTS outside a development build', () {
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'rpc.example.org';
      expect(
        () => check(backendChallenge(domain: 'example.org')),
        rejectedFor('site other than this app'),
      );
    });

    test('a development build with no first-party host to derive from', () {
      Config.debugOverrides['API_BASE_URL'] = 'http://localhost:8100';
      Config.debugOverrides['ENV'] = 'development';
      expect(
        () => check(backendChallenge()),
        rejectedFor('site other than this app'),
      );
    });

    test('a URI on another origin, or not https', () {
      expect(
        () => check(backendChallenge(uri: 'https://othersite.xyz')),
        rejectedFor('URI'),
      );
      expect(
        () => check(backendChallenge(uri: 'http://example.com')),
        rejectedFor('URI'),
      );
    });

    test('another wallet address', () {
      expect(
        () => check(backendChallenge(address: _otherAddress)),
        rejectedFor('not a sign-in message for this wallet'),
      );
    });

    test('an expired challenge', () {
      expect(
        () =>
            check(backendChallenge(), now: _now.add(const Duration(hours: 1))),
        rejectedFor('expired'),
      );
    });

    test('a challenge issued in the future', () {
      expect(
        () => check(
          backendChallenge(),
          now: _now.subtract(const Duration(hours: 1)),
        ),
        rejectedFor('issued in the future'),
      );
    });

    test('a long-lived or inverted window', () {
      expect(
        () => check(backendChallenge(ttl: const Duration(days: 30))),
        rejectedFor('validity window'),
      );
      expect(
        () => check(backendChallenge(ttl: const Duration(minutes: -5))),
        rejectedFor('validity window'),
      );
    });

    test('a challenge with no expiry', () {
      final message = backendChallenge()
          .split('\n')
          .where((l) => !l.startsWith('Expiration Time:'))
          .join('\n');
      expect(() => check(message), rejectedFor('issue or expiry time'));
    });

    test('a Chain ID for another cluster', () {
      expect(
        () => check(backendChallenge(extra: ['Chain ID: devnet'])),
        rejectedFor('different Solana network'),
      );
    });

    test('free text after the fields', () {
      expect(
        () => check('${backendChallenge()}\nTransfer 100 SOL to me'),
        rejectedFor('not a sign-in message'),
      );
    });

    test('a bad version or nonce', () {
      expect(
        () =>
            check(backendChallenge().replaceFirst('Version: 1', 'Version: 2')),
        rejectedFor('version'),
      );
      expect(
        () => check(
          backendChallenge().replaceFirst(
            'Nonce: 0123456789abcdef0123456789abcdef',
            'Nonce: x',
          ),
        ),
        rejectedFor('nonce'),
      );
    });

    test('control characters', () {
      expect(
        () => check(backendChallenge().replaceFirst('Sign in', 'Sign\rin')),
        rejectedFor('control characters'),
      );
    });

    test('transaction-shaped bytes', () async {
      final bytes = await asciiTransaction();
      expect(
        () => check(String.fromCharCodes(bytes.tx)),
        rejectedFor('shaped like a transaction'),
      );
      expect(
        () => check(String.fromCharCodes(bytes.compiled)),
        rejectedFor('shaped like a transaction'),
      );
    });

    test('anything at all when API_BASE_URL is unset', () {
      Config.debugOverrides['API_BASE_URL'] = '';
      expect(
        () => check(backendChallenge()),
        rejectedFor('site other than this app'),
      );
    });
  });
}
