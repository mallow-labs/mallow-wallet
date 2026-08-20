import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:solana/solana.dart';

import '../../../core/data/mallow_market.dart';
import '../../../core/realtime/models/account_update.dart';

/// Outcome of a single on-chain account read. The distinction between
/// [absent] (the chain authoritatively has no such account — a `404`
/// `AccountNotFound`) and [unknown] (a transport/decode failure where the
/// account's existence is undetermined) is load-bearing: only [absent] is
/// safe to clear stale indexed listing/auction state on. [unknown] must be a
/// no-op so a flaky network never hides a real, buyable listing.
enum OnChainReadStatus { present, absent, unknown }

/// A read of one decoded program account: its [status], the decoded
/// [account] (non-null only when [status] is [OnChainReadStatus.present]), the
/// [pda] that was read (so callers can open a live subscription on it without
/// re-deriving), and the [viewSlot] the serving RPC node evaluated the query
/// at. [pda] is empty only when derivation itself failed.
///
/// [viewSlot] is what makes an [OnChainReadStatus.absent] orderable against
/// the account socket's write-slots: "not found as of slot X" outranks a
/// stream frame written at slot W only when `X >= W` — otherwise the read was
/// served by a node behind our own evidence and must not clear state. Null
/// when the backend predates the `{ viewSlot, account }` envelope (a legacy
/// 404), in which case absence is unordered and callers fall back to
/// evidence-suppression.
typedef MarketAccountRead = ({
  OnChainReadStatus status,
  AccountUpdate? account,
  String pda,
  int? viewSlot,
});

/// Derives the canonical `Listing` / `AuctionConfig` PDAs from a mint and
/// reads them straight off the chain via `GET /v2/accounts/...`. Used by
/// [ArtworkBloc] to reconcile artwork listing/auction state against the chain
/// independently of the `/byMint` indexer — so a listing or auction the
/// indexer missed (or still shows after a cancel) is surfaced/cleared from
/// the authoritative on-chain account.
@lazySingleton
class MarketAccountRepository {
  MarketAccountRepository(this._apiV2);

  final api.MallowApiV2Client _apiV2;

  /// `["listing", mint]` under [kMallowMarketProgramId].
  Future<String> deriveListingPda(String mint) async {
    final mintKey = Ed25519HDPublicKey.fromBase58(mint);
    final programId = Ed25519HDPublicKey.fromBase58(kMallowMarketProgramId);
    final pda = await Ed25519HDPublicKey.findProgramAddress(
      seeds: [utf8.encode(kListingSeed), mintKey.bytes],
      programId: programId,
    );
    return pda.toBase58();
  }

  /// `[mint, "auction_config"]` under [kMallowAuctionProgramId].
  Future<String> deriveAuctionConfigPda(String mint) async {
    final mintKey = Ed25519HDPublicKey.fromBase58(mint);
    final programId = Ed25519HDPublicKey.fromBase58(kMallowAuctionProgramId);
    final pda = await Ed25519HDPublicKey.findProgramAddress(
      seeds: [mintKey.bytes, utf8.encode(kAuctionConfigSeed)],
      programId: programId,
    );
    return pda.toBase58();
  }

  /// `["offer", buyer, mint]` under [kMallowMarketProgramId] — the canonical
  /// codama 3-seed Offer PDA (see [kOfferSeed]).
  Future<String> deriveOfferPda(String buyer, String mint) async {
    final buyerKey = Ed25519HDPublicKey.fromBase58(buyer);
    final mintKey = Ed25519HDPublicKey.fromBase58(mint);
    final programId = Ed25519HDPublicKey.fromBase58(kMallowMarketProgramId);
    final pda = await Ed25519HDPublicKey.findProgramAddress(
      seeds: [utf8.encode(kOfferSeed), buyerKey.bytes, mintKey.bytes],
      programId: programId,
    );
    return pda.toBase58();
  }

