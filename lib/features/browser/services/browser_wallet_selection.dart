import '../../../core/models/account.dart';
import '../../../shared/utils/chain.dart';
import '../../wallets/services/profile_lookup_service.dart';
import '../models/browser_models.dart';
import 'tezos_dapp_adapter.dart';

/// A catalog hint chooses a wallet, never grants a website access to it.
Chain? browserSiteChain(Uri url) {
  if (!isBrowserUrl(url)) return null;
  final host = url.host.toLowerCase().replaceAll(RegExp(r'\.+$'), '');
  for (final (chain, sites) in [
    (Chain.solana, browserPopularSites),
    (Chain.ethereum, browserPopularEthereumSites),
    (Chain.tezos, browserPopularTezosSites),
  ]) {
    for (final site in sites) {
      // The catalog uses these app hosts; recognize their parent and sibling
      // hosts too, while retaining a dot boundary to exclude lookalikes.
      final domain = site.uri.host.replaceFirst(
        RegExp(r'^(www|app|stake|gacha)\.'),
        '',
      );
      if (host == domain || host.endsWith('.$domain')) return chain;
    }
  }
  // The catalog's Kamino app host redirects to this domain.
  if (host == 'kamino.com' || host.endsWith('.kamino.com')) return Chain.solana;
  return null;
}

class BrowserWalletSelection {
  const BrowserWalletSelection(this.wallet, {this.account, this.profile})
    : assert((account == null) != (profile == null));

  final WalletInfo wallet;
  final Account? account;
  final ProfileGroup? profile;
}

/// Keeps the current context when it holds the chain. Otherwise prefers the
/// current account, then another device account with a usable signer.
BrowserWalletSelection? selectBrowserSiteWallet({
  required Chain chain,
  required List<Account> accounts,
  Account? currentAccount,
  ProfileGroup? currentProfile,
  String? preferredWalletId,
}) {
  WalletInfo? choose(Iterable<WalletInfo> wallets) {
    final candidates = wallets.where(
      (w) => w.chainEnum == chain && !isViewOnlyPlaceholder(w),
    );
    return candidates.where((w) => w.id == preferredWalletId).firstOrNull ??
        candidates
            .where(
              (w) =>
                  w.canSign &&
                  (chain != Chain.tezos || tezosBrowserCanSign(w.walletType)),
            )
            .firstOrNull ??
        candidates.firstOrNull;
  }

  if (currentProfile != null) {
    final wallet = choose(currentProfile.wallets);
    if (wallet != null) {
      return BrowserWalletSelection(wallet, profile: currentProfile);
    }
  }
  if (currentAccount != null) {
    final wallet = choose(currentAccount.wallets);
    if (wallet != null) {
      return BrowserWalletSelection(wallet, account: currentAccount);
    }
  }
  final candidates = [
    for (final account in accounts)
      if (choose(account.wallets) case final wallet?)
        BrowserWalletSelection(wallet, account: account),
  ];
  return candidates
          .where((s) => s.wallet.id == preferredWalletId)
          .firstOrNull ??
      candidates
          .where(
            (s) =>
                s.wallet.canSign &&
                (chain != Chain.tezos ||
                    tezosBrowserCanSign(s.wallet.walletType)),
          )
          .firstOrNull ??
      candidates.firstOrNull;
}
