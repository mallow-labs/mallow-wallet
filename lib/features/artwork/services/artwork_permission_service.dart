import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' show ListingType;

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/network/das_api_service.dart';
import '../../../core/network/ethereum_rpc_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/utils/chain.dart'
    show Chain, apiOwnerAddress, isEthereumAddress, isEthereumAsset;
import '../../sale/services/direct_proceeds.dart' show resolveOnChainRoyalties;
import '../../wallets/services/profile_lookup_service.dart';
import '../models/on_chain_asset.dart';

/// The value [ArtworkPermissionService.checkPermissions] returns when the
/// on-chain read did NOT complete (DAS / RPC / parse failure) — as opposed to
/// completing and finding no permissions.
///
/// Every permission flag is false, exactly like [ArtworkPermissions.none], so
/// callers that only read the flags (context menu, chooser gate, options
/// sheets) behave identically and keep failing closed. The subtype exists for
/// the one caller that must NOT treat "we never found out" as an answer: the
/// Details tab's Royalties row, which would otherwise state a confident `0%`
/// for a Core / pNFT artwork whose royalty lives in an on-chain plugin the
/// failed read never saw. See [ArtworkPermissionsResolution.resolveFailed].
class UnresolvedArtworkPermissions extends ArtworkPermissions {
  const UnresolvedArtworkPermissions()
    : super(canTransfer: false, canEdit: false, canBurn: false, canList: false);
}

extension ArtworkPermissionsResolution on ArtworkPermissions {
  /// True when this object is the [UnresolvedArtworkPermissions] marker, i.e.
  /// the on-chain read threw. `false` for [ArtworkPermissions.none], which is
  /// a real answer ("resolved; no permissions").
  bool get resolveFailed => this is UnresolvedArtworkPermissions;
}

/// Computes on-chain permissions (canTransfer, canEdit, canBurn) for artworks.
///
/// Fetches asset data from the Helius DAS API and applies the same permission
/// logic used by the mallow web app.
@lazySingleton
class ArtworkPermissionService {
  ArtworkPermissionService(
    this._dasApi,
    this._walletManager,
    this._walletRepo,
    this._profileLookup,
    this._ethRpc,
  );

  final DasApiService _dasApi;
  final WalletManager _walletManager;
  final WalletRepository _walletRepo;
  final ProfileLookupService _profileLookup;
  final EthereumRpcService _ethRpc;

