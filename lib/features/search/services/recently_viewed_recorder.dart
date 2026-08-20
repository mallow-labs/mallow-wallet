import 'dart:async';

import '../../../core/services/preferences_service.dart';
import '../../../di.dart';
import '../models/recently_viewed_item.dart';
import '../models/search_models.dart';

/// Records content the user opens into the "Recently viewed" list shown on the
/// search landing page.
///
/// Each helper maps a detail screen's native data onto the corresponding
/// search-result model, so a recently-viewed row renders identically to its
/// search-result row. Writes are fire-and-forget — the caller never awaits.
abstract final class RecentlyViewedRecorder {
  static void _save(RecentlyViewedItem item) =>
      unawaited(sl<PreferencesService>().saveRecentlyViewed(item));

  static void recordArtwork({
    required String mintAccount,
    required String title,
    String? thumbnailUrl,
    String? artistUsername,
    int? editionNumber,
  }) {
    _save(
      RecentlyViewedItem.artwork(
        SearchArtworkResult(
          title: title,
          mintAccount: mintAccount,
          thumbnailUrl: thumbnailUrl,
          artistUsername: artistUsername,
          editionNumber: editionNumber,
        ),
      ),
    );
  }

  static void recordProfile({
    required String username,
    String? address,
    String? avatarUrl,
    bool isVerified = false,
    bool isAdmin = false,
  }) {
    _save(
      RecentlyViewedItem.user(
        SearchUserResult(
          username: username,
          address: address,
          avatarUrl: avatarUrl,
          isVerified: isVerified,
          isAdmin: isAdmin,
        ),
      ),
    );
  }

  static void recordCollection({
    required String name,
    String? slug,
    String? thumbnailUrl,
    String? curatorUsername,
    String? curatorAddress,
  }) {
    _save(
      RecentlyViewedItem.collection(
        SearchCollectionResult(
          name: name,
          thumbnailUrl: thumbnailUrl,
          curatorUsername: curatorUsername,
          curatorAddress: curatorAddress,
          slug: slug,
        ),
      ),
    );
  }

  static void recordCuration({
    required String id,
    required String name,
    int artworkCount = 0,
    String? thumbnailUrl,
    String? ownerAddress,
    String? ownerUsername,
  }) {
    _save(
      RecentlyViewedItem.curation(
        SearchCurationResult(
          id: id,
          name: name,
          artworkCount: artworkCount,
          thumbnailUrls: thumbnailUrl != null ? [thumbnailUrl] : const [],
          ownerAddress: ownerAddress,
          ownerUsername: ownerUsername,
        ),
      ),
    );
  }

  static void recordToken({
    required String mintAddress,
    required String name,
    required String symbol,
    String? iconUrl,
    double? usdPrice,
    double? priceChange24h,
  }) {
    _save(
      RecentlyViewedItem.token(
        SearchTokenResult(
          mintAddress: mintAddress,
          name: name,
          symbol: symbol,
          iconUrl: iconUrl,
          usdPrice: usdPrice,
          priceChange24h: priceChange24h,
        ),
      ),
    );
  }
}
