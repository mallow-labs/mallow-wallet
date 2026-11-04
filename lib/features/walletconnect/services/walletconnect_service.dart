import 'dart:async';

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:reown_core/reown_core.dart'
    show Errors, JsonRpcError, PairingMetadata, ReownConstants, Validation;
import 'package:reown_sign/reown_sign.dart'
    show
        ReownSignErrorExtension,
        SessionData,
        SessionProposalEvent,
        SessionRequestEvent;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/account.dart' show WalletInfo;
import '../../../core/observability/app_logger.dart';
import '../../../shared/utils/chain.dart';
import '../../browser/models/dapp_request.dart';
import '../../browser/services/dapp_permission_service.dart';
import '../../browser/services/dapp_request_coordinator.dart';
import '../../browser/services/ethereum_dapp_adapter.dart' show ethereumMainnet;
import '../../browser/services/tezos_dapp_adapter.dart'
    show tezosBrowserCanSign, tezosMainnet;
import '../../wallets/services/profile_lookup_service.dart'
    show isViewOnlyPlaceholder;
import 'walletconnect_client.dart';
import 'walletconnect_codec.dart';
import 'walletconnect_namespaces.dart';
import 'walletconnect_uri.dart';

/// A website asking to connect, as the approval sheet shows it.
class WalletConnectProposal {
  const WalletConnectProposal({
    required this.name,
    required this.origin,
    required this.iconUrl,
    required this.validation,
    required this.namespaces,
    required this.candidates,
  });

  /// The name and origin the website reported. Only [validation] says
  /// whether WalletConnect's Verify service saw the request come from it.
  final String name;
  final Uri origin;
  final Uri? iconUrl;
  final Validation validation;
  final List<RequestedNamespace> namespaces;

  /// The wallets the user may pick for each namespace, best first.
  final Map<String, List<WalletInfo>> candidates;
}

/// A connected website.
class WalletConnectSessionView {
  const WalletConnectSessionView({
    required this.topic,
    required this.name,
    required this.origin,
    required this.iconUrl,
    required this.expiry,
    required this.addresses,
  });
  final String topic;
  final String name;
  final Uri origin;
  final Uri? iconUrl;
  final DateTime expiry;

  /// The session's address for each namespace (`solana`, `eip155`, `tezos`).
  final Map<String, String> addresses;
}

/// What the service needs from the screen it shows on.
abstract class WalletConnectPresenter {
  /// A context under the root navigator, for the review sheets.
  BuildContext? get context;

  /// Asks the user to approve [proposal]. Returns the chosen wallet for each
  /// namespace, or null to reject.
  Future<Map<String, WalletInfo>?> approveProposal(
    WalletConnectProposal proposal,
  );
  void showMessage(String message, {bool error = false});
}

/// The wallet side of WalletConnect: pairing, session proposals, requests,
/// and the connected-site list.
///
/// Every request goes through the browser's [DappRequestCoordinator], one per
/// session, so it gets the same validation, serial approval, timeout and
/// review sheets as a request from a page in the in-app browser. A session is
/// bound to the wallets the user approved when connecting, never to whichever
/// wallet is active later: a session lives for days, and a signer that moved
/// with the active wallet would sign for an address the website never saw.
///
/// The connection a website reports (its name, URL and icon) is not proven by
/// anything the wallet controls, the way a browser tab's origin is. So its
/// grants live only inside its own session, never in the browser's store, and
/// a website WalletConnect's Verify service reports as malicious cannot
/// connect at all.
///
/// Nothing is shown while the app is locked or in the background. Proposals
/// and requests that arrive then wait, and are taken up in order once the
/// user is back.
class WalletConnectService with WidgetsBindingObserver {
  WalletConnectService({
    required this.projectId,
    required WalletConnectClient Function() createClient,
    required this.presenter,
    required Future<List<WalletInfo>> Function() deviceWallets,
    required List<WalletInfo> Function() sessionWallets,
    required bool Function() attended,
    String Function()? unattendedReason,
    required bool Function() enabled,
    required Future<Map<String, Object?>> Function(
      BuildContext,
      DappSigningRequest,
    )
    sign,
    required Future<String> Function(
      DappWallet wallet,
      void Function() active,
      Future<void>? cancelled,
    )
    tezosPublicKey,
    bool Function()? canContinue,
    Future<bool> Function()? readUsed,
    Future<void> Function(bool)? writeUsed,
    Future<String?> Function()? readBindings,
    Future<void> Function(String?)? writeBindings,
    this.allowDevnet = false,
    this.pairingTimeout = const Duration(seconds: 20),
  }) : _createClient = createClient,
       _deviceWallets = deviceWallets,
       _sessionWallets = sessionWallets,
       _attended = attended,
       _unattendedReason = unattendedReason ?? (() => 'not ready'),
       _canContinue = canContinue ?? attended,
       _enabled = enabled,
       _sign = sign,
       _tezosPublicKey = tezosPublicKey,
       _readUsed = readUsed ?? _readUsedPreference,
       _writeUsed = writeUsed ?? _writeUsedPreference,
       _readBindings = readBindings ?? _readBindingsPreference,
       _writeBindings = writeBindings ?? _writeBindingsPreference;