  /// Fetch on-chain data and compute permissions for [mintAccount].
  ///
  /// Returns an all-false [UnresolvedArtworkPermissions] on any error
  /// (network, parsing, etc.) to fail gracefully — the menu just hides the
  /// permission-gated items, same as [ArtworkPermissions.none]. The marker
  /// subtype lets the Details tab tell a failed read from a resolved one; see
  /// [ArtworkPermissionsResolution.resolveFailed].
  /// [sessionAddresses] widens the owner / update-authority arms of the
  /// signing gates (transfer / burn / list / edit) beyond the single active
  /// wallet to every wallet in the current session (Profile / Account), so an
  /// artwork held by a non-active session wallet still surfaces its owner
  /// actions — the detail screen auto-switches the signer to the holder before
  /// signing. Delegate arms stay active-only (a delegate acts AS the active
  /// wallet). The active address is always in scope, so the default (empty)
  /// preserves the historical active-wallet-only behaviour for callers that
  /// don't wire the auto-switch.
  ///
  /// [listingType] / [inGroupedSale] carry the indexer's listing state (see
  /// [isListedForSale]). Callers that know it MUST pass it: it is the only
  /// signal mobile has for listings that neither escrow nor freeze the asset,
  /// and without it transfer/burn are offered on a listed artwork. Absent (the
  /// default) means "caller has no listing info" and the on-chain arms decide
  /// alone — historical behaviour, kept for the surfaces that only know a mint.
  Future<ArtworkPermissions> checkPermissions(
    String mintAccount, {
    Set<String> sessionAddresses = const {},
    ListingType? listingType,
    bool inGroupedSale = false,
  }) async {
    final listed = isListedForSale(
      listingType: listingType,
      inGroupedSale: inGroupedSale,
    );
    // EVM assets have no DAS entry — resolve transfer permission from on-chain
    // ownership (ERC-721 ownerOf / ERC-1155 balanceOf) instead.
    if (isEthereumAsset(mintAccount)) {
      return _checkEvmPermissions(
        mintAccount,
        sessionAddresses: sessionAddresses,
        listed: listed,
      );
    }
    try {
      final userAddress = await _walletManager.getAddress();
      final owned = await ownedAddresses();
      final asset = await _dasApi.getAsset(mintAccount);

      // For Core assets in a collection, fetch collection for delegate checks
      DigitalAsset? collectionAsset;
      if (asset.tokenStandard == TokenStandard.core &&
          asset.collectionKey != null) {
        try {
          collectionAsset = await _dasApi.getAsset(asset.collectionKey!);
        } catch (_) {
          // Collection fetch failure is non-fatal; collection-level delegates
          // just won't be checked
        }
      }

      // Download is offered when the artwork is owned or created by any wallet
      // the user controls — not just the active one. `updateAuthority` is the
      // app's "creator" signal (mirrors `_canEdit`). Solana addresses are
      // case-significant base58, so match exactly.
      final ownsOrCreated =
          (asset.owner != null && owned.contains(asset.owner)) ||
          (asset.updateAuthority != null &&
              owned.contains(asset.updateAuthority));

      // Hide/unhide authorizes only against the LOGIN wallet's profile — a
      // strictly narrower set than the download gate above (see
      // [loginProfileAddresses]). Mirror the backend's owner/creator arms.
      final loginAddresses = loginProfileAddresses(userAddress);
      final canHide =
          (asset.owner != null && loginAddresses.contains(asset.owner)) ||
          (asset.updateAuthority != null &&
              loginAddresses.contains(asset.updateAuthority));

      // Owner / update-authority arms of the signing gates accept any wallet in
      // the current session; the active wallet is in scope too, so an empty
      // [sessionAddresses] collapses to the historical active-only behaviour.
      // The active wallet passes through `scopedToSession` first: a Profile
      // session must not offer signing actions via a wallet it doesn't link
      // (unlike the download gate above, which spans the whole device).
      final signers = <String>{
        ?sl<SessionManager>().scopedToSession(userAddress),
        ...sessionAddresses,
      }..removeWhere((a) => a.isEmpty);

      return ArtworkPermissions(
        // A live listing blocks BOTH transfer and burn, whatever the on-chain
        // mechanic — see [isListedForSale]. The on-chain arms below can only
        // see a freeze, so the indexer term is what stops a transfer on a
        // delegate-only / non-custodial / external-market listing.
        canTransfer:
            !listed &&
            _canTransfer(asset, signers, userAddress, collectionAsset),
        // Edit widens to the full session like transfer/burn/list: when a
        // non-active session wallet is the `updateAuthority`, the edit screen
        // (and, belt-and-suspenders, the mint bloc) auto-switch the signer to
        // that wallet via `ensureSigner` before building the edit tx.
        canEdit: _canEdit(asset, signers),
        canBurn:
            !listed && _canBurn(asset, signers, userAddress, collectionAsset),
        canList: _canList(asset, signers, userAddress, collectionAsset),
        canDownload: ownsOrCreated,
        canHide: canHide,
        // Not a permission — the Details tab's on-chain royalty fallback,
        // resolved off the reads above rather than a second DAS round-trip.
        // See [ArtworkPermissions.onChainRoyaltyBps].
        onChainRoyaltyBps: resolveOnChainRoyalties(
          asset,
          collection: collectionAsset,
        ).royaltyBps,
      );
    } catch (_) {
      return const UnresolvedArtworkPermissions();
    }
  }

