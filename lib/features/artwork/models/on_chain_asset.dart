// On-chain asset data from the Helius DAS API.
// Represents the parsed result of a `getAsset` RPC call, containing only
// the fields needed for permission computation (canTransfer/canEdit/canBurn).

import 'package:mallow_api/mallow_api.dart';

export 'package:mallow_api/mallow_api.dart' show TokenStandard;

/// Parsed on-chain asset data from the DAS getAsset response.
class DigitalAsset {
  const DigitalAsset({
    required this.id,
    required this.tokenStandard,
    required this.isMutable,
    required this.frozen,
    required this.supply,
    required this.freezeDelegateFrozen,
    required this.permanentFreezeDelegateFrozen,
    required this.hasMasterEditionPlugin,
    this.owner,
    this.updateAuthority,
    this.currentSize,
    this.freezeDelegateAuthority,
    this.transferDelegateAuthority,
    this.burnDelegateAuthority,
    this.permanentBurnDelegateAuthority,
    this.updateDelegateAuthority,
    this.collectionKey,
    this.masterEditionMaxSupply,
    this.name,
    this.uri,
    this.sellerFeeBasisPoints,
    this.tokenMetadataCreators = const [],
    this.royaltiesPluginBasisPoints,
    this.royaltiesPluginCreators = const [],
    this.primarySaleHappened = false,
  });

