import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../portfolio/models/token_balance.dart';
import '../../portfolio/screens/token_detail_screen.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../profile/screens/collection_screen.dart';
import '../../profile/screens/curation_screen.dart';
import '../models/search_models.dart';

/// Navigation for a tapped search / recently-viewed row. Shared so the live
/// results list and the recently-viewed section open content identically.
///
/// Each handler first pops the search sheet (these are invoked from inside it)
/// before routing to the destination.

void openSearchUser(BuildContext context, SearchUserResult user) {
  Navigator.of(context).pop();
  // Anonymous users (no mallow profile) have no username — route by address.
  if (user.username.isEmpty) {
    final address = user.address;
    if (address == null || address.isEmpty) return;
    context.push(AppRoutes.profilePath(address));
    return;
  }
  context.push(AppRoutes.profileByUsernamePath(user.username));
}

void openSearchArtwork(BuildContext context, SearchArtworkResult artwork) {
  Navigator.of(context).pop();
  context.push(AppRoutes.artworkDetailPath(artwork.mintAccount));
}

void openSearchCollection(
  BuildContext context,
  SearchCollectionResult collection,
) {
  final slug = collection.slug;
  Navigator.of(context).pop();

  if (slug != null && slug.isNotEmpty) {
    AppRoutes.rootNavigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => CollectionScreen(
          group: ArtGroup(
            id: slug,
            type: ArtGroupType.collection,
            name: collection.name,
            thumbnailUrl: collection.thumbnailUrl,
            artworkCount: 0,
            artistAddress: collection.curatorAddress,
            collectionMint: slug,
            creatorName: collection.curatorUsername,
          ),
        ),
      ),
    );
  } else if (collection.curatorUsername != null) {
    context.push(AppRoutes.profileByUsernamePath(collection.curatorUsername!));
  }
}

void openSearchCuration(BuildContext context, SearchCurationResult curation) {
  final ownerAddress = curation.ownerAddress;
  Navigator.of(context).pop();

  if (ownerAddress != null && ownerAddress.isNotEmpty) {
    AppRoutes.rootNavigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => CurationScreen(
          group: ArtGroup(
            id: curation.id,
            type: ArtGroupType.curation,
            name: curation.name,
            thumbnailUrl: curation.thumbnailUrls.isNotEmpty
                ? curation.thumbnailUrls.first
                : null,
            artworkCount: curation.artworkCount,
            creatorName: curation.ownerUsername,
          ),
          ownerAddress: ownerAddress,
        ),
      ),
    );
  } else if (curation.ownerUsername != null) {
    context.push(AppRoutes.profileByUsernamePath(curation.ownerUsername!));
  }
}

void openSearchToken(BuildContext context, SearchTokenResult token) {
  final rootCtx = AppRoutes.rootNavigatorKey.currentContext;
  Navigator.of(context).pop();
  if (rootCtx != null) {
    showTokenDetailSheet(
      rootCtx,
      TokenBalance(
        mint: token.mintAddress,
        symbol: token.symbol,
        name: token.name,
        decimals: 0,
        rawBalance: 0,
        uiBalance: 0,
        logoUrl: token.iconUrl,
        pricePerToken: token.usdPrice,
        priceChange24h: token.priceChange24h,
      ),
    );
  }
}
