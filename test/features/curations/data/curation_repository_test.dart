import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/curations/data/curation_repository.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'curation_repository_test.mocks.dart';

@GenerateMocks([api.MallowApiClient])
void main() {
  late MockMallowApiClient client;

  setUpAll(() {
    provideDummy<api.ApiResponse<api.CurationDetail>>(
      const api.ApiResponse(
        result: api.CurationDetail(
          id: 'dummy',
          name: 'Dummy',
          slug: 'dummy',
          visibility: 'public',
          owner: api.CurationOwner(address: 'DUMMY_OWNER'),
        ),
      ),
    );
  });

  setUp(() {
    client = MockMallowApiClient();
  });

  test('preserves the creator username for curation artwork cards', () async {
    const preview = api.NftPreview(
      mintAccount: 'MINT',
      name: 'Artwork',
      creator: api.ApiUserRef(
        address: 'CREATOR_ADDRESS',
        username: 'creator_handle',
        displayName: 'Creator Name',
      ),
    );
    const detail = api.CurationDetail(
      id: 'curation',
      name: 'Curation',
      slug: 'curation',
      visibility: 'public',
      owner: api.CurationOwner(address: 'OWNER_ADDRESS'),
      artworks: [preview],
    );
    when(
      client.getCurationById('curation'),
    ).thenAnswer((_) async => const api.ApiResponse(result: detail));

    final result = await CurationRepository(client).getCurationById('curation');
    final artwork = result.artworks.single;

    expect(artwork.artistUsername, 'creator_handle');
    expect(artwork.artistName, 'creator_handle');
  });
}