  /// Parse a DigitalAsset from a DAS `getAsset` result object.
  factory DigitalAsset.fromJson(Map<String, dynamic> json) {
    final iface = json['interface'] as String?;
    final compression = (json['compression'] as Map<String, dynamic>?) ?? {};
    final isCompressed = compression['compressed'] == true;

    final tokenStandard = TokenStandardDas.fromDasInterface(
      iface,
      isCompressed: isCompressed,
    );

    final ownership = (json['ownership'] as Map<String, dynamic>?) ?? {};
    final authorities = (json['authorities'] as List<dynamic>?) ?? [];
    final supplyObj = (json['supply'] as Map<String, dynamic>?) ?? {};
    final grouping = (json['grouping'] as List<dynamic>?) ?? [];
    final plugins = (json['plugins'] as Map<String, dynamic>?) ?? {};

    // Find the full-scope update authority
    String? updateAuthority;
    for (final auth in authorities) {
      final authMap = auth as Map<String, dynamic>;
      final scopes = (authMap['scopes'] as List<dynamic>?) ?? [];
      if (scopes.contains('full')) {
        updateAuthority = authMap['address'] as String?;
        break;
      }
    }

    // Find parent collection key from grouping array
    String? collectionKey;
    for (final group in grouping) {
      final groupMap = group as Map<String, dynamic>;
      if (groupMap['group_key'] == 'collection') {
        collectionKey = groupMap['group_value'] as String?;
        break;
      }
    }

    // Supply: print_current_supply for NFTs; 0 for Core assets
    final supply = (supplyObj['print_current_supply'] as int?) ?? 0;

    // Current size for Core collections. DAS nests it under `mpl_core_info`
    // (`{num_minted, current_size, plugins_json_version}`) — it is NOT a
    // top-level field. Missing this made every Core collection look empty
    // and let the burn gate offer chain-rejected burns.
    final mplCoreInfo = (json['mpl_core_info'] as Map<String, dynamic>?) ?? {};
    final currentSize = mplCoreInfo['current_size'] as int?;

    // Parse Core plugin delegate authorities. DAS serializes mpl-core
    // plugins with snake_case keys and nests each plugin's fields under
    // `data`: `{data: {frozen: ...}, authority: {type, address}, ...}`.
    // `authority.address` is only populated for explicit Address-type
    // delegates (null for Owner/UpdateAuthority types) — the same literal
    // reading the webapp's `useCanBurn` applies to mpl-core accounts.
    //
    // The "permanent" variants (`permanent_freeze_delegate`,
    // `permanent_burn_delegate`) live on the collection — once set, only
    // the holder of that authority can lift the freeze or burn the asset,
    // regardless of owner.
    Map<String, dynamic>? pluginData(String key) =>
        (plugins[key] as Map<String, dynamic>?)?['data']
            as Map<String, dynamic>?;
    String? pluginAuthority(String key) =>
        (((plugins[key] as Map<String, dynamic>?)?['authority']
                as Map<String, dynamic>?)?['address'])
            as String?;

    final freezeDelegateAuthority = pluginAuthority('freeze_delegate');
    final freezeDelegateFrozen =
        pluginData('freeze_delegate')?['frozen'] == true;
    final permanentFreezeDelegateFrozen =
        pluginData('permanent_freeze_delegate')?['frozen'] == true;
    final transferDelegateAuthority = pluginAuthority('transfer_delegate');
    final burnDelegateAuthority = pluginAuthority('burn_delegate');
    final permanentBurnDelegateAuthority = pluginAuthority(
      'permanent_burn_delegate',
    );
    final updateDelegateAuthority = pluginAuthority('update_delegate');

    // Master Edition plugin (Core Collections only) — presence marks the
    // asset as a printable master edition. `max_supply` may be null,
    // meaning open edition.
    final hasMasterEditionPlugin = plugins.containsKey('master_edition');
    final masterEditionMaxSupply =
        pluginData('master_edition')?['max_supply'] as int?;

    // Name + metadata URI live under `content` in DAS responses.
    final content = (json['content'] as Map<String, dynamic>?) ?? {};
    final metadata = (content['metadata'] as Map<String, dynamic>?) ?? {};
    final name = metadata['name'] as String?;
    final uri = content['json_uri'] as String?;

    // Royalty info: top-level `royalty` for token-metadata; for Core /
    // CoreCollection the chain stores it differently and the on-chain
    // signal we trust comes from the API render. Captured here for
    // verified-status preservation on token-metadata edits.
    final royalty = (json['royalty'] as Map<String, dynamic>?) ?? {};
    final sellerFeeBasisPoints = (royalty['basis_points'] as num?)?.toInt();

    // Whether a primary sale has already occurred for this token-metadata
    // asset. DAS surfaces it under `royalty.primary_sale_happened`. This is
    // the on-chain signal the webapp's `isSecondaryMarket` reads for
    // Nft/pNFT/cNFT on its asset model — once true, the asset
    // trades on the secondary market and the primary proceeds split no longer
    // applies. Absent/false for Core (which keys off owner vs update
    // authority instead).
    final primarySaleHappened = royalty['primary_sale_happened'] == true;
    final creatorsRaw = (json['creators'] as List<dynamic>?) ?? const [];
    final tokenMetadataCreators = creatorsRaw
        .whereType<Map<String, dynamic>>()
        .map(
          (c) => OnChainCreator(
            address: (c['address'] as String?) ?? '',
            share: (c['share'] as num?)?.toInt() ?? 0,
            verified: c['verified'] == true,
          ),
        )
        .where((c) => c.address.isNotEmpty)
        .toList(growable: false);

    // mpl-core royalties plugin (Core / CoreCollection). Helius nests the
    // plugin fields under `data`: `{data: {basis_points, creators:
    // [{address, percentage}], rule_set}, authority, ...}`. This is the
    // on-chain source of truth for Core royalties — mirrors the webapp's
    // `getRoyalties`, which reads the same plugin. `verified` is derived
    // (address == update authority), matching that helper.
    final royaltiesPluginData =
        (plugins['royalties'] as Map<String, dynamic>?)?['data']
            as Map<String, dynamic>?;
    final royaltiesPluginBasisPoints =
        (royaltiesPluginData?['basis_points'] as num?)?.toInt();
    final royaltiesPluginCreators =
        ((royaltiesPluginData?['creators'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(
              (c) => OnChainCreator(
                address: (c['address'] as String?) ?? '',
                share: (c['percentage'] as num?)?.toInt() ?? 0,
                verified: c['address'] == updateAuthority,
              ),
            )
            .where((c) => c.address.isNotEmpty)
            .toList(growable: false);

    return DigitalAsset(
      id: json['id'] as String,
      tokenStandard: tokenStandard,
      isMutable: json['mutable'] == true,
      frozen:
          ownership['frozen'] == true ||
          freezeDelegateFrozen ||
          permanentFreezeDelegateFrozen,
      supply: supply,
      freezeDelegateFrozen: freezeDelegateFrozen,
      permanentFreezeDelegateFrozen: permanentFreezeDelegateFrozen,
      hasMasterEditionPlugin: hasMasterEditionPlugin,
      owner: ownership['owner'] as String?,
      updateAuthority: updateAuthority,
      currentSize: currentSize,
      freezeDelegateAuthority: freezeDelegateAuthority,
      transferDelegateAuthority: transferDelegateAuthority,
      burnDelegateAuthority: burnDelegateAuthority,
      permanentBurnDelegateAuthority: permanentBurnDelegateAuthority,
      updateDelegateAuthority: updateDelegateAuthority,
      collectionKey: collectionKey,
      masterEditionMaxSupply: masterEditionMaxSupply,
      name: name,
      uri: uri,
      sellerFeeBasisPoints: sellerFeeBasisPoints,
      tokenMetadataCreators: tokenMetadataCreators,
      royaltiesPluginBasisPoints: royaltiesPluginBasisPoints,
      royaltiesPluginCreators: royaltiesPluginCreators,
      primarySaleHappened: primarySaleHappened,
    );
  }

  /// Mint account address
  final String id;

  final TokenStandard tokenStandard;

  /// Whether the asset metadata is mutable
  final bool isMutable;

  /// Whether the asset/token account is frozen
  final bool frozen;

  /// Print current supply (NFT/pNFT) — 0 means eligible for burn
  final int supply;

  /// Whether the freeze delegate has frozen this Core asset
  final bool freezeDelegateFrozen;

  /// Whether the permanentFreezeDelegate plugin has frozen this Core asset
  /// (or, for Core children, the parent collection's permanent freeze).
  /// Permanent freezes can only be lifted by the plugin authority and
  /// override owner consent.
  final bool permanentFreezeDelegateFrozen;

  /// Current token owner address
  final String? owner;

  /// Update authority address (full-scope authority)
  final String? updateAuthority;

  /// Current number of assets in a Core collection
  final int? currentSize;

  // --- Core asset plugin delegate authorities ---

  final String? freezeDelegateAuthority;
  final String? transferDelegateAuthority;
  final String? burnDelegateAuthority;

  /// Authority of the `permanentBurnDelegate` plugin (Core / CoreCollection).
  /// Webapp's `useCanBurn` allows this address to burn the asset even when
  /// they are not the owner — mpl-core honours it on-chain regardless.
  final String? permanentBurnDelegateAuthority;

  final String? updateDelegateAuthority;

  /// Parent collection mint address (if asset belongs to a collection)
  final String? collectionKey;

  /// True when the asset is a Core Collection carrying the
  /// `masterEdition` plugin — i.e. a Core master edition. Supply is
  /// editable on these (subject to mutability).
  final bool hasMasterEditionPlugin;

  /// `maxSupply` from the master-edition plugin (Core Collections only).
  /// `null` indicates an open edition; a positive integer is the
  /// limited-edition cap. Only meaningful when [hasMasterEditionPlugin]
  /// is true.
  final int? masterEditionMaxSupply;

  /// Asset name from on-chain metadata (DAS `content.metadata.name`).
  final String? name;

  /// Off-chain metadata URI (DAS `content.json_uri`).
  final String? uri;

  /// Seller-fee basis points reported by DAS (token-metadata only).
  final int? sellerFeeBasisPoints;

  /// On-chain creator entries with verified flags. Populated from DAS for
  /// token-metadata standards; for Core / CoreCollection use
  /// [royaltiesPluginCreators] instead. Used at edit time to preserve the
  /// immutable `verified` flag of non-self creators on NFT/pNFT edits.
  final List<OnChainCreator> tokenMetadataCreators;

  /// `basis_points` from the mpl-core royalties plugin (Core /
  /// CoreCollection). Null when the asset carries no royalties plugin.
  final int? royaltiesPluginBasisPoints;

  /// Royalty creators from the mpl-core royalties plugin (Core /
  /// CoreCollection); `share` is the plugin's `percentage`. Empty when
  /// the asset carries no royalties plugin. The on-chain source of truth
  /// for Core royalties — mirrors the webapp's `getRoyalties`.
  final List<OnChainCreator> royaltiesPluginCreators;

  /// Whether a primary sale has already happened (DAS
  /// `royalty.primary_sale_happened`). Meaningful only for token-metadata
  /// standards (Nft/pNFT/cNFT), where the webapp's `isSecondaryMarket`
  /// reads it directly. Always `false` for Core / CoreCollection assets,
  /// which classify off owner-vs-update-authority instead.
  final bool primarySaleHappened;
}

/// On-chain creator entry as returned by DAS for token-metadata assets.
class OnChainCreator {
  const OnChainCreator({
    required this.address,
    required this.share,
    required this.verified,
  });

  final String address;
  final int share;
  final bool verified;
}

/// Computed on-chain permissions for an artwork.
class ArtworkPermissions {
  const ArtworkPermissions({
    required this.canTransfer,
    required this.canEdit,
    required this.canBurn,
    required this.canList,
    this.canDownload = false,
    this.canHide = false,
    this.onChainRoyaltyBps,
  });

  final bool canTransfer;
  final bool canEdit;
  final bool canBurn;
  final bool canList;

  /// True when the artwork's on-chain owner or update authority (creator)
  /// matches any address the user controls — an imported signable wallet, or a
  /// wallet linked in the active portfolio that holds at least one signer.
  /// Gates the "Download to device" option; unlike the other flags it is not
  /// scoped to the single active wallet.
  final bool canDownload;

  /// True when the artwork's on-chain owner or update authority (creator) is an
  /// address on the current LOGIN wallet's backend profile — the only addresses
  /// the signed-login `/v0/hide` · `/v0/unhide` write authorizes against
  /// (`req.user.addresses`). Gates the Hide / Unhide row.
  ///
  /// Deliberately NARROWER than [canDownload], which spans every session wallet:
  /// the hide write is keyed to the login wallet's own profile, so in Account
  /// mode (wallets grouped locally with no shared profile) an artwork held by a
  /// different session wallet is NOT hideable — surfacing it would guarantee a
  /// backend 403. Subowner (`NftOwner`) authorization the backend also honors
  /// isn't visible on-chain, so this errs toward hiding the row, never showing
  /// one the backend would reject.
  final bool canHide;

  /// Seller-fee basis points read off the chain (`resolveOnChainRoyalties`),
  /// or null when the DAS read didn't happen / failed.
  ///
  /// Not a permission — it rides along because the DAS `getAsset` (plus, for a
  /// Core asset, its collection) that resolves it is exactly the read this
  /// call already performs, and a Core/pNFT asset whose royalty lives only in
  /// the on-chain plugin reports `sellerFeeBasisPoints: 0` in the index. The
  /// webapp does the same substitution from the same source
  /// (`ArtworkDetails` → `getRoyalties`); without it the Royalties
  /// row states 0% for an artwork that really does pay a royalty.
  final int? onChainRoyaltyBps;

  /// All-false permissions (fallback on error or view-only wallet).
  static const none = ArtworkPermissions(
    canTransfer: false,
    canEdit: false,
    canBurn: false,
    canList: false,
  );
}
