import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/portfolio/models/jupiter_token_info.dart';

/// Pins the Jupiter v2 search-API parsing that backs token detail / swap
/// screens. The fields here drive prices, 24h volume, and the security audit
/// surface (mint/freeze authority, dev holdings), so the null-coalescing and
/// numeric coercion rules must hold against partial API payloads.
void main() {
  group('fromApiResponse — identity', () {
    test('prefers `id`, falls back to `mint`, then empty string', () {
      expect(
        JupiterTokenInfo.fromApiResponse({'id': 'AAA', 'mint': 'BBB'}).mint,
        'AAA',
      );
      expect(JupiterTokenInfo.fromApiResponse({'mint': 'BBB'}).mint, 'BBB');
      expect(JupiterTokenInfo.fromApiResponse(<String, dynamic>{}).mint, '');
    });
  });

  group('fromApiResponse — 24h volume combination', () {
    test('sums buy and sell volume', () {
      final info = JupiterTokenInfo.fromApiResponse({
        'id': 'X',
        'stats24h': {'buyVolume': 100.0, 'sellVolume': 250.0},
      });
      expect(info.volume24h, 350.0);
    });

    test('uses the present side when only one of buy/sell is provided', () {
      expect(
        JupiterTokenInfo.fromApiResponse({
          'id': 'X',
          'stats24h': {'buyVolume': 100.0},
        }).volume24h,
        100.0,
      );
      expect(
        JupiterTokenInfo.fromApiResponse({
          'id': 'X',
          'stats24h': {'sellVolume': 75.0},
        }).volume24h,
        75.0,
      );
    });

    test('is null when neither buy nor sell volume is present', () {
      // Distinguishes "no data" (null) from a real zero so the UI can hide the
      // stat rather than render $0 volume.
      expect(
        JupiterTokenInfo.fromApiResponse({
          'id': 'X',
          'stats24h': {'priceChange': 1.0},
        }).volume24h,
        isNull,
      );
      expect(JupiterTokenInfo.fromApiResponse({'id': 'X'}).volume24h, isNull);
    });

    test('treats an explicit zero side as data, not absence', () {
      expect(
        JupiterTokenInfo.fromApiResponse({
          'id': 'X',
          'stats24h': {'buyVolume': 0, 'sellVolume': 0},
        }).volume24h,
        0.0,
      );
    });
  });

  group('fromApiResponse — numeric coercion', () {
    test('coerces integer JSON numbers to double price fields', () {
      final info = JupiterTokenInfo.fromApiResponse({
        'id': 'X',
        'usdPrice': 5, // int in JSON
        'liquidity': 1000,
        'mcap': 2000,
      });
      expect(info.price, 5.0);
      expect(info.liquidity, 1000.0);
      expect(info.marketCap, 2000.0);
    });

    test('coerces numbers to int for count fields', () {
      final info = JupiterTokenInfo.fromApiResponse({
        'id': 'X',
        'decimals': 6,
        'holderCount': 1234.0, // double in JSON
        'stats24h': {'numTraders': 42},
      });
      expect(info.decimals, 6);
      expect(info.holders, 1234);
      expect(info.uniqueTraders24h, 42);
    });
  });

  group('fromApiResponse — nested objects and security fields', () {
    test('reads audit dev/top-holder percentages', () {
      final info = JupiterTokenInfo.fromApiResponse({
        'id': 'X',
        'dev': 'DevWallet',
        'audit': {'devBalancePercentage': 12.5, 'topHoldersPercentage': 60.0},
      });
      expect(info.devAddress, 'DevWallet');
      expect(info.devHoldingPercent, 12.5);
      expect(info.topHoldersPercent, 60.0);
    });

    test('maps authority fields (null = frozen/burned) and mutability', () {
      final info = JupiterTokenInfo.fromApiResponse({
        'id': 'X',
        'mintAuthority': 'MA',
        'freezeAuthority': null,
        'isMutable': false,
      });
      expect(info.mintAuthority, 'MA');
      expect(info.freezeAuthority, isNull);
      expect(info.isMutable, false);
    });

    test('tolerates missing stats24h and audit objects', () {
      final info = JupiterTokenInfo.fromApiResponse({'id': 'X'});
      expect(info.priceChange24h, isNull);
      expect(info.uniqueTraders24h, isNull);
      expect(info.devHoldingPercent, isNull);
      expect(info.topHoldersPercent, isNull);
    });

    test('maps core metadata and icon→logoUri', () {
      final info = JupiterTokenInfo.fromApiResponse({
        'id': 'Mint1',
        'name': 'Token',
        'symbol': 'TKN',
        'icon': 'https://x.com/i.png',
      });
      expect(info.mint, 'Mint1');
      expect(info.name, 'Token');
      expect(info.symbol, 'TKN');
      expect(info.logoUri, 'https://x.com/i.png');
    });
  });

  group('fromEvmTokenInfo — EVM field names differ from Jupiter', () {
    // The v2 backend `EvmTokenInfo` payload uses its own camelCase names
    // (address/priceUsd/marketCapUsd/logoUrl/…), NOT Jupiter's
    // (id/usdPrice/mcap/icon/stats24h.*). Reading it with `fromApiResponse`
    // would silently null almost every field, so these pin the EVM mapping.
    test('maps identity, metadata, and market fields', () {
      final info = JupiterTokenInfo.fromEvmTokenInfo({
        'address': '0xabc',
        'name': 'USD Coin',
        'symbol': 'USDC',
        'logoUrl': 'https://x.com/usdc.png',
        'decimals': 6,
        'priceUsd': 1.0,
        'priceChange24h': -0.5,
        'marketCapUsd': 1000.0,
        'totalVolume24hUsd': 2000.0,
        'circulatingSupply': 500.0,
        'totalSupply': 800.0,
      });
      expect(info.mint, '0xabc');
      expect(info.name, 'USD Coin');
      expect(info.symbol, 'USDC');
      expect(info.logoUri, 'https://x.com/usdc.png');
      expect(info.decimals, 6);
      expect(info.price, 1.0);
      expect(info.priceChange24h, -0.5);
      expect(info.marketCap, 1000.0);
      expect(info.volume24h, 2000.0);
      expect(info.circSupply, 500.0);
      expect(info.totalSupply, 800.0);
    });

    test('coerces integer JSON numbers to doubles', () {
      final info = JupiterTokenInfo.fromEvmTokenInfo({
        'address': '0xabc',
        'priceUsd': 3, // int in JSON
        'marketCapUsd': 1000,
      });
      expect(info.price, 3.0);
      expect(info.marketCap, 1000.0);
    });

    test('does NOT read Jupiter-shaped keys (would null out under EVM)', () {
      // A Jupiter-style payload fed to the EVM mapper yields no usable fields —
      // proving the two shapes are genuinely distinct and must not be crossed.
      final info = JupiterTokenInfo.fromEvmTokenInfo({
        'id': '0xabc',
        'usdPrice': 1.0,
        'mcap': 1000.0,
        'icon': 'https://x.com/i.png',
      });
      expect(info.mint, ''); // `address` absent
      expect(info.price, isNull); // `priceUsd` absent
      expect(info.marketCap, isNull); // `marketCapUsd` absent
      expect(info.logoUri, isNull); // `logoUrl` absent
    });

    test('leaves Solana-only audit/authority fields null', () {
      final info = JupiterTokenInfo.fromEvmTokenInfo({
        'address': '0xabc',
        'priceUsd': 1.0,
      });
      expect(info.mintAuthority, isNull);
      expect(info.freezeAuthority, isNull);
      expect(info.devHoldingPercent, isNull);
      expect(info.topHoldersPercent, isNull);
      expect(info.holders, isNull);
    });
  });
}
