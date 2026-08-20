import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/activity/widgets/activity_list_item.dart';
import 'package:mallow_wallet/shared/theme/mallow_colors.dart';

// The trailing amount on Received / Transferred rows must always name the
// asset it is counting. The backend leaves `symbol` empty for tokens it can't
// resolve in its token list, and an unguarded interpolation rendered a bare
// "+1.5" — a number the user can't attribute to anything. These tests pin the
// symbol (or, failing that, the truncated mint) always being present.

api.Activity _transfer({
  required api.ActivityType type,
  required String symbol,
  String mint = 'So11111111111111111111111111111111111111112',
}) {
  return api.Activity(
    id: 'a1',
    type: type,
    timestamp: 1700000000,
    signature: 'sig1',
    status: api.ActivityStatus.confirmed,
    data: {
      'token': {'mint': mint, 'symbol': symbol, 'amount': 1.5, 'decimals': 9},
      'counterparty': {
        'address': 'Counterparty1111111111111111111111111111111',
      },
      'isNft': false,
    },
  );
}

api.Activity _row({
  required api.ActivityType type,
  required Map<String, dynamic> data,
}) {
  return api.Activity(
    id: 'a1',
    type: type,
    timestamp: 1700000000,
    signature: 'sig1',
    status: api.ActivityStatus.confirmed,
    data: data,
  );
}

/// Marketplace-shaped payload (`sale`/`buy`/`offer`/`offer-received`/Solana
/// `mint`). [extra] merges in row-specific fields such as the refund flag.
Map<String, dynamic> _marketData({
  double price = 0.5,
  Map<String, dynamic> extra = const {},
}) => {
  'artwork': {
    'mintAccount': 'ArtMint11111111111111111111111111111111111',
    'name': 'Sunset',
    'imageUrl': 'https://example.com/art.png',
  },
  'price': price,
  'currencyMint': 'So11111111111111111111111111111111111111112',
  'currencySymbol': 'SOL',
  ...extra,
};

/// NFT transfer payload. [extra] merges in the cost fields (`fee`, `rent`,
/// `feeCurrency`) the row may carry.
Map<String, dynamic> _nftTransfer({
  String mint = 'NftMint111111111111111111111111111111111111',
  Map<String, dynamic> extra = const {},
}) => {
  'token': {'mint': mint, 'symbol': '', 'amount': 1.0, 'decimals': 0},
  'counterparty': {'address': 'Recipient11111111111111111111111111111111'},
  'isNft': true,
  'nftName': 'Sunset',
  ...extra,
};

/// Swap payload — a SOL → mallowSOL trade by default. Both mints are in the
/// app's own token registry, so passing an empty symbol exercises the
/// registry fallback; pass an unknown mint to reach the truncated-address one.
/// [extra] merges in row-specific fields such as `usdPrice`.
Map<String, dynamic> _swapData({
  String inMint = 'So11111111111111111111111111111111111111112',
  String inSymbol = 'SOL',
  double inAmount = 2.8458394,
  int inDecimals = 9,
  String outMint = 'MLLWWq9TLHK3oQznWqwPyqD7kH4LXTHSKXK4yLz7LjD',
  String outSymbol = 'mallowSOL',
  double outAmount = 3.23,
  int outDecimals = 9,
  Map<String, dynamic> extra = const {},
}) => {
  'inputToken': {
    'mint': inMint,
    'symbol': inSymbol,
    'amount': inAmount,
    'decimals': inDecimals,
  },
  'outputToken': {
    'mint': outMint,
    'symbol': outSymbol,
    'amount': outAmount,
    'decimals': outDecimals,
  },
  ...extra,
};

/// Native-staking payload (`stake`/`unstake`/`stake-withdraw`). The backend
/// reports the stake account's whole balance — the stake plus the rent reserve
/// the wallet funded — so the amount is deliberately not round; it renders at
/// the same two base decimals every other token row uses.
Map<String, dynamic> _stakeData({
  double amount = 1.00228288,
  Map<String, dynamic> extra = const {},
}) => {
  'token': {
    'mint': 'So11111111111111111111111111111111111111112',
    'symbol': 'SOL',
    'amount': amount,
    'decimals': 9,
  },
  'fee': 0.000005,
  'feeCurrency': 'SOL',
  ...extra,
};

