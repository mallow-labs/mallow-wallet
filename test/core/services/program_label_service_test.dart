import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/program_label_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _url = 'https://cdn.example.com/config/solana-program-labels.json';
const _system = '11111111111111111111111111111111';
const _jupiter = 'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4';

// Programs with no compiled-in name, so only the list can name them.
const _config = 'Config1111111111111111111111111111111111111';
const _feature = 'Feature111111111111111111111111111111111111';

/// Serves the list from a per-test script and counts requests, so "no request
/// inside the TTL" is asserted rather than assumed.
class _ScriptedAdapter implements HttpClientAdapter {
  ResponseBody Function()? route;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    expect(options.uri.toString(), _url);
    final route = this.route;
    if (route == null) throw StateError('unstubbed list');
    return route();
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _body(Object? json, int status) => ResponseBody.fromString(
  json == null ? '' : jsonEncode(json),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

Map<String, dynamic> _list(List<Object?> programs) => {
  'version': 1,
  'programs': programs,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PreferencesService prefs;
  late _ScriptedAdapter adapter;
  late DateTime clock;

  setUp(() async {
    Config.debugOverrides['PROGRAM_LABELS_URL'] = _url;
    SharedPreferences.setMockInitialValues({});
    prefs = await PreferencesService.create();
    adapter = _ScriptedAdapter();
    clock = DateTime(2026, 10, 2, 9);
  });
  tearDown(Config.debugOverrides.clear);

  /// A fresh service on the same preferences: one app launch. No retries
  /// unless a test asks for them, so a failure case does not wait them out.
  Future<ProgramLabelService> launch({
    List<Duration> retryDelays = const [],
  }) async {
    final service = ProgramLabelService.withSeams(
      prefs,
      dio: Dio()..httpClientAdapter = adapter,
      now: () => clock,
      retryDelays: retryDelays,
    );
    addTearDown(service.dispose);
    service.start();
    await service.settled;
    return service;
  }

  group('launch fetch', () {
    test('a first launch fetches the list and names programs', () async {
      adapter.route = () => _body(
        _list([
          {'address': _system, 'name': 'System Program'},
          {'address': _jupiter, 'name': 'Jupiter Aggregator v6'},
        ]),
        200,
      );
      final service = await launch();
      expect(adapter.calls, 1);
      expect(service.nameOf(_system), 'System Program');
      expect(service.nameOf(_jupiter), 'Jupiter Aggregator v6');
      expect(service.nameOf('Unknown1111111111111111111111111111111111'), null);
    });

    test('a launch inside the TTL serves the cache with no request', () async {
      adapter.route = () => _body(
        _list([
          {'address': _system, 'name': 'System Program'},
        ]),
        200,
      );
      await launch();
      clock = clock.add(const Duration(hours: 23));
      final second = await launch();
      expect(adapter.calls, 1);
      expect(second.nameOf(_system), 'System Program');
    });

    test('a launch after the TTL refetches and replaces the list', () async {
      adapter.route = () => _body(
        _list([
          {'address': _config, 'name': 'Config Program'},
        ]),
        200,
      );
      await launch();
      clock = clock.add(ProgramLabelService.ttl);
      adapter.route = () => _body(
        _list([
          {'address': _feature, 'name': 'Feature Gate'},
        ]),
        200,
      );
      final second = await launch();
      expect(adapter.calls, 2);
      expect(second.nameOf(_feature), 'Feature Gate');
      expect(second.nameOf(_config), null);
    });

    test('start fetches once however often it is called', () async {
      adapter.route = () => _body(_list(const <Object?>[]), 200);
      final service = await launch();
      service.start();
      service.start();
      await service.settled;
      expect(adapter.calls, 1);
    });

    test(
      'a failed fetch keeps the last good list and retries next launch',
      () async {
        adapter.route = () => _body(
          _list([
            {'address': _config, 'name': 'Config Program'},
          ]),
          200,
        );
        await launch();
        clock = clock.add(const Duration(days: 2));
        adapter.route = () => _body(null, 503);
        final stale = await launch();
        expect(stale.nameOf(_config), 'Config Program');

        // The failure did not stamp the cache, so the next launch asks again.
        adapter.route = () => _body(_list(const <Object?>[]), 200);
        final next = await launch();
        expect(adapter.calls, 3);
        expect(next.nameOf(_config), null);
      },
    );

    test('a launch fetch that cannot reach the list retries', () async {
      // A phone that has just woken often has no network for a few seconds;
      // one failed attempt must not leave the whole session unnamed.
      adapter.route = () => adapter.calls < 3
          ? _body(null, 503)
          : _body(
              _list([
                {'address': _system, 'name': 'System Program'},
              ]),
              200,
            );
      final service = await launch(
        retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
      );
      expect(adapter.calls, 3);
      expect(service.nameOf(_system), 'System Program');
      expect(prefs.programLabelCache, isNotNull);
    });

    test('retries stop after the last backoff step', () async {
      adapter.route = () => _body(null, 503);
      final service = await launch(
        retryDelays: const [Duration.zero, Duration.zero],
      );
      expect(adapter.calls, 3);
      expect(service.labels.value, ProgramLabelService.canonicalNames);
      expect(prefs.programLabelCache, isNull);
    });

    test('a malformed list is not retried', () async {
      adapter.route = () =>
          _body({'version': 2, 'programs': const <Object?>[]}, 200);
      await launch(retryDelays: const [Duration.zero, Duration.zero]);
      expect(adapter.calls, 1);
    });

    test('a malformed payload keeps the last good list', () async {
      adapter.route = () => _body(
        _list([
          {'address': _system, 'name': 'System Program'},
        ]),
        200,
      );
      await launch();
      clock = clock.add(const Duration(days: 2));
      adapter.route = () =>
          _body({'version': 2, 'programs': const <Object?>[]}, 200);
      final service = await launch();
      expect(service.nameOf(_system), 'System Program');
    });

    test(
      'no URL configured means no request and only built-in names',
      () async {
        Config.debugOverrides['PROGRAM_LABELS_URL'] = '';
        final service = await launch();
        expect(adapter.calls, 0);
        expect(service.labels.value, ProgramLabelService.canonicalNames);
        expect(service.nameOf(_system), 'System Program');
        expect(
          service.nameOf('Unknown1111111111111111111111111111111111'),
          null,
        );
      },
    );

    test('an unreadable cache is ignored and refetched', () async {
      await prefs.setProgramLabelCache('not json');
      adapter.route = () => _body(
        _list([
          {'address': _system, 'name': 'System Program'},
        ]),
        200,
      );
      final service = await launch();
      expect(adapter.calls, 1);
      expect(service.nameOf(_system), 'System Program');
    });
  });

  group('instructions', () {
    test('a failed launch fetch retains core instruction names', () async {
      adapter.route = () => _body(null, 403);
      final service = await launch();
      expect(service.labels.value, ProgramLabelService.canonicalNames);
      expect(
        service.instructions.nameOf(_system, Uint8List.fromList([2, 0, 0, 0])),
        'Transfer',
      );
    });

    test('a fresh cache without instruction entries uses core names', () async {
      await prefs.setProgramLabelCache(
        jsonEncode({
          'fetchedAt': clock.millisecondsSinceEpoch,
          'programs': {_system: 'System Program'},
          'instructions': <String, Object?>{},
        }),
      );
      final service = await launch();
      expect(adapter.calls, 0);
      expect(
        service.instructions.nameOf(_system, Uint8List.fromList([2, 0, 0, 0])),
        'Transfer',
      );
    });

    test('core names are available before the launch fetch', () {
      final service = ProgramLabelService.withSeams(prefs);
      addTearDown(service.dispose);
      expect(
        service.instructions.nameOf(_system, Uint8List.fromList([2, 0, 0, 0])),
        'Transfer',
      );
    });

    test('a sparse published table supplements, never renames, the core '
        'names', () async {
      adapter.route = () => _body(
        _list([
          {
            'address': _system,
            'name': 'System Program',
            'instructions': [
              {'discriminator': '02000000', 'name': 'PublishedTransfer'},
              // Longer than the built-in tag, so it would win the match.
              {'discriminator': '0200000001', 'name': 'Refund'},
              {'discriminator': '0d000000', 'name': 'PublishedNew'},
            ],
          },
        ]),
        200,
      );
      for (final service in [await launch(), await launch()]) {
        expect(
          service.instructions.nameOf(
            _system,
            Uint8List.fromList([2, 0, 0, 0]),
          ),
          'Transfer',
        );
        expect(
          service.instructions.nameOf(
            _system,
            Uint8List.fromList([2, 0, 0, 0, 1]),
          ),
          'Transfer',
        );
        expect(
          service.instructions.nameOf(
            _system,
            Uint8List.fromList([13, 0, 0, 0]),
          ),
          'PublishedNew',
        );
        expect(
          service.instructions.nameOf(
            _system,
            Uint8List.fromList([0, 0, 0, 0]),
          ),
          'CreateAccount',
        );
      }
      expect(adapter.calls, 1);
    });

    test(
      'are published per program, cached, and read back at launch',
      () async {
        adapter.route = () => _body(
          _list([
            {
              'address': _system,
              'name': 'System Program',
              'instructions': [
                {'discriminator': '02000000', 'name': 'Transfer'},
              ],
            },
          ]),
          200,
        );
        final service = await launch();
        final transfer = Uint8List.fromList([
          2,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
        ]);
        expect(service.instructions.nameOf(_system, transfer), 'Transfer');

        // The next launch, inside the TTL, names it from the cache alone.
        final next = await launch();
        expect(adapter.calls, 1);
        expect(next.instructions.nameOf(_system, transfer), 'Transfer');
      },
    );

    test(
      'a cache from before instructions were published is refetched',
      () async {
        await prefs.setProgramLabelCache(
          jsonEncode({
            'fetchedAt': clock.millisecondsSinceEpoch,
            'programs': {_system: 'System Program'},
          }),
        );
        adapter.route = () => _body(
          _list([
            {
              'address': _system,
              'name': 'System Program',
              'instructions': [
                {'discriminator': '02000000', 'name': 'Transfer'},
              ],
            },
          ]),
          200,
        );
        final service = await launch();
        expect(adapter.calls, 1);
        expect(
          service.instructions.nameOf(
            _system,
            Uint8List.fromList([2, 0, 0, 0]),
          ),
          'Transfer',
        );
      },
    );

    test('the longest discriminator the data starts with wins', () {
      final tables = ProgramInstructions({
        _jupiter: {
          '': 'Fallback',
          '2c': 'Delegate',
          '2c05': 'DelegateStakingV1',
          '0102030405060708': 'Anchor',
        },
      });
      String? name(List<int> data) =>
          tables.nameOf(_jupiter, Uint8List.fromList(data));
      expect(name([0x2c, 5, 0]), 'DelegateStakingV1');
      expect(name([0x2c, 9]), 'Delegate');
      expect(name([0x2c]), 'Delegate');
      expect(name([1, 2, 3, 4, 5, 6, 7, 8, 9]), 'Anchor');
      // Too short for the eight-byte key, so the catch-all names it.
      expect(name([1, 2, 3]), 'Fallback');
      expect(name([]), 'Fallback');
      expect(tables.nameOf(_system, Uint8List(4)), isNull);
    });

    test('parseInstructions drops entries it cannot trust, one by one', () {
      final tables = ProgramLabelService.parseInstructions(
        _list([
          {
            'address': _system,
            'name': 'System Program',
            'instructions': [
              {'discriminator': '02000000', 'name': 'Transfer'},
              // Upper-case hex, odd length, and longer than 16 bytes.
              {'discriminator': '0A', 'name': 'Upper'},
              {'discriminator': 'abc', 'name': 'Odd'},
              {'discriminator': '00' * 17, 'name': 'Long'},
              // Not a bare identifier.
              {'discriminator': '03', 'name': 'Two Words'},
              {'discriminator': '04', 'name': 'Tr\u0430nsfer'},
              {'discriminator': '05', 'name': 42},
              'not an entry',
              // The first entry for a discriminator wins.
              {'discriminator': '02000000', 'name': 'Other'},
            ],
          },
          {'address': 'short', 'instructions': const <Object?>[]},
          {'address': _jupiter, 'name': 'Jupiter', 'instructions': 'x'},
        ]),
      );
      expect(tables.tables, {
        _system: {'02000000': 'Transfer'},
      });
      expect(ProgramLabelService.parseInstructions(null).tables, isEmpty);
      expect(
        ProgramLabelService.parseInstructions({
          'version': 2,
          'programs': const <Object?>[],
        }).tables,
        isEmpty,
      );
    });
  });

  group('parse', () {
    test('accepts a version-1 list, as a map or as a JSON string', () {
      final payload = _list([
        {'address': _system, 'name': 'System Program'},
      ]);
      expect(ProgramLabelService.parse(payload), {_system: 'System Program'});
      expect(ProgramLabelService.parse(jsonEncode(payload)), {
        _system: 'System Program',
      });
    });

    test('rejects anything that is not a version-1 list', () {
      expect(ProgramLabelService.parse(null), null);
      expect(ProgramLabelService.parse('<html>'), null);
      expect(ProgramLabelService.parse(const <dynamic>[]), null);
      expect(ProgramLabelService.parse({'programs': const <Object?>[]}), null);
      expect(
        ProgramLabelService.parse({
          'version': 2,
          'programs': const <Object?>[],
        }),
        null,
      );
      expect(ProgramLabelService.parse({'version': 1, 'programs': 'x'}), null);
    });

    test('drops entries it cannot trust, one by one', () {
      final parsed = ProgramLabelService.parse(
        _list([
          {'address': _system, 'name': '  System   Program  '},
          // Not base58 (0, O, I and l are outside the alphabet).
          {'address': '0OIl111111111111111111111111111111', 'name': 'Bad'},
          {'address': 'short', 'name': 'Short'},
          {'address': _jupiter, 'name': ''},
          {'address': _jupiter, 'name': 42},
          // Cyrillic "а" passing for Latin "a".
          {'address': _jupiter, 'name': 'Jupit\u0435r'},
          // A right-to-left override that reorders what follows it.
          {'address': _jupiter, 'name': 'Jupiter\u202E6v'},
          {'address': _jupiter, 'name': 'J' * 41},
          'not an entry',
          {'address': _jupiter, 'name': 'Jupiter Aggregator v6'},
          // The first entry for an address wins.
          {'address': _jupiter, 'name': 'Something Else'},
        ]),
      );
      expect(parsed, {
        _system: 'System Program',
        _jupiter: 'Jupiter Aggregator v6',
      });
    });

    test('refuses a canonical program name for any other address', () {
      final parsed = ProgramLabelService.parse(
        _list([
          {'address': _jupiter, 'name': 'System Program'},
          // Case, spacing and punctuation do not make it a different name.
          {'address': _jupiter, 'name': 'system-program'},
          {'address': _jupiter, 'name': 'Token  Program'},
          {'address': _jupiter, 'name': 'Token 2022'},
          {'address': _system, 'name': 'System Program'},
        ]),
      );
      expect(parsed, {_system: 'System Program'});
      // The next entry for the address is still read.
      expect(
        ProgramLabelService.parse(
          _list([
            {'address': _jupiter, 'name': 'Token Program'},
            {'address': _jupiter, 'name': 'Swap Router'},
          ]),
        ),
        {_jupiter: 'Swap Router'},
      );
    });

    test('a canonical program keeps its built-in name over the list', () async {
      adapter.route = () => _body(
        _list([
          {'address': _system, 'name': 'Free Airdrop'},
          {'address': _jupiter, 'name': 'Jupiter'},
        ]),
        200,
      );
      final service = await launch();
      expect(service.nameOf(_system), 'System Program');
      expect(service.nameOf(_jupiter), 'Jupiter Aggregator v6');
    });

    test('names every Memo program with no list, v4 included', () async {
      Config.debugOverrides['PROGRAM_LABELS_URL'] = '';
      final service = await launch();
      expect(
        service.nameOf('Memo4c2pN8afCj432Lb7RMVKi9PbQnnW7ewFFaV3oAH'),
        'Memo Program v4',
      );
      expect(
        service.nameOf('MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr'),
        'Memo Program',
      );
      expect(
        service.nameOf('Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo'),
        'Memo Program v1',
      );
    });

    test('a cached entry that borrows a canonical name is dropped', () async {
      const other = 'Other11111111111111111111111111111111111111';
      await prefs.setProgramLabelCache(
        jsonEncode({
          'fetchedAt': clock.millisecondsSinceEpoch,
          'programs': {other: 'System Program'},
          'instructions': <String, Object?>{},
        }),
      );
      final service = await launch();
      expect(adapter.calls, 0);
      expect(service.nameOf(other), isNull);
    });

    test('admits the punctuation real program names use', () {
      for (final name in [
        'Token-2022',
        'Pump.fun AMM',
        'Wormhole (Core)',
        'mallow Gumball',
        'Tensor cNFT Marketplace',
      ]) {
        expect(
          ProgramLabelService.parse(
            _list([
              {'address': _config, 'name': name},
            ]),
          ),
          // Token-2022 is a compiled-in name, so only its own address may
          // carry it.
          name == 'Token-2022' ? isEmpty : {_config: name},
          reason: name,
        );
      }
    });
  });
}
