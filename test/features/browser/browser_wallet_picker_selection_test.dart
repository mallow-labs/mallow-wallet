import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_wallet_picker.dart';
import 'package:mallow_wallet/features/wallets/services/wallet_drawer_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

const solana = WalletInfo(
  id: 'solana',
  address: '11111111111111111111111111111111',
  name: 'Solana',
  walletType: WalletType.hd,
  chain: 'solana',
);
const ethereum = WalletInfo(
  id: 'ethereum',
  address: '0x1111111111111111111111111111111111111111',
  name: 'Ethereum',
  walletType: WalletType.hd,
  chain: 'ethereum',
);
const tezos = WalletInfo(
  id: 'tezos',
  address: 'tz1abcdefghijklmnopqrstuvwxyz',
  name: 'Tezos',
  walletType: WalletType.hd,
  chain: 'tezos',
);
const loaded = WalletDrawerState.loaded(
  activeWalletId: 'solana',
  accounts: [
    Account(id: 'main', name: 'Main', wallets: [solana, ethereum, tezos]),
  ],
  profileGroups: [
    ProfileGroup(
      userId: 'profile',
      username: 'Profile',
      isAnon: false,
      wallets: [solana, ethereum, tezos],
    ),
  ],
  anonGroup: ProfileGroup(wallets: [], isAnon: true),
);

void main() {
  for (final displayed in [solana, ethereum, tezos]) {
    testWidgets('highlights only the ${displayed.chain} pill wallet', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: MallowTheme.lightTheme,
            home: Scaffold(
              body: BrowserWalletPicker(
                state: loaded,
                selected: solana,
                selectedEthereum: ethereum,
                selectedTezos: tezos,
                displayWallet: displayed,
                activeAccountId: 'main',
                host: 'example.com',
                siteConnected: true,
                ethereumConnected: true,
                tezosConnected: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel(RegExp(r', selected$')), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            RegExp('Main, ${displayed.chainEnum.label} .*selected'),
          ),
          findsOneWidget,
        );
        // Connection marks describe grants independently of the one highlight.
        expect(find.text('Connected'), findsNWidgets(3));
        await tester.tap(find.text('Profiles'));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel(RegExp(r', selected$')), findsNothing);
      } finally {
        semantics.dispose();
      }
    });
  }

  for (final signableOnly in [false, true]) {
    testWidgets(
      'signableOnly: $signableOnly ${signableOnly ? 'drops' : 'keeps'} a '
      'watch-only wallet and its group',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const watched = WalletInfo(
          id: 'watched',
          address: '22222222222222222222222222222222',
          name: 'Watched',
          walletType: WalletType.viewOnly,
          chain: 'solana',
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: MallowTheme.lightTheme,
            home: Scaffold(
              body: BrowserWalletPicker(
                state: const WalletDrawerState.loaded(
                  activeWalletId: 'solana',
                  accounts: [
                    Account(id: 'main', name: 'Main', wallets: [solana]),
                    Account(id: 'watch', name: 'Watch', wallets: [watched]),
                  ],
                  profileGroups: [],
                  anonGroup: ProfileGroup(wallets: [], isAnon: true),
                ),
                selected: solana,
                activeAccountId: 'main',
                onlyChain: Chain.solana,
                signableOnly: signableOnly,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Main'), findsOneWidget);
        expect(
          find.text('Watch'),
          signableOnly ? findsNothing : findsOneWidget,
        );
      },
    );
  }
}
