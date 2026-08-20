import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/token_image_utils.dart';

void main() {
  group('localTokenImagePath', () {
    test('returns SOL asset for native SOL mint', () {
      expect(
        localTokenImagePath('So11111111111111111111111111111111111111112'),
        'assets/images/tokens/sol.webp',
      );
    });

    test('returns USDC asset for canonical USDC mint', () {
      expect(
        localTokenImagePath('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'),
        'assets/images/tokens/usdc.webp',
      );
    });

    test('returns USDC asset for the devnet USDC variant', () {
      // Devnet uses a different mint but the UI presents it as USDC.
      expect(
        localTokenImagePath('4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU'),
        'assets/images/tokens/usdc.webp',
      );
    });

    test('returns null for unknown mints', () {
      expect(
        localTokenImagePath('UNKNOWNMINTaddress00000000000000000000000000'),
        isNull,
      );
    });

    test('returns null for empty string', () {
      expect(localTokenImagePath(''), isNull);
    });

    test('is case-sensitive — Solana base58 addresses are exact', () {
      // Lowercase form of the real mint should NOT match. Catches accidental
      // lower/uppercase normalization regressions.
      expect(
        localTokenImagePath('so11111111111111111111111111111111111111112'),
        isNull,
      );
    });
  });

  group('chainSymbolSvgAsset', () {
    // Tezos listings arrive from objkt with the currency as either the `xtz`
    // sentinel or the FA contract of a wrapped token (oXTZ) — never a Solana
    // mint. Without these the listing sheets fall through to the symbol-text
    // chip instead of the Tezos mark.
    test('maps the Tezos currency mints to the Tezos mark', () {
      expect(chainSymbolSvgAsset(mint: 'xtz'), 'assets/icons/tezos.svg');
      expect(
        chainSymbolSvgAsset(mint: 'KT1TjnZYs5CGLbmV6yuW169P8Pnr9BiVwwjz'),
        'assets/icons/tezos.svg',
      );
    });

    test('maps XTZ / oXTZ symbols to the Tezos mark', () {
      expect(chainSymbolSvgAsset(symbol: 'XTZ'), 'assets/icons/tezos.svg');
      expect(chainSymbolSvgAsset(symbol: 'oXTZ'), 'assets/icons/tezos.svg');
    });

    // Wrapped ETH is 1:1 with ETH and shares its brand mark — an Ethereum
    // listing denominated in wETH must not fall back to the Solana default.
    test('maps ETH / wETH symbols to the Ethereum mark', () {
      expect(chainSymbolSvgAsset(symbol: 'ETH'), 'assets/icons/ethereum.svg');
      expect(chainSymbolSvgAsset(symbol: 'wETH'), 'assets/icons/ethereum.svg');
    });

    test('returns null for non-chain tokens', () {
      expect(chainSymbolSvgAsset(symbol: 'USDC'), isNull);
    });
  });
}
