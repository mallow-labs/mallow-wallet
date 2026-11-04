import '../../artwork/models/on_chain_asset.dart';

const verifyingArtworkEligibility = 'Verifying artwork eligibility…';

/// Separates proven transfer restrictions from an incomplete network lookup.
enum TradeEligibility {
  eligible,
  restricted,
  unverified;

  String? get message => switch (this) {
    eligible => null,
    restricted =>
      'This artwork or its collection has transfer restrictions that prevent marketplace trading.',
    unverified => 'Could not verify artwork eligibility. Please try again.',
  };
}

TradeEligibility resolveTradeEligibility({
  required DigitalAsset? asset,
  DigitalAsset? collection,
  String? expectedTokenStandard,
}) {
  if (asset == null) {
    return expectedTokenStandard == null || expectedTokenStandard == 'cnft-v2'
        ? TradeEligibility.unverified
        : TradeEligibility.eligible;
  }
  if (asset.tokenStandard != TokenStandard.cnftV2) {
    return TradeEligibility.eligible;
  }
  if (asset.frozen ||
      asset.nonTransferable ||
      (asset.compressionFlags != null && asset.compressionFlags != 0)) {
    return TradeEligibility.restricted;
  }
  if (asset.compressionFlags == null ||
      (asset.collectionKey != null &&
          (collection == null ||
              collection.id != asset.collectionKey ||
              collection.tokenStandard != TokenStandard.coreCollection))) {
    return TradeEligibility.unverified;
  }
  return asset.isCnftV2TradeEligible(collection: collection)
      ? TradeEligibility.eligible
      : TradeEligibility.restricted;
}
