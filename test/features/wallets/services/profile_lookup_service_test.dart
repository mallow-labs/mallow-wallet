import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mocktail/mocktail.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockApi extends Mock implements MallowApiClient {}

WalletInfo _held(String address, {int sort = 0, String chain = 'solana'}) =>
    WalletInfo(
      id: 'id-$address',
      address: address,
      name: address,
      walletType: WalletType.hd,
      chain: chain,
      sortIndex: sort,
    );

// The user's real ETH wallet: stored EIP-55 checksummed, indexed lowercase.
const _ethChecksummed = '0x8332F42F02ef59D9425BD291F5901736bED1F801';
const _ethLower = '0x8332f42f02ef59d9425bd291f5901736bed1f801';

/// One bulk-lookup entry. [profileAddresses] is the profile's FULL linked set
/// (wire: `user.addresses`); [submittedHeld] is the subset of submitted
/// addresses that matched (wire: `linkedAddresses`) — i.e. the wallets the
/// user actually holds for this profile.
BulkUserEntry _entry({
  required List<String> profileAddresses,
  required List<String> submittedHeld,
  String? username,
}) => BulkUserEntry(
  user: UserPreview(username: username, addresses: profileAddresses),
  linkedAddresses: submittedHeld,
);

BulkUserLookupResponse _response(List<BulkUserEntry> users) =>
    BulkUserLookupResponse(result: BulkLookupResult(users: users));

