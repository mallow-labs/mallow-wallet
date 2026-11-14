import 'skr_resolver.dart';
import 'sns_resolver.dart';

/// The Solana name suffixes the recipient and watch-address fields accept,
/// routed to the service that owns each: `.sns` and legacy `.sol` through
/// [SnsResolver], `.skr` through [SkrResolver].
class SolanaNameResolver {
  const SolanaNameResolver._();

  /// Check if an input looks like a name any Solana resolver handles.
  static bool isDomain(String input) =>
      SnsResolver.isSnsDomain(input) || SkrResolver.isSkrDomain(input);

  /// Resolve a Solana name to an address, or null if it does not exist or
  /// cannot be resolved safely.
  static Future<String?> resolve(String domain) =>
      SkrResolver.isSkrDomain(domain)
      ? SkrResolver.resolve(domain)
      : SnsResolver.resolve(domain);

  /// A caution to show beside a resolved [domain], or null when none applies.
  ///
  /// A `.sol` name is read as its `.sns` twin, which is not guaranteed to be
  /// the same owner — see [SnsResolver]. The user sees which name the address
  /// actually came from.
  static String? notice(String domain) {
    if (!SnsResolver.isLegacySolDomain(domain)) return null;
    return 'Resolved as ${SnsResolver.snsNameFor(domain)}. .sol names are '
        'moving to a new registry and may belong to someone else — check '
        'the address.';
  }
}
