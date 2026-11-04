import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/features/walletconnect/services/walletconnect_namespaces.dart';
import 'package:mallow_wallet/features/walletconnect/services/walletconnect_service.dart';
import 'package:mallow_wallet/features/walletconnect/widgets/walletconnect_proposal_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:reown_core/reown_core.dart' show Validation;

const _main = WalletInfo(
  id: 'main',
  address: 'GsbwXfJraMomNxBcjYLcG3mxkBUiyWXAB32fGbSMQRdW',
  name: 'Main',
  walletType: WalletType.hd,
  chain: 'solana',
);
const _second = WalletInfo(
  id: 'second',
  address: '7Yjin2m4pN3sYoHdbUBG2wUKW4vGKgLHrHbPMd1Z1d1c',
  name: 'Second',
  walletType: WalletType.hd,
  chain: 'solana',
);

final _proposal = WalletConnectProposal(
  name: 'Example',
  origin: Uri.parse('https://app.example.org'),
  iconUrl: null,
  validation: Validation.VALID,
  namespaces: const [
    RequestedNamespace(
      namespace: 'solana',
      chains: [walletConnectSolanaMainnet],
      required: false,
    ),
  ],
  candidates: const {
    'solana': [_main],
  },
);

void main() {
  Future<Future<Map<String, WalletInfo>?>> open(
    WidgetTester tester, {
    WalletConnectWalletPicker? pickWallet,
  }) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        navigatorKey: key,
        home: const Scaffold(),
      ),
    );
    final result = showWalletConnectProposalSheet(
      key.currentContext!,
      _proposal,
      pickWallet: pickWallet,
    );
    await tester.pumpAndSettle();
    return result;
  }

  Finder switchButton() => find.bySemanticsLabel('Switch Solana wallet');

  testWidgets('Switch opens the picker for the row and connects its pick', (
    tester,
  ) async {
    final asked = <(Chain, String)>[];
    final result = await open(
      tester,
      pickWallet: (context, chain, current) async {
        asked.add((chain, current.id));
        return _second;
      },
    );
    await tester.tap(switchButton());
    await tester.pumpAndSettle();
    expect(asked, [(Chain.solana, 'main')]);
    await tester.tap(find.byKey(const Key('walletconnect-approve')));
    await tester.pumpAndSettle();
    expect((await result)!['solana']!.id, 'second');
  });

  testWidgets('Backing out of the picker keeps the wallet', (tester) async {
    final result = await open(
      tester,
      pickWallet: (context, chain, current) async => null,
    );
    await tester.tap(switchButton());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('walletconnect-approve')));
    await tester.pumpAndSettle();
    expect((await result)!['solana']!.id, 'main');
  });

  testWidgets('Without a picker, one candidate has nothing to switch to', (
    tester,
  ) async {
    await open(tester);
    expect(switchButton(), findsNothing);
  });
}
