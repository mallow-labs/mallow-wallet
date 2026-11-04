import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:reown_core/crypto/crypto.dart';
import 'package:reown_core/events/i_events.dart';
import 'package:reown_core/events/models/basic_event.dart';
import 'package:reown_core/reown_core.dart';
import 'package:reown_core/store/generic_store.dart';
import 'package:reown_core/store/i_store.dart';
import 'package:reown_sign/reown_sign.dart'
    show
        AuthPublicKey,
        IReownSign,
        Namespace,
        PendingSessionAuthRequest,
        ProposalData,
        ReownSign,
        ReownSignError,
        ReownSignErrorExtension,
        SessionData,
        SessionDelete,
        SessionExpire,
        SessionProposalEvent,
        SessionRequest,
        SessionRequestEvent,
        Sessions;

/// The part of the WalletConnect SDK the service uses, so the service can be
/// tested without a relay.
abstract class WalletConnectClient {
  Future<void> init();
  Future<void> pair(Uri uri);

  /// Approves proposal [id]; returns the new session's topic.
  Future<String> approve(int id, Map<String, Namespace> namespaces);
  Future<void> reject(int id, ReownSignError reason);
  Future<void> respond(
    String topic,
    int id, {
    Object? result,
    JsonRpcError? error,
  });
  Future<void> disconnect(String topic);

  /// Reconnects the relay socket, which iOS closes in the background.
  Future<void> reconnect();

  /// Whether the relay socket is open.
  bool get relayConnected;

  /// Why the relay last refused or dropped the connection, short enough to
  /// show the user; null once it connects again.
  String? get relayProblem;

  /// Stops the client for good, after a reset: the relay socket, and the
  /// heartbeat and connectivity listener that would otherwise reopen it.
  Future<void> close();

  /// When request [id] expires, in seconds since the epoch, if known. The
  /// SDK enforces it only when the wallet answers, which is too late for a
  /// request kept waiting until after the website gave up.
  int? requestExpiry(int id);
  Map<String, SessionData> sessions();

  /// Requests received and not yet answered, including ones persisted from a
  /// previous run of the app.
  Map<String, SessionRequest> pendingRequests();
  Stream<SessionProposalEvent> get proposals;
  Stream<SessionRequestEvent> get requests;

  /// A session the website or the SDK ended (deleted or expired).
  Stream<String> get endedSessions;
}

/// [WalletConnectClient] on Reown's core and sign SDKs, composed here rather
/// than through Reown's WalletKit, which also links a payments plugin with
/// its own native binaries that this wallet does not use.
///
/// Two of the SDK's defaults are replaced before it starts:
/// - SDK telemetry is dropped. The core otherwise posts usage events to
///   Reown's events server, with no option to turn it off.
/// - The key chain (each pairing's and session's symmetric key, and the
///   client's identity seed) lives in the OS secure store and nowhere else.
///   The SDK's own store falls back to plain shared preferences when the
///   secure store fails; [_SecureKeyStore] fails instead.
///
/// Sessions, pairings and pending requests remain in shared preferences, as
/// the SDK stores them. They name the connected websites and hold no key.
class ReownWalletConnectClient implements WalletConnectClient {
  ReownWalletConnectClient({
    required String projectId,
    required PairingMetadata metadata,
  }) {
    _core = ReownCore(projectId: projectId);
    _core.events = _NoEvents();
    _core.secureStorage = _SecureKeyStore();
    _core.crypto = Crypto(
      core: _core,
      keyChain: GenericStore<String>(
        storage: _core.secureStorage,
        context: StoreVersions.CONTEXT_KEYCHAIN,
        version: StoreVersions.VERSION_KEYCHAIN,
        fromJson: (dynamic value) => value as String,
      ),
    );
    _sign = _createSign(_core, metadata);
  }

  late final ReownCore _core;
  late final IReownSign _sign;
  String? _relayProblem;
  final _proposals = StreamController<SessionProposalEvent>.broadcast();
  final _requests = StreamController<SessionRequestEvent>.broadcast();
  final _ended = StreamController<String>.broadcast();

