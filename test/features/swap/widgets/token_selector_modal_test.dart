import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/swap/widgets/token_selector_modal.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

/// The swap token pickers are the last screen a user sees before committing to
/// a mint, so the row has to identify the mint unambiguously — two tokens can
/// (and do) share a symbol and a name, and picking the impostor is an
/// irreversible swap into a worthless token. These tests pin the things that
/// make the sheet legible and the picker complete:
///
///  1. the sheet title reads left-aligned, like every other sheet header,
///  2. every non-base-token row carries its truncated mint,
///  3. pasting a mint finds the token — including one already in the list,
///  4. the buy side searches a catalog wider than the user's own balances.
void main() {
  const solMint = 'So11111111111111111111111111111111111111112';
  const mallowSolMint = 'mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So';
  const usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

  const nativeSol = TokenBalance(
    mint: solMint,
    symbol: 'SOL',
    name: 'Solana',
    decimals: 9,
    rawBalance: 1000000000,
    uiBalance: 1,
    isNative: true,
    isVerified: true,
  );

  const mallowSol = TokenBalance(
    mint: mallowSolMint,
    symbol: 'mallowSOL',
    name: 'mallowSOL',
    decimals: 9,
    rawBalance: 0,
    uiBalance: 0,
    isVerified: true,
  );

  const nativeEth = TokenBalance(
    mint: TokenBalance.evmNativeSentinel,
    symbol: 'ETH',
    name: 'Ethereum',
    decimals: 18,
    rawBalance: 0,
    uiBalance: 0,
    isNative: true,
    chain: Chain.ethereum,
  );

  Widget host(Widget child) => MaterialApp(
    theme: MallowTheme.lightTheme,
    home: Scaffold(body: child),
  );

  group('token row subtitle', () {
    testWidgets('carries the truncated mint for a non-base token', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const TokenSelectorModal(
            tokens: [mallowSol],
            title: 'Select token to buy',
          ),
        ),
      );

      // The mint is what actually distinguishes two same-named tokens — without
      // it the row is indistinguishable from a spoofed "mallowSOL".
      expect(find.text('mallowSOL • mSoLz…Jm7So'), findsOneWidget);
    });

    testWidgets('omits the mint for base tokens (SOL / ETH)', (tester) async {
      await tester.pumpWidget(
        host(const TokenSelectorModal(tokens: [nativeSol, nativeEth])),
      );

      // There is exactly one SOL and one ETH, and ETH's "mint" is a sentinel
      // string rather than an address — printing either would be noise, not
      // disambiguation.
      expect(find.text('Solana'), findsOneWidget);
      expect(find.text('Ethereum'), findsOneWidget);
      expect(find.textContaining('…'), findsNothing);
    });
  });

  testWidgets('titles of any length start at the same leading edge', (
    tester,
  ) async {
    Future<double> titleLeft(String title) async {
      await tester.pumpWidget(
        host(TokenSelectorModal(tokens: const [nativeSol], title: title)),
      );
      return tester.getTopLeft(find.text(title)).dx;
    }

    final short = await titleLeft('Buy');
    final sheetLeft = tester.getRect(find.byType(TokenSelectorModal)).left;
    final long = await titleLeft('Select token to sell');

    // A shrink-wrapped title in a centre-aligned Column renders centred even
    // with `textAlign: TextAlign.left` set, and centring makes the start
    // position depend on the string's width. Pinning two very different titles
    // to the same left edge is what a centred layout cannot satisfy.
    expect(short, closeTo(sheetLeft + MallowTheme.spacingMd, 0.5));
    expect(long, closeTo(short, 0.5));
  });

  group('unverified section', () {
    const airdrop = TokenBalance(
      mint: usdcMint,
      symbol: 'USDC',
      name: 'USD Coin',
      decimals: 6,
      rawBalance: 1000000,
      uiBalance: 1,
    );

    testWidgets('unverified holdings sit below the verified ones under their '
        'own header', (tester) async {
      await tester.pumpWidget(
        host(
          const TokenSelectorModal(
            // The unverified row is passed *first* — the split has to reorder
            // it, not merely label wherever it happened to land.
            tokens: [airdrop, nativeSol, mallowSol],
            title: 'Select token to sell',
          ),
        ),
      );

      final header = tester.getTopLeft(find.text('Unverified tokens')).dy;
      // A mint with no verified tag is an unrecognized airdrop as often as it
      // is a real holding, and this picker is the last screen before an
      // irreversible swap: a spoofed "USDC" interleaved with the real tokens
      // is one mis-tap away from being sold into.
      expect(tester.getTopLeft(find.text('SOL')).dy, lessThan(header));
      expect(tester.getTopLeft(find.text('mallowSOL')).dy, lessThan(header));
      expect(tester.getTopLeft(find.text('USDC')).dy, greaterThan(header));
    });

    testWidgets('no header when every token is verified', (tester) async {
      await tester.pumpWidget(
        host(const TokenSelectorModal(tokens: [nativeSol, mallowSol])),
      );

      expect(find.text('Unverified tokens'), findsNothing);
    });

    testWidgets('catalog hits stay above the unverified holdings', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          TokenSelectorModal(
            tokens: const [airdrop],
            catalogSearch: (_) async => const [mallowSol],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'usd');
      await tester.pumpAndSettle();

      // Catalog hits are verified by construction, so they belong in the
      // verified section even though they are appended last.
      final header = tester.getTopLeft(find.text('Unverified tokens')).dy;
      expect(tester.getTopLeft(find.text('mallowSOL')).dy, lessThan(header));
      expect(tester.getTopLeft(find.text('USDC')).dy, greaterThan(header));
    });
  });

  group('mint search', () {
    testWidgets('a pasted mint surfaces a token the user already holds', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const TokenSelectorModal(tokens: [nativeSol, mallowSol])),
      );

      await tester.enterText(find.byType(TextField), mallowSolMint);
      await tester.pumpAndSettle();

      // The row prints its mint, which invites pasting one back in. The
      // catalog cannot rescue this case — it drops hits that duplicate a
      // local row — so a local-only symbol/name filter would answer "No
      // tokens found" for a token sitting in the very list being searched.
      expect(find.text('mallowSOL'), findsOneWidget);
      expect(find.text('SOL'), findsNothing);
      expect(find.text('No tokens found'), findsNothing);
    });

    testWidgets('a pasted mint still matches with trailing whitespace', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const TokenSelectorModal(tokens: [nativeSol, mallowSol])),
      );

      // Copying a mint out of an explorer or a chat message routinely drags a
      // space or newline along; the user cannot see it and would read the
      // empty picker as "this token is not available".
      await tester.enterText(find.byType(TextField), '  $mallowSolMint\n');
      await tester.pumpAndSettle();

      expect(find.text('mallowSOL'), findsOneWidget);
      expect(find.text('No tokens found'), findsNothing);
    });

    testWidgets('a partial mint does not match', (tester) async {
      await tester.pumpWidget(
        host(const TokenSelectorModal(tokens: [nativeSol, mallowSol])),
      );

      // 'So1' is a prefix of SOL's mint. Matching mints by substring would
      // turn every short query into a mint scan and surface tokens the user
      // was not asking for, so the mint comparison is exact.
      await tester.enterText(find.byType(TextField), 'So1');
      await tester.pumpAndSettle();

      expect(find.text('SOL'), findsNothing);
      expect(find.text('No tokens found'), findsOneWidget);
    });
  });

  group('catalog search', () {
    testWidgets('appends catalog hits below the local matches', (tester) async {
      const catalogToken = TokenBalance(
        mint: usdcMint,
        symbol: 'USDC',
        name: 'USD Coin',
        decimals: 6,
        rawBalance: 0,
        uiBalance: 0,
        isVerified: true,
      );

      await tester.pumpWidget(
        host(
          TokenSelectorModal(
            tokens: const [nativeSol],
            catalogSearch: (_) async => const [catalogToken],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'usd');
      await tester.pumpAndSettle();

      // The whole point of the catalog: a token the user neither holds nor has
      // in the hardcoded registry is still reachable.
      expect(find.text('USDC'), findsOneWidget);
      expect(find.text('USD Coin • EPjFW…TDt1v'), findsOneWidget);
    });

    testWidgets('drops catalog hits already present locally', (tester) async {
      await tester.pumpWidget(
        host(
          TokenSelectorModal(
            tokens: const [mallowSol],
            // The catalog contains every verified mint, including ones the
            // user already holds — without the filter the row renders twice.
            catalogSearch: (_) async => const [mallowSol],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'mallow');
      await tester.pumpAndSettle();

      expect(find.text('mallowSOL'), findsOneWidget);
    });

    testWidgets('does not query the catalog for a one-character query', (
      tester,
    ) async {
      final queries = <String>[];

      await tester.pumpWidget(
        host(
          TokenSelectorModal(
            tokens: const [nativeSol],
            catalogSearch: (q) async {
              queries.add(q);
              return const [];
            },
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 's');
      await tester.pumpAndSettle();

      // A single character matches most of a ~3.9k-token catalog, so the hits
      // would be noise and the query pure waste.
      expect(queries, isEmpty);
    });

    testWidgets('a stale in-flight response cannot overwrite a newer one', (
      tester,
    ) async {
      final gates = <String, Completer<List<TokenBalance>>>{};

      await tester.pumpWidget(
        host(
          TokenSelectorModal(
            tokens: const [],
            catalogSearch: (q) =>
                (gates[q] = Completer<List<TokenBalance>>()).future,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'usd');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField), 'mallow');
      await tester.pump(const Duration(milliseconds: 300));

      // Resolve the *older* request last — a slow first lookup landing after a
      // fast second one would otherwise show results for a query the user has
      // already replaced.
      gates['mallow']!.complete(const [mallowSol]);
      await tester.pumpAndSettle();
      gates['usd']!.complete(const [
        TokenBalance(
          mint: usdcMint,
          symbol: 'USDC',
          name: 'USD Coin',
          decimals: 6,
          rawBalance: 0,
          uiBalance: 0,
        ),
      ]);
      await tester.pumpAndSettle();

      expect(find.text('mallowSOL'), findsOneWidget);
      expect(find.text('USDC'), findsNothing);
    });

    testWidgets(
      'a response landing inside a newer query\'s debounce is stale',
      (tester) async {
        final gates = <String, Completer<List<TokenBalance>>>{};

        await tester.pumpWidget(
          host(
            TokenSelectorModal(
              tokens: const [],
              catalogSearch: (q) =>
                  (gates[q] = Completer<List<TokenBalance>>()).future,
            ),
          ),
        );

        await tester.enterText(find.byType(TextField), 'usd');
        await tester.pump(const Duration(milliseconds: 300));

        // The next keystroke only arms the debounce timer — nothing has been
        // sent for 'usdx' yet, so this is the window in which the guard has to
        // already consider 'usd' superseded.
        await tester.enterText(find.byType(TextField), 'usdx');
        await tester.pump(const Duration(milliseconds: 50));

        gates['usd']!.complete(const [
          TokenBalance(
            mint: usdcMint,
            symbol: 'USDC',
            name: 'USD Coin',
            decimals: 6,
            rawBalance: 0,
            uiBalance: 0,
          ),
        ]);
        await tester.pump();

        // Publishing here would not just show a wrong row: clearing the spinner
        // presents it as the finished answer for 'usdx', so the user reads a
        // settled list and taps a token they never searched for.
        expect(find.text('USDC'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        // Let the real 'usdx' lookup fire and answer so no timer outlives the
        // test.
        await tester.pump(const Duration(milliseconds: 250));
        gates['usdx']!.complete(const []);
        await tester.pump();
      },
    );

    testWidgets('browse tabs do not narrow the search', (tester) async {
      const popular = TokenBalance(
        mint: usdcMint,
        symbol: 'USDC',
        name: 'USD Coin',
        decimals: 6,
        rawBalance: 0,
        uiBalance: 0,
        isVerified: true,
      );

      await tester.pumpWidget(
        host(
          TokenSelectorModal(
            tokens: const [nativeSol, mallowSol],
            browseTabs: (
              owned: const [nativeSol],
              popular: () async => const [popular],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // mallowSOL is on neither tab: not held, and not liquid enough to be
      // popular. Scoping the query to the active tab would make it — and most
      // of the catalog — unreachable from the picker.
      await tester.enterText(find.byType(TextField), 'mallow');
      await tester.pumpAndSettle();

      expect(find.text('mallowSOL'), findsOneWidget);
    });

    testWidgets('a catalog failure leaves the local matches standing', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          TokenSelectorModal(
            tokens: const [mallowSol],
            catalogSearch: (_) async => throw Exception('offline'),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'mallow');
      await tester.pumpAndSettle();

      // The catalog is a supplement; losing it must not empty the picker.
      expect(find.text('mallowSOL'), findsOneWidget);
      expect(find.text('No tokens found'), findsNothing);
    });
  });

  group('browse tabs', () {
    const popularToken = TokenBalance(
      mint: usdcMint,
      symbol: 'USDC',
      name: 'USD Coin',
      decimals: 6,
      rawBalance: 0,
      uiBalance: 0,
      isVerified: true,
    );

    Widget picker({
      List<TokenBalance> owned = const [nativeSol],
      Future<List<TokenBalance>> Function()? popular,
    }) => host(
      TokenSelectorModal(
        tokens: const [nativeSol, mallowSol],
        browseTabs: (
          owned: owned,
          popular: popular ?? () async => const [popularToken],
        ),
      ),
    );

    testWidgets('opens on Owned and switches to Popular', (tester) async {
      await tester.pumpWidget(picker());
      await tester.pumpAndSettle();

      // Owned is the landing tab: what the user can act on right now, without
      // the registry's zero-balance rows the flat list used to mix in.
      expect(find.text('SOL'), findsOneWidget);
      expect(find.text('USDC'), findsNothing);
      expect(find.text('mallowSOL'), findsNothing);

      await tester.tap(find.text('Popular'));
      await tester.pumpAndSettle();

      expect(find.text('USDC'), findsOneWidget);
      expect(find.text('SOL'), findsNothing);
    });

    testWidgets('an empty Owned tab says so rather than "not found"', (
      tester,
    ) async {
      await tester.pumpWidget(picker(owned: const []));
      await tester.pumpAndSettle();

      // A wallet with no tokens has not failed a lookup — "No tokens found"
      // reads as a broken picker rather than an empty wallet.
      expect(find.text('You don\'t own any tokens yet'), findsOneWidget);
    });

    testWidgets('Popular shows a spinner until its rows land', (tester) async {
      final gate = Completer<List<TokenBalance>>();
      await tester.pumpWidget(picker(popular: () => gate.future));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Popular'));
      await tester.pump();

      // The catalog behind this tab can be a cold ~5 MB fetch. An empty list
      // in the meantime would read as a settled answer — "nothing is popular".
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('No tokens found'), findsNothing);

      gate.complete(const [popularToken]);
      await tester.pumpAndSettle();
      expect(find.text('USDC'), findsOneWidget);
    });

    testWidgets('a failed Popular load settles instead of spinning forever', (
      tester,
    ) async {
      await tester.pumpWidget(
        picker(popular: () async => throw Exception('offline')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Popular'));
      await tester.pumpAndSettle();

      // Offline the tab is empty, but the picker still has to be usable —
      // search reaches every token regardless.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('No tokens found'), findsOneWidget);
    });

    testWidgets('clearing the search returns to the active tab', (
      tester,
    ) async {
      await tester.pumpWidget(picker());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Popular'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'mallow');
      await tester.pumpAndSettle();
      expect(find.text('mallowSOL'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();

      // The tab bar stays on screen through a search, so it has to still mean
      // something when the query goes away — landing back on Owned would
      // silently discard the tab the user chose.
      expect(find.text('USDC'), findsOneWidget);
      expect(find.text('mallowSOL'), findsNothing);
    });

    testWidgets('no tabs when the caller supplies none (the sell side)', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const TokenSelectorModal(tokens: [nativeSol, mallowSol])),
      );
      await tester.pumpAndSettle();

      // You can only sell what you hold, so the sell picker's flat list is
      // already "owned" — tabs there would be two views of the same rows.
      expect(find.text('Owned'), findsNothing);
      expect(find.text('Popular'), findsNothing);
      expect(find.text('mallowSOL'), findsOneWidget);
    });

    // Note: "Popular is not loaded without a tab to render it" used to be
    // asserted here by supplying `popularTokens` with no `ownedTokens`. That
    // half-supplied state is now unrepresentable — `browseTabs` carries the
    // owned rows and the loader as one record — so the cold ~5 MB fetch can no
    // longer be paid for with nowhere to put the rows.
  });
}
