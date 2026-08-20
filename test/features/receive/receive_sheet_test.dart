import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/receive/sheets/receive_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class MockSessionManager extends Mock implements SessionManager {}

class MockWalletManager extends Mock implements WalletManager {}

/// Receive is **display-only**: it needs an address, not a signer. These tests
/// pin that contract — the sheet shows one address, the QR / printed text /
/// clipboard target all agree on it, and nothing here re-points the app-wide
/// signing wallet (`SessionManager.selectSourceWallet`), which would turn
/// opening a QR code into a global, persistent side effect plus a `/v0/login`
/// round trip.
void main() {
  const solA = 'SoLaNaWaLLeTaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  const solB = 'SoLaNaWaLLeTbBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
  const solWatch = 'SoLaNaWaTcHcCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
  const ethAddr = '0x1111111111111111111111111111111111111111';

  WalletInfo wallet(
    String id,
    String address,
    String name, {
    Chain chain = Chain.solana,
    WalletType type = WalletType.hd,
  }) => WalletInfo(
    id: id,
    address: address,
    name: name,
    walletType: type,
    chain: chain.toDbString(),
  );

  late MockSessionManager sessionManager;
  late MockWalletManager walletManager;
  late List<String> clipboardWrites;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUpAll(() async {
    registerFallbackValue(wallet('fallback', solA, 'fallback'));
    if (!sl.isRegistered<PreferencesService>()) {
      SharedPreferences.setMockInitialValues({});
      sl.registerSingleton<PreferencesService>(
        await PreferencesService.create(),
      );
    }
  });

  setUp(() {
    sessionManager = MockSessionManager();
    walletManager = MockWalletManager();
    register<SessionManager>(sessionManager);
    register<WalletManager>(walletManager);

    // Default: an Account session, where the active address is in scope. The
    // sheet narrows the account-resolved address to the session before showing
    // it, so a Profile never displays a wallet it doesn't link.
    when(
      () => sessionManager.scopedToSession(any()),
    ).thenAnswer((i) => i.positionalArguments.first as String);

    when(() => walletManager.getAddress()).thenAnswer((_) async => solA);
    when(
      () => walletManager.getAddress(chain: Chain.ethereum),
    ).thenAnswer((_) async => ethAddr);
    when(
      () => walletManager.getAddress(chain: Chain.tezos),
    ).thenAnswer((_) async => 'tz1Whatever');

    clipboardWrites = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardWrites.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    if (sl.isRegistered<WalletManager>()) sl.unregister<WalletManager>();
  });

  /// Pumps past a sheet's entrance animation and its tap guard. Never
  /// `pumpAndSettle` — the receive sheet shows an indefinite loader until the
  /// address resolves.
  Future<void> settleSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// Mounts a host screen and opens the receive sheet.
  Future<void> openReceive(
    WidgetTester tester, {
    String? address,
    Chain chain = Chain.solana,
  }) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: GestureDetector(
                onTap: () =>
                    showReceiveSheet(context, address: address, chain: chain),
                child: const Text('open-receive'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-receive'));
    await settleSheet(tester);
  }

  testWidgets('shows the active address for the chain', (tester) async {
    when(
      () => sessionManager.sessionWalletsForChain(Chain.solana),
    ).thenReturn([wallet('a', solA, 'Wallet A')]);
    when(() => sessionManager.scopedToSession(solA)).thenReturn(solA);

    await openReceive(tester);

    expect(find.text(solA), findsOneWidget);
  });

  testWidgets('never hands out an address the session does not hold', (
    tester,
  ) async {
    // A Profile linking no wallet on this chain. `getAddress(chain:)` still
    // answers — it resolves from the active *account*, whose Solana/ETH/Tezos
    // wallets are auto-derived at creation — so without the session narrowing
    // the QR would invite funds to a wallet outside the profile.
    when(
      () => sessionManager.sessionWalletsForChain(Chain.solana),
    ).thenReturn(const []);
    when(() => sessionManager.scopedToSession(solA)).thenReturn(null);

    await openReceive(tester);

    expect(find.text(solA), findsNothing);
  });

  testWidgets('offers no in-sheet wallet switch, even with several candidates', (
    tester,
  ) async {
    when(() => sessionManager.sessionWalletsForChain(Chain.solana)).thenReturn([
      wallet('a', solA, 'Wallet A'),
      wallet('b', solB, 'Wallet B'),
    ]);

    await openReceive(tester);

    // The sheet is one address, full stop — picking between session wallets
    // belongs to `showWalletsReceiveSheet`, which opens this sheet per wallet.
    expect(find.text(solA), findsOneWidget);
    expect(find.text('Switch'), findsNothing);
    expect(find.textContaining('Receiving to'), findsNothing);
    expect(find.text('Wallet A'), findsNothing);
  });

  testWidgets('the QR, the printed address and the copy target agree', (
    tester,
  ) async {
    when(() => sessionManager.sessionWalletsForChain(Chain.solana)).thenReturn([
      wallet('a', solA, 'Wallet A'),
      wallet('b', solB, 'Wallet B'),
    ]);

    await openReceive(tester, address: solB);

    // A QR showing one wallet while Copy yields another is a fund-loss path,
    // so all three are asserted in the same frame.
    expect(find.text(solB), findsOneWidget);
    expect(find.byKey(const ValueKey('receive-qr-$solB')), findsOneWidget);
    expect(find.text(solA), findsNothing);
    expect(find.byKey(const ValueKey('receive-qr-$solA')), findsNothing);

    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(clipboardWrites, [solB]);

    // Flush the "Copied" reset + snackbar timers.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('falls back to a view-only session wallet as a receive target', (
    tester,
  ) async {
    // `sessionWalletsForChain` includes view-only wallets by design — you can
    // always receive into a watch-only address. This is the deliberate
    // difference from the send-side, `canSign`-gated candidate list.
    when(
      () => sessionManager.sessionWalletsForChain(Chain.solana),
    ).thenReturn([wallet('w', solWatch, 'Watcher', type: WalletType.viewOnly)]);
    when(() => walletManager.getAddress()).thenThrow(Exception('no wallet'));

    await openReceive(tester);

    expect(find.text(solWatch), findsOneWidget);
    expect(find.byKey(const ValueKey('receive-qr-$solWatch')), findsOneWidget);
  });

  testWidgets('never re-points the signing wallet', (tester) async {
    when(() => sessionManager.sessionWalletsForChain(Chain.solana)).thenReturn([
      wallet('a', solA, 'Wallet A'),
      wallet('b', solB, 'Wallet B'),
    ]);

    await openReceive(tester, address: solB);

    expect(find.text(solB), findsOneWidget);
    // The core constraint of this surface: a read-only action must not trigger
    // the app-wide signer switch (and its `/v0/login` round trip).
    verifyNever(() => sessionManager.selectSourceWallet(any()));
    verifyNever(() => walletManager.switchWalletById(any()));
  });

  testWidgets('an Ethereum sheet with no explicit address shows the ETH '
      'address, not the Solana one', (tester) async {
    when(
      () => sessionManager.sessionWalletsForChain(Chain.ethereum),
    ).thenReturn([wallet('e', ethAddr, 'ETH Wallet', chain: Chain.ethereum)]);

    await openReceive(tester, chain: Chain.ethereum);

    // Regression: the address was previously resolved with a chain-blind
    // `getAddress()`, rendering the Solana address under an ETH glyph and
    // "Only send Ethereum tokens" copy.
    expect(find.text(ethAddr), findsOneWidget);
    expect(find.text(solA), findsNothing);
    expect(
      find.text('Only send Ethereum tokens to this address'),
      findsOneWidget,
    );
    verify(() => walletManager.getAddress(chain: Chain.ethereum)).called(1);
    verifyNever(() => walletManager.getAddress());
  });
}
