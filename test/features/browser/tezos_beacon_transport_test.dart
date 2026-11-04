import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart' as nacl;
import 'package:solana/base58.dart' as base58;
import 'package:mallow_wallet/core/crypto/tezos_forge.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/tezos_beacon_transport.dart';

// Independent fixtures generated with Beacon SDK 4.8.0, not the Dart codec.
// All transport seeds in this fixture are deterministic test values.
void main() {
  final fixture =
      jsonDecode(
            File(
              'test/features/browser/fixtures/tezos_beacon_v2.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  late TezosBeaconTransport transport;
  late String stored;
  late int calls;
  setUp(() {
    stored = jsonEncode({
      'seed': fixture['walletSeed'],
      'peers': <String, Object>{},
    });
    calls = 0;
    transport = TezosBeaconTransport(
      read: () async => stored,
      write: (s) async {
        stored = s;
      },
    );
  });
  Future<Map<String, Object?>> handle(
    Map<String, Object?> params, {
    String origin = 'https://site.example',
  }) => transport.handle(
    params: params,
    origin: origin,
    ensureActive: () {},
    execute: (message) async {
      calls++;
      expect(message, fixture['request']);
      return {
        'type': 'permission_response',
        'publicKey': 'edpk-test',
        'scopes': ['sign'],
      };
    },
  );
  test(
    'Given SDK JSON from the picker shim, the peer decrypts the same pairing reply',
    () async {
      final encoded = base58.base58decode(fixture['pairingV3'] as String);
      final raw = utf8.decode(encoded.sublist(0, encoded.length - 4));
      final response = await handle({'pairingJson': raw});
      final plain = nacl.SealedBox(
        nacl.PrivateKey(hexToBytes(fixture['peerCurveSecretKey'] as String)),
      ).decrypt(hexToBytes((response['message'] as Map)['payload'] as String));
      final pairing = jsonDecode(utf8.decode(plain)) as Map;
      expect(pairing['id'], 'sdk-pairing');
      expect(pairing['type'], 'postmessage-pairing-response');
      expect(pairing['version'], '2');
      expect(calls, 0);
      await handle({'encryptedPayload': fixture['encryptedRequest']});
      expect(calls, 1);
    },
  );
  test('Given invalid picker JSON, no peer is paired', () async {
    for (final raw in [
      null,
      42,
      'x' * 4097,
      jsonEncode({'type': 'permission_request'}),
    ]) {
      await expectLater(
        handle({'pairingJson': raw}),
        throwsA(isA<DappException>()),
      );
      expect((jsonDecode(stored) as Map)['peers'], isEmpty);
    }
    expect(calls, 0);
  });

  test(
    'Given SDK pairing, its peer can decrypt the sealed pairing response',
    () async {
      final response = await handle({'payload': fixture['pairing']});
      final message = response['message'] as Map;
      final plain = nacl.SealedBox(
        nacl.PrivateKey(hexToBytes(fixture['peerCurveSecretKey'] as String)),
      ).decrypt(hexToBytes(message['payload'] as String));
      final pairing = jsonDecode(utf8.decode(plain)) as Map;
      expect(pairing['id'], 'sdk-pairing');
      expect(pairing['type'], 'postmessage-pairing-response');
      expect(pairing['version'], '2');
      expect(pairing['publicKey'], hasLength(64));
      expect(calls, 0);
    },
  );
  test(
    'Given SDK v3 pairing, the wallet advertises v2 and handles Tezos requests',
    () async {
      final response = await handle({'payload': fixture['pairingV3']});
      final message = response['message'] as Map;
      final plain = nacl.SealedBox(
        nacl.PrivateKey(hexToBytes(fixture['peerCurveSecretKey'] as String)),
      ).decrypt(hexToBytes(message['payload'] as String));
      final pairing = jsonDecode(utf8.decode(plain)) as Map;
      expect(pairing['id'], 'sdk-pairing');
      expect(pairing['type'], 'postmessage-pairing-response');
      expect(pairing['version'], '2');
      expect(pairing['publicKey'], hasLength(64));
      expect(calls, 0);

      final reply = await handle({
        'encryptedPayload': fixture['encryptedRequest'],
      });
      expect((reply['message'] as Map)['encryptedPayload'], isA<String>());
      expect(calls, 1);
    },
  );
  test(
    'Given SDK encrypted request, it executes and the SDK reply key decrypts the response',
    () async {
      await handle({'payload': fixture['pairing']});
      final response = await handle({
        'encryptedPayload': fixture['encryptedRequest'],
      });
      final cipher = hexToBytes(
        (response['message'] as Map)['encryptedPayload'] as String,
      );
      final encoded = utf8.decode(
        nacl.SecretBox(
          hexToBytes(fixture['replyKey'] as String),
        ).decrypt(nacl.EncryptedMessage.fromList(cipher)),
      );
      final body = base58.base58decode(encoded);
      final reply =
          jsonDecode(utf8.decode(body.sublist(0, body.length - 4))) as Map;
      expect(reply['id'], 'sdk-request');
      expect(reply['version'], '2');
      expect(reply['type'], 'permission_response');
      expect(reply['senderId'], isNotEmpty);
      expect(calls, 1);
    },
  );
  test(
    'Given a different native origin, another origin cannot reuse pairing',
    () async {
      await handle({'payload': fixture['pairing']});
      await expectLater(
        handle({
          'encryptedPayload': fixture['encryptedRequest'],
        }, origin: 'https://other.example'),
        throwsA(isA<DappException>()),
      );
      expect(calls, 0);
    },
  );
  test(
    'Given a recreated transport, saved peers reconnect without exposing its seed',
    () async {
      await handle({'payload': fixture['pairing']});
      transport = TezosBeaconTransport(
        read: () async => stored,
        write: (s) async {
          stored = s;
        },
      );
      final reply = await handle({
        'encryptedPayload': fixture['encryptedRequest'],
      });
      expect((reply['message'] as Map)['encryptedPayload'], isA<String>());
      expect(calls, 1);
    },
  );
  // A valid Ed25519 point for each index; only the pairing codec reads it.
  String peerKey(int i) =>
      List.filled(32, (i + 2).toRadixString(16).padLeft(2, '0')).join();
  Future<void> pair(int i, String origin) => handle({
    'pairingJson': jsonEncode({
      'type': 'postmessage-pairing-request',
      'version': '2',
      'id': 'pairing-$i',
      'publicKey': peerKey(i),
    }),
  }, origin: origin);
  Map<String, dynamic> storedPeers() =>
      ((jsonDecode(stored) as Map)['peers'] as Map).cast<String, dynamic>();

  test(
    'Given a full origin, a new pairing evicts that origin\'s oldest peer',
    () async {
      for (var i = 0; i < 9; i++) {
        await pair(i, 'https://site.example');
      }
      expect(storedPeers()['https://site.example'], [
        for (var i = 1; i < 9; i++) peerKey(i),
      ]);
    },
  );
  test(
    'Given 64 paired origins, a new origin evicts the least recently used one',
    () async {
      await handle({'payload': fixture['pairing']});
      for (var i = 0; i < 63; i++) {
        await pair(i, 'https://s$i.example');
      }
      // Using the first site's pairing makes it the most recently used.
      await handle({'encryptedPayload': fixture['encryptedRequest']});
      await pair(99, 'https://new.example');
      final origins = storedPeers().keys.toList();
      expect(origins, hasLength(64));
      expect(origins, isNot(contains('https://s0.example')));
      expect(origins, contains('https://site.example'));
      expect(origins.last, 'https://new.example');
      // Evicted origins pair again; the kept one still decrypts.
      await pair(0, 'https://s0.example');
      await handle({'encryptedPayload': fixture['encryptedRequest']});
      expect(calls, 2);
    },
  );
  test(
    'Given a request during a clear, its recency save cannot restore the cleared state',
    () async {
      final deleting = Completer<void>();
      var writesAfterDelete = 0;
      var deleteStarted = false;
      transport = TezosBeaconTransport(
        read: () async => stored,
        write: (s) async {
          if (deleteStarted) writesAfterDelete++;
          stored = s;
        },
        delete: () async {
          deleteStarted = true;
          await deleting.future;
          stored = jsonEncode({
            'seed': fixture['walletSeed'],
            'peers': <String, Object>{},
          });
        },
      );
      await handle({'payload': fixture['pairing']});
      await pair(1, 'https://site.example');
      final clearing = transport.clear();
      await pumpEventQueue();
      expect(deleteStarted, true);
      // Using the older peer reorders the store and queues a save.
      await handle({'encryptedPayload': fixture['encryptedRequest']});
      deleting.complete();
      await clearing;
      await pumpEventQueue();
      expect(writesAfterDelete, 0);
      expect(storedPeers(), isEmpty);
    },
  );
  test('Given tampered ciphertext, no request executes', () async {
    await handle({'payload': fixture['pairing']});
    final encrypted = fixture['encryptedRequest'] as String;
    await expectLater(
      handle({
        'encryptedPayload': '${encrypted.substring(0, encrypted.length - 2)}ff',
      }),
      throwsA(isA<DappException>()),
    );
    expect(calls, 0);
  });
  test(
    'Given corrupted state, clearing still deletes the transport identity',
    () async {
      var deleted = false;
      transport = TezosBeaconTransport(
        read: () async => 'invalid',
        write: (_) async {},
        delete: () async {
          deleted = true;
        },
      );
      await expectLater(
        handle({'payload': fixture['pairing']}),
        throwsFormatException,
      );
      await transport.clear();
      expect(deleted, true);
    },
  );
}