  /// Transfer permission for an EVM asset (`<contract>-<tokenId>`): an Ethereum
  /// wallet in the current session must be the on-chain owner (ERC-721) or hold
  /// a positive balance (ERC-1155). [sessionAddresses] widens this beyond the
  /// active Ethereum wallet to every session ETH wallet (the active one is
  /// added explicitly); the detail screen switches the signer to the holder.
  /// Edit/burn/list are not supported for EVM standards.
  ///
  /// [listed] applies the same indexer listing gate as the Solana arm: an
  /// OpenSea / objkt listing is recorded against the artwork
  /// (`ethereumHelper.applyEthereumNftListingUpdate` sets `listingType =
  /// buy-now`) but leaves the token unescrowed and unfrozen, so ownership alone
  /// would happily offer a transfer that silently orphans the listing.
  Future<ArtworkPermissions> _checkEvmPermissions(
    String mintAccount, {
    Set<String> sessionAddresses = const {},
    bool listed = false,
  }) async {
    try {
      // The session's own ETH wallet, NOT `activeWalletForChain` — that answers
      // from the active account, whose auto-derived ETH sibling a Profile
      // session need not link. Granting transfer through it would offer to move
      // an asset with a wallet outside the profile.
      final active = sl<SessionManager>().sessionWalletForChain(Chain.ethereum);
      // EVM addresses are hex; base58 Solana addresses in the session set are
      // filtered out by the `0x` prefix. Compared case-insensitively.
      final ethAddrs = <String>{
        if (active != null) active.address,
        ...sessionAddresses.where(isEthereumAddress),
      }.map((a) => a.toLowerCase()).where((a) => a.isNotEmpty).toSet();
      if (ethAddrs.isEmpty) return ArtworkPermissions.none;
      final parts = mintAccount.split('-');
      if (parts.length < 2) return ArtworkPermissions.none;
      final contract = parts.first;
      final tokenId = BigInt.tryParse(parts[1]);
      if (tokenId == null) return ArtworkPermissions.none;

      bool owns;
      try {
        final onChainOwner = (await _ethRpc.erc721OwnerOf(
          contract: contract,
          tokenId: tokenId,
        )).toLowerCase();
        owns = ethAddrs.contains(onChainOwner);
      } catch (_) {
        // Not an ERC-721 (or the token doesn't exist) — try ERC-1155 balance
        // for each session ETH wallet until one holds a positive balance.
        owns = false;
        for (final a in ethAddrs) {
          final balance = await _ethRpc.erc1155BalanceOf(
            owner: a,
            contract: contract,
            tokenId: tokenId,
          );
          if (balance > BigInt.zero) {
            owns = true;
            break;
          }
        }
      }
      return ArtworkPermissions(
        canTransfer: owns && !listed,
        canEdit: false,
        canBurn: false,
        canList: false,
        canDownload: owns,
      );
    } catch (_) {
      return const UnresolvedArtworkPermissions();
    }
  }

  /// Every address the user controls, for the "owns or created" **download and
  /// cast** gates.
  ///
  /// 🛑 These two gates are the only ones allowed to reach outside the active
  /// session ([SessionManager.scopedToSession]). Both are purely local actions —
  /// saving a file, streaming to a display — so requiring a wallet switch just
  /// to download or cast art the user demonstrably owns is a UX cost with no
  /// authorization benefit. Everything else (signing, receiving, balances,
  /// ownership badges, "You own" lists) must be session-scoped: a Profile
  /// session sources only from the wallets linked in its user record.
  ///
  /// The set is:
  ///   1. Any imported wallet that can sign, across every account.
  ///   2. Every wallet grouped in an account (portfolio) that holds a signer —
  ///      pulls in view-only wallets sitting alongside a signable one.
  ///   3. Every wallet linked to a mallow profile that the user holds a signer
  ///      for — including profile-linked addresses the user hasn't imported
  ///      locally (the same synthetic view-only wallets the accounts drawer
  ///      shows). Sourced from [ProfileLookupService]'s in-memory bulk-lookup
  ///      cache (warmed at session login / on drawer open); no network call is
  ///      made here, so this clause is simply skipped when the cache is cold.
  Future<Set<String>> ownedAddresses() async {
    final signable = <String>{};
    for (final wallet in await _walletRepo.getAllWallets()) {
      if (wallet.canSign && wallet.address.isNotEmpty) {
        signable.add(wallet.address);
      }
    }

    final owned = <String>{...signable};

    for (final account in await _walletRepo.getAccountViews()) {
      if (account.wallets.any((w) => w.canSign)) {
        for (final wallet in account.wallets) {
          if (wallet.address.isNotEmpty) owned.add(wallet.address);
        }
      }
    }

    // Profile-linked addresses come back from the API with EVM hex lowercased
    // while local wallets hold the EIP-55 checksummed form, so the membership
    // test normalises both sides — a raw compare drops the whole widening for
    // an EVM signer. Solana / Tezos are case-sensitive and pass through.
    final signableKeys = signable.map(apiOwnerAddress).toSet();
    final profiles = _profileLookup.lastResponse?.result.users ?? const [];
    for (final entry in profiles) {
      final linked = entry.user.addresses;
      if (linked.map(apiOwnerAddress).any(signableKeys.contains)) {
        for (final address in linked) {
          if (address.isNotEmpty) owned.add(address);
        }
      }
    }

    return owned;
  }

