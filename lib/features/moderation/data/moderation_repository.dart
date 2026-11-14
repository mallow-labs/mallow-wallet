import 'package:dio/dio.dart' show DioException;
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/network/auth_service.dart' show kSkipSignatureRetryExtra;
import '../models/moderation_models.dart';

/// Thin wrapper over the `/v2` moderation writes — blocks and content reports.
///
/// Same shape as `OffersInboxRepository`: no state, no caching, no UI
/// concerns. Session state lives in `BlockStore`; the local, viewer-side
/// content suppression lives in `ModerationHideStore`.
///
/// Every route takes a signed login: the `login-token` cookie plus a
/// `wallet-sig` proof for that address. An anonymous caller, or one with no
/// proof, gets a 401. The flows in `moderation_actions.dart` gate on a profile
/// and a proof first.
@lazySingleton
class ModerationRepository {
  ModerationRepository(this._apiV2);

  final api.MallowApiV2Client _apiV2;

  /// `POST /v2/reports`. Never throws — the caller branches on
  /// [ReportOutcome] instead of a try/catch, because a 429 is a *soft*
  /// success the UI must not distinguish from a real one.
  ///
  /// [note] is passed through untruncated: the backend trims, maps empty to
  /// null, and truncates at 1000 chars on a char boundary, so there is nothing
  /// to guard against here.
  Future<ReportOutcome> submitReport({
    required api.ReportTargetType targetType,
    required String targetId,
    required api.ReportReason reason,
    String? note,
    api.ReportContext? context,
  }) async {
    final trimmed = note?.trim();
    try {
      await _apiV2.createReport(
        api.ReportRequest(
          targetType: targetType,
          targetId: targetId,
          reason: reason,
          note: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
          // Spec types `context` as a free-form object, so it generates as
          // `Object?` — the shape comes from the client-side `ReportContext`.
          context: context?.toJson(),
        ),
      );
      return ReportOutcome.submitted;
    } on DioException catch (e) {
      // Over the per-reporter daily cap. Treated as success by the UI.
      if (e.response?.statusCode == 429) return ReportOutcome.rateLimited;
      debugPrint('[Moderation] report failed: ${e.response?.statusCode}');
      return ReportOutcome.failed;
    } catch (_) {
      return ReportOutcome.failed;
    }
  }

  /// `POST /v2/blocks`. Idempotent server-side; self-blocks 400.
  Future<void> block(String address) =>
      _apiV2.blockAddress(api.BlockRequest(address: address));

  /// `DELETE /v2/blocks/{address}`. Idempotent — 200 whether or not a row
  /// existed.
  Future<void> unblock(String address) => _apiV2.unblockAddress(address);

  /// `GET /v2/blocks` — newest first, unpaged, server-capped at 1000 rows.
  /// Rows with no address are dropped: without one there is nothing to unblock.
  ///
  /// Always sent with `requireProof=true` (the client's default), so a login without a valid proof is
  /// a 401 the caller can tell from "no blocks", not an empty list.
  ///
  /// [background] marks a load the user did not ask for. Its 401 is returned
  /// to the caller and never re-signs: on a hardware wallet the re-sign is a
  /// verify sheet. Without it (the Blocked accounts screen) the 401 re-signs
  /// as usual and the read is retried.
  Future<List<api.BlockedAccount>> listBlocks({bool background = false}) async {
    final response = await _apiV2.getBlockedAccounts(
      extras: background ? const {kSkipSignatureRetryExtra: true} : const {},
    );
    return response.result
        .where((b) => b.address.isNotEmpty)
        .toList(growable: false);
  }
}