void main() {
  late ProfileLookupService service;
  late _MockApi api;

  setUpAll(
    () => registerFallbackValue(const BulkUserLookupRequest(addresses: [])),
  );

  setUp(() {
    api = _MockApi();
    service = ProfileLookupService(api);
  });

  group('buildProfileGroups — linked-wallet materialization', () {
    test('a profile shows ALL linked wallets even when only one is imported; '
        'unheld ones become view-only', () {
      // The user holds only HELD, but the profile links HELD + UNHELD.
      final response = _response([
        _entry(
          username: 'alice',
          profileAddresses: const ['HELD', 'UNHELD'],
          submittedHeld: const ['HELD'],
        ),
      ]);

      final (profiles, _) = service.buildProfileGroups([
        _held('HELD'),
      ], response);

      expect(profiles, hasLength(1));
      final wallets = profiles.single.wallets;
      expect(wallets.map((w) => w.address), ['HELD', 'UNHELD']);

      final placeholder = wallets.firstWhere((w) => w.address == 'UNHELD');
      // The unheld linked wallet is a non-signing view-only placeholder.
      expect(placeholder.walletType, WalletType.viewOnly);
      expect(placeholder.canSign, isFalse);
      // It is synthetic — the held wallet keeps its real type.
      expect(
        wallets.firstWhere((w) => w.address == 'HELD').walletType,
        WalletType.hd,
      );
    });

    test('placeholders never leak into the anon group (accounts list)', () {
      final response = _response([
        _entry(
          username: 'alice',
          profileAddresses: const ['HELD', 'UNHELD'],
          submittedHeld: const ['HELD'],
        ),
      ]);

      final (_, anon) = service.buildProfileGroups([_held('HELD')], response);

      // Only locally-held wallets ever appear in the anon group; the synthetic
      // UNHELD placeholder must not.
      expect(anon.wallets.map((w) => w.address), isNot(contains('UNHELD')));
    });

    test('importing a previously-unheld address upgrades it: placeholder is '
        'replaced by the held wallet (no view-only entry remains)', () {
      // The user now holds BOTH addresses, so both come back as held.
      final response = _response([
        _entry(
          username: 'alice',
          profileAddresses: const ['HELD', 'UNHELD'],
          submittedHeld: const ['HELD', 'UNHELD'],
        ),
      ]);

      final (profiles, _) = service.buildProfileGroups([
        _held('HELD'),
        _held('UNHELD', sort: 1),
      ], response);

      final wallets = profiles.single.wallets;
      expect(wallets, hasLength(2));
      // No placeholder survives once the address is imported for real.
      expect(wallets.every((w) => w.walletType == WalletType.hd), isTrue);
    });

    test('chain is inferred from address shape for placeholders', () {
      final response = _response([
        _entry(
          username: 'alice',
          profileAddresses: const [
            'HELD',
            '0x52908400098527886E0F7030069857D2E4169EE7',
          ],
          submittedHeld: const ['HELD'],
        ),
      ]);

      final (profiles, _) = service.buildProfileGroups([
        _held('HELD'),
      ], response);

      final eth = profiles.single.wallets.firstWhere(
        (w) => w.address.startsWith('0x'),
      );
      expect(eth.chainEnum, Chain.ethereum);
    });

    test('a held EVM wallet (checksummed) matches its lowercase backend '
        'address — it stays held, never a read-only placeholder', () {
      // Regression: the backend returns the ETH address lowercase, but the
      // imported wallet is stored EIP-55 checksummed. Raw-string matching missed
      // it and synthesized a view-only placeholder for a wallet the user holds,
      // so an imported wallet showed as read-only on the profile.
      final response = _response([
        _entry(
          username: 'alice',
          profileAddresses: const [_ethLower],
          submittedHeld: const [_ethLower],
        ),
      ]);

      final (profiles, anon) = service.buildProfileGroups([
        _held(_ethChecksummed, chain: 'ethereum'),
      ], response);

      final wallets = profiles.single.wallets;
      expect(wallets, hasLength(1));
      final w = wallets.single;
      // Kept as the real imported (signable) wallet — NOT downgraded.
      expect(w.address, _ethChecksummed);
      expect(w.walletType, WalletType.hd);
      expect(w.canSign, isTrue);
      // And it isn't duplicated into the anon accounts list.
      expect(anon.wallets, isEmpty);
    });

    test('anonymous profiles (no identity) materialize no placeholders', () {
      final response = _response([
        _entry(
          // No username/displayName → merged into anon, held wallets only.
          profileAddresses: const ['HELD', 'UNHELD'],
          submittedHeld: const ['HELD'],
        ),
      ]);

      final (profiles, anon) = service.buildProfileGroups([
        _held('HELD'),
      ], response);

      expect(profiles, isEmpty);
      expect(anon.wallets.map((w) => w.address), ['HELD']);
    });
  });

  group('profilesForAddresses — recipient identity in the send flows', () {
    test('empty input short-circuits without hitting the API', () async {
      expect(await service.profilesForAddresses(const []), isEmpty);
      verifyNever(() => api.bulkLookupUsers(any()));
    });

    test('keys are normalized whatever case the response echoes', () async {
      // `linkedAddresses` is an echo of the *submitted* addresses that matched,
      // so its casing is the backend's to choose — today lowercase, but a
      // verbatim echo of the submitted EIP-55 form is the same field. Callers
      // index this map by `apiOwnerAddress` (see the send sheet's `_profiles`),
      // so the key must not depend on which one arrives.
      when(() => api.bulkLookupUsers(any())).thenAnswer(
        (_) async => _response([
          _entry(
            username: 'alice',
            profileAddresses: const [_ethChecksummed],
            submittedHeld: const [_ethChecksummed],
          ),
        ]),
      );

      final profiles = await service.profilesForAddresses(const [
        _ethChecksummed,
      ]);

      expect(profiles[apiOwnerAddress(_ethChecksummed)]?.username, 'alice');
    });

    test(
      'a Solana key keeps its exact case — base58 is case-SENSITIVE',
      () async {
        // The control for the fix above. Two base58 strings differing only in
        // case are two different wallets holding different funds, so a blanket
        // `toLowerCase()` — the naive fix that looks correct on Ethereum — would
        // collapse them and label one wallet with another's profile.
        const solana = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
        when(() => api.bulkLookupUsers(any())).thenAnswer(
          (_) async => _response([
            _entry(
              username: 'bob',
              profileAddresses: const [solana],
              submittedHeld: const [solana],
            ),
          ]),
        );

        final profiles = await service.profilesForAddresses(const [solana]);

        expect(profiles[solana]?.username, 'bob');
      },
    );
  });

  group('namedProfileIdForAddresses — create-profile wallet eligibility', () {
    test('empty input short-circuits without hitting the API', () async {
      expect(await service.namedProfileIdForAddresses(const []), isEmpty);
      verifyNever(() => api.bulkLookupUsers(any()));
    });

    test(
      'addresses linked to a NAMED profile are reported as attached',
      () async {
        when(() => api.bulkLookupUsers(any())).thenAnswer(
          (_) async => _response([
            _entry(
              username: 'alice',
              profileAddresses: const ['A', 'B'],
              submittedHeld: const ['A'],
            ),
          ]),
        );

        final owners = await service.namedProfileIdForAddresses(const [
          'A',
          'C',
        ]);

        // Only the submitted address that matched a named profile is flagged —
        // `C` is unlinked, so it stays eligible to back a new profile.
        expect(owners, {'A': 'alice'});
      },
    );

    test('a display-name-only user still counts as a named profile', () async {
      when(() => api.bulkLookupUsers(any())).thenAnswer(
        (_) async => _response([
          const BulkUserEntry(
            user: UserPreview(displayName: 'Bob', addresses: ['A']),
            linkedAddresses: ['A'],
          ),
        ]),
      );

      expect(await service.namedProfileIdForAddresses(const ['A']), {'A': 'A'});
    });

    test(
      'anonymous users (no username/displayName) leave wallets eligible',
      () async {
        // A wallet that has logged in but never claimed a profile must remain
        // selectable — this is the core rule that lets you create a profile from
        // wallets you already use.
        when(() => api.bulkLookupUsers(any())).thenAnswer(
          (_) async => _response([
            _entry(profileAddresses: const ['A'], submittedHeld: const ['A']),
          ]),
        );

        expect(await service.namedProfileIdForAddresses(const ['A']), isEmpty);
      },
    );

    test('a checksummed EVM wallet resolves its named profile despite the '
        'backend returning the lowercase form', () async {
      // Regression: the eligibility map must key on the normalized address so a
      // checksummed local wallet resolves the profile it belongs to (otherwise
      // it looks unlinked and the picker offers/handles it wrongly).
      when(() => api.bulkLookupUsers(any())).thenAnswer(
        (_) async => _response([
          _entry(
            username: 'alice',
            profileAddresses: const [_ethLower],
            submittedHeld: const [_ethLower],
          ),
        ]),
      );

      final owners = await service.namedProfileIdForAddresses(const [
        _ethChecksummed,
      ]);

      expect(owners, {_ethLower: 'alice'});
    });
  });
}
