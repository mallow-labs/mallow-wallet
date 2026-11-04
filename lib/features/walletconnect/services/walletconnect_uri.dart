/// A WalletConnect v2 link: `wc:<topic>@2?symKey=…&relay-protocol=irn…`.
///
/// The `symKey` encrypts the pairing, so whoever holds the URI before the
/// wallet connects can answer the website's proposal in its place. Treat a
/// [WalletConnectUri] and the text it came from as a secret: never log,
/// report or persist either.
class WalletConnectUri {
  const WalletConnectUri._(this.uri, {required this.isPairing});

  /// The `wc:` URI itself, as the SDK pairs with it.
  final Uri uri;

  /// False for the "request waiting" link a website opens for a session that
  /// already exists. It carries no key; it only brings the wallet forward.
  final bool isPairing;

  /// The pairing topic, which the website's proposal names when it comes.
  String get topic => uri.path.substring(0, uri.path.lastIndexOf('@'));

  static final _topic = RegExp(r'^[0-9a-fA-F]{64}$');

  /// Parses [text] as a `wc:` URI, or as one of the wrappers that carry it in
  /// a `uri` query parameter (`mallowwallet://wc?uri=…`, or the universal
  /// link form a website builds for a wallet). Null when it is neither.
  static WalletConnectUri? tryParse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > 2048) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.scheme == 'wc') return _parse(uri);
    final wrapped = uri.queryParameters['uri'];
    if (wrapped != null && isWrapper(uri)) {
      final inner = Uri.tryParse(wrapped);
      if (inner != null && inner.scheme == 'wc') return _parse(inner);
    }
    return null;
  }

  /// Whether [uri] is this app's own wrapper for a `wc:` link: the custom
  /// scheme's `wc` host, so a deep link is recognised before anything logs it.
  static bool isWrapper(Uri uri) =>
      uri.scheme == 'mallowwallet' && uri.host == 'wc';

  static WalletConnectUri? _parse(Uri uri) {
    // `wc:<topic>@<version>?…`: the path holds the topic and version.
    final path = uri.path;
    final at = path.lastIndexOf('@');
    if (at <= 0) return null;
    final topic = path.substring(0, at);
    final version = path.substring(at + 1);
    if (!_topic.hasMatch(topic) || version != '2') return null;
    final query = uri.queryParameters;
    final symKey = query['symKey'];
    if (symKey == null) {
      // A request link names a session the wallet already holds.
      return query.containsKey('requestId')
          ? WalletConnectUri._(uri, isPairing: false)
          : null;
    }
    if (!_topic.hasMatch(symKey)) return null;
    final relay = query['relay-protocol'];
    if (relay != null && relay != 'irn') return null;
    final expiry = int.tryParse(query['expiryTimestamp'] ?? '');
    if (expiry != null &&
        DateTime.fromMillisecondsSinceEpoch(
          expiry * 1000,
          isUtc: true,
        ).isBefore(DateTime.now().toUtc())) {
      return null;
    }
    return WalletConnectUri._(uri, isPairing: true);
  }

  // A URI is a secret; keep it out of any accidental interpolation.
  @override
  String toString() => 'WalletConnectUri(<redacted>)';
}