  /// Set once at startup by `registerWalletConnectModule`; null while
  /// WalletConnect is not configured for this build.
  static WalletConnectService? instance;

  final String projectId;
  final WalletConnectPresenter presenter;
  final bool allowDevnet;

  /// How long a pairing waits for the website's proposal before the user is
  /// told it never came.
  final Duration pairingTimeout;
  final WalletConnectClient Function() _createClient;
  final Future<List<WalletInfo>> Function() _deviceWallets;
  final List<WalletInfo> Function() _sessionWallets;
  final bool Function() _attended;

  /// Why [_attended] is false, named in the message a stalled scan shows.
  final String Function() _unattendedReason;

  /// Whether a request already in review may go on. Looser than [_attended]:
  /// an external signer answers while the app is briefly in the background.
  final bool Function() _canContinue;
  final bool Function() _enabled;
  final Future<Map<String, Object?>> Function(BuildContext, DappSigningRequest)
  _sign;
  final Future<String> Function(DappWallet, void Function(), Future<void>?)
  _tezosPublicKey;
  final Future<bool> Function() _readUsed;
  final Future<void> Function(bool) _writeUsed;
  final Future<String?> Function() _readBindings;
  final Future<void> Function(String?) _writeBindings;

  /// The connected websites, newest first.
  final sessions = ValueNotifier<List<WalletConnectSessionView>>(const []);

  WalletConnectClient? _client;
  Future<WalletConnectClient>? _starting;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final Map<String, Future<_Session>> _coordinators = {};
  final List<Object> _queue = [];
  final Set<int> _handled = {};
  bool _draining = false;
  List<WalletInfo> _wallets = const [];

  /// Pairings still waiting for the website's proposal, by pairing topic.
  final Map<String, Timer> _awaitingProposal = {};

  /// The address the user approved for each namespace of each session, by
  /// topic. The SDK lets the website replace a session's namespaces
  /// (`wc_sessionUpdate`) without checking it is the controller, so the
  /// session's own namespaces are never trusted alone: a session that no
  /// longer matches what the user approved is ended.
  Map<String, Map<String, String>> _bindings = {};

  /// Bumped by [reset], so a client still starting then is discarded.
  int _generation = 0;

  /// Approvals in flight. The SDK stores a session before `approve`
  /// returns its topic, so until then a session without a binding may be
  /// the one being approved, and is refused but not ended.
  int _approving = 0;

  bool _mayEnd(SessionData session) =>
      _approving == 0 || _bindings.containsKey(session.topic);

  /// The metadata the wallet presents to websites.
  static const metadata = PairingMetadata(
    name: 'mallow',
    description: 'mallow wallet',
    url: 'https://wallet.mallow.art',
    icons: ['https://wallet.mallow.art/apple-touch-icon.png'],
  );

  static const _usedKey = 'walletconnect.used';
  static const _bindingsKey = 'walletconnect.bindings';

  static Future<String?> _readBindingsPreference() async =>
      (await SharedPreferences.getInstance()).getString(_bindingsKey);

  static Future<void> _writeBindingsPreference(String? value) async {
    final preferences = await SharedPreferences.getInstance();
    value == null
        ? await preferences.remove(_bindingsKey)
        : await preferences.setString(_bindingsKey, value);
  }

