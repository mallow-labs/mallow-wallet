import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_repository.dart';

/// Hand-written fake (no codegen) returning one scripted artwork payload from
/// `getArtworkByMint`; everything else routes through [noSuchMethod].
class _FakeApi implements MallowApiClient {
  _FakeApi(this._item);

  final NftDetail _item;

  @override
  Future<ApiResponse<ArtworkResult>> getArtworkByMint(
    String mintAccount,
  ) async => ApiResponse<ArtworkResult>(result: ArtworkResult(item: _item));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `/v1/artwork/byMint` has always shipped `playbackId` — `NftRenderer`'s
/// detail render spreads the preview render, which fills it from the asset's
/// Mux metadata once transcoding reports `ready`. The field was simply absent
/// from [NftDetail], so deserialization dropped it and the detail screen had no
/// transcode to reach for: every open of a video artwork pulled the
/// multi-megabyte original off a gateway instead.
///
/// The fixtures below are therefore built from raw JSON, not the Dart
/// constructor: the failure being pinned is a *parse* that drops the field, so
/// a test that skips parsing cannot see the bug it exists for. That covers the
/// wire name as well as the mapping behind it.
void main() {
  const mint = 'Mint111111111111111111111111111111111111111';
  const video = 'https://arweave.net/abc123/v.mp4';

  Future<String?> playbackIdFor(Map<String, dynamic> wire) async {
    final details = await ArtworkRepository(
      _FakeApi(
        NftDetail.fromJson({'mintAccount': mint, 'name': 'Artwork', ...wire}),
      ),
    ).getArtworkDetail(mint);
    return details.playbackId;
  }

  test('a transcoded video carries its playback id to the detail model', () {
    expect(
      playbackIdFor({'videoUrl': video, 'playbackId': 'pb123'}),
      completion('pb123'),
    );
  });

  test('a video still awaiting transcode carries none', () {
    // Mux only reports an id once the asset is `ready`, so an untranscoded (or
    // still-processing) video legitimately has none — the player falls back to
    // the original source rather than waiting on a stream that cannot exist.
    expect(playbackIdFor({'videoUrl': video}), completion(isNull));
  });

  test('a still-image artwork carries none', () {
    expect(playbackIdFor({}), completion(isNull));
  });
}
