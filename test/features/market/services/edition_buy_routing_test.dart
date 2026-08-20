import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/market/services/edition_buy_routing.dart';

/// `resolvePrintableMasterEdition` is the ONE decision the buy builder and
/// the artwork action sheet both route on. If they disagree, the user taps a
/// sheet for one purchase and signs a transaction for another — so the point of
/// these tests is the *priority order*, not any single input.
void main() {
  EditionLiveState editionState({required bool printable}) => EditionLiveState(
    tokenStandard: 'nft',
    isPrintableMasterEdition: printable,
    supplyInfo: const EditionSupplyInfo(supply: 3, maxSupply: 10),
  );

  group('supplyType fallback (no authoritative signal)', () {
    // Mirrors the webapp's `isPrintableMasterEditionFromSupplyType`
    // (supplyType): open + limited
    // editions only.
    test('a printable master is limited-edition or open-edition', () {
      expect(
        resolvePrintableMasterEdition(supplyType: SupplyType.limitedEdition),
        isTrue,
      );
      expect(
        resolvePrintableMasterEdition(supplyType: SupplyType.openEdition),
        isTrue,
      );
    });

    // The regression itself: `edition-print` is a *secondary* resale of an
    // already-minted print. Buying it must transfer that token via the
    // fixed-price builder, never mint a fresh print.
    test('a secondary edition print is NOT a printable master', () {
      expect(
        resolvePrintableMasterEdition(supplyType: SupplyType.editionPrint),
        isFalse,
      );
    });

    test('a 1/1 and a collection are not printable masters', () {
      expect(
        resolvePrintableMasterEdition(supplyType: SupplyType.oneOfOne),
        isFalse,
      );
      expect(
        resolvePrintableMasterEdition(supplyType: SupplyType.collection),
        isFalse,
      );
    });
  });

  group('priority order', () {
    test('live DAS edition state outranks the server flag', () {
      expect(
        resolvePrintableMasterEdition(
          supplyType: SupplyType.editionPrint,
          isMasterEdition: false,
          editionState: editionState(printable: true),
        ),
        isTrue,
      );
      expect(
        resolvePrintableMasterEdition(
          supplyType: SupplyType.openEdition,
          isMasterEdition: true,
          editionState: editionState(printable: false),
        ),
        isFalse,
      );
    });

    test('the server flag outranks the supplyType proxy', () {
      // A fully-minted master the indexer has re-typed as an edition print:
      // the server still knows it is a master.
      expect(
        resolvePrintableMasterEdition(
          supplyType: SupplyType.editionPrint,
          isMasterEdition: true,
        ),
        isTrue,
      );
      // ...and the converse — an indexed "open edition" the server says is not
      // a printable master must not reach the print builder.
      expect(
        resolvePrintableMasterEdition(
          supplyType: SupplyType.openEdition,
          isMasterEdition: false,
        ),
        isFalse,
      );
    });

    test('an explicit false is honoured, not treated as absent', () {
      // Guards the difference between `isMasterEdition == null` (fall through
      // to supplyType) and `isMasterEdition == false` (authoritative no).
      expect(
        resolvePrintableMasterEdition(supplyType: SupplyType.limitedEdition),
        isTrue,
      );
      expect(
        resolvePrintableMasterEdition(
          supplyType: SupplyType.limitedEdition,
          isMasterEdition: false,
        ),
        isFalse,
      );
    });
  });
}
