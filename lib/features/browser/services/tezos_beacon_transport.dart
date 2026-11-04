import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:pinenacl/x25519.dart' as nacl;
import 'package:pointycastle/digests/blake2b.dart';
import 'package:solana/base58.dart' as base58;

import '../../../core/crypto/tezos_forge.dart';
import '../../../core/security/secure_storage.dart';
import '../../../di.dart';
import '../models/dapp_request.dart';

const mallowBeaconId = 'art.mallow.wallet';

// Bounds on the persisted peer store. A full store evicts its least-recently
// used entry instead of refusing, so no page can lock Beacon out for good.
const _maxBeaconOrigins = 64;
const _maxBeaconPeersPerOrigin = 8;

/// Beacon v2 postMessage transport. Transport keys are independent of wallet
/// keys and live only in the OS secure store. Peers are bound to the native
/// origin; pairing never grants permission to connect or sign.
class TezosBeaconTransport {
  TezosBeaconTransport({
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
    Future<void> Function()? delete,
  }) {
    _read = read ?? () => sl<SecureWalletStorage>().loadBrowserBeaconState();
    _write =
        write ??
        (value) => sl<SecureWalletStorage>().storeBrowserBeaconState(value);
    _delete =
        delete ?? () => sl<SecureWalletStorage>().deleteBrowserBeaconState();
  }
  static final instance = TezosBeaconTransport();

  late final Future<String?> Function() _read;
  late final Future<void> Function(String) _write;
  late final Future<void> Function() _delete;
  Future<void>? _loaded;
  bool _ready = false;
  Future<void> _tail = Future.value();
  late Uint8List _seed;
  late Uint8List _publicKey;
  late nacl.PrivateKey _privateKey;

  /// Peer keys by native origin. Both the origins and each origin's peers are
  /// kept least- to most-recently used, and that order is persisted. A peer is
  /// only ever tried for the origin it paired from.
  final _peers = <String, List<String>>{};

  /// Bumped by [clear], so a save queued before it never restores old state.
  int _generation = 0;

  Future<void> clear() async {
    _generation++;
    try {
      if (_loaded != null) await _loaded;
    } catch (_) {
      // Clearing must also recover from unreadable or malformed old state.
    }
    // The delete joins the save queue, so a save queued while it runs comes
    // after it and finds nothing loaded to write.
    final cleared = _tail.then((_) async {
      await _delete();
      _peers.clear();
      if (_ready) _seed.fillRange(0, _seed.length, 0);
      _ready = false;
      _loaded = null;
    });
    _tail = cleared.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await cleared;
  }

  Future<void> _load() async {
    final stored = await _read();
    if (stored != null) {
      final data = jsonDecode(stored) as Map;
      _seed = base64Decode(data['seed'] as String);
      final peers = data['peers'] as Map;
      for (final entry in peers.entries) {
        _peers[entry.key as String] = (entry.value as List).cast<String>();
      }
    } else {
      final random = Random.secure();
      _seed = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
    }
    final pair = await Ed25519().newKeyPairFromSeed(_seed);
    _publicKey = Uint8List.fromList((await pair.extractPublicKey()).bytes);
    final scalar = Uint8List.fromList(
      crypto.sha512.convert(_seed).bytes.sublist(0, 32),
    );
    scalar[0] &= 248;
    scalar[31] = (scalar[31] & 127) | 64;
    _privateKey = nacl.PrivateKey(scalar);
    if (stored == null) await _save();
    _ready = true;
  }

  Future<void> _save() =>
      _write(jsonEncode({'seed': base64Encode(_seed), 'peers': _peers}));

  /// Marks [peer] of [origin] most recently used, evicting the least recently
  /// used peer or origin past the limits. Returns whether anything changed.
  bool _promote(String origin, String peer) {
    final existing = _peers[origin];
    if (existing != null &&
        existing.isNotEmpty &&
        existing.last == peer &&
        _peers.keys.last == origin) {
      return false;
    }
    final peers = _peers.remove(origin) ?? <String>[];
    peers
      ..remove(peer)
      ..add(peer);
    while (peers.length > _maxBeaconPeersPerOrigin) {
      peers.removeAt(0);
    }
    _peers[origin] = peers;
    while (_peers.length > _maxBeaconOrigins) {
      _peers.remove(_peers.keys.first);
    }
    return true;
  }

  /// Queues a save behind earlier ones. A [clear] in between cancels it.
  Future<void> _queueSave() {
    final generation = _generation;
    final saved = _tail.then((_) async {
      if (generation == _generation && _ready) await _save();
    });
    _tail = saved.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return saved;
  }

