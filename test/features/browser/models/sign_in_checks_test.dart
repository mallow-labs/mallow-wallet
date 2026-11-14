import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/models/dapp_message_review.dart';
import 'package:mallow_wallet/features/browser/models/sign_in_checks.dart';

const _me = '7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU';
const _eth = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';

class _Review extends DappMessageReview {
  _Review(String text, {required this.origin, this.chain = 'Solana'})
    : bytes = Uint8List.fromList(utf8.encode(text));
  @override
  final Uint8List bytes;
  @override
  final String origin;
  final String chain;
  @override
  String get address => chain == 'Solana' ? _me : _eth;
  @override
  String get digestLabel => 'digest';
  @override
  String get digest => '';
  SignInMessage? get _signIn => parseSignInMessage(
    text,
    address: address,
    chain: chain,
    resourceList: true,
  );
  @override
  Map<String, String> get signInFields => _signIn?.fields ?? const {};
  @override
  String? get signInStatement => _signIn?.statement;
}

SignInAssessment _assess(
  String domain,
  List<String> lines, {
  String origin = 'https://app.example',
  String chain = 'Solana',
}) {
  final review = _Review(
    '$domain wants you to sign in with your $chain account:\n'
    '${chain == 'Solana' ? _me : _eth}'
    '${lines.isEmpty ? '' : '\n\n${lines.join('\n')}'}',
    origin: origin,
    chain: chain,
  );
  expect(review.signInFields, isNotEmpty, reason: 'the fixture is a sign-in');
  return assessSignIn(review, now: DateTime.utc(2026, 10, 28, 10));
}

void main() {
  test('a sign-in for the page that asked needs no hold', () {
    final check = _assess('app.example', [
      'URI: https://app.example/login?next=%2F',
      'Version: 1',
      'Chain ID: mainnet',
      'Issued At: 2026-10-28T09:59:00Z',
      'Expiration Time: 2026-10-28T10:10:00Z',
    ]);
    expect(check.forThisSite, isTrue);
    expect(check.timeProblem, isNull);
    expect(check.networkWarning, isNull);
    expect(check.needsHold, isFalse);
  });

  test('a domain that is not the page\'s authority needs a hold', () {
    for (final domain in [
      'evil.example',
      // A parent, a child and a look-alike are all other sites.
      'example',
      'login.app.example',
      'app.example.evil.example',
      // The port is part of the authority.
      'app.example:8443',
      'APP.EXAMPLE',
    ]) {
      final check = _assess(domain, const []);
      expect(check.domainMatches, isFalse, reason: domain);
      expect(check.needsHold, isTrue, reason: domain);
    }
    expect(
      _assess(
        'app.example:8443',
        const [],
        origin: 'https://app.example:8443',
      ).needsHold,
      isFalse,
    );
  });

  test('a URI on another origin needs a hold, whatever the domain says', () {
    for (final uri in [
      'https://evil.example/login',
      'https://app.example.evil.example',
      'https://app.example@evil.example/',
      'https://evil.example@app.example/',
      'https://app.example:8443/',
      'http://app.example/',
      'app.example/login',
      '/login',
      'did:pkh:solana:$_me',
    ]) {
      final check = _assess('app.example', ['URI: $uri']);
      expect(check.domainMatches, isTrue, reason: uri);
      expect(check.uriMatches, isFalse, reason: uri);
      expect(check.forThisSite, isFalse, reason: uri);
      expect(check.needsHold, isTrue, reason: uri);
    }
    for (final uri in [
      'https://app.example',
      'https://app.example/',
      'https://app.example:443/a?b#c',
      'HTTPS://APP.EXAMPLE/x',
    ]) {
      expect(
        _assess('app.example', ['URI: $uri']).uriMatches,
        isTrue,
        reason: uri,
      );
    }
  });

  test('a sign-in outside its validity window needs a hold', () {
    for (final (line, problem) in [
      ('Expiration Time: 2026-10-28T09:59:59Z', 'expired'),
      ('Not Before: 2026-10-28T10:05:01Z', 'not valid yet'),
      ('Issued At: 2026-10-28T10:05:01Z', 'dated in the future'),
      ('Issued At: yesterday', 'cannot read'),
    ]) {
      final check = _assess('app.example', [line]);
      expect(check.timeProblem, contains(problem), reason: line);
      expect(check.forThisSite, isTrue);
      expect(check.needsHold, isTrue, reason: line);
    }
    final edge = _assess('app.example', [
      'Issued At: 2026-10-28T10:05:00Z',
      'Not Before: 2026-10-28T10:05:00Z',
    ]);
    expect(edge.timeProblem, isNull, reason: 'the skew is allowed');
    expect(kSignInClockSkew, const Duration(minutes: 5));
  });

  test('a Solana sign-in naming another network is cautioned, by name', () {
    for (final chainId in [
      'mainnet',
      'mainnet-beta',
      'solana:mainnet',
      'solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp',
    ]) {
      expect(
        _assess('app.example', ['Chain ID: $chainId']).networkWarning,
        isNull,
        reason: chainId,
      );
    }
    for (final chainId in [
      'devnet',
      'testnet',
      'solana:devnet',
      '1',
      'Mainnet',
    ]) {
      final check = _assess('app.example', ['Chain ID: $chainId']);
      expect(check.networkWarning, contains('"$chainId"'), reason: chainId);
      // A caution, not a hold: the site that asked is still the one named.
      expect(check.needsHold, isFalse, reason: chainId);
    }
  });

  test('an Ethereum sign-in keeps its own network rule', () {
    final check = _assess('app.example', [
      'URI: https://app.example',
      'Version: 1',
      'Chain ID: mainnet',
    ], chain: 'Ethereum');
    expect(check.networkWarning, isNull);
    expect(check.forThisSite, isTrue);
  });

  test('parseSignInTime reads only a full date-time with its zone', () {
    expect(
      parseSignInTime('2026-10-28T12:00:00.5+02:00'),
      DateTime.utc(2026, 10, 28, 10, 0, 0, 500),
    );
    expect(
      parseSignInTime('2026-10-28T10:00:00Z'),
      DateTime.utc(2026, 10, 28, 10),
    );
    for (final value in [
      '2026-10-28T10:00:00',
      '2026-10-28T10:00Z',
      '20261028T100000Z',
      ' 2026-10-28T10:00:00Z',
      '2026-10-28T10:00:00Z ',
      '',
    ]) {
      expect(parseSignInTime(value), isNull, reason: value);
    }
  });
}
