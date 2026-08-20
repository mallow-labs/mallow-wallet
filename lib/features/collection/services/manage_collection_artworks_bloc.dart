import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:solana/solana.dart' show Ed25519HDKeyPair;

import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/models/account.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/services/transaction_executor.dart';
import '../../../core/services/signing_copy.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../artwork/services/artwork_edited_signal.dart';
import '../../artwork/services/ensure_signer.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/services/portfolio_bloc.dart' show PortfolioArtwork;
import '../../portfolio/services/portfolio_refresh_signal.dart';
import '../../profile/data/user_profile_repository.dart';

part 'manage_collection_artworks_bloc.freezed.dart';

/// Coarse status of the membership transaction, collapsed onto the shared
/// `TransactionPipelineSheet` phases by the screen.
enum ManageArtworksTxStatus { idle, signing, broadcasting, success, error }

@freezed
sealed class ManageCollectionArtworksEvent
    with _$ManageCollectionArtworksEvent {
  /// Loads the current members of [collectionMint] (pre-selected) plus the
  /// signer's own artworks (candidates to add). The collection mint travels on
  /// the event (mirrors [TransferArtworkBloc]'s `started`) so the bloc stays a
  /// plain `@injectable`.
  const factory ManageCollectionArtworksEvent.started(String collectionMint) =
      ManageCollectionArtworksStarted;
  const factory ManageCollectionArtworksEvent.toggled(String mintAccount) =
      ManageCollectionArtworksToggled;
  const factory ManageCollectionArtworksEvent.queryChanged(String query) =
      ManageCollectionArtworksQueryChanged;

  /// Builds the membership tx(s), signs and broadcasts the batch.
  const factory ManageCollectionArtworksEvent.submit() =
      ManageCollectionArtworksSubmit;
  const factory ManageCollectionArtworksEvent.retry() =
      ManageCollectionArtworksRetry;
  const factory ManageCollectionArtworksEvent.dismissError() =
      ManageCollectionArtworksDismissError;
}

@freezed
sealed class ManageCollectionArtworksState
    with _$ManageCollectionArtworksState {
  const factory ManageCollectionArtworksState({
    @Default(true) bool isLoading,
    @Default(<PortfolioArtwork>[]) List<PortfolioArtwork> artworks,
    String? loadError,

    /// Mints already in the collection at load time — pre-selected, so
    /// unchecking one queues it for removal.
    @Default(<String>{}) Set<String> memberMints,
    @Default(<String>{}) Set<String> selected,
    @Default('') String query,

    /// The parent collection's update authority — the address the backend
    /// requires as `EditCollectionArtworksRequest.authority`. Resolved in
    /// [ManageCollectionArtworksStarted] from the collection's creator address
    /// (the same field the collection burn flow threads as `updateAuth`).
    /// Null when the collection couldn't be resolved, in which case the submit
    /// falls back to the active wallet unchanged.
    String? authority,
    @Default(ManageArtworksTxStatus.idle) ManageArtworksTxStatus txStatus,
    String? txStage,
    String? txError,

    /// The classified failure behind [txError], carried so the screen can tell
    /// a remote kill from an ordinary tx error and present the operator's copy
    /// instead of the pipeline's generic "Could not update collection" body.
    /// Always cleared alongside [txError].
    AppFailure? txFailure,
    String? signature,
  }) = _ManageCollectionArtworksState;

  const ManageCollectionArtworksState._();

  /// Candidate artworks narrowed by the search query (title / collection).
  List<PortfolioArtwork> get filtered {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return artworks;
    return artworks
        .where(
          (a) =>
              a.title.toLowerCase().contains(q) ||
              (a.collectionName?.toLowerCase().contains(q) ?? false),
        )
        .toList(growable: false);
  }

  /// Mints newly checked since load — assets/MEs to add.
  Set<String> get added => selected.difference(memberMints);

  /// Members unchecked since load — assets/MEs to remove.
  Set<String> get removed => memberMints.difference(selected);

  bool get canSubmit =>
      (added.isNotEmpty || removed.isNotEmpty) &&
      txStatus == ManageArtworksTxStatus.idle;
}