  /// Read the `Listing` account for [mint] (derives the PDA first).
  Future<MarketAccountRead> readListing(String mint) =>
      _deriveAndRead(mint, deriveListingPda, 'market', 'listing');

  /// Read the `AuctionConfig` account for [mint] (derives the PDA first).
  Future<MarketAccountRead> readAuctionConfig(String mint) =>
      _deriveAndRead(mint, deriveAuctionConfigPda, 'auction', 'auction-config');

  /// Read [buyer]'s `Offer` account on [mint] (derives the PDA first). Used to
  /// reconcile the make ↔ cancel offer affordance against the chain right
  /// after an offer action, instead of waiting for the indexer round-trip.
  Future<MarketAccountRead> readOffer({
    required String buyer,
    required String mint,
  }) =>
      _deriveAndRead(mint, (m) => deriveOfferPda(buyer, m), 'market', 'offer');

  Future<MarketAccountRead> _deriveAndRead(
    String mint,
    Future<String> Function(String) derive,
    String program,
    String accountType,
  ) async {
    if (mint.isEmpty) {
      return (
        status: OnChainReadStatus.unknown,
        account: null,
        pda: '',
        viewSlot: null,
      );
    }
    final String pda;
    try {
      pda = await derive(mint);
    } catch (e, s) {
      debugPrint(
        '[MarketAccountRepository] $program/$accountType PDA derivation '
        'failed for $mint: $e\n$s',
      );
      return (
        status: OnChainReadStatus.unknown,
        account: null,
        pda: '',
        viewSlot: null,
      );
    }
    final read = await _read(
      program: program,
      accountType: accountType,
      address: pda,
    );
    return (
      status: read.status,
      account: read.account,
      pda: pda,
      viewSlot: read.viewSlot,
    );
  }

  Future<({OnChainReadStatus status, AccountUpdate? account, int? viewSlot})>
  _read({
    required String program,
    required String accountType,
    required String address,
  }) async {
    try {
      final response = await _apiV2.getProgramAccount(
        program,
        accountType,
        address,
      );
      final raw = response.result?.data;
      if (raw == null) {
        // Legacy backend: absent encoded as a null result with no view slot —
        // absence is unordered, callers fall back to evidence-suppression.
        return (
          status: OnChainReadStatus.absent,
          account: null,
          viewSlot: null,
        );
      }
      // `{ viewSlot, account }` envelope: `account` null means the account
      // does not exist as of the node's view `viewSlot` — orderable against
      // the account socket's write-slots.
      if (raw.containsKey('account')) {
        final viewSlot = (raw['viewSlot'] as num?)?.toInt();
        final accountJson = raw['account'];
        if (accountJson == null) {
          return (
            status: OnChainReadStatus.absent,
            account: null,
            viewSlot: viewSlot,
          );
        }
        return (
          status: OnChainReadStatus.present,
          account: AccountUpdate.fromJson(accountJson as Map<String, dynamic>),
          viewSlot: viewSlot,
        );
      }
      // Legacy backend: the flat decoded record itself (no envelope).
      return (
        status: OnChainReadStatus.present,
        account: AccountUpdate.fromJson(raw),
        viewSlot: null,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        // Legacy backend AccountNotFound — absent, but with no view slot to
        // order it, so callers treat it as unordered absence.
        return (
          status: OnChainReadStatus.absent,
          account: null,
          viewSlot: null,
        );
      }
      // Transport / 5xx — existence is undetermined, so do not clear.
      debugPrint(
        '[MarketAccountRepository] read $program/$accountType/$address '
        'failed (status undetermined): $e',
      );
      return (status: OnChainReadStatus.unknown, account: null, viewSlot: null);
    } catch (e, s) {
      // A non-Dio error is a deserialization / contract mismatch, NOT an
      // absent account. Surface it loudly and treat as undetermined.
      debugPrint(
        '[MarketAccountRepository] read $program/$accountType/$address '
        'DECODE error (contract drift?): $e\n$s',
      );
      return (status: OnChainReadStatus.unknown, account: null, viewSlot: null);
    }
  }
}
