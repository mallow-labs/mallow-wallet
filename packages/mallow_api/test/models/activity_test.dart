import 'package:test/test.dart';
import 'package:mallow_api/mallow_api.dart';

void main() {
  group('ActivityType', () {
    // The wire strings the backend emits, pinned against the enum's
    // `@JsonValue` annotations. A typo on either side is invisible at runtime:
    // `unknownEnumValue` degrades an unrecognised string to
    // [ActivityType.unknown] rather than throwing, so a mistyped mapping does
    // not fail a decode — the row just renders as "unknown" forever. This
    // table is the only place that mismatch can surface.
    const wireValues = {
      'sale': ActivityType.sale,
      'buy': ActivityType.buy,
      'list': ActivityType.list,
      'delist': ActivityType.delist,
      'offer': ActivityType.offer,
      'offer-received': ActivityType.offerReceived,
      'mint': ActivityType.mint,
      'swap': ActivityType.swap,
      'send': ActivityType.send,
      'receive': ActivityType.receive,
      'gumball-create': ActivityType.gumballCreate,
      'gumball-update': ActivityType.gumballUpdate,
      'alt-create': ActivityType.altCreate,
      'stake': ActivityType.stake,
      'unstake': ActivityType.unstake,
      'stake-withdraw': ActivityType.stakeWithdraw,
      'unknown': ActivityType.unknown,
    };

    test('every member has its wire value pinned here', () {
      // A member added without a row above would otherwise ship untested, and
      // the fallback guarantees nothing else complains about it.
      expect(wireValues.values.toSet(), ActivityType.values.toSet());
    });

    wireValues.forEach((wire, type) {
      test("'$wire' decodes to $type and re-encodes unchanged", () {
        final activity = Activity.fromJson(_activityJson(wire));

        expect(activity.type, type);
        expect(activity.toJson()['type'], wire);
      });
    });

    test('a type shipped after this build degrades to unknown', () {
      // Not a nicety: without the fallback one row of an unrecognised type
      // fails the whole page decode, blacking out the feed for every client
      // that has not updated yet.
      expect(Activity.fromJson(_activityJson('teleport')).type, ActivityType.unknown);
    });
  });

  group('ActivityStatus', () {
    test('parses all JSON values correctly', () {
      expect(ActivityStatus.values.length, 3);
      expect(ActivityStatus.confirmed, isNotNull);
      expect(ActivityStatus.finalized, isNotNull);
      expect(ActivityStatus.failed, isNotNull);
    });
  });

  group('TokenInfo', () {
    test('fromJson parses correctly', () {
      final json = {
        'mint': 'So11111111111111111111111111111111111111112',
        'symbol': 'SOL',
        'amount': 1.5,
        'decimals': 9,
        'logoUrl': 'https://example.com/sol.png',
      };

      final token = TokenInfo.fromJson(json);

      expect(token.mint, 'So11111111111111111111111111111111111111112');
      expect(token.symbol, 'SOL');
      expect(token.amount, 1.5);
      expect(token.decimals, 9);
      expect(token.logoUrl, 'https://example.com/sol.png');
    });

    test('fromJson works without optional fields', () {
      final json = {
        'mint': 'So11111111111111111111111111111111111111112',
        'symbol': 'SOL',
        'amount': 1.5,
        'decimals': 9,
      };

      final token = TokenInfo.fromJson(json);

      expect(token.logoUrl, isNull);
    });
  });

  group('Counterparty', () {
    test('fromJson parses correctly with all fields', () {
      final json = {
        'address': 'ABC123',
        'username': 'alice',
        'avatarUrl': 'https://example.com/avatar.png',
      };

      final counterparty = Counterparty.fromJson(json);

      expect(counterparty.address, 'ABC123');
      expect(counterparty.username, 'alice');
      expect(counterparty.avatarUrl, 'https://example.com/avatar.png');
    });

    test('fromJson works without optional fields', () {
      final json = {'address': 'ABC123'};

      final counterparty = Counterparty.fromJson(json);

      expect(counterparty.address, 'ABC123');
      expect(counterparty.username, isNull);
      expect(counterparty.avatarUrl, isNull);
    });
  });

  group('ActivityArtwork', () {
    test('fromJson parses correctly', () {
      final json = {
        'mintAccount': 'MINT123',
        'name': 'Cool Art',
        'imageUrl': 'https://example.com/art.png',
        'artistName': 'Artist',
        'collectionName': 'Collection',
      };

      final artwork = ActivityArtwork.fromJson(json);

      expect(artwork.mintAccount, 'MINT123');
      expect(artwork.name, 'Cool Art');
      expect(artwork.imageUrl, 'https://example.com/art.png');
      expect(artwork.artistName, 'Artist');
      expect(artwork.collectionName, 'Collection');
    });

    test('fromJson works without optional fields', () {
      final json = {
        'mintAccount': 'MINT123',
        'name': 'Cool Art',
        'imageUrl': 'https://example.com/art.png',
      };

      final artwork = ActivityArtwork.fromJson(json);

      expect(artwork.artistName, isNull);
      expect(artwork.collectionName, isNull);
    });
  });

  group('MarketActivityData', () {
    test('fromJson parses correctly', () {
      final json = {
        'artwork': {
          'mintAccount': 'MINT123',
          'name': 'Cool Art',
          'imageUrl': 'https://example.com/art.png',
        },
        'price': 10.5,
        'currencyMint': 'So11111111111111111111111111111111111111112',
        'counterparty': {'address': 'BUYER123', 'username': 'buyer'},
      };

      final data = MarketActivityData.fromJson(json);

      expect(data.artwork.mintAccount, 'MINT123');
      expect(data.price, 10.5);
      expect(data.currencyMint, 'So11111111111111111111111111111111111111112');
      expect(data.counterparty?.address, 'BUYER123');
    });

    test('fromJson works without counterparty', () {
      final json = {
        'artwork': {
          'mintAccount': 'MINT123',
          'name': 'Cool Art',
          'imageUrl': 'https://example.com/art.png',
        },
        'price': 10.5,
        'currencyMint': 'So11111111111111111111111111111111111111112',
      };

      final data = MarketActivityData.fromJson(json);

      expect(data.counterparty, isNull);
    });
  });

  group('SwapActivityData', () {
    test('fromJson parses correctly', () {
      final json = {
        'inputToken': {
          'mint': 'So11111111111111111111111111111111111111112',
          'symbol': 'SOL',
          'amount': 1.0,
          'decimals': 9,
        },
        'outputToken': {
          'mint': 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
          'symbol': 'USDC',
          'amount': 100.0,
          'decimals': 6,
        },
        'priceImpact': 0.05,
        'route': 'Orca',
      };

      final data = SwapActivityData.fromJson(json);

      expect(data.inputToken.symbol, 'SOL');
      expect(data.inputToken.amount, 1.0);
      expect(data.outputToken.symbol, 'USDC');
      expect(data.outputToken.amount, 100.0);
      expect(data.priceImpact, 0.05);
      expect(data.route, 'Orca');
    });

    test('fromJson works without optional fields', () {
      final json = {
        'inputToken': {
          'mint': 'So11111111111111111111111111111111111111112',
          'symbol': 'SOL',
          'amount': 1.0,
          'decimals': 9,
        },
        'outputToken': {
          'mint': 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
          'symbol': 'USDC',
          'amount': 100.0,
          'decimals': 6,
        },
      };

      final data = SwapActivityData.fromJson(json);

      expect(data.priceImpact, isNull);
      expect(data.route, isNull);
    });
  });

  group('TransferActivityData', () {
    test('fromJson parses correctly', () {
      final json = {
        'token': {
          'mint': 'So11111111111111111111111111111111111111112',
          'symbol': 'SOL',
          'amount': 5.0,
          'decimals': 9,
        },
        'counterparty': {'address': 'RECIPIENT123', 'username': 'bob'},
        'isNft': false,
      };

      final data = TransferActivityData.fromJson(json);

      expect(data.token.symbol, 'SOL');
      expect(data.token.amount, 5.0);
      expect(data.counterparty.address, 'RECIPIENT123');
      expect(data.counterparty.username, 'bob');
      expect(data.isNft, false);
    });

    test('fromJson handles NFT transfers', () {
      final json = {
        'token': {'mint': 'NFT_MINT_123', 'symbol': 'NFT', 'amount': 1.0, 'decimals': 0},
        'counterparty': {'address': 'RECIPIENT123'},
        'isNft': true,
      };

      final data = TransferActivityData.fromJson(json);

      expect(data.isNft, true);
      expect(data.token.decimals, 0);
    });
  });

  group('UnknownActivityData', () {
    test('fromJson parses correctly', () {
      final json = {
        'programIds': ['PROG1', 'PROG2'],
        'fee': 0.000005,
      };

      final data = UnknownActivityData.fromJson(json);

      expect(data.programIds, ['PROG1', 'PROG2']);
      expect(data.fee, 0.000005);
    });
  });

  group('Activity', () {
    group('fromJson', () {
      test('parses sale activity correctly', () {
        final json = {
          'id': 'tx123',
          'type': 'sale',
          'timestamp': 1704067200,
          'signature': 'sig123',
          'status': 'finalized',
          'data': {
            'artwork': {
              'mintAccount': 'MINT123',
              'name': 'Cool Art',
              'imageUrl': 'https://example.com/art.png',
            },
            'price': 10.5,
            'currencyMint': 'So11111111111111111111111111111111111111112',
          },
        };

        final activity = Activity.fromJson(json);

        expect(activity.id, 'tx123');
        expect(activity.type, ActivityType.sale);
        expect(activity.timestamp, 1704067200);
        expect(activity.signature, 'sig123');
        expect(activity.status, ActivityStatus.finalized);
        expect(activity.data, isNotEmpty);
        // displayLabel is optional and absent on legacy/cached responses.
        expect(activity.displayLabel, isNull);
      });

      test('parses server-derived displayLabel when present', () {
        final json = {
          'id': 'tx789',
          'type': 'sale',
          'timestamp': 1704067200,
          'signature': 'sig789',
          'status': 'finalized',
          'displayLabel': 'Sold',
          'data': {
            'artwork': {
              'mintAccount': 'MINT123',
              'name': 'Cool Art',
              'imageUrl': 'https://example.com/art.png',
            },
            'price': 10.5,
            'currencyMint': 'So11111111111111111111111111111111111111112',
          },
        };

        final activity = Activity.fromJson(json);

        expect(activity.displayLabel, 'Sold');
      });

      test('parses swap activity correctly', () {
        final json = {
          'id': 'tx456',
          'type': 'swap',
          'timestamp': 1704067200,
          'signature': 'sig456',
          'status': 'confirmed',
          'data': {
            'inputToken': {
              'mint': 'So11111111111111111111111111111111111111112',
              'symbol': 'SOL',
              'amount': 1.0,
              'decimals': 9,
            },
            'outputToken': {
              'mint': 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
              'symbol': 'USDC',
              'amount': 100.0,
              'decimals': 6,
            },
          },
        };

        final activity = Activity.fromJson(json);

        expect(activity.type, ActivityType.swap);
        expect(activity.status, ActivityStatus.confirmed);
      });

      test('parses send activity correctly', () {
        final json = {
          'id': 'tx789',
          'type': 'send',
          'timestamp': 1704067200,
          'signature': 'sig789',
          'status': 'finalized',
          'data': {
            'token': {
              'mint': 'So11111111111111111111111111111111111111112',
              'symbol': 'SOL',
              'amount': 5.0,
              'decimals': 9,
            },
            'counterparty': {'address': 'RECIPIENT123'},
            'isNft': false,
          },
        };

        final activity = Activity.fromJson(json);

        expect(activity.type, ActivityType.send);
      });

      test('parses receive activity correctly', () {
        final json = {
          'id': 'tx101',
          'type': 'receive',
          'timestamp': 1704067200,
          'signature': 'sig101',
          'status': 'finalized',
          'data': {
            'token': {
              'mint': 'So11111111111111111111111111111111111111112',
              'symbol': 'SOL',
              'amount': 2.5,
              'decimals': 9,
            },
            'counterparty': {'address': 'SENDER123'},
            'isNft': false,
          },
        };

        final activity = Activity.fromJson(json);

        expect(activity.type, ActivityType.receive);
      });

      test('parses unknown activity correctly', () {
        final json = {
          'id': 'tx111',
          'type': 'unknown',
          'timestamp': 1704067200,
          'signature': 'sig111',
          'status': 'finalized',
          'data': {
            'programIds': ['PROG1'],
            'fee': 0.000005,
          },
        };

        final activity = Activity.fromJson(json);

        expect(activity.type, ActivityType.unknown);
      });
    });

    group('helper getters', () {
      test('marketData returns correct data for sale type', () {
        final activity = Activity(
          id: 'tx1',
          type: ActivityType.sale,
          timestamp: 1704067200,
          signature: 'sig1',
          status: ActivityStatus.finalized,
          data: {
            'artwork': {
              'mintAccount': 'MINT123',
              'name': 'Cool Art',
              'imageUrl': 'https://example.com/art.png',
            },
            'price': 10.5,
            'currencyMint': 'So11111111111111111111111111111111111111112',
          },
        );

        final marketData = activity.marketData;

        expect(marketData, isNotNull);
        expect(marketData!.artwork.name, 'Cool Art');
        expect(marketData.price, 10.5);
      });

      test('marketData returns null for swap type', () {
        final activity = Activity(
          id: 'tx1',
          type: ActivityType.swap,
          timestamp: 1704067200,
          signature: 'sig1',
          status: ActivityStatus.finalized,
          data: {},
        );

        expect(activity.marketData, isNull);
      });

      test('swapData returns correct data for swap type', () {
        final activity = Activity(
          id: 'tx1',
          type: ActivityType.swap,
          timestamp: 1704067200,
          signature: 'sig1',
          status: ActivityStatus.finalized,
          data: {
            'inputToken': {
              'mint': 'So11111111111111111111111111111111111111112',
              'symbol': 'SOL',
              'amount': 1.0,
              'decimals': 9,
            },
            'outputToken': {
              'mint': 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
              'symbol': 'USDC',
              'amount': 100.0,
              'decimals': 6,
            },
          },
        );

        final swapData = activity.swapData;

        expect(swapData, isNotNull);
        expect(swapData!.inputToken.symbol, 'SOL');
        expect(swapData.outputToken.symbol, 'USDC');
      });

      test('swapData returns null for sale type', () {
        final activity = Activity(
          id: 'tx1',
          type: ActivityType.sale,
          timestamp: 1704067200,
          signature: 'sig1',
          status: ActivityStatus.finalized,
          data: {},
        );

        expect(activity.swapData, isNull);
      });

      test('transferData returns correct data for send type', () {
        final activity = Activity(
          id: 'tx1',
          type: ActivityType.send,
          timestamp: 1704067200,
          signature: 'sig1',
          status: ActivityStatus.finalized,
          data: {
            'token': {
              'mint': 'So11111111111111111111111111111111111111112',
              'symbol': 'SOL',
              'amount': 5.0,
              'decimals': 9,
            },
            'counterparty': {'address': 'RECIPIENT123'},
            'isNft': false,
          },
        );

        final transferData = activity.transferData;

        expect(transferData, isNotNull);
        expect(transferData!.token.symbol, 'SOL');
        expect(transferData.counterparty.address, 'RECIPIENT123');
      });

      test('transferData returns correct data for receive type', () {
        final activity = Activity(
          id: 'tx1',
          type: ActivityType.receive,
          timestamp: 1704067200,
          signature: 'sig1',
          status: ActivityStatus.finalized,
          data: {
            'token': {
              'mint': 'So11111111111111111111111111111111111111112',
              'symbol': 'SOL',
              'amount': 2.5,
              'decimals': 9,
            },
            'counterparty': {'address': 'SENDER123'},
            'isNft': false,
          },
        );

        expect(activity.transferData, isNotNull);
      });

      test('transferData returns null for swap type', () {
        final activity = Activity(
          id: 'tx1',
          type: ActivityType.swap,
          timestamp: 1704067200,
          signature: 'sig1',
          status: ActivityStatus.finalized,
          data: {},
        );

        expect(activity.transferData, isNull);
      });

      test('unknownData returns correct data for unknown type', () {
        final activity = Activity(
          id: 'tx1',
          type: ActivityType.unknown,
          timestamp: 1704067200,
          signature: 'sig1',
          status: ActivityStatus.finalized,
          data: {
            'programIds': ['PROG1', 'PROG2'],
            'fee': 0.000005,
          },
        );

        final unknownData = activity.unknownData;

        expect(unknownData, isNotNull);
        expect(unknownData!.programIds, ['PROG1', 'PROG2']);
        expect(unknownData.fee, 0.000005);
      });

      test('unknownData returns null for sale type', () {
        final activity = Activity(
          id: 'tx1',
          type: ActivityType.sale,
          timestamp: 1704067200,
          signature: 'sig1',
          status: ActivityStatus.finalized,
          data: {},
        );

        expect(activity.unknownData, isNull);
      });

      test('dateTime converts timestamp correctly', () {
        final activity = Activity(
          id: 'tx1',
          type: ActivityType.sale,
          timestamp: 1704067200, // 2024-01-01 00:00:00 UTC
          signature: 'sig1',
          status: ActivityStatus.finalized,
          data: {},
        );

        final dateTime = activity.dateTime;

        expect(dateTime.year, 2024);
        expect(dateTime.month, 1);
        expect(dateTime.day, 1);
      });

      test('explorerUrl generates correct URL', () {
        final activity = Activity(
          id: 'tx1',
          type: ActivityType.sale,
          timestamp: 1704067200,
          signature: 'abc123xyz',
          status: ActivityStatus.finalized,
          data: {},
        );

        expect(activity.explorerUrl, 'https://orbmarkets.io/tx/abc123xyz');
      });
    });

    group('market activity types', () {
      final marketTypes = [
        ActivityType.sale,
        ActivityType.buy,
        ActivityType.list,
        ActivityType.delist,
        ActivityType.offer,
        ActivityType.offerReceived,
        ActivityType.mint,
      ];

      for (final type in marketTypes) {
        test('$type returns marketData correctly', () {
          final activity = Activity(
            id: 'tx1',
            type: type,
            timestamp: 1704067200,
            signature: 'sig1',
            status: ActivityStatus.finalized,
            data: {
              'artwork': {
                'mintAccount': 'MINT123',
                'name': 'Art',
                'imageUrl': 'https://example.com/art.png',
              },
              'price': 10.0,
              'currencyMint': 'So11111111111111111111111111111111111111112',
            },
          );

          expect(activity.marketData, isNotNull);
          expect(activity.swapData, isNull);
          expect(activity.transferData, isNull);
          expect(activity.unknownData, isNull);
        });
      }
    });
  });

  group('ActivityPagination', () {
    test('fromJson parses correctly', () {
      final json = {'page': 1, 'limit': 20, 'hasMore': true, 'lastSignature': 'sig123'};

      final pagination = ActivityPagination.fromJson(json);

      expect(pagination.page, 1);
      expect(pagination.limit, 20);
      expect(pagination.hasMore, true);
      expect(pagination.lastSignature, 'sig123');
    });

    test('fromJson works without lastSignature', () {
      final json = {'page': 0, 'limit': 20, 'hasMore': false};

      final pagination = ActivityPagination.fromJson(json);

      expect(pagination.lastSignature, isNull);
      expect(pagination.hasMore, false);
    });
  });

  group('ActivityListResponse', () {
    test('fromJson parses correctly', () {
      final json = <String, dynamic>{
        'result': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'tx1',
            'type': 'sale',
            'timestamp': 1704067200,
            'signature': 'sig1',
            'status': 'finalized',
            'data': <String, dynamic>{},
          },
          <String, dynamic>{
            'id': 'tx2',
            'type': 'swap',
            'timestamp': 1704067100,
            'signature': 'sig2',
            'status': 'confirmed',
            'data': <String, dynamic>{},
          },
        ],
        'pagination': <String, dynamic>{'page': 0, 'limit': 20, 'hasMore': true},
      };

      final response = ActivityListResponse.fromJson(json);

      expect(response.result.length, 2);
      expect(response.result[0].type, ActivityType.sale);
      expect(response.result[1].type, ActivityType.swap);
      expect(response.pagination.hasMore, true);
    });

    test('fromJson handles empty result', () {
      final json = <String, dynamic>{
        'result': <Map<String, dynamic>>[],
        'pagination': <String, dynamic>{'page': 0, 'limit': 20, 'hasMore': false},
      };

      final response = ActivityListResponse.fromJson(json);

      expect(response.result, isEmpty);
      expect(response.pagination.hasMore, false);
    });
  });
}

/// A minimal well-formed activity row, varying only the `type` wire value.
Map<String, dynamic> _activityJson(String type) => <String, dynamic>{
  'id': 'tx1',
  'type': type,
  'timestamp': 1704067200,
  'signature': 'sig1',
  'status': 'finalized',
  'data': <String, dynamic>{},
};
