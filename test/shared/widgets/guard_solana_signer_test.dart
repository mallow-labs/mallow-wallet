import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mallow_wallet/shared/widgets/view_only_prompt.dart';

/// `guardViewOnly` let a session whose only key is Tezos into every Solana
/// marketplace flow: the active Tezos wallet *can* sign, just not on Solana.
/// Solana's executor signs with the active wallet and the request names it as
/// the buyer, so the backend received a `tz1…` buyer and refused it.
/// `guardSolanaSigner` answers for Solana specifically.
class _FakeWalletRepository extends Fake implements WalletRepository {
  _FakeWalletRepository(this.active);

  final WalletInfo? active;

  @override
  Future<WalletInfo?> getActiveWallet() async => active;
}

class _FakeSessionManager extends Fake implements SessionManager {
  _FakeSessionManager(this.wallets, {this.switchFails = false});

  final List<WalletInfo> wallets;
  final bool switchFails;
  final switched = <WalletInfo>[];

  @override
  WalletInfo? sessionWalletForChain(Chain chain) {
    for (final w in wallets) {
      if (w.chainEnum == chain && w.canSign) return w;
    }
    return null;
  }

  @override
  List<WalletInfo> sessionWalletsForChain(Chain chain) => [
    for (final w in wallets)
      if (w.chainEnum == chain) w,
  ];

  @override
  Future<void> selectSourceWallet(WalletInfo wallet) async {
    if (switchFails) throw StateError('login failed');
    switched.add(wallet);
  }
}

WalletInfo _wallet(Chain chain, {WalletType walletType = WalletType.hd}) =>
    WalletInfo(
      id: '${walletType.name}-${chain.name}',
      address: 'addr-${walletType.name}-${chain.name}',
      name: 'Wallet',
      walletType: walletType,
      chain: chain.toDbString(),
    );

void main() {
  late _FakeSessionManager session;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  void setUp$({
    required WalletInfo? active,
    required List<WalletInfo> wallets,
    bool switchFails = false,
  }) {
    session = _FakeSessionManager(wallets, switchFails: switchFails);
    register<WalletRepository>(_FakeWalletRepository(active));
    register<SessionManager>(session);
  }

  tearDown(() {
    sl.unregister<WalletRepository>();
    sl.unregister<SessionManager>();
  });

  /// Runs the guard and dismisses whatever prompt it shows, so the import
  /// route is never pushed. [prompt] is the prompt's body or title.
  Future<({bool blocked, String? prompt})> runGuard(WidgetTester tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    late Future<bool> pending;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () =>
                pending = guardSolanaSigner(context, action: 'buy this'),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    String? prompt;
    if (find.text('Import wallet').evaluate().isNotEmpty) {
      prompt = find
          .textContaining('Import')
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .firstWhere((t) => t != 'Import wallet');
    } else if (find.text('View-only wallet').evaluate().isNotEmpty) {
      prompt = 'View-only wallet';
    }
    if (navigatorKey.currentState?.canPop() ?? false) {
      navigatorKey.currentState!.pop();
    }
    await tester.pumpAndSettle();
    return (blocked: await pending, prompt: prompt);
  }

  testWidgets('Tezos-only key with watch-only Solana links → import prompt', (
    tester,
  ) async {
    setUp$(
      active: _wallet(Chain.tezos),
      wallets: [
        _wallet(Chain.tezos),
        _wallet(Chain.solana, walletType: WalletType.viewOnly),
      ],
    );
    final r = await runGuard(tester);
    expect(r.blocked, isTrue);
    expect(
      r.prompt,
      'Your Solana wallet is watch-only. Import its private key to buy this.',
    );
    expect(session.switched, isEmpty);
  });

  testWidgets('no Solana wallet at all → import prompt naming the chain', (
    tester,
  ) async {
    setUp$(active: _wallet(Chain.tezos), wallets: [_wallet(Chain.tezos)]);
    final r = await runGuard(tester);
    expect(r.blocked, isTrue);
    expect(
      r.prompt,
      'This account has no Solana wallet that can sign. '
      'Import one to buy this.',
    );
  });

  testWidgets('non-Solana active with a signable Solana wallet in session → '
      're-points the signer and proceeds', (tester) async {
    final sol = _wallet(Chain.solana);
    setUp$(active: _wallet(Chain.tezos), wallets: [_wallet(Chain.tezos), sol]);
    final r = await runGuard(tester);
    expect(r.blocked, isFalse);
    expect(session.switched, [sol]);
  });

  testWidgets('a failed re-point blocks', (tester) async {
    setUp$(
      active: _wallet(Chain.tezos),
      wallets: [_wallet(Chain.solana)],
      switchFails: true,
    );
    expect((await runGuard(tester)).blocked, isTrue);
  });

  testWidgets('signable Solana active → proceeds without switching', (
    tester,
  ) async {
    final sol = _wallet(Chain.solana);
    setUp$(active: sol, wallets: [sol]);
    final r = await runGuard(tester);
    expect(r.blocked, isFalse);
    expect(session.switched, isEmpty);
  });

  testWidgets('watch-only Solana active → the view-only prompt, as before', (
    tester,
  ) async {
    final watch = _wallet(Chain.solana, walletType: WalletType.viewOnly);
    setUp$(active: watch, wallets: [watch, _wallet(Chain.solana)]);
    final r = await runGuard(tester);
    expect(r.blocked, isTrue);
    expect(r.prompt, 'View-only wallet');
  });
}
