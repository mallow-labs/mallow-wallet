import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart' show smoresMint;
import 'package:mallow_wallet/core/utils/price_formatter.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

void main() {
  group('PriceFormatter.formatRawAmount', () {
    test('null and zero collapse to "0"', () {
      expect(PriceFormatter.formatRawAmount(null, PriceFormatter.solMint), '0');
      expect(PriceFormatter.formatRawAmount(0, PriceFormatter.solMint), '0');
      expect(PriceFormatter.formatRawAmount(0, null), '0');
    });

    test('unregistered mint says so rather than guessing SOL', () {
      // The registry is the only source of a mint's decimals and symbol.
      // Falling back to SOL's 9 decimals printed a 6-decimal token's 1 unit as
      // "0.001" — a wrong figure the user has no way to spot. Returning the
      // empty string instead was the other dishonest answer: only a handful of
      // price surfaces route through `TokenAmountText`, so every other caller
      // painted a blank into a row that says "price". Name the problem.
      expect(
        PriceFormatter.formatRawAmount(1e9, 'unknown-mint-not-in-table'),
        kUnknownTokenLabel,
      );
      expect(
        PriceFormatter.formatRawAmount(1e6, 'unknown-mint-not-in-table'),
        kUnknownTokenLabel,
      );
    });

    test('a null mint still means the native currency, not "unknown"', () {
      // Absent ≠ unrecognized: the wire omits `currencyMint` for native-SOL
      // amounts, and the webapp defaults it the same way
      // (`PriceDisplay` `price?.currencyMint ?? SOL`).
      expect(PriceFormatter.formatRawAmount(1e9, null), '1');
    });

    test('an unregistered mint is not rescued by the chain hint', () {
      // An unkeyed FA contract is not tez, so rendering it with tez's symbol
      // and 1e6 scaling states a figure nobody computed. Knowing the chain
      // narrows which native currency an *absent* mint means; it says nothing
      // about a mint that is present and unrecognized.
      expect(
        PriceFormatter.formatRawAmountWithSymbol(
          1000000,
          'KT1UnknownFaContract',
          chain: 'tezos',
        ),
        kUnknownTokenLabel,
      );
    });

    test('a four-digit abbreviated tier is thousands-grouped', () {
      // Everything at or above 500 display units takes the abbreviation path,
      // so the only figure that can reach four digits is a high B tier.
      // 1.5e12 SOL -> "1,500B", not "1500B" — the webapp groups every tier
      // through `.toLocaleString()` (`tokens`).
      expect(
        PriceFormatter.formatRawAmount(1.5e12 * 1e9, PriceFormatter.solMint),
        '1,500B',
      );
    });

    test('SOL: sub-1k values are truncated (not rounded) to 3 decimals', () {
      // 1.2349 SOL -> truncated to 1.234, then trailing-zero stripped.
      expect(
        PriceFormatter.formatRawAmount(1_234_900_000, PriceFormatter.solMint),
        '1.234',
      );
      // 0.5 SOL renders without trailing zeros.
      expect(
        PriceFormatter.formatRawAmount(500_000_000, PriceFormatter.solMint),
        '0.5',
      );
      // Exactly 1 SOL renders as a whole number.
      expect(
        PriceFormatter.formatRawAmount(1_000_000_000, PriceFormatter.solMint),
        '1',
      );
    });

    test('USDC: sub-1k values truncate to 2 decimals', () {
      // 12.349 USDC (6 decimals) -> 12.34
      expect(
        PriceFormatter.formatRawAmount(12_349_999, PriceFormatter.usdcMint),
        '12.34',
      );
      // 10 USDC even -> '10'
      expect(
        PriceFormatter.formatRawAmount(10_000_000, PriceFormatter.usdcMint),
        '10',
      );
    });

    test('BONK: sub-1k values truncate to 0 decimals', () {
      // 100 BONK (5 decimals): below the 500 abbreviation threshold so it
      // stays in the plain truncate path.
      expect(
        PriceFormatter.formatRawAmount(100_00000, PriceFormatter.bonkMint),
        '100',
      );
    });

    test('JUP: 1 display decimal place', () {
      // 12.37 JUP (6 decimals) -> '12.3' (truncated)
      expect(
        PriceFormatter.formatRawAmount(12_370_000, PriceFormatter.jupMint),
        '12.3',
      );
    });

    test('crosses 1k threshold and abbreviates with K', () {
      // 1,500 SOL display -> 1.5K (after ceil/divide/roundUp).
      const raw = 1500 * 1e9;
      expect(
        PriceFormatter.formatRawAmount(raw, PriceFormatter.solMint),
        endsWith('K'),
      );
    });

    test('crosses 1M threshold and abbreviates with M', () {
      // 1,500,000 SOL -> at least ends with M, not K or B.
      const raw = 1_500_000 * 1e9;
      final out = PriceFormatter.formatRawAmount(raw, PriceFormatter.solMint);
      expect(out, endsWith('M'));
      expect(out, isNot(endsWith('B')));
    });

    test('crosses 1B threshold and abbreviates with B', () {
      const raw = 1_500_000_000 * 1e9;
      expect(
        PriceFormatter.formatRawAmount(raw, PriceFormatter.solMint),
        endsWith('B'),
      );
    });

    test('below 500 stays plain, 500+ enters abbreviated path', () {
      // 499 SOL: ceil(499)/1000 rounds to 0 → no abbreviation.
      expect(
        PriceFormatter.formatRawAmount(499 * 1e9, PriceFormatter.solMint),
        '499',
      );
      // 1000 SOL → '1K' (after stripTrailingZeros on '1.00').
      expect(
        PriceFormatter.formatRawAmount(1000 * 1e9, PriceFormatter.solMint),
        '1K',
      );
    });
  });

  group('PriceFormatter.formatRawAmountWithSymbol', () {
    test('null amount returns empty string (not "0 SOL")', () {
      expect(
        PriceFormatter.formatRawAmountWithSymbol(null, PriceFormatter.solMint),
        '',
      );
    });

    test('zero amount renders as "0 <symbol>"', () {
      expect(
        PriceFormatter.formatRawAmountWithSymbol(0, PriceFormatter.solMint),
        '0 SOL',
      );
      expect(
        PriceFormatter.formatRawAmountWithSymbol(0, PriceFormatter.usdcMint),
        '0 USDC',
      );
    });

    test('dev USDC mint uses its canonical "USDC_DEV" symbol', () {
      // PriceFormatter now resolves symbols/decimals through the canonical
      // tokenByMint registry (mallow_tokens.dart), where the devnet mint is
      // named 'USDC_DEV'. It is devnet-only and excluded from the bid-currency
      // picker, so the explicit suffix is acceptable.
      expect(
        PriceFormatter.formatRawAmountWithSymbol(
          1_000_000,
          PriceFormatter.usdcDevMint,
        ),
        '1 USDC_DEV',
      );
    });

    test('unregistered mint yields the unknown-token label, not a symbol', () {
      // Never label an unknown token's amount "SOL": the number would be wrong
      // (scaled by the wrong decimals) *and* attributed to the wrong asset.
      // The label replaces the whole "<amount> <symbol>" pair — a bare amount
      // with no ticker is as unreadable as the wrong ticker.
      expect(
        PriceFormatter.formatRawAmountWithSymbol(1e9, 'unknown'),
        kUnknownTokenLabel,
      );
      // An absent amount is a different thing from an unknown currency and
      // still collapses to nothing.
      expect(PriceFormatter.formatRawAmountWithSymbol(null, 'unknown'), '');
    });

    test('SMORES uses its own 6-decimal/0-display formatting, not SOL', () {
      // Regression: SMORES was absent from the old hardcoded _tokenInfo table,
      // so raw 500_000_000 rendered as "0.5 SOL" (9 decimals + SOL fallback)
      // instead of "500 SMORES" (6 decimals). An auction reserve denominated
      // in SMORES must surface the correct token and amount.
      expect(
        PriceFormatter.formatRawAmountWithSymbol(500000000, smoresMint),
        '500 SMORES',
      );
    });

    test('mallowSOL symbol round-trips', () {
      expect(
        PriceFormatter.formatRawAmountWithSymbol(
          1e9,
          PriceFormatter.mallowSolMint,
        ),
        '1 mallowSOL',
      );
    });
  });

  group('PriceFormatter.abbreviateAmount', () {
    test(
      '500 (sub-K but in abbreviated path) returns 2-decimal plain number',
      () {
        // The sub-K branch returns _roundUp(amount, 2) stripped.
        // 500 -> '500' (no trailing zeros).
        expect(PriceFormatter.abbreviateAmount(500), '500');
      },
    );

    test('1000 rounds up to 1K, 1500 to 1.5K', () {
      expect(PriceFormatter.abbreviateAmount(1000), '1K');
      expect(PriceFormatter.abbreviateAmount(1500), '1.5K');
    });

    test('1234 rounds to 1.23K (toStringAsFixed truncates before roundUp)', () {
      // 1234 / 1000 = 1.234 → toStringAsFixed(2) snaps to '1.23' before the
      // K-tier roundUp sees it, so the result floors rather than ceils.
      expect(PriceFormatter.abbreviateAmount(1234), '1.23K');
    });

    test('1,500,000 -> 1.5M', () {
      expect(PriceFormatter.abbreviateAmount(1_500_000), '1.5M');
    });

    test('1,500,000,000 -> 1.5B', () {
      expect(PriceFormatter.abbreviateAmount(1_500_000_000), '1.5B');
    });

    test('negative amounts keep sign through the tiers', () {
      // -1500 -> '-1.5K'
      expect(PriceFormatter.abbreviateAmount(-1500), startsWith('-'));
      expect(PriceFormatter.abbreviateAmount(-1500), endsWith('K'));
    });

    test('decimalPlaces argument is respected', () {
      // With 0 decimals, 1500 rounds up to 2K (ceil after divide).
      expect(PriceFormatter.abbreviateAmount(1500, decimalPlaces: 0), '2K');
    });
  });

  group('PriceFormatter.formatFeeLamports', () {
    test('zero lamports renders as "0 SOL"', () {
      expect(PriceFormatter.formatFeeLamports(0), '0 SOL');
      expect(PriceFormatter.formatFeeLamports(0, sign: '-'), '0 SOL');
    });

    test('5_000 lamports renders with 6-decimal precision (no rounding)', () {
      // Default tx fee. formatRawAmount would have truncated this to "0".
      expect(PriceFormatter.formatFeeLamports(5_000), '0.000005 SOL');
    });

    test('strips trailing zeros after 6-decimal padding', () {
      // 0.001 SOL — trailing zeros after the leading digit get stripped.
      expect(PriceFormatter.formatFeeLamports(1_000_000), '0.001 SOL');
    });

    test('sign argument is prepended for positive lamports', () {
      expect(
        PriceFormatter.formatFeeLamports(5_000, sign: '-'),
        '-0.000005 SOL',
      );
      expect(
        PriceFormatter.formatFeeLamports(5_000, sign: '+'),
        '+0.000005 SOL',
      );
    });

    test(
      'negative lamports force a "-" sign and override the sign argument',
      () {
        // Confirms the renderer can't accidentally show "+-0.000005" if a
        // caller passes a signed delta together with a sign hint.
        expect(PriceFormatter.formatFeeLamports(-5_000), '-0.000005 SOL');
        expect(
          PriceFormatter.formatFeeLamports(-5_000, sign: '+'),
          '-0.000005 SOL',
        );
      },
    );
  });

  group('PriceFormatter.formatRawAmountPrecise', () {
    test('renders sub-unit fractions of a 0-input-decimal token (SMORES)', () {
      // Regression: the auction-settle breakdown (mallow fee / royalties /
      // seller proceeds) is a fraction of the winning bid. SMORES lists in
      // whole numbers (inputDecimals: 0), so formatRawAmount truncates a
      // 0.93 / 0.02 / 0.05 SMORES split to "0". The precise renderer uses the
      // token's 6 on-chain decimals so the fractions survive.
      expect(PriceFormatter.formatRawAmount(930000, smoresMint), '0');
      expect(PriceFormatter.formatRawAmountPrecise(930000, smoresMint), '0.93');
      expect(PriceFormatter.formatRawAmountPrecise(20000, smoresMint), '0.02');
      expect(PriceFormatter.formatRawAmountPrecise(50000, smoresMint), '0.05');
    });

    test('strips trailing zeros for whole amounts', () {
      expect(PriceFormatter.formatRawAmountPrecise(1_000_000, smoresMint), '1');
    });

    test('null/zero render as "0"; symbol variant appends the token', () {
      expect(PriceFormatter.formatRawAmountPrecise(null, smoresMint), '0');
      expect(PriceFormatter.formatRawAmountPrecise(0, smoresMint), '0');
      expect(
        PriceFormatter.formatRawAmountPreciseWithSymbol(50000, smoresMint),
        '0.05 SMORES',
      );
      expect(
        PriceFormatter.formatRawAmountPreciseWithSymbol(null, smoresMint),
        '',
      );
    });
  });

  // `chain` answers exactly one question: what does a price carrying no
  // `currencyMint` mean? A Tezos event's native amount is mutez (1e6), so
  // without the hint it would fall through to the SOL default and a 1 XTZ sale
  // would read "0 SOL". It deliberately does NOT rescue a mint that is present
  // but unregistered — see the `_token` doc.
  group('PriceFormatter chain fallback', () {
    // Not a real token — stands in for any FA contract outside the registry.
    const unknownFaContract = 'KT1ZZZzzzZzZzZzZzZzZzZzZzZzZzZzZzZzZ';

    test('an absent mint means the chain native currency', () {
      // 1 tez = 1e6 mutez. Under the SOL default this would read "0" (1e6 /
      // 1e9 truncated to 3 places) with a SOL symbol.
      expect(
        PriceFormatter.formatRawAmountWithSymbol(
          1_000_000,
          null,
          chain: Chain.tezos.toDbString(),
        ),
        '1 XTZ',
      );
      // The indexer rescales ETH from wei to 8 decimals to match the Solana
      // wrapped-ETH mint, so 0.5 ETH is 5e7 — not 5e17.
      expect(
        PriceFormatter.formatRawAmountWithSymbol(
          50_000_000,
          null,
          chain: Chain.ethereum.toDbString(),
        ),
        '0.5 ETH',
      );
    });

    test('an unregistered currency is unknown on every chain', () {
      // The chain's base token is not a stand-in for an unkeyed currency: an
      // FA contract is not tez and an ERC-20 is not ETH. Rendering one as the
      // other is a wrong number under a wrong ticker — worse than saying so.
      // Solana mints recover through `TokenMetadataService`'s DAS lookup;
      // EVM/Tezos have no such source yet and stay unknown.
      for (final chain in [Chain.tezos, Chain.ethereum, Chain.solana]) {
        expect(
          PriceFormatter.formatRawAmountWithSymbol(
            1_000_000,
            unknownFaContract,
            chain: chain.toDbString(),
          ),
          kUnknownTokenLabel,
          reason: 'unkeyed mint on ${chain.toDbString()}',
        );
      }
    });

    test('a registry hit still wins over the chain hint', () {
      // A Tezos listing priced in a token we do know must format as that
      // token, not as tez.
      expect(
        PriceFormatter.formatRawAmountWithSymbol(
          12_340_000,
          PriceFormatter.usdcMint,
          chain: Chain.tezos.toDbString(),
        ),
        '12.34 USDC',
      );
    });
  });

  group('PriceFormatter.formatListingPrice', () {
    // A listing price of "0" is never a price the user should read as one.
    // The webapp swaps in a word (`PriceDisplay`); mobile printing
    // "0 SOL" told a buyer a free mint costs nothing *and* told a SYOP buyer
    // the artist wants nothing, which is the display half of the SYOP
    // buy-at-zero bug.
    test('a SYOP listing shows the instruction, never its zero price', () {
      expect(
        PriceFormatter.formatListingPrice(
          0,
          PriceFormatter.solMint,
          buyerSetsPrice: true,
        ),
        'Set your own price',
      );
      // The flag wins even if a stale non-zero amount rides along.
      expect(
        PriceFormatter.formatListingPrice(
          5e9,
          PriceFormatter.solMint,
          buyerSetsPrice: true,
        ),
        'Set your own price',
      );
    });

    test('a zero price reads "Free" and an absent one "Not listed"', () {
      expect(
        PriceFormatter.formatListingPrice(0, PriceFormatter.solMint),
        'Free',
      );
      expect(
        PriceFormatter.formatListingPrice(null, PriceFormatter.solMint),
        'Not listed',
      );
    });

    test('showZero opts a total back into rendering the figure', () {
      expect(
        PriceFormatter.formatListingPrice(
          0,
          PriceFormatter.solMint,
          showZero: true,
        ),
        '0 SOL',
      );
    });

    test('a real price is unchanged from the plain formatter', () {
      expect(
        PriceFormatter.formatListingPrice(
          1_500_000_000,
          PriceFormatter.solMint,
        ),
        '1.5 SOL',
      );
      expect(
        PriceFormatter.formatListingPrice(
          1_500_000_000,
          PriceFormatter.solMint,
          withSymbol: false,
        ),
        '1.5',
      );
    });
  });

  group('PriceFormatter.formatDisplayAmount', () {
    // The collection floor arrives already divided (webapp passes
    // `isShortAmount: true`), so it must NOT be scaled a second time.
    test('treats the amount as display units, not raw base units', () {
      expect(
        PriceFormatter.formatDisplayAmount(1.5, PriceFormatter.solMint),
        '1.5',
      );
    });

    test('renders in the passed currency, not a hardcoded SOL profile', () {
      // ETH's inputDecimals is 4, SOL's is 3 — a 4-dp floor must survive.
      expect(
        PriceFormatter.formatDisplayAmount(0.1234, PriceFormatter.ethMint),
        '0.1234',
      );
    });

    test('abbreviates past the same threshold as raw amounts', () {
      expect(
        PriceFormatter.formatDisplayAmount(1500, PriceFormatter.solMint),
        '1.5K',
      );
    });
  });
}
