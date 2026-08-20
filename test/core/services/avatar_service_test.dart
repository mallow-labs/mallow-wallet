import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mocktail/mocktail.dart';

class _MockDio extends Mock implements Dio {}

class _FakeOptions extends Fake implements Options {}

void main() {
  setUpAll(() {
    registerFallbackValue(Uri());
    registerFallbackValue(_FakeOptions());
  });

  late Directory tmp;
  late _MockDio dio;

  final svgBytes = '<svg xmlns="http://www.w3.org/2000/svg"></svg>'.codeUnits;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('avatar_test');
    dio = _MockDio();
    when(
      () => dio.getUri<List<int>>(any(), options: any(named: 'options')),
    ).thenAnswer(
      (_) async => Response<List<int>>(
        requestOptions: RequestOptions(),
        data: svgBytes,
        statusCode: 200,
      ),
    );
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test(
    'fetches once, writes to disk, and serves later loads from disk',
    () async {
      // First service instance fetches over the network and persists.
      final svc1 = AvatarService.forTest(dio, cacheDir: tmp);
      final file1 = await svc1.avatarFile('seed-uuid');
      expect(file1, isNotNull);
      expect(await file1!.exists(), isTrue);
      expect(await file1.readAsBytes(), svgBytes);
      verify(
        () => dio.getUri<List<int>>(any(), options: any(named: 'options')),
      ).called(1);

      // A fresh instance (cold in-memory cache) over the SAME dir must read the
      // persisted file without hitting the network again — the whole point of the
      // on-disk cache.
      final dio2 = _MockDio();
      final svc2 = AvatarService.forTest(dio2, cacheDir: tmp);
      final file2 = await svc2.avatarFile('seed-uuid');
      expect(file2, isNotNull);
      verifyNever(
        () => dio2.getUri<List<int>>(any(), options: any(named: 'options')),
      );
    },
  );

  test('returns null for an empty seed without touching the network', () async {
    final svc = AvatarService.forTest(dio, cacheDir: tmp);
    expect(await svc.avatarFile(''), isNull);
    verifyNever(
      () => dio.getUri<List<int>>(any(), options: any(named: 'options')),
    );
  });

  test('avatarUrl carries the seed verbatim', () {
    final svc = AvatarService.forTest(dio, cacheDir: tmp);
    final url = svc.avatarUrl('abc-123').toString();
    // Why: the identicon is deterministic in the seed, so the URL must carry
    // it unmodified — account UUIDs and public identifiers (address/username)
    // alike — or the same identity would render different avatars.
    expect(url, contains('seed=abc-123'));
    expect(url, contains('identicon'));
  });

  test('avatarSeedOf prefers username, then address, then id', () {
    // Why: the fallback-avatar contract is username → address → id so a
    // profile renders the same identicon on surfaces that only know its
    // username (drawer header, profile switcher) as on the profile page, which
    // also knows its address — and wallet-only rows still get a stable one.
    expect(avatarSeedOf(address: 'ADDR', username: 'user', id: 'id-1'), 'user');
    expect(avatarSeedOf(address: 'ADDR', username: '', id: 'id-1'), 'ADDR');
    expect(avatarSeedOf(id: 'id-1'), 'id-1');
    expect(avatarSeedOf(), '');
  });

  test('EVM address seeds normalise to lowercase everywhere', () async {
    // Why: the same EVM account reaches the UI both EIP-55 checksummed (local
    // wallets) and lowercased (backend rows). The identicon and its rowColor
    // hash the seed string, so without normalisation one address would render
    // two different avatars depending on which surface drew it.
    const checksummed = '0xAbC0000000000000000000000000000000000dEf';
    const lowercased = '0xabc0000000000000000000000000000000000def';

    final svc = AvatarService.forTest(dio, cacheDir: tmp);
    expect(svc.avatarUrl(checksummed), svc.avatarUrl(lowercased));
    expect(avatarSeedOf(address: checksummed), lowercased);

    // One cache entry and one fetch, whichever form the caller holds.
    final a = await svc.avatarFile(checksummed);
    final b = await svc.avatarFile(lowercased);
    expect(a!.path, b!.path);
    verify(
      () => dio.getUri<List<int>>(any(), options: any(named: 'options')),
    ).called(1);
    expect(svc.cachedFile(checksummed)?.path, a.path);

    // Solana (base58) and Tezos addresses are case-sensitive — untouched.
    const solana = 'GDfnEsia2WLAW5t8yx2X5j2mkfA74i5kwGdDuZHt7XmG';
    expect(avatarSeedOf(address: solana), solana);
    expect(
      normalizeAvatarSeed('tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb'),
      'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb',
    );
  });

  test('path-unsafe seeds cache under distinct sanitised filenames', () async {
    // Why: seeds are no longer only UUIDs — usernames can carry path-unsafe
    // characters, and two seeds that sanitise alike must not share (and thus
    // overwrite) one cache file.
    final svc = AvatarService.forTest(dio, cacheDir: tmp);
    final a = await svc.avatarFile('a/b');
    final b = await svc.avatarFile('a_b');
    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(a!.path, isNot(b!.path));
    expect(a.path, isNot(contains('a/b')));
  });
}
