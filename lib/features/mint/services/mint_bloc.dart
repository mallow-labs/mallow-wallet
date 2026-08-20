import 'dart:async';
import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:solana/encoder.dart' show SignedTx;
import 'package:solana/solana.dart' show Ed25519HDKeyPair;

import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/data/mallow_tokens.dart';
import '../../../core/models/account.dart';
import '../../../core/network/solana_rpc_service.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/security/security_utils.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/services/fee_config.dart';
import '../../../core/services/sentry_service.dart';
import '../../../core/services/signing_copy.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/services/transaction_executor.dart';
import '../../../core/services/transaction_pipeline.dart';
import '../../../di.dart';
import '../../artwork/services/artwork_edited_signal.dart';
import '../../artwork/services/ensure_signer.dart';
import '../../portfolio/services/balance_optimistic_updater.dart';
import '../../portfolio/services/portfolio_refresh_signal.dart';
import '../data/edit_prefill.dart';
import '../data/mint_repository.dart';
import '../models/mint_form_models.dart';
import '../models/picked_mint_asset.dart';
import '../models/token_metadata.dart';
import '../pickers/category_picker_sheet.dart';

part 'mint_bloc.freezed.dart';

// Sentinel for MintState.copyWith — lets callers pass explicit null on
// nullable fields without conflating "leave unchanged" with "set to null".
const Object _sentinel = Object();

const _nsfwTag = 'nsfw';

/// Real-shape IPFS gateway URL used as a stand-in for the not-yet-pinned
/// metadata JSON during cost-simulation tx builds. The backend doesn't
/// dereference the URI — it just embeds it in the on-chain instruction —
/// so this lets us preview the SOL cost without burning an IPFS pin.
const _kSimulationMetadataUri =
    'ipfs://QmSimulatedMetadataPlaceholder000000000000000';

/// Backstop for the pre-success indexer wait. `checkTx` + `checkEntry` each
/// give up after 10 one-second attempts, so the poll itself tops out around
/// 22 s; this fires when the ack is dropped entirely (the bloc was closed
/// mid-poll, so `runIndexerCheck`'s `isClosed` guard swallows it).
///
/// It bounds only the *success emission* — the backend finalize call runs
/// concurrently with this wait, so a swallowed ack can never skip finalize.
///
/// Mutable only so tests running against a mocked [TransactionPipeline] — one
/// that never invokes `onAck` — don't sit on the real backstop.
@visibleForTesting
Duration mintIndexedAckTimeout = const Duration(seconds: 60);

/// Backstop for the *wait* on the backend finalize call — not for the call
/// itself. [_finalizeWithRetry] runs up to 3 attempts against a 30 s-timeout
/// Dio, so a wedged backend can otherwise hold "Finalizing…" for ~90 s past
/// the point where the mint is already confirmed on-chain.
///
/// Timing out here only stops *waiting*: the future is not cancelled, so its
/// remaining attempts still run to completion in the background. That's safe
/// precisely because finalize is bookkeeping for an already-landed tx whose
/// failure is swallowed either way — the same reasoning that lets the success
/// emission proceed on an exhausted retry budget.
@visibleForTesting
Duration mintFinalizeWaitTimeout = const Duration(seconds: 30);

/// Convert seller-fee basis points to the user-facing percent string used
/// in the Royalties step (e.g. `500` → `"5"`, `750` → `"7.5"`). Strips
/// the trailing `.0` so the existing text-controller sync stays clean.
String _bpsToPercentText(int bps) {
  final percent = bps / 100;
  if (percent == percent.truncateToDouble()) {
    return percent.toStringAsFixed(0);
  }
  return percent.toString();
}

/// The steps of the mint flow.
///
/// Indexed so the progress bar can compute `(index+1)/length`. The
/// [editionSupply] step is only visited when [MintState.mintType] is
/// [MintCreateType.editions]; for 1/1 it is skipped by the navigation
/// reducers.
enum MintStep {
  upload,
  details,
  categorization,
  royalties,
  editionSupply,
  review,
}

/// Editions sub-type — only meaningful when [MintState.mintType] is
/// [MintCreateType.editions].
enum MintEditionType { limited, open }

/// Pipeline status inside the confirmation sheet once the user taps
/// **Mint Artwork** on the review step.
enum MintPipelineStatus {
  /// Cost review — Confirm button active.
  idle,

  /// Uploading picked files to IPFS.
  uploading,

  /// `POST /v2/tx/nft/{mint,edit}` in flight.
  buildingTx,

  /// Waiting for the user's wallet to sign.
  awaitingApproval,

  /// Broadcast + confirming on Solana.
  broadcasting,

  /// `POST /v1/{create,edit}/finalize` in flight.
  finalizing,

  /// Successfully minted — success UI shown.
  success,

  /// Terminal error — error UI shown with retry.
  error,
}

@freezed
sealed class MintEvent with _$MintEvent {
  /// Fired once after the bloc is built to hydrate the active wallet
  /// pubkey into the form.
  const factory MintEvent.started() = MintStarted;

  /// Fired after the user picks a different funding wallet from the review
  /// step's source line — the picker has already committed the switch, so this
  /// only re-derives what the form computed for the previous wallet.
  ///
  /// The selected wallet is not just the payer: it is written on-chain as the
  /// artwork's creator/update authority and can never be changed afterwards.
  /// So the self creator row, the parent collection (scoped to
  /// `/v0/collections/byCreator/{pubkey}`) and the simulated cost — all derived
  /// from the previous wallet — must be recomputed here. Create-only; an edit's
  /// authority is fixed by the asset's update authority, which
  /// [MintConfirmMint] re-points to on its own.
  const factory MintEvent.sourceWalletChanged() = MintSourceWalletChanged;

  /// Fired once when the bloc is mounted for an edit. Loads the existing
  /// asset's on-chain + IPFS metadata and seeds every form field.
  ///
  /// [isCollection] marks an edit-collection flow (the mint is a
  /// collection NFT). The prefill can derive this on its own for Core
  /// collections, but legacy token-metadata collection NFTs look like
  /// plain 1/1s on-chain, so the caller's intent is authoritative —
  /// mirrors the webapp routing EditCollection vs EditNft explicitly.
  const factory MintEvent.startedForEdit({
    required String mintAccount,
    @Default(false) bool isCollection,
  }) = MintStartedForEdit;

  /// Internal — emitted once [MintStartedForEdit] finishes loading. Not
  /// for external dispatch.
  const factory MintEvent.editPrefilled(EditNftPrefill prefill) =
      MintEditPrefilled;

  // --- Navigation ---
  const factory MintEvent.next() = MintNext;
  const factory MintEvent.back() = MintBack;
  const factory MintEvent.gotoStep(MintStep step) = MintGotoStep;

  // --- Upload step ---
  const factory MintEvent.pickMainAsset(PickedMintAsset asset) =
      MintPickMainAsset;
  const factory MintEvent.pickThumbnail(PickedMintAsset asset) =
      MintPickThumbnail;
  const factory MintEvent.pickProcessVideo(PickedMintAsset asset) =
      MintPickProcessVideo;
  const factory MintEvent.pickBanner(PickedMintAsset asset) = MintPickBanner;
  const factory MintEvent.clearThumbnail() = MintClearThumbnail;
  const factory MintEvent.clearProcessVideo() = MintClearProcessVideo;
  const factory MintEvent.clearBanner() = MintClearBanner;
  const factory MintEvent.addExclusiveContent(PickedMintAsset asset) =
      MintAddExclusiveContent;
  const factory MintEvent.removeExclusiveContent(int index) =
      MintRemoveExclusiveContent;
  const factory MintEvent.toggleExistingExclusive(int id) =
      MintToggleExistingExclusive;

  // --- Details step ---
  const factory MintEvent.setName(String value) = MintSetName;
  const factory MintEvent.setDescription(String value) = MintSetDescription;
  const factory MintEvent.setCollection({
    MintCollectionRef? collection,
    String? name,
    CollectionPreviewRender? source,
  }) = MintSetCollection;
  const factory MintEvent.toggleNsfw() = MintToggleNsfw;

  // --- Categorization step ---
  /// Replace the category-id portion of [MintState.tags] with the ids derived
  /// from [categories] (display names from the picker). Non-category tags are
  /// preserved.
  const factory MintEvent.setCategories(List<String> categories) =
      MintSetCategories;
  const factory MintEvent.addTag(String tag) = MintAddTag;
  const factory MintEvent.removeTag(String tag) = MintRemoveTag;
  const factory MintEvent.addTrait(String name) = MintAddTrait;
  const factory MintEvent.setTraitValue(int index, String value) =
      MintSetTraitValue;
  const factory MintEvent.removeTrait(int index) = MintRemoveTrait;

  // --- Royalties step ---
  const factory MintEvent.setRoyaltyPercent(String raw) = MintSetRoyaltyPercent;
  const factory MintEvent.addCreator() = MintAddCreator;
  const factory MintEvent.setCreatorAddress(int index, String address) =
      MintSetCreatorAddress;
  const factory MintEvent.setCreatorShare(int index, String raw) =
      MintSetCreatorShare;
  const factory MintEvent.removeCreator(int index) = MintRemoveCreator;

  // --- Mint type / editions step ---
  const factory MintEvent.setMintType(MintCreateType type) = MintSetMintType;
  const factory MintEvent.setEditionType(MintEditionType type) =
      MintSetEditionType;
  const factory MintEvent.setEditionSupply(String raw) = MintSetEditionSupply;

  // --- Pipeline ---
  const factory MintEvent.requestMint() = MintRequestMint;

  /// Build the (mint or edit) tx with a placeholder metadata URI to skip
  /// the IPFS pin, simulate it with `inspectAccounts: [userPubkey]`, and
  /// store the user's lamport delta as [MintState.simulatedTxCostLamports]
  /// so the confirm sheet can show a real "Solana and protocol fees"
  /// number instead of a static estimate.
  const factory MintEvent.simulateTxCost() = MintSimulateTxCost;

  const factory MintEvent.confirmMint() = MintConfirmMint;
  const factory MintEvent.retryMint() = MintRetryMint;
  const factory MintEvent.dismissError() = MintDismissError;
  const factory MintEvent.reset() = MintReset;

  /// Internal — emitted by the background `_runCheckTx` poll once the
  /// indexer acks the mint tx. Drives [MintState.indexed] so the
  /// success screen can enable "View artwork" once the new asset is
  /// queryable server-side.
  const factory MintEvent.indexedAck({
    required String signature,
    required bool ok,
  }) = MintIndexedAck;
}

class MintState extends Equatable {
  const MintState({
    this.step = MintStep.upload,
    this.userPubkey = '',
    this.mintType = MintCreateType.oneOfOne,
    this.editionType = MintEditionType.limited,
    this.editionSupply = '',
    this.mainAsset,
    this.thumbnail,
    this.processVideo,
    this.banner,
    this.exclusiveContentFiles = const <PickedMintAsset>[],
    this.exclusiveContentExistingIds = const <int>[],
    this.name = '',
    this.description = '',
    this.collection,
    this.collectionName,
    this.collectionSource,
    this.nsfw = false,
    this.tags = const <String>[],
    this.traits = const <MintTraitInput>[],
    this.royaltyPercent = '',
    this.creators = const <MintCreatorInput>[],
    this.txFees,
    this.pipelineStatus = MintPipelineStatus.idle,
    this.pipelineError,
    this.pipelineFailure,
    this.pipelineStage,
    this.mintAccount,
    this.mintSignature,
    this.indexed,
    this.editMintAccount,
    this.editTokenStandard,
    this.isMasterEditionEdit = false,
    this.editCurrentSupply = 0,
    this.editIsMutable = true,
    this.editUpdateAuthority,
    this.existingImageUrl,
    this.existingThumbnailUrl,
    this.existingProcessVideoUrl,
    this.existingBannerUrl,
    this.existingMainAssetIsVideo = false,
    this.existingFileTypesByUri = const <String, String>{},
    this.unlockableContentUnknown = false,
    this.editPrefillLoading = false,
    this.existingMetadataUri,
    this.existingCreatorVerifiedByAddress = const <String, bool>{},
    this.preEditMetadataJson,
    this.preEditMaxSupply,
    this.preEditCollectionMint,
    this.isSimulatingTxCost = false,
    this.simulatedTxCostLamports,
  });

