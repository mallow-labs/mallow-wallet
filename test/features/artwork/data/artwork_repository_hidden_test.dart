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

// `/v0/hide` writes ONE of two flags depending on how the caller relates to the
// artwork: `isCreatorHidden` when they minted it, `isOwnerHidden` when they
// merely hold it. A creator who has since sold their work therefore only ever
// gets the creator flag back, and reading `isOwnerHidden` alone made their
// hidden artwork read as visible — the hide silently undid itself on the next
// refresh. Both flags are requestor-gated server-side (only the wallet that set
// one receives it), so the client folds them together with no address check of
// its own.
void main() {
  const mint = 'Mint111111111111111111111111111111111111111';

  NftDetail detail({bool creatorHidden = false, bool ownerHidden = false}) =>
      NftDetail(
        mintAccount: mint,
        name: 'Artwork',
        isCreatorHidden: creatorHidden,
        isOwnerHidden: ownerHidden,
      );

  Future<bool> hiddenFor(NftDetail item) async {
    final details = await ArtworkRepository(
      _FakeApi(item),
    ).getArtworkDetail(mint);
    return details.isHidden;
  }

  test('a creator who hid their own mint sees it as hidden', () async {
    expect(await hiddenFor(detail(creatorHidden: true)), isTrue);
  });

  test('an owner who hid the artwork sees it as hidden', () async {
    expect(await hiddenFor(detail(ownerHidden: true)), isTrue);
  });

  test('neither flag set leaves the artwork visible', () async {
    expect(await hiddenFor(detail()), isFalse);
  });
}
