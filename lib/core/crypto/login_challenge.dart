import 'dart:convert';
import 'dart:typed_data';

import '../../features/browser/models/dapp_message_review.dart';
import '../../features/browser/services/solana_dapp_transaction.dart';
import '../config/environment.dart';
import 'exceptions.dart';

/// How far the device clock may disagree with the server's before a
/// challenge's `Issued At` / `Expiration Time` counts as wrong. Generous on
/// purpose: the server enforces its own expiry, so this check only has to
/// catch a challenge that is plainly not fresh, and a phone set a few minutes
/// off must still be able to log in.
const Duration loginChallengeClockSkew = Duration(minutes: 15);

/// The longest validity window a login challenge may claim. The server issues
/// a few minutes; a long-lived sign-in is worth more to whoever holds it.
const Duration loginChallengeMaxLifetime = Duration(hours: 1);

/// Refuses to let the wallet sign a Sign in with Solana login challenge unless
/// it is a sign-in to this app's own backend, for [address], and fresh.
///
/// The login handshake signs the server's message verbatim, in the background
/// and for every session wallet, with no review screen. Before signing, the
/// app must therefore establish for itself what the user would otherwise have
/// read. A hijacked or misconfigured API response could otherwise obtain a
/// valid sign-in for a third-party site, or a signature over transaction
/// bytes. Throws [LoginChallengeRejectedException] when any rule fails:
///
/// - The text is neither a Solana transaction nor a compiled message
///   ([isSolanaSigningPayload]) and holds no control character but `\n`.
/// - The whole text is a strictly parsed sign-in message
///   ([parseSignInMessage]) whose account line is [address].
/// - Its domain is first-party ([loginChallengeDomains]), and `URI` is
///   `https://<domain>`.
/// - `Version` is `1`, and `Nonce` is at least 8 letters or digits.
/// - `Issued At` and `Expiration Time` are both present, the window between
///   them is positive and at most [loginChallengeMaxLifetime], and [now] lies
///   inside it, give or take [loginChallengeClockSkew]. `Not Before`, if
///   present, has passed.
/// - `Chain ID`, which the backend does not send today, is refused unless it
///   names the Solana cluster this build runs on.
void checkSolanaLoginChallenge(
  String message, {
  required String address,
  DateTime? now,
}) {
  Never reject(String reason) => throw LoginChallengeRejectedException(reason);

  if (isSolanaSigningPayload(Uint8List.fromList(utf8.encode(message)))) {
    reject('it is shaped like a transaction');
  }
  if (message.codeUnits.any((c) => (c < 0x20 && c != 0x0A) || c == 0x7F)) {
    reject('it contains control characters');
  }
  final parsed = parseSignInMessage(message, address: address, chain: 'Solana');
  if (parsed == null) {
    reject('it is not a sign-in message for this wallet');
  }
  final fields = parsed.fields;

  final domain = fields['Domain']!;
  final domainUri = Uri.tryParse('https://$domain');
  if (domainUri == null ||
      domainUri.host.isEmpty ||
      domainUri.authority != domain ||
      domainUri.userInfo.isNotEmpty ||
      !loginChallengeDomains().contains(domainUri.host)) {
    reject('it names a site other than this app');
  }
  if (fields['URI'] != 'https://$domain') {
    reject('its URI does not match its domain');
  }

  if (fields['Version'] != '1') reject('its version is not 1');
  final nonce = fields['Nonce'];
  if (nonce == null || !RegExp(r'^[A-Za-z0-9]{8,}$').hasMatch(nonce)) {
    reject('its nonce is missing or malformed');
  }

  final chainId = fields['Chain ID'];
  if (chainId != null && !_expectedChainIds().contains(chainId)) {
    reject('it names a different Solana network');
  }

  DateTime? time(String key) {
    final value = fields[key];
    return value == null ? null : DateTime.tryParse(value);
  }

  final issuedAt = time('Issued At');
  final expiresAt = time('Expiration Time');
  if (issuedAt == null || expiresAt == null) {
    reject('it has no valid issue or expiry time');
  }
  final lifetime = expiresAt.difference(issuedAt);
  if (lifetime <= Duration.zero || lifetime > loginChallengeMaxLifetime) {
    reject('its validity window is not plausible');
  }
  final clock = now ?? DateTime.now();
  if (issuedAt.isAfter(clock.add(loginChallengeClockSkew))) {
    reject('it was issued in the future');
  }
  if (!expiresAt.isAfter(clock.subtract(loginChallengeClockSkew))) {
    reject('it has expired');
  }
  if (fields.containsKey('Not Before')) {
    final notBefore = time('Not Before');
    if (notBefore == null ||
        notBefore.isAfter(clock.add(loginChallengeClockSkew))) {
      reject('it is not valid yet');
    }
  }
}

/// The hosts a login challenge may name as its domain.
///
/// The backend names the domain of the web app it belongs to, and serves the
/// API from that domain or a subdomain of it. So the set is each API host
/// ([Config.sessionHosts], derived from `API_BASE_URL`) together with its
/// parent domains of two or more labels, plus every host `FIRST_PARTY_HOSTS`
/// declares, exactly. A parent is never taken from an IP address, and a
/// one-label parent (a top-level domain) is never taken at all.
///
/// A development build points `API_BASE_URL` at a local backend, a host with
/// no parent to derive the web domain from, so it also takes the parents of
/// the `FIRST_PARTY_HOSTS` entries. Release builds do not: an entry there
/// says that host is first-party, not that its whole parent domain is.
Set<String> loginChallengeDomains() {
  final declared = Config.extraFirstPartyHosts;
  return {
    for (final host in Config.sessionHosts) ..._withParents(host),
    ...declared,
    if (Config.isDevelopment)
      for (final host in declared) ..._withParents(host),
  };
}

Iterable<String> _withParents(String host) sync* {
  final lower = host.toLowerCase();
  yield lower;
  if (lower.contains(':') || RegExp(r'^[0-9.]+$').hasMatch(lower)) return;
  final labels = lower.split('.');
  for (var i = 1; i <= labels.length - 2; i++) {
    yield labels.sublist(i).join('.');
  }
}

Set<String> _expectedChainIds() => Config.isProduction
    ? {'mainnet', 'solana:mainnet', Config.solanaChainId}
    : {'devnet', 'solana:devnet', Config.solanaChainId};
