import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';

void main() {
  group('MallowToken conversions', () {
    const sol = MallowToken(
      symbol: 'SOL',
      mint: solMint,
      decimals: 9,
      inputDecimals: 3,
      minListingPrice: 10000000, // 0.01 SOL
    );

    const foxy = MallowToken(
      symbol: 'FOXY',
      mint: foxyMint,
      decimals: 0,
      inputDecimals: 0,
      minListingPrice: 1000,
    );

    test('rawToDisplay divides by 10^decimals', () {
      expect(sol.rawToDisplay(1000000000), 1.0);
      expect(sol.rawToDisplay(10000000), 0.01);
      expect(sol.rawToDisplay(0), 0.0);
    });

    test('rawToDisplay with zero-decimal token is identity', () {
      expect(foxy.rawToDisplay(1234), 1234.0);
      expect(foxy.rawToDisplay(0), 0.0);
    });

    test('displayToRaw multiplies and rounds', () {
      expect(sol.displayToRaw(1.0), 1000000000);
      expect(sol.displayToRaw(0.01), 10000000);
      // Rounding: 0.0000000005 SOL = 0.5 lamport -> rounds to 1.
      expect(sol.displayToRaw(0.0000000005), 1);
      expect(sol.displayToRaw(0.0), 0);
    });

    test('minListingDisplay matches rawToDisplay(minListingPrice)', () {
      expect(sol.minListingDisplay, 0.01);
      expect(foxy.minListingDisplay, 1000.0);
    });

    test('displayToRaw and rawToDisplay round-trip on integer units', () {
      for (final raw in [0, 1, 1000, 1234567890]) {
        expect(sol.displayToRaw(sol.rawToDisplay(raw)), raw);
      }
    });
  });

  group('tokenByMint / tokenBySymbol', () {
    test('returns null for null mint', () {
      expect(tokenByMint(null), isNull);
    });

    test('returns null for unknown mint', () {
      expect(tokenByMint('not-a-real-mint'), isNull);
    });

    test('returns null for unknown symbol', () {
      expect(tokenBySymbol('NOPE'), isNull);
    });

    test('looks up SOL by mint and symbol', () {
      final byMint = tokenByMint(solMint);
      final bySymbol = tokenBySymbol('SOL');
      expect(byMint, isNotNull);
      expect(byMint!.symbol, 'SOL');
      expect(byMint.decimals, 9);
      expect(bySymbol?.mint, solMint);
      // The two lookups must resolve to the same registry entry.
      expect(identical(byMint, bySymbol), isTrue);
    });

    test('looks up USDC and ETH', () {
      expect(tokenByMint(usdcMint)?.decimals, 6);
      expect(tokenByMint(ethMint)?.disableSwap, isTrue);
    });

    test('devnet entries are reachable through tokenByMint', () {
      // Lookup must work for devnet mints regardless of picker filtering so
      // existing balances can render.
      final dev = tokenByMint(usdcDevMint);
      expect(dev, isNotNull);
      expect(dev!.isDevnet, isTrue);
    });
  });

  group('mallowTokenMints', () {
    test('contains every registered mint', () {
      expect(mallowTokenMints, contains(solMint));
      expect(mallowTokenMints, contains(usdcMint));
      expect(mallowTokenMints, contains(usdcDevMint));
      expect(mallowTokenMints, contains(ethMint));
    });

    test('is unmodifiable', () {
      expect(() => mallowTokenMints.add('x'), throwsUnsupportedError);
    });
  });

  group('defaultBidToken', () {
    test('is SOL', () {
      expect(defaultBidToken.symbol, 'SOL');
      expect(defaultBidToken.mint, solMint);
    });
  });

  group('pickableBidTokens', () {
    // `ENV` defaults to production, so devnet is a choice this group has to
    // make. Selecting it here keeps the devnet branch covered instead of
    // letting it drop out of the suite when the default flipped.
    setUp(() => Config.debugOverrides['ENV'] = 'development');
    tearDown(Config.debugOverrides.clear);

    test('returns default symbols when no user mints provided', () {
      final picks = pickableBidTokens();
      final symbols = picks.map((t) => t.symbol).toList();
      expect(symbols, containsAll(defaultListingTokenSymbols));
      // No extras beyond the defaults.
      expect(symbols.length, defaultListingTokenSymbols.length);
    });

    test('uses USDC_DEV instead of real USDC on devnet', () {
      // The group selects ENV=development, so Config.isDevnet is true.
      // Mirrors the reference web client: the USDC default is swapped for the devnet mint
      // so listings on devnet don't reference the real mainnet USDC.
      final mints = pickableBidTokens().map((t) => t.mint).toList();
      expect(mints, contains(usdcDevMint));
      expect(mints, isNot(contains(usdcMint)));
    });

    test('keeps user-enabled devnet tokens on devnet', () {
      // On devnet the picker does not strip isDevnet entries.
      final picks = pickableBidTokens(userListingMints: [xnuDevMint]);
      expect(picks.any((t) => t.mint == xnuDevMint), isTrue);
    });

    test('adds user-enabled non-devnet mints to the picker', () {
      // BONK is not in the default list — opting in must surface it.
      final picks = pickableBidTokens(userListingMints: [bonkMint]);
      final symbols = picks.map((t) => t.symbol).toList();
      expect(symbols, contains('BONK'));
      expect(symbols, containsAll(defaultListingTokenSymbols));
    });

    test('null userListingMints behaves like empty', () {
      final picksNull = pickableBidTokens();
      final picksEmpty = pickableBidTokens(userListingMints: const []);
      expect(
        picksNull.map((t) => t.symbol).toList(),
        picksEmpty.map((t) => t.symbol).toList(),
      );
    });

    test('returns an unmodifiable-style fixed list (growable: false)', () {
      final picks = pickableBidTokens();
      expect(() => picks.add(defaultBidToken), throwsUnsupportedError);
    });
  });
}
