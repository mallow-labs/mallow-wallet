import '../../../core/models/account.dart';
import '../../../shared/utils/chain.dart' show apiOwnerAddress;

// ---------------------------------------------------------------------------
// Profile wallet-linking selection
//
// Pure view models + rules behind the "Select wallets" step of the Create/Edit
// Profile wizard. Deliberately Flutter-free so the eligibility and diff rules —
// the parts that decide what gets linked and unlinked on the backend — are unit
// testable without pumping a widget.
// ---------------------------------------------------------------------------

/// One selectable wallet row inside an account card.
///
/// Activity is resolved for every chain: artwork counts come from the
/// multi-chain v2 portfolio read, and balances route per chain to the Solana,
/// EVM, or Tezos token service.
class LinkableWallet {
  const LinkableWallet({
    required this.wallet,
    required this.linkedToProfile,
    this.artworkCount,
    this.balanceUsd,
  });

  final WalletInfo wallet;

  /// True when this wallet is already linked to the profile being edited, so it
  /// starts selected and unselecting it means "unlink on save".
  final bool linkedToProfile;

  /// Null while loading; set (possibly 0) once enriched.
  final int? artworkCount;
  final double? balanceUsd;

  String get id => wallet.id;

  String get address => wallet.address;

  /// Provenance icon for the row — hardware / Google / Apple, or null for a
  /// plain HD or imported wallet.
  WalletBadge? get badge => wallet.badge;

  bool get isEnriched => artworkCount != null && balanceUsd != null;

  bool get hasActivity =>
      (artworkCount != null && artworkCount! > 0) ||
      (balanceUsd != null && balanceUsd! > 0);

  LinkableWallet copyWith({int? artworkCount, double? balanceUsd}) =>
      LinkableWallet(
        wallet: wallet,
        linkedToProfile: linkedToProfile,
        artworkCount: artworkCount ?? this.artworkCount,
        balanceUsd: balanceUsd ?? this.balanceUsd,
      );
}

/// One account card: a device account with the wallets that may back a profile.
class LinkableAccount {
  const LinkableAccount({required this.account, required this.wallets});

  final Account account;
  final List<LinkableWallet> wallets;

  String get name => account.name;

  String get avatarSeed => account.avatarSeed;

  /// Aggregate artwork count across every chain, or null while loading.
  int? get artworkCount {
    if (wallets.any((w) => w.artworkCount == null)) return null;
    return wallets.fold<int>(0, (sum, w) => sum + (w.artworkCount ?? 0));
  }

  /// Aggregate USD across every chain, or null while loading.
  double? get balanceUsd {
    if (wallets.any((w) => w.balanceUsd == null)) return null;
    return wallets.fold<double>(0.0, (sum, w) => sum + (w.balanceUsd ?? 0));
  }

  bool get isEnriched => wallets.every((w) => w.isEnriched);

  bool get hasActivity => wallets.any((w) => w.hasActivity);

  LinkableAccount withWallets(List<LinkableWallet> next) =>
      LinkableAccount(account: account, wallets: next);
}

/// Build the account cards the "Select wallets" step renders.
///
/// A wallet is offered when it is **signable** ([WalletInfo.canSign] — view-only
/// wallets cannot sign the link challenge) AND is not linked to a *different*
/// named profile. Wallets linked to [currentProfileId] are kept and flagged
/// [LinkableWallet.linkedToProfile] so the edit flow can start them selected.
///
/// [profileIdByAddress] comes from
/// [ProfileLookupService.namedProfileIdForAddresses], which already excludes
/// anonymous logins — a wallet that has logged in but never claimed a profile
/// stays eligible.
///
/// Accounts left with no wallet are dropped entirely.
List<LinkableAccount> resolveLinkable({
  required List<Account> accounts,
  required Map<String, String> profileIdByAddress,
  required String? currentProfileId,
}) {
  final result = <LinkableAccount>[];
  for (final account in accounts) {
    final wallets = <LinkableWallet>[];
    for (final wallet in account.wallets) {
      if (!wallet.canSign) continue;
      // [profileIdByAddress] is keyed on the normalized address (EVM lowercased)
      // — match on the same form so a checksummed Ethereum wallet resolves its
      // owning profile instead of looking unlinked.
      final owner = profileIdByAddress[apiOwnerAddress(wallet.address)];
      // Spoken for by someone else — never offer it.
      if (owner != null && owner != currentProfileId) continue;
      wallets.add(
        LinkableWallet(
          wallet: wallet,
          linkedToProfile: owner != null && owner == currentProfileId,
        ),
      );
    }
    if (wallets.isNotEmpty) {
      result.add(LinkableAccount(account: account, wallets: wallets));
    }
  }
  return result;
}

/// The link/unlink work implied by a selection, keyed by wallet address.
class WalletDiff {
  const WalletDiff({required this.toLink, required this.toUnlink});

  final Set<String> toLink;
  final Set<String> toUnlink;

  bool get isEmpty => toLink.isEmpty && toUnlink.isEmpty;
}

/// Diff [selected] against the wallets already linked to the profile.
///
/// [locked] addresses are never unlinked regardless of selection — the profile's
/// signing wallet lives there, and removing it would invalidate the session
/// mid-save (and could empty the profile entirely).
WalletDiff diffSelection({
  required Set<String> currentlyLinked,
  required Set<String> selected,
  Set<String> locked = const {},
}) => WalletDiff(
  toLink: selected.difference(currentlyLinked),
  toUnlink: currentlyLinked.difference(selected).difference(locked),
);