  Future<void> _loadBindings() async {
    try {
      final stored = await _readBindings();
      final decoded = stored == null ? null : jsonDecode(stored);
      _bindings = decoded is Map
          ? {
              for (final entry in decoded.entries)
                if (entry.value is Map)
                  entry.key as String: (entry.value as Map)
                      .cast<String, String>(),
            }
          : {};
    } catch (_) {
      // Unreadable bindings end every session, which is the safe side.
      _bindings = {};
    }
  }

  Future<void> _saveBindings() async {
    try {
      await _writeBindings(_bindings.isEmpty ? null : jsonEncode(_bindings));
    } catch (_) {
      // Kept in memory; the next launch ends the sessions it cannot match.
    }
  }

  /// [session]'s accounts, when they are exactly what the user approved.
  Map<String, ({String address, List<String> chains})>? _bound(
    SessionData session,
  ) {
    final binding = _bindings[session.topic];
    final accounts = sessionAccounts(session.namespaces);
    if (binding == null || accounts == null || accounts.isEmpty) return null;
    for (final entry in accounts.entries) {
      if (binding[entry.key] != entry.value.address) return null;
    }
    return accounts;
  }

  static Future<bool> _readUsedPreference() async =>
      (await SharedPreferences.getInstance()).getBool(_usedKey) ?? false;

  static Future<void> _writeUsedPreference(bool used) async {
    final preferences = await SharedPreferences.getInstance();
    used
        ? await preferences.setBool(_usedKey, true)
        : await preferences.remove(_usedKey);
  }

