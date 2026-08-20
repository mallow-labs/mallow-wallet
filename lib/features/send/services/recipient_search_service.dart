import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../shared/utils/chain.dart';
import '../models/recipient_suggestion.dart';

/// Looks up mallow profiles by username for the recipient address fields.
///
/// Wraps `POST /v1/search/users`, which matches case-insensitively on username,
/// display name and twitter handle (and exactly on address), sorted by follower
/// count. See `search`.
@lazySingleton
class RecipientSearchService {
  RecipientSearchService(this._api);

  final MallowApiClient _api;

  /// How many profiles to ask for. Each can fan out into several rows, so this
  /// is deliberately well under the backend's cap of 30.
  static const _pageSize = 10;

  /// Profiles matching [query], flattened to one suggestion per address that is
  /// valid on [chain].
  ///
  /// Returns `[]` on **any** failure. The search is an accelerator layered over
  /// a field that still accepts a pasted address, so an outage must degrade to
  /// "no suggestions", never to a blocked or erroring input.
  Future<List<RecipientSuggestion>> search(String query, Chain chain) async {
    // The backend strips this itself; doing it here too keeps the length gate
    // in [RecipientSearchController] and the query actually sent in agreement.
    final trimmed = query.trim();
    final normalized = trimmed.startsWith('@') ? trimmed.substring(1) : trimmed;
    if (normalized.isEmpty) return const [];

    try {
      final response = await _api.searchUsers({
        'query': normalized,
        'pageSize': _pageSize,
      });

      final suggestions = <RecipientSuggestion>[];
      final seen = <String>{};

      for (final item in response.result.users) {
        for (final address in item.addresses) {
          // The API stores EVM addresses lower-cased, so the shape-only
          // Ethereum arm of [Chain.isValidAddress] is the right check here:
          // there is no checksum to verify on an all-lowercase address, and the
          // value is server-owned rather than typed.
          if (!chain.isValidAddress(address)) continue;
          // A profile cannot link the same wallet twice, but the response is
          // assembled from two queries that are merged by username — an
          // anonymous duplicate would otherwise render as two identical rows.
          if (!seen.add(address)) continue;
          suggestions.add(
            RecipientSuggestion(
              address: address,
              username: item.username,
              displayName: item.displayName,
              imageUrl: item.imageUrl,
            ),
          );
        }
      }

      return suggestions;
    } catch (e) {
      debugPrint('[RecipientSearchService] search failed: $e');
      return const [];
    }
  }
}