  final MintStep step;

  // Wallet context
  final String userPubkey;

  // Mint type — drives header copy, the editionSupply step, and the
  // create-asset payload. Defaults to 1/1 so existing entry points keep
  // working unchanged.
  final MintCreateType mintType;
  final MintEditionType editionType;
  final String editionSupply;

  // Upload step
  final PickedMintAsset? mainAsset;
  final PickedMintAsset? thumbnail;
  final PickedMintAsset? processVideo;
  // Collection-only: required banner image (top of the collection card).
  final PickedMintAsset? banner;
  final List<PickedMintAsset> exclusiveContentFiles;
  final List<int> exclusiveContentExistingIds;

  // Details step
  final String name;
  final String description;
  final MintCollectionRef? collection;
  final String? collectionName;
  // Full preview render for the picked collection. Held so the
  // Categorization step can derive the collection's category/free-tag
  // partition for UI gating (mirrors `Details 371-416`).
  final CollectionPreviewRender? collectionSource;
  final bool nsfw;

  // Categorization step
  //
  // [tags] is the unified source of truth for both free-form tags and
  // selected categories — categories are stored as their canonical id
  // (e.g. "AI" → "ai", "Short Film" → "short-film"). The categorization
  // step parses categories out for display via [mintCategoryIdSet].
  final List<String> tags;
  final List<MintTraitInput> traits;

  // Royalties step
  final String royaltyPercent;
  final List<MintCreatorInput> creators;

  // Protocol fees for the confirmation-sheet cost breakdown.
  final TxFees? txFees;

  // Pipeline
  final MintPipelineStatus pipelineStatus;
  final String? pipelineError;

  /// The classified failure behind [pipelineError], carried so the host can
  /// tell a remote kill from an ordinary mint/edit failure and present the
  /// operator's copy instead of the pipeline's generic "Mint failed" body.
  /// Null for the pipeline errors set from
  /// client-side validation, and always cleared alongside [pipelineError].
  final AppFailure? pipelineFailure;
  final String? pipelineStage;
  final String? mintAccount;
  final String? mintSignature;

  /// Indexer-ack flag for the just-broadcast mint tx — runs in parallel
  /// with the [finalizeMint] call below. `null` while polling, `true`
  /// once the marketplace indexer acks (or `false` after retries
  /// exhaust). The success screen's "View artwork" CTA can gate on this
  /// to avoid bouncing the user to a 404 detail screen.
  final bool? indexed;

  // --- Edit mode (mirrors webapp's CreateContext used for /edit) ---
  //
  // When [editMintAccount] is non-null, the bloc is operating on an
  // existing asset: skip the ephemeral mint keypair, reuse the
  // existing IPFS URLs when the user doesn't pick new files, and
  // route through the edit endpoints instead of create.

  /// Mint account being edited. Null when minting fresh.
  final String? editMintAccount;

  /// On-chain token standard of the asset being edited. Cannot be
  /// changed — mirrors webapp's `setTokenStandard(...)` after fetching
  /// the asset.
  final TokenStandard? editTokenStandard;

  /// True when the edited asset is a Core master edition
  /// (`coreCollection` + `masterEdition` plugin). Drives whether the
  /// edition-supply step is visible.
  final bool isMasterEditionEdit;

  /// Current minted count for master-edition edits. Surfaced so the
  /// supply step can warn the user about reducing below printed.
  final int editCurrentSupply;

  /// On-chain mutability of the edited asset. When false the edit
  /// flow should never have been entered, but defended against here.
  final bool editIsMutable;

  /// On-chain update authority of the edited asset — the wallet the edit
  /// tx must be signed by. Captured at prefill time so the edit screen and
  /// [_onConfirmMint] can auto-switch the active signer to the holding
  /// session wallet (mirrors transfer/burn/list's `ensureSigner`).
  final String? editUpdateAuthority;

  /// Existing IPFS URLs from the on-chain metadata JSON. Reused as
  /// the `image` / `animation_url` / `processVideo` / `banner` payload
  /// values when the user has not picked a fresh asset.
  final String? existingImageUrl;
  final String? existingThumbnailUrl;
  final String? existingProcessVideoUrl;
  final String? existingBannerUrl;

  /// True when the existing main asset is a video — drives the
  /// upload-step artwork dropzone to render with the video preview
  /// path instead of `Image.network` (which can't decode mp4/webm).
  final bool existingMainAssetIsVideo;

  /// Mime type per existing asset URL, keyed by URL. Seeded at prefill time
  /// from the on-chain JSON's own `properties.files` (plus the indexer's
  /// `mimeType` for the main asset), so an edit that doesn't re-pick a file
  /// can still emit a faithful `properties.files` entry and the right
  /// `properties.category`. Empty for a fresh mint — freshly picked files
  /// carry their own [PickedMintAsset.mimeType].
  final Map<String, String> existingFileTypesByUri;

  /// True when the attached-unlockable-content lookup failed for the asset
  /// being edited, i.e. we do **not** know which content ids are on the
  /// AppData plugin. The v2 edit builder reads an empty
  /// `unlockableContentIds` as an explicit clear
  /// (the backend's edit-asset builder emits `RemoveExternalPluginAdapter`), so
  /// guessing `[]` would destroy the collector's exclusive content. The
  /// confirm pipeline refuses instead.
  final bool unlockableContentUnknown;

  /// True between the moment the edit flow mounts and the prefill
  /// completes. Drives the upload-step skeletons so the user sees a
  /// loading indicator instead of an empty dropzone while the DAS +
  /// IPFS fetches are in flight.
  final bool editPrefillLoading;

  /// Existing metadata URI (the `uri` on-chain). Reused when nothing
  /// in the form changed — short-circuits the IPFS metadata upload.
  final String? existingMetadataUri;

  /// Original on-chain `verified` flag per creator address, captured
  /// at prefill time. For NFT/pNFT, the chain refuses to flip
  /// `verified` for any creator that isn't signing — so non-self
  /// creators must round-trip with their original flag. For Core /
  /// CoreCollection this map is empty (verified is derived from the
  /// update authority server-side).
  final Map<String, bool> existingCreatorVerifiedByAddress;

  /// Deep snapshot of `toMetadataJson()` captured at prefill time —
  /// drives two optimizations at confirm time (mirrors webapp's
  /// `isEqual(preEditJsonMetadata, ...)`):
  ///
  ///   1. **Skip metadata re-upload** — when the freshly built JSON
  ///      deep-equals this snapshot we reuse `existingMetadataUri`
  ///      instead of pinning a no-op JSON to IPFS.
  ///   2. **Short-circuit no-op edits** — combined with
  ///      [preEditMaxSupply] + [preEditCollectionMint], if nothing
  ///      changed we surface an error before signing instead of
  ///      paying the edit fee for a no-op tx.
  final Map<String, dynamic>? preEditMetadataJson;

  /// `maxSupply` at prefill time. Not encoded in the metadata JSON
  /// (it's a chain-side field), so tracked separately for the
  /// no-change check.
  final int? preEditMaxSupply;

  /// Parent collection mint at prefill time. Tracked separately for
  /// the no-change check — collection swap is a chain-side change
  /// not visible in the metadata JSON.
  final String? preEditCollectionMint;

  /// True while the cost simulation is in flight. Drives the
  /// "Solana and protocol fees" loading state on the confirm sheet.
  final bool isSimulatingTxCost;

  /// Total lamports the user will spend on the (mint or edit) tx,
  /// computed by simulating with `inspectAccounts: [userPubkey]` and
  /// diffing the user's pre/post SOL balance. Null while loading or
  /// when the simulation falls through (e.g. tx-build failure). The
  /// confirm sheet falls back to the static [MintCostBreakdown] sum
  /// when null.
  final int? simulatedTxCostLamports;

  MintState copyWith({
    MintStep? step,
    String? userPubkey,
    MintCreateType? mintType,
    MintEditionType? editionType,
    String? editionSupply,
    Object? mainAsset = _sentinel,
    Object? thumbnail = _sentinel,
    Object? processVideo = _sentinel,
    Object? banner = _sentinel,
    List<PickedMintAsset>? exclusiveContentFiles,
    List<int>? exclusiveContentExistingIds,
    String? name,
    String? description,
    Object? collection = _sentinel,
    Object? collectionName = _sentinel,
    Object? collectionSource = _sentinel,
    bool? nsfw,
    List<String>? tags,
    List<MintTraitInput>? traits,
    String? royaltyPercent,
    List<MintCreatorInput>? creators,
    Object? txFees = _sentinel,
    MintPipelineStatus? pipelineStatus,
    Object? pipelineError = _sentinel,
    Object? pipelineFailure = _sentinel,
    Object? pipelineStage = _sentinel,
    Object? mintAccount = _sentinel,
    Object? mintSignature = _sentinel,
    Object? indexed = _sentinel,
    Object? editMintAccount = _sentinel,
    Object? editTokenStandard = _sentinel,
    bool? isMasterEditionEdit,
    int? editCurrentSupply,
    bool? editIsMutable,
    Object? editUpdateAuthority = _sentinel,
    Object? existingImageUrl = _sentinel,
    Object? existingThumbnailUrl = _sentinel,
    Object? existingProcessVideoUrl = _sentinel,
    Object? existingBannerUrl = _sentinel,
    bool? existingMainAssetIsVideo,
    Map<String, String>? existingFileTypesByUri,
    bool? unlockableContentUnknown,
    bool? editPrefillLoading,
    Object? existingMetadataUri = _sentinel,
    Map<String, bool>? existingCreatorVerifiedByAddress,
    Object? preEditMetadataJson = _sentinel,
    Object? preEditMaxSupply = _sentinel,
    Object? preEditCollectionMint = _sentinel,
    bool? isSimulatingTxCost,
    Object? simulatedTxCostLamports = _sentinel,
  }) => MintState(
    step: step ?? this.step,
    userPubkey: userPubkey ?? this.userPubkey,
    mintType: mintType ?? this.mintType,
    editionType: editionType ?? this.editionType,
    editionSupply: editionSupply ?? this.editionSupply,
    mainAsset: identical(mainAsset, _sentinel)
        ? this.mainAsset
        : mainAsset as PickedMintAsset?,
    thumbnail: identical(thumbnail, _sentinel)
        ? this.thumbnail
        : thumbnail as PickedMintAsset?,
    processVideo: identical(processVideo, _sentinel)
        ? this.processVideo
        : processVideo as PickedMintAsset?,
    banner: identical(banner, _sentinel)
        ? this.banner
        : banner as PickedMintAsset?,
    exclusiveContentFiles: exclusiveContentFiles ?? this.exclusiveContentFiles,
    exclusiveContentExistingIds:
        exclusiveContentExistingIds ?? this.exclusiveContentExistingIds,
    name: name ?? this.name,
    description: description ?? this.description,
    collection: identical(collection, _sentinel)
        ? this.collection
        : collection as MintCollectionRef?,
    collectionName: identical(collectionName, _sentinel)
        ? this.collectionName
        : collectionName as String?,
    collectionSource: identical(collectionSource, _sentinel)
        ? this.collectionSource
        : collectionSource as CollectionPreviewRender?,
    nsfw: nsfw ?? this.nsfw,
    tags: tags ?? this.tags,
    traits: traits ?? this.traits,
    royaltyPercent: royaltyPercent ?? this.royaltyPercent,
    creators: creators ?? this.creators,
    txFees: identical(txFees, _sentinel) ? this.txFees : txFees as TxFees?,
    pipelineStatus: pipelineStatus ?? this.pipelineStatus,
    pipelineError: identical(pipelineError, _sentinel)
        ? this.pipelineError
        : pipelineError as String?,
    pipelineFailure: identical(pipelineFailure, _sentinel)
        ? this.pipelineFailure
        : pipelineFailure as AppFailure?,
    pipelineStage: identical(pipelineStage, _sentinel)
        ? this.pipelineStage
        : pipelineStage as String?,
    mintAccount: identical(mintAccount, _sentinel)
        ? this.mintAccount
        : mintAccount as String?,
    mintSignature: identical(mintSignature, _sentinel)
        ? this.mintSignature
        : mintSignature as String?,
    indexed: identical(indexed, _sentinel) ? this.indexed : indexed as bool?,
    editMintAccount: identical(editMintAccount, _sentinel)
        ? this.editMintAccount
        : editMintAccount as String?,
    editTokenStandard: identical(editTokenStandard, _sentinel)
        ? this.editTokenStandard
        : editTokenStandard as TokenStandard?,
    isMasterEditionEdit: isMasterEditionEdit ?? this.isMasterEditionEdit,
    editCurrentSupply: editCurrentSupply ?? this.editCurrentSupply,
    editIsMutable: editIsMutable ?? this.editIsMutable,
    editUpdateAuthority: identical(editUpdateAuthority, _sentinel)
        ? this.editUpdateAuthority
        : editUpdateAuthority as String?,
    existingImageUrl: identical(existingImageUrl, _sentinel)
        ? this.existingImageUrl
        : existingImageUrl as String?,
    existingThumbnailUrl: identical(existingThumbnailUrl, _sentinel)
        ? this.existingThumbnailUrl
        : existingThumbnailUrl as String?,
    existingProcessVideoUrl: identical(existingProcessVideoUrl, _sentinel)
        ? this.existingProcessVideoUrl
        : existingProcessVideoUrl as String?,
    existingBannerUrl: identical(existingBannerUrl, _sentinel)
        ? this.existingBannerUrl
        : existingBannerUrl as String?,
    existingMainAssetIsVideo:
        existingMainAssetIsVideo ?? this.existingMainAssetIsVideo,
    existingFileTypesByUri:
        existingFileTypesByUri ?? this.existingFileTypesByUri,
    unlockableContentUnknown:
        unlockableContentUnknown ?? this.unlockableContentUnknown,
    editPrefillLoading: editPrefillLoading ?? this.editPrefillLoading,
    existingMetadataUri: identical(existingMetadataUri, _sentinel)
        ? this.existingMetadataUri
        : existingMetadataUri as String?,
    existingCreatorVerifiedByAddress:
        existingCreatorVerifiedByAddress ??
        this.existingCreatorVerifiedByAddress,
    preEditMetadataJson: identical(preEditMetadataJson, _sentinel)
        ? this.preEditMetadataJson
        : preEditMetadataJson as Map<String, dynamic>?,
    preEditMaxSupply: identical(preEditMaxSupply, _sentinel)
        ? this.preEditMaxSupply
        : preEditMaxSupply as int?,
    preEditCollectionMint: identical(preEditCollectionMint, _sentinel)
        ? this.preEditCollectionMint
        : preEditCollectionMint as String?,
    isSimulatingTxCost: isSimulatingTxCost ?? this.isSimulatingTxCost,
    simulatedTxCostLamports: identical(simulatedTxCostLamports, _sentinel)
        ? this.simulatedTxCostLamports
        : simulatedTxCostLamports as int?,
  );

