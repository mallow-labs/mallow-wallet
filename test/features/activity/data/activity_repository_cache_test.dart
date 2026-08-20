import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/activity/data/activity_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockApi extends Mock implements api.MallowApiV2Client {}

/// Build a `receive` transfer activity for [amount] units of an [decimals]-
/// decimal token. Mirrors the wire shape the API sends (and the EVM activity
/// feed now produces): a human-readable `amount` plus the token's native
/// `decimals`.
api.Activity _transfer({
  required double amount,
  required int decimals,
  String mint = 'native',
  String symbol = 'ETH',
}) {
  return api.Activity(
    id: '0xhash-$amount',
    type: api.ActivityType.receive,
    timestamp: 1700000000,
    signature: '0xhash-$amount',
    status: api.ActivityStatus.finalized,
    data: {
      'token': {
        'mint': mint,
        'symbol': symbol,
        'amount': amount,
        'decimals': decimals,
      },
      'counterparty': {'address': '0xcounterparty'},
      'isNft': false,
    },
  );
}

api.Activity _optimisticSend() => const api.Activity(
  id: 'sig-send',
  type: api.ActivityType.send,
  timestamp: 1700000001,
  signature: 'sig-send',
  status: api.ActivityStatus.confirmed,
  data: {
    'token': {
      'mint': 'So11111111111111111111111111111111111111112',
      'symbol': 'SOL',
      'amount': 1.25,
      'decimals': 9,
    },
    'counterparty': {'address': 'recipient'},
    'isNft': false,
  },
);

void main() {
  late MallowDatabase db;
  late ActivityRepository repo;
  late _MockApi apiClient;

  setUp(() {
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    apiClient = _MockApi();
    repo = ActivityRepository(apiClient, db);
  });

  tearDown(() => db.close());

  const wallet = '0x8332f42f02ef59d9425bd291f5901736bed1f801';

  // A high-value 18-decimal transfer scales to a raw smallest-unit value that
  // overflows int64 (1000 × 10^18 = 1e21 > 9.22e18). The denormalized
  // `Activities.amount` cache column cannot hold it; before the overflow guard,
  // computing it threw `StateError` mid-cache-write, failing the WHOLE activity
  // load with a "Failed to load activities" toast even though the response
  // parsed fine. EVM (18 decimals) hits this constantly; Solana (≤9) never did.
  test(
    'caches a transfer whose raw amount overflows int64 without throwing',
    () async {
      final activity = _transfer(amount: 1000, decimals: 18);

      await expectLater(repo.cacheActivities(wallet, [activity]), completes);

      // The row must persist, and the true amount must survive (it is read back
      // from the JSON blob, not the dropped int column) so large EVM transfers
      // still render from cache.
      final cached = await repo.getCachedActivities(wallet);
      expect(cached, hasLength(1));
      expect(cached.single.transferData?.token.amount, 1000);
      expect(cached.single.transferData?.token.decimals, 18);
    },
  );

  test(
    'a mixed page with an overflowing item still caches every item',
    () async {
      final activities = [
        _transfer(amount: 0.024, decimals: 18),
        _transfer(amount: 5000, decimals: 18),
        _transfer(amount: 1.5, decimals: 9, mint: 'So111', symbol: 'SOL'),
      ];

      await repo.cacheActivities(wallet, activities);

      final cached = await repo.getCachedActivities(wallet);
      expect(cached, hasLength(3));
    },
  );

  test('keeps an optimistic send until the server returns its row', () async {
    final activity = _optimisticSend();
    await repo.cacheOptimisticActivity(addresses: [wallet], activity: activity);

    final cached = await repo.getCachedActivities(wallet);
    expect(cached.single.id, activity.id);
    expect(cached.single.transferData?.token.amount, 1.25);

    when(
      () => apiClient.getActivities(
        addresses: any(named: 'addresses'),
        page: any(named: 'page'),
        limit: any(named: 'limit'),
        types: any(named: 'types'),
        before: any(named: 'before'),
      ),
    ).thenAnswer(
      (_) async => const api.ActivityListResponse(
        result: [],
        pagination: api.ActivityPagination(page: 0, limit: 50, hasMore: false),
      ),
    );

    final beforeIndexed = await repo.getActivities(
      addresses: [wallet],
      page: 0,
      limit: 50,
    );
    expect(beforeIndexed.result.map((item) => item.id), [activity.id]);

    final serverActivity = activity.copyWith(
      status: api.ActivityStatus.finalized,
    );
    when(
      () => apiClient.getActivities(
        addresses: any(named: 'addresses'),
        page: any(named: 'page'),
        limit: any(named: 'limit'),
        types: any(named: 'types'),
        before: any(named: 'before'),
      ),
    ).thenAnswer(
      (_) async => api.ActivityListResponse(
        result: [serverActivity],
        pagination: const api.ActivityPagination(
          page: 0,
          limit: 50,
          hasMore: false,
        ),
      ),
    );

    final afterIndexed = await repo.getActivities(
      addresses: [wallet],
      page: 0,
      limit: 50,
    );
    expect(afterIndexed.result, [serverActivity]);
  });
}
