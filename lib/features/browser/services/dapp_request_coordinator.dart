import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import '../../../core/models/account.dart' show WalletType;

import '../models/dapp_request.dart';
import '../models/solana_offchain_message.dart';
import '../models/solana_sign_in.dart';
import 'dapp_permission_service.dart';
import 'ethereum_dapp_adapter.dart';
import 'tezos_dapp_adapter.dart';
import 'tezos_beacon_transport.dart';

/// The most transactions one `signAllTransactions` request may carry. They
/// are reviewed and approved as one; a batch larger than the adapter's
/// `kMaxSimulatedSolanaBatch` is reviewed without a simulation.
const kMaxSolanaBatch = 100;

/// Serializes approval and pins the native document, signer, cluster and bytes.
///
/// Requests arrive in independent namespaces: Solana (no `namespace` field,
/// the original wire), `eip155` for Ethereum and `tezos` for Tezos/Beacon. Each
/// namespace has its own wallet, and a grant is per origin and address, so
/// connecting one never connects another.
class DappRequestCoordinator {
  DappRequestCoordinator({
    required this.permissions,
    required this.currentWallet,
    required this.approveConnection,
    required this.execute,
    required this.isContextCurrent,
    bool Function(DappFrameContext)? isRequestCurrent,
    this.currentEthereumWallet,
    this.ethereumRead,
    this.currentTezosWallet,
    this.tezosPublicKey,
    this.connectTezosPublicKey,
    this.cachedTezosPublicKey,
    this.beaconTransport,
    this.requestTimeout = const Duration(minutes: 3),
    this.onActivity,
    DateTime Function()? now,
  }) : isRequestCurrent = isRequestCurrent ?? isContextCurrent,
       now = now ?? DateTime.now;
  final DappPermissionService permissions;
  final DappWallet? Function() currentWallet;

  /// The Ethereum wallet the page's `window.ethereum` acts for. Null leaves
  /// the `eip155` namespace unsupported.
  final DappWallet? Function()? currentEthereumWallet;

  /// A read-only call through the wallet's Ethereum node, restricted to
  /// [ethereumReadMethods]. It skips the approval lane: it signs nothing and
  /// must not wait behind a signature the user is still reading.
  final Future<Object?> Function(String method, List<Object?> params)?
  ethereumRead;
  final DappWallet? Function()? currentTezosWallet;
  final Future<String> Function(DappWallet, void Function())? tezosPublicKey;
  final Future<String> Function(DappWallet, void Function(), Future<void>)?
  connectTezosPublicKey;
  final String? Function(DappWallet)? cachedTezosPublicKey;
  final TezosBeaconTransport? beaconTransport;
  final Future<bool> Function(DappConnectionRequest) approveConnection;
  final Future<Map<String, Object?>> Function(DappSigningRequest) execute;

  /// Whether a new request may be admitted from this frame.
  final bool Function(DappFrameContext) isContextCurrent;

  /// Whether an already admitted request may continue. It can be looser than
  /// [isContextCurrent]: an external signer returns its result before the app
  /// is foregrounded again, so a transient inactive state must not discard a
  /// signature the user has just approved.
  final bool Function(DappFrameContext) isRequestCurrent;
  final Duration requestTimeout;

  /// Called with a request's namespace (`solana`, `eip155`, `tezos`) when a
  /// site makes a request the wallet serves, before it is handled.
  final void Function(String namespace)? onActivity;

  /// The clock a sign-in's validity times are checked against.
  final DateTime Function() now;
  Future<void> _tail = Future.value();
  final Map<String, Completer<void>> _pending = {};
  final Set<String> _seen = {};
  int _epoch = 0;
  int _reads = 0;
  bool _disposed = false;

  /// Documents on a certificate exception whose connection the user approved
  /// under the certificate warning, per namespace and address. Only these
  /// may request a signature: a saved grant names an origin whose identity
  /// such a document does not prove. Not cleared by [invalidate], which also
  /// runs for a native overlay or the app going to the background, after
  /// which the page keeps its connection; the key names the document, so a
  /// new one never inherits an entry.
  final Set<String> _certificateConnections = <String>{};

  static String _certificateKey(
    DappFrameContext context,
    String namespace,
    DappWallet wallet,
  ) => [
    context.tabId,
    context.generation,
    context.documentToken,
    context.canonicalOrigin,
    namespace,
    wallet.address,
  ].join('\n');

  void _rememberCertificateConnection(
    DappFrameContext context,
    String namespace,
    DappWallet wallet,
  ) {
    if (!context.certificateException) return;
    final key = _certificateKey(context, namespace, wallet);
    _certificateConnections
      ..remove(key)
      ..add(key);
    while (_certificateConnections.length > 64) {
      _certificateConnections.remove(_certificateConnections.first);
    }
  }

