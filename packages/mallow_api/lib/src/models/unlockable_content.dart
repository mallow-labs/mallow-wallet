import 'package:freezed_annotation/freezed_annotation.dart';

part 'unlockable_content.freezed.dart';
part 'unlockable_content.g.dart';

/// A piece of gated ("exclusive"/unlockable) content.
///
/// One model for two routes that emit the same shape:
/// - `GET /v1/unlockableContent/myContent` — the creator's own library
///   (`unlockableContent`), which adds
///   an ephemeral [assetUrl];
/// - `item.unlockableContent` on `GET /v0/artwork/byMint/{mint}`
///   (`nftRenderer`), which omits it.
///
/// Every field but `id` is optional so a shape change on either route can
/// never fail the whole parse. In particular the wire field is **`name`**,
/// not `fileName` — an earlier `UnlockableContentRender` model required
/// `fileName` and would have thrown on every response from both routes.
///
/// Consumed by the mint feature to round-trip `unlockableContentIds` through
/// an edit: the v2 edit route reads an empty list as an explicit clear and
/// emits `RemoveExternalPluginAdapter`, destroying the collector's content.
@freezed
sealed class UnlockableContentPreview with _$UnlockableContentPreview {
  const factory UnlockableContentPreview({
    required int id,
    String? name,
    String? thumbnailUrl,
    String? assetUrl,
    @Default(<int>[]) List<int> bundledContentIds,
  }) = _UnlockableContentPreview;

  factory UnlockableContentPreview.fromJson(Map<String, dynamic> json) =>
      _$UnlockableContentPreviewFromJson(json);
}
