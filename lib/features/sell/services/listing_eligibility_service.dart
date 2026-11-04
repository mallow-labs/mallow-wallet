import 'package:mallow_api/mallow_api.dart';

import '../../../core/network/auth_service.dart';
import '../../../core/network/das_api_service.dart';
import '../../../core/observability/app_logger.dart';
import '../../../di.dart';
import '../../artwork/models/on_chain_asset.dart';
import 'listing_eligibility.dart';
import 'trade_eligibility.dart';

const _tag = 'ListingEligibility';

/// Loads everything [evaluateListingEligibility] needs and runs the gate.
///
/// Mirrors what the webapp's list-artwork page has in hand before it decides
/// between the form and `VerifyToList`: the current user, `/v0/listingData`
/// for the mint, and the on-chain asset (plus its collection, for Core).
///
/// Every fetch is best-effort. Unknown or suspected v2 assets require a successful
/// eligibility check; known non-v2 standards retain the approved-creator fallback.
/// Callers get `null` when the user may list.
Future<ListingBlockReason?> checkListingEligibility({
  String? mintAccount,
}) async {
  final user = await _currentUser();
  if (mintAccount == null) {
    return evaluateListingEligibility(user: user);
  }

  final api = sl<MallowApiClient>();
  final das = sl<DasApiService>();

  final results = await Future.wait([
    _guard(() => api.getListingData(mintAccount).then((r) => r.result)),
    _guard(() => das.getAsset(mintAccount)),
  ]);
  final listingData = results[0] as ListingData?;
  final asset = results[1] as DigitalAsset?;

  // Core creator checks and v2 escrow eligibility require the collection.
  DigitalAsset? collectionAsset;
  final collectionKey = asset?.collectionKey;
  if ((asset?.tokenStandard == TokenStandard.core ||
          asset?.tokenStandard == TokenStandard.cnftV2) &&
      collectionKey != null) {
    collectionAsset = await _guard(() => das.getAsset(collectionKey));
  }

  final preview = listingData?.nftPreview;
  return evaluateListingEligibility(
    user: user,
    artwork: ArtworkListingFacts(
      isFlagged: preview?.isFlagged ?? false,
      creatorIsFlagged: preview?.creator?.isFlagged ?? false,
      hasVerifiedSale: listingData?.hasVerifiedSale ?? false,
      hasOnChainAsset: asset != null,
      tradeEligibility: resolveTradeEligibility(
        asset: asset,
        collection: collectionAsset,
        expectedTokenStandard: preview?.tokenStandard,
      ),
      hasVerifiedCreator: computeHasVerifiedCreator(
        creator: preview?.creator,
        asset: asset,
        collectionAsset: collectionAsset,
      ),
    ),
  );
}

/// The session user, re-read from the API when possible.
///
/// The webapp re-fetches `/v0/currentUser` when it renders `VerifyToList` so a
/// role granted after sign-in clears the gate without a re-login. A mobile
/// session outlives a browser tab by days, so the same staleness applies —
/// `/v0/userWithDetails` is the public read that carries the fields the gate
/// needs (`roles` filtered to admin/primaryLister, `username`, `imageUrl`,
/// `isTwitterVerified`, `isFlagged`). The result is used for this check only;
/// it is deliberately not written back into [AuthService], whose cached user
/// is the privileged login render and carries fields this one drops.
Future<User?> _currentUser() async {
  final auth = sl<AuthService>();
  final cached = auth.currentUser;
  final address = auth.currentAddress;
  if (address == null) return cached;

  final fresh = await _guard(
    () => sl<MallowApiClient>()
        .getUserWithDetails(
          UserWithDetailsRequest(
            user: UserWithDetailsUser(addresses: [address]),
          ),
        )
        .then((r) => r.result.user),
  );
  return fresh ?? cached;
}

Future<T?> _guard<T>(Future<T> Function() fetch) async {
  try {
    return await fetch();
  } catch (e) {
    AppLogger.warn(_tag, 'Eligibility input failed to load: $e');
    return null;
  }
}
