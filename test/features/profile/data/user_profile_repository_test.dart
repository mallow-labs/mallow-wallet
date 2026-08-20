import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/profile/data/profile_image_uploader.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'user_profile_repository_test.mocks.dart';

@GenerateMocks([api.MallowApiClient, api.MallowApiV2Client])
@GenerateNiceMocks([
  MockSpec<MallowDatabase>(),
  MockSpec<PortfolioRepository>(),
  MockSpec<ProfileImageUploader>(),
])
void main() {
  late MockMallowApiClient apiClient;
  late MockMallowApiV2Client apiV2Client;
  late MockMallowDatabase db;
  late MockPortfolioRepository portfolio;
  late MockProfileImageUploader uploader;
  late UserProfileRepository repo;

  api.ApiResponse<api.UserWithDetailsResult> okResponse() =>
      const api.ApiResponse<api.UserWithDetailsResult>(
        result: api.UserWithDetailsResult(
          user: api.User(addresses: ['ADDR'], username: 'bob'),
          userDetails: api.UserDetails(),
        ),
      );

  /// The `UpdateProfileRequest` body posted to /v1/user/updateProfile.
  Map<String, dynamic> capturedBody() =>
      verify(apiClient.updateProfile(captureAny)).captured.single
          as Map<String, dynamic>;

  /// The editable-fields envelope nested under `user`.
  Map<String, dynamic> capturedEnvelope() =>
      capturedBody()['user'] as Map<String, dynamic>;

  setUpAll(() {
    provideDummy<api.ApiResponse<api.UserWithDetailsResult>>(okResponse());
    provideDummy<api.ApiResponse<bool>>(
      const api.ApiResponse<bool>(result: true),
    );
  });

  setUp(() {
    apiClient = MockMallowApiClient();
    apiV2Client = MockMallowApiV2Client();
    db = MockMallowDatabase();
    portfolio = MockPortfolioRepository();
    uploader = MockProfileImageUploader();
    repo = UserProfileRepository(
      apiClient,
      apiV2Client,
      db,
      portfolio,
      uploader,
    );
    when(apiClient.updateProfile(any)).thenAnswer((_) async => okResponse());
    when(
      uploader.upload(
        bytes: anyNamed('bytes'),
        fileName: anyNamed('fileName'),
        type: anyNamed('type'),
      ),
    ).thenAnswer(
      (call) async =>
          '${(call.namedArguments[#type] as api.CreateProfileUploadRequestType).value}'
          '/ADDR/1700000000',
    );
  });

  group('updateProfile envelope', () {
    test('omits fields that are not provided', () async {
      await repo.updateProfile(displayName: 'Bob', bio: 'gm', website: 'x.com');

      final envelope = capturedEnvelope();
      expect(envelope['displayName'], 'Bob');
      expect(envelope['bio'], 'gm');
      expect(envelope['website'], 'x.com');
      // The server treats omitted keys as unchanged — username and email must
      // not appear when the caller didn't change them.
      expect(envelope.containsKey('username'), isFalse);
      expect(envelope.containsKey('email'), isFalse);
    });

    test('sends username when provided', () async {
      await repo.updateProfile(username: 'newname');
      expect(capturedEnvelope()['username'], 'newname');
    });

    test(
      'clearEmail sends an explicit null so the backend detaches it',
      () async {
        await repo.updateProfile(clearEmail: true);

        final envelope = capturedEnvelope();
        // Key present AND null — the backend only clears the email in this case.
        expect(envelope.containsKey('email'), isTrue);
        expect(envelope['email'], isNull);
      },
    );

    // Images go straight to S3 now. The API only ever sees the signed path the
    // upload returned — sending bytes here is what the presigned flow removed.
    test('uploads picked images and sends back their paths', () async {
      await repo.updateProfile(
        pfp: (bytes: Uint8List.fromList([1, 2, 3]), fileName: 'a.png'),
        banner: (bytes: Uint8List.fromList([4, 5, 6]), fileName: 'b.png'),
      );

      verify(
        uploader.upload(
          bytes: anyNamed('bytes'),
          fileName: 'a.png',
          type: api.CreateProfileUploadRequestType.pfp,
        ),
      ).called(1);
      verify(
        uploader.upload(
          bytes: anyNamed('bytes'),
          fileName: 'b.png',
          type: api.CreateProfileUploadRequestType.banner,
        ),
      ).called(1);

      final body = capturedBody();
      expect(body['pfpPath'], 'pfp/ADDR/1700000000');
      expect(body['bannerPath'], 'banner/ADDR/1700000000');
    });

    // `pfpPath`/`bannerPath` are `z.string().optional()` server-side: an
    // explicit null is a 400, so every save without a new image would fail.
    test('omits the image paths entirely when nothing was picked', () async {
      await repo.updateProfile(displayName: 'Bob');

      final body = capturedBody();
      expect(body.containsKey('pfpPath'), isFalse);
      expect(body.containsKey('bannerPath'), isFalse);
      verifyNever(
        uploader.upload(
          bytes: anyNamed('bytes'),
          fileName: anyNamed('fileName'),
          type: anyNamed('type'),
        ),
      );
    });

    // The text fields must not commit against a picture that never landed.
    test('a failed upload aborts the profile write', () async {
      when(
        uploader.upload(
          bytes: anyNamed('bytes'),
          fileName: anyNamed('fileName'),
          type: anyNamed('type'),
        ),
      ).thenThrow(const ProfileImageUploadException('nope'));

      await expectLater(
        repo.updateProfile(
          displayName: 'Bob',
          pfp: (bytes: Uint8List.fromList([1, 2, 3]), fileName: 'a.png'),
        ),
        throwsA(isA<ProfileImageUploadException>()),
      );
      verifyNever(apiClient.updateProfile(any));
    });
  });

  group('getUserArtworks filter', () {
    void stubProfile() {
      when(
        apiClient.getProfile(any),
      ).thenAnswer((_) async => const api.ProfileResponse());
    }

    api.ProfileRequest capturedRequest() =>
        verify(apiClient.getProfile(captureAny)).captured.single
            as api.ProfileRequest;

    // The v1 `listed` branch reads `filter.listingTypes` before defaulting it,
    // so a null filter throws server-side (500). `_onLoadListedArtworks`
    // catches that and settles the tab on its empty state, which silently drops
    // every artwork the profile user created that another owner has listed —
    // the whole point of the Listed tab. A non-null filter is the contract.
    test('sends a filter object when the caller has none', () async {
      stubProfile();

      await repo.getUserArtworks(['ADDR'], tab: api.ApiProfileTab.listed);

      expect(capturedRequest().filter, isNotNull);
    });

    test('forwards an active filter', () async {
      stubProfile();
      const active = api.ExploreFilter(listingTypes: ['auction']);

      await repo.getUserArtworks(
        ['ADDR'],
        tab: api.ApiProfileTab.listed,
        filter: active,
      );

      expect(capturedRequest().filter?.listingTypes, ['auction']);
    });

    // Webapp parity (ProfileMarketplace): an artist's tabs show the master
    // edition, not one tile per print someone re-listed, while the ownership
    // tabs must keep prints because that is what a collector actually holds.
    // The filter sheet never sets hidePrints, so the tab decides it outright —
    // an active filter must not be able to flip it.
    test('hides prints on the creator-facing tabs', () async {
      for (final tab in [api.ApiProfileTab.created, api.ApiProfileTab.listed]) {
        stubProfile();
        await repo.getUserArtworks(['ADDR'], tab: tab);
        expect(capturedRequest().filter?.hidePrints, isTrue, reason: '$tab');
      }
    });

    test('keeps prints on the ownership tabs', () async {
      for (final tab in [
        api.ApiProfileTab.collected,
        api.ApiProfileTab.pinned,
      ]) {
        stubProfile();
        await repo.getUserArtworks(
          ['ADDR'],
          tab: tab,
          // Even a filter that asks to hide them: the tab wins.
          filter: const api.ExploreFilter(hidePrints: true),
        );
        expect(capturedRequest().filter?.hidePrints, isFalse, reason: '$tab');
      }
    });
  });

  group('OTP', () {
    test('sendEmailOtp posts a verifyEmail OTP request', () async {
      when(
        apiClient.createOtp(any),
      ).thenAnswer((_) async => const api.ApiResponse<bool>(result: true));

      await repo.sendEmailOtp('user@example.com');

      final req =
          verify(apiClient.createOtp(captureAny)).captured.single
              as api.CreateOtpRequest;
      expect(req.email, 'user@example.com');
      expect(req.action, api.OtpActions.verifyEmail);
    });
  });
}