  @override
  List<Object?> get props => [
    step,
    userPubkey,
    mintType,
    editionType,
    editionSupply,
    mainAsset,
    thumbnail,
    processVideo,
    banner,
    exclusiveContentFiles,
    exclusiveContentExistingIds,
    name,
    description,
    collection,
    collectionName,
    collectionSource,
    nsfw,
    tags,
    traits,
    royaltyPercent,
    creators,
    txFees,
    pipelineStatus,
    pipelineError,
    pipelineFailure,
    pipelineStage,
    mintAccount,
    mintSignature,
    indexed,
    editMintAccount,
    editTokenStandard,
    isMasterEditionEdit,
    editCurrentSupply,
    editIsMutable,
    editUpdateAuthority,
    existingImageUrl,
    existingThumbnailUrl,
    existingProcessVideoUrl,
    existingBannerUrl,
    existingMainAssetIsVideo,
    existingFileTypesByUri,
    unlockableContentUnknown,
    editPrefillLoading,
    existingMetadataUri,
    existingCreatorVerifiedByAddress,
    preEditMetadataJson,
    preEditMaxSupply,
    preEditCollectionMint,
    isSimulatingTxCost,
    simulatedTxCostLamports,
  ];

  /// Build the 4-line cost breakdown shown in the confirmation sheet.
  ///
  /// Mirrors `ReadyToMint` in the webapp: mallow fee (from
  /// `/v0/txFees`), Metaplex protocol fee + rent (hardcoded per token
  /// standard), Solana tx fee (`targetPriorityFeeLamports` + 5000 base).
  /// In edit mode the mallow fee line uses `txFees.edit` instead of
  /// `txFees.mint`.
  MintCostBreakdown get costBreakdown {
    final mallowSol = isEdit ? txFees?.edit : txFees?.mint;
    final mallowLamports = mallowSol == null
        ? 0
        : (mallowSol * kLamportsPerSol).round();
    // Editions and Collections both land as `CoreCollection` on-chain.
    final isCoreCollection =
        mintType == MintCreateType.editions ||
        mintType == MintCreateType.collection;
    final rentLamports = isCoreCollection
        ? kCoreCollectionRentLamports
        : kCoreRentLamports;
    return MintCostBreakdown(
      mallowFeeLamports: mallowLamports,
      protocolFeeLamports: kCoreProtocolFeeLamports,
      rentLamports: rentLamports,
      txFeeLamports: kDefaultPriorityFeeLamports + kBaseSolanaTxFeeLamports,
    );
  }

  /// Steps that participate in the visible flow given the current
  /// [mintType]. The [MintStep.editionSupply] step is hidden for 1/1.
  List<MintStep> get visibleSteps => MintStep.values
      .where(
        (s) =>
            s != MintStep.editionSupply || mintType == MintCreateType.editions,
      )
      .toList(growable: false);

  /// True when the bloc is operating on an existing asset.
  bool get isEdit => editMintAccount != null;

  /// True when the form has diverged from the prefilled snapshot — i.e.
  /// the edit would produce a real on-chain change. Mirrors the webapp's
  /// `editContext.requiresUpdate` (CreateContext). Always
  /// true in create mode; in edit mode, returns false when *every*
  /// signal we track (picked files, maxSupply, collection, JSON shape)
  /// matches the prefill.
  bool get requiresUpdate {
    if (!isEdit) return true;
    if (mainAsset != null) return true;
    if (thumbnail != null) return true;
    if (processVideo != null) return true;
    if (banner != null) return true;
    if (preEditMaxSupply != maxSupplyForRequest) return true;
    if (preEditCollectionMint != collection?.mintAccount) return true;
    final preJson = preEditMetadataJson;
    if (preJson == null) return true;
    return !const DeepCollectionEquality().equals(preJson, toMetadataJson());
  }

  /// Are we allowed to advance from the current step?
  bool get canGoNext => switch (step) {
    MintStep.upload =>
      mintType == MintCreateType.collection
          // Collections require both the banner and main image; image-only
          // formats mean no thumbnail-fallback gating applies. Edit mode
          // can fall back to the on-chain URLs when the user doesn't
          // re-pick.
          ? (mainAsset != null || (isEdit && existingImageUrl != null)) &&
                (banner != null || (isEdit && existingBannerUrl != null))
          : (mainAsset != null &&
                    (!mainAsset!.needsThumbnail || thumbnail != null)) ||
                // Edit mode: an existing image is always present, the user
                // doesn't have to re-pick to advance.
                (isEdit && existingImageUrl != null),
    MintStep.details => name.trim().isNotEmpty && description.trim().isNotEmpty,
    MintStep.categorization => traitsError == null,
    MintStep.royalties =>
      royaltyPercent.trim().isNotEmpty &&
          royaltyError == null &&
          creatorsError == null,
    MintStep.editionSupply => switch (editionType) {
      MintEditionType.open => true,
      MintEditionType.limited => () {
        final n = int.tryParse(editionSupply.trim());
        // Webapp parity: Limited Edition supply ∈ [2, 10000]
        // (`Supply` enforces `>= 2`; `EditionsFields` caps at 10k).
        if (n == null || n < 2 || n > 10000) return false;
        // Edit mode additionally can't cap supply below what has already
        // been printed (`Supply`:
        // `maxSupply == null || maxSupply >= nftRender.supply`). mpl-core
        // rejects the underflow, so without this gate the creator pays a
        // signature and the tx fees for a transaction that can only fail.
        // (The webapp drops its `>= 2` floor on an edit, which would admit a
        // 0/1 max supply for a not-yet-printed master edition; keeping the
        // floor here is strictly the safer side of that difference.)
        return !isEdit || n >= editCurrentSupply;
      }(),
    },
    MintStep.review => true,
  };

  /// 0..1 progress fraction for the top progress bar.
  ///
  /// Create flow: `visibleSteps.length + 2` positions — mint-type chooser
  /// (slot 1), form steps (slots 2..n+1), success (final slot). The screen
  /// picks up where the chooser left off; the final fill is reserved for
  /// success.
  ///
  /// Edit flow skips the chooser entirely, so the form starts at slot 1
  /// of `visibleSteps.length + 1`.
  double get progressFraction {
    if (pipelineStatus == MintPipelineStatus.success) return 1.0;
    final visible = visibleSteps;
    final idx = visible.indexOf(step);
    if (idx < 0) return 0;
    if (isEdit) return (idx + 1) / (visible.length + 1);
    return (idx + 2) / (visible.length + 2);
  }

  /// Trait validation — null when valid. Collections only carry trait names
  /// (per-token values are filled in when artworks mint into the collection),
  /// so the rule only applies to artwork mints.
  String? get traitsError {
    if (mintType == MintCreateType.collection) return null;
    final hasMissingValue = traits.any(
      (t) => t.name.trim().isNotEmpty && t.value.trim().isEmpty,
    );
    return hasMissingValue ? 'Each trait needs a value' : null;
  }

  /// Royalty validation — null when valid.
  String? get royaltyError {
    final parsed = double.tryParse(royaltyPercent.trim());
    if (royaltyPercent.trim().isEmpty) return null; // 0% is valid
    if (parsed == null) return 'Enter a valid percentage';
    if (parsed < 0 || parsed > 15) return 'Royalties must be between 0 and 15%';
    return null;
  }

  /// Creator-split validation — null when valid.
  String? get creatorsError {
    if (creators.isEmpty) return null;
    var total = 0;
    final addresses = <String>{};
    for (final c in creators) {
      if (c.address.trim().isEmpty) return 'Each wallet needs an address';
      // Decode-validate, matching the webapp's `new PublicKey(address)` guard
      // in `Royalties`. A creator address is written into immutable
      // on-chain metadata: a typo that only fails the character-class check
      // costs a real mint and sends every future royalty payment nowhere.
      if (!SecurityUtils.isValidSolanaAddress(c.address.trim())) {
        return 'Creator address is invalid';
      }
      if (!addresses.add(c.address.trim())) return 'Duplicate wallet address';
      final share = int.tryParse(c.shareText.trim());
      if (share == null || share < 0 || share > 100) {
        return 'Shares must be whole numbers 0–100';
      }
      total += share;
    }
    if (total != 100) return 'Proceed splits must add up to 100%';
    return null;
  }