  Future<Map<String, Object?>> handle({
    required Object? params,
    required String origin,
    required void Function() ensureActive,
    required Future<Map<String, Object?>> Function(Map<String, dynamic>)
    execute,
  }) async {
    await (_loaded ??= _load());
    ensureActive();
    if (params is! Map)
      throw const DappException(-32602, 'Invalid Beacon message');
    var pairing = params['payload'];
    if (pairing == null && params.containsKey('pairingJson')) {
      final raw = params['pairingJson'];
      if (raw is! String || raw.length > 4096) {
        throw const DappException(-32602, 'Invalid Beacon pairing');
      }
      // The in-page picker shim observes the SDK's public JSON before its
      // Base58Check encoding. Rejoin the normal codec and validation below.
      pairing = _checkEncode(utf8.encode(raw));
    }
    if (pairing != null) {
      if (pairing is! String || pairing.length > 4096)
        throw const DappException(-32602, 'Invalid Beacon pairing');
      final message = _deserialize(pairing);
      if (message['type'] != 'postmessage-pairing-request' ||
          (message['version'] != '2' && message['version'] != '3') ||
          message['id'] is! String ||
          (message['id'] as String).length > 128 ||
          message['publicKey'] is! String ||
          !RegExp(
            r'^[0-9a-fA-F]{64}$',
          ).hasMatch(message['publicKey'] as String)) {
        throw const DappException(-32602, 'Invalid Beacon pairing');
      }
      final peer = (message['publicKey'] as String).toLowerCase();
      final curveKey = _curvePublicKey(hexToBytes(peer));
      final response = nacl.SealedBox(nacl.PublicKey(curveKey)).encrypt(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'id': message['id'],
              'type': 'postmessage-pairing-response',
              'name': 'mallow',
              // Current SDKs pair as v3 but still send v2 Tezos requests.
              // Advertise the request protocol we actually support.
              'version': '2',
              'publicKey': bytesToHex(_publicKey),
            }),
          ),
        ),
      );
      ensureActive();
      if (_promote(origin, peer)) await _queueSave();
      ensureActive();
      return {
        'message': {'target': 'toPage', 'payload': bytesToHex(response)},
      };
    }
    final encrypted = params['encryptedPayload'];
    if (encrypted is! String ||
        encrypted.length > 400000 ||
        !RegExp(r'^(?:[0-9a-fA-F]{2}){40,}$').hasMatch(encrypted)) {
      throw const DappException(-32602, 'Invalid Beacon payload');
    }
    final cipher = hexToBytes(encrypted);
    for (final peer in List<String>.of(_peers[origin] ?? const [])) {
      final receive = await _sessionKey(peer, receiving: true);
      Map<String, dynamic> message;
      try {
        message = _deserialize(
          utf8.decode(
            nacl.SecretBox(
              receive,
            ).decrypt(nacl.EncryptedMessage.fromList(cipher)),
          ),
        );
      } catch (_) {
        continue;
      }
      ensureActive();
      // Best effort: a failed write only loses the recency order.
      if (_promote(origin, peer)) unawaited(_queueSave().catchError((_) {}));
      final id = message['id'];
      if (id is! String || id.isEmpty || id.length > 128) {
        throw const DappException(-32602, 'Invalid Beacon request');
      }
      Map<String, Object?> reply;
      if (message['version'] != '2') {
        reply = {'type': 'error', 'errorType': 'UNKNOWN_ERROR'};
      } else {
        reply = await execute(message);
      }
      // A cancellation response may still reach the original document; it
      // contains no signature. Successful responses are guarded by execute.
      final send = await _sessionKey(peer, receiving: false);
      final senderId = _checkEncode(
        Blake2bDigest(digestSize: 5).process(_publicKey),
      );
      if (reply['appMetadata'] case final Map<String, Object?> metadata) {
        reply = {
          ...reply,
          'appMetadata': {...metadata, 'senderId': senderId},
        };
      }
      final encoded = _serialize({
        ...reply,
        'id': id,
        'version': '2',
        'senderId': senderId,
      });
      final response = nacl.SecretBox(
        send,
      ).encrypt(Uint8List.fromList(utf8.encode(encoded)));
      return {
        'message': {
          'target': 'toPage',
          'encryptedPayload': bytesToHex(response),
        },
      };
    }
    throw const DappException(4100, 'Pair this site with mallow first');
  }

  Future<Uint8List> _sessionKey(String peer, {required bool receiving}) async {
    final other = _curvePublicKey(hexToBytes(peer));
    final self = Uint8List.fromList(_privateKey.publicKey);
    final shared = await X25519().sharedSecretKey(
      keyPair: SimpleKeyPairData(
        Uint8List.fromList(_privateKey),
        publicKey: SimplePublicKey(self, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      ),
      remotePublicKey: SimplePublicKey(other, type: KeyPairType.x25519),
    );
    final raw = await shared.extractBytes();
    if (raw.every((byte) => byte == 0))
      throw const FormatException('Invalid peer');
    // Beacon uses server receive keys inbound, client send keys outbound.
    final hash = Blake2bDigest(digestSize: 64).process(
      Uint8List.fromList([
        ...raw,
        ...(receiving ? other : self),
        ...(receiving ? self : other),
      ]),
    );
    return Uint8List.fromList(hash.sublist(32));
  }
}

Uint8List _curvePublicKey(Uint8List ed25519) {
  final p = (BigInt.one << 255) - BigInt.from(19);
  var y = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    y = (y << 8) | BigInt.from(i == 31 ? ed25519[i] & 127 : ed25519[i]);
  }
  if (y >= p || y == BigInt.one) throw const FormatException('Invalid peer');
  var u = ((BigInt.one + y) * (BigInt.one - y).modInverse(p)) % p;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = (u & BigInt.from(255)).toInt();
    u >>= 8;
  }
  return out;
}

String _checkEncode(List<int> bytes) => base58.base58encode([
  ...bytes,
  ...crypto.sha256.convert(crypto.sha256.convert(bytes).bytes).bytes.take(4),
]);
String _serialize(Map<String, Object?> message) =>
    _checkEncode(utf8.encode(jsonEncode(message)));
Map<String, dynamic> _deserialize(Object? encoded) {
  if (encoded is! String || encoded.length > 300000)
    throw const FormatException();
  final bytes = base58.base58decode(encoded);
  if (bytes.length < 5) throw const FormatException();
  final body = bytes.sublist(0, bytes.length - 4);
  if (_checkEncode(body) != encoded) throw const FormatException();
  return (jsonDecode(utf8.decode(body)) as Map).cast<String, dynamic>();
}
