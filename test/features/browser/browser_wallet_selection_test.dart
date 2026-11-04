import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/features/browser/models/browser_models.dart';
import 'package:mallow_wallet/features/browser/services/browser_wallet_selection.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

const solana = WalletInfo(
  id: 'solana',
  address: 'solana-address',
  name: 'Solana',
  walletType: WalletType.hd,
  chain: 'solana',
  accountId: 'main',
);
const ethereum = WalletInfo(
  id: 'ethereum',
  address: 'ethereum-address',
  name: 'Ethereum',
  walletType: WalletType.hd,
  chain: 'ethereum',
  accountId: 'main',
);
const tezos = WalletInfo(
  id: 'tezos',
  address: 'tezos-address',
  name: 'Tezos',
  walletType: WalletType.hd,
  chain: 'tezos',
  accountId: 'main',
);
const mainAccount = Account(
  id: 'main',
  name: 'Main',
  wallets: [solana, ethereum, tezos],
);

void main() {
  group('site chain hints', () {
    for (final (chain, sites) in [
      (Chain.solana, browserPopularSites),
      (Chain.ethereum, browserPopularEthereumSites),
      (Chain.tezos, browserPopularTezosSites),
    ]) {
      test('recognizes every ${chain.name} catalog site', () {
        for (final site in sites) {
          expect(browserSiteChain(site.uri), chain, reason: site.name);
        }
      });
    }
    test('recognizes parent hosts, subdomains and the Kamino redirect', () {
      for (final host in [
        'uniswap.org',
        'app.uniswap.org',
        'www.uniswap.org',
      ]) {
        expect(browserSiteChain(Uri.https(host, '/swap')), Chain.ethereum);
      }
      expect(browserSiteChain(Uri.https('kamino.com', '/')), Chain.solana);
      expect(browserSiteChain(Uri.https('OBJKT.COM', '/')), Chain.tezos);
    });
    test('unknown sites, lookalikes and unsafe URLs have no hint', () {
      for (final url in [
        'https://example.com/?url=https://jup.ag',
        'https://jup.ag.example.com',
        'https://fakejup.ag',
        'https://objkt.com.evil.example',
        'http://jup.ag',
        'https://user:password@jup.ag',
      ]) {
        expect(browserSiteChain(Uri.parse(url)), isNull, reason: url);
      }
    });
  });

  group('wallet selection', () {
    for (final (chain, wallet) in [
      (Chain.solana, solana),
      (Chain.ethereum, ethereum),
      (Chain.tezos, tezos),
    ]) {
      test('prefers the current account for ${chain.name}', () {
        final other = mainAccount.copyWith(id: 'other');
        final selection = selectBrowserSiteWallet(
          chain: chain,
          accounts: [other, mainAccount],
          currentAccount: mainAccount,
        );
        expect(selection?.wallet, wallet);
        expect(selection?.account, mainAccount);
      });
    }
    test('falls back to another account when the chain is missing', () {
      final current = mainAccount.copyWith(wallets: [solana]);
      final selection = selectBrowserSiteWallet(
        chain: Chain.tezos,
        accounts: [current, mainAccount],
        currentAccount: current,
      );
      expect(selection?.wallet, tezos);
      expect(selection?.account, mainAccount);
    });
    test('keeps a current view-only wallet ahead of another account', () {
      final watch = ethereum.copyWith(
        id: 'watch',
        walletType: WalletType.viewOnly,
      );
      final current = mainAccount.copyWith(wallets: [solana, watch]);
      final selection = selectBrowserSiteWallet(
        chain: Chain.ethereum,
        accounts: [mainAccount],
        currentAccount: current,
      );
      expect(selection?.wallet, watch);
      expect(selection?.account, current);
    });
    test('prefers a signer over a watcher when choosing another account', () {
      final watcher = mainAccount.copyWith(
        id: 'watch',
        wallets: [tezos.copyWith(walletType: WalletType.viewOnly)],
      );
      expect(
        selectBrowserSiteWallet(
          chain: Chain.tezos,
          accounts: [watcher, mainAccount],
        )?.account,
        mainAccount,
      );
    });
    test('preserves a remembered wallet among multiple wallets on a chain', () {
      final remembered = solana.copyWith(id: 'legacy');
      final account = mainAccount.copyWith(wallets: [solana, remembered]);
      expect(
        selectBrowserSiteWallet(
          chain: Chain.solana,
          accounts: [account],
          currentAccount: account,
          preferredWalletId: remembered.id,
        )?.wallet,
        remembered,
      );
    });
    test('keeps the current profile when it holds the chain', () {
      const profile = ProfileGroup(
        wallets: [tezos],
        isAnon: false,
        userId: 'p',
      );
      final selection = selectBrowserSiteWallet(
        chain: Chain.tezos,
        accounts: [mainAccount],
        currentAccount: mainAccount,
        currentProfile: profile,
      );
      expect(selection?.profile, profile);
      expect(selection?.account, isNull);
    });
    test('does not select linked addresses that are not on the device', () {
      final placeholder = tezos.copyWith(id: 'view-only:linked');
      final account = mainAccount.copyWith(wallets: [solana]);
      final profile = ProfileGroup(
        wallets: [placeholder],
        isAnon: false,
        userId: 'p',
      );
      expect(
        selectBrowserSiteWallet(
          chain: Chain.tezos,
          accounts: [account],
          currentAccount: account,
          currentProfile: profile,
        ),
        isNull,
      );
    });
    test('returns no selection when no account holds the chain', () {
      final account = mainAccount.copyWith(wallets: [solana]);
      expect(
        selectBrowserSiteWallet(
          chain: Chain.ethereum,
          accounts: [account],
          currentAccount: account,
        ),
        isNull,
      );
    });
  });
}
