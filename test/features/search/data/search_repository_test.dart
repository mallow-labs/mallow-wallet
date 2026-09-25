import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/search/data/search_repository.dart';
import 'package:mallow_wallet/features/search/models/search_models.dart';
import 'package:mocktail/mocktail.dart';

class _Api extends Mock implements api.MallowApiClient {}

class _Dio extends Mock implements Dio {}

void main() {
  for (final first in ['mallow', 'curations', 'tokens']) {
    test('$first results appear before the other endpoints finish', () async {
      final client = _Api();
      final dio = _Dio();
      final mallow = Completer<api.ApiResponse<api.SearchResponse>>();
      final curations =
          Completer<api.ApiResponse<api.CurationSearchResponse>>();
      final tokens = Completer<Response<List<dynamic>>>();
      when(() => client.search(any())).thenAnswer((_) => mallow.future);
      when(
        () => client.searchCurations(any()),
      ).thenAnswer((_) => curations.future);
      when(
        () => dio.get<List<dynamic>>(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer((_) => tokens.future);
      final updates = <SearchResults>[];
      final firstUpdate = Completer<void>();
      final result = SearchRepository(client, dio).search(
        'art',
        onUpdate: (value) {
          updates.add(value);
          if (!firstUpdate.isCompleted) firstUpdate.complete();
        },
      );
      void complete(String source) {
        switch (source) {
          case 'mallow':
            mallow.complete(
              const api.ApiResponse(
                result: api.SearchResponse(
                  users: [api.SearchUserItem(username: 'artist')],
                ),
              ),
            );
          case 'curations':
            curations.complete(
              const api.ApiResponse(
                result: api.CurationSearchResponse(
                  curations: [
                    api.CurationSearchItem(id: 'curation', name: 'Art'),
                  ],
                ),
              ),
            );
          case 'tokens':
            tokens.complete(
              Response(
                requestOptions: RequestOptions(),
                data: [
                  {'id': 'mint', 'name': 'Token', 'symbol': 'TKN'},
                ],
              ),
            );
        }
      }

      complete(first);
      await firstUpdate.future;
      expect(updates.single.isLoading, isTrue);
      expect(
        updates.single.pendingSources,
        SearchSource.values.where((source) => source.name != first).toSet(),
      );
      expect(updates.single.isEmpty, isFalse);
      for (final source in ['mallow', 'curations', 'tokens']) {
        if (source != first) complete(source);
      }
      final finalResult = await result;
      expect(finalResult.isLoading, isFalse);
      expect(finalResult.users.single.username, 'artist');
      expect(finalResult.curations.single.id, 'curation');
      expect(finalResult.tokens.single.mintAddress, 'mint');
      // Published snapshots must not mutate as other responses arrive.
      expect(
        updates.first.users.length +
            updates.first.curations.length +
            updates.first.tokens.length,
        1,
      );
    });
  }

  test('a failed endpoint preserves successful results', () async {
    final client = _Api();
    final dio = _Dio();
    when(() => client.search(any())).thenThrow(Exception('offline'));
    when(() => client.searchCurations(any())).thenAnswer(
      (_) async => const api.ApiResponse(
        result: api.CurationSearchResponse(
          curations: [api.CurationSearchItem(id: 'curation', name: 'Art')],
        ),
      ),
    );
    when(
      () => dio.get<List<dynamic>>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenThrow(Exception('offline'));
    final result = await SearchRepository(client, dio).search('art');
    expect(result.isLoading, isFalse);
    expect(result.curations.single.id, 'curation');
  });
}
