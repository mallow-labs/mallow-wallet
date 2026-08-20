import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/sale/services/edition_mint_fees.dart';

/// These numbers are the buyer's *balance requirement*, not decoration:
/// under-quote them and the app starts a buy it knows cannot land, spending
/// the user's time and a signature on a guaranteed on-chain failure — and on
/// an SPL-priced edition they are the only SOL the buy needs, so getting them
/// wrong there means the gate checked nothing at all.
///
/// Pinned against webapp `getTokenStandardMintFees`
/// (`assets`) + the ATA term in
/// `getEditionMintSolFeeLamports` (`swapFunding`).
void main() {
  group('editionPrintSolFeeLamports', () {
    test('Core prints quote rent 0.0025 + protocol 0.0015 and no ATA', () {
      expect(editionPrintSolFeeLamports(tokenStandard: 'core'), 4_000_000);
    });

    test('a Core master edition is a CoreCollection on-chain but still prints '
        'Core assets — it must quote the Core fee, not the collection one', () {
      // The webapp reaches the same answer structurally: the on-chain
      // `Listing.tokenStandard` is `core | nonFungible`, and `toTokenStandard`
      // maps `core` to `TokenStandard.Core`. Quoting the CoreCollection pair
      // (0.0015 + 0.0015) would under-require by 0.001 SOL per print.
      expect(
        editionPrintSolFeeLamports(tokenStandard: 'core-collection'),
        4_000_000,
      );
      // Defensive: the wire spells this `core-collection`, but the Dart model's
      // doc comment claims `coreCollection`. Both must land on the same quote.
      expect(
        editionPrintSolFeeLamports(tokenStandard: 'coreCollection'),
        4_000_000,
      );
    });

    test('legacy prints quote rent 0.01 + protocol 0.01 + 0.002 buyer ATA', () {
      expect(editionPrintSolFeeLamports(tokenStandard: 'nft'), 22_000_000);
    });

    test('an unknown or absent standard errs high (legacy quote), because a '
        'too-low quote silently re-opens the gap this closes', () {
      expect(editionPrintSolFeeLamports(), 22_000_000);
      expect(editionPrintSolFeeLamports(tokenStandard: 'pnft'), 22_000_000);
      expect(editionPrintSolFeeLamports(tokenStandard: 'objkt'), 22_000_000);
    });
  });
}
