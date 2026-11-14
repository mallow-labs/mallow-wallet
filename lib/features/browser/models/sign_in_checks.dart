import 'dapp_message_review.dart';

/// How far ahead of this device's clock a sign-in's `Issued At` or
/// `Not Before` may lie before the request is treated as wrongly dated. A
/// site's server and a phone rarely agree to the second; they do agree to a
/// few minutes.
const kSignInClockSkew = Duration(minutes: 5);

/// A full RFC 3339 date-time with its zone, which is what both sign-in
/// standards ask for. A time without a zone would be read in the device's
/// own, so it is not accepted as a time at all.
final _signInTime = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$',
);

/// The instant a sign-in time field names, or null when it is not a time the
/// wallet can read unambiguously.
DateTime? parseSignInTime(String value) =>
    _signInTime.hasMatch(value) ? DateTime.tryParse(value)?.toUtc() : null;

/// Why a sign-in carrying these times must not be signed as it stands at
/// [now], or null. [fields] are keyed by their label in the message
/// (`Issued At`, `Expiration Time`, `Not Before`).
///
/// A time that cannot be read counts as a problem: the wallet could neither
/// check it nor tell the user when the sign-in stops being valid.
String? signInTimeProblem(Map<String, String> fields, DateTime now) {
  final times = <String, DateTime>{};
  for (final label in const ['Issued At', 'Expiration Time', 'Not Before']) {
    final raw = fields[label];
    if (raw == null) continue;
    final at = parseSignInTime(raw);
    if (at == null) {
      return 'This sign-in request has a time the wallet cannot read';
    }
    times[label] = at;
  }
  final latest = now.add(kSignInClockSkew);
  if (times['Expiration Time'] case final at? when !at.isAfter(now)) {
    return 'This sign-in request has expired';
  }
  if (times['Not Before'] case final at? when at.isAfter(latest)) {
    return 'This sign-in request is not valid yet';
  }
  if (times['Issued At'] case final at? when at.isAfter(latest)) {
    return 'This sign-in request is dated in the future';
  }
  return null;
}

/// Whether a sign-in message's `URI` is a page on [origin], the site that
/// asked for the signature. Anything that does not parse to exactly that
/// origin is a mismatch, including an address with embedded credentials,
/// which reads as one host and resolves to another.
bool signInUriMatches(String uri, Uri origin) {
  final parsed = Uri.tryParse(uri);
  if (parsed == null ||
      !parsed.hasScheme ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty) {
    return false;
  }
  try {
    return parsed.origin == origin.origin;
  } on StateError {
    // Only http and https addresses have an origin.
    return false;
  }
}

/// The `chainId` values that name Solana mainnet: the cluster's short name,
/// its wallet-standard chain and its genesis-hash chain id.
const _solanaMainnetChainIds = {
  'mainnet',
  'mainnet-beta',
  'solana:mainnet',
  'solana:mainnet-beta',
  'solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp',
};

bool isSolanaMainnetChainId(String chainId) =>
    _solanaMainnetChainIds.contains(chainId);

/// What the wallet makes of a strictly parsed sign-in message before it lets
/// the user sign it. The message's own claims (where it signs in to, when it
/// is valid, on which network) are compared with what the wallet knows: the
/// page that asked, and the clock.
class SignInAssessment {
  const SignInAssessment({
    required this.domainMatches,
    required this.uriMatches,
    this.timeProblem,
    this.networkWarning,
  });

  /// The message's domain is the requesting page's own authority.
  final bool domainMatches;

  /// The message names no `URI`, or one on the requesting page's origin.
  final bool uriMatches;

  /// See [signInTimeProblem].
  final String? timeProblem;

  /// A caution naming the network the message asks to sign in on, when that
  /// is not the one this wallet uses.
  final String? networkWarning;

  /// The message signs in to the site that asked for it.
  bool get forThisSite => domainMatches && uriMatches;

  /// Signing is offered reject-first, behind a press-and-hold. A sign-in for
  /// another site is the shape of a phishing page relaying a real site's
  /// challenge; one outside its validity window is one no honest site
  /// needs signed.
  bool get needsHold => !forThisSite || timeProblem != null;
}

/// Assesses [review], whose [DappMessageReview.signInFields] must not be
/// empty, at [now].
SignInAssessment assessSignIn(
  DappMessageReview review, {
  required DateTime now,
}) {
  final fields = review.signInFields;
  final origin = Uri.parse(review.origin);
  final uri = fields['URI'];
  final chainId = fields['Chain ID'];
  // The header names the chain the message was parsed for.
  final solana =
      review.text
          ?.split('\n')
          .first
          .endsWith(' wants you to sign in with your Solana account:') ??
      false;
  return SignInAssessment(
    domainMatches: fields['Domain'] == origin.authority,
    uriMatches: uri == null || signInUriMatches(uri, origin),
    timeProblem: signInTimeProblem(fields, now),
    networkWarning:
        review.signInNetworkWarning ??
        (solana && chainId != null && !isSolanaMainnetChainId(chainId)
            ? 'The message asks to sign in on the Solana network "$chainId", not on mainnet.'
            : null),
  );
}
