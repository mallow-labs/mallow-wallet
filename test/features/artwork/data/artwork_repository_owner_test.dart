import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_repository.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';

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

// `ArtworkDetails.ownerAddress` is the authority every owner-side transaction
// is signed by: the detail screen re-points the active signer to it before
// pushing the listing flow, and the listing tx is then built with that wallet
// as `seller`. So it has to be the wallet that HOLDS the mint.
//
// The API's `owner` field cannot answer that: it is the holder's mallow
// *profile* (`UserRenderer.renderSingle` drops the per-artwork address and
// emits the profile's whole `addresses` array), so reading it picks whichever
// wallet the user linked first. For a profile with two wallets on the
// artwork's chain that is a coin flip, and losing it means listing an artwork
// held by wallet B while signing as wallet A — a tx that can only revert.
// The holder rides on the sibling top-level `ownerAddress` field.
void main() {
  const mint = 'Mint111111111111111111111111111111111111111';
  const firstLinked = 'EtnrTfgycnvSwcviqjCBzMvazNyv2qp66Wi8YU7THe8P';
  const holder = 'FD3sQ62fPLAf8MrCuWakiqqW6dLV2b6RtrmBy6LC76c7';

  Future<ArtworkDetails> detailsFor(NftDetail item) =>
      ArtworkRepository(_FakeApi(item)).getArtworkDetail(mint);

  test('the signing authority is the holding wallet, not the owner profile’s '
      'first linked wallet', () async {
    final details = await detailsFor(
      const NftDetail(
        mintAccount: mint,
        name: 'Artwork',
        // Same mallow profile, two wallets on the same chain; the piece is
        // held by the second one.
        owner: ApiUserRef(addresses: [firstLinked, holder]),
        ownerAddress: holder,
        ownerAddresses: [holder],
      ),
    );

    expect(details.ownerAddress, holder);
  });

  test('holders come before profile links in the owner-address list', () async {
    final details = await detailsFor(
      const NftDetail(
        mintAccount: mint,
        name: 'Artwork',
        owner: ApiUserRef(addresses: [firstLinked, holder]),
        ownerAddress: holder,
        ownerAddresses: [holder],
      ),
    );

    // The affordance gates match on membership either way, but the EVM holder
    // resolver scans this list in order and must not stop on a linked wallet
    // that doesn't hold the copy.
    expect(details.ownerAddresses, [holder, firstLinked]);
  });

  test(
    'falls back to the owner profile when the API omits the holder',
    () async {
      final details = await detailsFor(
        const NftDetail(
          mintAccount: mint,
          name: 'Artwork',
          owner: ApiUserRef(address: firstLinked),
        ),
      );

      expect(details.ownerAddress, firstLinked);
      expect(details.ownerAddresses, [firstLinked]);
    },
  );
}
