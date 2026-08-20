import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/priority_fee_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mocktail/mocktail.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockSession extends Mock implements SessionManager {}

class _MockTokens extends Mock implements TokenRepository {}

TokenBalance _tb(
  String mint,
  double ui, {
  double? price,
  bool native = false,
}) => TokenBalance(
  mint: mint,
  symbol: mint,
  name: mint,
  decimals: 9,
  rawBalance: (ui * 1e9).round(),
  uiBalance: ui,
  pricePerToken: price,
  totalUsdValue: price == null ? null : ui * price,
  isNative: native,
);

WalletInfo _wallet(String address, {String chain = 'solana'}) => WalletInfo(
  id: 'id-$address',
  address: address,
  name: address,
  walletType: WalletType.hd,
  chain: chain,
);

void main() {
  const sol = TokenBalance.solMint;

  group('mergeTokenBalances (pure)', () {
    test('sums balances per mint and pins native SOL first', () {
      final merged = SessionPortfolioAggregator.mergeTokenBalances([
        [_tb(sol, 1, price: 100, native: true), _tb('USDC', 10, price: 1)],
        [_tb(sol, 2, price: 100, native: true), _tb('BONK', 5, price: 2)],
      ]);

      // Why: a wallet switcher showing per-account totals must not double-list
      // a mint held in two wallets — it sums into one row.
      expect(merged.first.mint, sol);
      expect(merged.first.uiBalance, 3);
      expect(merged.first.totalUsdValue, 300);

      final usdc = merged.firstWhere((t) => t.mint == 'USDC');
      expect(usdc.uiBalance, 10);
      // After SOL ($300), BONK ($10) outranks USDC ($10 too) — tie broken by
      // insertion is fine; assert both present with correct values instead.
      expect(merged.map((t) => t.mint), containsAll(<String>['BONK', 'USDC']));
    });

    test('keeps a price/total even if only one wallet reported a price', () {
      final merged = SessionPortfolioAggregator.mergeTokenBalances([
        [_tb('MINT', 3)], // no price
        [_tb('MINT', 2, price: 4)], // priced
      ]);
      final row = merged.single;
      expect(row.uiBalance, 5);
      expect(row.pricePerToken, 4);
      expect(row.totalUsdValue, 20); // recomputed from the summed UI balance
    });
  });

  group('session fan-out', () {
    late _MockSession session;
    late _MockTokens tokens;
    late SessionPortfolioAggregator agg;

    setUp(() {
      session = _MockSession();
      tokens = _MockTokens();
      agg = SessionPortfolioAggregator(session, tokens);
      // Real summing behaviour for calculateTotalValue.
      when(() => tokens.calculateTotalValue(any())).thenAnswer((inv) {
        final list = inv.positionalArguments[0] as List<TokenBalance>;
        return list.fold<double>(0, (s, t) => s + (t.totalUsdValue ?? 0));
      });
    });

    test('selects only distinct Solana addresses, in order', () {
      when(() => session.sessionWallets).thenReturn([
        _wallet('SOL_A'),
        _wallet('ETH_1', chain: 'ethereum'),
        _wallet('SOL_B'),
        _wallet('SOL_A'), // duplicate
      ]);
      expect(agg.sessionSolanaAddresses(), ['SOL_A', 'SOL_B']);
    });

    test('sums USD across wallets; a failing wallet contributes 0', () async {
      when(
        () => session.sessionWallets,
      ).thenReturn([_wallet('SOL_A'), _wallet('SOL_B')]);
      when(
        () => tokens.getTokenBalances('SOL_A'),
      ).thenAnswer((_) async => [_tb(sol, 1, price: 100, native: true)]);
      when(
        () => tokens.getTokenBalances('SOL_B'),
      ).thenThrow(Exception('helius down'));

      // Why: one wallet's RPC hiccup must not zero out the whole header balance.
      expect(await agg.aggregateBalanceUsd(), 100);
    });
  });

  group('profilePortfolioAddresses', () {
    late _MockSession session;
    late SessionPortfolioAggregator agg;

    setUp(() {
      session = _MockSession();
      agg = SessionPortfolioAggregator(session, _MockTokens());
    });

    test('null outside profile mode — account sessions keep one wallet', () {
      when(() => session.isProfileMode).thenReturn(false);
      when(
        () => session.sessionWallets,
      ).thenReturn([_wallet('SOL_A'), _wallet('SOL_B')]);
      expect(agg.profilePortfolioAddresses(), isNull);
    });

    test('the linked wallet when a profile holds a single Solana wallet', () {
      when(() => session.isProfileMode).thenReturn(true);
      when(
        () => session.sessionWallets,
      ).thenReturn([_wallet('SOL_A'), _wallet('ETH_1', chain: 'ethereum')]);
      // Why: null here would fall through to the active-signer path, which
      // reads whatever wallet is *globally selected* — a Profile session does
      // not guarantee that to be one of its linked wallets, so the header could
      // total a wallet the profile never linked. Naming the linked wallet keeps
      // the read inside the profile even when it links exactly one.
      expect(agg.profilePortfolioAddresses(), ['SOL_A']);
    });

    test('the distinct Solana set when a profile spans multiple', () {
      when(() => session.isProfileMode).thenReturn(true);
      when(() => session.sessionWallets).thenReturn([
        _wallet('SOL_A'),
        _wallet('SOL_B'),
        _wallet('SOL_A'), // duplicate
      ]);
      expect(agg.profilePortfolioAddresses(), ['SOL_A', 'SOL_B']);
    });
  });

  group('SendSourceCandidate.qualifies', () {
    WalletInfo w() => _wallet('A');

    test('native SOL must clear the transaction fee', () {
      // Why: offering a wallet that can't cover its own fee guarantees a failed
      // send, so the dust floor is exclusive of the fee itself.
      final dust = SendSourceCandidate(
        wallet: w(),
        rawBalance: worstCaseSolTxFeeLamports,
        uiBalance: 0.000055,
      );
      final funded = SendSourceCandidate(
        wallet: w(),
        rawBalance: worstCaseSolTxFeeLamports + 1,
        uiBalance: 0.000055,
      );
      expect(dust.qualifies(isNative: true), isFalse);
      expect(funded.qualifies(isNative: true), isTrue);
    });

    // Why: the floor is what the transfer costs, not a round cushion above it.
    // A wallet holding 0.002 SOL can pay for its own transfer many times over,
    // and the old flat 0.008 SOL floor hid it from the source picker — so the
    // user could never empty it.
    test('a wallet holding well under the old flat floor still qualifies', () {
      final small = SendSourceCandidate(
        wallet: w(),
        rawBalance: 2000000, // 0.002 SOL
        uiBalance: 0.002,
      );
      expect(small.qualifies(isNative: true), isTrue);
    });

    test('an SPL token only needs a nonzero balance, ignoring SOL for gas', () {
      // Why: a wallet holding the token but short on SOL still qualifies — the
      // gas shortfall surfaces at confirm, not selection.
      final zero = SendSourceCandidate(
        wallet: w(),
        rawBalance: 0,
        uiBalance: 0,
      );
      final held = SendSourceCandidate(
        wallet: w(),
        rawBalance: 1,
        uiBalance: 0.000000001,
      );
      expect(zero.qualifies(isNative: false), isFalse);
      expect(held.qualifies(isNative: false), isTrue);
    });
  });

  group('sendSourcesForMint', () {
    late _MockSession session;
    late _MockTokens tokens;
    late SessionPortfolioAggregator agg;

    WalletInfo viewOnly(String address) => WalletInfo(
      id: 'id-$address',
      address: address,
      name: address,
      walletType: WalletType.viewOnly,
      chain: 'solana',
    );

    setUp(() {
      session = _MockSession();
      tokens = _MockTokens();
      agg = SessionPortfolioAggregator(session, tokens);
    });

    test(
      'only signable same-chain wallets, deduped, with the token balance',
      () async {
        when(() => session.sessionWallets).thenReturn([
          _wallet('SOL_A'),
          viewOnly('SOL_VO'),
          _wallet('ETH_1', chain: 'ethereum'),
          _wallet('SOL_B'),
          _wallet('SOL_A'), // duplicate address
        ]);
        when(
          () => tokens.getCachedBalances('SOL_A'),
        ).thenAnswer((_) async => [_tb('USDC', 5)]);
        when(
          () => tokens.getCachedBalances('SOL_B'),
        ).thenAnswer((_) async => const []); // holds no USDC

        final sources = await agg.sendSourcesForMint(
          chain: Chain.solana,
          mint: 'USDC',
        );

        // Why: a view-only wallet can't sign, an Ethereum wallet is the wrong
        // chain, and a duplicate address must not double-list — so only the two
        // distinct signable Solana wallets are candidates, in session order.
        expect(sources.map((s) => s.wallet.address), ['SOL_A', 'SOL_B']);
        expect(sources[0].uiBalance, 5);
        expect(sources[0].rawBalance, (5 * 1e9).round());
        // A wallet without the mint contributes a zero balance, not an
        // omission — the picker still shows it (the qualification filter greys
        // it out).
        expect(sources[1].uiBalance, 0);
      },
    );

    test('refresh fans out to the network instead of the cache', () async {
      when(() => session.sessionWallets).thenReturn([_wallet('SOL_A')]);
      when(
        () => tokens.getTokenBalances('SOL_A'),
      ).thenAnswer((_) async => [_tb('USDC', 9)]);

      final sources = await agg.sendSourcesForMint(
        chain: Chain.solana,
        mint: 'USDC',
        refresh: true,
      );

      // Why: the up-front decision reads cache (no spinner), but an explicit
      // refresh must hit Helius to refine stale figures.
      expect(sources.single.uiBalance, 9);
      verify(() => tokens.getTokenBalances('SOL_A')).called(1);
      verifyNever(() => tokens.getCachedBalances(any()));
    });

    /// Gates the tokens tab's swipe actions. A watch-only wallet's holdings are
    /// still *read* into the aggregated portfolio (an address is all Helius
    /// needs), but nothing in the session can sign for them — so the row must
    /// not offer send or burn.
    group('signableSolanaMints', () {
      test('excludes mints only watch-only wallets hold', () async {
        when(
          () => session.sessionWallets,
        ).thenReturn([_wallet('SOL_A'), viewOnly('SOL_VO')]);
        when(
          () => tokens.getCachedBalances('SOL_A'),
        ).thenAnswer((_) async => [_tb('USDC', 5)]);
        when(
          () => tokens.getCachedBalances('SOL_VO'),
        ).thenAnswer((_) async => [_tb('BONK', 7)]);

        final mints = await agg.signableSolanaMints();

        expect(mints, {'USDC'});
        // Why: BONK is visible in the portfolio (the watch-only wallet's
        // balance is aggregated in) but no session wallet can sign it away.
        expect(mints, isNot(contains('BONK')));
        verifyNever(() => tokens.getCachedBalances('SOL_VO'));
      });

      test('unions every signable wallet and drops zero balances', () async {
        when(
          () => session.sessionWallets,
        ).thenReturn([_wallet('SOL_A'), _wallet('SOL_B')]);
        when(
          () => tokens.getCachedBalances('SOL_A'),
        ).thenAnswer((_) async => [_tb('USDC', 5), _tb('DUST', 0)]);
        when(
          () => tokens.getCachedBalances('SOL_B'),
        ).thenAnswer((_) async => [_tb('BONK', 2)]);

        // Why: the gate is per *mint*, not per wallet — a token any signable
        // wallet holds is actionable, and a fully-spent row is not.
        expect(await agg.signableSolanaMints(), {'USDC', 'BONK'});
      });

      test('ignores non-Solana wallets', () async {
        when(
          () => session.sessionWallets,
        ).thenReturn([_wallet('SOL_A'), _wallet('ETH_1', chain: 'ethereum')]);
        when(
          () => tokens.getCachedBalances('SOL_A'),
        ).thenAnswer((_) async => [_tb('USDC', 5)]);

        // Why: the cached rows carry no chain of their own, so an ETH wallet's
        // contract addresses would land in a set the Solana-only swipe gate
        // reads — and the gate is what decides whether an SPL burn is offered.
        expect(await agg.signableSolanaMints(), {'USDC'});
        verifyNever(() => tokens.getCachedBalances('ETH_1'));
      });
    });
  });
}
