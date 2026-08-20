import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/send/widgets/send_sheet.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';

class _MockRemoteConfigService extends Mock implements RemoteConfigService {}

class _MockWalletRepository extends Mock implements WalletRepository {}

class _MockSessionManager extends Mock implements SessionManager {}

const _tezosWallet = WalletInfo(
  id: 'w-tez',
  address: 'tz1abc',
  name: 'Tezos',
  walletType: WalletType.hd,
  chain: 'tezos',
);

/// Linked to the profile, but its key was never imported.
const _watchOnlySolana = WalletInfo(
  id: 'w-sol',
  address: 'SoLaddr',
  name: 'Solana',
  walletType: WalletType.viewOnly,
  chain: 'solana',
);

const _solToken = TokenBalance(
  mint: 'So11111111111111111111111111111111111111112',
  symbol: 'SOL',
  name: 'Solana',
  decimals: 9,
  rawBalance: 1000000000,
  uiBalance: 1.0,
  isNative: true,
);

/// `showSendSheet` is the signer gate for every entry point that already knows
/// the token — the tokens-tab swipe and the token detail screen.
///
/// Why it belongs here and not at those callers: a session holding only a Tezos
/// key could open the *Solana* send flow and walk it to the confirm step, where
/// Solana's executor signs with whatever the global selection is — the Tezos
/// wallet. The only signal the user got was a failed simulation four steps in,
/// which reads as a network problem rather than "you never imported this key".
void main() {
  late _MockSessionManager session;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUp(() {
    final config = _MockRemoteConfigService();
    when(config.refreshIfStale).thenAnswer((_) async {});
    register<RemoteConfigService>(config);

    session = _MockSessionManager();
    // The session's only *signable* wallet is the Tezos one; the Solana wallet
    // is linked watch-only, so it is absent from the `canSign`-gated lookup and
    // present in the plural one.
    when(
      () => session.sessionWalletForChain(Chain.tezos),
    ).thenReturn(_tezosWallet);
    when(() => session.sessionWalletForChain(Chain.solana)).thenReturn(null);
    when(() => session.sessionWalletForChain(Chain.ethereum)).thenReturn(null);
    when(
      () => session.sessionWalletsForChain(Chain.solana),
    ).thenReturn(const [_watchOnlySolana]);
    register<SessionManager>(session);

    final walletRepo = _MockWalletRepository();
    // The globally selected wallet is the signable Tezos one — the state that
    // used to satisfy the gate.
    when(walletRepo.getActiveWallet).thenAnswer((_) async => _tezosWallet);
    register<WalletRepository>(walletRepo);
  });

  tearDown(() {
    for (final drop in [
      () => sl.unregister<RemoteConfigService>(),
      () => sl.unregister<SessionManager>(),
      () => sl.unregister<WalletRepository>(),
    ]) {
      drop();
    }
  });

  testWidgets('a Solana send from a session whose Solana wallet is watch-only '
      'never opens the sheet — it offers the import route instead', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showSendSheet(context, initialToken: _solToken),
            child: const Text('send'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('send'));
    await tester.pumpAndSettle();

    // The import prompt, not the send flow: no recipient step, no token list.
    expect(find.text('Import wallet'), findsOneWidget);
    expect(find.text('Watch-only wallet'), findsOneWidget);
    expect(find.text('Send'), findsNothing);
  });
}
