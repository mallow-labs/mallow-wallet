import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/push_notification_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockPrefs extends Mock implements PreferencesService {}

class _MockWallets extends Mock implements WalletRepository {}

/// Captures every `/v1/deviceToken/sync` body, so the test can assert what the
/// device claimed rather than how it got there.
class _CapturingAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> syncs = [];
  int status = 200;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/v1/deviceToken/sync')) {
      syncs.add(Map<String, dynamic>.from(options.data as Map));
    }
    return ResponseBody.fromString(
      '{"result":{"success":true}}',
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

WalletInfo _wallet(String address, {WalletType type = WalletType.hd}) =>
    WalletInfo(
      id: 'id-$address',
      address: address,
      name: address,
      walletType: type,
      chain: 'solana',
    );

void main() {
  late _MockPrefs prefs;
  late _MockWallets wallets;
  late _CapturingAdapter adapter;
  late Dio dio;

  setUp(() {
    Config.debugOverrides['API_BASE_URL'] = 'https://api.test';
    prefs = _MockPrefs();
    wallets = _MockWallets();
    adapter = _CapturingAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    when(() => prefs.pushNotificationsEnabled).thenReturn(true);
    when(() => wallets.walletsRevision).thenReturn(ValueNotifier(0));
  });

  tearDown(Config.debugOverrides.clear);

  PushNotificationService build() =>
      PushNotificationService(dio, wallets, prefs);

  // WHY: the whole contract is "this token maps to the wallets on this device".
  // Every test below is one clause of that sentence.
  group('syncAddresses', () {
    test('sends every wallet the device can sign for', () async {
      when(
        wallets.getAllWallets,
      ).thenAnswer((_) async => [_wallet('AAA'), _wallet('BBB')]);

      await build().debugSyncWithToken('tok-1');

      expect(adapter.syncs.single['token'], 'tok-1');
      expect(adapter.syncs.single['addresses'], ['AAA', 'BBB']);
    });

    test('excludes view-only wallets', () async {
      // A view-only wallet is an address the user is watching, not holding.
      // Registering it would deliver its owner's sales and offers to a stranger.
      when(wallets.getAllWallets).thenAnswer(
        (_) async => [
          _wallet('MINE'),
          _wallet('WATCHED', type: WalletType.viewOnly),
        ],
      );

      await build().debugSyncWithToken('tok-1');

      expect(adapter.syncs.single['addresses'], ['MINE']);
    });

    test('sends an empty set when the device holds no wallets', () async {
      // A wipe deletes every wallet; the resulting sync is what tells the
      // backend to stop pushing to this handset.
      when(wallets.getAllWallets).thenAnswer((_) async => []);

      await build().debugSyncWithToken('tok-1');

      expect(adapter.syncs.single['addresses'], isEmpty);
    });

    test('re-sends the full set after a wallet is removed', () async {
      // Full replace is the mechanism: the device re-states what it still has
      // and the server drops the rest. No delete call exists.
      final service = build();
      when(
        wallets.getAllWallets,
      ).thenAnswer((_) async => [_wallet('AAA'), _wallet('BBB')]);
      await service.debugSyncWithToken('tok-1');

      when(wallets.getAllWallets).thenAnswer((_) async => [_wallet('AAA')]);
      await service.debugSyncWithToken('tok-1');

      expect(adapter.syncs.map((s) => s['addresses']), [
        ['AAA', 'BBB'],
        ['AAA'],
      ]);
    });

    test('does not re-post when nothing changed', () async {
      // Wallet renames and reorders bump the same revision counter, so an
      // unconditional POST would put the app on the network for every edit.
      final service = build();
      when(wallets.getAllWallets).thenAnswer((_) async => [_wallet('AAA')]);

      await service.debugSyncWithToken('tok-1');
      await service.debugSyncWithToken('tok-1');

      expect(adapter.syncs, hasLength(1));
    });

    test(
      'retries after a failed sync instead of treating it as done',
      () async {
        // The fingerprint is recorded on success only; a device that lost one
        // call must not stay wrong until its wallets change again.
        final service = build();
        when(wallets.getAllWallets).thenAnswer((_) async => [_wallet('AAA')]);

        adapter.status = 500;
        await service.debugSyncWithToken('tok-1');
        adapter.status = 200;
        await service.debugSyncWithToken('tok-1');

        expect(adapter.syncs, hasLength(2));
      },
    );

    test('sends nothing while push is switched off', () async {
      when(() => prefs.pushNotificationsEnabled).thenReturn(false);
      when(wallets.getAllWallets).thenAnswer((_) async => [_wallet('AAA')]);

      await build().syncAddresses();

      expect(adapter.syncs, isEmpty);
    });

    test('orders addresses so the fingerprint is stable', () async {
      // Wallet order is a user-visible sort that changes on reorder; without a
      // canonical order the same set would look like a change every time.
      when(
        wallets.getAllWallets,
      ).thenAnswer((_) async => [_wallet('ZZZ'), _wallet('AAA')]);

      await build().debugSyncWithToken('tok-1');

      expect(adapter.syncs.single['addresses'], ['AAA', 'ZZZ']);
    });
  });
}