  /// The addresses the backend will authorize a hide/unhide write against under
  /// the current login: the active (login) wallet [activeAddress] plus every
  /// address on the mallow profile that wallet belongs to — exactly
  /// `req.user.addresses` in the backend's `hideService` (the login token's
  /// address resolves to exactly one profile).
  ///
  /// This is deliberately NARROWER than [ownedAddresses]: it never spans other
  /// session wallets or other profiles the user holds a signer for, because the
  /// signed-login `/v0/hide` write honors only the login wallet's own profile.
  /// In Account mode (wallets grouped locally with no shared profile) it
  /// collapses to just the active wallet — matching what the backend accepts.
  ///
  /// Sourced from [ProfileLookupService]'s in-memory bulk-lookup cache (the
  /// same source [ownedAddresses] uses); no network call is made here. When the
  /// cache is cold it degrades to the active address alone — a subset of what
  /// the backend accepts, so it can never surface a row the backend would 403.
  Set<String> loginProfileAddresses(String activeAddress) {
    final addresses = <String>{if (activeAddress.isNotEmpty) activeAddress};
    final profiles = _profileLookup.lastResponse?.result.users ?? const [];
    for (final entry in profiles) {
      if (entry.user.addresses.contains(activeAddress)) {
        for (final address in entry.user.addresses) {
          if (address.isNotEmpty) addresses.add(address);
        }
      }
    }
    return addresses;
  }

  /// Bulk variant of the [ArtworkPermissions.canDownload] gate: the subset of
  /// [mints] owned or created by any wallet the user controls, resolved via
  /// DAS getAssetBatch (1000 mints per call). Returns an empty set on any
  /// error — callers deny rather than fail. Used by both the curation
  /// download and cast gates, which restrict bulk actions to owned/created art.
  Future<Set<String>> ownedOrCreatedMints(List<String> mints) async {
    try {
      final owned = await ownedAddresses();
      if (owned.isEmpty || mints.isEmpty) return const {};
      final downloadable = <String>{};
      for (var i = 0; i < mints.length; i += 1000) {
        final chunk = mints.sublist(
          i,
          i + 1000 > mints.length ? mints.length : i + 1000,
        );
        for (final asset in await _dasApi.getAssetBatch(chunk)) {
          // Same rule as the single-mint gate above: owner or update
          // authority (the app's "creator" signal) in the owned set.
          final ownsOrCreated =
              (asset.owner != null && owned.contains(asset.owner)) ||
              (asset.updateAuthority != null &&
                  owned.contains(asset.updateAuthority));
          if (ownsOrCreated) downloadable.add(asset.id);
        }
      }
      return downloadable;
    } catch (_) {
      return const {};
    }
  }

  // ---------------------------------------------------------------------------
  // Permission logic — mirrors the mallow web app
  // ---------------------------------------------------------------------------

  // The DAS API only ever yields the five Solana standards parsed in
  // `TokenStandardDas.fromDasInterface`. The wildcard arms below cover
  // `objkt` / EVM standards so the switch stays exhaustive against the
  // canonical enum, but they're never reached in practice.

