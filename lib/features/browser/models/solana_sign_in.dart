import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:solana/base58.dart';

import 'dapp_message_review.dart';
import 'sign_in_checks.dart';
import 'solana_offchain_message.dart';

/// The optional `solana:signIn` input fields, in message order, with the
/// label each takes in the message.
const _labels = {
  'uri': 'URI',
  'version': 'Version',
  'chainId': 'Chain ID',
  'nonce': 'Nonce',
  'issuedAt': 'Issued At',
  'expirationTime': 'Expiration Time',
  'notBefore': 'Not Before',
  'requestId': 'Request ID',
};

const kMaxSignInFieldLength = 1024;
const kMaxSignInResources = 32;

/// A `solana:signIn` request (Sign In With Solana). The site sends optional
/// fields and the wallet writes the message itself, in the layout of the
/// reference `createSignInMessageText`:
///
/// ```text
/// <domain> wants you to sign in with your Solana account:
/// <address>
///
/// <statement>
///
/// URI: <uri>
/// …
/// Resources:
/// - <resource>
/// ```
///
/// A field left out, or sent empty, is not written. The domain defaults to
/// the requesting page's authority.
///
/// A request is accepted only when the review's strict parser
/// ([parseSignInMessage]) reads the written message back to exactly these
/// fields, so the sign-in card can never show less than what is signed.
/// That refuses line breaks inside a field, a statement that reads as a
/// field, and the like.
///
/// A request is also refused when it could not be a valid sign-in now: a
/// `version` other than 1, an `expirationTime` already past, or a
/// `notBefore` or `issuedAt` further ahead than [kSignInClockSkew] (see
/// [signInTimeProblem]). The wallet does not ask the user to sign what the
/// site itself should reject. None of these checks depends on the account,
/// so a site learns nothing about the wallet from which requests fail.
///
/// With `useOffchainMessage: {messageVersion: 1}` (version 1.1.0 of the
/// feature) the message is wrapped in a version 1 off-chain message whose
/// only signer is the account, which is how a Ledger signs in.
class SolanaSignInRequest {
  SolanaSignInRequest._(this.text, this.offchainMessage, Uint8List bytes)
    : bytes = bytes.asUnmodifiableView();

  /// Reads [params] for [address], defaulting the domain to [authority].
  /// Throws [FormatException] for a request it cannot write faithfully, or
  /// one that is not valid at [now] (the device's clock when left out).
  factory SolanaSignInRequest.parse(
    Map<String, dynamic> params, {
    required String authority,
    required String address,
    DateTime? now,
  }) {
    String? field(String key, Object? value) {
      if (value == null) return null;
      if (value is! String ||
          value.length > kMaxSignInFieldLength ||
          value.contains('\n') ||
          value.contains('\r')) {
        throw FormatException('Invalid sign-in $key');
      }
      return value.isEmpty ? null : value;
    }

    final domain = field('domain', params['domain']) ?? authority;
    final statement = field('statement', params['statement']);
    final values = <String, String>{
      for (final MapEntry(key: key, value: label) in _labels.entries)
        if (field(key, params[key]) case final value?) label: value,
    };
    if (values['Version'] case final version? when version != '1') {
      throw const FormatException('Unsupported sign-in version');
    }
    if (signInTimeProblem(values, now ?? DateTime.now()) case final problem?) {
      throw FormatException(problem);
    }
    final rawResources = params['resources'];
    List<String>? resources;
    if (rawResources != null) {
      if (rawResources is! List ||
          rawResources.isEmpty ||
          rawResources.length > kMaxSignInResources) {
        throw const FormatException('Invalid sign-in resources');
      }
      resources = [
        for (final resource in rawResources)
          field('resource', resource) ??
              (throw const FormatException('Invalid sign-in resources')),
      ];
    }
    final offchain = params['useOffchainMessage'];
    if (offchain != null &&
        (offchain is! Map || offchain['messageVersion'] != 1)) {
      throw const FormatException('Unsupported off-chain message version');
    }

    final lines = [
      for (final MapEntry(key: label, value: value) in values.entries)
        '$label: $value',
      if (resources != null) ...[
        'Resources:',
        for (final resource in resources) '- $resource',
      ],
    ];
    final text = [
      '$domain wants you to sign in with your Solana account:\n$address',
      ?statement,
      if (lines.isNotEmpty) lines.join('\n'),
    ].join('\n\n');

    final parsed = parseSignInMessage(
      text,
      address: address,
      chain: 'Solana',
      resourceList: true,
    );
    final expected = {
      'Domain': domain,
      'Account': address,
      ...values,
      if (resources != null) 'Resources': resources.join('\n'),
    };
    if (parsed == null ||
        parsed.statement != statement ||
        !const MapEquality<String, String>().equals(parsed.fields, expected)) {
      throw const FormatException('This sign-in request cannot be shown');
    }

    final bytes = offchain == null
        ? Uint8List.fromList(utf8.encode(text))
        : SolanaOffchainMessage.build(
            content: text,
            requiredSigners: [Uint8List.fromList(base58decode(address))],
          ).bytes;
    return SolanaSignInRequest._(text, offchain != null, bytes);
  }

  /// The sign-in message.
  final String text;

  /// Whether [bytes] wrap [text] in an off-chain message.
  final bool offchainMessage;

  /// What gets signed and returned to the site as `signedMessage`.
  final Uint8List bytes;
}