  /// Ordered `properties.files` payload for the metadata JSON.
  ///
  /// Order is load-bearing: **entry 0 is the primary asset**, which is what
  /// `buildTokenMetadataJson` reads `properties.category` and `animation_url`
  /// off. It mirrors the webapp's per-flow asset lists — `Mint` /
  /// `EditNft` push `[artwork, thumbnail?, processVideo?]`;
  /// `MintCollection` / `EditCollection` push `[image, banner?]`.
  ///
  /// Freshly picked files contribute their own mime type; existing (not
  /// re-picked) URLs resolve theirs through [existingFileTypesByUri], falling
  /// back to a per-slot default. The default only has to land in the right
  /// *category* — no consumer reads the exact subtype.
  List<MintMetadataFile> get metadataAssets {
    final out = <MintMetadataFile>[];

    void add(String? uri, String? mimeType, String fallbackMimeType) {
      if (uri == null || uri.isEmpty) return;
      out.add(
        MintMetadataFile(
          uri: uri,
          type: mimeType ?? existingFileTypesByUri[uri] ?? fallbackMimeType,
        ),
      );
    }

    final mainUrl = mainAsset?.ipfsUrl ?? (isEdit ? existingImageUrl : null);
    add(
      mainUrl,
      mainAsset?.mimeType,
      existingMainAssetIsVideo ? 'video/mp4' : 'image/png',
    );

    if (mintType == MintCreateType.collection) {
      add(
        banner?.ipfsUrl ?? (isEdit ? existingBannerUrl : null),
        banner?.mimeType,
        'image/png',
      );
      return out;
    }

    // The existing thumbnail carries forward whenever the *resolved* primary
    // still needs one — not only when nothing was re-picked. Re-picking just
    // the artwork (a new video) leaves `thumbnail` null, and dropping the
    // existing URL there ships a `files` list with no image at all, so
    // `buildTokenMetadataJson`'s first-image-wins pass emits `image: null` and
    // the artwork loses its card image on an immutable URI. A re-picked *still
    // image* still drops it (mirrors `_onPickMainAsset` clearing a stale
    // picked thumbnail) — that primary is its own image.
    add(
      thumbnail?.ipfsUrl ??
          (isEdit && (mainAsset == null || mainAsset!.needsThumbnail)
              ? existingThumbnailUrl
              : null),
      thumbnail?.mimeType,
      'image/png',
    );
    add(
      processVideo?.ipfsUrl ?? (isEdit ? existingProcessVideoUrl : null),
      processVideo?.mimeType,
      'video/mp4',
    );
    return out;
  }

  /// Convert the form state into an `nftMetadata` payload for the
  /// create-asset request.
  MintNftMetadata toNftMetadata() {
    final sellerFeeBps = () {
      final pct = double.tryParse(royaltyPercent.trim()) ?? 0;
      return (pct * 100).round().clamp(0, 1500);
    }();

    final apiCreators = creators.map((c) {
      final addr = c.address.trim();
      // Edit mode (token-metadata): preserve the original `verified`
      // flag for any creator that was already on-chain. The chain only
      // lets a creator flip their own verified flag while signing —
      // sending a different value for someone else fails the tx.
      final preservedVerified = existingCreatorVerifiedByAddress[addr];
      final verified = preservedVerified ?? c.isSelf;
      return MintCreator(
        address: addr,
        share: int.tryParse(c.shareText.trim()) ?? 0,
        verified: verified,
      );
    }).toList();

    // For collections, `value` is irrelevant — the on-chain JSON omits it
    // via `toMetadataJson`.
    //
    // Edit mode: when the user hasn't picked a new file we send the
    // existing IPFS URL so the backend's metadata diff doesn't see a
    // bogus change. Mirrors the webapp's behavior of reusing the
    // pre-edit `image` / `animation_url` / `processVideo` fields.
    final mainUrl = mainAsset?.ipfsUrl ?? (isEdit ? existingImageUrl : null);
    final thumbnailUrl =
        thumbnail?.ipfsUrl ??
        (isEdit && (mainAsset == null || mainAsset!.needsThumbnail)
            ? existingThumbnailUrl
            : null);
    final processVideoUrl =
        processVideo?.ipfsUrl ?? (isEdit ? existingProcessVideoUrl : null);
    final bannerUrl = banner?.ipfsUrl ?? (isEdit ? existingBannerUrl : null);
    final assets = metadataAssets;
    final primaryCategory = assets.isEmpty
        ? null
        : mintFileCategoryForMimeType(assets.first.type);
    final extended = MintExtendedMetadata(
      description: description,
      attributes: traits
          .where((t) => t.name.trim().isNotEmpty)
          .map((t) => NftAttribute(traitType: t.name.trim(), value: t.value))
          .toList(),
      // Image vs animation_url: when the main asset is a video the URL
      // primarily belongs in `animation_url`; the dedicated thumbnail
      // (or a still frame from the same source) goes in `image`. In
      // edit mode we preserve whichever shape the existing JSON used.
      image: thumbnailUrl ?? mainUrl,
      banner: bannerUrl,
      // Derived from the resolved primary asset's category, not from
      // `mainAsset` — in edit mode nothing is re-picked, so keying off the
      // picked file dropped `video` (and with it `animation_url`) from every
      // edit of a video artwork.
      video: primaryCategory == MintFileCategory.video ? mainUrl : null,
      processVideo: processVideoUrl,
      tags: tags,
      nsfw: nsfw || tags.contains(_nsfwTag),
    );

    return MintNftMetadata(
      name: name.trim(),
      sellerFeeBasisPoints: sellerFeeBps,
      creators: apiCreators,
      extendedMetadata: extended,
      // Webapp parity (Mint): 1/1 → 0, Limited → count, Open → null.
      maxSupply: maxSupplyForRequest,
    );
  }

  /// Wire-format `maxSupply` for the create-asset request.
  ///
  /// Mirrors `Mint`:
  /// 1/1 always sends `0`; Open Edition sends `null` (server treats this
  /// as unlimited); Limited sends the parsed integer.
  int? get maxSupplyForRequest => switch (mintType) {
    MintCreateType.editions => switch (editionType) {
      MintEditionType.open => null,
      MintEditionType.limited => int.tryParse(editionSupply.trim()) ?? 0,
    },
    _ => 0,
  };

  /// Serialize the metadata for IPFS upload.
  ///
  /// Delegates to [buildTokenMetadataJson], the port of the webapp's
  /// `tokenMetadata`, so the pinned JSON carries `properties.files`
  /// and a real `properties.category` — the only two fields the indexer
  /// derives an artwork's media type and playable URLs from.
  ///
  /// `seller_fee_basis_points` and `properties.creators` are deliberately
  /// **not** emitted: the webapp never writes them (royalties live on-chain),
  /// and emitting them made every mobile-minted artwork fail the webapp's
  /// `requiresMetadataUpdate` deep-equality check.
  Map<String, dynamic> toMetadataJson() {
    final meta = toNftMetadata();
    final isCollection = mintType == MintCreateType.collection;
    return buildTokenMetadataJson(
      assets: metadataAssets,
      name: meta.name,
      description: meta.extendedMetadata.description,
      // For collections, omit `value` so the on-chain JSON has trait names
      // only — per-token values are populated when artworks are minted in.
      attributes: meta.extendedMetadata.attributes
          .map(
            (a) => isCollection
                ? {'trait_type': a.traitType}
                : {'trait_type': a.traitType, 'value': a.value},
          )
          .toList(),
      tags: meta.extendedMetadata.tags,
      nsfw: meta.extendedMetadata.nsfw,
      banner: meta.extendedMetadata.banner,
      processVideoUri: meta.extendedMetadata.processVideo,
    );
  }
}

/// Bloc that owns the mint form state and orchestrates the mint pipeline.
///
/// Instantiate per-route via `BlocProvider` so each opening of the flow
/// starts fresh. The [userPubkey] seeds the read-only creator row and the
/// collection-picker query.
@injectable
class MintBloc extends Bloc<MintEvent, MintState> {
  MintBloc(
    this._repository,
    this._walletManager,
    this._rpcService,
    this._editPrefill,
    this._pipeline,
    this._priceService,
    this._feeConfig,
    this._executor,
  ) : super(const MintState()) {
    on<MintStarted>(_onStarted);
    on<MintStartedForEdit>(_onStartedForEdit);
    on<MintEditPrefilled>(_onEditPrefilled);
    on<MintNext>(_onNext);
    on<MintBack>(_onBack);
    on<MintGotoStep>(_onGotoStep);

    on<MintPickMainAsset>(_onPickMainAsset);
    on<MintPickThumbnail>(
      (e, emit) => emit(state.copyWith(thumbnail: e.asset)),
    );
    on<MintPickProcessVideo>(
      (e, emit) => emit(state.copyWith(processVideo: e.asset)),
    );
    on<MintPickBanner>((e, emit) => emit(state.copyWith(banner: e.asset)));
    on<MintClearThumbnail>((_, emit) => emit(state.copyWith(thumbnail: null)));
    on<MintClearProcessVideo>(
      (_, emit) => emit(state.copyWith(processVideo: null)),
    );
    on<MintClearBanner>((_, emit) => emit(state.copyWith(banner: null)));
    on<MintAddExclusiveContent>(
      (e, emit) => emit(
        state.copyWith(
          exclusiveContentFiles: [...state.exclusiveContentFiles, e.asset],
        ),
      ),
    );
    on<MintRemoveExclusiveContent>((e, emit) {
      final next = [...state.exclusiveContentFiles]..removeAt(e.index);
      emit(state.copyWith(exclusiveContentFiles: next));
    });
    on<MintToggleExistingExclusive>((e, emit) {
      final ids = {...state.exclusiveContentExistingIds};
      ids.contains(e.id) ? ids.remove(e.id) : ids.add(e.id);
      emit(state.copyWith(exclusiveContentExistingIds: ids.toList()));
    });

    on<MintSetName>((e, emit) {
      final clipped = e.value.length > 32 ? e.value.substring(0, 32) : e.value;
      emit(state.copyWith(name: clipped));
    });
    on<MintSetDescription>((e, emit) {
      final clipped = e.value.length > 1000
          ? e.value.substring(0, 1000)
          : e.value;
      emit(state.copyWith(description: clipped));
    });
    on<MintSetCollection>(_onSetCollection);
    on<MintToggleNsfw>((_, emit) {
      final next = !state.nsfw;
      final tags = next
          ? (state.tags.contains(_nsfwTag)
                ? state.tags
                : [...state.tags, _nsfwTag])
          : state.tags.where((t) => t != _nsfwTag).toList();
      emit(state.copyWith(nsfw: next, tags: tags));
    });

    on<MintSetCategories>((e, emit) {
      // [e.categories] are picker display names — convert to canonical ids and
      // splice them in alongside any non-category tags already present.
      final ids = e.categories.map(mintCategoryIdFor).toList();
      final preserved = state.tags
          .where((t) => !mintCategoryIdSet.contains(t))
          .toList();
      emit(state.copyWith(tags: [...preserved, ...ids]));
    });
    on<MintAddTag>((e, emit) {
      final tag = e.tag.trim().replaceAll('#', '');
      if (tag.isEmpty || state.tags.contains(tag)) return;
      emit(
        state.copyWith(
          tags: [...state.tags, tag],
          nsfw: state.nsfw || tag == _nsfwTag,
        ),
      );
    });
    on<MintRemoveTag>(
      (e, emit) => emit(
        state.copyWith(
          tags: state.tags.where((t) => t != e.tag).toList(),
          nsfw: e.tag == _nsfwTag ? false : state.nsfw,
        ),
      ),
    );
    on<MintAddTrait>((e, emit) {
      final name = e.name.trim();
      if (name.isEmpty) return;
      emit(
        state.copyWith(
          traits: [
            ...state.traits,
            MintTraitInput(name: name),
          ],
        ),
      );
    });
    on<MintSetTraitValue>((e, emit) {
      final next = [...state.traits];
      if (e.index < 0 || e.index >= next.length) return;
      next[e.index] = next[e.index].copyWith(value: e.value);
      emit(state.copyWith(traits: next));
    });
    on<MintRemoveTrait>((e, emit) {
      if (e.index < 0 || e.index >= state.traits.length) return;
      final next = [...state.traits]..removeAt(e.index);
      emit(state.copyWith(traits: next));
    });

    on<MintSetRoyaltyPercent>(
      (e, emit) => emit(state.copyWith(royaltyPercent: e.raw)),
    );
    on<MintAddCreator>((_, emit) {
      if (state.creators.length >= 5) return;
      emit(
        state.copyWith(
          creators: [
            ...state.creators,
            const MintCreatorInput(address: '', shareText: ''),
          ],
        ),
      );
    });
    on<MintSetCreatorAddress>((e, emit) {
      final next = [...state.creators];
      if (e.index <= 0 || e.index >= next.length) return; // self row locked
      next[e.index] = next[e.index].copyWith(address: e.address);
      emit(state.copyWith(creators: next));
    });
    on<MintSetCreatorShare>((e, emit) {
      final next = [...state.creators];
      if (e.index < 0 || e.index >= next.length) return;
      next[e.index] = next[e.index].copyWith(shareText: e.raw);
      emit(state.copyWith(creators: next));
    });
    on<MintRemoveCreator>((e, emit) {
      if (e.index <= 0 || e.index >= state.creators.length) return;
      final next = [...state.creators]..removeAt(e.index);
      emit(state.copyWith(creators: next));
    });

    on<MintSetMintType>((e, emit) => emit(state.copyWith(mintType: e.type)));
    on<MintSetEditionType>((e, emit) {
      // Switching to Open clears any stale Limited-supply input so we
      // never leak an unintended maxSupply into the create-asset call.
      emit(
        state.copyWith(
          editionType: e.type,
          editionSupply: e.type == MintEditionType.open
              ? ''
              : state.editionSupply,
        ),
      );
    });
    on<MintSetEditionSupply>(
      (e, emit) => emit(state.copyWith(editionSupply: e.raw)),
    );

    on<MintRequestMint>(
      (_, emit) => emit(
        state.copyWith(
          pipelineStatus: MintPipelineStatus.idle,
          pipelineError: null,
          pipelineFailure: null,
        ),
      ),
    );
    on<MintSourceWalletChanged>(_onSourceWalletChanged);
    on<MintSimulateTxCost>(_onSimulateTxCost);
    on<MintConfirmMint>(_onConfirmMint);
    on<MintRetryMint>(_onConfirmMint);
    on<MintIndexedAck>(_onIndexedAck);
    on<MintDismissError>(
      (_, emit) => emit(
        state.copyWith(
          pipelineStatus: MintPipelineStatus.idle,
          pipelineError: null,
          pipelineFailure: null,
        ),
      ),
    );
    on<MintReset>(
      (_, emit) => emit(
        MintState(
          userPubkey: state.userPubkey,
          creators: [MintCreatorInput(address: state.userPubkey, isSelf: true)],
        ),
      ),
    );
  }

