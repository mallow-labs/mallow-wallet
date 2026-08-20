import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/portfolio/widgets/token_burn_flow.dart';
import 'package:mocktail/mocktail.dart';

class MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class MockRemoteConfigService extends Mock implements RemoteConfigService {}

class MockWalletManager extends Mock implements WalletManager {}

class MockSessionManager extends Mock implements SessionManager {}

class MockSessionPortfolioAggregator extends Mock
    implements SessionPortfolioAggregator {}

/// Phase 4b — the `solana:token-burn` entry gate.
void main() {
  const token = TokenBalance(
    mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
    rawBalance: 5000000,
    uiBalance: 5.0,
  );

  setUpAll(
    () => registerFallbackValue(
      const WalletInfo(
        id: 'wallet',
        address: 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH',
        name: 'W',
        walletType: WalletType.hd,
        chain: 'solana',
        accountId: 'acct',
      ),
    ),
  );

  late ValueNotifier<RemoteConfig> config;
  late MockWalletManager walletManager;
  late MockSessionManager sessionManager;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUp(() {
    config = ValueNotifier(RemoteConfig.permissive);
    final service = MockRemoteConfigService();
    when(() => service.config).thenReturn(config);
    when(service.refreshIfStale).thenAnswer((_) async {});
    register<RemoteConfigService>(service);

    walletManager = MockWalletManager();
    sessionManager = MockSessionManager();
    register<WalletManager>(walletManager);
    register<SessionManager>(sessionManager);
    register<SessionPortfolioAggregator>(MockSessionPortfolioAggregator());
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<RemoteConfigService>();
    drop<WalletManager>();
    drop<SessionManager>();
    drop<SessionPortfolioAggregator>();
    config.dispose();
  });

  testWidgets('a killed token-burn refuses before touching the signer', (
    tester,
  ) async {
    // The gate sits *above* `_resolveBurnSource`, which durably re-points the
    // active wallet at whichever one holds the mint. A flow that is about to
    // refuse must not leave the user on a different wallet than they started
    // on as a side effect.
    const message = 'Burns are paused while we investigate a build bug.';
    config.value = const RemoteConfig(
      disabledMessages: {'solana:token-burn': message},
    );

    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await runTokenBurnFlow(
                    context,
                    token: token,
                    tokenBalanceBloc: MockTokenBalanceBloc(),
                  );
                },
                child: const Text('Burn'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Burn'));
    await tester.pumpAndSettle();

    expect(find.text(message), findsOneWidget);
    verifyNever(() => walletManager.getAddress());
    verifyNever(() => sessionManager.selectSourceWallet(any()));

    // The caller sees a plain "didn't burn", same as a cancel.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(result, isFalse);
  });
}
