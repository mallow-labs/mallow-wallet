import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart' as mt;
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';

void main() {
  group('TokenBalance.nativeSol', () {
    test('produces canonical SOL fields and isNative/isVerified true', () {
      const lamports = 1_500_000_000; // 1.5 SOL
      final b = TokenBalance.nativeSol(lamports: lamports);

      expect(b.mint, mt.solMint);
      expect(b.symbol, 'SOL');
      expect(b.decimals, 9);
      expect(b.rawBalance, lamports);
      expect(b.uiBalance, closeTo(1.5, 1e-9));
      expect(b.isNative, isTrue);
      expect(b.isVerified, isTrue);
      // Native SOL gets the canonical logo URL.
      expect(b.logoUrl, isNotNull);
    });

    test('computes totalUsdValue when pricePerToken is supplied', () {
      final b = TokenBalance.nativeSol(
        lamports: 1_000_000_000, // 1 SOL
        pricePerToken: 200,
      );
      expect(b.totalUsdValue, closeTo(200, 1e-9));
    });

    test('leaves totalUsdValue null when no price is supplied', () {
      final b = TokenBalance.nativeSol(lamports: 1_000_000_000);
      expect(b.totalUsdValue, isNull);
    });
  });

  group('TokenBalance.fromHeliusAsset', () {
    test('decodes balance + decimals → uiBalance and basic metadata', () {
      final asset = <String, dynamic>{
        'id': 'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN',
        'token_info': {
          'symbol': 'JUP',
          'decimals': 6,
          'balance': 1_234_567,
          'price_info': {'price_per_token': 0.5, 'total_price': 0.61},
        },
        'content': {
          'metadata': {'name': 'Jupiter'},
          'files': [
            {'uri': 'https://example.com/jup.png'},
          ],
        },
      };
      final b = TokenBalance.fromHeliusAsset(asset);

      expect(b.mint, 'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN');
      expect(b.decimals, 6);
      expect(b.rawBalance, 1_234_567);
      expect(b.uiBalance, closeTo(1.234567, 1e-9));
      expect(b.symbol, 'JUP');
      expect(b.name, 'Jupiter');
      expect(b.pricePerToken, 0.5);
      expect(b.totalUsdValue, 0.61);
      expect(b.logoUrl, 'https://example.com/jup.png');
    });

    test('zero decimals -> uiBalance equals rawBalance as double (no /1)', () {
      final asset = <String, dynamic>{
        'id': 'somecollectible1111111111111111111111111111',
        'token_info': {'symbol': 'NFT', 'decimals': 0, 'balance': 5},
        'content': {
          'metadata': {'name': 'NFT Asset'},
        },
      };
      final b = TokenBalance.fromHeliusAsset(asset);
      expect(b.decimals, 0);
      expect(b.uiBalance, 5.0);
    });

    test('missing token_info defaults decimals to 0 and balance to 0', () {
      final asset = <String, dynamic>{
        'id': 'mint11111111111111111111111111111111111111',
        'content': {
          'metadata': {'name': 'Unknown', 'symbol': 'UNK'},
        },
      };
      final b = TokenBalance.fromHeliusAsset(asset);
      expect(b.decimals, 0);
      expect(b.rawBalance, 0);
      expect(b.uiBalance, 0.0);
      // Falls back to metadata.symbol.
      expect(b.symbol, 'UNK');
    });

    test('falls back to truncated mint when metadata.name is missing', () {
      const longMint = 'AbCdEf012345678901234567890123456789012345';
      final asset = <String, dynamic>{
        'id': longMint,
        'token_info': {'symbol': 'X', 'decimals': 0, 'balance': 1},
        'content': <String, dynamic>{},
      };
      final b = TokenBalance.fromHeliusAsset(asset);
      // Truncated form: 5/5 ellipsis.
      expect(b.name, contains('…'));
      expect(b.name.length, lessThan(longMint.length));
    });

    test('applies metadata override for the dev USDC mint', () {
      const usdcDev = '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU';
      final asset = <String, dynamic>{
        'id': usdcDev,
        'token_info': {'symbol': 'USDC', 'decimals': 6, 'balance': 1_000_000},
        'content': {
          'metadata': {'name': 'USD Coin'},
        },
      };
      final b = TokenBalance.fromHeliusAsset(asset);
      // Override forces name=USDC (DEV), symbol=USDC_DEV regardless of input.
      expect(b.name, 'USDC (DEV)');
      expect(b.symbol, 'USDC_DEV');
    });
  });

  group('TokenBalance.applyMetadataOverrides', () {
    test('no override, no registry hit → returns same instance', () {
      const t = TokenBalance(
        mint: 'unknown111111111111111111111111111111111111',
        symbol: 'UNK',
        name: 'Unknown',
        decimals: 0,
        rawBalance: 0,
        uiBalance: 0,
      );
      expect(identical(TokenBalance.applyMetadataOverrides(t), t), isTrue);
    });

    test('override mint rewrites name and symbol', () {
      const usdcDev = '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU';
      const t = TokenBalance(
        mint: usdcDev,
        symbol: 'USDC', // stale cached value
        name: 'USD Coin',
        decimals: 6,
        rawBalance: 0,
        uiBalance: 0,
      );
      final updated = TokenBalance.applyMetadataOverrides(t);
      expect(updated.symbol, 'USDC_DEV');
      expect(updated.name, 'USDC (DEV)');
    });

    test('registry-hit with mismatched symbol updates symbol only', () {
      // Find any registry token, force its symbol to be wrong, ensure repair.
      final registryToken = mt.tokenByMint(mt.solMint)!;
      final stale = TokenBalance(
        mint: registryToken.mint,
        symbol: 'WRONG',
        name: 'Solana',
        decimals: registryToken.decimals,
        rawBalance: 0,
        uiBalance: 0,
      );
      final fixed = TokenBalance.applyMetadataOverrides(stale);
      expect(fixed.symbol, registryToken.symbol);
      // Name is left alone in the registry-only branch.
      expect(fixed.name, 'Solana');
    });
  });

  group('TokenBalance.hasKnownZeroValue', () {
    const unpriced = TokenBalance(
      mint: 'DUSTawucrTsGU8hcqRdHDCbuYhCPADMLM2VcCb8VnFnQ',
      symbol: 'DUST',
      name: 'Unpriced Dust',
      decimals: 6,
      rawBalance: 1000000,
      uiBalance: 1.0,
    );

    test('false when the feed carried no price at all', () {
      // Fail-closed: this drives the send/burn auth gate, and an absent price
      // (feed outage, indexer gap, newly-listed-but-valuable mint) must NOT be
      // mistaken for "worthless" — otherwise a valuable token with a missed
      // price lookup could be sent/burned with no step-up auth. Only an
      // affirmative $0 from the feed may skip the gate.
      expect(unpriced.pricePerToken, isNull);
      expect(unpriced.totalUsdValue, isNull);
      expect(unpriced.hasKnownZeroValue, isFalse);
    });

    test('true only when the feed affirmatively prices the holding at \$0', () {
      // We *know* it is worth nothing, so burning/sending dust may skip auth.
      expect(
        unpriced.copyWith(pricePerToken: 0, totalUsdValue: 0).hasKnownZeroValue,
        isTrue,
      );
    });

    test('false once the feed prices the token above zero', () {
      // A real (even tiny) value must go through the gate's normal pricing,
      // not be short-circuited to $0.
      expect(
        unpriced
            .copyWith(pricePerToken: 0.0001, totalUsdValue: 0.0001)
            .hasKnownZeroValue,
        isFalse,
      );
    });

    test('false for a native coin priced at zero / missing', () {
      // Native coins always have real value — a missing (or zero) price there
      // means the lookup failed, so the gate must still fail closed.
      final sol = TokenBalance.nativeSol(lamports: 1_000_000_000);
      expect(sol.pricePerToken, isNull);
      expect(sol.hasKnownZeroValue, isFalse);
      expect(sol.copyWith(totalUsdValue: 0).hasKnownZeroValue, isFalse);
    });
  });
}
