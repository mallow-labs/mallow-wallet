import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/activity/screens/activity_detail_screen.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mallow_wallet/shared/widgets/mallow_kv_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The activity detail sheet is the only place a user can audit what a
// transaction actually cost and which direction the money moved. Every test
// here pins a claim the screen makes about the user's money — a wrong ticker,
// a raw float, or an inverted direction is a factual misstatement about their
// funds, not a cosmetic defect.

api.Activity _activity({
  required api.ActivityType type,
  required Map<String, dynamic> data,
  String signature = 'sig1',
}) => api.Activity(
  id: 'a1',
  type: type,
  timestamp: 1700000000,
  signature: signature,
  status: api.ActivityStatus.confirmed,
  data: data,
);

Future<void> _pump(
  WidgetTester tester,
  api.Activity activity, {
  Chain? chain,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ActivityDetailScreen(
          activity: activity,
          onBack: () {},
          chain: chain,
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // The explorer button resolves the user's preferred Solana explorer by
    // name on build, so the screen can't render without this registration.
    if (!sl.isRegistered<PreferencesService>()) {
      SharedPreferences.setMockInitialValues({});
      sl.registerSingleton<PreferencesService>(
        await PreferencesService.create(),
      );
    }
  });

  group('chain-aware explorer link', () {
    testWidgets('activity chain inference wins over the active wallet chain', (
      tester,
    ) async {
      final ethereumSignature = '0x${List.filled(64, 'a').join()}';

      await _pump(
        tester,
        _activity(
          type: api.ActivityType.unknown,
          data: const {'programIds': <String>[], 'fee': 0.001},
          signature: ethereumSignature,
        ),
        // The activity feed may be opened while the Solana wallet is active
        // even though this row belongs to an Ethereum wallet.
        chain: Chain.solana,
      );

      expect(find.text('View on Etherscan'), findsOneWidget);
      expect(find.text('View on Solscan'), findsNothing);
    });
  });

  group('network fee currency', () {
    // A fee row that always says "SOL" tells a Tezos user they paid a Solana
    // fee for a Tezos transaction. The number is right and the unit is wrong,
    // which is the one failure mode a user cannot detect by reading the screen.
    testWidgets('Tezos row denominates the fee in XTZ, never SOL', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.unknown,
          data: {
            'programIds': <String>[],
            'fee': 0.0005, // baker fee, in tez
          },
        ),
        chain: Chain.tezos,
      );

      expect(find.text('-0.0005 XTZ'), findsOneWidget);
      expect(find.textContaining('SOL'), findsNothing);
    });

    // The activity sheet aggregates rows from every session wallet, but the
    // caller can only hand the detail screen ONE chain — the active wallet's.
    // So a Tezos row opened while a Solana wallet is active would infer Solana
    // and print a tez fee as SOL. `data.feeCurrency` describes the row itself,
    // so it must beat the inferred chain: a fee ticker the user cannot verify
    // from the screen is the one error they have no way to catch, because the
    // digits look perfectly right.
    testWidgets('stated feeCurrency wins over the caller-supplied chain', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.unknown,
          data: {'programIds': <String>[], 'fee': 0.0005, 'feeCurrency': 'XTZ'},
        ),
        // Active wallet is Solana while the row is a Tezos contract call.
        chain: Chain.solana,
      );

      expect(find.text('-0.0005 XTZ'), findsOneWidget);
      expect(find.textContaining('SOL'), findsNothing);
    });

    // A ticker the token registry doesn't key must still be shown, not
    // dropped — the server states it because it knows the chain and we don't.
    testWidgets('an unregistered stated ticker is still rendered', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.unknown,
          data: {
            'programIds': <String>[],
            'fee': 0.0005,
            'feeCurrency': 'MATIC',
          },
        ),
      );

      expect(find.text('-0.0005 MATIC'), findsOneWidget);
    });

    testWidgets('Solana row still denominates the fee in SOL', (tester) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.unknown,
          data: {'programIds': <String>[], 'fee': 0.000005},
        ),
        chain: Chain.solana,
      );

      expect(find.text('-0.000005 SOL'), findsOneWidget);
    });

    // When no chain reaches the screen (the feed hasn't resolved the active
    // wallet yet) we cannot establish the currency. Showing a bare number is
    // recoverable — the user can check the explorer — whereas guessing a
    // ticker asserts something we don't know.
    testWidgets('unknown chain shows the fee unlabelled rather than guessing', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.unknown,
          data: {'programIds': <String>[], 'fee': 0.000005},
        ),
      );

      expect(find.text('-0.000005'), findsOneWidget);
      expect(find.textContaining('SOL'), findsNothing);
      expect(find.textContaining('XTZ'), findsNothing);
    });

    // `unknown` rows carry nothing but program ids and a fee, so the fee row is
    // the only thing that distinguishes them from an empty screen.
    testWidgets('unknown transactions surface their fee', (tester) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.unknown,
          data: {
            'programIds': <String>['Prog111'],
            'fee': 0.00001,
          },
        ),
        chain: Chain.solana,
      );

      expect(find.text('Network fee'), findsOneWidget);
      // Trailing zeros stripped: the fee reads as a number, not a raw double.
      expect(find.text('-0.00001 SOL'), findsOneWidget);
    });
  });

  group('account rent', () {
    // Rent is the sender funding the recipient's token account on a legacy
    // Solana NFT transfer. It dwarfs the network fee (~0.002 SOL vs ~0.000005)
    // and is real money leaving the wallet, so folding it into a row labelled
    // "Network fee" would both overstate what validators charged and hide the
    // largest component of the transfer's cost.
    Map<String, dynamic> transferData({double? rent}) => {
      'token': {
        'mint': 'Mint1111111111111111111111111111111111111',
        'symbol': '',
        'amount': 1,
        'decimals': 0,
      },
      'counterparty': {'address': 'Counterparty11111111111111111111111111111'},
      'isNft': true,
      'nftName': 'Piece',
      'fee': 0.000005,
      // Null-aware element: a row that paid no rent carries no `rent` key.
      'rent': ?rent,
    };

    testWidgets('a transfer that paid rent itemises fee and rent separately', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.send,
          data: transferData(rent: 0.00203928),
        ),
        chain: Chain.solana,
      );

      expect(find.text('Network fee'), findsOneWidget);
      expect(find.text('-0.000005 SOL'), findsOneWidget);
      expect(find.text('Account rent'), findsOneWidget);
      expect(find.text('-0.002039 SOL'), findsOneWidget);
    });

    // The list row shows fee + rent as one combined "cost to transfer"; this
    // screen itemises them. That divergence is only safe while the parts still
    // add up — if either row rounded away or double-counted a component, the
    // two surfaces would disagree about what the same transfer cost.
    testWidgets('itemised fee and rent reconcile with the combined total', (
      tester,
    ) async {
      const fee = 0.000005;
      const rent = 0.00203928;
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.send,
          data: transferData(rent: rent),
        ),
        chain: Chain.solana,
      );

      double rendered(String label) {
        final row = tester.widget<MallowKvRow>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(MallowKvRow),
          ),
        );
        return double.parse(row.value!.replaceAll(RegExp(r'[^0-9.]'), ''));
      }

      // Tolerance is the 6-decimal display cap both surfaces render at.
      expect(
        rendered('Network fee') + rendered('Account rent'),
        closeTo(fee + rent, 1e-6),
      );
    });

    testWidgets('a transfer with no rent shows only the network fee', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(type: api.ActivityType.send, data: transferData()),
        chain: Chain.solana,
      );

      expect(find.text('Network fee'), findsOneWidget);
      expect(find.text('-0.000005 SOL'), findsOneWidget);
      expect(find.text('Account rent'), findsNothing);
    });

    // Rent is Solana-only today, but it resolves its ticker exactly like the
    // fee does — hardcoding "SOL" here is how the fee row went wrong.
    testWidgets('rent renders bare when the chain cannot be established', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.send,
          data: transferData(rent: 0.00203928),
        ),
      );

      expect(find.text('-0.002039'), findsOneWidget);
      expect(find.textContaining('SOL'), findsNothing);
    });
  });

  group('amount formatting', () {
    // Prices arrive as IEEE-754 doubles, so server-side arithmetic leaks
    // artefacts like 0.30000000000000004. Rendering that verbatim makes the
    // app look broken and buries the value the user is trying to read.
    testWidgets('listing price is formatted, not interpolated raw', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.list,
          data: {
            'artwork': {
              'mintAccount': 'Mint111',
              'name': 'Piece',
              'imageUrl': '',
            },
            'price': 0.30000000000000004,
            'currencyMint': 'So11111111111111111111111111111111111111112',
            'currencySymbol': 'SOL',
          },
        ),
        chain: Chain.solana,
      );

      expect(find.text('0.3 SOL'), findsOneWidget);
      expect(find.textContaining('0.30000000000000004'), findsNothing);
    });

    testWidgets('sale proceeds are formatted and keep the + sign', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.sale,
          data: {
            'artwork': {
              'mintAccount': 'Mint111',
              'name': 'Piece',
              'imageUrl': '',
            },
            'price': 1.1000000000000001,
            'currencyMint': 'So11111111111111111111111111111111111111112',
            'currencySymbol': 'SOL',
          },
        ),
        chain: Chain.solana,
      );

      expect(find.text('+1.1 SOL'), findsOneWidget);
    });
  });

  group('bid refunds', () {
    Map<String, dynamic> offerData({
      bool refund = false,
      double price = 0.5,
      bool amountUnknown = false,
    }) => {
      'artwork': {'mintAccount': 'Mint111', 'name': 'Piece', 'imageUrl': ''},
      'price': price,
      'currencyMint': 'So11111111111111111111111111111111111111112',
      'currencySymbol': 'SOL',
      'counterparty': {'address': 'Counterparty11111111111111111111111111111'},
      if (refund) 'isRefund': true,
      if (amountUnknown) 'amountUnknown': true,
    };

    // A refund is escrow coming back after the user was outbid. Rendered as
    // "To … / Amount" it reads as a second bid — the user believes they are
    // out twice the money they actually committed.
    testWidgets('refunded bid reads as incoming money', (tester) async {
      await _pump(
        tester,
        _activity(type: api.ActivityType.offer, data: offerData(refund: true)),
        chain: Chain.solana,
      );

      expect(find.text('Refunded'), findsOneWidget);
      expect(find.text('+0.5 SOL'), findsOneWidget);
      expect(find.text('From'), findsOneWidget);
      expect(find.text('To'), findsNothing);
      expect(find.text('Amount'), findsNothing);
    });

    // `price` is `required double` on the wire, so a server that cannot work
    // out the viewer's actual credit (refund landed in another session wallet,
    // escrow settled in a later tx, token-denominated auction) must send 0
    // rather than omit the key. Rendering that as "+0 SOL" tells the user they
    // got nothing back — a definite claim about their money in the one case
    // where we have none. Showing no amount is the honest degradation, and the
    // label and counterparty still carry real information.
    testWidgets('an unknown-amount refund shows no amount row at all', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.offer,
          data: offerData(refund: true, price: 0),
        ),
        chain: Chain.solana,
      );

      // Still true and still useful: who returned it, and that it came back.
      expect(find.text('From'), findsOneWidget);
      expect(find.text('Count…11111'), findsOneWidget);
      // No amount row, and specifically not a zero masquerading as a figure.
      expect(find.text('Refunded'), findsNothing);
      expect(find.textContaining('0 SOL'), findsNothing);
    });

    // The whole point of the flag: an absent amount row and a stated-unknown
    // amount row are the difference between the user concluding "nothing came
    // back" and knowing "it came back, we can't show how much". They cannot
    // tell those apart from silence, and only one of them is true — so when the
    // server says it couldn't determine the credit, the screen says it too.
    testWidgets('a refund flagged amountUnknown says so instead of going '
        'silent', (tester) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.offer,
          data: offerData(refund: true, price: 0, amountUnknown: true),
        ),
        chain: Chain.solana,
      );

      expect(find.text('Refunded'), findsOneWidget);
      expect(find.text('Amount unavailable'), findsOneWidget);
      // Still true, still useful, and still shown.
      expect(find.text('From'), findsOneWidget);
      expect(find.text('Count…11111'), findsOneWidget);
      // The sentinel price must never leak out as a figure.
      expect(find.textContaining('0 SOL'), findsNothing);
      expect(find.text('+0 SOL'), findsNothing);
    });

    // The flag outranks the zero-suppression: `price` is still 0.0 on a flagged
    // row, so if suppression won the explanation would never render.
    testWidgets('the flag wins over zero-suppression', (tester) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.offer,
          data: offerData(refund: true, price: 0, amountUnknown: true),
        ),
        chain: Chain.solana,
      );

      expect(find.text('Amount unavailable'), findsOneWidget);
    });

    // Dust below display precision formats to "0" too, and is just as
    // meaningless to show — the list row suppresses on the formatted value for
    // exactly this reason, so the two surfaces must agree here.
    testWidgets('a refund that rounds to zero is suppressed the same way', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.offer,
          data: offerData(refund: true, price: 0.000005),
        ),
        chain: Chain.solana,
      );

      expect(find.text('Refunded'), findsNothing);
      expect(find.textContaining('0 SOL'), findsNothing);
    });

    testWidgets('a normal offer is unaffected and still reads as outgoing', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(type: api.ActivityType.offer, data: offerData()),
        chain: Chain.solana,
      );

      expect(find.text('To'), findsOneWidget);
      expect(find.text('Amount'), findsOneWidget);
      expect(find.text('0.5 SOL'), findsOneWidget);
      expect(find.text('Refunded'), findsNothing);
    });
  });

  group('mint payload shapes', () {
    // Tezos emits `mint` with a transfer-shaped payload, so the market-data
    // path finds nothing. Before the fallback the screen showed only date and
    // status — the user could not tell what they had just minted.
    testWidgets('Tezos mint renders the received asset from transfer data', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.mint,
          data: {
            'token': {
              'mint': 'KT1Contract-7',
              'symbol': '',
              'amount': 1,
              'decimals': 0,
            },
            'counterparty': {'address': 'KT1Contract'},
            'isNft': true,
            'nftName': 'Tez Piece',
          },
        ),
        chain: Chain.tezos,
      );

      expect(find.text('Received'), findsOneWidget);
      expect(find.text('+1 Tez Piece'), findsOneWidget);
      expect(find.text('From'), findsOneWidget);
    });

    // Market data must stay the first branch: a Solana mint carries both a
    // price and the artwork, and neither survives the transfer-shaped path.
    testWidgets('Solana mint keeps its marketplace price and artwork', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.mint,
          data: {
            'artwork': {
              'mintAccount': 'Mint111',
              'name': 'Sol Piece',
              'imageUrl': '',
            },
            'price': 0.7000000000000001,
            'currencyMint': 'So11111111111111111111111111111111111111112',
            'currencySymbol': 'SOL',
          },
        ),
        chain: Chain.solana,
      );

      expect(find.text('Paid'), findsOneWidget);
      expect(find.text('-0.7 SOL'), findsOneWidget);
      expect(find.text('+1 Sol Piece'), findsOneWidget);
    });

    // A free mint's zero is a REAL price, not a missing one, and the screen has
    // always omitted the row for it. Pinned because the zero-suppression rule
    // now routes through the shared market-amount helper: the artwork the user
    // received must survive, only the meaningless "-0 SOL" goes.
    testWidgets('a free mint shows the artwork but no Paid row', (
      tester,
    ) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.mint,
          data: {
            'artwork': {
              'mintAccount': 'Mint111',
              'name': 'Free Piece',
              'imageUrl': '',
            },
            'price': 0.0,
            'currencyMint': 'So11111111111111111111111111111111111111112',
            'currencySymbol': 'SOL',
          },
        ),
        chain: Chain.solana,
      );

      expect(find.text('Paid'), findsNothing);
      expect(find.textContaining('0 SOL'), findsNothing);
      expect(find.text('+1 Free Piece'), findsOneWidget);
    });
  });

  group('native staking', () {
    Map<String, dynamic> stakeData({Map<String, dynamic> extra = const {}}) => {
      'token': {
        'mint': 'So11111111111111111111111111111111111111112',
        'symbol': 'SOL',
        'amount': 1.00228288,
        'decimals': 9,
      },
      'fee': 0.000005,
      'feeCurrency': 'SOL',
      ...extra,
    };

    testWidgets('a stake states the amount and the validator', (tester) async {
      await _pump(
        tester,
        _activity(
          type: api.ActivityType.stake,
          data: stakeData(
            extra: const {
              'validator': 'mALLoAbdQrgsnm7kWJyPrhcQcmxfT73t8DaqEkpZNd6',
            },
          ),
        ),
        chain: Chain.solana,
      );

      expect(find.text('Staked'), findsWidgets);
      // Both the preview hero and the itemised row state the amount.
      expect(find.text('-1.0023 SOL'), findsWidgets);
      expect(find.text('Validator'), findsOneWidget);
    });

    testWidgets('an unstake is unsigned and names no validator', (
      tester,
    ) async {
      // Deactivating moves nothing and never names the vote account on chain,
      // so a signed amount or a validator row would both be invented.
      await _pump(
        tester,
        _activity(type: api.ActivityType.unstake, data: stakeData()),
        chain: Chain.solana,
      );

      expect(find.text('Deactivating'), findsOneWidget);
      expect(find.text('1.0023 SOL'), findsWidgets);
      expect(find.text('-1.0023 SOL'), findsNothing);
      expect(find.text('Validator'), findsNothing);
    });

    testWidgets('a claim reads as SOL returning to the wallet', (tester) async {
      await _pump(
        tester,
        _activity(type: api.ActivityType.stakeWithdraw, data: stakeData()),
        chain: Chain.solana,
      );

      expect(find.text('Claimed'), findsOneWidget);
      expect(find.text('+1.0023 SOL'), findsWidgets);
    });
  });
}