  static IReownSign _createSign(ReownCore core, PairingMetadata metadata) =>
      ReownSign(
        core: core,
        metadata: metadata,
        proposals: GenericStore(
          storage: core.storage,
          context: StoreVersions.CONTEXT_PROPOSALS,
          version: StoreVersions.VERSION_PROPOSALS,
          fromJson: (dynamic value) =>
              ProposalData.fromJson(value as Map<String, dynamic>),
        ),
        sessions: Sessions(
          storage: core.storage,
          context: StoreVersions.CONTEXT_SESSIONS,
          version: StoreVersions.VERSION_SESSIONS,
          fromJson: (dynamic value) =>
              SessionData.fromJson(value as Map<String, dynamic>),
        ),
        pendingRequests: GenericStore(
          storage: core.storage,
          context: StoreVersions.CONTEXT_PENDING_REQUESTS,
          version: StoreVersions.VERSION_PENDING_REQUESTS,
          fromJson: (dynamic value) =>
              SessionRequest.fromJson(value as Map<String, dynamic>),
        ),
        authKeys: GenericStore(
          storage: core.storage,
          context: StoreVersions.CONTEXT_AUTH_KEYS,
          version: StoreVersions.VERSION_AUTH_KEYS,
          fromJson: (dynamic value) =>
              AuthPublicKey.fromJson(value as Map<String, dynamic>),
        ),
        pairingTopics: GenericStore(
          storage: core.storage,
          context: StoreVersions.CONTEXT_PAIRING_TOPICS,
          version: StoreVersions.VERSION_PAIRING_TOPICS,
          fromJson: (dynamic value) => value as String,
        ),
        sessionAuthRequests: GenericStore(
          storage: core.storage,
          context: StoreVersions.CONTEXT_AUTH_REQUESTS,
          version: StoreVersions.VERSION_AUTH_REQUESTS,
          fromJson: (dynamic value) =>
              PendingSessionAuthRequest.fromJson(value as Map<String, dynamic>),
        ),
      );

  @override
  Future<void> init() async {
    // Before start: the first connection is made inside it.
    _core.relayClient.onRelayClientError.subscribe((ErrorEvent? event) {
      _relayProblem = describeRelayError(event?.error);
    });
    _core.relayClient.onRelayClientConnect.subscribe((_) {
      _relayProblem = null;
    });
    await _core.start();
    await _sign.init();
    _sign.onSessionProposal.subscribe(_proposals.add);
    _sign.onSessionRequest.subscribe(_requests.add);
    _sign.onSessionDelete.subscribe((SessionDelete? event) {
      if (event != null) _ended.add(event.topic);
    });
    _sign.onSessionExpire.subscribe((SessionExpire? event) {
      if (event != null) _ended.add(event.topic);
    });
  }

  @override
  Future<void> pair(Uri uri) => _sign.pair(uri: uri);

  @override
  Future<String> approve(int id, Map<String, Namespace> namespaces) async =>
      (await _sign.approveSession(id: id, namespaces: namespaces)).topic;

  @override
  Future<void> reject(int id, ReownSignError reason) =>
      _sign.rejectSession(id: id, reason: reason);

  @override
  Future<void> respond(
    String topic,
    int id, {
    Object? result,
    JsonRpcError? error,
  }) => _sign.respondSessionRequest(
    topic: topic,
    response: JsonRpcResponse(id: id, result: result, error: error),
  );

  @override
  Future<void> disconnect(String topic) => _sign.disconnectSession(
    topic: topic,
    reason: Errors.getSdkError(Errors.USER_DISCONNECTED).toSignError(),
  );

  @override
  Future<void> reconnect() async {
    // Also after the relay closed the socket with a refusal: the SDK then
    // treats it as closed on purpose, and every later subscribe is dropped
    // without an error until something connects it again.
    if (!_core.relayClient.isConnected) await _core.relayClient.connect();
  }

  @override
  bool get relayConnected => _core.relayClient.isConnected;

  @override
  String? get relayProblem => _relayProblem;

  @override
  Future<void> close() async {
    _core.heartbeat.stop();
    await _core.connectivity.dispose();
    await _core.relayClient.disconnect();
  }

  @override
  int? requestExpiry(int id) {
    final key = id.toString();
    return _core.expirer.has(key) ? _core.expirer.get(key) : null;
  }

  @override
  Map<String, SessionData> sessions() => _sign.getActiveSessions();

  @override
  Map<String, SessionRequest> pendingRequests() =>
      _sign.getPendingSessionRequests();

  @override
  Stream<SessionProposalEvent> get proposals => _proposals.stream;

  @override
  Stream<SessionRequestEvent> get requests => _requests.stream;

