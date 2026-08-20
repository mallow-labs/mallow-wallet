import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../di.dart';
import '../../../shared/utils/chain.dart' show apiOwnerAddress;

/// Viewer-side suppression of content the viewer has reported.
///
/// 🛑 This is **not** `/v0/hide`. That endpoint is *owner*-scoped — it hides an
/// artwork you own from your own public profile and is gated by a `wallet-sig`
/// cookie proving ownership (`artwork_hide_actions.dart`), so calling it on
/// someone else's artwork 403s. Reporting must hide the content from the
/// *reporter's* view only, with no signature prompt and no server write beyond
/// the report itself. Nothing in this file talks to the network.
///
/// Suppression lasts for the session. The server-side report/block filter takes
/// over on the next fresh fetch; until then this store plus the app-wide
/// `ArtworkRemovalSignal` (fired by `moderation_actions.dart`, which every
/// mounted artwork grid already listens to) keep the reported item off screen.
@lazySingleton
class ModerationHideStore {
  final Set<String> _artworks = <String>{};
  final Set<String> _curations = <String>{};
  final Set<String> _users = <String>{};

  /// Bumped on every suppression so `ValueListenableBuilder` rebuilds. The
  /// value itself carries no meaning.
  final ValueNotifier<int> revision = ValueNotifier(0);

  bool isArtworkHidden(String mintAccount) => _artworks.contains(mintAccount);

  /// [curationSlug] is the exhibition slug — the same identifier the report
  /// carries as its `targetId`.
  bool isCurationHidden(String curationSlug) =>
      _curations.contains(curationSlug);

  bool isUserHidden(String address) =>
      _users.contains(apiOwnerAddress(address));

  /// Records [targetId] as suppressed for this session.
  void hide(api.ReportTargetType targetType, String targetId) {
    if (targetId.isEmpty) return;
    final added = switch (targetType) {
      api.ReportTargetType.artwork => _artworks.add(targetId),
      api.ReportTargetType.curation => _curations.add(targetId),
      api.ReportTargetType.user => _users.add(apiOwnerAddress(targetId)),
      // Inbound-only placeholder for a target type the spec doesn't list, so
      // there is no bucket to hide it in. Unreachable in practice — every
      // caller passes a literal from `moderation_actions.dart`.
      api.ReportTargetType.swaggerGeneratedUnknown => false,
    };
    if (added) revision.value++;
  }

  @disposeMethod
  void dispose() => revision.dispose();
}

/// Sync check usable from any widget; false when DI isn't configured.
bool isLocallySuppressedArtwork(String mintAccount) =>
    sl.isRegistered<ModerationHideStore>() &&
    sl<ModerationHideStore>().isArtworkHidden(mintAccount);
