import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/send/widgets/send_token_select_step.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class MockRemoteConfigService extends Mock implements RemoteConfigService {}

/// The send picker lists the same holdings as the tokens portfolio and is
/// reached from those same rows, so a different order here reads as a
/// different set of tokens — and burying the gas token the user needs for fees
/// under a pile of dust airdrops is the concrete failure. These assertions are
/// about the picker matching the portfolio's shape, not about sorting per se.
void main() {
  const sol = TokenBalance(
    mint: 'So11111111111111111111111111111111111111112',
    symbol: 'SOL',
    name: 'Solana',
    decimals: 9,
    rawBalance: 1000000000,
    uiBalance: 1.0,
    totalUsdValue: 12.0,
    isNative: true,
    isVerified: true,
  );
  const eth = TokenBalance(
    mint: TokenBalance.evmNativeSentinel,
    symbol: 'ETH',
    name: 'Ethereum',
    decimals: 18,
    rawBalance: 1000000000,
    uiBalance: 1.0,
    totalUsdValue: 3.0,
    isNative: true,
    isVerified: true,
    chain: Chain.ethereum,
  );
  const usdc = TokenBalance(
    mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
    rawBalance: 5000000,
    uiBalance: 5.0,
    totalUsdValue: 500.0,
    isVerified: true,
  );
  const bonk = TokenBalance(
    mint: 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263',
    symbol: 'BONK',
    name: 'Bonk',
    decimals: 5,
    rawBalance: 100000,
    uiBalance: 1.0,
    totalUsdValue: 50.0,
    isVerified: true,
  );
  // Worth more than every verified holding: a value sort alone would put it at
  // the very top of the picker.
  const scam = TokenBalance(
    mint: 'ScAm11111111111111111111111111111111111111',
    symbol: 'FREE',
    name: 'Free Airdrop',
    decimals: 6,
    rawBalance: 1000000,
    uiBalance: 1.0,
    totalUsdValue: 9999.0,
  );

  late MockTokenBalanceBloc tokenBalanceBloc;
  late ValueNotifier<RemoteConfig> config;

  setUp(() {
    tokenBalanceBloc = MockTokenBalanceBloc();
    // Deliberately arbitrary order in — the picker, not the bloc, owns the
    // display order.
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.loaded(
        tokens: [bonk, scam, eth, usdc, sol],
        totalUsdValue: 0,
      ),
    );

    config = ValueNotifier(RemoteConfig.permissive);
    final service = MockRemoteConfigService();
    when(() => service.config).thenReturn(config);
    when(service.refreshIfStale).thenAnswer((_) async {});
    if (sl.isRegistered<RemoteConfigService>()) {
      sl.unregister<RemoteConfigService>();
    }
    sl.registerFactory<RemoteConfigService>(() => service);
  });

  tearDown(() {
    if (sl.isRegistered<RemoteConfigService>()) {
      sl.unregister<RemoteConfigService>();
    }
    config.dispose();
  });

  Future<void> pumpPicker(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: BlocProvider<TokenBalanceBloc>.value(
            value: tokenBalanceBloc,
            child: SendTokenSelectStep(onSelected: (_) {}),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Vertical order of [labels] as laid out on screen.
  List<String> orderOf(WidgetTester tester, List<String> labels) {
    final positioned = [
      for (final label in labels)
        (label, tester.getTopLeft(find.text(label)).dy),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final entry in positioned) entry.$1];
  }

  testWidgets('gas tokens lead, then holdings by value, unverified last', (
    tester,
  ) async {
    await pumpPicker(tester);

    expect(
      orderOf(tester, [
        'Solana',
        'Ethereum',
        'USD Coin',
        'Bonk',
        'Unverified tokens',
        'Free Airdrop',
      ]),
      // SOL before ETH is the portfolio's fixed gas-token order, not a value
      // sort — ETH is the *least* valuable holding here and still outranks the
      // $500 USDC position.
      [
        'Solana',
        'Ethereum',
        'USD Coin',
        'Bonk',
        'Unverified tokens',
        'Free Airdrop',
      ],
    );
  });

  testWidgets('an unverified mint stays under its header while searching', (
    tester,
  ) async {
    // The search results are the same list, so they keep the same sections —
    // otherwise a searched-for airdrop would lose the "unverified" warning
    // precisely when the user is looking straight at it.
    await pumpPicker(tester);
    await tester.enterText(find.byType(TextField), 'free');
    await tester.pump();

    expect(find.text('USD Coin'), findsNothing);
    expect(orderOf(tester, ['Unverified tokens', 'Free Airdrop']), [
      'Unverified tokens',
      'Free Airdrop',
    ]);
  });
}