  final MintRepository _repository;
  final WalletManager _walletManager;
  final SolanaRpcService _rpcService;
  final EditNftPrefillService _editPrefill;
  final TransactionPipeline _pipeline;
  final TokenPriceService _priceService;
  final FeeConfig _feeConfig;
  final TransactionExecutor _executor;

  Future<void> _onStartedForEdit(
    MintStartedForEdit event,
    Emitter<MintState> emit,
  ) async {
    // Flip the loading flag synchronously so the upload-step skeletons
    // appear immediately — the wallet address + DAS fetches below would
    // otherwise leave the dropzones blank for a frame or two.
    // Collection edits also seed `mintType` here so the collection form
    // variant (banner dropzone, collection labels) renders during the
    // prefill fetch; `_onEditPrefilled` keeps it (the prefill alone can't
    // identify legacy token-metadata collection NFTs).
    emit(
      state.copyWith(
        editPrefillLoading: true,
        mintType: event.isCollection
            ? MintCreateType.collection
            : state.mintType,
      ),
    );

    // Hydrate the active wallet pubkey first so the creator self-row
    // marking lines up correctly when the prefill creators arrive.
    String? address;
    try {
      address = await _walletManager.getAddress();
    } catch (_) {
      address = null;
    }
    emit(state.copyWith(userPubkey: address ?? ''));

    // Fees fetch runs in parallel with prefill; both are best-effort.
    final feesFuture = _repository.fetchTxFees();

    // Which unlockable-content records are attached to this asset. Must be
    // known before an edit can be built — see [MintState.unlockableContentUnknown].
    // Collection edits skip it: the v2 edit route rejects
    // `unlockableContentIds` for `editTarget=parent_collection`, and a
    // collection mint isn't in the artwork index to look up anyway.
    final unlockableFuture = event.isCollection
        ? Future<List<int>?>.value(const <int>[])
        : _repository.fetchAttachedUnlockableContentIds(event.mintAccount);

    final prefillResult = await Result.guard(
      () => _editPrefill.load(event.mintAccount),
    );
    final EditNftPrefill prefill;
    switch (prefillResult) {
      case ResultSuccess(:final value):
        prefill = value;
      case ResultFailure(:final error):
        emit(
          state.copyWith(
            pipelineStatus: MintPipelineStatus.error,
            pipelineError: 'Could not load asset: ${error.message}',
            pipelineFailure: null,
            editPrefillLoading: false,
          ),
        );
        return;
    }

    final attachedUnlockableIds = await unlockableFuture;
    if (isClosed) return;
    emit(
      state.copyWith(
        exclusiveContentExistingIds: attachedUnlockableIds ?? const <int>[],
        unlockableContentUnknown: attachedUnlockableIds == null,
      ),
    );
    add(MintEditPrefilled(prefill));

    try {
      final fees = await feesFuture;
      if (!isClosed) emit(state.copyWith(txFees: fees));
    } catch (_) {
      // Fees are optional; the cost breakdown falls back to zero.
    }
  }

  void _onEditPrefilled(MintEditPrefilled event, Emitter<MintState> emit) {
    final p = event.prefill;
    final user = state.userPubkey;

    // Build creator inputs from the prefill, marking the active wallet
    // as `isSelf`. If the user isn't a creator we still surface them
    // as the implicit signer — but unlike the create flow, we do not
    // auto-add them to the royalty splits (that would change shares).
    final creatorInputs = <MintCreatorInput>[];
    final verifiedMap = <String, bool>{};
    for (final c in p.creators) {
      verifiedMap[c.address] = c.verified;
      creatorInputs.add(
        MintCreatorInput(
          address: c.address,
          shareText: c.share.toString(),
          isSelf: c.address == user,
        ),
      );
    }
    final selfIdx = creatorInputs.indexWhere((c) => c.isSelf);
    if (selfIdx > 0) {
      final self = creatorInputs.removeAt(selfIdx);
      creatorInputs.insert(0, self);
    }

    final royaltyPct = _bpsToPercentText(p.sellerFeeBasisPoints);

    // Determine mintType from the prefill so the right form variant
    // shows up (mirrors the reference web client's `setCreateType`):
    //  - `coreCollection + masterEdition plugin` → Editions
    //  - `coreCollection` without master-edition plugin → Collection
    //  - everything else → 1/1 (legacy `maxSupply != 0` editions don't
    //    apply to the v2 edit pipeline today).
    //
    // An explicit collection-edit intent (`startedForEdit(isCollection:
    // true)` seeded `mintType` before the prefill) wins over the 1/1
    // fallback: a legacy token-metadata collection NFT is
    // indistinguishable from a plain NFT in DAS data. Master-edition
    // still takes priority — the backend rejects parent-collection
    // edits on master editions.
    final isCollectionIntent =
        state.mintType == MintCreateType.collection || p.isCollection;
    final mintType = p.isMasterEdition
        ? MintCreateType.editions
        : isCollectionIntent
        ? MintCreateType.collection
        : MintCreateType.oneOfOne;
    final editionType = p.isMasterEdition && p.maxSupply == null
        ? MintEditionType.open
        : MintEditionType.limited;
    final editionSupplyText = p.isMasterEdition && p.maxSupply != null
        ? p.maxSupply.toString()
        : '';

    final prefilledState = state.copyWith(
      editPrefillLoading: false,
      editMintAccount: p.mintAccount,
      editTokenStandard: p.tokenStandard,
      isMasterEditionEdit: p.isMasterEdition,
      editCurrentSupply: p.currentSupply,
      editIsMutable: p.isMutable,
      editUpdateAuthority: p.updateAuthority,
      existingImageUrl: p.existingImageUrl,
      existingThumbnailUrl: p.existingThumbnailUrl,
      existingProcessVideoUrl: p.existingProcessVideoUrl,
      existingBannerUrl: p.existingBannerUrl,
      existingMainAssetIsVideo: p.isMainAssetVideo,
      existingFileTypesByUri: p.existingFileTypesByUri,
      existingMetadataUri: p.existingUri,
      existingCreatorVerifiedByAddress: verifiedMap,
      name: p.name,
      description: p.description,
      traits: p.attributes
          .map((a) => MintTraitInput(name: a.traitType, value: a.value ?? ''))
          .toList(growable: false),
      tags: p.tags,
      nsfw: p.nsfw,
      royaltyPercent: royaltyPct,
      creators: creatorInputs,
      mintType: mintType,
      editionType: editionType,
      editionSupply: editionSupplyText,
      collection: p.collection,
      collectionName: p.collectionName,
    );

    // Snapshot what the form would emit *right now*, before any user
    // edits — used at confirm time to (a) skip the metadata IPFS
    // re-upload and (b) short-circuit the whole tx when nothing
    // changed. Mirrors webapp's `setPreEditNftMetadata(cloneDeep(...))`
    // in CreateContext.onEditAssetFetched.
    final preEditJson = prefilledState.toMetadataJson();
    emit(
      prefilledState.copyWith(
        preEditMetadataJson: preEditJson,
        preEditMaxSupply: prefilledState.maxSupplyForRequest,
        preEditCollectionMint: p.collection?.mintAccount,
      ),
    );
  }

  Future<void> _onStarted(MintStarted _, Emitter<MintState> emit) async {
    if (state.userPubkey.isNotEmpty) return;

    // Kick off the fee fetch in parallel, but emit the address as soon as
    // it resolves so UI gated on `userPubkey` (collection picker, creator
    // row) isn't held up by the network call.
    final feesFuture = _repository.fetchTxFees();

    String? address;
    try {
      address = await _walletManager.getAddress();
    } catch (_) {
      address = null;
    }

    emit(
      state.copyWith(
        userPubkey: address ?? '',
        creators: address == null
            ? state.creators
            : [
                MintCreatorInput(address: address, isSelf: true),
                ...state.creators.where((c) => !c.isSelf),
              ],
      ),
    );

    try {
      final fees = await feesFuture;
      emit(state.copyWith(txFees: fees));
    } catch (_) {
      // Fees are optional for the form itself; confirmation sheet will
      // fall back to a zero breakdown if this fails.
    }
  }

  /// Re-derive everything the form computed for the previously-active wallet
  /// after the source picker committed a switch.
  ///
  /// The address is re-read from [WalletManager.getAddress] (the DB selection
  /// the tx builders themselves read) rather than taken from the picker, so the
  /// creator this form shows and the creator the mint is built for can never
  /// disagree. A wallet that fails to resolve leaves the form untouched — the
  /// picker only reports a switch that committed, but a stale creator is worse
  /// than no change at all.
  Future<void> _onSourceWalletChanged(
    MintSourceWalletChanged _,
    Emitter<MintState> emit,
  ) async {
    // Edit mode has no wallet choice: the authority must be the asset's own
    // update authority. The affordance isn't rendered there; this is the guard.
    if (state.isEdit) return;

    String? address;
    try {
      address = await _walletManager.getAddress();
    } catch (_) {
      address = null;
    }
    if (address == null || address.isEmpty || address == state.userPubkey) {
      return;
    }

    // Move the self row onto the new wallet, keeping its share and any
    // co-creators the user added by hand. Drop a co-creator row that already
    // holds the new address so it can't appear twice in the royalty splits.
    final selfIdx = state.creators.indexWhere((c) => c.isSelf);
    final self = selfIdx == -1 ? null : state.creators[selfIdx];
    final others = [
      for (final c in state.creators)
        if (!c.isSelf && c.address.trim() != address) c,
    ];
    final hadCollection = state.collection != null;

    emit(
      state.copyWith(
        userPubkey: address,
        creators: [
          (self ?? const MintCreatorInput(address: '')).copyWith(
            address: address,
            isSelf: true,
          ),
          ...others,
        ],
        // Simulated against the previous payer — a fee quoted for one wallet
        // and signed by another is exactly the stale value this switch exists
        // to kill. Cleared here, refetched by the dispatch below.
        simulatedTxCostLamports: null,
      ),
    );

    // The collection picker only lists collections created by the previous
    // wallet, so a parent collection chosen there isn't mintable into by the
    // new one. Clear it through the normal reducer so royalties/creators fall
    // back to the same defaults a manual clear produces.
    if (hadCollection) add(const MintEvent.setCollection());
    add(const MintEvent.simulateTxCost());
  }

