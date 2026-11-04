import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_action_state.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import '../../market/opensea_fixtures.dart';

void main() {
  ArtworkActionState resolve(
    ArtworkDetails a, {
    String? address = buyer,
    Set<String> sessionAddresses = const {},
  }) => resolveArtworkActionState(
    artwork: a,
    currentAddress: address,
    sessionAddresses: sessionAddresses,
    creatorLinkedAddresses: const {},
    permissions: null,
  );
  final listed = artwork.copyWith(
    lastSource: MarketSource.opensea,
    listingType: ListingType.buyNow,
  );

  test('OpenSea Ethereum listing routes to native review', () {
    expect(resolve(listed), isA<ArtworkOpenSeaBuyAction>());
  });
  test('sign-in precedes OpenSea purchase for disconnected viewer', () {
    expect(resolve(listed, address: null), isA<ArtworkConnectWalletAction>());
  });
  test(
    'owner detection includes session wallets and normalizes EVM casing',
    () {
      final owned = listed.copyWith(ownerAddress: contract);
      expect(
        resolve(owned, address: contract.toUpperCase()),
        isA<ArtworkNoAction>(),
      );
      expect(
        resolve(owned, sessionAddresses: {contract.toUpperCase()}),
        isA<ArtworkNoAction>(),
      );
    },
  );
  test('other external marketplaces cannot reach the OpenSea builder', () {
    expect(
      resolve(listed.copyWith(lastSource: MarketSource.objkt)),
      isA<ArtworkNoAction>(),
    );
  });
  test('unlisted provenance cannot offer an OpenSea purchase', () {
    expect(
      resolve(listed.copyWith(listingType: ListingType.unlisted)),
      isA<ArtworkNoAction>(),
    );
  });
}
