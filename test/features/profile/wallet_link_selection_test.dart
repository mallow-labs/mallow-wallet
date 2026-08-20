import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/features/profile/services/wallet_link_selection.dart';

/// A device wallet. [type] drives signability — view-only wallets have no
/// keypair and so cannot sign the link challenge.
WalletInfo _wallet(
  String address, {
  String chain = 'solana',
  WalletType type = WalletType.hd,
}) => WalletInfo(
  id: 'w-$address',
  address: address,
  name: address,
  walletType: type,
  chain: chain,
);

Account _account(String id, List<WalletInfo> wallets) =>
    Account(id: id, name: id, wallets: wallets);

void main() {
  group('resolveLinkable', () {
    test('drops wallets linked to a different profile', () {
      // A wallet belongs to at most one profile, so offering someone else's
      // would fail server-side on approveLinkRequestV2 — it must never appear.
      final accounts = [
        _account('a1', [_wallet('mine'), _wallet('theirs')]),
      ];

      final result = resolveLinkable(
        accounts: accounts,
        profileIdByAddress: {'theirs': 'someone-else'},
        currentProfileId: 'me',
      );

      expect(result, hasLength(1));
      expect(result.single.wallets.map((w) => w.address), ['mine']);
    });

    test('keeps wallets linked to this profile and flags them', () {
      // The edit flow starts these selected, so an untouched pass produces an
      // empty diff instead of re-linking what is already linked.
      final accounts = [
        _account('a1', [_wallet('linked'), _wallet('free')]),
      ];

      final result = resolveLinkable(
        accounts: accounts,
        profileIdByAddress: {'linked': 'me'},
        currentProfileId: 'me',
      );

      final wallets = {
        for (final w in result.single.wallets) w.address: w.linkedToProfile,
      };
      expect(wallets, {'linked': true, 'free': false});
    });

    test('EVM link-state is matched case-insensitively (checksummed wallet vs '
        'lowercase profile map)', () {
      // Regression: profileIdByAddress is keyed on the normalized (lowercase)
      // EVM form, but a device wallet is stored EIP-55 checksummed. Matching
      // raw strings left an Ethereum wallet looking unlinked — so one linked to
      // another profile was wrongly offered, and one linked to THIS profile
      // never started selected (blocking edit/unlink recovery).
      const checksummed = '0x8332F42F02ef59D9425BD291F5901736bED1F801';
      const lower = '0x8332f42f02ef59d9425bd291f5901736bed1f801';
      const otherChecksummed = '0x52908400098527886E0F7030069857D2E4169EE7';
      const otherLower = '0x52908400098527886e0f7030069857d2e4169ee7';

      final result = resolveLinkable(
        accounts: [
          _account('a1', [
            _wallet(checksummed, chain: 'ethereum'),
            _wallet(otherChecksummed, chain: 'ethereum'),
          ]),
        ],
        profileIdByAddress: const {lower: 'me', otherLower: 'someone-else'},
        currentProfileId: 'me',
      );

      // The other-profile EVM wallet is dropped; ours is kept and flagged.
      final wallets = {
        for (final w in result.single.wallets) w.address: w.linkedToProfile,
      };
      expect(wallets, {checksummed: true});
    });

    test('creating treats every offered wallet as unlinked', () {
      // There is no profile yet, so nothing can be "already linked" — a null
      // currentProfileId must not accidentally match an absent owner entry.
      final result = resolveLinkable(
        accounts: [
          _account('a1', [_wallet('free')]),
        ],
        profileIdByAddress: const {},
        currentProfileId: null,
      );

      expect(result.single.wallets.single.linkedToProfile, isFalse);
    });

    test('an anonymous login stays eligible', () {
      // A wallet that logged in but never claimed a username/display name is
      // absent from the owner map by design (see
      // ProfileLookupService.namedProfileIdForAddresses). Excluding it would
      // strand users who signed in before creating a profile.
      final result = resolveLinkable(
        accounts: [
          _account('a1', [_wallet('anon-login')]),
        ],
        profileIdByAddress: const {},
        currentProfileId: 'me',
      );

      expect(result.single.wallets.map((w) => w.address), ['anon-login']);
    });

    test('view-only wallets are never offered', () {
      // Linking is a dual-signature flow; a view-only wallet has no keypair and
      // would fail at signAndVerifyForWallet.
      final result = resolveLinkable(
        accounts: [
          _account('a1', [
            _wallet('signer'),
            _wallet('watched', type: WalletType.viewOnly),
          ]),
        ],
        profileIdByAddress: const {},
        currentProfileId: null,
      );

      expect(result.single.wallets.map((w) => w.address), ['signer']);
    });

    test('accounts left with no offerable wallet disappear', () {
      // An empty card is noise — the step shows only accounts the user can act
      // on, and an all-empty result is what drives the empty state.
      final result = resolveLinkable(
        accounts: [
          _account('a1', [_wallet('free')]),
          _account('a2', [_wallet('taken')]),
          _account('a3', [_wallet('watched', type: WalletType.viewOnly)]),
        ],
        profileIdByAddress: {'taken': 'someone-else'},
        currentProfileId: 'me',
      );

      expect(result.map((a) => a.account.id), ['a1']);
    });

    test('offers wallets across multiple accounts', () {
      // A profile is no longer anchored to a single account — this is the whole
      // point of the multi-account picker.
      final result = resolveLinkable(
        accounts: [
          _account('a1', [_wallet('sol1'), _wallet('eth1', chain: 'ethereum')]),
          _account('a2', [_wallet('sol2')]),
        ],
        profileIdByAddress: const {},
        currentProfileId: null,
      );

      expect(result, hasLength(2));
      expect(result.expand((a) => a.wallets).map((w) => w.address), [
        'sol1',
        'eth1',
        'sol2',
      ]);
    });
  });

  group('LinkableAccount activity aggregation', () {
    LinkableWallet enriched(
      String address, {
      String chain = 'solana',
      int? art,
      double? usd,
    }) => LinkableWallet(
      wallet: _wallet(address, chain: chain),
      linkedToProfile: false,
      artworkCount: art,
      balanceUsd: usd,
    );

    test('stays unenriched until every wallet has landed', () {
      // A half-loaded aggregate would flash a wrong total, so the header holds
      // its shimmer until the whole account is in.
      final account = LinkableAccount(
        account: _account('a1', const []),
        wallets: [enriched('a', art: 2, usd: 5), enriched('b')],
      );

      expect(account.isEnriched, isFalse);
      expect(account.artworkCount, isNull);
      expect(account.balanceUsd, isNull);
    });

    test('sums across every chain, not just Solana', () {
      // Artwork counts come from the multi-chain v2 portfolio read and balances
      // route per chain, so an ETH or Tezos wallet contributes to the account
      // total like any other. Dropping them would under-report the header.
      final account = LinkableAccount(
        account: _account('a1', const []),
        wallets: [
          enriched('sol', art: 3, usd: 10),
          enriched('eth', chain: 'ethereum', art: 2, usd: 4.5),
          enriched('tez', chain: 'tezos', art: 1, usd: 0.5),
        ],
      );

      expect(account.isEnriched, isTrue);
      expect(account.artworkCount, 6);
      expect(account.balanceUsd, 15);
    });

    test('an all-zero account reads as no activity', () {
      // Enriched-and-empty is what swaps the chips for the "No activity" pill —
      // it must not be confused with still-loading.
      final account = LinkableAccount(
        account: _account('a1', const []),
        wallets: [enriched('sol', art: 0, usd: 0)],
      );

      expect(account.isEnriched, isTrue);
      expect(account.hasActivity, isFalse);
    });
  });

  group('diffSelection', () {
    test('an untouched edit links and unlinks nothing', () {
      // Stepping through the wizard without touching a toggle must not fire a
      // single link/unlink call.
      final diff = diffSelection(
        currentlyLinked: {'a', 'b'},
        selected: {'a', 'b'},
      );

      expect(diff.isEmpty, isTrue);
    });

    test('splits additions from removals', () {
      final diff = diffSelection(
        currentlyLinked: {'a', 'b'},
        selected: {'b', 'c'},
      );

      expect(diff.toLink, {'c'});
      expect(diff.toUnlink, {'a'});
    });

    test('a locked wallet is never unlinked', () {
      // The profile signs with this wallet — removing it would invalidate the
      // session mid-save and could empty the profile entirely.
      final diff = diffSelection(
        currentlyLinked: {'signer', 'other'},
        selected: const {},
        locked: {'signer'},
      );

      expect(diff.toUnlink, {'other'});
      expect(diff.toLink, isEmpty);
    });
  });
}
