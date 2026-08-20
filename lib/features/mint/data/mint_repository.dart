import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:solana/solana.dart';

import '../models/picked_mint_asset.dart';
import 'ipfs_uploader.dart';

/// Solana lamports in one SOL.
const kLamportsPerSol = 1000000000;

/// Rent for a Metaplex Core asset — matches `getTokenStandardMintFees`
/// in the server's shared Solana asset helpers for
/// `TokenStandard.core`.
const kCoreRentLamports = 2500000;

/// Rent for a Metaplex CoreCollection asset (editions) — matches
/// `getTokenStandardMintFees` for `TokenStandard.coreCollection`.
const kCoreCollectionRentLamports = 1500000;

/// Metaplex Core protocol fee paid to the standard authority. Equal for
/// both `Core` and `CoreCollection` per the webapp fee table.
const kCoreProtocolFeeLamports = 1500000;

/// Per-line-item cost breakdown shown in the confirmation sheet before
/// the user taps **Confirm**. Values in lamports for precision; the UI
/// formats to SOL.
class MintCostBreakdown {
  const MintCostBreakdown({
    required this.mallowFeeLamports,
    required this.protocolFeeLamports,
    required this.rentLamports,
    required this.txFeeLamports,
  });

  final int mallowFeeLamports;
  final int protocolFeeLamports;
  final int rentLamports;
  final int txFeeLamports;

  int get totalLamports =>
      mallowFeeLamports + protocolFeeLamports + rentLamports + txFeeLamports;

  double get totalSol => totalLamports / kLamportsPerSol;
}

/// Orchestrates the mint pipeline: IPFS uploads, backend tx build, and
/// finalization. Signing + broadcast live in [MintBloc] so they can
/// co-ordinate with the user wallet via `WalletManager` (Phase 7).
@lazySingleton
class MintRepository {
  MintRepository(this._api, this._apiV2, this._ipfs);

  final MallowApiClient _api;
  final MallowApiV2Client _apiV2;
  final IpfsUploader _ipfs;

  /// Upload [asset] to IPFS and tag it with the returned hash. Mutates by
  /// returning a new instance — callers should replace the stored value.
  Future<PickedMintAsset> uploadAsset(PickedMintAsset asset) async {
    if (asset.ipfsHash != null && asset.ipfsHash!.isNotEmpty) return asset;
    final hash = await _ipfs.uploadBytes(
      bytes: asset.bytes,
      fileName: asset.fileName,
      mimeType: asset.mimeType,
    );
    // fire-and-forget pin request; don't block on failure.
    unawaited(
      _api.pinIpfsHash(IpfsPinRequest(hash: hash)).catchError((_) => null),
    );
    return asset.copyWith(ipfsHash: hash, ipfsUrl: _ipfs.gatewayUrl(hash));
  }

  /// Build the NFT metadata JSON and upload it to IPFS. Returns the
  /// gateway URL used as `uri` in the create-asset request.
  Future<String> uploadMetadata(Map<String, dynamic> metadata) async {
    final hash = await _ipfs.uploadJson(payload: metadata);
    return _ipfs.gatewayUrl(hash);
  }

  /// Generate a fresh ephemeral keypair to use as the mint account. Held
  /// only in memory for the duration of a mint attempt.
  Future<Ed25519HDKeyPair> generateMintKeypair() => Ed25519HDKeyPair.random();

  /// Build the mint transaction via the Rust v2 endpoint
  /// (`POST /v2/tx/nft/mint`). Handles 1/1 (`core_asset`), editions
  /// (`core_master_edition_collection`), and parent collections
  /// (`core_collection`) through the request's `kind` discriminator —
  /// matches the webapp's `buildMintShadowBody` / `buildMintCollectionShadowBody`.
  Future<ApiResponse<UnsignedTxResponse>> buildMintNftTx(
    MintNftV2Request request,
  ) {
    return _apiV2.mintNftTx(request);
  }

  /// Hit `/v1/create/finalize?type=<type>` after the mint transaction lands.
  /// `type` is `'nft'` for 1/1 + editions and `'collection'` for collections —
  /// matches the webapp's `?type=` query. The v2 mint builder writes the
  /// upload record; finalization stays on v1.
  Future<void> finalize({
    required String mintAccount,
    required List<String> txIds,
    String type = 'nft',
  }) {
    return _api.finalizeMint(
      type,
      FinalizeMintRequest(mintAccount: mintAccount, txIds: txIds),
    );
  }

