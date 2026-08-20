import 'package:dio/dio.dart';

import '../observability/app_logger.dart';

/// Resolves `.eth` ENS (Ethereum Name Service) domains to Ethereum addresses.
///
/// The Ethereum counterpart to [SnsResolver]: uses the public ENSIdeas API,
/// which handles forward resolution including offchain (CCIP-read) and wildcard
/// resolvers that a naive on-chain registry lookup would miss. Returned
/// addresses are EIP-55 checksummed.
class EnsResolver {
  const EnsResolver._();

  static const _baseUrl = 'https://api.ensideas.com';

  /// Check if an input looks like a .eth domain.
  static bool isEthDomain(String input) {
    final trimmed = input.trim().toLowerCase();
    return trimmed.endsWith('.eth') && trimmed.length > 4;
  }

  /// Resolve a .eth domain to an Ethereum address.
  ///
  /// Returns the address or null if resolution fails (not found or network
  /// error).
  static Future<String?> resolve(String domain) async {
    final trimmed = domain.trim().toLowerCase();

    try {
      final dio = Dio();
      final response = await dio.get<Map<String, dynamic>>(
        '$_baseUrl/ens/resolve/$trimmed',
      );

      final result = response.data?['address'] as String?;
      if (result != null && result.isNotEmpty) {
        return result;
      }
      return null;
    } catch (e) {
      AppLogger.warn('EnsResolver', 'Failed to resolve $domain: $e');
      return null;
    }
  }
}
