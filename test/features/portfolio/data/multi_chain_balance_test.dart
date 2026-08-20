import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show EvmHolding;
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

void main() {
  group('TokenBalance.fromEvmHolding', () {
    test('maps an ERC-20 holding with a lowercased contract + chain', () {
      final token = TokenBalance.fromEvmHolding(
        const EvmHolding(
          contractAddress: '0xA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48',
          symbol: 'USDC',
          name: 'USD Coin',
          decimals: 6,
          rawBalance: '1500000',
          usdPrice: 1.0,
          priceChange24h: 0.2,
        ),
      );

      expect(token.chain, Chain.ethereum);
      expect(token.isEvm, isTrue);
      expect(token.isNative, isFalse);
      // Contract is lowercased so verification + cache keys are stable.
      expect(token.mint, '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48');
      expect(token.uiBalance, 1.5);
      expect(token.totalUsdValue, closeTo(1.5, 1e-9));
      // Verification is resolved later by the service, not at parse time.
      expect(token.isVerified, isFalse);
    });

    test('treats the native sentinel as native ETH with a default name', () {
      final token = TokenBalance.fromEvmHolding(
        const EvmHolding(
          contractAddress: 'native',
          symbol: 'ETH',
          decimals: 18,
          rawBalance: '500000000000000000', // 0.5 ETH
          usdPrice: 2000.0,
        ),
      );

      expect(token.isNative, isTrue);
      expect(token.mint, TokenBalance.evmNativeSentinel);
      expect(token.name, 'Ethereum');
      expect(token.uiBalance, closeTo(0.5, 1e-9));
      expect(token.totalUsdValue, closeTo(1000.0, 1e-6));
    });

    test(
      'computes uiBalance via BigInt so wei past int64 does not overflow',
      () {
        // 12 ETH = 1.2e19 wei, which exceeds the signed-int64 max (~9.22e18).
        final token = TokenBalance.fromEvmHolding(
          const EvmHolding(
            contractAddress: '0x0000000000000000000000000000000000000abc',
            symbol: 'BIG',
            decimals: 18,
            rawBalance: '12000000000000000000',
          ),
        );

        // uiBalance is exact despite the int rawBalance being clamped.
        expect(token.uiBalance, closeTo(12.0, 1e-9));
        expect(token.rawBalance, greaterThan(0));
      },
    );

    // `/v2/tezos/balances` reuses this same holding shape, so the EVM
    // lower-casing above must not follow it onto Tezos: `KT1…` is Base58Check
    // and case-significant, and a lower-cased one no longer decodes — the FA
    // send path could never forge a `transfer` against it.
    test('keeps a Tezos KT1 contract case-exact', () {
      final token = TokenBalance.fromEvmHolding(
        const EvmHolding(
          contractAddress: 'KT1XnTn74bUtxHfDtBmm2bGZAQfhPbvKWR8o',
          symbol: 'USDt',
          name: 'Tether USD',
          decimals: 6,
          rawBalance: '23252886',
          usdPrice: 0.998489,
        ),
        chain: Chain.tezos,
      );

      expect(token.chain, Chain.tezos);
      expect(token.isNative, isFalse);
      expect(token.mint, 'KT1XnTn74bUtxHfDtBmm2bGZAQfhPbvKWR8o');
      expect(token.uiBalance, closeTo(23.252886, 1e-9));
    });

    test('keeps the FA2 token-id suffix on a multitoken contract', () {
      final token = TokenBalance.fromEvmHolding(
        const EvmHolding(
          contractAddress: 'KT1XnTn74bUtxHfDtBmm2bGZAQfhPbvKWR8o-7',
          symbol: 'M',
          name: 'Multi',
          decimals: 3,
          rawBalance: '42',
        ),
        chain: Chain.tezos,
      );

      expect(token.mint, 'KT1XnTn74bUtxHfDtBmm2bGZAQfhPbvKWR8o-7');
    });

    test('still maps the native sentinel to XTZ on Tezos', () {
      final token = TokenBalance.fromEvmHolding(
        const EvmHolding(
          contractAddress: 'native',
          symbol: 'XTZ',
          name: 'Tezos',
          decimals: 6,
          rawBalance: '1406000',
          usdPrice: 0.2117,
        ),
        chain: Chain.tezos,
      );

      expect(token.isNative, isTrue);
      expect(token.mint, TokenBalance.tezosNativeSentinel);
      expect(token.uiBalance, closeTo(1.406, 1e-9));
    });
  });

  group('mergeTokenBalances chain-keying', () {
    TokenBalance sol(String mint, {required double ui}) => TokenBalance(
      mint: mint,
      symbol: 'S',
      name: 'S',
      decimals: 9,
      rawBalance: (ui * 1e9).round(),
      uiBalance: ui,
      pricePerToken: 2,
      totalUsdValue: ui * 2,
    );

    TokenBalance eth(String mint, {required double ui}) => TokenBalance(
      mint: mint,
      symbol: 'E',
      name: 'E',
      decimals: 18,
      rawBalance: 0,
      uiBalance: ui,
      pricePerToken: 10,
      totalUsdValue: ui * 10,
      chain: Chain.ethereum,
    );

    test('keeps a Solana mint and an Ethereum contract that share a key string '
        'as two distinct rows', () {
      // Contrived identical mint strings on different chains must NOT collapse.
      final merged = SessionPortfolioAggregator.mergeTokenBalances([
        [sol('SHARED', ui: 1)],
        [eth('SHARED', ui: 1)],
      ]);

      expect(merged, hasLength(2));
      expect(merged.map((t) => t.chain).toSet(), {
        Chain.solana,
        Chain.ethereum,
      });
    });

    test('sums same-chain same-mint balances across wallets', () {
      final merged = SessionPortfolioAggregator.mergeTokenBalances([
        [eth('0xabc', ui: 1)],
        [eth('0xabc', ui: 2.5)],
      ]);

      expect(merged, hasLength(1));
      expect(merged.single.uiBalance, closeTo(3.5, 1e-9));
      // totalUsdValue is recomputed from the summed UI balance × price.
      expect(merged.single.totalUsdValue, closeTo(35.0, 1e-6));
    });
  });
}