  /// Build an edit-NFT transaction via the Rust v2 endpoint
  /// (`POST /v2/tx/nft/edit`). Used for 1/1s and Core master editions.
  /// The chain-side metadata payload is much smaller in v2 — extended
  /// fields (description, attributes, image, …) live only in the IPFS
  /// JSON pointed to by the request's `uri`.
  Future<ApiResponse<UnsignedTxResponse>> buildEditNftTx(
    EditNftV2Request request,
  ) {
    return _apiV2.editNftTx(request);
  }

  /// Hit `/v1/edit/finalize?type=<type>` after the edit transaction
  /// lands. `type` is `'editNft'` for asset edits and `'editCollection'`
  /// for collection edits (queues the UpdateCollectionMetadata job
  /// instead of UpdateNftMetadata). The v2 builder (`POST /v2/tx/nft/edit`)
  /// writes the upload record; finalization stays on v1, matching the webapp.
  Future<void> finalizeEdit({
    required String mintAccount,
    required List<String> txIds,
    String type = 'editNft',
  }) {
    return _api.finalizeEditNft(
      type,
      FinalizeMintRequest(mintAccount: mintAccount, txIds: txIds),
    );
  }

  /// Load the current user's Core collections for the picker.
  Future<List<CollectionPreviewRender>> listCollectionsForCreator(
    String pubkey,
  ) async {
    try {
      final response = await _api.getCollectionsByCreator(
        pubkey,
        tokenStandard: TokenStandard.core.wireValue,
      );
      return response.result;
    } catch (e, s) {
      debugPrint('[MintRepository] listCollectionsForCreator failed: $e');
      debugPrintStack(stackTrace: s, label: 'listCollectionsForCreator');
      rethrow;
    }
  }

  /// Load the server-side protocol fees used to build the pre-mint cost
  /// breakdown. Returns `null` on failure so the UI can fall back to
  /// cached defaults instead of blocking the flow.
  Future<TxFees?> fetchTxFees() async {
    try {
      final response = await _api.getTxFees();
      return response.result;
    } catch (_) {
      return null;
    }
  }

  /// Tags previously used in the create flow, offered as autosuggest.
  Future<List<String>> fetchRecentTags() async {
    try {
      final response = await _api.getRecentCreateTags();
      return response.result;
    } catch (_) {
      return const [];
    }
  }

  /// Unlockable-content record ids currently attached to [mintAccount].
  ///
  /// Read from `item.unlockableContent` on the artwork render — the same
  /// source the webapp uses (`CreateContext`) to round-trip the ids
  /// through an edit. Returns **null** when the lookup fails: the caller
  /// must not fall back to an empty list, because the v2 edit route reads an
  /// empty `unlockableContentIds` as "clear the AppData plugin" and would
  /// destroy the collector's exclusive content.
  Future<List<int>?> fetchAttachedUnlockableContentIds(
    String mintAccount,
  ) async {
    try {
      final response = await _api.getArtworkByMint(mintAccount);
      return response.result.item.unlockableContent
          .map((c) => c.id)
          .toList(growable: false);
    } catch (e) {
      debugPrint(
        '[MintRepository] fetchAttachedUnlockableContentIds failed: $e',
      );
      return null;
    }
  }

  /// List previously uploaded exclusive content for the picker in the
  /// Upload step's "Exclusive Content" tab.
  Future<List<UnlockableContentPreview>> listMyUnlockableContent() async {
    try {
      final response = await _api.getMyUnlockableContent();
      return response.result;
    } catch (e) {
      debugPrint('[MintRepository] listMyUnlockableContent failed: $e');
      return const [];
    }
  }
}

/// Marker exception type for mint-pipeline failures. Surfaced as-is in
/// the confirmation sheet's error state.
class MintException implements Exception {
  MintException(this.message, {this.stage});

  final String message;
  final String? stage;

  @override
  String toString() => stage == null
      ? 'MintException: $message'
      : 'MintException[$stage]: $message';
}
