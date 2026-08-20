import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/sale/services/proceeds_calculator.dart';

ArtworkRoyaltySplit _split(String address, int sharePercent) =>
    ArtworkRoyaltySplit(address: address, sharePercent: sharePercent);

const _seller = 'SELLERseller11111111111111111111111111111111';
const _creatorA = 'CREATORaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _creatorB = 'CREATORbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

ProceedsSplit _findByAddress(List<ProceedsSplit> rows, String address) =>
    rows.firstWhere((r) => r.address == address);

void main() {
  group('computeProceedsSplits', () {
    group('secondary sale', () {
      test('250 bps fee + 10% royalty across two creators', () {
        final rows = computeProceedsSplits(
          seller: _seller,
          priceRaw: 1_000_000_000, // 1 SOL
          isSecondary: true,
          royaltyShares: [_split(_creatorA, 60), _split(_creatorB, 40)],
          royaltyBps: 1000, // 10%
          primaryFeeBps: 500,
          secondaryFeeBps: 250,
        );

        expect(rows, hasLength(4));
        // Sorted descending: seller 87.5, creatorA 6, creatorB 4, mallow 2.5
        expect(rows.map((r) => r.address).toList(), [
          _seller,
          _creatorA,
          _creatorB,
          kMallowFeeAddress,
        ]);

        final mallow = _findByAddress(rows, kMallowFeeAddress);
        expect(mallow.label, ProceedsLabel.mallow);
        expect(mallow.proceedsPct, 2.5);
        expect(mallow.amountRaw, 25_000_000);

        final you = _findByAddress(rows, _seller);
        expect(you.label, ProceedsLabel.you);
        expect(you.proceedsPct, closeTo(87.5, 1e-9));
        expect(you.amountRaw, 875_000_000);

        final a = _findByAddress(rows, _creatorA);
        expect(a.label, ProceedsLabel.creator);
        expect(a.proceedsPct, closeTo(6.0, 1e-9));
        expect(a.amountRaw, 60_000_000);

        final b = _findByAddress(rows, _creatorB);
        expect(b.label, ProceedsLabel.creator);
        expect(b.proceedsPct, closeTo(4.0, 1e-9));
        expect(b.amountRaw, 40_000_000);

        // Splits sum to 100%.
        final sumPct = rows.fold<double>(0, (s, r) => s + r.proceedsPct);
        expect(sumPct, closeTo(100.0, 1e-9));
      });

      test('no royalty splits → seller gets everything minus fee', () {
        final rows = computeProceedsSplits(
          seller: _seller,
          priceRaw: 1_000_000_000,
          isSecondary: true,
          royaltyShares: [],
          royaltyBps: 1000,
          primaryFeeBps: 500,
          secondaryFeeBps: 250,
        );

        expect(rows, hasLength(2));
        final you = _findByAddress(rows, _seller);
        expect(you.label, ProceedsLabel.you);
        // When there are no splits, the royalty pct is still subtracted from
        // the seller's remaining — that matches the webapp implementation.
        expect(you.proceedsPct, closeTo(87.5, 1e-9));
        expect(you.amountRaw, 875_000_000);

        final mallow = _findByAddress(rows, kMallowFeeAddress);
        expect(mallow.proceedsPct, 2.5);
      });

      test('seller is also a creator → combined into one "you" row', () {
        final rows = computeProceedsSplits(
          seller: _seller,
          priceRaw: 1_000_000_000,
          isSecondary: true,
          royaltyShares: [_split(_seller, 50), _split(_creatorA, 50)],
          royaltyBps: 1000,
          primaryFeeBps: 500,
          secondaryFeeBps: 250,
        );

        expect(rows, hasLength(3));
        final you = _findByAddress(rows, _seller);
        expect(you.label, ProceedsLabel.you);
        // Seller-as-creator: 87.5% remainder + 5% royalty share = 92.5%.
        expect(you.proceedsPct, closeTo(92.5, 1e-9));
        expect(you.amountRaw, 925_000_000);

        final a = _findByAddress(rows, _creatorA);
        expect(a.proceedsPct, closeTo(5.0, 1e-9));
      });
    });

    group('primary sale', () {
      test('splits enabled → ALL non-fee goes to creators, none to seller', () {
        final rows = computeProceedsSplits(
          seller: _seller,
          priceRaw: 1_000_000_000,
          isSecondary: false,
          royaltyShares: [_split(_creatorA, 60), _split(_creatorB, 40)],
          royaltyBps: 1000, // ignored on primary when splits are enabled
          primaryFeeBps: 500,
          secondaryFeeBps: 250,
        );

        // Seller is NOT one of the creators → no row for seller.
        expect(rows.where((r) => r.address == _seller), isEmpty);
        expect(rows, hasLength(3));

        final mallow = _findByAddress(rows, kMallowFeeAddress);
        expect(mallow.proceedsPct, 5.0);
        expect(mallow.amountRaw, 50_000_000);

        final a = _findByAddress(rows, _creatorA);
        expect(a.proceedsPct, closeTo(57.0, 1e-9)); // 95 * 0.6
        expect(a.amountRaw, 570_000_000);

        final b = _findByAddress(rows, _creatorB);
        expect(b.proceedsPct, closeTo(38.0, 1e-9));
        expect(b.amountRaw, 380_000_000);
      });

      test('splits enabled with seller-as-creator → seller labeled "you"', () {
        final rows = computeProceedsSplits(
          seller: _seller,
          priceRaw: 1_000_000_000,
          isSecondary: false,
          royaltyShares: [_split(_seller, 70), _split(_creatorA, 30)],
          royaltyBps: 1000,
          primaryFeeBps: 500,
          secondaryFeeBps: 250,
        );

        expect(rows, hasLength(3));
        final you = _findByAddress(rows, _seller);
        expect(you.label, ProceedsLabel.you);
        expect(you.proceedsPct, closeTo(66.5, 1e-9));
      });

      test('empty royalty shares → falls back to secondary-style logic', () {
        // No creators to distribute to → the "remaining" assignment to
        // the seller kicks in via the else branch.
        final rows = computeProceedsSplits(
          seller: _seller,
          priceRaw: 1_000_000_000,
          isSecondary: false,
          royaltyShares: [],
          royaltyBps: 1000,
          primaryFeeBps: 500,
          secondaryFeeBps: 250,
        );

        expect(rows, hasLength(2));
        final you = _findByAddress(rows, _seller);
        // Falls into the secondary-style branch: 100 - 5 (fee) - 10 (royalty) = 85.
        expect(you.proceedsPct, closeTo(85.0, 1e-9));
        expect(you.amountRaw, 850_000_000);
      });

      test('disablePrimarySplit=true → behaves like secondary', () {
        final rows = computeProceedsSplits(
          seller: _seller,
          priceRaw: 1_000_000_000,
          isSecondary: false,
          disablePrimarySplit: true,
          royaltyShares: [_split(_creatorA, 100)],
          royaltyBps: 1000,
          primaryFeeBps: 500,
          secondaryFeeBps: 250,
        );

        // Mirrors the secondary branch: fee=5%, royalty=10% to creators,
        // seller gets remaining=85%. (Uses primary fee, not secondary.)
        expect(rows, hasLength(3));
        final mallow = _findByAddress(rows, kMallowFeeAddress);
        expect(mallow.proceedsPct, 5.0);
        final you = _findByAddress(rows, _seller);
        expect(you.proceedsPct, closeTo(85.0, 1e-9));
        final a = _findByAddress(rows, _creatorA);
        expect(a.proceedsPct, closeTo(10.0, 1e-9));
      });
    });

    group('edge cases', () {
      test('priceRaw == 0 → amounts all zero, percentages preserved', () {
        final rows = computeProceedsSplits(
          seller: _seller,
          priceRaw: 0,
          isSecondary: true,
          royaltyShares: [_split(_creatorA, 100)],
          royaltyBps: 1000,
          primaryFeeBps: 500,
          secondaryFeeBps: 250,
        );

        for (final r in rows) {
          expect(r.amountRaw, 0, reason: '${r.label} should have 0 amount');
        }
        expect(_findByAddress(rows, kMallowFeeAddress).proceedsPct, 2.5);
      });

      test('priceRaw < 0 (defensive) → amounts coerced to 0', () {
        // The contract says price is unsigned, but the implementation guards
        // against <= 0 anyway. Lock that in.
        final rows = computeProceedsSplits(
          seller: _seller,
          priceRaw: -1,
          isSecondary: true,
          royaltyShares: [_split(_creatorA, 100)],
          royaltyBps: 1000,
          primaryFeeBps: 500,
          secondaryFeeBps: 250,
        );
        for (final r in rows) {
          expect(r.amountRaw, 0);
        }
      });

      test('0 bps fees and 0 royalty → seller gets 100% on secondary', () {
        final rows = computeProceedsSplits(
          seller: _seller,
          priceRaw: 1_000_000_000,
          isSecondary: true,
          royaltyShares: [],
          royaltyBps: 0,
          primaryFeeBps: 0,
          secondaryFeeBps: 0,
        );

        // The marketplace row still appears (at 0%) because it's seeded
        // unconditionally. Lock that behavior in so the UI knows to render `—`.
        final mallow = _findByAddress(rows, kMallowFeeAddress);
        expect(mallow.proceedsPct, 0);
        expect(mallow.amountRaw, 0);

        final you = _findByAddress(rows, _seller);
        expect(you.proceedsPct, 100.0);
        expect(you.amountRaw, 1_000_000_000);
      });

      test('amounts use banker-free rounding (round half away from zero)', () {
        // priceRaw=3, 50% share → 1.5 → 2 (dart's int.round() rounds half
        // away from zero). Lock the rounding mode so future refactors notice.
        final rows = computeProceedsSplits(
          seller: _seller,
          priceRaw: 3,
          isSecondary: true,
          royaltyShares: [],
          royaltyBps: 0,
          primaryFeeBps: 0,
          secondaryFeeBps: 5000, // 50%
        );

        final mallow = _findByAddress(rows, kMallowFeeAddress);
        expect(mallow.proceedsPct, 50.0);
        expect(mallow.amountRaw, 2); // 1.5 rounded → 2

        final you = _findByAddress(rows, _seller);
        expect(you.amountRaw, 2);
      });

      test('rows are sorted by proceeds percentage descending', () {
        final rows = computeProceedsSplits(
          seller: _seller,
          priceRaw: 1_000_000_000,
          isSecondary: true,
          royaltyShares: [_split(_creatorA, 30), _split(_creatorB, 70)],
          royaltyBps: 1000,
          primaryFeeBps: 500,
          secondaryFeeBps: 250,
        );

        for (var i = 0; i < rows.length - 1; i++) {
          expect(
            rows[i].proceedsPct >= rows[i + 1].proceedsPct,
            isTrue,
            reason: 'row $i should be >= row ${i + 1}',
          );
        }
        // Within the creators: B (70%) should come before A (30%).
        final indexA = rows.indexWhere((r) => r.address == _creatorA);
        final indexB = rows.indexWhere((r) => r.address == _creatorB);
        expect(indexB, lessThan(indexA));
      });
    });
  });
}