  @override
  Stream<String> get endedSessions => _ended.stream;
}

/// Telemetry that goes nowhere: see [ReownWalletConnectClient].
class _NoEvents implements IEvents {
  @override
  Future<void> init() async {}
  @override
  void setQueryParams(Map<String, String> queryParams) {}
  @override
  Future<void> sendEvent(BasicCoreEvent event) async {}
  @override
  Future<void> sendEventBatch(List<BasicCoreEvent> events) async {}
  @override
  Future<void> recordEvent(BasicCoreEvent event) async {}
  @override
  Future<void> sendStoredEvents() async {}
}

/// The SDK's key chain, in the OS secure store only, as one entry. A read
/// or write that fails throws, so WalletConnect stops working rather than
/// move a key somewhere weaker.
class _SecureKeyStore implements IStore<Map<String, dynamic>> {
  final Map<String, Map<String, dynamic>> _map = {};
  bool _initialized = false;

  @override
  Map<String, Map<String, dynamic>> get map => _map;
  @override
  List<String> get keys => _map.keys.toList();
  @override
  List<Map<String, dynamic>> get values => _map.values.toList();
  @override
  String get storagePrefix => ReownConstants.CORE_STORAGE_PREFIX;

  @override
  Future<void> init() async {
    if (_initialized) return;
    final stored = await walletConnectSecureStorage.read(
      key: walletConnectKeychainKey,
    );
    if (stored != null) {
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        _map[entry.key] = entry.value as Map<String, dynamic>;
      }
    }
    _initialized = true;
  }

  String _key(String key) => '$storagePrefix$key';

  void _check() {
    if (!_initialized) throw Errors.getInternalError(Errors.NOT_INITIALIZED);
  }

  Future<void> _persist(Map<String, Map<String, dynamic>> next) async {
    await walletConnectSecureStorage.write(
      key: walletConnectKeychainKey,
      value: jsonEncode(next),
    );
    _map
      ..clear()
      ..addAll(next);
  }

  @override
  Map<String, dynamic>? get(String key) {
    _check();
    return _map[_key(key)];
  }

  @override
  bool has(String key) {
    _check();
    return _map.containsKey(_key(key));
  }

  @override
  List<dynamic> getAll() {
    _check();
    return values;
  }

  @override
  Future<void> set(String key, Map<String, dynamic> value) {
    _check();
    return _persist({..._map, _key(key): value});
  }

  @override
  Future<void> update(String key, Map<String, dynamic> value) async {
    _check();
    if (!_map.containsKey(_key(key))) {
      throw Errors.getInternalError(Errors.NO_MATCHING_KEY);
    }
    await set(key, value);
  }

  @override
  Future<void> delete(String key) {
    _check();
    return _persist({..._map}..remove(_key(key)));
  }

  @override
  Future<void> deleteAll() async {
    _check();
    await walletConnectSecureStorage.delete(key: walletConnectKeychainKey);
    _map.clear();
  }
}

/// The one secure-store entry that holds the SDK's key chain.
const walletConnectKeychainKey = 'walletconnect.keychain.v1';

/// Where the SDK's keys are kept: the same keychain class as the browser's
/// own connection grants, readable only while the device is unlocked. On
/// Android it is a store of its own, and a read it cannot decrypt fails
/// rather than wipe it, as the plugin's default would — and with the shared
/// default store, every other entry of the app's too.
const walletConnectSecureStorage = FlutterSecureStorage(
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
    accountName: 'mallow_wallet',
  ),
  aOptions: AndroidOptions(
    resetOnError: false,
    storageNamespace: 'walletconnect',
  ),
);

/// A relay failure as a short reason: the relay's close code and its own
/// reason (such as `3000: Unauthorized: origin not allowed`), or the HTTP
/// status of a refused handshake. Never the error's text otherwise, which
/// can quote the relay URL and the client's auth token.
String? describeRelayError(Object? error) {
  if (error is ReownCoreError) {
    return error.message.isEmpty
        ? '${error.code}'
        : '${error.code}: ${error.message}';
  }
  if (error == null) return null;
  final text = '$error';
  final status = RegExp(r'status code:? (\d{3})').firstMatch(text);
  if (status != null) return 'HTTP ${status.group(1)}';
  if (error is TimeoutException || text.contains('timeout')) return 'timeout';
  return 'no connection';
}
