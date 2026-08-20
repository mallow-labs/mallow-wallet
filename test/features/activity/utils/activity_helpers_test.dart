import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/activity/utils/activity_helpers.dart';
import 'package:mallow_wallet/shared/theme/mallow_colors.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

void main() {
  const colors = MallowColors.light;

  api.Activity activity({
    required api.ActivityType type,
    Map<String, dynamic>? data,
    String? displayLabel,
  }) {
    return api.Activity(
      id: 'a1',
      type: type,
      timestamp: 0,
      signature: 'sig',
      status: api.ActivityStatus.confirmed,
      data: data ?? const {},
      displayLabel: displayLabel,
    );
  }

  group('isOutgoing', () {
    test('true for asset-leaving types', () {
      for (final t in [
        api.ActivityType.buy,
        api.ActivityType.mint,
        api.ActivityType.send,
        api.ActivityType.offer,
        api.ActivityType.stake,
      ]) {
        expect(isOutgoing(t), isTrue, reason: t.name);
      }
    });

    test('false for everything else', () {
      for (final t in [
        api.ActivityType.sale,
        api.ActivityType.receive,
        api.ActivityType.offerReceived,
        api.ActivityType.list,
        api.ActivityType.delist,
        api.ActivityType.swap,
        api.ActivityType.gumballCreate,
        api.ActivityType.gumballUpdate,
        api.ActivityType.altCreate,
        api.ActivityType.unstake,
        api.ActivityType.stakeWithdraw,
        api.ActivityType.unknown,
      ]) {
        expect(isOutgoing(t), isFalse, reason: t.name);
      }
    });
  });

  group('isIncoming', () {
    test('true for asset-entering types', () {
      for (final t in [
        api.ActivityType.sale,
        api.ActivityType.receive,
        api.ActivityType.stakeWithdraw,
      ]) {
        expect(isIncoming(t), isTrue, reason: t.name);
      }
    });

    test('unstaking is neither direction — nothing has moved yet', () {
      // Deactivation only starts the epoch-bound wind-down; the lamports stay
      // in the stake account until the claim (`stakeWithdraw`) moves them. A
      // sign here would credit or debit a balance change that hasn't happened.
      expect(isOutgoing(api.ActivityType.unstake), isFalse);
      expect(isIncoming(api.ActivityType.unstake), isFalse);
      expect(directionColor(api.ActivityType.unstake, colors), isNull);
    });

    test('offer-received is not incoming — no money entered the wallet', () {
      // A bid placed on the viewer's listing sits in the bidder's escrow until
      // it is accepted. Treating it as incoming rendered a green "+0.5 SOL"
      // credit for funds the viewer does not have.
      expect(isIncoming(api.ActivityType.offerReceived), isFalse);
      expect(directionColor(api.ActivityType.offerReceived, colors), isNull);
    });

    test('false for everything else', () {
      for (final t in [
        api.ActivityType.buy,
        api.ActivityType.mint,
        api.ActivityType.send,
        api.ActivityType.offer,
        api.ActivityType.offerReceived,
        api.ActivityType.list,
        api.ActivityType.delist,
        api.ActivityType.swap,
        api.ActivityType.gumballCreate,
        api.ActivityType.gumballUpdate,
        api.ActivityType.altCreate,
        api.ActivityType.stake,
        api.ActivityType.unstake,
        api.ActivityType.unknown,
      ]) {
        expect(isIncoming(t), isFalse, reason: t.name);
      }
    });

    test('no activity type is both incoming and outgoing', () {
      for (final t in api.ActivityType.values) {
        expect(
          isOutgoing(t) && isIncoming(t),
          isFalse,
          reason: '${t.name} flagged as both directions',
        );
      }
    });
  });

  group('directionColor', () {
    test('returns negative for outgoing types', () {
      expect(directionColor(api.ActivityType.send, colors), colors.negative);
      expect(directionColor(api.ActivityType.offer, colors), colors.negative);
    });

    test('returns positive for incoming types', () {
      expect(directionColor(api.ActivityType.sale, colors), colors.positive);
      expect(directionColor(api.ActivityType.receive, colors), colors.positive);
    });

    test('returns null for neutral types', () {
      expect(directionColor(api.ActivityType.list, colors), isNull);
      expect(directionColor(api.ActivityType.delist, colors), isNull);
      expect(directionColor(api.ActivityType.swap, colors), isNull);
      expect(directionColor(api.ActivityType.unknown, colors), isNull);
    });
  });

  group('refunds', () {
    // Being outbid returns your escrowed bid: the row keeps the `offer` type of
    // the bid it reverses, so without the server's `isRefund` flag the money
    // coming back reads as a second debit. It must read as a credit.
    api.Activity refundedBid() =>
        activity(type: api.ActivityType.offer, data: const {'isRefund': true});

    test('isRefund only fires on rows the server flagged', () {
      expect(isRefund(refundedBid()), isTrue);
      expect(isRefund(activity(type: api.ActivityType.offer)), isFalse);
      expect(
        isRefund(
          activity(
            type: api.ActivityType.offer,
            data: const {'isRefund': false},
          ),
        ),
        isFalse,
      );
      // The flag is a strict `true` check — a truthy-looking string is not a
      // refund, so a malformed payload can't flip a debit into a credit.
      expect(
        isRefund(
          activity(
            type: api.ActivityType.offer,
            data: const {'isRefund': 'true'},
          ),
        ),
        isFalse,
      );
    });

    test('a refunded bid is incoming, never outgoing', () {
      final a = refundedBid();
      expect(isActivityIncoming(a), isTrue);
      expect(isActivityOutgoing(a), isFalse);
      expect(activityDirectionColor(a, colors), colors.positive);
    });

    test('an unrefunded bid still reads as a debit', () {
      // The refund fix must not neutralise the bid itself — placing an offer
      // does escrow the viewer's funds.
      final a = activity(type: api.ActivityType.offer);
      expect(isActivityOutgoing(a), isTrue);
      expect(activityDirectionColor(a, colors), colors.negative);
    });

    test('activity-level helpers otherwise match the type-level ones', () {
      for (final t in api.ActivityType.values) {
        final a = activity(type: t);
        expect(isActivityOutgoing(a), isOutgoing(t), reason: t.name);
        expect(isActivityIncoming(a), isIncoming(t), reason: t.name);
        expect(
          activityDirectionColor(a, colors),
          directionColor(t, colors),
          reason: t.name,
        );
      }
    });
  });

  group('previewBorderColor', () {
    test('negative for asset-leaving types and buy', () {
      expect(
        previewBorderColor(api.ActivityType.send, colors),
        colors.negative,
      );
      expect(
        previewBorderColor(api.ActivityType.list, colors),
        colors.negative,
      );
      expect(previewBorderColor(api.ActivityType.buy, colors), colors.negative);
    });

    test('positive for asset-entering types and sale', () {
      expect(
        previewBorderColor(api.ActivityType.receive, colors),
        colors.positive,
      );
      expect(
        previewBorderColor(api.ActivityType.mint, colors),
        colors.positive,
      );
      expect(
        previewBorderColor(api.ActivityType.delist, colors),
        colors.positive,
      );
      expect(
        previewBorderColor(api.ActivityType.sale, colors),
        colors.positive,
      );
    });

    test('null for swap and other neutral types', () {
      expect(previewBorderColor(api.ActivityType.swap, colors), isNull);
      expect(previewBorderColor(api.ActivityType.offer, colors), isNull);
      expect(
        previewBorderColor(api.ActivityType.offerReceived, colors),
        isNull,
      );
      expect(previewBorderColor(api.ActivityType.unknown, colors), isNull);
    });
  });

  group('activityVerb', () {
    test('returns the canonical verb for every activity type', () {
      final expected = {
        api.ActivityType.sale: 'Sold',
        api.ActivityType.buy: 'Bought',
        api.ActivityType.list: 'Listed',
        api.ActivityType.delist: 'Delisted',
        api.ActivityType.offer: 'Offer made',
        api.ActivityType.offerReceived: 'Offer received',
        api.ActivityType.mint: 'Minted',
        api.ActivityType.swap: 'Token swap',
        api.ActivityType.send: 'Transferred',
        api.ActivityType.receive: 'Received',
        api.ActivityType.gumballCreate: 'Create Gumball',
        api.ActivityType.gumballUpdate: 'Update Gumball',
        api.ActivityType.altCreate: 'Create Lookup Table',
        api.ActivityType.stake: 'Staked',
        api.ActivityType.unstake: 'Unstaked',
        api.ActivityType.stakeWithdraw: 'Claimed stake',
        api.ActivityType.unknown: 'Unknown transaction',
      };

      // Ensure no enum value is missing — guards against silent drift when
      // new ActivityTypes are added upstream.
      expect(expected.keys.toSet(), api.ActivityType.values.toSet());

      for (final entry in expected.entries) {
        expect(activityVerb(entry.key), entry.value, reason: entry.key.name);
      }
    });
  });

  group('activityDisplayLabel', () {
    test('uses the server displayLabel when present', () {
      final a = activity(
        type: api.ActivityType.sale,
        displayLabel: 'Royalty payout',
      );
      expect(activityDisplayLabel(a), 'Royalty payout');
    });

    test('falls back to the typed verb when displayLabel is null', () {
      // Legacy/cached responses omit the field entirely.
      final a = activity(type: api.ActivityType.sale);
      expect(a.displayLabel, isNull);
      expect(activityDisplayLabel(a), 'Sold');
    });

    test('falls back to the typed verb when displayLabel is empty', () {
      // Empty string is a common "no label" serialization — it must not
      // render as a blank label, which a bare `?? activityVerb` would allow.
      final a = activity(type: api.ActivityType.buy, displayLabel: '');
      expect(activityDisplayLabel(a), 'Bought');
    });

    test(
      'falls back to the typed verb when displayLabel is whitespace-only',
      () {
        // Mixed whitespace (spaces, tab, newline) must not render as a
        // visually blank label — pins the trim semantics of the guard.
        final a = activity(type: api.ActivityType.buy, displayLabel: ' \t\n ');
        expect(activityDisplayLabel(a), 'Bought');
      },
    );

    test('trims surrounding whitespace from the server displayLabel', () {
      // The guard trims for the blank-check, so the returned label is trimmed
      // too — padding must never leak into the rendered Text.
      final a = activity(
        type: api.ActivityType.sale,
        displayLabel: '  Royalty payout  ',
      );
      expect(activityDisplayLabel(a), 'Royalty payout');
    });
  });

  group('inferActivityChain', () {
    // The feed mixes every session wallet's chains into one list, so a row's
    // own shape is all a list item has to go on before rendering a chain-
    // denominated value. Guessing wrong prints the wrong ticker.
    api.Activity transfer({
      required String mint,
      String signature = 'sig',
      String counterparty = 'OtherWallet1111111111111111111111111111111',
    }) => api.Activity(
      id: 'a1',
      type: api.ActivityType.send,
      timestamp: 0,
      signature: signature,
      status: api.ActivityStatus.confirmed,
      data: {
        'token': {'mint': mint, 'symbol': '', 'amount': 1.0, 'decimals': 0},
        'counterparty': {'address': counterparty},
        'isNft': true,
      },
    );

    test('reads Ethereum off the 0x signature or mint', () {
      expect(
        inferActivityChain(
          transfer(
            mint: 'Base58Mint111111111111111111111111111111111',
            signature: '0xabc',
          ),
        ),
        Chain.ethereum,
      );
      expect(
        inferActivityChain(
          transfer(mint: '0x1111111111111111111111111111111111111111-42'),
        ),
        Chain.ethereum,
      );
    });

    test('reads Tezos off a KT1 contract or a tz counterparty', () {
      expect(inferActivityChain(transfer(mint: 'KT1Abc-7')), Chain.tezos);
      expect(
        inferActivityChain(
          transfer(
            mint: 'Base58Mint111111111111111111111111111111111',
            counterparty: 'tz1Minter11111111111111111111111',
          ),
        ),
        Chain.tezos,
      );
    });

    test('treats a plain base58 mint as Solana', () {
      expect(
        inferActivityChain(
          transfer(mint: 'So11111111111111111111111111111111111111112'),
        ),
        Chain.solana,
      );
    });

    test('returns null when the row carries no asset to judge by', () {
      // Gumball / unknown rows have no mint at all — callers must render
      // without a ticker rather than defaulting to SOL.
      expect(
        inferActivityChain(
          activity(type: api.ActivityType.unknown, data: const {'fee': 0.1}),
        ),
        isNull,
      );
    });
  });

  group('hasNftData', () {
    Map<String, dynamic> marketDataJson() => {
      'artwork': {
        'mintAccount': 'MINT',
        'name': 'Art',
        'imageUrl': 'https://example.com/i.png',
      },
      'price': 1.0,
      'currencyMint': 'CUR',
    };

    Map<String, dynamic> transferDataJson({required bool isNft}) => {
      'token': {'mint': 'MINT', 'symbol': 'SOL', 'amount': 1.0, 'decimals': 9},
      'counterparty': {'address': 'OTHER'},
      'isNft': isNft,
    };

    test('true when the activity has market data', () {
      // Any market type with valid market JSON exposes marketData.
      final a = activity(type: api.ActivityType.sale, data: marketDataJson());
      expect(hasNftData(a), isTrue);
    });

    test('true for transfers that move an NFT', () {
      final a = activity(
        type: api.ActivityType.send,
        data: transferDataJson(isNft: true),
      );
      expect(hasNftData(a), isTrue);
    });

    test('false for fungible-token transfers', () {
      final a = activity(
        type: api.ActivityType.send,
        data: transferDataJson(isNft: false),
      );
      expect(hasNftData(a), isFalse);
    });

    test('false for non-NFT activity kinds (swap, unknown)', () {
      final swap = activity(
        type: api.ActivityType.swap,
        data: {
          'inputToken': {
            'mint': 'A',
            'symbol': 'A',
            'amount': 1.0,
            'decimals': 9,
          },
          'outputToken': {
            'mint': 'B',
            'symbol': 'B',
            'amount': 1.0,
            'decimals': 9,
          },
        },
      );
      final unknown = activity(
        type: api.ActivityType.unknown,
        data: {'programIds': <String>[], 'fee': 0.0},
      );
      expect(hasNftData(swap), isFalse);
      expect(hasNftData(unknown), isFalse);
    });
  });

  group('statusLabel', () {
    test('covers every ActivityStatus value', () {
      final expected = {
        api.ActivityStatus.confirmed: 'Confirmed',
        api.ActivityStatus.finalized: 'Finalized',
        api.ActivityStatus.failed: 'Failed',
      };
      expect(expected.keys.toSet(), api.ActivityStatus.values.toSet());
      for (final entry in expected.entries) {
        expect(statusLabel(entry.key), entry.value, reason: entry.key.name);
      }
    });
  });
}
