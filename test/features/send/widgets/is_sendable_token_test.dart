import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/send/widgets/send_token_select_step.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

/// The picker's chain filter. It decides what the user is *offered*, so a wrong
/// answer either hides an asset the wallet can move or advertises one it can't.
void main() {
  const kt1 = 'KT1XnTn74bUtxHfDtBmm2bGZAQfhPbvKWR8o';

  TokenBalance tezos({required String mint, bool isNative = false}) =>
      TokenBalance(
        mint: mint,
        symbol: 'T',
        name: 'T',
        decimals: 6,
        rawBalance: 1,
        uiBalance: 1,
        isNative: isNative,
        chain: Chain.tezos,
      );

  group('isSendableToken', () {
    test('native XTZ is sendable', () {
      expect(
        isSendableToken(
          tezos(mint: TokenBalance.tezosNativeSentinel, isNative: true),
        ),
        isTrue,
      );
    });

    test('an FA holding with a decodable KT1 is sendable', () {
      expect(isSendableToken(tezos(mint: kt1)), isTrue);
      // FA2 multitoken: `{contract}-{tokenId}`.
      expect(isSendableToken(tezos(mint: '$kt1-7')), isTrue);
    });

    test('an FA holding whose KT1 no longer decodes is not offered', () {
      // A row cached before the balances mapper stopped lower-casing Tezos
      // contracts. The case cannot be recovered from the string, so the row
      // stays unsendable until a network refresh rewrites it — hidden here
      // rather than shown and then failing at review, after the user has
      // picked a recipient and an amount.
      expect(isSendableToken(tezos(mint: kt1.toLowerCase())), isFalse);
    });

    test('every Solana and Ethereum holding stays sendable', () {
      expect(
        isSendableToken(
          const TokenBalance(
            mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
            symbol: 'USDC',
            name: 'USD Coin',
            decimals: 6,
            rawBalance: 1,
            uiBalance: 1,
          ),
        ),
        isTrue,
      );
      expect(
        isSendableToken(
          const TokenBalance(
            mint: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
            symbol: 'USDC',
            name: 'USD Coin',
            decimals: 6,
            rawBalance: 1,
            uiBalance: 1,
            chain: Chain.ethereum,
          ),
        ),
        isTrue,
      );
    });
  });
}
