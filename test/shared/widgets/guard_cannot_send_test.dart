import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mallow_wallet/shared/widgets/view_only_prompt.dart';

/// `guardViewOnly` asks whether the *globally selected* wallet can sign. That
/// is the right question only for Solana, whose executor signs with exactly
/// that wallet. A Tezos or Ethereum send picks its source from the session's
/// wallets on the token's chain and signs by explicit wallet id — so gating it
/// on the active selection blocked ETH and XTZ sends whenever the user's
/// selected Solana wallet happened to be watch-only, even with a perfectly
/// signable ETH/XTZ wallet in the same session.
///
/// The inverse matters just as much, and is what these tests mostly encode: a
/// chain with **no** signable session wallet must block whatever the active
/// selection is. Deferring to the active wallet's type there let a session
/// holding only a Tezos key walk a Solana send to its confirm step, where the
/// Solana executor signed with the Tezos wallet and the simulation failed.
class _FakeWalletRepository extends Fake implements WalletRepository {
  _FakeWalletRepository(this.active);

  final WalletInfo? active;

  @override
  Future<WalletInfo?> getActiveWallet() async => active;
}

class _FakeSessionManager extends Fake implements SessionManager {
  _FakeSessionManager(this.wallets);

  final List<WalletInfo> wallets;

  /// `canSign`-gated, like the real resolver — a linked watch-only wallet is
  /// not a signer.
  @override
  WalletInfo? sessionWalletForChain(Chain chain) {
    for (final w in wallets) {
      if (w.chainEnum == chain && w.canSign) return w;
    }
    return null;
  }

  /// Includes view-only, like the real one — this is what tells the prompt
  /// "you linked this wallet but not its key" from "you have no such wallet".
  @override
  List<WalletInfo> sessionWalletsForChain(Chain chain) => [
    for (final w in wallets)
      if (w.chainEnum == chain) w,
  ];
}

WalletInfo _wallet(
  Chain chain, {
  WalletType walletType = WalletType.hd,
  String id = 'w',
}) => WalletInfo(
  id: '$id-${chain.name}',
  address: 'addr-${chain.name}',
  name: 'Wallet',
  walletType: walletType,
  chain: chain.toDbString(),
);

