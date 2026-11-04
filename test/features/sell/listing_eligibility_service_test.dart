import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/features/sell/services/listing_eligibility.dart';
import 'package:mallow_wallet/features/sell/services/listing_eligibility_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';

class _Auth extends Mock implements AuthService {}

class _Api extends Mock implements MallowApiClient {}

class _Das extends Mock implements DasApiService {}

void main() {
  late _Auth auth;
  late _Api api;
  late _Das das;
  setUp(() {
    auth = _Auth();
    api = _Api();
    das = _Das();
    GetIt.I.registerSingleton<AuthService>(auth);
    GetIt.I.registerSingleton<MallowApiClient>(api);
    GetIt.I.registerSingleton<DasApiService>(das);
    when(() => auth.currentAddress).thenReturn(null);
    when(() => auth.currentUser).thenReturn(
      const User(
        roles: ['primaryLister'],
        username: 'artist',
        imageUrl: 'image',
        isTwitterVerified: true,
      ),
    );
    when(() => das.getAsset('mint')).thenThrow(StateError('DAS unavailable'));
  });
  tearDown(() => GetIt.I.reset());

  for (final standard in [null, 'nft', 'pnft', 'core', 'cnft', 'cnft-v2']) {
    test(
      'DAS failure for indexed $standard distinguishes unverified assets',
      () async {
        when(() => api.getListingData('mint')).thenAnswer(
          (_) async => ApiResponse(
            result: ListingData(
              nftPreview: ListingDataNftPreview(tokenStandard: standard),
            ),
          ),
        );
        expect(
          await checkListingEligibility(mintAccount: 'mint'),
          standard == null || standard == 'cnft-v2'
              ? ListingBlockReason.unverifiedAsset
              : null,
        );
      },
    );
  }
  test('failed leaf and index reads remain unverified', () async {
    when(() => api.getListingData('mint')).thenThrow(StateError('offline'));
    expect(
      await checkListingEligibility(mintAccount: 'mint'),
      ListingBlockReason.unverifiedAsset,
    );
  });

  for (final restricted in [false, true]) {
    test(
      'v2 collection ${restricted ? 'restriction' : 'lookup failure'} has its own reason',
      () async {
        when(
          () => api.getListingData('mint'),
        ).thenAnswer((_) async => const ApiResponse(result: ListingData()));
        when(() => das.getAsset('mint')).thenAnswer(
          (_) async => DigitalAsset.fromJson({
            'id': 'mint',
            'interface': 'MplBubblegumV2',
            'compression': {'compressed': true, 'flags': 0},
            'grouping': [
              {'group_key': 'collection', 'group_value': 'parent'},
            ],
          }),
        );
        if (restricted) {
          when(() => das.getAsset('parent')).thenAnswer(
            (_) async => DigitalAsset.fromJson({
              'id': 'parent',
              'interface': 'MplCoreCollection',
              'plugins': {
                'permanent_transfer_delegate': {'data': <String, dynamic>{}},
              },
            }),
          );
        } else {
          when(() => das.getAsset('parent')).thenThrow(StateError('offline'));
        }
        expect(
          await checkListingEligibility(mintAccount: 'mint'),
          restricted
              ? ListingBlockReason.ineligibleAsset
              : ListingBlockReason.unverifiedAsset,
        );
        verify(() => das.getAsset('parent')).called(1);
      },
    );
  }
}
