import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/push_notification_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mocktail/mocktail.dart';

class _MockPrefs extends Mock implements PreferencesService {}

class _MockWallets extends Mock implements WalletRepository {}

class _MockAuth extends Mock implements AuthService {}

/// Captures every `/v1/deviceToken/sync` body, so the test can assert what the
/// device claimed rather than how it got there.
class _CapturingAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> syncs = [];
  final List<String?> cookies = [];
  int status = 200;
  String result = '{"success":true,"unproven":[]}';

  /// What the post after the first answers, when it differs.
  String? resultAfterFirst;
  int? statusAfterFirst;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/v1/deviceToken/sync')) {
      syncs.add(Map<String, dynamic>.from(options.data as Map));
      cookies.add(options.headers['Cookie'] as String?);
    }
    final later = syncs.length > 1;
    return ResponseBody.fromString(
      '{"result":${later ? resultAfterFirst ?? result : result}}',
      later ? statusAfterFirst ?? status : status,
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

    test('syncs again while an address is unproven', () async {
      // Its pushes say nothing until a sync carries its proof, so an unchanged
      // wallet set is not done with yet.
      final service = build();
      when(wallets.getAllWallets).thenAnswer((_) async => [_wallet('AAA')]);

      adapter.result = '{"success":true,"unproven":["AAA"]}';
      await service.debugSyncWithToken('tok-1');
      adapter.result = '{"success":true,"unproven":[]}';
      await service.debugSyncWithToken('tok-1');
      await service.debugSyncWithToken('tok-1');

      expect(adapter.syncs, hasLength(2));
    });

    test('treats a response with no unproven list as done', () async {
      final service = build();
      when(wallets.getAllWallets).thenAnswer((_) async => [_wallet('AAA')]);

      adapter.result = '{"success":true}';
      await service.debugSyncWithToken('tok-1');
      await service.debugSyncWithToken('tok-1');

      expect(adapter.syncs, hasLength(1));
    });

    group('wallet proofs', () {
      late _MockAuth auth;

      setUp(() {
        auth = _MockAuth();
        sl.registerSingleton<AuthService>(auth);
        when(
          () => auth.discardWalletProof(any(), any()),
        ).thenAnswer((_) async {});
        when(
          () => auth.storedWalletProofCookie(any()),
        ).thenAnswer((_) async => null);
        when(
          () => auth.signWalletProofCookie(any()),
        ).thenAnswer((inv) async => 'signed-${inv.positionalArguments.first}');
      });

      tearDown(() => sl.unregister<AuthService>());

      void serverSaysUnproven(List<String> addresses) {
        adapter.result = jsonEncode({'success': true, 'unproven': addresses});
      }

      test(
        'reads and signs nothing when the backend holds every proof',
        () async {
          when(wallets.getAllWallets).thenAnswer((_) async => [_wallet('AAA')]);

          await build().debugSyncWithToken('tok-1');

          verifyNever(() => auth.storedWalletProofCookie(any()));
          verifyNever(() => auth.signWalletProofCookie(any()));
          expect(adapter.syncs, hasLength(1));
        },
      );

      test(
        'sends a proof only on the request after the backend asks',
        () async {
          when(wallets.getAllWallets).thenAnswer((_) async => [_wallet('AAA')]);
          when(
            () => auth.storedWalletProofCookie('AAA'),
          ).thenAnswer((_) async => 'stored-AAA');
          serverSaysUnproven(['AAA']);

          await build().debugSyncWithToken('tok-1');

          expect(adapter.cookies, [null, 'stored-AAA']);
          verifyNever(() => auth.signWalletProofCookie(any()));
        },
      );

      test('caps the proofs on one request, however many wallets', () async {
        // Each is about 300 bytes, and servers refuse a header that grows too
        // large. The whole list on one request would fail it, every time.
        final all = [for (var i = 10; i < 40; i++) 'W$i'];
        when(
          wallets.getAllWallets,
        ).thenAnswer((_) async => [for (final a in all) _wallet(a)]);
        when(
          () => auth.storedWalletProofCookie(any()),
        ).thenAnswer((inv) async => 'stored-${inv.positionalArguments.first}');
        serverSaysUnproven(all);

        await build().debugSyncWithToken('tok-1');

        expect(adapter.cookies.last!.split('; '), hasLength(8));
      });

      test('finishes a capped set over later syncs', () async {
        final service = build();
        when(
          wallets.getAllWallets,
        ).thenAnswer((_) async => [_wallet('AAA'), _wallet('BBB')]);
        when(
          () => auth.storedWalletProofCookie(any()),
        ).thenAnswer((inv) async => 'stored-${inv.positionalArguments.first}');
        serverSaysUnproven(['BBB']);

        await service.debugSyncWithToken('tok-1');
        expect(adapter.cookies.last, 'stored-BBB');

        serverSaysUnproven([]);
        await service.debugSyncWithToken('tok-1');
        final posts = adapter.syncs.length;
        await service.debugSyncWithToken('tok-1');

        expect(adapter.syncs, hasLength(posts));
      });

      test('discards a stored proof the backend refused', () async {
        // Its local expiry says nothing about a proof from before the format
        // changed. Left stored it would be resent until it expired.
        when(wallets.getAllWallets).thenAnswer(
          (_) async => [_wallet('AAA'), _wallet('BBB'), _wallet('CCC')],
        );
        when(() => auth.storedWalletProofCookie(any())).thenAnswer((inv) async {
          final address = inv.positionalArguments.first;
          return address == 'CCC' ? null : 'stored-$address';
        });
        when(
          () => auth.signWalletProofCookie('CCC'),
        ).thenAnswer((_) async => null);
        serverSaysUnproven(['AAA', 'BBB', 'CCC']);
        adapter.resultAfterFirst = jsonEncode({
          'success': true,
          'unproven': ['AAA', 'CCC'],
        });

        await build().debugSyncWithToken('tok-1');

        verify(() => auth.discardWalletProof('AAA', 'stored-AAA')).called(1);
        // BBB was accepted, and CCC was never sent a proof.
        verifyNever(() => auth.discardWalletProof('BBB', any()));
        verifyNever(() => auth.discardWalletProof('CCC', any()));
      });

      test('keeps the proofs when the post carrying them failed', () async {
        when(wallets.getAllWallets).thenAnswer((_) async => [_wallet('AAA')]);
        when(
          () => auth.storedWalletProofCookie(any()),
        ).thenAnswer((_) async => 'stored-AAA');
        serverSaysUnproven(['AAA']);
        adapter.statusAfterFirst = 500;

        await build().debugSyncWithToken('tok-1');

        verifyNever(() => auth.discardWalletProof(any(), any()));
      });

      test('still syncs the wallet set when a proof lookup throws', () async {
        // A removed wallet must stop receiving push whatever else is true.
        when(wallets.getAllWallets).thenAnswer((_) async => [_wallet('AAA')]);
        when(
          () => auth.storedWalletProofCookie(any()),
        ).thenThrow(StateError('secure storage'));
        serverSaysUnproven(['AAA']);

        await build().debugSyncWithToken('tok-1');

        expect(adapter.syncs.single['addresses'], ['AAA']);
      });

      test(
        'posts nothing after the proofs when push went off meanwhile',
        () async {
          when(wallets.getAllWallets).thenAnswer((_) async => [_wallet('AAA')]);
          when(() => auth.signWalletProofCookie('AAA')).thenAnswer((_) async {
            when(() => prefs.pushNotificationsEnabled).thenReturn(false);
            return 'signed-AAA';
          });
          serverSaysUnproven(['AAA']);

          await build().debugSyncWithToken('tok-1');

          expect(adapter.syncs, hasLength(1));
        },
      );

      test('posts the wallet set as it is after the proofs', () async {
        when(
          wallets.getAllWallets,
        ).thenAnswer((_) async => [_wallet('AAA'), _wallet('BBB')]);
        when(() => auth.signWalletProofCookie('AAA')).thenAnswer((_) async {
          when(wallets.getAllWallets).thenAnswer((_) async => [_wallet('AAA')]);
          return 'signed-AAA';
        });
        serverSaysUnproven(['AAA']);

        await build().debugSyncWithToken('tok-1');

        expect(adapter.syncs.last['addresses'], ['AAA']);
      });

      test('uses a hardware wallet\'s proof on disk but never signs', () async {
        // Its proof needs an approval on the device, and a sync has no user
        // action behind it to ask for one.
        when(wallets.getAllWallets).thenAnswer(
          (_) async => [
            _wallet('LEDGER_A', type: WalletType.ledger),
            _wallet('LEDGER_B', type: WalletType.ledger),
          ],
        );
        when(
          () => auth.storedWalletProofCookie('LEDGER_A'),
        ).thenAnswer((_) async => 'stored-LEDGER_A');
        serverSaysUnproven(['LEDGER_A', 'LEDGER_B']);

        await build().debugSyncWithToken('tok-1');

        verifyNever(() => auth.signWalletProofCookie(any()));
        expect(adapter.cookies.last, 'stored-LEDGER_A');
      });

      test(
        'signs for a few wallets per sync, to stay under the rate limit',
        () async {
          final all = [for (var i = 0; i < 9; i++) 'W$i'];
          when(
            wallets.getAllWallets,
          ).thenAnswer((_) async => [for (final a in all) _wallet(a)]);
          serverSaysUnproven(all);

          await build().debugSyncWithToken('tok-1');

          verify(() => auth.signWalletProofCookie(any())).called(4);
        },
      );

      test('does not spend the budget on wallets that yield no proof', () async {
        // A social row whose key needs a re-login answers null without a request.
        final all = [for (var i = 0; i < 9; i++) 'W$i'];
        when(
          wallets.getAllWallets,
        ).thenAnswer((_) async => [for (final a in all) _wallet(a)]);
        for (final a in all.take(4)) {
          when(
            () => auth.signWalletProofCookie(a),
          ).thenAnswer((_) async => null);
        }
        serverSaysUnproven(all);

        await build().debugSyncWithToken('tok-1');

        expect(adapter.cookies.last, startsWith('signed-W4'));
      });

      test('stops signing after repeated failures', () async {
        final all = [for (var i = 0; i < 9; i++) 'W$i'];
        when(
          wallets.getAllWallets,
        ).thenAnswer((_) async => [for (final a in all) _wallet(a)]);
        when(
          () => auth.signWalletProofCookie(any()),
        ).thenThrow(StateError('rate limited'));
        serverSaysUnproven(all);

        await build().debugSyncWithToken('tok-1');

        verify(() => auth.signWalletProofCookie(any())).called(4);
      });
    });

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