  void _onNext(MintNext event, Emitter<MintState> emit) {
    if (!state.canGoNext) return;
    var next = state.step.index + 1;
    while (next < MintStep.values.length &&
        _shouldSkip(MintStep.values[next])) {
      next++;
    }
    if (next >= MintStep.values.length) return;
    emit(state.copyWith(step: MintStep.values[next]));
  }

  void _onBack(MintBack event, Emitter<MintState> emit) {
    var prev = state.step.index - 1;
    while (prev >= 0 && _shouldSkip(MintStep.values[prev])) {
      prev--;
    }
    if (prev < 0) return;
    emit(state.copyWith(step: MintStep.values[prev]));
  }

  bool _shouldSkip(MintStep step) =>
      step == MintStep.editionSupply &&
      state.mintType != MintCreateType.editions;

  void _onGotoStep(MintGotoStep event, Emitter<MintState> emit) {
    emit(state.copyWith(step: event.step));
  }

  /// Mirror `CreateContext` — picking (or clearing) a parent
  /// collection auto-populates royalties, creator splits, tags, and trait
  /// names. On clear, royalties + creators reset to defaults; tags and
  /// trait names stick (webapp parity).
  void _onSetCollection(MintSetCollection event, Emitter<MintState> emit) {
    final source = event.source;

    // Edit mode never inherits the parent's royalties / creators / tags /
    // traits: `CreateContext` bails out of the whole effect when
    // `isEdit`. Re-parenting an existing artwork must only move it — silently
    // rewriting its on-chain royalty split and creator shares is not
    // recoverable, and mpl-core rejects the edit outright when the inherited
    // shares don't sum to 100.
    if (state.isEdit) {
      emit(
        state.copyWith(
          collection: event.collection,
          collectionName: event.name,
          collectionSource: source,
        ),
      );
      return;
    }

    final royalties = source?.nft?.royalties;

    // Creators: start from the collection's shares, ensure the connected
    // user is at index 0 marked as self.
    final creators = <MintCreatorInput>[];
    final shares = royalties?.shares ?? const <MintCreator>[];
    for (final s in shares) {
      creators.add(
        MintCreatorInput(
          address: s.address,
          shareText: s.share.toString(),
          isSelf: s.address == state.userPubkey,
        ),
      );
    }
    final selfIdx = creators.indexWhere((c) => c.address == state.userPubkey);
    if (selfIdx == -1 && state.userPubkey.isNotEmpty) {
      creators.insert(
        0,
        MintCreatorInput(address: state.userPubkey, isSelf: true),
      );
    } else if (selfIdx > 0) {
      final self = creators.removeAt(selfIdx);
      creators.insert(0, self);
    }
    if (creators.isEmpty) {
      // Defensive: no userPubkey yet — fall back to the existing default.
      creators.add(MintCreatorInput(address: state.userPubkey, isSelf: true));
    }

    // Royalty %: feeBPS → percent. Default 1000 bps (10%) when no royalties.
    final feeBps = royalties?.feeBPS ?? 1000;
    final royaltyPercent = _bpsToPercentText(feeBps);

    // Tags + traits: replace with the collection's when picking; stick when
    // clearing (Details strips inherited categories on clear via
    // a separate effect, but free-form tags + trait names are intentionally
    // preserved).
    final nextTags = source != null
        ? List<String>.from(source.tags)
        : state.tags;
    final nextTraits = source != null
        ? source.nft?.attributes
                  .where((a) => a.traitType.trim().isNotEmpty)
                  .map((a) => MintTraitInput(name: a.traitType))
                  .toList() ??
              const <MintTraitInput>[]
        : state.traits;

    emit(
      state.copyWith(
        collection: event.collection,
        collectionName: event.name,
        collectionSource: source,
        creators: creators,
        royaltyPercent: royaltyPercent,
        tags: nextTags,
        traits: nextTraits,
        // Re-derive the disclosure flag — the collection might carry a
        // pre-existing `nsfw` tag.
        nsfw: nextTags.contains(_nsfwTag),
      ),
    );
  }

  void _onPickMainAsset(MintPickMainAsset event, Emitter<MintState> emit) {
    final next = event.asset;
    emit(
      state.copyWith(
        mainAsset: next,
        // If the new main asset doesn't need a thumbnail, drop any stale one.
        thumbnail: next.needsThumbnail ? state.thumbnail : null,
      ),
    );
  }

  Future<void> _onConfirmMint(MintEvent _, Emitter<MintState> emit) async {
    final isEditMode = state.isEdit;
    if (!isEditMode && state.mainAsset == null) {
      emit(
        state.copyWith(
          pipelineStatus: MintPipelineStatus.error,
          pipelineError: 'Main artwork is required.',
          pipelineFailure: null,
        ),
      );
      return;
    }

    // Edit mode no-op guard — mirrors the webapp's
    // `invariant(editContext.requiresUpdate, "No updates required")` in
    // EditNft. Surface the error before any upload so the user
    // doesn't pay the edit fee for a tx that wouldn't change anything.
    if (isEditMode && !state.requiresUpdate) {
      emit(
        state.copyWith(
          pipelineStatus: MintPipelineStatus.error,
          pipelineError: 'No changes to save.',
          pipelineFailure: null,
        ),
      );
      return;
    }

    // Refuse rather than guess: an edit built with an empty
    // `unlockableContentIds` tells the backend to *remove* the on-chain
    // AppData plugin, so a failed lookup must not be allowed to silently
    // strip a collector's exclusive content. Parent-collection edits are
    // exempt — they always send `[]` and never touch the plugin, and a
    // collection mint isn't in the artwork index for the lookup to succeed.
    if (isEditMode && !_isCollectionEdit && state.unlockableContentUnknown) {
      emit(
        state.copyWith(
          pipelineStatus: MintPipelineStatus.error,
          pipelineError:
              "Couldn't load this artwork's exclusive content. "
              'Saving now could remove it — please try again.',
          pipelineFailure: null,
        ),
      );
      return;
    }

    // Signer to restore if the edit path re-points the active wallet to a
    // different update authority and then fails/cancels. Null when no switch
    // happens. Declared out here so the catch below can see it.
    WalletInfo? previousSigner;
    try {
      // 1. Upload any newly-picked files. Edit mode reuses existing
      // IPFS URLs for any slot the user didn't change, so when nothing
      // was picked we skip the whole "Uploading media…" phase.
      final hasAssetPicks =
          state.mainAsset != null ||
          state.thumbnail != null ||
          state.processVideo != null ||
          state.banner != null;
      if (hasAssetPicks) {
        emit(
          state.copyWith(
            pipelineStatus: MintPipelineStatus.uploading,
            pipelineStage: 'Uploading media…',
          ),
        );
        final uploadedMain = state.mainAsset == null
            ? null
            : await _repository.uploadAsset(state.mainAsset!);
        final uploadedThumb = state.thumbnail == null
            ? null
            : await _repository.uploadAsset(state.thumbnail!);
        final uploadedVideo = state.processVideo == null
            ? null
            : await _repository.uploadAsset(state.processVideo!);
        final uploadedBanner = state.banner == null
            ? null
            : await _repository.uploadAsset(state.banner!);

        emit(
          state.copyWith(
            mainAsset: uploadedMain ?? state.mainAsset,
            thumbnail: uploadedThumb,
            processVideo: uploadedVideo,
            banner: uploadedBanner,
          ),
        );
      }

      // 2. Build the on-chain tx. Edit mode reuses the existing mint
      // account (no ephemeral keypair); create mode generates one.
      // The metadata JSON pin happens here too: in edit mode we reuse
      // the existing on-chain `uri` when the freshly built JSON
      // deep-equals the prefill snapshot (mirrors webapp's
      // `requiresMetadataUpdate` in EditNft).
      emit(
        state.copyWith(
          pipelineStatus: MintPipelineStatus.buildingTx,
          pipelineStage: kPreparingLabel,
        ),
      );
      final String metadataUri;
      final newJson = state.toMetadataJson();
      final preEditJson = state.preEditMetadataJson;
      final metadataUnchanged =
          isEditMode &&
          preEditJson != null &&
          state.existingMetadataUri != null &&
          const DeepCollectionEquality().equals(preEditJson, newJson);
      if (metadataUnchanged) {
        metadataUri = state.existingMetadataUri!;
      } else {
        metadataUri = await _repository.uploadMetadata(newJson);
      }
      final Ed25519HDKeyPair? mintKeypair = isEditMode
          ? null
          : await _repository.generateMintKeypair();
      final mintAccount = isEditMode
          ? state.editMintAccount!
          : mintKeypair!.publicKey.toBase58();

      // A master-edition mint under a parent collection may lazy-create a
      // GroupV1 that the new group account must sign. The same applies when
      // an edit re-parents a master edition into a collection that has no
      // group yet (the backend 400s without `newGroupSigner`). Generate the
      // keypair client-side, pass its pubkey to the builder, and sign the
      // returned tx with it only if it ends up a required signer (mirrors
      // `Mint` / `EditNft` groupKeypair handling).
      final needsGroupKeypair = isEditMode
          ? _isMasterEditionReparent
          : _needsGroupSigner();
      final Ed25519HDKeyPair? groupKeypair = needsGroupKeypair
          ? await _repository.generateMintKeypair()
          : null;

      // Authoritative pre-sign signer switch: the edit screen only gates a
      // watch-only authority (via `ensureSignerAvailable`) and no longer
      // re-points on open, so this is the single point that switches the active
      // signer. When the asset's update authority is a *signable* session wallet
      // other than the active one, re-point to it before reading the address
      // below. Watch-only holders can't be handled here — that stays the
      // screen's job (it prompts for import).
      if (isEditMode) {
        final authority = state.editUpdateAuthority;
        if (authority != null && authority.isNotEmpty) {
          final session = sl<SessionManager>();
          final target = session.sessionWalletForAddress(authority);
          final active = await _walletManager.getAddress();
          if (target != null && target.canSign && target.address != active) {
            // Snapshot the signer being switched away from BEFORE the durable
            // switch (selectSourceWallet persists prefs + notifies), so any
            // downstream failure/cancel can put it back in the catch below. A
            // confirmed edit returns before the catch and intentionally leaves
            // the signer switched — mirrors the transfer/burn convention in
            // artwork_detail_screen/actions.dart (reuses its shared helpers).
            previousSigner = activeSignerSnapshot();
            await session.selectSourceWallet(target);
          }
        }
      }

      // Both flows build via the Rust v2 routes; finalization stays on v1.
      // The v2 builders take the actor (creator/authority) explicitly.
      final signer = await _walletManager.getAddress();
      final String responseTx;
      if (isEditMode) {
        responseTx = (await _repository.buildEditNftTx(
          _buildEditV2Request(
            authority: signer,
            mintAccount: mintAccount,
            uri: metadataUri,
            // The tx the user signs — never a dry run.
            dryRun: false,
            newGroupSigner: groupKeypair?.publicKey.toBase58(),
          ),
        )).result.tx;
      } else {
        responseTx = (await _repository.buildMintNftTx(
          _buildMintV2Request(
            creator: signer,
            mintAccount: mintAccount,
            uri: metadataUri,
            // The tx the user signs — never a dry run.
            dryRun: false,
            groupSigner: groupKeypair?.publicKey.toBase58(),
          ),
        )).result.tx;
      }

      // 4. Sign + broadcast. Edit mode has no additional signer (the
      // mint account already exists); create mode signs with the
      // ephemeral mint keypair, plus the group keypair when the v2
      // builder made it a required signer (lazy GroupV1 creation).
      final additionalSigners = <Ed25519HDKeyPair>[
        ?mintKeypair,
        if (groupKeypair != null && _isRequiredSigner(responseTx, groupKeypair))
          groupKeypair,
      ];
      final isLocal = await _walletManager.isLocalSigner();
      emit(
        state.copyWith(
          pipelineStatus: MintPipelineStatus.awaitingApproval,
          pipelineStage: isLocal ? kLocalSigningLabel : kExternalSigningLabel,
          mintAccount: mintAccount,
        ),
      );
      // USD outflow for the step-up auth gate. Prefer the exact simulated cost
      // from the simulate step; when the user confirms before simulation
      // completes, fall back to the static [costBreakdown] estimate (the same
      // figure shown in the cost preview) so the gate still prices the tx
      // rather than fail-closing on a null and demanding re-auth for what is
      // almost always a sub-threshold mint. Pricing can still return null if
      // SOL price data is unavailable, in which case the gate fails closed.
      final lamports =
          state.simulatedTxCostLamports ?? state.costBreakdown.totalLamports;
      final usdOutflow = _priceService.usdValueOfRaw(lamports, solMint);

      // Route sign → broadcast → confirm through the shared
      // [TransactionExecutor] — the single signing path. Create flows sign
      // with the ephemeral mint keypair (and any lazily-created group
      // keypair) via [additionalSigners]; edit flows pass none. Mint txs
      // aren't server-co-signed, so no [StaleTxTracker] is needed.
      final signResult = await _executor.execute(
        txsBase64: [responseTx],
        usdValue: usdOutflow,
        flow: FlowKey.solana(flowCell),
        additionalSigners: additionalSigners,
        onStage: (e) {
          switch (e.stage) {
            case ExecutorStage.awaitingApproval:
              emit(
                state.copyWith(
                  pipelineStatus: MintPipelineStatus.awaitingApproval,
                  pipelineStage: isLocal
                      ? kLocalSigningLabel
                      : kExternalSigningLabel,
                ),
              );
            case ExecutorStage.ledgerAwaitingDevice:
              emit(state.copyWith(pipelineStage: kLedgerSigningStage));
            case ExecutorStage.broadcasting:
              emit(
                state.copyWith(
                  pipelineStatus: MintPipelineStatus.broadcasting,
                  pipelineStage: kConfirmingLabel,
                ),
              );
          }
        },
      );
      // Surface pipeline cancel/error as a uniform AppFailure so the
      // outer catch — which already classifies via [AppFailure.from] —
      // sees the right kind.
      final signature = switch (signResult) {
        ResultSuccess(:final value) => value,
        ResultFailure(:final error) => throw error,
      };

      // 5. Finalize and wait for the indexer, concurrently. Both flows
      // finalize on v1 (matching the webapp): edit hits
      // `/v1/edit/finalize?type=editNft`; create hits
      // `/v1/create/finalize?type=nft|collection`.
      emit(
        state.copyWith(
          pipelineStatus: MintPipelineStatus.finalizing,
          pipelineStage: 'Finalizing…',
          mintSignature: signature,
          indexed: null,
        ),
      );
      // Success must not be declared before the artwork is queryable: the
      // success sheet's "View artwork" routes straight to `/artwork/:mint`,
      // which 404s until the marketplace *entry* lands. `checkTx` alone acks
      // within tens of milliseconds — strictly earlier than the entry — so
      // the webapp awaits both (`Mint`, `EditNft`,
      // `MintCollection`, `EditCollection`) before
      // it finalizes and flips to Success. Neither poll throws: each gives up
      // after 10 attempts and reports `false`, so a slow indexer degrades to
      // an un-gated success rather than turning a confirmed mint into a
      // failure. [mintIndexedAckTimeout] is the belt-and-braces backstop for the
      // case where the ack is dropped entirely (bloc closed mid-poll).
      //
      // Finalize is backend bookkeeping that runs AFTER the mint/edit tx is
      // already confirmed on-chain (we hold [signature]). A finalize failure
      // must NOT surface as "Mint failed" — the artwork exists on-chain and
      // the indexer poll reconciles it. Retry briefly, then log and proceed
      // to success regardless.
      //
      // It fires immediately on confirmation and runs *concurrently* with the
      // ack wait: `runIndexerCheck`'s `isClosed` guards swallow `onAck` when
      // the user backs out, parking this handler on the full 60 s backstop —
      // if the OS suspends or kills the app in that window, a finalize
      // sequenced after the wait would never run at all (dropping e.g.
      // unlockable-content association) for a mint that is already on-chain.
      // Only the success emission gates on the ack.
      final finalizeFuture = _finalizeWithRetry(
        isEditMode: isEditMode,
        mintAccount: mintAccount,
        signature: signature,
      );
      final ackCompleter = Completer<bool>();
      _pipeline.runIndexerCheck(
        signature: signature,
        requireEntry: true,
        onAck: (sig, ok) {
          if (!ackCompleter.isCompleted) ackCompleter.complete(ok);
          add(MintEvent.indexedAck(signature: sig, ok: ok));
        },
        isClosed: () => isClosed,
      );
      await ackCompleter.future.timeout(
        mintIndexedAckTimeout,
        onTimeout: () => false,
      );
      // Never throws — [_finalizeWithRetry] logs and returns on exhaustion —
      // and [mintFinalizeWaitTimeout] bounds how long success waits on it, so
      // a stalled backend can't sit on "Finalizing…" for the full retry budget.
      // The timeout doesn't cancel it: the outstanding attempts finish on their
      // own, exactly as they do when the user backs out mid-wait.
      await finalizeFuture.timeout(mintFinalizeWaitTimeout, onTimeout: () {});

      emit(
        state.copyWith(
          pipelineStatus: MintPipelineStatus.success,
          pipelineStage: null,
        ),
      );
      // Optimistically subtract the SOL outflow from the sender's cached
      // balance and ping the portfolio bloc to rehydrate. Prefer the
      // simulated post-balance delta (exact); fall back to the static
      // breakdown when simulation didn't produce a value.
      unawaited(
        _applyOptimisticMintDelta(
          state.simulatedTxCostLamports ?? state.costBreakdown.totalLamports,
        ),
      );
    } catch (error, stackTrace) {
      // Undo the pre-sign signer switch on every failure/cancel path (backend
      // error, network drop, or user-cancelled auth — TransactionAuthCancelled
      // — all land here) so an abandoned edit doesn't leave the active wallet
      // durably re-pointed. A confirmed edit never reaches this block, so its
      // switch persists. No-op when nothing was switched (previousSigner null).
      await restoreSigner(previousSigner);
      // [AppFailure.from] classifies TransactionAuthCancelled distinctly
      // (kind = cancelled) and a kill-switch stop as `flowDisabled`, both
      // carried on [MintState.pipelineFailure] so the host can branch on the
      // kind without losing the message.
      final failure = AppFailure.from(error);
      // The pipeline sheet only shows the classified message — log the
      // raw error so `flutter run` output identifies the failing step.
      debugPrint(
        '[MintBloc] ${isEditMode ? 'edit' : 'mint'} pipeline failed: '
        '$error\n$stackTrace',
      );
      emit(
        state.copyWith(
          pipelineStatus: MintPipelineStatus.error,
          pipelineError: failure.message,
          pipelineFailure: failure,
        ),
      );
    }
  }