/// Drives the "manage collection artworks" flow — add and remove members of an
/// on-chain collection.
///
/// The list is the signer's **own artworks** (candidates to add); the
/// collection's **current member mints** only pre-select the ones already in
/// it (mirrors the reference web client — a member the signer can't sign for isn't shown
/// and would revert on-chain anyway). Unchecking a member queues a remove;
/// checking a candidate queues an add. On confirm the selections are
/// diffed against the initial members and split by supply type:
///
///  * a **master edition** (open/limited original — `PortfolioArtwork.isPrintable`,
///    mirroring the backend's `deriveIsMasterEdition`) goes into
///    `addMasterEditions` / `removeMasterEditions`, which drive mpl-core Group
///    ops server-side;
///  * everything else (1/1s, edition prints) goes into `addAssets` /
///    `removeAssets`.
///
/// **groupSigner**: adding a master edition to a collection that has no Group
/// yet makes the backend lazily emit a `CreateGroupV1` the new group account
/// must sign. We generate an ephemeral group keypair whenever `addMasterEditions`
/// is non-empty, pass its pubkey as `groupSigner`, and hand the keypair to the
/// [TransactionExecutor] — which co-signs only the batch tx that actually
/// requires it (the `CreateGroupV1` chunk). Mirrors the mint/edit `groupKeypair`
/// pattern. If the collection already anchors a Group the backend ignores the
/// signer and it won't be a required signer, so nothing is co-signed.
///
/// The returned tx batch is signed/broadcast through the shared executor, which
/// gates only the first tx, aborts the batch on any failure, and returns the
/// last signature. Membership edits have no v1 finalize — the DAS indexer
/// reconciles the moves.
@injectable
class ManageCollectionArtworksBloc
    extends Bloc<ManageCollectionArtworksEvent, ManageCollectionArtworksState> {
  ManageCollectionArtworksBloc(
    this._portfolio,
    this._profile,
    this._walletManager,
    this._executor,
    this._apiV2,
  ) : super(const ManageCollectionArtworksState()) {
    on<ManageCollectionArtworksStarted>(_onStarted);
    on<ManageCollectionArtworksToggled>(_onToggled);
    on<ManageCollectionArtworksQueryChanged>(_onQueryChanged);
    on<ManageCollectionArtworksSubmit>(_onSubmit);
    on<ManageCollectionArtworksRetry>(_onSubmit);
    on<ManageCollectionArtworksDismissError>(_onDismissError);
  }

  final PortfolioRepository _portfolio;
  final UserProfileRepository _profile;
  final WalletManager _walletManager;
  final TransactionExecutor _executor;
  final MallowApiV2Client _apiV2;

  /// The parent collection's mint — the `parentCollection` the assets join.
  /// Seeded by [ManageCollectionArtworksStarted].
  String? _collectionMint;

  /// Whether the parent is an mpl-core Core Collection. Only Core parents
  /// accept `addMasterEditions`/`removeMasterEditions` (Group ops); a legacy
  /// token-metadata parent 400s the whole batch on any master-edition list, so
  /// this drives the submit-time split. Resolved in [_onStarted]; defaults to
  /// `false` (assets-only, fail-closed) when the collection can't be resolved.
  bool _parentIsCore = false;

  Future<void> _onStarted(
    ManageCollectionArtworksStarted event,
    Emitter<ManageCollectionArtworksState> emit,
  ) async {
    _collectionMint = event.collectionMint;
    emit(state.copyWith(isLoading: true, loadError: null));
    try {
      // Resolve the parent collection first: its token standard both scopes the
      // candidate query (a mismatched-standard asset 400s the whole edit batch)
      // and decides the master-edition split. Best-effort — a brand-new
      // collection may not be indexed yet.
      final collection = await _profile.getCollectionByMint(
        event.collectionMint,
      );
      final standard = collection?.nft?.tokenStandard;
      _parentIsCore =
          standard == TokenStandard.core ||
          standard == TokenStandard.coreCollection;

      // Current member mints (to pre-select) and the signer's own artworks
      // (candidates to add), in parallel. Candidates come from an
      // update-authority query scoped to the parent's standard — the set the
      // signer can actually re-collection — mirroring the reference web client
      // SelectArtworks (an ownership query would list collected art the signer
      // can't sign for, and only its first page). Members come from the full
      // mint list keyed by the collection mint (not a single indexed page), so
      // a member on any page can be removed; a non-404 members failure throws
      // here and surfaces the load error rather than silently disabling
      // removal.
      final (memberMints, candidates) = await (
        _profile.getCollectionMintAccounts(event.collectionMint),
        _portfolio.getArtworksByUpdateAuth(
          tokenStandards: [_candidateStandard(standard)],
        ),
      ).wait;

      // The displayed list is exactly the candidate set (mirrors the reference web client):
      // members are used only to pre-select the ones already in the collection.
      // A member the signer has no update-auth over isn't a candidate, so it
      // isn't shown and can't be removed — exactly as on web, and it would
      // revert on-chain anyway.
      final memberSet = memberMints.toSet();
      emit(
        state.copyWith(
          isLoading: false,
          artworks: candidates,
          memberMints: memberSet,
          selected: Set<String>.from(memberSet),
          authority: collection?.creatorAddress,
        ),
      );
    } catch (e) {
      debugPrint('[ManageCollectionArtworksBloc] load failed: $e');
      emit(
        state.copyWith(
          isLoading: false,
          loadError: 'Could not load your artworks',
        ),
      );
    }
  }

  /// The token standard to scope the candidate query to. A Core *collection*
  /// holds Core *assets*, so a `core-collection` parent queries for `core`;
  /// any other parent queries for its own standard. Mirrors the reference web client
  /// SelectArtworks (`CoreCollection → Core`). Falls back to legacy `nft` when
  /// the parent standard couldn't be resolved.
  String _candidateStandard(TokenStandard? parent) {
    final standard =
        (parent == TokenStandard.core || parent == TokenStandard.coreCollection)
        ? TokenStandard.core
        : (parent ?? TokenStandard.nft);
    return standard.wireValue;
  }

  void _onToggled(
    ManageCollectionArtworksToggled event,
    Emitter<ManageCollectionArtworksState> emit,
  ) {
    final next = Set<String>.from(state.selected);
    if (!next.remove(event.mintAccount)) next.add(event.mintAccount);
    emit(state.copyWith(selected: next));
  }

  void _onQueryChanged(
    ManageCollectionArtworksQueryChanged event,
    Emitter<ManageCollectionArtworksState> emit,
  ) {
    emit(state.copyWith(query: event.query));
  }

  Future<void> _onSubmit(
    ManageCollectionArtworksEvent event,
    Emitter<ManageCollectionArtworksState> emit,
  ) async {
    final collectionMint = _collectionMint;
    final added = state.added;
    final removed = state.removed;
    if (collectionMint == null || (added.isEmpty && removed.isEmpty)) return;

    // Split each add/remove by supply type. A master edition drives mpl-core
    // Group ops server-side — but only for a Core parent. A legacy
    // token-metadata parent rejects any `addMasterEditions`/`removeMasterEditions`
    // list with a 400 that fails the whole batch (it verifies/unverifies every
    // move as a plain asset instead), so we only split out master editions when
    // the parent is Core; otherwise everything is an asset move.
    final byMint = {for (final a in state.artworks) a.mintAccount: a};
    bool isMe(String mint) =>
        _parentIsCore && (byMint[mint]?.isPrintable ?? false);
    final addAssets = added.where((m) => !isMe(m)).toList(growable: false);
    final addMasterEditions = added.where(isMe).toList(growable: false);
    final removeAssets = removed.where((m) => !isMe(m)).toList(growable: false);
    final removeMasterEditions = removed.where(isMe).toList(growable: false);

    emit(
      state.copyWith(
        txStatus: ManageArtworksTxStatus.signing,
        txStage: kPreparingLabel,
        txError: null,
        txFailure: null,
      ),
    );

    // The signer this flow switched away from, if any — restored on every
    // failure/cancel path below so an abandoned edit doesn't leave the active
    // wallet durably re-pointed.
    WalletInfo? previousSigner;

    // A null value threads the "no-op success" sentinel (empty batch) through
    // the Result; a non-null value is the landed signature.
    final result = await Result.guard<String?>(() async {
      // Authoritative pre-sign signer switch. The collection's update authority
      // may be a session wallet other than the active one (creator status is
      // widened across the session), in which case the request must carry *its*
      // address or the backend/on-chain edit rejects the batch. This bloc has no
      // BuildContext, so it mirrors the mint bloc's pre-sign switch rather than
      // `ensureSigner`: switch only for a *signable* session wallet, and leave a
      // watch-only authority to the screen's `ensureSignerAvailable` gate (which
      // prompts for import). Reads resolve via `WalletManager.getAddress()` — a
      // DB read that is correct the moment the switch returns.
      final collectionAuthority = state.authority;
      if (collectionAuthority != null && collectionAuthority.isNotEmpty) {
        final session = sl<SessionManager>();
        final target = session.sessionWalletForAddress(collectionAuthority);
        final active = await _walletManager.getAddress();
        if (target != null && target.canSign && target.address != active) {
          // Snapshot BEFORE the durable switch (selectSourceWallet persists
          // prefs + notifies) so the failure path can put it back. A confirmed
          // edit intentionally leaves the signer switched — the
          // transfer/burn/mint convention.
          previousSigner = activeSignerSnapshot();
          await session.selectSourceWallet(target);
        }
      }

      final authority = await _walletManager.getAddress();

      // Adding a master edition may lazily create the collection's Group, whose
      // new account must sign the CreateGroupV1. Generate an ephemeral keypair,
      // send its pubkey, and hand the keypair to the executor — it co-signs
      // only the batch tx that actually requires it.
      final Ed25519HDKeyPair? groupKeypair = addMasterEditions.isEmpty
          ? null
          : await Ed25519HDKeyPair.random();

      final response = await _apiV2.editCollectionArtworksTx(
        EditCollectionArtworksRequest(
          authority: authority,
          parentCollection: collectionMint,
          groupSigner: groupKeypair?.publicKey.toBase58(),
          addAssets: addAssets,
          removeAssets: removeAssets,
          addMasterEditions: addMasterEditions,
          removeMasterEditions: removeMasterEditions,
        ),
      );
      final txs = response.result.txs.map((t) => t.tx).toList(growable: false);
      if (txs.isEmpty) {
        // The backend returns 200 with an empty batch when every requested move
        // is already a no-op (the builder skips already-in-target adds). That
        // is benign success, not an error — mirror the reference web client's
        // "No updates required": land on success with no signature (nothing to
        // broadcast or reindex). Returning null flags the no-op path for the
        // success case.
        return null;
      }

      final isLocal = await _walletManager.isLocalSigner();

      // An NFT membership move has no priced outflow, so a null usdValue makes
      // the executor's auth gate fail-closed and always require confirmation —
      // the desired behaviour for signing on-chain asset moves.
      final execResult = await _executor.execute(
        txsBase64: txs,
        usdValue: null,
        flow: const FlowKey.solana(AppFlow.collectionArtworksEdit),
        additionalSigners: [?groupKeypair],
        onStage: (e) {
          switch (e.stage) {
            case ExecutorStage.awaitingApproval:
            case ExecutorStage.ledgerAwaitingDevice:
              // Multi-tx batches (the lazy CreateGroupV1 chunk makes this the
              // norm here) fire a fresh approval event per tx. Revert to the
              // signing phase on every one so a Ledger user awaiting device
              // approval for tx 2+ isn't stuck reading "Confirming
              // transaction" from the previous tx's broadcast. Mirrors
              // marketplace_action_flow's onStage mapping.
              final progress = e.total > 1
                  ? ' (${e.index + 1}/${e.total})'
                  : '';
              emit(
                state.copyWith(
                  txStatus: ManageArtworksTxStatus.signing,
                  txStage: e.stage == ExecutorStage.ledgerAwaitingDevice
                      ? '$kLedgerSigningStage$progress'
                      : isLocal
                      ? '$kLocalSigningLabel$progress'
                      : '$kExternalSigningLabel$progress',
                ),
              );
            case ExecutorStage.broadcasting:
              emit(
                state.copyWith(
                  txStatus: ManageArtworksTxStatus.broadcasting,
                  txStage: kConfirmingLabel,
                ),
              );
          }
        },
      );
      return switch (execResult) {
        ResultSuccess(:final value) => value,
        ResultFailure(:final error) => throw error,
      };
    });

    switch (result) {
      case ResultSuccess(:final value):
        emit(
          state.copyWith(
            txStatus: ManageArtworksTxStatus.success,
            txStage: null,
            signature: value,
          ),
        );
        // A null signature is the no-op path (empty batch): nothing landed on
        // chain, so there is nothing to reconcile or refresh (mirrors
        // the reference web client's early return).
        if (value != null) {
          // Reconcile the collection's membership tables before the collection
          // screen refetches on return. Best-effort: a reindex failure must not
          // turn a landed tx into an error state.
          try {
            await _profile.reindexCollectionArtworks(collectionMint);
          } catch (e) {
            debugPrint('[ManageCollectionArtworksBloc] reindex failed: $e');
          }
          // Refresh My Art and ping every moved artwork's listeners. No
          // collection-membership signal exists; these are the closest hooks.
          notifyPortfolioRefresh();
          for (final mint in {...added, ...removed}) {
            notifyArtworkEdited(mint);
          }
        }
      case ResultFailure(:final error):
        // Undo the pre-sign switch on every failure/cancel path (build error,
        // network drop, or a user-cancelled auth gate — all land here) so an
        // abandoned edit doesn't leave the active wallet re-pointed. No-op when
        // nothing was switched. Retry re-runs the switch from scratch.
        await restoreSigner(previousSigner);
        debugPrint(
          '[ManageCollectionArtworksBloc] submit failed: ${error.message}',
        );
        emit(
          state.copyWith(
            txStatus: ManageArtworksTxStatus.error,
            txStage: null,
            txError: error.message,
            txFailure: error,
          ),
        );
    }
  }

  void _onDismissError(
    ManageCollectionArtworksDismissError event,
    Emitter<ManageCollectionArtworksState> emit,
  ) {
    emit(
      state.copyWith(
        txStatus: ManageArtworksTxStatus.idle,
        txStage: null,
        txError: null,
        txFailure: null,
      ),
    );
  }
}
