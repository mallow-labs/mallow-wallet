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

/// Phase 4b — the send flow's entry gate.
///
/// `showSendSheet` cannot be gated: neither the chain nor the native-vs-token
/// split exists until a row here is tapped. So this picker is where the
/// per-cell promise of the whole design either holds or quietly doesn't —
/// every assertion below is about the gate reading the *right* cell, not
/// merely reading one.
void main() {
  const sol = TokenBalance(
    mint: 'So11111111111111111111111111111111111111112',
    symbol: 'SOL',
    name: 'Solana',
    decimals: 9,
    rawBalance: 1000000000,
    uiBalance: 1.0,
    isNative: true,
  );
  const usdc = TokenBalance(
    mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
    rawBalance: 5000000,
    uiBalance: 5.0,
  );
  const eth = TokenBalance(
    mint: TokenBalance.evmNativeSentinel,
    symbol: 'ETH',
    name: 'Ethereum',
    decimals: 18,
    rawBalance: 1000000000,
    uiBalance: 1.0,
    isNative: true,
    chain: Chain.ethereum,
  );

  late MockTokenBalanceBloc tokenBalanceBloc;
  late ValueNotifier<RemoteConfig> config;

  setUp(() {
    tokenBalanceBloc = MockTokenBalanceBloc();
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.loaded(
        tokens: [sol, usdc, eth],
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

  /// Seeds the kill switch with `'<chain>:<flow>' -> message` cells.
  void kill(Map<String, String> cells) =>
      config.value = RemoteConfig(disabledMessages: cells);

  late List<TokenBalance> selected;

  Future<void> pumpPicker(WidgetTester tester) async {
    selected = [];
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: BlocProvider<TokenBalanceBloc>.value(
            value: tokenBalanceBloc,
            child: SendTokenSelectStep(onSelected: selected.add),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('killing solana:token-send leaves native SOL sends working', (
    tester,
  ) async {
    // The finest-grained claim in the design: native and token sends are
    // separate cells on the *same chain*. A gate that keyed off the chain
    // alone — or off "is this the send flow" — would take SOL down with USDC
    // and nothing else in the stack would notice.
    kill({'solana:token-send': 'SPL sends are paused.'});
    await pumpPicker(tester);

    await tester.tap(find.text('Solana'));
    expect(selected.single.symbol, 'SOL');

    await tester.tap(find.text('USD Coin'));
    expect(selected.length, 1, reason: 'the killed SPL row must be inert');
  });

  testWidgets(
    'killing ethereum:native-send leaves solana:native-send working',
    (tester) async {
      // Per-chain granularity — "kill EVM send without killing Solana send" is
      // the feature's flagship example.
      kill({'ethereum:native-send': 'Ethereum sends are paused.'});
      await pumpPicker(tester);

      await tester.tap(find.text('Ethereum'));
      expect(selected, isEmpty);

      await tester.tap(find.text('Solana'));
      expect(selected.single.chain, Chain.solana);
    },
  );

  testWidgets('a killed row surfaces the server message verbatim', (
    tester,
  ) async {
    // Rendered, not filtered out, and not reworded: mid-incident the
    // operator's copy is the only thing that can tell a user their funds are
    // safe, and a row that simply vanishes reads as "my token is gone".
    const message =
        'Ethereum sends are paused while we fix a fee-estimation bug. '
        'Your funds are safe.';
    kill({'ethereum:native-send': message});
    await pumpPicker(tester);

    expect(find.text(message), findsOneWidget);
    expect(find.text('Ethereum'), findsOneWidget);
  });

  testWidgets('a config refresh landing after the picker opens re-gates it', (
    tester,
  ) async {
    // `showSendSheet` fires `refreshIfStale()` fire-and-forget on the way in,
    // so the answer routinely arrives a beat after these rows are on screen.
    // If the picker read the value once, that refresh would be pointless.
    await pumpPicker(tester);
    await tester.tap(find.text('Solana'));
    expect(selected.length, 1);

    kill({'solana:native-send': 'SOL sends are paused.'});
    await tester.pump();

    await tester.tap(find.text('Solana'));
    expect(selected.length, 1);
    expect(find.text('SOL sends are paused.'), findsOneWidget);
  });
}
