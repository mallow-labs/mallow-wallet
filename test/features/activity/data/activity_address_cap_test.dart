import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/activity/data/activity_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockApi extends Mock implements api.MallowApiV2Client {}

/// Distinct base58-shaped Solana addresses.
List<String> _solana(int n) => [
  for (var i = 0; i < n; i++)
    'So1ana${'1' * 30}${i.toString().padLeft(4, 'A')}',
];

/// Distinct lowercased EVM addresses.
List<String> _evm(int n) => [
  for (var i = 0; i < n; i++) '0x${i.toRadixString(16).padLeft(40, '0')}',
];

const _tezos = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';

void main() {
  group('capActivityAddresses', () {
    test('passes a set within both limits through unchanged', () {
      final addresses = [..._solana(10), ..._evm(19), _tezos];
      expect(capActivityAddresses(addresses), addresses);
    });

    test('keeps the first 10 Solana addresses and drops the rest', () {
      final solana = _solana(12);
      final evm = _evm(2);
      final capped = capActivityAddresses([...solana, ...evm]);
      expect(capped, [...solana.take(10), ...evm]);
    });

    test('keeps at most 30 addresses in total', () {
      final addresses = [..._solana(5), ..._evm(30)];
      final capped = capActivityAddresses(addresses);
      expect(capped, hasLength(kActivityMaxAddresses));
      expect(capped, addresses.take(30));
    });

    test('skips empty and repeated addresses', () {
      final solana = _solana(2);
      expect(capActivityAddresses(['', solana[0], solana[0], solana[1]]), [
        solana[0],
        solana[1],
      ]);
    });

    test('counts Tezos wallets and EVM addresses outside the Solana limit', () {
      final addresses = [..._solana(10), _tezos, ..._evm(3)];
      expect(capActivityAddresses(addresses), addresses);
    });

    test('counts an unrecognised address against the Solana limit', () {
      final solana = _solana(10);
      expect(capActivityAddresses([...solana, 'KT1-contract']), solana);
    });
  });

  test('getActivities sends only the capped addresses', () async {
    final db = MallowDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final apiClient = _MockApi();
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
        pagination: api.ActivityPagination(page: 0, limit: 20, hasMore: false),
      ),
    );
    final solana = _solana(11);

    await ActivityRepository(apiClient, db).getActivities(addresses: solana);

    final sent =
        verify(
              () => apiClient.getActivities(
                addresses: captureAny(named: 'addresses'),
                page: any(named: 'page'),
                limit: any(named: 'limit'),
                types: any(named: 'types'),
                before: any(named: 'before'),
              ),
            ).captured.single
            as String;
    expect(sent.split(','), solana.take(kActivityMaxSolanaAddresses));
  });
}