  /// Refuses a signature from a document on a certificate exception that has
  /// not connected under the warning, whatever grant the origin holds.
  void _requireCertificateConnection(
    DappFrameContext context,
    String namespace,
    DappWallet wallet,
  ) {
    if (context.certificateException &&
        !_certificateConnections.contains(
          _certificateKey(context, namespace, wallet),
        )) {
      throw const DappException(
        4100,
        "This site's certificate is not trusted. Connect again before "
        'requesting a signature',
      );
    }
  }

  static const _solanaMethods = {
    'connect',
    'disconnect',
    'signTransaction',
    'signAllTransactions',
    'signAndSendTransaction',
    'signMessage',
    'signOffchainMessage',
    'signIn',
  };

  static const _ethereumMethods = {
    'connect',
    'disconnect',
    'read',
    'personal_sign',
    'eth_signTypedData_v4',
    'eth_sendTransaction',
  };

  void invalidate() {
    _epoch++;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.complete();
    }
    _seen.clear();
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }

  Future<Map<String, Object?>> handle(
    Map<String, dynamic> message,
    DappFrameContext context,
  ) async {
    String? key;
    var active = true;
    Timer? timer;
    try {
      _checkContext(context);
      final id = message['id'];
      final method = message['method'];
      final namespace = message['namespace'];
      if (id is! String ||
          id.isEmpty ||
          id.length > 128 ||
          method is! String ||
          (namespace != null &&
              namespace != 'eip155' &&
              namespace != 'tezos')) {
        throw const DappException(-32600, 'Invalid request');
      }
      final ethereum = namespace == 'eip155';
      final tezos = namespace == 'tezos';
      if (tezos && method == 'beacon') {
        final transport = beaconTransport;
        if (transport == null)
          throw const DappException(4200, 'Beacon is unavailable');
        final epoch = _epoch;
        return {
          'result': await transport.handle(
            params: message['params'],
            origin: context.canonicalOrigin,
            ensureActive: () {
              if (epoch != _epoch)
                throw const DappException(4001, 'Request cancelled');
              _checkContext(context, admitting: false);
            },
            execute: (beacon) => _processBeacon(beacon, context),
          ),
        };
      }
      final walletFor = tezos
          ? currentTezosWallet
          : ethereum
          ? currentEthereumWallet
          : currentWallet;
      if (walletFor == null ||
          !(tezos
                  ? const {
                      'connect',
                      'disconnect',
                      'signPayload',
                      'sendOperations',
                    }
                  : ethereum
                  ? _ethereumMethods
                  : _solanaMethods)
              .contains(method)) {
        throw const DappException(-32601, 'Unsupported method');
      }
      onActivity?.call(
        tezos
            ? 'tezos'
            : ethereum
            ? 'eip155'
            : 'solana',
      );
      if (jsonEncode(message).length > 400000) {
        throw const DappException(-32602, 'Request is too large');
      }
      if (ethereum && method == 'read') {
        return {'result': await _read(message['params'], context)};
      }
      final silent = message['params'];
      if ((ethereum || tezos) &&
          method == 'connect' &&
          silent is Map &&
          silent['silent'] == true) {
        // A grant lookup and nothing else, so it skips the approval lane:
        // pages poll `eth_accounts`, and must not wait behind a signature.
        return {
          'result': tezos
              ? await _silentTezos(walletFor, context)
              : await _silentEthereum(walletFor, context),
        };
      }
      if (method == 'disconnect') {
        // Revocation must cancel an open approval immediately, rather than wait
        // behind the very signature the website is trying to abandon.
        final wallet = walletFor();
        invalidate();
        if (wallet != null) {
          await permissions.revoke(context.canonicalOrigin, wallet.address);
        }
        _checkContext(context);
        return {'result': <String, Object?>{}};
      }
      final requestKey =
          '$_epoch:${context.tabId}:${context.generation}:${namespace ?? 'solana'}:$id';
      if (_seen.contains(requestKey)) {
        throw const DappException(-32600, 'Duplicate request');
      }
      if (_pending.length >= 8 || _seen.length >= 4096) {
        throw const DappException(-32005, 'Too many requests');
      }
      key = requestKey;
      _seen.add(key);
      final cancelled = Completer<void>();
      _pending[key] = cancelled;
      final epoch = _epoch;
      final revocationRevision = permissions.revocationRevision;
      final wallet = walletFor();
      if (wallet == null) {
        throw DappException(
          4100,
          tezos
              ? 'Select a Tezos wallet'
              : ethereum
              ? 'Select an Ethereum wallet'
              : 'Select a Solana wallet',
        );
      }
      // Copy every mutable value before queueing, including signer capabilities.
      final pinned = DappWallet(
        id: wallet.id,
        address: wallet.address,
        canSign: wallet.canSign,
        canSignMessages: wallet.canSignMessages,
        canSignTypedData: wallet.canSignTypedData,
        chains: List.unmodifiable(wallet.chains),
        type: wallet.type,
      );
      final rawParams = message['params'] ?? <String, dynamic>{};
      if (rawParams is! Map) {
        throw const DappException(-32602, 'Invalid parameters');
      }
      final params = jsonDecode(jsonEncode(rawParams)) as Map<String, dynamic>;
      void ensureActive() {
        final selected = walletFor();
        if (!active ||
            _epoch != epoch ||
            permissions.revocationRevision != revocationRevision ||
            selected?.id != pinned.id ||
            selected?.address != pinned.address ||
            selected?.canSign != pinned.canSign ||
            selected?.canSignMessages != pinned.canSignMessages ||
            selected?.canSignTypedData != pinned.canSignTypedData ||
            !_sameChains(selected?.chains, pinned.chains)) {
          throw const DappException(4001, 'Request cancelled');
        }
        _checkContext(context, admitting: false);
      }

      final work = _tail.then((_) async {
        ensureActive();
        return (tezos
            ? _processTezos
            : ethereum
            ? _processEthereum
            : _process)(
          id,
          method,
          params,
          context,
          pinned,
          ensureActive,
          cancelled.future,
        );
      });
      // Keep the approval lane occupied until a cancelled overlay actually closes.
      _tail = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
      timer = Timer(requestTimeout, () {
        active = false;
        if (!cancelled.isCompleted) cancelled.complete();
      });
      final result = await Future.any<Map<String, Object?>>([
        work,
        cancelled.future.then(
          (_) => throw const DappException(4001, 'Request cancelled'),
        ),
      ]);
      ensureActive();
      return {'result': result};
    } on DappException catch (error) {
      return {'error': error.toJson()};
    } on FormatException {
      return {
        'error': const DappException(
          -32602,
          'Malformed request payload',
        ).toJson(),
      };
    } catch (_) {
      // Never return arbitrary exceptions: they can contain RPC URLs or payloads.
      return {
        'error': const DappException(-32603, 'Wallet request failed').toJson(),
      };
    } finally {
      active = false;
      timer?.cancel();
      if (key != null) _pending.remove(key);
    }
  }

  /// The version 1 off-chain message a `signOffchainMessage` request asks
  /// for: the site's text and its required signers (base64, 32 bytes each),
  /// which must include the connected [address].
  Uint8List _offchainMessage(Map<String, dynamic> params, String address) {
    final content = params['message'];
    final signers = params['requiredSigners'];
    if (content is! String ||
        content.length > kMaxSolanaOffchainContent ||
        signers is! List ||
        signers.isEmpty ||
        signers.length > 255) {
      throw const DappException(-32602, 'Invalid off-chain message');
    }
    final keys = <Uint8List>[];
    for (final signer in signers) {
      if (signer is! String || signer.length > 44) {
        throw const DappException(-32602, 'Invalid required signer');
      }
      keys.add(base64Decode(signer));
    }
    final SolanaOffchainMessage message;
    try {
      message = SolanaOffchainMessage.build(
        content: content,
        requiredSigners: keys,
      );
    } on FormatException catch (error) {
      throw DappException(-32602, error.message);
    }
    if (!message.signers.contains(address)) {
      throw const DappException(
        -32602,
        'The required signers must include the connected account',
      );
    }
    return message.bytes;
  }

  bool _sameChains(List<String>? first, List<String> second) =>
      first != null &&
      first.length == second.length &&
      first.every(second.contains);

  void _checkContext(DappFrameContext context, {bool admitting = true}) {
    if (_disposed ||
        !context.isMainFrame ||
        !context.isActive ||
        context.origin.scheme != 'https' ||
        context.origin.host.isEmpty ||
        context.origin.userInfo.isNotEmpty ||
        !(admitting ? isContextCurrent : isRequestCurrent)(context)) {
      throw const DappException(
        4100,
        'Request requires the active HTTPS main frame',
      );
    }
  }

  Future<Map<String, Object?>> _process(
    String id,
    String method,
    Map<String, dynamic> params,
    DappFrameContext context,
    DappWallet wallet,
    void Function() ensureActive,
    Future<void> cancelled,
  ) async {
    final origin = context.canonicalOrigin;
    var granted = await permissions.isGranted(origin, wallet.address);
    ensureActive();
    // A sign-in connects too. Before the user has approved the connection
    // the site may learn nothing about the wallet, so only what holds for
    // any wallet is checked here: a malformed request fails the same way
    // whichever account is active. Whether the request names this account,
    // and whether this wallet can sign it, is answered only once connected.
    final signingIn = method == 'signIn';
    if (signingIn) _writeSignIn(params, context, _anyAddress);
    if (method == 'connect' || signingIn) {
      // A saved grant names an origin whose identity this document's
      // certificate does not prove, so connecting asks again every time.
      if (!granted || context.certificateException) {
        if (!signingIn && params['silent'] == true) {
          return {'accounts': <Object?>[]};
        }
        if (!signingIn && params['onlyIfTrusted'] == true) {
          throw const DappException(4100, 'Connection approval required');
        }
        if (!await approveConnection(
          DappConnectionRequest(
            context: context,
            wallet: wallet,
            cancelled: cancelled,
            ensureActive: ensureActive,
          ),
        )) {
          throw const DappException(4001, 'Connection rejected');
        }
        ensureActive();
        await permissions.grant(
          origin,
          wallet.address,
          ensureActive: ensureActive,
        );
        ensureActive();
        granted = true;
        _rememberCertificateConnection(context, 'solana', wallet);
      }
      if (!signingIn) return _solanaConnection(wallet);
    }
    if (!granted) {
      throw const DappException(4100, 'Connect before requesting a signature');
    }
    _requireCertificateConnection(context, 'solana', wallet);
    final signIn = signingIn ? _signInRequest(params, context, wallet) : null;
    // A view-only wallet's transactions continue to a review it can read but
    // not approve; a message has no simulation to show.
    if (method == 'signMessage' && !wallet.canSignMessages) {
      throw DappException(
        4200,
        wallet.canSign
            ? 'This wallet supports transaction signing, but not message signing'
            : 'This wallet is view-only',
      );
    }
    if (method == 'signOffchainMessage' && !wallet.canSignOffchainMessages) {
      throw DappException(
        4200,
        wallet.canSign
            ? 'This wallet does not support off-chain message signing'
            : 'This wallet is view-only',
      );
    }
    if (params['account'] != null && params['account'] != wallet.address) {
      throw const DappException(
        4100,
        'Requested account does not match the active wallet',
      );
    }
    final chain = params['chain'] ?? 'solana:mainnet';
    if (chain is! String ||
        !{'solana:mainnet', 'solana:devnet'}.contains(chain) ||
        !wallet.chains.contains(chain)) {
      throw const DappException(4901, 'Unsupported Solana network');
    }
    final List<dynamic> encoded;
    if (method == 'signOffchainMessage' || signIn != null) {
      // The wallet builds these bytes itself; nothing encoded to decode.
      encoded = const [];
    } else if (method == 'signAllTransactions') {
      if (params['transactions'] is! List) {
        throw const DappException(-32602, 'Transactions must be an array');
      }
      encoded = params['transactions'] as List;
      if (encoded.isEmpty || encoded.length > kMaxSolanaBatch) {
        throw const DappException(
          -32602,
          'A batch must contain 1 to $kMaxSolanaBatch transactions',
        );
      }
    } else {
      encoded = [params[method == 'signMessage' ? 'message' : 'transaction']];
    }
    final payloads = <Uint8List>[];
    for (final value in encoded) {
      if (value is! String ||
          value.length > (method == 'signMessage' ? 87384 : 16384)) {
        throw const DappException(-32602, 'Invalid payload size');
      }
      final bytes = base64Decode(value);
      if ((bytes.isEmpty && method != 'signMessage') ||
          bytes.length > (method == 'signMessage' ? 65536 : 1232)) {
        throw const DappException(-32602, 'Invalid payload size');
      }
      payloads.add(bytes);
    }
    if (method == 'signOffchainMessage') {
      payloads.add(_offchainMessage(params, wallet.address));
    }
    if (signIn != null) payloads.add(signIn.bytes);
    final options = <String, Object?>{};
    final suppliedOptions = params['options'];
    if (suppliedOptions != null) {
      if (suppliedOptions is! Map) {
        throw const DappException(-32602, 'Invalid options');
      }
      for (final entry in suppliedOptions.entries) {
        if (!{
          'commitment',
          'preflightCommitment',
          'skipPreflight',
          'maxRetries',
          'minContextSlot',
        }.contains(entry.key)) {
          continue;
        }
        final value = entry.value;
        final valid = switch (entry.key) {
          'commitment' || 'preflightCommitment' =>
            value is String &&
                const {'processed', 'confirmed', 'finalized'}.contains(value),
          'skipPreflight' => value is bool,
          'minContextSlot' => value is int && value >= 0,
          'maxRetries' => value is int && value == 0,
          _ => false,
        };
        if (!valid) {
          throw DappException(
            -32602,
            entry.key == 'maxRetries'
                ? 'Automatic broadcast retries are unsupported; maxRetries must be zero'
                : 'Invalid ${entry.key} option',
          );
        }
        options[entry.key as String] = value;
      }
    }
    if (signIn != null) options['offchainMessage'] = signIn.offchainMessage;
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'method': method,
              'chain': chain,
              'wallet': wallet.id,
              'address': wallet.address,
              'payloads': payloads.map(base64Encode).toList(),
              'options': options,
            }),
          ),
        )
        .toString();
    ensureActive();
    // Revocation while waiting for the serial approval lane cannot authorize work.
    if (!await permissions.isGranted(origin, wallet.address)) {
      throw const DappException(4100, 'Connection revoked');
    }
    ensureActive();
    final result = await execute(
      DappSigningRequest(
        id: id,
        method: method,
        context: context,
        wallet: wallet,
        chain: chain,
        payloads: payloads,
        payloadDigest: digest,
        options: options,
        ensureActive: ensureActive,
        cancelled: cancelled,
      ),
    );
    // A sign-in answers with the account it connected, as connect does.
    return signIn == null ? result : {...result, ..._solanaConnection(wallet)};
  }

  Map<String, Object?> _solanaConnection(DappWallet wallet) => {
    'publicKey': wallet.address,
    'chains': wallet.chains,
    'canSign': wallet.canSign,
    'canSignMessages': wallet.canSignMessages,
    'canSignOffchainMessages': wallet.canSignOffchainMessages,
  };

  /// A well-formed address standing in for the wallet's while a sign-in is
  /// checked before the site is connected. Fixed, so that check cannot
  /// depend on the active account.
  static const _anyAddress = '11111111111111111111111111111111';

  /// Writes the message a `signIn` request asks [address] to sign. What it
  /// refuses depends on the request, the page and the clock alone: a field
  /// the sign-in card could not show, an unsupported version, or a validity
  /// window that is closed.
  SolanaSignInRequest _writeSignIn(
    Map<String, dynamic> params,
    DappFrameContext context,
    String address,
  ) {
    final requested = params['address'];
    if (requested != null && requested is! String) {
      throw const DappException(-32602, 'Invalid sign-in address');
    }
    try {
      return SolanaSignInRequest.parse(
        params,
        authority: context.origin.authority,
        address: address,
        now: now(),
      );
    } on FormatException catch (error) {
      throw DappException(-32602, error.message);
    }
  }

  /// The message a `signIn` request asks [wallet] to sign, refused when the
  /// request names another account or asks for a form the wallet cannot
  /// sign: a Ledger signs in only through an off-chain message. Both answers
  /// describe the wallet, so this runs only for a connected site.
  SolanaSignInRequest _signInRequest(
    Map<String, dynamic> params,
    DappFrameContext context,
    DappWallet wallet,
  ) {
    final requested = params['address'];
    if (requested != null && requested != wallet.address) {
      throw const DappException(
        4100,
        'Requested account does not match the active wallet',
      );
    }
    final request = _writeSignIn(params, context, wallet.address);
    final capable = request.offchainMessage
        ? wallet.canSignOffchainMessages
        : wallet.canSignMessages;
    if (!capable) {
      throw DappException(
        4200,
        !wallet.canSign
            ? 'This wallet is view-only'
            : wallet.canSignOffchainMessages
            ? 'This wallet can sign in only with an off-chain message'
            : 'This wallet does not support sign-in',
      );
    }
    return request;
  }

  Future<Map<String, Object?>> _silentEthereum(
    DappWallet? Function() walletFor,
    DappFrameContext context,
  ) async {
    final wallet = walletFor();
    if (wallet == null) {
      return {'accounts': <Object?>[]};
    }
    final epoch = _epoch;
    final granted = await permissions.isGranted(
      context.canonicalOrigin,
      wallet.address,
    );
    if (epoch != _epoch || walletFor()?.address != wallet.address) {
      throw const DappException(4001, 'Request cancelled');
    }
    _checkContext(context, admitting: false);
    if (!granted || context.certificateException) {
      return {'accounts': <Object?>[]};
    }
    return {
      'accounts': [wallet.address],
      'chainId': '0x1',
      'canSign': wallet.canSign,
      'canSignMessages': wallet.canSignMessages,
      'canSignTypedData': wallet.canSignTypedData,
    };
  }

  Future<Object?> _read(Object? raw, DappFrameContext context) async {
    final read = ethereumRead;
    if (read == null) throw const DappException(-32601, 'Unsupported method');
    if (raw is! Map ||
        raw['method'] is! String ||
        (raw['params'] != null && raw['params'] is! List)) {
      throw const DappException(-32602, 'Invalid parameters');
    }
    final method = raw['method'] as String;
    if (!ethereumReadMethods.contains(method)) {
      throw const DappException(4200, 'Unsupported method');
    }
    if (_reads >= 16) throw const DappException(-32005, 'Too many requests');
    _reads++;
    final epoch = _epoch;
    try {
      final result = await read(
        method,
        jsonDecode(jsonEncode(raw['params'] ?? const [])) as List<Object?>,
      );
      if (epoch != _epoch) {
        throw const DappException(4001, 'Request cancelled');
      }
      _checkContext(context, admitting: false);
      return result;
    } finally {
      _reads--;
    }
  }

  Future<Map<String, Object?>> _processEthereum(
    String id,
    String method,
    Map<String, dynamic> params,
    DappFrameContext context,
    DappWallet wallet,
    void Function() ensureActive,
    Future<void> cancelled,
  ) async {
    final origin = context.canonicalOrigin;
    var granted = await permissions.isGranted(origin, wallet.address);
    ensureActive();
    if (method == 'connect') {
      // As for Solana: past a certificate exception, a saved grant does not
      // vouch for this document, so connecting asks again.
      if (!granted || context.certificateException) {
        if (params['silent'] == true) {
          return {'accounts': <Object?>[]};
        }
        if (!await approveConnection(
          DappConnectionRequest(
            context: context,
            wallet: wallet,
            cancelled: cancelled,
            ensureActive: ensureActive,
          ),
        )) {
          throw const DappException(4001, 'Connection rejected');
        }
        ensureActive();
        await permissions.grant(
          origin,
          wallet.address,
          ensureActive: ensureActive,
        );
        ensureActive();
        granted = true;
        _rememberCertificateConnection(context, 'eip155', wallet);
      }
      return {
        'accounts': [wallet.address],
        'chainId': '0x1',
        'canSign': wallet.canSign,
        'canSignMessages': wallet.canSignMessages,
        'canSignTypedData': wallet.canSignTypedData,
      };
    }
    if (!granted) {
      throw const DappException(4100, 'Connect before requesting a signature');
    }
    _requireCertificateConnection(context, 'eip155', wallet);
    if (!wallet.canSign) {
      throw const DappException(4200, 'This wallet is view-only');
    }
    if (!wallet.chains.contains(ethereumMainnet)) {
      throw const DappException(4901, 'Unsupported Ethereum network');
    }
    final account = params['address'];
    if (account != null &&
        (account is! String ||
            account.toLowerCase() != wallet.address.toLowerCase())) {
      throw const DappException(
        4100,
        'Requested account does not match the connected wallet',
      );
    }
    final Uint8List payload;
    switch (method) {
      case 'personal_sign':
        if (!wallet.canSignMessages) {
          throw const DappException(
            4200,
            'This wallet does not support message signing',
          );
        }
        final raw = params['message'];
        if (raw is! String || raw.length > 131074) {
          throw const DappException(-32602, 'Invalid message');
        }
        // Hex is the wire form; anything else is the text a website passed
        // as-is, which is signed as its UTF-8 bytes.
        payload = RegExp(r'^0x([0-9a-fA-F]{2})*$').hasMatch(raw)
            ? Uint8List.fromList([
                for (var i = 2; i < raw.length; i += 2)
                  int.parse(raw.substring(i, i + 2), radix: 16),
              ])
            : Uint8List.fromList(utf8.encode(raw));
        if (payload.length > 65536) {
          throw const DappException(-32602, 'Invalid payload size');
        }
      case 'eth_signTypedData_v4':
        if (!wallet.canSignTypedData) {
          throw const DappException(
            4200,
            'This wallet does not support typed data signing',
          );
        }
        final raw = params['typedData'];
        final text = raw is String ? raw : jsonEncode(raw);
        if (raw == null || text.length > 65536) {
          throw const DappException(-32602, 'Invalid typed data');
        }
        payload = Uint8List.fromList(utf8.encode(text));
      case 'eth_sendTransaction':
        final request = EthereumDappTransactionRequest.parse(
          params['transaction'],
          account: wallet.address,
        );
        payload = Uint8List.fromList(utf8.encode(jsonEncode(request.toJson())));
      default:
        throw const DappException(-32601, 'Unsupported method');
    }
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'method': method,
              'chain': ethereumMainnet,
              'wallet': wallet.id,
              'address': wallet.address,
              'payloads': [base64Encode(payload)],
              'options': const <String, Object?>{},
            }),
          ),
        )
        .toString();
    ensureActive();
    // Revocation while waiting for the serial approval lane cannot authorize work.
    if (!await permissions.isGranted(origin, wallet.address)) {
      throw const DappException(4100, 'Connection revoked');
    }
    ensureActive();
    return execute(
      DappSigningRequest(
        id: id,
        method: method,
        context: context,
        wallet: wallet,
        chain: ethereumMainnet,
        payloads: [payload],
        payloadDigest: digest,
        options: const {},
        ensureActive: ensureActive,
        cancelled: cancelled,
      ),
    );
  }

  Future<Map<String, Object?>> _silentTezos(
    DappWallet? Function() walletFor,
    DappFrameContext context,
  ) async {
    final wallet = walletFor();
    final epoch = _epoch;
    if (wallet == null ||
        context.certificateException ||
        !await permissions.isGranted(context.canonicalOrigin, wallet.address)) {
      return {'accounts': <Object?>[]};
    }
    void active() {
      if (epoch != _epoch ||
          walletFor()?.id != wallet.id ||
          walletFor()?.address != wallet.address) {
        throw const DappException(4001, 'Request cancelled');
      }
      _checkContext(context, admitting: false);
    }

    active();
    // Silent restores must not open a Ledger connection prompt.
    final key = wallet.type == WalletType.ledger
        ? cachedTezosPublicKey?.call(wallet)
        : await tezosPublicKey?.call(wallet, active);
    if (key == null) return {'accounts': <Object?>[]};
    active();
    return {
      'accounts': [wallet.address],
      'address': wallet.address,
      'publicKey': key,
      'network': const {'type': 'mainnet'},
      'canSign': wallet.canSign,
    };
  }

  Future<Map<String, Object?>> _processTezos(
    String id,
    String method,
    Map<String, dynamic> params,
    DappFrameContext context,
    DappWallet wallet,
    void Function() ensureActive,
    Future<void> cancelled,
  ) async {
    // A site may name its own mainnet node in `rpcUrl` (Teia always does).
    // It is only a hint: the wallet forges, simulates and broadcasts through
    // its own node, so the hint is ignored rather than refused.
    final network = params['network'];
    if (!wallet.chains.contains(tezosMainnet) ||
        (network != null &&
            (network is! Map || network['type'] != 'mainnet'))) {
      throw const DappException(4901, 'Only Tezos mainnet is supported');
    }
    final origin = context.canonicalOrigin;
    final granted = await permissions.isGranted(origin, wallet.address);
    ensureActive();
    if (method == 'connect') {
      final requestedScopes =
          params['scopes'] ?? const ['sign', 'operation_request'];
      if (requestedScopes is! List ||
          requestedScopes.any(
            (scope) =>
                scope is! String ||
                !const {'sign', 'operation_request'}.contains(scope),
          )) {
        throw const DappException(
          4200,
          'These Tezos permissions are not supported',
        );
      }
      final scopes = requestedScopes.cast<String>().toSet().toList();
      final existingScopes =
          (await permissions.list())
              .where(
                (grant) =>
                    grant.origin == origin && grant.address == wallet.address,
              )
              .firstOrNull
              ?.scopes ??
          const <String>[];
      ensureActive();
      final needsApproval =
          !granted ||
          context.certificateException ||
          scopes.any((scope) => !existingScopes.contains(scope));
      final keyFor = tezosPublicKey;
      if (keyFor == null || !wallet.canSign) {
        throw const DappException(
          4200,
          'This Tezos wallet does not support browser signing',
        );
      }
      if (needsApproval) {
        if (params['silent'] == true) return {'accounts': <Object?>[]};
        if (!await approveConnection(
          DappConnectionRequest(
            context: context,
            wallet: wallet,
            cancelled: cancelled,
            ensureActive: ensureActive,
          ),
        )) {
          throw const DappException(4001, 'Connection rejected');
        }
        ensureActive();
      }
      final connectKey = connectTezosPublicKey;
      final key = connectKey == null
          ? await keyFor(wallet, ensureActive)
          : await connectKey(wallet, ensureActive, cancelled);
      ensureActive();
      if (needsApproval) {
        await permissions.grant(
          origin,
          wallet.address,
          ensureActive: ensureActive,
          scopes: scopes,
        );
        ensureActive();
        _rememberCertificateConnection(context, 'tezos', wallet);
      }
      ensureActive();
      return {
        'accounts': [wallet.address],
        'address': wallet.address,
        'publicKey': key,
        'network': const {'type': 'mainnet'},
        'canSign': wallet.canSign,
        'scopes': scopes,
      };
    }
    if (!granted)
      throw const DappException(4100, 'Connect before requesting a signature');
    _requireCertificateConnection(context, 'tezos', wallet);
    if (!wallet.canSign)
      throw const DappException(4200, 'This Tezos wallet cannot sign');
    if (params['sourceAddress'] != null &&
        params['sourceAddress'] != wallet.address) {
      throw const DappException(
        4100,
        'Requested account does not match the connected wallet',
      );
    }
    final scope = method == 'signPayload' ? 'sign' : 'operation_request';
    if (!await permissions.hasScope(origin, wallet.address, scope)) {
      throw const DappException(4100, 'This Tezos permission was not granted');
    }
    ensureActive();
    final Uint8List payload;
    final options = <String, Object?>{};
    if (method == 'signPayload') {
      if (!wallet.canSignMessages)
        throw const DappException(4200, 'Message signing is unavailable');
      final hex = params['payload'];
      final signingType = params['signingType'] ?? 'raw';
      if (hex is! String ||
          hex.length > 131072 ||
          !RegExp(r'^(?:[0-9a-fA-F]{2})+$').hasMatch(hex) ||
          signingType is! String) {
        throw const DappException(-32602, 'Invalid Tezos message');
      }
      payload = Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
      TezosMessageReview(
        payload: payload,
        origin: origin,
        address: wallet.address,
        walletId: wallet.id,
        signingType: signingType,
      );
      options['signingType'] = signingType;
    } else {
      final operations = TezosDappOperationRequest.parse(
        params['operationDetails'],
        account: wallet.address,
      );
      payload = Uint8List.fromList(
        utf8.encode(jsonEncode(operations.toJson())),
      );
    }
    ensureActive();
    if (!await permissions.isGranted(origin, wallet.address))
      throw const DappException(4100, 'Connection revoked');
    ensureActive();
    return execute(
      DappSigningRequest(
        id: id,
        method: method,
        context: context,
        wallet: wallet,
        chain: tezosMainnet,
        payloads: [payload],
        payloadDigest: sha256
            .convert(
              utf8.encode(
                jsonEncode({
                  'method': method,
                  'chain': tezosMainnet,
                  'wallet': wallet.id,
                  'address': wallet.address,
                  'payload': base64Encode(payload),
                  'options': options,
                }),
              ),
            )
            .toString(),
        options: options,
        ensureActive: ensureActive,
        cancelled: cancelled,
      ),
    );
  }

  Future<Map<String, Object?>> _processBeacon(
    Map<String, dynamic> message,
    DappFrameContext context,
  ) async {
    final type = message['type'];
    final method = switch (type) {
      'permission_request' => 'connect',
      'sign_payload_request' => 'signPayload',
      'operation_request' => 'sendOperations',
      'disconnect' => 'disconnect',
      _ => null,
    };
    if (method == null) return {'type': 'error', 'errorType': 'UNKNOWN_ERROR'};
    // The dapp's metadata and sender id never replace native frame provenance.
    final response = await handle({
      'id': message['id'],
      'namespace': 'tezos',
      'method': method,
      'params': message,
    }, context);
    if (response['error'] case final Map<Object?, Object?> error) {
      return {
        'type': 'error',
        'errorType': switch (error['code']) {
          4001 => 'ABORTED_ERROR',
          4100 => 'NOT_GRANTED_ERROR',
          4901 => 'NETWORK_NOT_SUPPORTED',
          -32602 => 'PARAMETERS_INVALID_ERROR',
          _ =>
            type == 'operation_request'
                ? 'TRANSACTION_INVALID_ERROR'
                : 'UNKNOWN_ERROR',
        },
      };
    }
    final result = response['result'] as Map;
    return switch (type) {
      'permission_request' => {
        'type': 'permission_response',
        'publicKey': result['publicKey'],
        'network': result['network'],
        'scopes': result['scopes'],
        'appMetadata': const {'name': 'mallow'},
      },
      'sign_payload_request' => {
        'type': 'sign_payload_response',
        'signature': result['signature'],
        'signingType': message['signingType'] ?? 'raw',
      },
      'operation_request' => {
        'type': 'operation_response',
        'transactionHash': result['hash'],
      },
      _ => {'type': 'disconnect'},
    };
  }
}
