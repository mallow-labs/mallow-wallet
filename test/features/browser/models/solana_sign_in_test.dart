import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/models/sign_in_checks.dart';
import 'package:mallow_wallet/features/browser/models/solana_offchain_message.dart';
import 'package:mallow_wallet/features/browser/models/solana_sign_in.dart';

void main() {
  const address = 'So11111111111111111111111111111111111111112';

  // Inside the validity window of every fixture below.
  final now = DateTime.utc(2026, 10, 28, 10, 1);

  SolanaSignInRequest parse(
    Map<String, dynamic> params, {
    String authority = 'example.org',
    DateTime? at,
  }) => SolanaSignInRequest.parse(
    params,
    authority: authority,
    address: address,
    now: at ?? now,
  );

  // The expected messages come from `createSignInMessageText` in
  // @solana/wallet-standard-util 1.2.0, the text sites verify against; the
  // off-chain bytes from @solana/offchain-messages 8.5.0.
  test('writes every field the way the reference does', () {
    final request = parse({
      'domain': 'example.org:8443',
      'address': address,
      'statement': 'Sign in to Example.',
      'uri': 'https://example.org:8443/login',
      'version': '1',
      'chainId': 'mainnet',
      'nonce': 'a1b2c3d4',
      'issuedAt': '2026-10-28T10:00:00.000Z',
      'expirationTime': '2026-10-28T10:10:00.000Z',
      'notBefore': '2026-10-28T09:59:00.000Z',
      'requestId': 'req-7',
      'resources': ['https://example.org/terms', 'ipfs://bafy'],
    });
    expect(
      request.text,
      'example.org:8443 wants you to sign in with your Solana account:\n'
      'So11111111111111111111111111111111111111112\n\n'
      'Sign in to Example.\n\n'
      'URI: https://example.org:8443/login\n'
      'Version: 1\n'
      'Chain ID: mainnet\n'
      'Nonce: a1b2c3d4\n'
      'Issued At: 2026-10-28T10:00:00.000Z\n'
      'Expiration Time: 2026-10-28T10:10:00.000Z\n'
      'Not Before: 2026-10-28T09:59:00.000Z\n'
      'Request ID: req-7\n'
      'Resources:\n'
      '- https://example.org/terms\n'
      '- ipfs://bafy',
    );
    expect(request.offchainMessage, isFalse);
    expect(utf8.decode(request.bytes), request.text);
  });

  test('defaults the domain to the page and leaves out empty fields', () {
    final request = parse({'statement': '', 'nonce': '', 'uri': null});
    expect(
      request.text,
      'example.org wants you to sign in with your Solana account:\n$address',
    );
  });

  test('wraps the message in an off-chain message when asked', () {
    final request = parse({
      'useOffchainMessage': {'messageVersion': 1},
    });
    expect(request.offchainMessage, isTrue);
    expect(
      base64Encode(request.bytes),
      '/3NvbGFuYSBvZmZjaGFpbgEBBpuIV/6rgYT7aH9jRhjANdrEOdwa6ztVmKDwAAAAAAFleGFt'
      'cGxlLm9yZyB3YW50cyB5b3UgdG8gc2lnbiBpbiB3aXRoIHlvdXIgU29sYW5hIGFjY291bnQ6'
      'ClNvMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTI=',
    );
    final message = SolanaOffchainMessage.parse(request.bytes);
    expect(message.content, request.text);
    expect(message.signers, [address]);
  });

  test('refuses what the sign-in card could not show in full', () {
    for (final (reason, params) in <(String, Map<String, dynamic>)>[
      ('a line break in the statement', {'statement': 'Hi\nNonce: 1'}),
      ('a carriage return', {'nonce': 'a\rb'}),
      ('a statement that reads as a field', {'statement': 'Nonce: 123'}),
      ('a blank statement', {'statement': '   '}),
      ('whitespace in the domain', {'domain': 'evil.example example.org'}),
      ('a non-string field', {'nonce': 42}),
      ('an empty resource list', {'resources': <String>[]}),
      (
        'an empty resource',
        {
          'resources': <String>[''],
        },
      ),
      (
        'a resource that is not a string',
        {
          'resources': <Object>[1],
        },
      ),
      (
        'too many resources',
        {
          'resources': [for (var i = 0; i <= kMaxSignInResources; i++) 'r$i'],
        },
      ),
      ('an overlong field', {'nonce': 'x' * (kMaxSignInFieldLength + 1)}),
      (
        'an unsupported off-chain version',
        {
          'useOffchainMessage': {'messageVersion': 0},
        },
      ),
    ]) {
      expect(() => parse(params), throwsFormatException, reason: reason);
    }
  });

  group('validity', () {
    Matcher refuses(String because) => throwsA(
      isA<FormatException>().having((e) => e.message, 'message', because),
    );

    test('a version other than 1 is refused', () {
      expect(parse({'version': '1'}).text, endsWith('Version: 1'));
      for (final version in ['2', '1.0', '01', ' 1']) {
        expect(
          () => parse({'version': version}),
          refuses('Unsupported sign-in version'),
          reason: version,
        );
      }
    });

    test('an expiration time that has passed is refused', () {
      const expired = 'This sign-in request has expired';
      expect(
        parse({'expirationTime': '2026-10-28T10:01:00.001Z'}).text,
        contains('Expiration Time'),
      );
      for (final time in [
        // Exactly now is no longer valid.
        '2026-10-28T10:01:00Z',
        '2026-10-28T10:00:59.999Z',
        '2020-01-01T00:00:00Z',
        // The same instant written in another zone.
        '2026-10-28T12:00:00+02:00',
      ]) {
        expect(
          () => parse({'expirationTime': time}),
          refuses(expired),
          reason: time,
        );
      }
    });

    test('a start more than the allowed skew ahead is refused', () {
      final edge = now.add(kSignInClockSkew).toIso8601String();
      final past = now
          .add(kSignInClockSkew + const Duration(seconds: 1))
          .toIso8601String();
      expect(parse({'notBefore': edge}).text, contains('Not Before'));
      expect(parse({'issuedAt': edge}).text, contains('Issued At'));
      expect(
        () => parse({'notBefore': past}),
        refuses('This sign-in request is not valid yet'),
      );
      expect(
        () => parse({'issuedAt': past}),
        refuses('This sign-in request is dated in the future'),
      );
      // Long ago is fine: only the future is suspect.
      expect(
        parse({'issuedAt': '2020-01-01T00:00:00Z'}).text,
        contains('Issued At'),
      );
    });

    test('a time the wallet cannot read is refused, not passed over', () {
      for (final key in ['issuedAt', 'expirationTime', 'notBefore']) {
        for (final time in [
          'soon',
          '1793181660',
          // No zone: it would mean a different instant on every device.
          '2026-10-28T10:05:00',
          '2026-10-28 10:05:00Z',
          '2026-10-28',
        ]) {
          expect(
            () => parse({key: time}),
            refuses('This sign-in request has a time the wallet cannot read'),
            reason: '$key $time',
          );
        }
      }
    });

    test('the clock defaults to the device\'s', () {
      expect(
        () => SolanaSignInRequest.parse(
          {'expirationTime': '2020-01-01T00:00:00Z'},
          authority: 'example.org',
          address: address,
        ),
        throwsFormatException,
      );
    });

    test('a domain or address for another site is still written: the review, '
        'not the parser, puts it behind a hold', () {
      final request = parse({
        'domain': 'other.example',
        'uri': 'https://other.example/login',
      });
      expect(request.text, startsWith('other.example wants you to sign in'));
      expect(request.text, contains('URI: https://other.example/login'));
    });
  });
}