  /// Finalize the mint/edit on the backend after a successful on-chain
  /// broadcast. Retries a few times to ride out transient backend lag, then —
  /// because the tx is already confirmed on-chain — logs and returns rather
  /// than throwing, so a finalize hiccup never presents as "Mint failed".
  Future<void> _finalizeWithRetry({
    required bool isEditMode,
    required String mintAccount,
    required String signature,
  }) async {
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        if (isEditMode) {
          await _repository.finalizeEdit(
            mintAccount: mintAccount,
            txIds: [signature],
            type: _isCollectionEdit ? 'editCollection' : 'editNft',
          );
        } else {
          await _repository.finalize(
            mintAccount: mintAccount,
            txIds: [signature],
            type: state.mintType == MintCreateType.collection
                ? 'collection'
                : 'nft',
          );
        }
        return;
      } catch (error, stackTrace) {
        if (attempt == maxAttempts) {
          await SentryService.captureException(
            error,
            stackTrace: stackTrace,
            message:
                'Mint finalize failed after on-chain broadcast '
                '(edit=$isEditMode, sig=$signature); proceeding as success '
                'since the tx is already confirmed.',
          );
          return;
        }
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
  }

  Future<void> _applyOptimisticMintDelta(int lamports) async {
    try {
      final sender = await _walletManager.getAddress();
      await BalanceOptimisticUpdater.recordMintCost(
        senderAddress: sender,
        lamports: lamports,
      );
    } catch (_) {
      // Inner updater already logs and swallows; nothing actionable here.
    }
  }

  /// Best-effort cost preview: build the (mint or edit) tx with a
  /// placeholder metadata URI to skip the IPFS pin, simulate with
  /// `inspectAccounts: [userPubkey]`, and emit the user's lamport delta
  /// as [MintState.simulatedTxCostLamports]. The URI's content doesn't
  /// affect tx lamport cost — only its length matters and the placeholder
  /// is a real-shape metadata URI — so the simulated delta
  /// is a faithful preview of the real cost.
  Future<void> _onSimulateTxCost(
    MintSimulateTxCost _,
    Emitter<MintState> emit,
  ) async {
    final payer = state.userPubkey;
    if (payer.isEmpty) return;

    emit(
      state.copyWith(isSimulatingTxCost: true, simulatedTxCostLamports: null),
    );

    try {
      final responseTx = state.isEdit
          ? await _buildEditTxForSimulation()
          : await _buildCreateTxForSimulation();
      if (isClosed) return;
      if (responseTx == null) {
        emit(state.copyWith(isSimulatingTxCost: false));
        return;
      }

      final sim = await _rpcService.simulateWithDelta(
        address: payer,
        simulate: (inspect) => _rpcService.simulateEncodedTransaction(
          responseTx,
          inspectAccounts: inspect,
        ),
      );
      if (isClosed) return;

      // Null delta → simulation failed or the payer wasn't returned; leave the
      // cost unset so the UI falls back to the static breakdown.
      final netDelta = sim.lamportsDelta;
      if (netDelta == null) {
        emit(state.copyWith(isSimulatingTxCost: false));
        return;
      }
      // Cost is pre−post (negated net): validator fees + Metaplex protocol fee
      // + account rent + any mallow-side transfer baked into the tx. A
      // negative cost (net refund) is treated as "no cost to show".
      final cost = -netDelta;
      emit(
        state.copyWith(
          isSimulatingTxCost: false,
          simulatedTxCostLamports: cost < 0 ? null : cost,
        ),
      );
    } catch (_) {
      if (isClosed) return;
      emit(state.copyWith(isSimulatingTxCost: false));
    }
  }

  /// Build the edit-tx for simulation only. Reuses `existingMetadataUri`
  /// so the IPFS pin isn't needed. Returns null when the required
  /// edit-mode state isn't available yet (prefill incomplete, etc.).
  ///
  /// Sent with `dryRun: true` so pricing the edit doesn't claim the
  /// group-rent subsidy slot or leave a pending `NftUpload` row behind when
  /// the user backs out of the confirm sheet — parity with
  /// `ReadyToUpdateNft`.
  Future<String?> _buildEditTxForSimulation() async {
    final mintAccount = state.editMintAccount;
    final placeholderUri = state.existingMetadataUri;
    if (mintAccount == null ||
        placeholderUri == null ||
        placeholderUri.isEmpty) {
      return null;
    }
    // A throwaway group-signer pubkey is enough for a re-parent estimate —
    // the sim tx is never signed (same trick as the create path below).
    final groupSigner = _isMasterEditionReparent
        ? (await _repository.generateMintKeypair()).publicKey.toBase58()
        : null;
    final response = await _repository.buildEditNftTx(
      _buildEditV2Request(
        authority: await _walletManager.getAddress(),
        mintAccount: mintAccount,
        uri: placeholderUri,
        dryRun: true,
        newGroupSigner: groupSigner,
      ),
    );
    return response.result.tx;
  }