  /// The indexer's "this artwork is committed to a sale" gate — the single
  /// predicate behind both the Transfer and the Burn row, so the two can't
  /// drift apart (they were separate before: burn read `listingType`, transfer
  /// read only the on-chain frozen bit).
  ///
  /// Webapp parity: `useCanTransfer` refuses transfer whenever the
  /// on-chain listing PDA exists, for every token standard. Mobile has no
  /// listing-PDA read, so `listingType` (from `/byMint` —
  /// `nftRenderer`, and the v2 portfolio read)
  /// stands in for it. That indexed flag is the ONLY signal that covers
  /// listings which neither escrow nor freeze the asset:
  ///   * `listEditionsV2` installs a token-metadata `print_delegate` record and
  ///     `listCoreEditions` an mpl-core `update_delegate` plugin — both leave
  ///     the master edition in the seller's wallet, unescrowed and unfrozen
  ///     (the backend even has a 15-minute janitor,
  ///     `editionsHelper.delistMovedNonCustodialEditionListings`, that closes
  ///     listings whose asset was moved out from under them);
  ///   * non-custodial listings (`Listing.nonCustodial`) never escrow;
  ///   * external-market listings (OpenSea / objkt / exchange.art) set nothing
  ///     on the mallow programs at all.
  /// On those, a transfer *confirms* — simulation does not save us — and the
  /// listing is orphaned. Hence the term is applied before the on-chain arms.
  ///
  /// `null` [listingType] means the caller has no listing info (surfaces whose
  /// wire row omits it); it is treated as unlisted, matching the burn gate's
  /// long-standing behaviour. Widening `null` to "possibly listed" would hide
  /// transfer on every such surface, so the residual gap — a listing that the
  /// indexer has not caught up with yet — is left to the on-chain frozen arms.
  static bool isListedForSale({
    required ListingType? listingType,
    bool inGroupedSale = false,
  }) =>
      inGroupedSale ||
      (listingType != null && listingType != ListingType.unlisted);

  // [signers] is the set of session wallets that may own the token (owner /
  // update-authority arms); [user] is the active wallet, kept for delegate
  // arms — a delegate authorizes as itself, so widening it would have no wallet
  // to auto-switch to.
  //
  // The caller ANDs this with `!isListedForSale(...)`; the arms below see only
  // on-chain state and cannot tell a delegate-based listing from an unlisted
  // asset.
  bool _canTransfer(
    DigitalAsset asset,
    Set<String> signers,
    String user,
    DigitalAsset? collection,
  ) {
    // For Core children, the parent collection's permanent freeze delegate
    // freezes the child too, so we OR it in here. Mirrors the webapp's
    // `onChainCollectionAsset?.asset.permanentFreezeDelegate?.frozen`
    // check in `useCanBurn` / transfer logic.
    final notFrozen =
        !asset.frozen && !(collection?.permanentFreezeDelegateFrozen ?? false);
    return switch (asset.tokenStandard) {
      TokenStandard.nft ||
      TokenStandard.pnft ||
      TokenStandard.cnft => notFrozen && signers.contains(asset.owner),
      TokenStandard.core =>
        notFrozen &&
            (signers.contains(asset.owner) ||
                asset.transferDelegateAuthority == user ||
                collection?.transferDelegateAuthority == user),
      TokenStandard.coreCollection =>
        notFrozen &&
            (signers.contains(asset.updateAuthority) ||
                asset.transferDelegateAuthority == user),
      _ => false,
    };
  }

  bool _canBurn(
    DigitalAsset asset,
    Set<String> signers,
    String user,
    DigitalAsset? collection,
  ) =>
      canBurnAsset(asset, user: user, collection: collection, signers: signers);

