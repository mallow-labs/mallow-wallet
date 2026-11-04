import 'dart:convert';
import 'dart:typed_data';

/// An off-chain message a website asked the wallet to sign, frozen for review.
/// Implemented per chain; the review sheet reads only this.
abstract class DappMessageReview {
  Uint8List get bytes;

  /// The native committed origin of the requesting page.
  String get origin;
  String get address;

  /// What [digest] is, as the review labels it.
  String get digestLabel;

  /// Hex digest the user can compare against another tool.
  String get digest;

  /// Sign-in fields (plus `Domain` and `Account`) when the whole message is a
  /// strictly parsed sign-in message, else empty. See [parseSignInMessage].
  Map<String, String> get signInFields;

  /// The statement of a strictly parsed sign-in message, if it has one.
  String? get signInStatement;

  /// A caution when the sign-in names a network this wallet does not use.
  String? get signInNetworkWarning => null;

  String? get text {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  String get display =>
      text ?? bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

typedef SignInMessage = ({Map<String, String> fields, String? statement});

/// Parses a Sign In With Solana / Ethereum message, or returns null unless the
/// WHOLE message follows the sign-in grammar: header, address, then an
/// optional blank + one-line statement, then an optional blank + known
/// `Key: value` lines and nothing else. A loose match would let a site hide
/// arbitrary text (an order, a permit) behind a friendly sign-in card.
///
/// [chain] is the word in the header ("Solana", "Ethereum"). EIP-4361 also
/// allows a trailing `Resources:` list and a `scheme://` before the domain;
/// [resources] admits the list. A message whose address is not [address] is
/// not a sign-in for this wallet; [caseInsensitive] compares hex addresses
/// without their EIP-55 casing.
SignInMessage? parseSignInMessage(
  String? content, {
  required String address,
  required String chain,
  bool resources = false,
  bool caseInsensitive = false,
}) {
  if (content == null) return null;
  final lines = content.split('\n');
  final suffix = ' wants you to sign in with your $chain account:';
  if (lines.length < 2 ||
      !lines.first.endsWith(suffix) ||
      (caseInsensitive
          ? lines[1].toLowerCase() != address.toLowerCase()
          : lines[1] != address)) {
    return null;
  }
  var domain = lines.first.substring(0, lines.first.length - suffix.length);
  // An https scheme names the same site; anything else stays in the domain,
  // where it fails the comparison with the committed origin.
  if (resources && domain.startsWith('https://')) {
    domain = domain.substring('https://'.length);
  }
  if (domain.isEmpty || domain.contains(RegExp(r'\s'))) return null;
  const keys = {
    'URI',
    'Version',
    'Chain ID',
    'Nonce',
    'Issued At',
    'Expiration Time',
    'Not Before',
    'Request ID',
  };
  MapEntry<String, String>? field(String line) {
    final split = line.indexOf(': ');
    if (split <= 0 || !keys.contains(line.substring(0, split))) return null;
    return MapEntry(line.substring(0, split), line.substring(split + 2));
  }

  final fields = <String, String>{'Domain': domain, 'Account': lines[1]};
  String? statement;
  var i = 2;
  // Each section after the address is introduced by exactly one blank line.
  // Ethereum keeps both separators when the optional statement is absent.
  if (i < lines.length) {
    if (lines[i].isNotEmpty || ++i >= lines.length) return null;
    if (resources && lines[i].isEmpty) {
      if (++i >= lines.length) return null;
    } else if (field(lines[i]) == null &&
        !(resources && lines[i] == 'Resources:')) {
      statement = lines[i];
      if (statement.trim().isEmpty) return null;
      i++;
      if (i < lines.length && (lines[i].isNotEmpty || ++i >= lines.length)) {
        return null;
      }
    }
  }
  for (; i < lines.length; i++) {
    if (resources && lines[i] == 'Resources:') {
      // The list is last, holds at least one item, and nothing follows it.
      final items = <String>[];
      for (i++; i < lines.length; i++) {
        final line = lines[i];
        if (!line.startsWith('- ') || line.length < 3) return null;
        items.add(line.substring(2));
      }
      if (items.isEmpty || fields.containsKey('Resources')) return null;
      fields['Resources'] = items.join('\n');
      break;
    }
    final entry = field(lines[i]);
    if (entry == null || fields.containsKey(entry.key)) return null;
    fields[entry.key] = entry.value;
  }
  return (fields: Map.unmodifiable(fields), statement: statement);
}