Future<void> _pump(
  WidgetTester tester,
  api.Activity activity, {
  String? tokenMintContext,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ActivityListItem(
          activity: activity,
          tokenMintContext: tokenMintContext,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('receive row shows the token symbol with the amount', (
    tester,
  ) async {
    await _pump(
      tester,
      _transfer(type: api.ActivityType.receive, symbol: 'USDC'),
    );

    expect(find.text('+1.50 USDC'), findsOneWidget);
  });

  testWidgets('send row shows the token symbol with the amount', (
    tester,
  ) async {
    await _pump(tester, _transfer(type: api.ActivityType.send, symbol: 'USDC'));

    expect(find.text('-1.50 USDC'), findsOneWidget);
  });

  testWidgets('an empty symbol on a known mint resolves from the registry', (
    tester,
  ) async {
    await _pump(tester, _transfer(type: api.ActivityType.receive, symbol: ''));

    expect(find.text('+1.50 SOL'), findsOneWidget);
  });

  testWidgets('unresolved symbol falls back to the truncated mint', (
    tester,
  ) async {
    await _pump(
      tester,
      _transfer(
        type: api.ActivityType.receive,
        symbol: '',
        mint: 'Unindexed11111111111111111111111111111111x',
      ),
    );

    expect(find.text('+1.50 Unind…1111x'), findsOneWidget);
  });

  testWidgets('offer-received shows the bid unsigned', (tester) async {
    // Someone bidding on the viewer's listing moves no money into the wallet —
    // the bidder's escrow is theirs until the offer is accepted. A signed
    // amount would claim a balance change that never happened.
    await _pump(
      tester,
      _row(type: api.ActivityType.offerReceived, data: _marketData()),
    );

    expect(find.text('0.5 SOL'), findsOneWidget);
    expect(find.text('+0.5 SOL'), findsNothing);
  });

  testWidgets('a bid still reads as a debit', (tester) async {
    // Placing an offer escrows the viewer's funds — the sign must stay.
    await _pump(
      tester,
      _row(type: api.ActivityType.offer, data: _marketData()),
    );

    expect(find.text('-0.5 SOL'), findsOneWidget);
  });

  testWidgets('a refunded bid reads as money returning', (tester) async {
    // Being outbid returns the escrowed bid, but the row keeps the `offer`
    // type of the bid it reverses. Without honouring `data.isRefund` the
    // returned funds render as a second "-0.5 SOL" debit.
    await _pump(
      tester,
      _row(
        type: api.ActivityType.offer,
        data: _marketData(extra: const {'isRefund': true}),
      ),
    );

    expect(find.text('+0.5 SOL'), findsOneWidget);
    expect(find.text('-0.5 SOL'), findsNothing);
  });

  testWidgets('unknown rows never render a bare marketplace price', (
    tester,
  ) async {
    // Clobbered marketplace payloads arrive typed `unknown` but still carry a
    // `price`. Rendering it produced an unsigned "0.5 SOL" beside a truncated
    // signature — a number the user cannot attribute to any balance change.
    await _pump(
      tester,
      _row(
        type: api.ActivityType.unknown,
        data: const {'price': 0.5, 'programIds': <String>[], 'fee': 0.0},
      ),
    );

    expect(find.textContaining('SOL'), findsNothing);
  });

  testWidgets('gumball rows keep their raw price', (tester) async {
    // The raw-price fallback exists for gumball rows, which carry no typed
    // payload — the `unknown` guard must not take it away from them.
    await _pump(
      tester,
      _row(type: api.ActivityType.gumballCreate, data: const {'price': 0.5}),
    );

    expect(find.text('0.5 SOL'), findsOneWidget);
  });

  testWidgets('swap of an unindexed mint names the token', (tester) async {
    // An unindexed mint comes back with an empty symbol; interpolating it
    // directly rendered " → " and "+12.5 " — an amount with nothing attached.
    await _pump(
      tester,
      _row(
        type: api.ActivityType.swap,
        data: _swapData(
          inAmount: 1.0,
          outMint: 'Unindexed11111111111111111111111111111111x',
          outSymbol: '',
          outAmount: 12.5,
          outDecimals: 6,
        ),
      ),
    );

    expect(find.text('SOL → Unind…1111x'), findsOneWidget);
    expect(find.text('+12.50 Unind…1111x'), findsOneWidget);
  });

  testWidgets('a swap names a token the app knows but the indexer did not', (
    tester,
  ) async {
    // The server leaves `symbol` empty for anything missing from its token
    // list, including tokens the app ships in its own registry. Truncating the
    // mint there showed "MLLW…7LjD" for mallowSOL — a symbol we had all along.
    await _pump(
      tester,
      _row(
        type: api.ActivityType.swap,
        data: _swapData(inSymbol: '', inAmount: 1.0, outSymbol: ''),
      ),
    );

    expect(find.text('SOL → mallowSOL'), findsOneWidget);
    expect(find.text('+3.23 mallowSOL'), findsOneWidget);
  });

  testWidgets('a swap row shows what was sold beneath what was received', (
    tester,
  ) async {
    // A swap moves two balances. Showing only the credit hid the cost of the
    // trade, and the USD value that used to sit on the second line said
    // nothing about what was given up for it.
    await _pump(
      tester,
      _row(
        type: api.ActivityType.swap,
        data: _swapData(extra: const {'usdPrice': 500.0}),
      ),
    );

    expect(
      tester.widget<Text>(find.text('+3.23 mallowSOL')).style?.color,
      MallowColors.light.textPrimary,
    );
    // The debit reads as a debit — same red the feed uses for money leaving.
    expect(
      tester.widget<Text>(find.text('-2.85 SOL')).style?.color,
      MallowColors.light.negative,
    );
    expect(find.text('\$500.00'), findsNothing);
  });

  testWidgets('a swap seen from the sold token flips both lines', (
    tester,
  ) async {
    // Inside a token's own history the row is about that token, so the leg it
    // shows on top is the debit — leaving the credit for the line beneath,
    // which must then read as a credit rather than inheriting the debit's red.
    await _pump(
      tester,
      _row(type: api.ActivityType.swap, data: _swapData()),
      tokenMintContext: 'So11111111111111111111111111111111111111112',
    );

    expect(find.text('-2.85 SOL'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('+3.23 mallowSOL')).style?.color,
      MallowColors.light.positive,
    );
  });

  testWidgets('listing prices are de-emphasised, real movements are not', (
    tester,
  ) async {
    // A list/delist price is what the artwork is offered at — no balance
    // changed — so it must not carry the same visual weight as the signed
    // debits and credits it sits between in the feed.
    await _pump(tester, _row(type: api.ActivityType.list, data: _marketData()));
    expect(
      tester.widget<Text>(find.text('0.5 SOL')).style?.color,
      MallowColors.light.textSecondary,
    );

    await _pump(tester, _row(type: api.ActivityType.sale, data: _marketData()));
    expect(
      tester.widget<Text>(find.text('+0.5 SOL')).style?.color,
      MallowColors.light.textPrimary,
    );
  });

  testWidgets('an NFT send costs the fee plus the rent it paid', (
    tester,
  ) async {
    // Legacy Solana NFTs need the recipient to have a token account, and the
    // sender funds that rent — real money out of the wallet, so the row's cost
    // is the whole outlay rather than the network fee alone.
    await _pump(
      tester,
      _row(
        type: api.ActivityType.send,
        data: _nftTransfer(extra: const {'fee': 0.000005, 'rent': 0.00203928}),
      ),
    );

    expect(find.text('-0.002044 SOL'), findsOneWidget);
  });

  testWidgets('a stated fee currency is never relabelled or rescaled as SOL', (
    tester,
  ) async {
    // The feed mixes every session wallet's chain into one list, so there is
    // no ambient chain to inherit. Routing a tez fee through the lamports
    // formatter would both mislabel it and misstate it by 1e9.
    await _pump(
      tester,
      _row(
        type: api.ActivityType.send,
        data: _nftTransfer(
          mint: 'KT1Tezos11111111111111111111111111111111x-7',
          extra: const {'fee': 0.0005, 'feeCurrency': 'XTZ'},
        ),
      ),
    );

    expect(find.text('-0.0005 XTZ'), findsOneWidget);
    expect(find.textContaining('SOL'), findsNothing);
  });

  testWidgets('an unestablished chain renders the cost bare', (tester) async {
    // No stated currency and nothing in the row proves Solana: an unlabelled
    // amount is recoverable, a wrong ticker is not.
    await _pump(
      tester,
      _row(
        type: api.ActivityType.send,
        data: _nftTransfer(
          mint: 'KT1Tezos11111111111111111111111111111111x-7',
          extra: const {'fee': 0.0005},
        ),
      ),
    );

    expect(find.text('-0.0005'), findsOneWidget);
  });

  testWidgets('transfer-shaped mint reads as acquiring the artwork', (
    tester,
  ) async {
    // The Tezos feed emits mints with a transfer payload (Solana uses the
    // marketplace one), so the row must resolve through transferData: the
    // artwork name as the subtitle rather than a truncated signature, and no
    // trailing debit — a mint is an acquisition, and its fee isn't lamports.
    await _pump(
      tester,
      _row(
        type: api.ActivityType.mint,
        data: const {
          'token': {
            'mint': 'KT1Tezos11111111111111111111111111111111x',
            'symbol': '',
            'amount': 1.0,
            'decimals': 0,
            'logoUrl': 'https://example.com/art.png',
          },
          'counterparty': {'address': 'tz1Minter1111111111111111111111111'},
          'isNft': true,
          'nftName': 'Tezos Piece',
          'fee': 0.001,
        },
      ),
    );

    expect(find.text('Tezos Piece'), findsOneWidget);
    expect(find.text('sig1'), findsNothing);
    expect(find.textContaining('SOL'), findsNothing);
  });

  testWidgets('a stake reads as SOL leaving the wallet', (tester) async {
    // THE BUG THIS ENCODES: the whole tx used to arrive as `unknown` and
    // rendered "Unknown transaction" with no amount, because a stake moves no
    // tokens and its only parsed transfer is a 0-lamport fee marker.
    await _pump(
      tester,
      _row(
        type: api.ActivityType.stake,
        data: _stakeData(extra: const {'validator': 'Vote1111111111111111'}),
      ),
    );

    expect(find.text('Staked'), findsOneWidget);
    expect(find.text('Native stake'), findsOneWidget);
    expect(find.text('-1.00 SOL'), findsOneWidget);
  });

  testWidgets('an unstake shows the amount unsigned', (tester) async {
    // Deactivating moves nothing: the lamports stay in the stake account until
    // they are claimed. A signed amount would claim a balance change that
    // hasn't happened — and won't until the epoch turns.
    await _pump(
      tester,
      _row(type: api.ActivityType.unstake, data: _stakeData()),
    );

    expect(find.text('Unstaked'), findsOneWidget);
    expect(find.text('1.00 SOL'), findsOneWidget);
    expect(find.text('-1.00 SOL'), findsNothing);
    expect(find.text('+1.00 SOL'), findsNothing);
  });

  testWidgets('claiming deactivated stake reads as a credit', (tester) async {
    await _pump(
      tester,
      _row(type: api.ActivityType.stakeWithdraw, data: _stakeData()),
    );

    expect(find.text('Claimed stake'), findsOneWidget);
    expect(find.text('+1.00 SOL'), findsOneWidget);
  });
}