  /// Build the create-tx for simulation. Uses an ephemeral mint pubkey
  /// (`_onConfirmMint` generates its own at confirm time) and a
  /// real-shape IPFS gateway URL so the backend accepts the request
  /// without us having to pin anything first. A throwaway group-signer
  /// pubkey is supplied when the kind needs one — the sim tx is never
  /// signed, so a placeholder is sufficient to build a faithful cost.
  ///
  /// Sent with `dryRun: true` so pricing the mint doesn't claim the
  /// group-rent subsidy slot (which would make the real mint that follows
  /// user-pays) or leave a pending `NftUpload` row behind when the user
  /// backs out of the confirm sheet — parity with `ReadyToMint`.
  Future<String?> _buildCreateTxForSimulation() async {
    final mintKeypair = await _repository.generateMintKeypair();
    final mintAccount = mintKeypair.publicKey.toBase58();
    final groupSigner = _needsGroupSigner()
        ? (await _repository.generateMintKeypair()).publicKey.toBase58()
        : null;
    final response = await _repository.buildMintNftTx(
      _buildMintV2Request(
        creator: await _walletManager.getAddress(),
        mintAccount: mintAccount,
        uri: _kSimulationMetadataUri,
        dryRun: true,
        groupSigner: groupSigner,
      ),
    );
    return response.result.tx;
  }

  /// True when the current create state is a master-edition mint into a
  /// parent collection — the only kind that may need a `groupSigner`
  /// (lazy GroupV1 creation). Mirrors `Mint`'s `groupKeypair` gate.
  bool _needsGroupSigner() =>
      state.mintType == MintCreateType.editions && _v2CollectionRef() != null;

  /// The parent-collection ref for the create flow, or null. Drops the
  /// collection when its token standard is unknown — mirrors the webapp's
  /// `toV2Collection`, which omits a collection without a tokenStandard.
  EditNftV2CollectionRef? _v2CollectionRef() {
    final c = state.collection;
    if (c == null || c.tokenStandard == null) return null;
    return EditNftV2CollectionRef(
      asset: c.mintAccount,
      tokenStandard: c.tokenStandard!,
    );
  }

  /// Map the form's `nftMetadata` onto the shared v2 metadata payload.
  /// Mirrors the webapp's `toV2Metadata` — the extended block is sent
  /// so the v1 finalize path can read `nsfw` etc. off the upload record.
  EditNftV2Metadata _v2Metadata() {
    final meta = state.toNftMetadata();
    final em = meta.extendedMetadata;
    return EditNftV2Metadata(
      name: meta.name,
      sellerFeeBasisPoints: meta.sellerFeeBasisPoints,
      creators: meta.creators
          .map((c) => EditNftV2Creator(address: c.address, share: c.share))
          .toList(growable: false),
      extendedMetadata: EditNftV2ExtendedMetadata(
        description: em.description,
        attributes: em.attributes
            .map(
              (a) => EditNftV2Attribute(traitType: a.traitType, value: a.value),
            )
            .toList(growable: false),
        image: em.image,
        banner: em.banner,
        video: em.video,
        tags: em.tags,
        nsfw: em.nsfw,
      ),
    );
  }

  /// Build the `POST /v2/tx/nft/mint` body for the current create state.
  /// Selects the `kind` discriminator (1/1 → `core_asset`, editions →
  /// `core_master_edition_collection`, collection → `core_collection`)
  /// and slots the kind-specific fields — mirrors `buildMintShadowBody`
  /// and `buildMintCollectionShadowBody`.
  ///
  /// [dryRun] is required rather than defaulted so the cost preview and the
  /// real submit can't silently converge — a non-dry preview reserves the
  /// group-rent subsidy slot and persists an `NftUpload` row.
  MintNftV2Request _buildMintV2Request({
    required String creator,
    required String mintAccount,
    required String uri,
    required bool dryRun,
    String? groupSigner,
  }) {
    final collectionRef = _v2CollectionRef();
    final String kind;
    EditNftV2CollectionRef? collection;
    int? maxSupply;
    String? group;
    // Collections never carry unlockable content (parity with
    // `buildMintCollectionShadowBody`, which hardcodes `[]`).
    var unlockableContentIds = [...state.exclusiveContentExistingIds];
    switch (state.mintType) {
      case MintCreateType.collection:
        kind = MintNftV2Kind.coreCollection;
        unlockableContentIds = [];
      case MintCreateType.editions:
        kind = MintNftV2Kind.coreMasterEditionCollection;
        maxSupply = state.maxSupplyForRequest;
        collection = collectionRef;
        group = collectionRef == null ? null : groupSigner;
      case MintCreateType.oneOfOne:
      case MintCreateType.jellybean:
      case MintCreateType.airdrop:
        kind = MintNftV2Kind.coreAsset;
        collection = collectionRef;
    }
    return MintNftV2Request(
      authority: creator,
      asset: mintAccount,
      uri: uri,
      nftMetadata: _v2Metadata(),
      kind: kind,
      collection: collection,
      maxSupply: maxSupply,
      groupSigner: group,
      createType: _createTypeWire(state.mintType),
      unlockableContentIds: unlockableContentIds,
      targetPriorityFeeLamports: _feeConfig.priorityFeeLamports,
      dryRun: dryRun,
    );
  }

  /// True when the active edit targets a collection NFT (the webapp's
  /// EditCollection flow). Edit mode can't change `mintType`, so the
  /// flag set at prefill time is stable for the whole session.
  bool get _isCollectionEdit =>
      state.isEdit && state.mintType == MintCreateType.collection;

  /// Kill-switch cell for the action this bloc is about to sign. Mint and edit
  /// share one executor call site but are five distinct backend builders, so
  /// each gets its own cell rather than one coarse "mint" label.
  ///
  /// Public because the confirmation sheet reads it when presenting a kill, so
  /// the event carries the same cell the backstop refused — deriving it a
  /// second time from `isEdit`/`mintType` at the host would be free to drift.
  AppFlow get flowCell {
    if (state.isEdit) {
      return _isCollectionEdit ? AppFlow.collectionEdit : AppFlow.nftEdit;
    }
    return switch (state.mintType) {
      MintCreateType.collection => AppFlow.collectionMint,
      MintCreateType.editions => AppFlow.editionMint,
      // jellybean / airdrop compile to the same `coreAsset` 1/1 builder.
      MintCreateType.oneOfOne ||
      MintCreateType.jellybean ||
      MintCreateType.airdrop => AppFlow.nftMint,
    };
  }

  /// True when this edit moves a Master Edition from one parent Core
  /// Collection to another. A ME's link to its parent is an mpl-core Group,
  /// not the asset's update authority, so the plain `collection` field is a
  /// no-op for it — the move only happens when the body also carries
  /// `newParentCollection`. Mirrors the
  /// webapp's `isMasterEditionReparent` (`editHelpers`);
  /// `isMasterEditionEdit` is the mobile equivalent of its
  /// `tokenStandard === CoreCollection` test, minus parent collections
  /// (which the backend rejects for a re-parent).
  bool get _isMasterEditionReparent {
    if (!state.isEdit || !state.isMasterEditionEdit || _isCollectionEdit) {
      return false;
    }
    final picked = state.collection?.mintAccount;
    return picked != null && picked != state.preEditCollectionMint;
  }

  /// True when this edit clears a Master Edition's parent collection.
  /// Mirrors `isMasterEditionDetach` (`editHelpers`). Signalled
  /// to the backend as an explicit `collection: null`, which is distinct from
  /// an absent field — see [EditNftV2CollectionUpdate].
  bool get _isMasterEditionDetach {
    if (!state.isEdit || !state.isMasterEditionEdit || _isCollectionEdit) {
      return false;
    }
    return state.collection?.mintAccount == null &&
        state.preEditCollectionMint != null;
  }

  /// Build the `POST /v2/tx/nft/edit` body for the current edit state.
  ///
  /// Collection edits mirror the webapp's `fetchEditCollectionTxBase64`
  /// v2 body: `editTarget=parent_collection`, `createType=editCollection`,
  /// and no `maxSupply`/`collection` fields (an absent `collection` means
  /// "leave group membership untouched" on the backend's double-option).
  ///
  /// [dryRun] is required rather than defaulted so the cost preview and the
  /// real submit can't silently converge — a non-dry preview reserves the
  /// group-rent subsidy slot and persists an `NftUpload` row.
  EditNftV2Request _buildEditV2Request({
    required String authority,
    required String mintAccount,
    required String uri,
    required bool dryRun,
    String? newGroupSigner,
  }) {
    final isCollectionEdit = _isCollectionEdit;
    final isReparent = _isMasterEditionReparent;
    return EditNftV2Request(
      authority: authority,
      asset: mintAccount,
      uri: uri,
      nftMetadata: _v2Metadata(),
      tokenStandard: state.editTokenStandard ?? TokenStandard.core,
      maxSupply: isCollectionEdit ? null : state.maxSupplyForRequest,
      // Detach must be an explicit `null` on the wire; "unchanged" must be an
      // absent field. Webapp parity: `EditNft` sends the ref plus
      // `newParentCollection` on a move, and `detachCollection` on a clear.
      collection: isCollectionEdit
          ? null
          : _isMasterEditionDetach
          ? const EditNftV2CollectionUpdate.detach()
          : state.collection == null
          ? null
          : EditNftV2CollectionUpdate.assign(
              EditNftV2CollectionRef(
                asset: state.collection!.mintAccount,
                tokenStandard:
                    state.collection!.tokenStandard ??
                    TokenStandard.coreCollection,
              ),
            ),
      newParentCollection: isReparent ? state.collection!.mintAccount : null,
      newGroupSigner: isReparent ? newGroupSigner : null,
      dryRun: dryRun,
      createType: isCollectionEdit ? 'editCollection' : 'editNft',
      editTarget: isCollectionEdit
          ? EditNftV2EditTarget.parentCollection
          : EditNftV2EditTarget.asset,
      // Round-trip the unlockable-content ids already on the asset. The
      // backend reads an *empty* list as an explicit clear and emits
      // `RemoveExternalPluginAdapter` (the edit-asset builder's
      // `append_app_data_ixs`: `(None, has_plugin) → Remove`), so shipping
      // the freezed default `[]` made any edit — a typo fix included —
      // destroy the collector's exclusive content. Webapp parity:
      // `EditNft` sends the id it read off the artwork render.
      //
      // Parent-collection edits must send `[]`: the backend rejects
      // `unlockableContentIds` outright with `editTarget=parent_collection`
      // (in its v2 NFT tx builder), and the JS `getEditCollectionIxs` path
      // never touches the AppData plugin.
      unlockableContentIds: isCollectionEdit
          ? const <int>[]
          : state.exclusiveContentExistingIds,
      targetPriorityFeeLamports: _feeConfig.priorityFeeLamports,
    );
  }

  /// `createType` wire string carried through to the upload record.
  String _createTypeWire(MintCreateType type) => switch (type) {
    MintCreateType.oneOfOne => '1/1',
    MintCreateType.editions => 'editions',
    MintCreateType.collection => 'collection',
    MintCreateType.jellybean => 'jellybean',
    MintCreateType.airdrop => 'airdrop',
  };

  /// True when [signer] occupies one of the required-signer slots of the
  /// compiled tx. Used to decide whether to sign with the lazily-created
  /// group keypair — `WalletManager.signCompiledTx` throws if handed a
  /// signer that isn't in the signer slots.
  bool _isRequiredSigner(String txBase64, Ed25519HDKeyPair signer) {
    try {
      final msg = SignedTx.fromBytes(base64Decode(txBase64)).compiledMessage;
      final target = signer.publicKey.toBase58();
      final n = msg.requiredSignatureCount;
      for (var i = 0; i < n && i < msg.accountKeys.length; i++) {
        if (msg.accountKeys[i].toBase58() == target) return true;
      }
    } catch (_) {}
    return false;
  }

  void _onIndexedAck(MintIndexedAck event, Emitter<MintState> emit) {
    if (state.mintSignature != event.signature) return;
    emit(state.copyWith(indexed: event.ok));
    // A create adds a new artwork to My Art; an edit changes an existing one.
    // Refetch the portfolio now that the indexer has acked the mint/edit tx.
    notifyPortfolioRefresh();
    // An edit also mutates the item's metadata in place (thumbnail, name,
    // description, collection) — fan out to any mounted detail/collection/
    // curation/own-profile view showing it so it refetches too. Guarded to
    // edits; a fresh mint has no such originating view to refresh.
    final editedMint = state.editMintAccount;
    if (editedMint != null) notifyArtworkEdited(editedMint);
  }
}
