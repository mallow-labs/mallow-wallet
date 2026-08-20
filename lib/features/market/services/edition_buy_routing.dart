import 'package:mallow_api/mallow_api.dart' show EditionLiveState, SupplyType;

/// Is this artwork a **printable master edition** — i.e. does buying it mint a
/// new print (master-edition print builder) rather than transfer the existing
/// token (fixed-price builder)?
///
/// This is the single decision both the action-sheet routing and the buy
/// builder must agree on. They previously disagreed: the sheet resolved it from
/// the authoritative on-chain edition state while `MarketBloc._onBuy` used the
/// indexer's `supplyType` (`SupplyTypeX.usesBuySingleTx`), which classifies
/// `editionPrint` — a *secondary* edition print someone re-listed, the most
/// common secondary-market purchase — as an edition buy and routed it to the
/// print builder. Mirrors the webapp, which takes the same call from on-chain
/// state for both (`useBuyNow`
/// `isPrintableMasterEdition(onChainAsset)`, defined at
/// `assets`).
///
/// Priority order — identical to the sheet's (`_isEditionMaster` in
/// `lib/features/artwork/services/artwork_action_state.dart`):
///  1. [editionState] — live DAS edition state (`GET /v2/editions/{mint}`),
///     the authoritative signal.
///  2. [isMasterEdition] — the server-derived `/byMint` flag.
///  3. [supplyType] — indexer proxy, `limited-edition` / `open-edition` only.
///     Matches the webapp's `isPrintableMasterEditionFromSupplyType`
///     (`supplyType`), which likewise
///     excludes `edition-print`.
bool resolvePrintableMasterEdition({
  required SupplyType supplyType,
  bool? isMasterEdition,
  EditionLiveState? editionState,
}) {
  if (editionState != null) return editionState.isPrintableMasterEdition;
  if (isMasterEdition != null) return isMasterEdition;
  return supplyType == SupplyType.limitedEdition ||
      supplyType == SupplyType.openEdition;
}
