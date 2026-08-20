import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_raffle_sheet.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_unclaimed_raffle_sheet.dart';

// The pass that put every number the app renders through `groupThousands`
// missed these two sheets, which were being edited at the time. A raffle is
// exactly where the omission bites: supplies run to five and six digits, and
// "12000 / 100000 sold" is the digit soup the webapp's `toLocaleString` exists
// to prevent. The counts are also what a buyer reads to judge their odds, so
// misreading a magnitude here is a decision, not a cosmetic annoyance.

ArtworkDetails _artwork(RaffleMetadata raffle) => ArtworkDetails(
  mintAccount: 'mint1',
  title: 'T',
  imageUrl: '',
  description: null,
  artistName: 'A',
  artistAddress: 'artist1',
  raffleMetadata: raffle,
);

RaffleMetadata _raffle({int? supply, int? sold}) => RaffleMetadata(
  mintAccount: 'mint1',
  creator: 'artist1',
  raffleAccount: 'raffle1',
  entrantsAccount: 'entrants1',
  // Lamports: 0.1 SOL. Present so the summary line renders its full form.
  priceRaw: 100000000,
  currencyMint: 'So11111111111111111111111111111111111111112',
  supply: supply,
  sold: sold,
);

void main() {
  testWidgets('the live sheet groups sold, supply and the wallet limit', (
    tester,
  ) async {
    final raffle = _raffle(supply: 100000, sold: 12345);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ArtworkRaffleSheet(
            artwork: _artwork(raffle),
            role: RaffleRole.observer,
            subState: RaffleSubState.selling,
            raffle: raffle,
            gate: const RaffleGate(walletLimit: 40000, userTickets: 1200),
            onBuyTickets: () {},
            onCancelRaffle: () {},
            onClaimNft: () {},
            onClaimProceeds: () {},
          ),
        ),
      ),
    );

    final summary = tester.widget<Text>(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data?.contains('sold') ?? false),
      ),
    );
    expect(summary.data, contains('12,345 / 100,000 sold'));
    expect(summary.data, contains('Wallet limit: 40,000'));
    expect(summary.data, contains('Your tickets: 1,200'));
  });

  testWidgets('the unclaimed sheet groups its sold count', (tester) async {
    // The creator's claim screen: this figure is the basis of the proceeds
    // they're about to collect.
    final raffle = _raffle(supply: 100000, sold: 12345);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ArtworkUnclaimedRaffleSheet(
            raffle: raffle,
            claim: UnclaimedRaffleClaim.proceeds,
            onClaimNft: () {},
            onClaimProceeds: () {},
          ),
        ),
      ),
    );

    final summary = tester.widget<Text>(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data?.contains('sold') ?? false),
      ),
    );
    expect(summary.data, contains('12,345 / 100,000 sold'));
  });

  testWidgets('counts under a thousand are left alone', (tester) async {
    // The grouping must not invent a separator where the webapp shows none.
    final raffle = _raffle(supply: 500, sold: 12);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ArtworkUnclaimedRaffleSheet(
            raffle: raffle,
            claim: UnclaimedRaffleClaim.proceeds,
            onClaimNft: () {},
            onClaimProceeds: () {},
          ),
        ),
      ),
    );

    final summary = tester.widget<Text>(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data?.contains('sold') ?? false),
      ),
    );
    expect(summary.data, contains('12 / 500 sold'));
  });
}