  /// Reconnects at launch only when this device has paired before, so a user
  /// who never uses WalletConnect never opens a connection to its relay.
  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      if (await _readUsed()) await _ensureClient();
    } catch (_) {
      // Nothing to report: the next pairing tries again.
    }
  }

  Future<WalletConnectClient> _ensureClient() {
    final client = _client;
    if (client != null) return Future.value(client);
    final generation = _generation;
    return _starting ??= () async {
      final created = _createClient();
      try {
        await created.init();
        await _loadBindings();
      } catch (_) {
        if (generation == _generation) _starting = null;
        rethrow;
      }
      if (generation != _generation) {
        // Reset while starting: this client must not outlive the wipe.
        unawaited(created.close().catchError((Object _) {}));
        throw StateError('WalletConnect was reset');
      }
      _subscriptions.addAll([
        created.proposals.listen(_onProposal),
        created.requests.listen(_onRequest),
        created.endedSessions.listen((topic) => unawaited(_ended(topic))),
      ]);
      _client = created;
      await _refreshSessions();
      _queuePending(created);
      unawaited(_drain());
      return created;
    }();
  }

  /// Pairs with the website behind [uri]. Its proposal arrives as a separate
  /// event, which the approval sheet answers.
  Future<void> pair(WalletConnectUri uri) async {
    if (!_enabled()) {
      presenter.showMessage(
        'Connecting to websites is unavailable right now',
        error: true,
      );
      return;
    }
    final WalletConnectClient client;
    try {
      client = await _ensureClient();
    } catch (_) {
      presenter.showMessage('WalletConnect could not start', error: true);
      return;
    }
    if (!uri.isPairing) {
      // A "request waiting" link: the request itself comes over the relay.
      await resume();
      return;
    }
    try {
      await client.reconnect();
    } catch (_) {
      // Reported just below.
    }
    if (!client.relayConnected) {
      presenter.showMessage(_unreachable(client), error: true);
      return;
    }
    try {
      await client.pair(uri.uri);
      await _writeUsed(true);
      _awaitProposal(client, uri.topic);
    } catch (_) {
      // Never the SDK's text: it can quote the URI, which holds the key.
      presenter.showMessage(
        'This link has expired or was already used. Get a new one from the '
        'website.',
        error: true,
      );
    }
  }

  /// Pairing returns once the wallet has subscribed, before the website
  /// answers. A relay that refuses the connection, a lost network or a
  /// closed website tab would all leave a scan doing nothing visible, so the
  /// user is told when the proposal does not come.
  void _awaitProposal(WalletConnectClient client, String topic) {
    _awaitingProposal.remove(topic)?.cancel();
    presenter.showMessage('Connecting to the website…');
    _awaitingProposal[topic] = Timer(pairingTimeout, () {
      if (_awaitingProposal.remove(topic) == null) return;
      presenter.showMessage(
        client.relayConnected
            ? 'The website did not answer. Get a new code from the website '
                  'and try again.'
            : _unreachable(client),
        error: true,
      );
    });
  }

  /// The relay's own reason goes in the message: it is the one detail that
  /// tells a refused app apart from a lost network.
  static String _unreachable(WalletConnectClient client) {
    final problem = client.relayProblem;
    return 'mallow could not reach WalletConnect'
        '${problem == null ? '' : ' ($problem)'}. Check your connection and '
        'try again.';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(resume());
  }

  /// Reconnects the relay and takes up anything that arrived meanwhile.
  Future<void> resume() async {
    final client = _client;
    if (client == null) {
      // A start at launch can fail, such as a keychain read before the
      // first unlock; a device that has paired tries again here.
      try {
        if (await _readUsed()) await _ensureClient();
      } catch (_) {
        // The next resume or pairing tries again.
      }
      return;
    }
    try {
      await client.reconnect();
    } catch (_) {
      // The SDK retries the socket itself.
    }
    _queuePending(client);
    await _drain();
  }

  /// Takes up queued work: the lock was lifted, or the app came back.
  void attendedChanged() => unawaited(_drain());

  /// Cancels the request in review in every session, for the app lock. Its
  /// website hears a rejection; queued requests wait for the unlock.
  void cancelActive() {
    for (final session in _coordinators.values) {
      unawaited(
        session.then((s) => s.coordinator.invalidate(), onError: (_) {}),
      );
    }
  }

  Future<void> disconnect(String topic) async {
    final client = _client;
    if (client == null) return;
    try {
      await client.disconnect(topic);
    } finally {
      await _ended(topic);
    }
  }

  /// Ends every session whose wallet is no longer on this device.
  Future<void> walletsChanged() async {
    final client = _client;
    if (client == null) return;
    final List<WalletInfo> wallets;
    try {
      wallets = await _deviceWallets();
    } catch (_) {
      return;
    }
    // An empty list is a wallet store not loaded yet, or one being reset,
    // which [reset] handles; it is never a reason to end every session.
    if (wallets.isEmpty) return;
    _wallets = wallets;
    for (final session in client.sessions().values.toList()) {
      final accounts = _bound(session);
      final orphaned =
          accounts == null ||
          accounts.entries.any(
            (entry) => _walletFor(entry.key, entry.value.address) == null,
          );
      if (orphaned && _mayEnd(session)) {
        try {
          await disconnect(session.topic);
        } catch (_) {
          // The session is dropped locally regardless; see [disconnect].
        }
      }
    }
  }

  /// Ends every session and erases WalletConnect's storage, for an app
  /// reset. Returns the names of the steps that failed.
  Future<List<String>> reset() async {
    _generation++;
    for (final timer in _awaitingProposal.values) {
      timer.cancel();
    }
    _awaitingProposal.clear();
    final failures = <String>[];
    final client = _client;
    if (client != null) {
      for (final topic in client.sessions().keys.toList()) {
        try {
          await client.disconnect(topic).timeout(const Duration(seconds: 3));
        } catch (_) {
          // Best effort: the website's session lapses at its expiry.
        }
      }
    }
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    try {
      await client?.close();
    } catch (_) {
      // The socket goes with the process at the latest.
    }
    for (final session in _coordinators.values) {
      unawaited(session.then((s) => s.dispose(), onError: (_) {}));
    }
    _coordinators.clear();
    _queue.clear();
    _client = null;
    _starting = null;
    sessions.value = const [];
    _bindings = {};
    try {
      await walletConnectSecureStorage.delete(key: walletConnectKeychainKey);
    } catch (_) {
      failures.add('keys');
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      for (final key in preferences.getKeys().toList()) {
        if (key.startsWith(ReownConstants.CORE_STORAGE_PREFIX)) {
          await preferences.remove(key);
        }
      }
      await _writeUsed(false);
      await _writeBindings(null);
    } catch (_) {
      failures.add('sessions');
    }
    return failures;
  }

  void _onProposal(SessionProposalEvent event) {
    final scanned = _awaitingProposal.remove(event.params.pairingTopic);
    scanned?.cancel();
    if (!_enabled()) {
      unawaited(_reject(event.id, Errors.USER_REJECTED));
      return;
    }
    _queue.add(event);
    unawaited(_drain());
    if (scanned != null) _watchTakenUp(event);
  }

  /// The user has just scanned, so a proposal still queued moments later is
  /// one they are waiting on with nothing on screen. Say why it waits.
  void _watchTakenUp(SessionProposalEvent event) {
    Timer(const Duration(seconds: 3), () {
      if (!_queue.contains(event)) return;
      final reason = !_attended()
          ? _unattendedReason()
          : _draining
          ? 'another request is open'
          : 'queued';
      presenter.showMessage(
        'mallow got the connection request but could not show it '
        '($reason).',
        error: true,
      );
    });
  }

  void _onRequest(SessionRequestEvent event) {
    if (!_handled.add(event.id)) return;
    _queue.add(event);
    unawaited(_drain());
  }

  void _queuePending(WalletConnectClient client) {
    for (final request in client.pendingRequests().values) {
      if (_handled.add(request.id)) {
        _queue.add(SessionRequestEvent.fromSessionRequest(request));
      }
    }
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && _attended()) {
        final item = _queue.removeAt(0);
        try {
          if (item is SessionProposalEvent) {
            await _proposal(item);
          } else if (item is SessionRequestEvent) {
            await _request(item);
          }
        } catch (error, stackTrace) {
          // One failed item must not stall the ones behind it.
          AppLogger.error(
            'WalletConnect',
            'Queued item failed',
            error,
            stackTrace,
          );
          if (item is SessionProposalEvent) {
            // The type only: an SDK error's text can quote the pairing URI.
            presenter.showMessage(
              'mallow could not show the connection request '
              '(${error.runtimeType}). Get a new code from the website and '
              'try again.',
              error: true,
            );
          }
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _reject(int id, String reason) async {
    try {
      await _client?.reject(id, Errors.getSdkError(reason).toSignError());
    } catch (_) {
      // The proposal lapses at its expiry.
    }
  }

  Future<void> _proposal(SessionProposalEvent event) async {
    final proposal = event.params;
    if (_expired(proposal.expiry)) {
      presenter.showMessage(
        'The connection request expired. Try again from the website.',
        error: true,
      );
      return;
    }
    final verify = event.verifyContext;
    final validation = verify?.isScam == true
        ? Validation.SCAM
        : verify?.validation ?? Validation.UNKNOWN;
    if (validation.scam) {
      await _reject(event.id, Errors.USER_REJECTED);
      presenter.showMessage(
        'mallow blocked a connection from a website reported as malicious',
        error: true,
      );
      return;
    }
    final peer = proposal.proposer.metadata;
    final origin = _origin(peer.url);
    if (origin == null) {
      await _reject(event.id, Errors.USER_REJECTED);
      presenter.showMessage(
        "This website has no secure address, so mallow can't connect to it",
        error: true,
      );
      return;
    }
    List<RequestedNamespace> requested;
    try {
      requested = requestedNamespaces(
        requiredNamespaces: proposal.requiredNamespaces,
        optionalNamespaces: proposal.optionalNamespaces,
        allowDevnet: allowDevnet,
      );
    } on WalletConnectUnsupported catch (error) {
      await _reject(
        event.id,
        error.methods ? Errors.UNSUPPORTED_METHODS : Errors.UNSUPPORTED_CHAINS,
      );
      presenter.showMessage(error.message, error: true);
      return;
    }
    try {
      final wallets = await _deviceWallets();
      if (wallets.isNotEmpty) _wallets = wallets;
    } catch (_) {
      // The session's own wallets are still offered.
    }
    final candidates = <String, List<WalletInfo>>{};
    for (final namespace in requested) {
      final wallets = _candidates(namespace.namespace);
      if (wallets.isNotEmpty) {
        candidates[namespace.namespace] = wallets;
      } else if (namespace.required) {
        await _reject(event.id, Errors.UNSUPPORTED_ACCOUNTS);
        presenter.showMessage(
          'Add ${_article(namespace.namespace)} wallet to connect to this '
          'website',
          error: true,
        );
        return;
      }
    }
    requested = [
      for (final namespace in requested)
        if (candidates.containsKey(namespace.namespace)) namespace,
    ];
    if (requested.isEmpty) {
      await _reject(event.id, Errors.UNSUPPORTED_CHAINS);
      presenter.showMessage(
        'This website asks for no network mallow supports',
        error: true,
      );
      return;
    }
    final choice = await presenter.approveProposal(
      WalletConnectProposal(
        name: peer.name.trim().isEmpty ? origin.host : peer.name.trim(),
        origin: origin,
        iconUrl: _icon(peer.icons),
        validation: validation,
        namespaces: requested,
        candidates: candidates,
      ),
    );
    if (choice == null) {
      await _reject(event.id, Errors.USER_REJECTED);
      return;
    }
    if (_expired(proposal.expiry)) {
      presenter.showMessage(
        'The connection request expired. Try again from the website.',
        error: true,
      );
      return;
    }
    try {
      final addresses = {
        for (final entry in choice.entries) entry.key: entry.value.address,
      };
      final String topic;
      _approving++;
      try {
        topic = await _client!.approve(
          event.id,
          approvedNamespaces(requested, addresses),
        );
        _bindings[topic] = addresses;
      } finally {
        _approving--;
      }
      await _saveBindings();
      await _writeUsed(true);
    } catch (_) {
      presenter.showMessage(
        "Couldn't connect. Try again from the website.",
        error: true,
      );
    }
    await _refreshSessions();
  }

  /// The wallets offered for [namespace]: the current session's first, so
  /// the default is the one the user is using, then the device's others,
  /// which the sheet's Switch lists too. A profile's address that is not on
  /// this device is left out: the session's signer could never be found, so
  /// [walletsChanged] would end it.
  List<WalletInfo> _candidates(String namespace) {
    final chain = namespaceChain(namespace);
    bool usable(WalletInfo w) =>
        w.chainEnum == chain &&
        w.address.isNotEmpty &&
        !isViewOnlyPlaceholder(w);
    bool signs(WalletInfo w) =>
        w.canSign &&
        (chain != Chain.tezos || tezosBrowserCanSign(w.walletType));
    final session = _sessionWallets().where(usable).toList();
    final ids = {for (final w in session) w.id};
    final others = _wallets
        .where((w) => usable(w) && !ids.contains(w.id))
        .toList();
    // Signable first; a view-only wallet can still connect and review.
    return [
      for (final group in [session, others]) ...[
        ...group.where(signs),
        ...group.where((w) => !signs(w)),
      ],
    ];
  }

  Future<void> _request(SessionRequestEvent event) async {
    final client = _client;
    if (client == null) return;
    var signed = false;
    var name = '';
    // The website stops waiting at the request's expiry; a review the user
    // approves after it would sign, or broadcast, for nobody listening.
    final expiry = client.requestExpiry(event.id);
    if (expiry != null && _expired(expiry)) return;
    try {
      final session = client.sessions()[event.topic];
      if (session == null) {
        throw const DappException(4100, 'This website is not connected');
      }
      final accounts = _bound(session);
      if (accounts == null) {
        if (_mayEnd(session)) {
          unawaited(disconnect(session.topic).catchError((Object _) {}));
        }
        throw const DappException(4100, 'This website is not connected');
      }
      name = session.peer.metadata.name.trim();
      if (!_enabled()) {
        throw const DappException(
          4100,
          'Connecting to websites is unavailable right now',
        );
      }
      final namespace = event.chainId.split(':').first;
      final chain = coordinatorChain(event.chainId, allowDevnet: allowDevnet);
      final address = accounts[namespace]?.address;
      if (chain == null) {
        throw const DappException(4901, 'Unsupported network');
      }
      if (address == null) {
        throw const DappException(4100, 'This network is not connected');
      }
      final call = decodeWalletConnectRequest(
        namespace: namespace,
        method: event.method,
        params: event.params,
        address: address,
        chain: chain,
      );
      final Object? result;
      switch (call) {
        case final WalletConnectAnswer answer:
          result = answer.result;
        case WalletConnectCoordinatorCall():
          final state = await _sessionFor(session, accounts);
          final wallets = await _deviceWallets();
          if (wallets.isNotEmpty) _wallets = wallets;
          state.expiry = expiry;
          final Map<String, Object?> response;
          try {
            response = await state.coordinator.handle({
              'id': '${event.id}',
              'namespace': call.namespace,
              'method': call.method,
              'params': call.params,
            }, state.frame);
          } finally {
            state.expiry = null;
          }
          final error = response['error'];
          if (error is Map) {
            throw DappException(
              error['code'] as int? ?? -32603,
              error['message'] as String? ?? 'Wallet request failed',
            );
          }
          result = call.result(response['result']! as Map);
          signed = call.method != 'connect';
      }
      await client.respond(event.topic, event.id, result: result);
      if (signed && name.isNotEmpty) {
        presenter.showMessage('Done. Return to $name to continue.');
      }
    } on DappException catch (error) {
      await _respondError(client, event, error);
    } catch (_) {
      await _respondError(
        client,
        event,
        const DappException(-32603, 'Wallet request failed'),
      );
    }
  }

  Future<void> _respondError(
    WalletConnectClient client,
    SessionRequestEvent event,
    DappException error,
  ) async {
    // The coordinator's messages are already safe to show a website.
    final rejected = error.code == 4001;
    try {
      await client.respond(
        event.topic,
        event.id,
        error: JsonRpcError(
          code: rejected ? 5000 : error.code,
          message: rejected ? 'User rejected.' : error.message,
        ),
      );
    } catch (_) {
      // The request lapses at its expiry.
    }
  }

  Future<_Session> _sessionFor(
    SessionData session,
    Map<String, ({String address, List<String> chains})> accounts,
  ) {
    final topic = session.topic;
    final existing = _coordinators[topic];
    if (existing != null) return existing;
    final created = _createSession(session, accounts);
    _coordinators[topic] = created;
    // A session that could not be set up is tried afresh next time.
    created.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_coordinators[topic], created)) {
          _coordinators.remove(topic);
        }
      },
    );
    return created;
  }

  Future<_Session> _createSession(
    SessionData session,
    Map<String, ({String address, List<String> chains})> accounts,
  ) async {
    final topic = session.topic;
    final peer = session.peer.metadata;
    final origin = _origin(peer.url);
    if (origin == null) {
      throw const DappException(4100, 'This website has no secure address');
    }
    // The session's own grants: approved with the session, gone with it,
    // and never shared with the browser's connected sites.
    String? stored;
    final permissions = DappPermissionService(
      read: () async => stored,
      write: (value) async => stored = value,
    );
    final addresses = {
      for (final entry in accounts.entries) entry.key: entry.value.address,
    };
    for (final address in addresses.values) {
      await permissions.grant(
        origin.origin,
        address,
        scopes: const ['sign', 'operation_request'],
      );
    }
    final frame = DappFrameContext(
      tabId: 'walletconnect:$topic',
      generation: 0,
      origin: origin,
      isMainFrame: true,
      isActive: true,
      documentToken: topic,
      iconUrl: _icon(peer.icons),
    );
    final state = _Session(permissions, frame);
    // Still connected, and still exactly what the user approved.
    bool live() {
      if (!_enabled()) return false;
      final current = _client?.sessions()[topic];
      final bound = current == null ? null : _bound(current);
      return bound != null &&
          bound.entries.every(
            (entry) => addresses[entry.key] == entry.value.address,
          );
    }

    final solanaChains = [
      for (final chain in accounts['solana']?.chains ?? const <String>[])
        ?coordinatorChain(chain, allowDevnet: allowDevnet),
    ];
    DappWallet? wallet(String namespace) {
      final address = addresses[namespace];
      final info = address == null ? null : _walletFor(namespace, address);
      if (info == null) return null;
      return switch (namespace) {
        'solana' => DappWallet(
          id: info.id,
          address: info.address,
          canSign: info.canSign,
          canSignMessages:
              info.canSign && solanaSignsDappMessagesVerbatim(info.walletType),
          chains: solanaChains.toSet().toList(),
          type: info.walletType,
        ),
        'eip155' => DappWallet(
          id: info.id,
          address: info.address,
          canSign: info.canSign,
          chains: const [ethereumMainnet],
          type: info.walletType,
        ),
        _ => DappWallet(
          id: info.id,
          address: info.address,
          canSign: info.canSign && tezosBrowserCanSign(info.walletType),
          chains: const [tezosMainnet],
          type: info.walletType,
        ),
      };
    }

    state.coordinator = DappRequestCoordinator(
      permissions: permissions,
      currentWallet: () => wallet('solana'),
      currentEthereumWallet: () => wallet('eip155'),
      currentTezosWallet: () => wallet('tezos'),
      tezosPublicKey: (wallet, active) => _tezosPublicKey(wallet, active, null),
      connectTezosPublicKey: (wallet, active, cancelled) =>
          _tezosPublicKey(wallet, active, cancelled),
      // Approval happened when the session was; nothing connects again.
      approveConnection: (_) async => false,
      execute: (request) {
        final context = presenter.context;
        if (context == null || !context.mounted) {
          throw const DappException(4001, 'Request cancelled');
        }
        return _sign(context, request);
      },
      isContextCurrent: (_) => live() && _attended() && state.current,
      // An external signer answers before the app is foregrounded again,
      // but nothing signs past the lock or the request's expiry.
      isRequestCurrent: (_) => live() && _canContinue() && state.current,
    );
    return state;
  }

  WalletInfo? _walletFor(String namespace, String address) {
    final chain = namespaceChain(namespace);
    final ethereum = chain == Chain.ethereum;
    bool same(String a) =>
        ethereum ? a.toLowerCase() == address.toLowerCase() : a == address;
    final matches = _wallets.where(
      (w) => w.chainEnum == chain && same(w.address),
    );
    return matches.where((w) => w.canSign).firstOrNull ?? matches.firstOrNull;
  }

  Future<void> _ended(String topic) async {
    final session = _coordinators.remove(topic);
    if (session != null) {
      unawaited(session.then((s) => s.dispose(), onError: (_) {}));
    }
    if (_bindings.remove(topic) != null) await _saveBindings();
    await _refreshSessions();
  }

  Future<void> _refreshSessions() async {
    final client = _client;
    if (client == null) return;
    try {
      _wallets = await _deviceWallets();
    } catch (_) {
      // The list below needs no wallet; requests reload them anyway.
    }
    final views = <WalletConnectSessionView>[];
    for (final session in client.sessions().values) {
      final accounts = _bound(session);
      if (accounts == null) {
        // Changed by the website since the user approved it, or approved
        // where the record of it was lost: either way, not the user's.
        if (_mayEnd(session)) {
          unawaited(client.disconnect(session.topic).catchError((Object _) {}));
        }
        continue;
      }
      final origin = _origin(session.peer.metadata.url);
      if (origin == null) continue;
      final name = session.peer.metadata.name.trim();
      views.add(
        WalletConnectSessionView(
          topic: session.topic,
          name: name.isEmpty ? origin.host : name,
          origin: origin,
          iconUrl: _icon(session.peer.metadata.icons),
          expiry: DateTime.fromMillisecondsSinceEpoch(
            session.expiry * 1000,
            isUtc: true,
          ),
          addresses: {
            for (final entry in accounts.entries)
              entry.key: entry.value.address,
          },
        ),
      );
    }
    views.sort((a, b) => b.expiry.compareTo(a.expiry));
    sessions.value = List.unmodifiable(views);
    if (views.isEmpty && _coordinators.isEmpty) return;
    for (final topic in _coordinators.keys.toList()) {
      if (!views.any((view) => view.topic == topic)) await _ended(topic);
    }
  }

  static bool _expired(int expirySeconds) =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expirySeconds;

  /// The website's HTTPS origin, or null when it reported none.
  static Uri? _origin(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return Uri.parse(uri.origin);
  }

  static Uri? _icon(List<String> icons) {
    for (final icon in icons) {
      final uri = Uri.tryParse(icon);
      if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
        return uri;
      }
    }
    return null;
  }

  static String _article(String namespace) => switch (namespace) {
    'eip155' => 'an Ethereum',
    'tezos' => 'a Tezos',
    _ => 'a Solana',
  };
}

class _Session {
  _Session(this.permissions, this.frame);
  late final DappRequestCoordinator coordinator;
  final DappPermissionService permissions;
  final DappFrameContext frame;

  /// The expiry of the request in review, in seconds since the epoch.
  int? expiry;

  bool get current =>
      expiry == null || DateTime.now().millisecondsSinceEpoch ~/ 1000 < expiry!;

  void dispose() {
    coordinator.dispose();
    unawaited(permissions.dispose());
  }
}
