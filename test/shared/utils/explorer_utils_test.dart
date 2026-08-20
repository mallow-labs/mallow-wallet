import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mallow_wallet/shared/utils/explorer_utils.dart';

/// Tests target the explorer URL builders that don't depend on the GetIt
/// `PreferencesService`. The `*FromPrefs` variants are excluded because they
/// require service-locator wiring that isn't relevant to the URL logic itself.
///
/// `ENV` is unset in tests and defaults to **production**, so the Solana URLs
/// below carry no cluster parameter. The one case that asserts the
/// `?cluster=devnet` suffix selects the environment itself; the default-side
/// assertion lives with the other unconfigured-build defaults in
/// `test/core/config/environment_defaults_test.dart`.
void main() {
  tearDown(Config.debugOverrides.clear);

  const signature = 'sigABC123';
  const mint = 'So11111111111111111111111111111111111111112';
  const wallet = '8DkNB1234567890123456789012345678901RYfS4';

  group('buildExplorerUrl', () {
    test('routes each known key to its tx URL pattern', () {
      expect(
        buildExplorerUrl(signature, 'solscan'),
        startsWith('https://solscan.io/tx/$signature'),
      );
      expect(
        buildExplorerUrl(signature, 'solana_beach'),
        startsWith('https://solanabeach.io/transaction/$signature'),
      );
      expect(
        buildExplorerUrl(signature, 'solana_explorer'),
        startsWith('https://explorer.solana.com/tx/$signature'),
      );
      expect(
        buildExplorerUrl(signature, 'orb'),
        startsWith('https://orbmarkets.io/tx/$signature'),
      );
    });

    test('unknown key falls back to solscan', () {
      expect(
        buildExplorerUrl(signature, 'not_a_real_explorer'),
        startsWith('https://solscan.io/tx/$signature'),
      );
    });

    test('non-production env appends ?cluster=devnet', () {
      Config.debugOverrides['ENV'] = 'development';

      expect(
        buildExplorerUrl(signature, 'solscan'),
        endsWith('?cluster=devnet'),
      );
    });
  });

  group('buildTokenExplorerUrl', () {
    test('uses /token/ path for solscan and /address/ for the rest', () {
      expect(
        buildTokenExplorerUrl(mint, 'solscan'),
        startsWith('https://solscan.io/token/$mint'),
      );
      expect(
        buildTokenExplorerUrl(mint, 'solana_beach'),
        startsWith('https://solanabeach.io/address/$mint'),
      );
      expect(
        buildTokenExplorerUrl(mint, 'orb'),
        startsWith('https://orbmarkets.io/address/$mint'),
      );
    });

    test('unknown explorer falls back to solscan token path', () {
      expect(
        buildTokenExplorerUrl(mint, 'bogus'),
        startsWith('https://solscan.io/token/$mint'),
      );
    });
  });

  group('buildAccountExplorerUrl', () {
    test('uses /account/ path for solscan and /address/ for the rest', () {
      expect(
        buildAccountExplorerUrl(wallet, 'solscan'),
        startsWith('https://solscan.io/account/$wallet'),
      );
      expect(
        buildAccountExplorerUrl(wallet, 'solana_explorer'),
        startsWith('https://explorer.solana.com/address/$wallet'),
      );
    });
  });

  group('buildTokenExplorerUrlForChain', () {
    test('Tezos with <contract>-<tokenId> uses tzkt /tokens/ form', () {
      expect(
        buildTokenExplorerUrlForChain('KT1abc-42', Chain.tezos),
        'https://tzkt.io/KT1abc/tokens/42',
      );
    });

    test('Tezos without token id uses tzkt direct contract', () {
      expect(
        buildTokenExplorerUrlForChain('KT1abc', Chain.tezos),
        'https://tzkt.io/KT1abc',
      );
    });

    test('Ethereum NFT (<contract>-<tokenId>) uses etherscan /nft/ form and '
        'stays on mainnet (mallow artworks are mainnet)', () {
      expect(
        buildTokenExplorerUrlForChain(
          '0xabcdef0123456789abcdef0123456789abcdef01-7',
          Chain.ethereum,
          ethExplorerKey: 'etherscan',
        ),
        'https://etherscan.io/nft/0xabcdef0123456789abcdef0123456789abcdef01/7',
      );
    });

    test('Ethereum bare contract (fungible) uses /token/ on etherscan mainnet '
        '(Ethereum is mainnet-only)', () {
      expect(
        buildTokenExplorerUrlForChain(
          '0xabcdef0123456789abcdef0123456789abcdef01',
          Chain.ethereum,
          ethExplorerKey: 'etherscan',
        ),
        'https://etherscan.io/token/0xabcdef0123456789abcdef0123456789abcdef01',
      );
    });

    test('Blockscout NFT uses /token/<contract>/instance/<id> on mainnet', () {
      expect(
        buildTokenExplorerUrlForChain(
          '0xabcdef0123456789abcdef0123456789abcdef01-7',
          Chain.ethereum,
          ethExplorerKey: 'blockscout',
        ),
        'https://eth.blockscout.com/token/'
        '0xabcdef0123456789abcdef0123456789abcdef01/instance/7',
      );
    });

    test('Blockscout fungible token uses /token/ on mainnet', () {
      expect(
        buildTokenExplorerUrlForChain(
          '0xabcdef0123456789abcdef0123456789abcdef01',
          Chain.ethereum,
          ethExplorerKey: 'blockscout',
        ),
        'https://eth.blockscout.com/token/'
        '0xabcdef0123456789abcdef0123456789abcdef01',
      );
    });
  });

  group('buildTxExplorerUrlForChain', () {
    test('Ethereum routes to etherscan /tx/ on mainnet', () {
      expect(
        buildTxExplorerUrlForChain(
          '0xTXHASH',
          Chain.ethereum,
          ethExplorerKey: 'etherscan',
        ),
        'https://etherscan.io/tx/0xTXHASH',
      );
    });

    test('Ethereum honors the Blockscout preference', () {
      expect(
        buildTxExplorerUrlForChain(
          '0xTXHASH',
          Chain.ethereum,
          ethExplorerKey: 'blockscout',
        ),
        'https://eth.blockscout.com/tx/0xTXHASH',
      );
    });

    test('Tezos routes to tzkt by operation hash', () {
      expect(
        buildTxExplorerUrlForChain('ooOPHASH', Chain.tezos),
        'https://tzkt.io/ooOPHASH',
      );
    });
  });

  group('buildAccountExplorerUrlForChain', () {
    test('Tezos routes to tzkt root', () {
      expect(
        buildAccountExplorerUrlForChain('tz1abc', Chain.tezos),
        'https://tzkt.io/tz1abc',
      );
    });

    test('Ethereum routes to etherscan /address/ on mainnet', () {
      expect(
        buildAccountExplorerUrlForChain(
          '0xdead',
          Chain.ethereum,
          ethExplorerKey: 'etherscan',
        ),
        'https://etherscan.io/address/0xdead',
      );
    });

    test('Ethereum honors the Blockscout preference', () {
      expect(
        buildAccountExplorerUrlForChain(
          '0xdead',
          Chain.ethereum,
          ethExplorerKey: 'blockscout',
        ),
        'https://eth.blockscout.com/address/0xdead',
      );
    });
  });

  group('explorerDisplayName', () {
    test('returns the canonical display name for each known key', () {
      expect(explorerDisplayName('solscan'), 'Solscan');
      expect(explorerDisplayName('solana_beach'), 'Solana Beach');
      expect(explorerDisplayName('solana_explorer'), 'Solana Explorer');
      expect(explorerDisplayName('orb'), 'Orb');
    });

    test('unknown key falls back to "Solscan" (matches URL fallback)', () {
      expect(explorerDisplayName('not_a_real_explorer'), 'Solscan');
    });
  });
}