  /// Webapp `useCanBurn` parity — the burn gate for every entry point,
  /// public (and static) so the market bloc can re-check right before
  /// preparing the tx (the webapp's BurnModal does the same on click).
  ///
  /// Authority arms match `useCanBurn` exactly: NFT/pNFT need the unfrozen
  /// token in the wallet and no prints minted; Core burns for the owner,
  /// the asset's burn delegate, or the parent collection's PERMANENT burn
  /// delegate; Core Collections must be empty and burn for the update
  /// authority or their permanent burn delegate.
  ///
  /// One deliberate deviation: the frozen check uses [DigitalAsset.frozen]
  /// (ownership ∪ freeze delegate ∪ permanent freeze delegate) where the
  /// webapp consults only a subset per standard. Strictly stricter — it
  /// only hides burns mpl-core would reject on-chain anyway.
  /// [signers], when provided, widens the owner / update-authority arms to any
  /// session wallet (the detail screen then auto-switches the signer). When
  /// null — the market bloc's pre-sign re-check, which runs after the signer is
  /// already the holder — it collapses to the single active [user].
  static bool canBurnAsset(
    DigitalAsset asset, {
    required String user,
    DigitalAsset? collection,
    Set<String>? signers,
  }) {
    bool owns(String? a) => signers != null ? signers.contains(a) : a == user;
    // For Core children, the parent collection's permanent freeze delegate
    // freezes the child too. Mirrors webapp `useCanBurn`'s
    // `onChainCollectionAsset.asset.permanentFreezeDelegate?.frozen` check.
    final notFrozen =
        !asset.frozen && !(collection?.permanentFreezeDelegateFrozen ?? false);
    return switch (asset.tokenStandard) {
      TokenStandard.nft ||
      TokenStandard.pnft => asset.supply == 0 && notFrozen && owns(asset.owner),
      // The webapp's burnAsset has no cnft arm, and the v2 burn builder
      // explicitly rejects cnft with BadRequest. Hide the menu item rather
      // than fail the request mid-flow.
      TokenStandard.cnft => false,
      TokenStandard.core =>
        notFrozen &&
            (owns(asset.owner) ||
                asset.burnDelegateAuthority == user ||
                collection?.permanentBurnDelegateAuthority == user),
      TokenStandard.coreCollection =>
        (asset.currentSize ?? 0) == 0 &&
            notFrozen &&
            (owns(asset.updateAuthority) ||
                asset.permanentBurnDelegateAuthority == user),
      _ => false,
    };
  }

  /// Listing puts the asset in marketplace escrow, so the wallet must own
  /// the token (or be the transfer-delegate for Core) and the asset must
  /// not be frozen. For Core Collections — Mpl Core's open-edition master
  /// — there's no token holder, so update authority gates listing instead.
  ///
  /// The parent-collection permanent-freeze arm matches [_canTransfer] and
  /// [canBurnAsset]: a Core child inside a permanently-frozen collection cannot
  /// move, and listing escrows the asset — so listing it is exactly as
  /// impossible as transferring it. Omitting the term here made listing the
  /// loosest of the three gates on the same asset.
  bool _canList(
    DigitalAsset asset,
    Set<String> signers,
    String user,
    DigitalAsset? collection,
  ) {
    if (asset.frozen || (collection?.permanentFreezeDelegateFrozen ?? false)) {
      return false;
    }
    return switch (asset.tokenStandard) {
      TokenStandard.nft ||
      TokenStandard.pnft ||
      TokenStandard.cnft => signers.contains(asset.owner),
      TokenStandard.core =>
        signers.contains(asset.owner) ||
            asset.transferDelegateAuthority == user,
      TokenStandard.coreCollection =>
        signers.contains(asset.updateAuthority) ||
            asset.transferDelegateAuthority == user,
      _ => false,
    };
  }

  /// Mirrors the webapp's `ArtworkOptionsButton.showEditOption`:
  /// `userPubkey === nftPreview.updateAuth && isMutable(asset)`. The
  /// `groupedSale == null` half of the gate is enforced at the call site.
  ///
  /// `isMutable` (`assets`):
  ///   - NFT/pNFT/cNFT → on-chain mutable flag
  ///   - Core / CoreCollection → `updateAuthority != null` (implicit once
  ///     `updateAuthority == user`)
  bool _canEdit(DigitalAsset asset, Set<String> signers) {
    if (!signers.contains(asset.updateAuthority)) return false;
    return switch (asset.tokenStandard) {
      TokenStandard.nft ||
      TokenStandard.pnft ||
      TokenStandard.cnft => asset.isMutable,
      TokenStandard.core || TokenStandard.coreCollection => true,
      _ => false,
    };
  }
}
