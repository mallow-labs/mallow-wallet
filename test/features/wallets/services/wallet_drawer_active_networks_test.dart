import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/features/wallets/services/wallet_drawer_bloc.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

/// The drawer's half of the Active Networks rule: a network the user switched
/// off takes its wallets out of the switcher, the same way it already drops out
/// of the tokens tab, the NFT portfolio, and the import picker.
///
/// The filter is pure so the two properties that make it safe can be pinned
/// without standing up the whole drawer: nothing on a disabled chain is listed,
/// and the wallet the session signs with is listed regardless.
void main() {
  WalletInfo wallet(
    String id,
    String address, {
    String chain = 'solana',
    WalletType type = WalletType.hd,
  }) => WalletInfo(
    id: id,
    address: address,
    name: id,
    walletType: type,
    chain: chain,
  );

  final sol = wallet('w-sol', 'SOL_ADDR');
  final eth = wallet('w-eth', '0xAbC', chain: 'ethereum');
  final tez = wallet('w-tez', 'tz1_ADDR', chain: 'tezos');

  group('walletsOnActiveNetworks', () {
    test('drops wallets on switched-off chains', () {
      final visible = WalletDrawerBloc.walletsOnActiveNetworks(
        [sol, eth, tez],
        disabled: {Chain.tezos},
        activeWalletId: 'w-sol',
      );

      expect(visible.map((w) => w.id), ['w-sol', 'w-eth']);
    });

    test('keeps the active wallet even on a switched-off chain', () {
      final visible = WalletDrawerBloc.walletsOnActiveNetworks(
        [sol, tez],
        disabled: {Chain.tezos},
        activeWalletId: 'w-tez',
      );

      // Why: the header renders the active wallet whether or not the drawer
      // lists it. Hiding it would leave the user on an address with no row to
      // switch away from — a settings toggle must never strand a session.
      expect(visible.map((w) => w.id), ['w-sol', 'w-tez']);
    });

    test('drops a profile placeholder on a switched-off chain', () {
      // Linked-but-unimported addresses reach the drawer as synthetic view-only
      // wallets whose chain is derived from the address, so the same filter has
      // to catch them — they are rows in exactly the same list.
      final placeholder = wallet(
        'view-only:tz1_LINKED',
        'tz1_LINKED',
        chain: 'tezos',
        type: WalletType.viewOnly,
      );

      final visible = WalletDrawerBloc.walletsOnActiveNetworks(
        [sol, placeholder],
        disabled: {Chain.tezos},
        activeWalletId: 'w-sol',
      );

      expect(visible.map((w) => w.id), ['w-sol']);
    });

    test('no toggles off returns the list untouched', () {
      final all = [sol, eth, tez];
      expect(
        WalletDrawerBloc.walletsOnActiveNetworks(
          all,
          disabled: const {},
          activeWalletId: 'w-sol',
        ),
        same(all),
      );
    });
  });

  group('groupsOnActiveNetworks', () {
    ProfileGroup group(String id, List<WalletInfo> wallets) =>
        ProfileGroup(userId: id, username: id, wallets: wallets, isAnon: false);

    test('filters each group and drops the ones left empty', () {
      final groups = WalletDrawerBloc.groupsOnActiveNetworks(
        [
          group('alice', [sol, tez]),
          group('bob', [tez]),
        ],
        disabled: {Chain.tezos},
        activeWalletId: 'w-sol',
      );

      // Why: a group whose every wallet sits on a switched-off network has
      // nothing to show or switch to, and an empty group row reads as a bug.
      expect(groups.map((g) => g.userId), ['alice']);
      expect(groups.single.wallets.map((w) => w.id), ['w-sol']);
    });

    test("the active wallet's group survives", () {
      final groups = WalletDrawerBloc.groupsOnActiveNetworks(
        [
          group('alice', [tez]),
        ],
        disabled: {Chain.tezos},
        activeWalletId: 'w-tez',
      );

      expect(groups.single.wallets.map((w) => w.id), ['w-tez']);
    });
  });
}
