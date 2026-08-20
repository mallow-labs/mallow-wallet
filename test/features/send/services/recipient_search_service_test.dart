import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/send/services/recipient_search_service.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'recipient_search_service_test.mocks.dart';

/// Real, decodable addresses. The service validates by decoding, not by shape,
/// so placeholder strings would be filtered out and hide whatever the test
/// meant to assert.
const _sol1 = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
const _sol2 = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
const _eth = '0x1234567890123456789012345678901234567890';
const _tez = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';

ApiResponse<UserSearchResponse> _response(List<Map<String, dynamic>> users) {
  return ApiResponse<UserSearchResponse>(
    result: UserSearchResponse.fromJson({
      'usersWithDetails': [
        for (final u in users) {'user': u},
      ],
    }),
  );
}

@GenerateMocks([MallowApiClient])
void main() {
  late MockMallowApiClient api;
  late RecipientSearchService service;

  setUpAll(() {
    // Mockito cannot synthesize a generic ApiResponse<T>; without this every
    // stubbed call throws MissingDummyValueError before reaching the stub.
    provideDummy<ApiResponse<UserSearchResponse>>(
      const ApiResponse<UserSearchResponse>(result: UserSearchResponse()),
    );
  });

  setUp(() {
    api = MockMallowApiClient();
    service = RecipientSearchService(api);
  });

  group('query normalization', () {
    test('strips a leading @ so the sent query matches the typed handle', () {
      // The gate in RecipientSearchController measures the handle without its
      // @; sending the @ through would let a 32-character handle be rejected
      // by the backend's own 200-char cap boundary differently than the client
      // measured it, and shifts the server's cache key for the same search.
      when(api.searchUsers(any)).thenAnswer((_) async => _response([]));

      service.search('@alice', Chain.solana);

      final body =
          verify(api.searchUsers(captureAny)).captured.single
              as Map<String, dynamic>;
      expect(body['query'], 'alice');
    });

    test('does not call the API for an empty query', () async {
      final result = await service.search('   ', Chain.solana);

      expect(result, isEmpty);
      verifyNever(api.searchUsers(any));
    });
  });

  group('chain filtering', () {
    test('keeps only the addresses valid on the requested chain', () async {
      // A mallow profile links a wallet per chain. Handing the send flow an
      // address from the wrong chain produces a recipient its validator
      // rejects — after the user picked a row that looked correct.
      when(api.searchUsers(any)).thenAnswer(
        (_) async => _response([
          {
            'username': 'alice',
            'addresses': [_eth, _sol1, _tez],
          },
        ]),
      );

      final result = await service.search('alice', Chain.solana);

      expect(result.map((s) => s.address), [_sol1]);
    });

    test('drops a user with no address on the requested chain', () async {
      // The dropdown shows nothing rather than an unreachable row: the empty
      // state names the chain, so "alice has no Tezos wallet" is legible.
      when(api.searchUsers(any)).thenAnswer(
        (_) async => _response([
          {
            'username': 'alice',
            'addresses': [_sol1],
          },
        ]),
      );

      final result = await service.search('alice', Chain.tezos);

      expect(result, isEmpty);
    });

    test('matches Ethereum and Tezos addresses on their own chains', () async {
      when(api.searchUsers(any)).thenAnswer(
        (_) async => _response([
          {
            'username': 'alice',
            'addresses': [_sol1, _eth, _tez],
          },
        ]),
      );

      expect(
        (await service.search('alice', Chain.ethereum)).map((s) => s.address),
        [_eth],
      );
      expect(
        (await service.search('alice', Chain.tezos)).map((s) => s.address),
        [_tez],
      );
    });
  });

  group('address fan-out', () {
    test(
      'emits one suggestion per matching address of the same user',
      () async {
        // Deliberate divergence from the webapp, which collapses a user to
        // addresses[0]. Two linked Solana wallets are two real destinations;
        // silently picking one would send to the wrong wallet.
        when(api.searchUsers(any)).thenAnswer(
          (_) async => _response([
            {
              'username': 'alice',
              'imageUrl': 'https://img/alice.png',
              'addresses': [_sol1, _sol2],
            },
          ]),
        );

        final result = await service.search('alice', Chain.solana);

        expect(result, hasLength(2));
        expect(result.map((s) => s.address), [_sol1, _sol2]);
        // Same profile on both rows — only the address separates them, which is
        // why the row renders it.
        expect(result.every((s) => s.username == 'alice'), isTrue);
        expect(
          result.every((s) => s.imageUrl == 'https://img/alice.png'),
          isTrue,
        );
      },
    );

    test('keeps backend order, with one user\'s addresses adjacent', () async {
      // The backend sorts by follower count; re-ordering here would bury the
      // most likely recipient below a long-tail match.
      when(api.searchUsers(any)).thenAnswer(
        (_) async => _response([
          {
            'username': 'alice',
            'addresses': [_sol1, _sol2],
          },
          {
            'username': 'alicecooper',
            'addresses': ['EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'],
          },
        ]),
      );

      final result = await service.search('alice', Chain.solana);

      expect(result.map((s) => s.username), ['alice', 'alice', 'alicecooper']);
    });

    test('dedupes a repeated address', () async {
      // The endpoint merges two queries by username, so an anonymous profile
      // can surface twice and would otherwise render as identical rows.
      when(api.searchUsers(any)).thenAnswer(
        (_) async => _response([
          {
            'username': 'alice',
            'addresses': [_sol1],
          },
          {
            'username': 'alice',
            'addresses': [_sol1],
          },
        ]),
      );

      final result = await service.search('alice', Chain.solana);

      expect(result, hasLength(1));
    });
  });

  group('failure handling', () {
    test('returns no suggestions when the endpoint throws', () async {
      // The field still accepts a pasted address, so a search outage must
      // degrade to "no suggestions" — never to a blocked or erroring input.
      when(api.searchUsers(any)).thenThrow(Exception('boom'));

      final result = await service.search('alice', Chain.solana);

      expect(result, isEmpty);
    });
  });

  group('suggestion labelling', () {
    test(
      'falls back to display name when the profile has no username',
      () async {
        // The backend matches on display name too, so a result without a
        // username is a real match and must stay tappable.
        when(api.searchUsers(any)).thenAnswer(
          (_) async => _response([
            {
              'displayName': 'Alice A',
              'addresses': [_sol1],
            },
          ]),
        );

        final result = await service.search('alice', Chain.solana);

        expect(result.single.label, 'Alice A');
        // No @ prefix: it would read as a handle that does not exist.
        expect(result.single.fieldText, 'Alice A');
      },
    );

    test('a username is prefixed with @ in the field', () async {
      when(api.searchUsers(any)).thenAnswer(
        (_) async => _response([
          {
            'username': 'alice',
            'addresses': [_sol1],
          },
        ]),
      );

      final result = await service.search('alice', Chain.solana);

      expect(result.single.fieldText, '@alice');
    });

    test(
      'a profile with neither name puts the full address in the field',
      () async {
        // Never the truncated label — that is not a resolvable address.
        when(api.searchUsers(any)).thenAnswer(
          (_) async => _response([
            {
              'addresses': [_sol1],
            },
          ]),
        );

        final result = await service.search(_sol1, Chain.solana);

        expect(result.single.fieldText, _sol1);
      },
    );
  });
}