void main() {
  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  /// [active] is the globally selected wallet — the one Solana's executor signs
  /// with. Defaults to a **watch-only Solana** wallet, the state that used to
  /// block everything.
  void setUp$({required List<WalletInfo> session, WalletInfo? active}) {
    register<WalletRepository>(
      _FakeWalletRepository(
        active ??
            _wallet(
              Chain.solana,
              walletType: WalletType.viewOnly,
              id: 'active',
            ),
      ),
    );
    register<SessionManager>(_FakeSessionManager(session));
  }

  tearDown(() {
    sl.unregister<WalletRepository>();
    sl.unregister<SessionManager>();
  });

  /// Runs the guard against a real BuildContext so the prompt sheet it may show
  /// has somewhere to mount.
  ///
  /// A blocking answer only resolves once the prompt is dismissed — the guard
  /// awaits the sheet before returning `true` — so this reads the prompt's
  /// title, pops it, and then reads the result. Dismissing (rather than
  /// confirming) is also what keeps the import route out of this test: the
  /// confirm sheet resolves null, so nothing is pushed.
  Future<({bool blocked, String? prompt})> runGuard(
    WidgetTester tester, {
    Chain? chain,
  }) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    late Future<bool> pending;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => pending = guardCannotSend(context, chain: chain),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump(); // the guard's DB lookup
    await tester.pump(const Duration(milliseconds: 50));
    final prompt = find.text('Import wallet').evaluate().isNotEmpty
        ? 'import'
        : find.text('View-only wallet').evaluate().isNotEmpty
        ? 'view-only'
        : null;
    if (navigatorKey.currentState?.canPop() ?? false) {
      navigatorKey.currentState!.pop();
    }
    await tester.pumpAndSettle();
    return (blocked: await pending, prompt: prompt);
  }

  testWidgets('Ethereum send is allowed despite a watch-only Solana selection '
      '— it signs with the session ETH wallet by id', (tester) async {
    setUp$(session: [_wallet(Chain.ethereum)]);
    expect((await runGuard(tester, chain: Chain.ethereum)).blocked, isFalse);
  });

  testWidgets('Tezos send is allowed despite a watch-only Solana selection', (
    tester,
  ) async {
    setUp$(session: [_wallet(Chain.tezos)]);
    expect((await runGuard(tester, chain: Chain.tezos)).blocked, isFalse);
  });

  testWidgets('Solana send is blocked by a watch-only selection even with a '
      'signable Solana wallet in session — its executor signs with exactly '
      'that wallet, so the remedy is switching, not importing', (tester) async {
    setUp$(session: [_wallet(Chain.solana)]);
    final result = await runGuard(tester, chain: Chain.solana);
    expect(result.blocked, isTrue);
    expect(result.prompt, 'view-only');
  });

  testWidgets('🛑 a Solana send from a session whose only key is a Tezos one '
      'is blocked and offers the import route — the regression: the guard '
      'used to read the signable Tezos selection and wave it through, and the '
      'Solana executor then signed with that Tezos wallet', (tester) async {
    setUp$(
      session: [
        _wallet(Chain.tezos),
        _wallet(Chain.solana, walletType: WalletType.viewOnly),
      ],
      active: _wallet(Chain.tezos),
    );
    final result = await runGuard(tester, chain: Chain.solana);
    expect(result.blocked, isTrue);
    expect(result.prompt, 'import');
  });

  testWidgets('🛑 after switching to a watch-only profile, a Solana send is '
      'blocked even while the PREVIOUS profile\'s signable Solana wallet is '
      'still the global selection — the selection is not the session', (
    tester,
  ) async {
    // The reported scenario: profile A held an imported Solana key, profile B
    // links only watch-only wallets. Solana signs with the global selection, so
    // a guard that read the selection instead of the session would wave this
    // through and the transfer would leave profile A's wallet. `sendBlocker`
    // asks the session first, which is why it does not.
    setUp$(
      session: [_wallet(Chain.solana, walletType: WalletType.viewOnly)],
      active: _wallet(Chain.solana, id: 'prior-profile-signer'),
    );
    final result = await runGuard(tester, chain: Chain.solana);
    expect(result.blocked, isTrue);
    expect(result.prompt, 'import');
    // The chain-less entry point (portfolio action row) must agree — it opens
    // the sheet before any chain is known and gates again at token selection.
    expect((await runGuard(tester)).blocked, isTrue);
  });

  testWidgets('an Ethereum send with no signable session ETH wallet is '
      'blocked even when the active wallet can sign — there is no key to '
      'sign the ETH transfer with', (tester) async {
    setUp$(session: [_wallet(Chain.tezos)], active: _wallet(Chain.tezos));
    final result = await runGuard(tester, chain: Chain.ethereum);
    expect(result.blocked, isTrue);
    expect(result.prompt, 'import');
  });

  testWidgets('a Tezos Ledger wallet does not clear the gate — signTezos'
      'Operation cannot use it, so the send would dead-end after auth', (
    tester,
  ) async {
    setUp$(session: [_wallet(Chain.tezos, walletType: WalletType.ledger)]);
    expect((await runGuard(tester, chain: Chain.tezos)).blocked, isTrue);
  });

  // `sessionCanSend` is the same predicate read *without* a BuildContext, to
  // decide whether a send affordance is rendered at all — the tokens tab's
  // action row and swipe actions, and the token detail sheet's action bar.
  //
  // Show/hide and the tap gate must agree: the token detail bar was hidden on
  // the active wallet's type while its Send button gated on the chain, so the
  // guard was unreachable — the control was never built. Both now read this.
  group('sessionCanSend (visibility)', () {
    test(
      'true for an ETH token despite a watch-only Solana selection',
      () async {
        setUp$(session: [_wallet(Chain.ethereum)]);
        expect(await sessionCanSend(chain: Chain.ethereum), isTrue);
      },
    );

    test('false for a Solana token under a watch-only selection', () async {
      setUp$(session: [_wallet(Chain.solana)]);
      expect(await sessionCanSend(chain: Chain.solana), isFalse);
    });

    test('false for a Solana token the session holds only watch-only — the '
        'Send affordance must not be offered on a linked-but-not-imported '
        'wallet', () async {
      setUp$(
        session: [
          _wallet(Chain.tezos),
          _wallet(Chain.solana, walletType: WalletType.viewOnly),
        ],
        active: _wallet(Chain.tezos),
      );
      expect(await sessionCanSend(chain: Chain.solana), isFalse);
      // …while the Tezos wallet it does hold the key for stays sendable.
      expect(await sessionCanSend(chain: Chain.tezos), isTrue);
    });

    test('chain-less: true when any non-Solana chain is signable — this is '
        'what keeps the tokens-tab action row on screen', () async {
      setUp$(session: [_wallet(Chain.tezos)]);
      expect(await sessionCanSend(), isTrue);
    });

    test('chain-less: false for a session that can sign nothing — a genuinely '
        'watch-only session keeps the collapsed layout', () async {
      setUp$(session: const []);
      expect(await sessionCanSend(), isFalse);
    });
  });

  group('chain unknown (generic Send entry point)', () {
    testWidgets('opens when any non-Solana chain has a signable wallet — the '
        'token list and source picker narrow it from there', (tester) async {
      setUp$(session: [_wallet(Chain.ethereum)]);
      expect((await runGuard(tester)).blocked, isFalse);
    });

    testWidgets('blocks a session that can sign nothing anywhere', (
      tester,
    ) async {
      setUp$(session: const []);
      expect((await runGuard(tester)).blocked, isTrue);
    });
  });
}
