import 'dart:convert';
import 'dart:math' show max;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import '../../../core/config/environment.dart';
import '../../../core/crypto/ed25519_verify.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/data/mallow_tokens.dart'
    show isRegistryMint, mallowTokenMints, tokenByMint;
import '../../../core/network/kept_alive_http.dart';
import '../../../core/models/simulation_review.dart';
import '../../../core/services/program_label_service.dart';
import '../models/dapp_message_review.dart';
import '../models/dapp_request.dart';
import '../models/solana_offchain_message.dart';
import 'solana_asset_instructions.dart';
import 'solana_dapp_transaction.dart';
import 'browser_transaction_tracker.dart';
import 'solana_lookup_table_cache.dart';

export 'solana_asset_instructions.dart' show solanaCoreProgram;

const solanaSystemProgram = '11111111111111111111111111111111';
const _computeBudgetProgram = 'ComputeBudget111111111111111111111111111111';
const solanaTokenProgram = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const solanaToken2022Program = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
const solanaNativeMint = 'So11111111111111111111111111111111111111112';
const _lookupProgram = 'AddressLookupTab1e1111111111111111111111111';
const _memoPrograms = {
  'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr',
  'Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo',
  'Memo4c2pN8afCj432Lb7RMVKi9PbQnnW7ewFFaV3oAH',
};
const _sol = ReviewAsset(id: solanaNativeMint, symbol: 'SOL', decimals: 9);

/// A [SimulationReview.warnings] entry: the wallet signs for an instruction
/// of a program this review has no reader for, so what the review lists is
/// not all the transaction can do.
const kSolanaUnreadProgramsWarning =
    'Some instructions you sign for could not be read. The programs they run can change assets or permissions that are not shown here.';

const _lookupsUnresolvedWarning =
    'Address lookup tables could not be resolved. Some affected accounts are unknown.';

/// The name a compressed NFT goes by when no asset lookup named it.
const _compressedNftName = 'Compressed NFT';

/// A name its creator chose, as the review may show it, or null when
/// [value] is no text or nothing readable is left of it.
///
/// An NFT's name comes from metadata anyone can write, and the review draws
/// it inside its own rows and card titles. So it is made one short line of
/// plain text before it enters the review: no control characters; none of
/// the characters that change the direction text is drawn in, which could
/// reorder the words around the name; no characters that take up no width,
/// which could make a name that looks empty; line breaks and tabs become one
/// space; and it is cut at [max] characters, with an ellipsis.
String? solanaCreatorText(Object? value, {int max = 64}) {
  if (value is! String) return null;
  final kept = <int>[];
  for (final rune in value.runes) {
    final lineBreakOrTab =
        (rune >= 0x09 && rune <= 0x0D) ||
        rune == 0x85 ||
        rune == 0x2028 ||
        rune == 0x2029;
    final dropped =
        // C0 and C1 controls.
        rune <= 0x1F ||
        (rune >= 0x7F && rune <= 0x9F) ||
        // Direction marks, embeddings, overrides and isolates.
        rune == 0x061C ||
        rune == 0x200E ||
        rune == 0x200F ||
        (rune >= 0x202A && rune <= 0x202E) ||
        (rune >= 0x2066 && rune <= 0x2069) ||
        // Zero-width space, word joiner and byte-order mark.
        rune == 0x200B ||
        rune == 0x2060 ||
        rune == 0xFEFF ||
        // Half of a surrogate pair on its own, which is no character and
        // which text layout refuses to draw.
        (rune >= 0xD800 && rune <= 0xDFFF);
    if (lineBreakOrTab || rune == 0x20) {
      if (kept.isNotEmpty && kept.last != 0x20) kept.add(0x20);
    } else if (!dropped) {
      kept.add(rune);
    }
  }
  if (kept.isNotEmpty && kept.last == 0x20) kept.removeLast();
  final cleaned = String.fromCharCodes(kept).trim();
  // Joiners shape the letters or emoji beside them and show nothing alone.
  if (cleaned.runes.every((rune) => rune == 0x200C || rune == 0x200D)) {
    return null;
  }
  final runes = cleaned.runes;
  return runes.length > max
      ? '${String.fromCharCodes(runes.take(max)).trimRight()}…'
      : cleaned;
}

/// The most transactions of one batch the review simulates. A larger batch is
/// still reviewed and signed as a whole, with a warning that its effects were
/// not checked.
const kMaxSimulatedSolanaBatch = 10;

/// Symbols of the tokens the app knows, lower-cased: an unverified token
/// claiming one is shown without its metadata (see [ReviewTokenMetadata]).
final Set<String> _reservedSymbols = {
  'sol',
  for (final mint in mallowTokenMints) ?tokenByMint(mint)?.symbol.toLowerCase(),
};

typedef DappRpc =
    Future<Object?> Function(String chain, String method, List<Object?> params);

/// Only the structured RPC code is retained; server messages can contain
/// payloads or service configuration and are never surfaced verbatim.
class SolanaDappRpcException implements Exception {
  const SolanaDappRpcException(this.code);
  final int code;
  bool get rejectedBeforeBroadcast =>
      const {-32002, -32003, -32602}.contains(code);
}

class SolanaDappSendOptions {
  const SolanaDappSendOptions({
    this.skipPreflight = false,
    this.preflightCommitment = 'confirmed',
    this.minContextSlot,
  });
  final bool skipPreflight;
  final String preflightCommitment;
  final int? minContextSlot;
  factory SolanaDappSendOptions.fromMap(Map<String, Object?> options) {
    const commitments = {'processed', 'confirmed', 'finalized'};
    for (final key in ['commitment', 'preflightCommitment']) {
      if (options.containsKey(key) && !commitments.contains(options[key]))
        throw const DappException(-32602, 'Invalid commitment.');
    }
    if (options.containsKey('skipPreflight') &&
        options['skipPreflight'] is! bool)
      throw const DappException(-32602, 'skipPreflight must be a boolean.');
    final slot = options['minContextSlot'];
    if (options.containsKey('minContextSlot') && (slot is! int || slot < 0))
      throw const DappException(
        -32602,
        'minContextSlot must be a nonnegative integer.',
      );
    if (options.containsKey('maxRetries') &&
        (options['maxRetries'] is! int || options['maxRetries'] != 0))
      throw const DappException(
        -32602,
        'mallow does not automatically retry broadcasts; maxRetries must be zero.',
      );
    return SolanaDappSendOptions(
      skipPreflight: options['skipPreflight'] as bool? ?? false,
      preflightCommitment:
          (options['preflightCommitment'] ??
                  options['commitment'] ??
                  'confirmed')
              as String,
      minContextSlot: slot as int?,
    );
  }
  Map<String, Object?> toRpc() => {
    'encoding': 'base64',
    'skipPreflight': skipPreflight,
    'preflightCommitment': preflightCommitment,
    if (minContextSlot != null) 'minContextSlot': minContextSlot,
    'maxRetries': 0,
  };
}

class PreparedSolanaTransaction {
  PreparedSolanaTransaction(Uint8List bytes, this.review)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final Uint8List bytes;
  final SimulationReview review;
}

/// A batch approved with one review: each transaction keeps its own review
/// for signing, and [review] combines them for display (see
/// [combineSolanaReviews]).
class PreparedSolanaBatch {
  PreparedSolanaBatch(List<PreparedSolanaTransaction> transactions, this.review)
    : transactions = List.unmodifiable(transactions);
  final List<PreparedSolanaTransaction> transactions;
  final SimulationReview review;
}

class SolanaMessageReview extends DappMessageReview {
  SolanaMessageReview({
    required Uint8List bytes,
    required this.origin,
    required this.address,
    required this.walletId,
    required this.chain,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  @override
  final Uint8List bytes;
  @override
  final String origin;
  @override
  final String address;
  final String walletId;
  final String chain;
  @override
  String get digestLabel => 'SHA-256';
  @override
  String get digest => sha256.convert(bytes).toString();

  /// Sign In With Solana fields; see [parseSignInMessage].
  @override
  Map<String, String> get signInFields => _signIn?.fields ?? const {};

  @override
  String? get signInStatement => _signIn?.statement;

  SignInMessage? get _signIn => parseSignInMessage(
    text,
    address: address,
    chain: 'Solana',
    resourceList: true,
  );
}

/// A `solana:signOffchainMessage` request. [bytes] is the whole version 1
/// message the wallet built, which is what gets signed and what the exact
/// bytes and digest show; the review reads the site's text and signers from
/// [message].
class SolanaOffchainMessageReview extends SolanaMessageReview {
  SolanaOffchainMessageReview({
    required this.message,
    required super.origin,
    required super.address,
    required super.walletId,
    required super.chain,
  }) : super(bytes: message.bytes);
  final SolanaOffchainMessage message;

  @override
  String get text => message.content;

  @override
  List<String> get coSigners => [
    for (final signer in message.signers)
      if (signer != address) signer,
  ];

  // A sign-in proves one wallet's ownership; with other signers required it
  // is something else, so it gets the plain message review.
  @override
  Map<String, String> get signInFields =>
      coSigners.isEmpty ? super.signInFields : const {};

  @override
  String? get signInStatement =>
      coSigners.isEmpty ? super.signInStatement : null;
}

/// The browser owns its RPC transport so the dapp's cluster never accidentally
/// follows the app environment. Requests contain no app API credentials.
class SolanaDappAdapter {
  SolanaDappAdapter({
    required this.walletManager,
    DappRpc? rpc,
    BrowserTransactionTracker? tracker,
    SolanaLookupTableCache? lookupTables,
  }) : _rpc = rpc ?? _defaultRpc,
       _tracker = tracker ?? BrowserTransactionTracker.instance,
       _lookupTables = lookupTables ?? SolanaLookupTableCache.instance;
  final WalletManager walletManager;
  final DappRpc _rpc;
  final BrowserTransactionTracker _tracker;
  final SolanaLookupTableCache _lookupTables;

  /// Where [sendSigned] and [watchSigned] record receipts.
  BrowserTransactionTracker get tracker => _tracker;

  /// The JSON-RPC transport this adapter reads the chain through.
  DappRpc get rpc => _rpc;

  static void validateChain(String chain) {
    if (chain != 'solana:mainnet' &&
        !(chain == 'solana:devnet' && !Config.isProduction)) {
      throw const DappException(4901, 'Unsupported Solana network.');
    }
  }

  static String rpcUrl(String chain) {
    validateChain(chain);
    if (chain == 'solana:mainnet') return Config.solanaMainnetRpcUrl;
    return 'https://api.devnet.solana.com';
  }

  /// Where NFT and token metadata is looked up. Plain nodes, including both
  /// [rpcUrl] defaults, answer `getAssetBatch` with nulls rather than an
  /// error, so a review there silently loses every NFT's name and image. The
  /// RPC proxy serves DAS for either cluster; devnet is selected the same way
  /// as [Config.solanaRpcUrl] does, merged into any query the base carries.
  static String dasUrl(String chain) {
    validateChain(chain);
    return _onCluster(Config.rpcProxyBaseUrl, chain);
  }

  /// Where a review's own reads go ([simulationMethods]): the endpoint near
  /// the user that [Config.solanaSimulationUrl] names, or null when the build
  /// names none and they share [rpcUrl] and [dasUrl] with everything else.
  static String? simulationUrl(String chain) {
    validateChain(chain);
    final base = Config.solanaSimulationUrl;
    return base.isEmpty ? null : _onCluster(base, chain);
  }

  /// The reads [prepareTransaction] makes, which [simulationUrl] serves.
  static const simulationMethods = {
    'simulateTransaction',
    'getMultipleAccounts',
    'getAssetBatch',
    'getFeeForMessage',
  };

  /// [base] for [chain]: devnet is selected with `network=devnet`, merged
  /// into any query the base carries, as [Config.solanaRpcUrl] does.
  static String _onCluster(String base, String chain) {
    final uri = Uri.parse(base);
    if (chain == 'solana:mainnet') return uri.toString();
    return uri
        .replace(
          queryParameters: {
            ...uri.queryParametersAll,
            'network': const ['devnet'],
          },
        )
        .toString();
  }

  /// One client for every adapter, so a review's calls reuse kept-alive
  /// connections instead of each paying for its own TLS handshake. The
  /// browser builds an adapter per request.
  static final _dio = keptAliveDio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  /// The client for [simulationUrl]. It gives up on connecting sooner, since
  /// a review that cannot reach it still has [_dio]'s path to fall back to.
  static final _simulationDio = keptAliveDio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  static Future<Object?> _defaultRpc(
    String chain,
    String method,
    List<Object?> params,
  ) async {
    final simulation = simulationMethods.contains(method)
        ? simulationUrl(chain)
        : null;
    if (simulation != null) {
      try {
        return await _post(_simulationDio, simulation, method, params);
      } on DioException {
        // Unreachable, refusing or rate-limited: the call goes the usual
        // way, which costs this review time rather than its simulation.
      } on FormatException {
        // Not a JSON-RPC answer; likewise.
      }
    }
    return _post(
      _dio,
      method == 'getAssetBatch' ? dasUrl(chain) : rpcUrl(chain),
      method,
      params,
    );
  }

  static Future<Object?> _post(
    Dio dio,
    String url,
    String method,
    List<Object?> params,
  ) async {
    final response = await dio.post<Object?>(
      url,
      data: {
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': method == 'getAssetBatch' ? {'ids': params.first} : params,
      },
      options: Options(headers: Config.clientIdHeadersFor(Uri.parse(url))),
    );
    final body = _map(response.data);
    if (body['error'] != null) {
      final code = _map(body['error'])['code'];
      throw SolanaDappRpcException(code is int ? code : -32000);
    }
    if (!body.containsKey('result')) throw const FormatException();
    return body['result'];
  }

  /// Opens the connections a mainnet review reads through, as many to each
  /// host as the review has calls in flight there at once: the simulation,
  /// the account read and the DAS batch.
  static Future<void> warmConnections() async {
    const chain = 'solana:mainnet';
    final simulation = simulationUrl(chain);
    if (simulation != null) {
      await openConnections(
        dioHead(_simulationDio),
        simulation,
        connections: 3,
      );
      return;
    }
    await Future.wait([
      openConnections(dioHead(_dio), rpcUrl(chain), connections: 2),
      openConnections(dioHead(_dio), dasUrl(chain)),
    ]);
  }

  SolanaMessageReview prepareMessage({
    required Uint8List bytes,
    required String origin,
    required String address,
    required String walletId,
    required String chain,
  }) {
    validateChain(chain);
    if (bytes.length > 65536)
      throw const DappException(-32602, 'Message is too large.');
    if (isSolanaSigningPayload(bytes))
      throw const DappException(
        -32602,
        'Use transaction signing for a Solana transaction.',
      );
    return SolanaMessageReview(
      bytes: bytes,
      origin: origin,
      address: address,
      walletId: walletId,
      chain: chain,
    );
  }

  /// Reads back the off-chain message the coordinator built, so the review
  /// shows exactly the bytes that will be signed.
  SolanaOffchainMessageReview prepareOffchainMessage({
    required Uint8List bytes,
    required String origin,
    required String address,
    required String walletId,
    required String chain,
  }) {
    validateChain(chain);
    final SolanaOffchainMessage message;
    try {
      message = SolanaOffchainMessage.parse(bytes);
    } on FormatException {
      throw const DappException(-32602, 'Invalid off-chain message.');
    }
    if (!message.signers.contains(address))
      throw const DappException(
        -32602,
        'The required signers must include the connected account.',
      );
    return SolanaOffchainMessageReview(
      message: message,
      origin: origin,
      address: address,
      walletId: walletId,
      chain: chain,
    );
  }

  /// Signs [review]'s exact bytes: a site's raw message, or a whole off-chain
  /// message the wallet built.
  Future<Uint8List> signMessage(
    SolanaMessageReview review, {
    required void Function() ensureActive,
    Future<void>? cancelled,
  }) async {
    ensureActive();
    final result = await walletManager.signMessageForWallet(
      review.walletId,
      review.bytes,
      expectedAddress: review.address,
      ensureActive: ensureActive,
      cancelled: cancelled,
    );
    ensureActive();
    await verifyDappSignature(review.bytes, result.bytes, review.address);
    ensureActive();
    return Uint8List.fromList(result.bytes);
  }

  /// Signs a reviewed transaction. The review expires two minutes after its
  /// simulation; [approvedAt] measures that to the moment the user approved,
  /// so a batch whose later transactions wait on a hardware signer is judged
  /// by its one approval, not by how long signing takes.
  Future<Uint8List> signPrepared(
    PreparedSolanaTransaction prepared, {
    required void Function() ensureActive,
    Future<void>? cancelled,
    DateTime? approvedAt,
  }) async {
    ensureActive();
    if ((approvedAt ?? DateTime.now()).difference(prepared.review.simulatedAt) >
        const Duration(minutes: 2))
      throw const DappException(
        4001,
        'Review expired. Request a new transaction.',
      );
    if (sha256.convert(prepared.bytes).toString() !=
        prepared.review.payloadDigest)
      throw const DappException(-32602, 'Transaction changed after review.');
    final tx = parseDappTransaction(
      prepared.bytes,
      signer: prepared.review.address,
    );
    final signed = await walletManager.signCompiledTx(
      unsignedTx: tx,
      walletId: prepared.review.walletId,
      expectedAddress: prepared.review.address,
      ensureActive: ensureActive,
      cancelled: cancelled,
    );
    ensureActive();
    const equality = ListEquality<int>();
    if (!equality.equals(
          tx.compiledMessage.toByteArray().toList(),
          signed.compiledMessage.toByteArray().toList(),
        ) ||
        signed.signatures.length != tx.signatures.length) {
      throw const DappException(
        -32602,
        'Signed transaction does not match the reviewed transaction.',
      );
    }
    for (var i = 0; i < tx.signatures.length; i++) {
      final address = tx.compiledMessage.accountKeys[i].toBase58();
      if (address == prepared.review.address) {
        await verifyDappSignature(
          tx.compiledMessage.toByteArray().toList(),
          signed.signatures[i].bytes,
          address,
        );
      } else if (!equality.equals(
        tx.signatures[i].bytes,
        signed.signatures[i].bytes,
      )) {
        throw const DappException(-32602, 'An existing co-signature changed.');
      }
    }
    ensureActive();
    return Uint8List.fromList(signed.toByteArray().toList());
  }

  /// Follows a transaction this wallet signed for a website to broadcast,
  /// so it reaches the recent transactions once the network sees it. Skipped
  /// when the fee payer's signature is still missing: the transaction's id
  /// is not known until someone else signs.
  void watchSigned(Uint8List bytes, String chain) {
    final tx = parseDappTransaction(bytes);
    if (tx.signatures.isEmpty ||
        tx.signatures.first.bytes.every((b) => b == 0)) {
      return;
    }
    _tracker.watchSigned(
      signature: tx.id,
      chain: chain,
      lookup: (chain, signature) => _rpc(chain, 'getSignatureStatuses', [
        [signature],
        {'searchTransactionHistory': true},
      ]),
    );
  }

  Future<String> sendSigned(
    Uint8List bytes,
    String chain, {
    Map<String, Object?> options = const {},
  }) async {
    validateChain(chain);
    final sendOptions = SolanaDappSendOptions.fromMap(options);
    final tx = parseDappTransaction(bytes);
    if (tx.signatures.any((s) => s.bytes.every((b) => b == 0)))
      throw const DappException(
        -32602,
        'Transaction is missing another required signature.',
      );
    _tracker.start(
      signature: tx.id,
      chain: chain,
      lookup: (chain, signature) => _rpc(chain, 'getSignatureStatuses', [
        [signature],
        {'searchTransactionHistory': true},
      ]),
    );
    try {
      final result = await _rpc(chain, 'sendTransaction', [
        base64Encode(bytes),
        sendOptions.toRpc(),
      ]);
      if (result is! String || result != tx.id) throw const FormatException();
      return result;
    } on SolanaDappRpcException catch (error) {
      if (error.rejectedBeforeBroadcast) {
        _tracker.markRejected(chain, tx.id);
        throw const DappException(
          -32000,
          'The RPC rejected this submission before broadcast. Request a new transaction or ask the website to change its submission options.',
        );
      }
      _tracker.markUncertain(chain, tx.id);
      throw DappException(
        -32000,
        'Broadcast status is uncertain. Check transaction ${tx.id} before trying again.',
      );
    } catch (_) {
      _tracker.markUncertain(chain, tx.id);
      // Submission may already have reached the network. Never auto-retry.
      throw DappException(
        -32000,
        'Broadcast status is uncertain. Check transaction ${tx.id} before trying again.',
      );
    }
  }

  /// A transaction reviewed without simulating it, for a batch larger than
  /// [kMaxSimulatedSolanaBatch]: no RPC is called, so the review holds what
  /// the transaction's own bytes ask for, its program calls and its Explorer
  /// link. It is checked and signed like any other.
  /// [describeUnsimulated], on this adapter: what an approval given before
  /// the review signs.
  PreparedSolanaTransaction describeTransaction({
    required Uint8List transaction,
    required String walletId,
    required String address,
    required String origin,
    required String chain,
  }) => describeUnsimulated(
    transaction: transaction,
    walletId: walletId,
    address: address,
    origin: origin,
    chain: chain,
  );

  static PreparedSolanaTransaction describeUnsimulated({
    required Uint8List transaction,
    required String walletId,
    required String address,
    required String origin,
    required String chain,
  }) {
    validateChain(chain);
    final frozen = Uint8List.fromList(transaction).asUnmodifiableView();
    final tx = parseDappTransaction(frozen, signer: address);
    final message = tx.compiledMessage;
    final keys = message.accountKeys.map((k) => k.toBase58()).toList();
    // Whoever asks for the signature can make a simulation unavailable (a
    // batch too large to simulate, a node kept busy), so an unsimulated
    // transaction is still read: the transfers the wallet makes, the
    // compressed NFTs it sends and the permissions it gives are in its
    // bytes. An account loaded from a lookup table cannot be named with no
    // node to ask, and the review says so.
    final warnings = <String>[];
    final funds = <FundChange>[];
    final accounts = <AccountChange>[];
    final nfts = <NftChange>[];
    decodeSolanaInstructions(
      tx,
      keys,
      const {},
      funds,
      accounts,
      warnings,
      address,
      nfts: nfts,
    );
    if (message is CompiledMessageV0 &&
        message.addressTableLookups.isNotEmpty) {
      warnings.add(_lookupsUnresolvedWarning);
    }
    if (solanaSignsUnreadProgram(tx, keys, address)) {
      warnings.add(kSolanaUnreadProgramsWarning);
    }
    return PreparedSolanaTransaction(
      frozen,
      SimulationReview(
        explorerUrl: _inspectorUrl(chain, tx),
        // Program ids always sit in the static keys; parsing enforces it.
        programCalls: solanaProgramCalls(
          solanaInvocations(message.instructions, keys),
        ),
        nftMetadata: {
          for (final id in _coreDelegatedAssetIds(accounts))
            id: const ReviewNftMetadata(),
          for (final id in _compressedAssetIds(accounts, nfts))
            id: const ReviewNftMetadata(name: _compressedNftName),
        },
        payloadDigest: sha256.convert(frozen).toString(),
        origin: origin,
        walletId: walletId,
        address: address,
        chain: chain,
        simulatedAt: DateTime.now().toUtc(),
        execution: SimulationExecution.unavailable,
        coverage: SimulationCoverage.unavailable,
        feePayer: keys.first,
        error: 'Simulation is unavailable.',
        warnings: warnings.toSet().toList(),
        funds: funds,
        accounts: accounts,
        nfts: nfts,
      ),
    );
  }

  Future<PreparedSolanaTransaction> prepareTransaction({
    required Uint8List transaction,
    required String walletId,
    required String address,
    required String origin,
    required String chain,
  }) async {
    validateChain(chain);
    final frozen = Uint8List.fromList(transaction).asUnmodifiableView();
    final tx = parseDappTransaction(frozen, signer: address);
    final keys = tx.compiledMessage.accountKeys
        .map((k) => k.toBase58())
        .toList();
    final warnings = <String>[];
    final funds = <FundChange>[];
    final accounts = <AccountChange>[];
    final nfts = <NftChange>[];
    final programCalls = <ReviewProgramCall>[];
    final nftMetadata = <String, ReviewNftMetadata>{};
    final tokenMetadata = <String, ReviewTokenMetadata>{};
    final singleSupply = <String>{};
    var delegatedBy = const <String, Set<String>>{};
    var execution = SimulationExecution.unavailable;
    var effectsUndecodable = false;
    // Whether the transaction's own instructions have been read yet.
    var decoded = false;
    int? slot;
    int? fee;
    var complete = false;
    // Both snapshots cover every inspected account, at one slot.
    var snapshotComplete = false;
    var tokenDecimals = const <String, int>{};
    Future<List<Map<String, Object?>>?> inspectedAssets = Future.value();
    var inspectedKeys = const <String>{};
    String? error;
    try {
      final message = tx.compiledMessage;
      if (message is CompiledMessageV0 &&
          message.addressTableLookups.isNotEmpty) {
        try {
          keys.addAll(
            await _resolveLookups(chain, message.addressTableLookups),
          );
        } catch (_) {
          warnings.add(_lookupsUnresolvedWarning);
        }
      }
      // Include the signer first even when the transaction has over 100 accounts.
      final inspected = <String>{address, ...keys}.take(100).toList();
      if (keys.length > 100)
        warnings.add(
          'Only the first 100 affected accounts could be inspected.',
        );
      // The simulation does not wait for the read of the accounts before it:
      // both go out at once, and the slots they report are compared below.
      // The read stays, because the simulation's own pre-balances carry
      // amounts only, not the delegate, freeze state or Core owner the review
      // compares.
      final simulation = _rpc(chain, 'simulateTransaction', [
        base64Encode(frozen),
        {
          'encoding': 'base64',
          'sigVerify': false,
          'replaceRecentBlockhash': false,
          'commitment': 'confirmed',
          'innerInstructions': true,
          'accounts': {'encoding': 'base64', 'addresses': inspected},
        },
      ]);
      // Awaited after the read: until then a failure is held for that await,
      // not reported as unhandled.
      simulation.ignore();
      // The assets the review will name are, nearly always, among the
      // accounts it inspects: a token's mint and a Core asset are accounts of
      // the instructions that move them. So DAS is asked for all of them now,
      // alongside the simulation, rather than after it for those it moved; a
      // DAS record names only accounts that are assets. A transaction of
      // System and compute-budget calls alone moves no asset to ask about.
      if (!message.instructions.every(
        (ix) => const {
          solanaSystemProgram,
          _computeBudgetProgram,
        }.contains(keys[ix.programIdIndex]),
      )) {
        inspectedKeys = inspected.where((key) => key != address).toSet();
        inspectedAssets = _assetBatch(chain, inspectedKeys.toList());
      }
      Map<String, Object?> before = const {};
      try {
        before = _map(
          await _rpc(chain, 'getMultipleAccounts', [
            inspected,
            {'encoding': 'base64', 'commitment': 'confirmed'},
          ]),
        );
      } catch (_) {
        warnings.add('Balances before simulation are unavailable.');
      }
      final beforeSlot = _map(before['context'])['slot'] as int?;
      final preList = before['value'] is List
          ? before['value'] as List
          : const <Object?>[];
      final pre = <String, Map<String, Object?>>{};
      for (var i = 0; i < inspected.length && i < preList.length; i++) {
        pre[inspected[i]] = _map(preList[i]);
      }
      decoded = true;
      decodeSolanaInstructions(
        tx,
        keys,
        pre,
        funds,
        accounts,
        warnings,
        address,
        nfts: nfts,
      );
      final result = _map(await simulation);
      slot = _map(result['context'])['slot'] as int?;
      final value = _map(result['value']);
      // The node names the addresses the tables loaded. Ones that differ from
      // the read (or the cache) mean the review inspected other accounts.
      if (message is CompiledMessageV0 &&
          message.addressTableLookups.isNotEmpty) {
        final loaded = _map(value['loadedAddresses']);
        if (loaded['writable'] is List && loaded['readonly'] is List) {
          final reported = [
            ...loaded['writable'] as List,
            ...loaded['readonly'] as List,
          ];
          final resolved = keys.sublist(tx.compiledMessage.accountKeys.length);
          if (!const ListEquality<Object?>().equals(reported, resolved)) {
            for (final lookup in message.addressTableLookups) {
              _lookupTables.forget(chain, lookup.accountKey.toBase58());
            }
            warnings.add(_lookupsUnresolvedWarning);
          }
        }
      }
      // Inner instructions, by the top-level instruction that made them.
      final inner = <int, List<SolanaInnerInstruction>>{};
      for (final raw in value['innerInstructions'] as List? ?? const []) {
        final group = _map(raw);
        final index = group['index'];
        if (index is! int) continue;
        for (final call in group['instructions'] as List? ?? const []) {
          final parsed = parseSimulationInnerInstruction(_map(call), keys);
          if (parsed != null) inner.putIfAbsent(index, () => []).add(parsed);
        }
      }
      programCalls.addAll(
        parseSimulationProgramCalls(
          (value['logs'] as List?)?.whereType<String>().toList() ?? const [],
          invocations: solanaInvocations(
            tx.compiledMessage.instructions,
            keys,
            inner,
          ),
        ),
      );
      if (!value.containsKey('err')) throw const FormatException();
      execution = value['err'] == null
          ? SimulationExecution.succeeded
          : SimulationExecution.failed;
      if (execution == SimulationExecution.failed) {
        // Error is bounded and displayed only locally, never logged.
        final detail = jsonEncode(value['err']);
        error =
            'Simulation failed: ${detail.length > 400 ? detail.substring(0, 400) : detail}';
      } else {
        // Amounts come from the simulation's own balances where the node
        // reports them: every account, at the slot that ran the transaction.
        // The read of the accounts before then serves only the state it alone
        // carries (delegates, freezes, Core owners).
        final simulated = _simulatedAmounts(value, tx, address);
        if (simulated != null) {
          funds.addAll(simulated);
        } else if (beforeSlot != slot) {
          warnings.add(kSimulationSnapshotSlotsWarning);
        }
        delegatedBy = solanaDelegationOrigins(
          tx.compiledMessage.instructions,
          keys,
          inner,
        );
        // Inner instructions carry token actions performed by other programs,
        // and the moves no balance of the wallet's shows: a compressed NFT, a
        // stake account, a program's authority. A call the node parsed itself
        // has no data left to decode; the account reads below still catch
        // what a token call changed, and the fields the node names say what a
        // stake, loader or System call did.
        final innerFunds = <FundChange>[];
        for (final call in inner.values.expand((calls) => calls)) {
          try {
            if (call.instruction == null) {
              if (call.program == solanaSystemProgram) {
                _applyParsedSystemCall(
                  call.parsed,
                  address,
                  innerFunds,
                  accounts,
                  warnings,
                );
                continue;
              }
              final effect = decodeParsedSolanaAssetInstruction(
                call.program,
                call.parsed,
                address,
              );
              if (effect != null) {
                _applyAssetEffect(
                  effect,
                  address,
                  true,
                  innerFunds,
                  accounts,
                  nfts,
                  warnings,
                );
              }
              continue;
            }
            decodeSolanaInstructions(
              tx,
              keys,
              pre,
              innerFunds,
              accounts,
              warnings,
              address,
              instructions: [call.instruction!],
              nfts: nfts,
            );
          } catch (_) {
            // State deltas remain available when an inner call is malformed.
          }
        }
        // The simulation's balances already count what an inner call moved
        // in or out of the wallet. What it moved out of another account the
        // wallet controls is in no balance of the wallet's, so it is kept.
        funds.addAll(innerFunds.where((f) => _isOffBalance(f, address)));
        for (var i = 0; i < funds.length; i++) {
          final fund = funds[i];
          if (fund.isNet || !_isOffBalance(fund, address)) continue;
          // Shown beside the simulated changes, which the review prefers to
          // requested ones: these are the part of the outcome it cannot see.
          funds[i] = FundChange(
            asset: fund.asset,
            address: fund.address,
            rawAmount: fund.rawAmount,
            evidence: fund.evidence,
            from: fund.from,
            to: fund.to,
            isNet: true,
          );
        }
        final postList = value['accounts'] is List
            ? value['accounts'] as List
            : const <Object?>[];
        for (var i = 0; i < inspected.length && i < postList.length; i++) {
          final key = inspected[i];
          final old = pre[key];
          final next = _map(postList[i]);
          if (old == null) continue;
          if (simulated == null &&
              key == address &&
              (old['lamports'] is int || next['lamports'] is int)) {
            final delta = BigInt.from(
              (next['lamports'] as int? ?? 0) - (old['lamports'] as int? ?? 0),
            );
            funds.add(
              FundChange(
                asset: _sol,
                address: key,
                rawAmount: delta,
                evidence: ReviewEvidence.simulatedState,
                isNet: true,
              ),
            );
          }
          nfts.addAll(decodeCoreAssetDelta(key, old, next, address));
          final core = _coreState(next) ?? _coreState(old);
          if (core != null)
            nftMetadata[key] = ReviewNftMetadata(
              name: solanaCreatorText(core.name),
            );
          final oldToken = _tokenState(old);
          final nextToken = _tokenState(next);
          final token = oldToken ?? nextToken;
          if (token == null ||
              (oldToken?.owner != address && nextToken?.owner != address))
            continue;
          final amount =
              (nextToken?.owner == address ? nextToken!.amount : BigInt.zero) -
              (oldToken?.owner == address ? oldToken!.amount : BigInt.zero);
          if (simulated == null && amount != BigInt.zero)
            funds.add(
              FundChange(
                asset: ReviewAsset(id: token.mint, symbol: 'Token'),
                address: key,
                rawAmount: amount,
                evidence: ReviewEvidence.simulatedState,
                isNet: true,
              ),
            );
          if (oldToken != null &&
              nextToken != null &&
              oldToken.frozen != nextToken.frozen) {
            accounts.add(
              AccountChange(
                kind: nextToken.frozen
                    ? AccountChangeKind.freeze
                    : AccountChangeKind.thaw,
                address: key,
                program: next['owner'] as String,
                assetId: token.mint,
                description: nextToken.frozen
                    ? 'Freeze token account'
                    : 'Thaw token account',
                evidence: ReviewEvidence.simulatedState,
              ),
            );
          }
          if (oldToken != null &&
              nextToken != null &&
              (oldToken.delegate != nextToken.delegate ||
                  oldToken.delegatedAmount != nextToken.delegatedAmount))
            accounts.add(
              AccountChange(
                kind: nextToken.delegate == null
                    ? AccountChangeKind.revoke
                    : AccountChangeKind.approve,
                address: key,
                program: next['owner'] as String,
                description: nextToken.delegate == null
                    ? 'Token delegate revoked'
                    : 'Token spending permission changed',
                assetId: token.mint,
                beneficiary: nextToken.delegate,
                rawAllowance: nextToken.delegatedAmount,
                balance: oldToken.amount,
                evidence: ReviewEvidence.simulatedState,
              ),
            );
          if (oldToken != null &&
              nextToken != null &&
              oldToken.owner != nextToken.owner)
            accounts.add(
              AccountChange(
                kind: AccountChangeKind.authority,
                address: key,
                program: next['owner'] as String,
                description: 'Token account owner changes',
                beneficiary: nextToken.owner,
                evidence: ReviewEvidence.simulatedState,
              ),
            );
        }
        // The fee the simulation charged, prioritization fee included.
        final simulatedFee = value['fee'];
        if (simulatedFee is int && simulatedFee >= 0) fee = simulatedFee;
        tokenDecimals = _tokenBalanceDecimals(value);
        // Amounts from the simulation need no second snapshot at its slot.
        snapshotComplete =
            preList.length == inspected.length &&
            postList.length == inspected.length &&
            (simulated != null || (beforeSlot != null && beforeSlot == slot));
      }
    } catch (_) {
      error ??=
          'Simulation is unavailable. The effects and cost could not be verified.';
      // A simulation that ran but whose answer could not be read to the end
      // is not a success: what was read so far stays, and approving takes
      // the same care as when it did not run.
      if (execution == SimulationExecution.succeeded) {
        execution = SimulationExecution.unavailable;
        effectsUndecodable = true;
      }
      // What the bytes ask for does not depend on the node. When it failed
      // before they were read, they are read now, with no account state.
      if (!decoded) {
        try {
          decodeSolanaInstructions(
            tx,
            keys,
            const {},
            funds,
            accounts,
            warnings,
            address,
            nfts: nfts,
          );
        } catch (_) {
          warnings.add(
            'An instruction references accounts or data that could not be decoded.',
          );
        }
      }
    }
    final succeeded = execution == SimulationExecution.succeeded;
    if (!succeeded) {
      fee = null;
    }
    final compressed = _compressedAssetIds(accounts, nfts);
    final coreDelegated = _coreDelegatedAssetIds(accounts);
    final assetIds = <String>{
      ...nfts.map((n) => n.assetId),
      ...accounts.map((a) => a.assetId).whereType<String>(),
      ...funds
          .where((f) => f.asset.id != solanaNativeMint && !_isUnknownMint(f))
          .map((f) => f.asset.id),
    }.take(100).toList();
    // DAS serves both the mints' identities and the review's names and
    // images. The batch sent with the simulation covers every inspected
    // account; only an asset outside them, or every asset when that batch
    // failed, is asked for now, alongside the fee a node left out.
    final inspectedBatch = await inspectedAssets;
    final wanted = assetIds.toSet();
    final remaining = inspectedBatch == null
        ? assetIds
        : assetIds.where((id) => !inspectedKeys.contains(id)).toList();
    final assetBatch = _assetBatch(chain, remaining);
    final feeLookup = succeeded && fee == null
        ? _feeForMessage(chain, tx, warnings)
        : null;
    final asked = await assetBatch;
    final assets = inspectedBatch == null && asked == null
        ? null
        : [
            ...?inspectedBatch?.where((asset) => wanted.contains(asset['id'])),
            ...?asked,
          ];
    if (feeLookup != null) fee = await feeLookup;
    if (succeeded) {
      singleSupply.addAll(
        await _resolveAssets(
          chain,
          funds,
          nfts,
          warnings,
          // Neither a compressed NFT nor a Core one has a mint account to
          // read.
          accounts
              .map((a) => a.assetId)
              .whereType<String>()
              .where(
                (id) => !compressed.contains(id) && !coreDelegated.contains(id),
              ),
          decimals: tokenDecimals,
          assets: assets,
        ),
      );
      // Only a fully inspected System transfer has exhaustive interpretation.
      // Generic program/NFT execution remains partial even on RPC success.
      complete =
          snapshotComplete &&
          warnings.isEmpty &&
          accounts.isEmpty &&
          nfts.isEmpty &&
          tx.compiledMessage.instructions.every(
            (ix) =>
                keys[ix.programIdIndex] == solanaSystemProgram &&
                ix.data.length == 12 &&
                ix.data.first == 2,
          );
    }
    if (!complete)
      warnings.add(
        // Said in the review when the wallet's signature reaches a program
        // it cannot read. The general statement stays with the review's
        // coverage, since nearly every transaction is partial in that sense.
        solanaSignsUnreadProgram(tx, keys, address)
            ? kSolanaUnreadProgramsWarning
            : 'Some effects could not be decoded. Unknown programs, inner calls and NFT extensions may change additional assets or permissions.',
      );
    if (assets != null) {
      try {
        for (final asset in assets) {
          final id = asset['id'] as String;
          final interface = asset['interface'];
          final tokenInfo = _map(asset['token_info']);
          final decimals = tokenInfo['decimals'];
          // A single-supply, zero-decimal mint is an NFT whatever interface
          // DAS files it under; it files some legacy NFTs as fungible.
          final nft =
              singleSupply.contains(id) ||
              (tokenInfo['supply'] == 1 && decimals == 0);
          final fungible =
              !nft &&
              (const ['FungibleToken', 'FungibleAsset'].contains(interface) ||
                  (decimals is int && decimals > 0));
          if (fungible && !isRegistryMint(id)) {
            final content = _map(asset['content']);
            final files = content['files'];
            final file = files is List && files.isNotEmpty
                ? _map(files.first)
                : const <String, dynamic>{};
            final metadata = ReviewTokenMetadata.fromCreator(
              symbol:
                  _map(content['metadata'])['symbol'] ??
                  _map(asset['token_info'])['symbol'],
              image:
                  _map(content['links'])['image'] ??
                  file['cdn_uri'] ??
                  file['uri'],
              reservedSymbols: _reservedSymbols,
            );
            if (metadata != null) tokenMetadata[id] = metadata;
            continue;
          }
          // DAS files NFTs whose metadata names no token standard, common
          // among older collections, as `Custom`; so every interface but the
          // fungible ones and those that are never an owned item reads as an
          // NFT.
          if (fungible ||
              (!nft &&
                  const [
                    'MplCoreCollection',
                    'Executable',
                    'Identity',
                  ].contains(interface)))
            continue;
          final content = _map(asset['content']);
          nftMetadata[id] = ReviewNftMetadata(
            name:
                solanaCreatorText(_map(content['metadata'])['name']) ??
                nftMetadata[id]?.name,
            imageUrl: _nftImage(content),
          );
        }
      } catch (_) {
        // Metadata is decoration; unavailable DAS must not hide effects.
      }
    }
    // A single-supply mint DAS could not describe is still an NFT: the
    // review names it as one, with a placeholder image, rather than as a
    // bare token account. So is a Core asset the wallet signs a delegate
    // onto, whether or not its account or a lookup named it.
    for (final id in {...singleSupply, ...coreDelegated}) {
      nftMetadata.putIfAbsent(id, () => const ReviewNftMetadata());
    }
    // So is a compressed NFT, which has no account of its own to read. One
    // no lookup named is called what it is.
    for (final id in compressed) {
      final known = nftMetadata[id];
      if (known?.name == null) {
        nftMetadata[id] = ReviewNftMetadata(
          name: _compressedNftName,
          imageUrl: known?.imageUrl,
        );
      }
    }
    return PreparedSolanaTransaction(
      frozen,
      SimulationReview(
        explorerUrl: _inspectorUrl(chain, tx),
        programCalls: programCalls.isNotEmpty
            ? programCalls
            : solanaProgramCalls(
                solanaInvocations(tx.compiledMessage.instructions, keys),
              ),
        nftMetadata: nftMetadata,
        tokenMetadata: tokenMetadata,
        delegatedBy: delegatedBy,
        payloadDigest: sha256.convert(frozen).toString(),
        origin: origin,
        walletId: walletId,
        address: address,
        chain: chain,
        simulatedAt: DateTime.now().toUtc(),
        execution: execution,
        coverage: complete
            ? SimulationCoverage.complete
            : SimulationCoverage.partial,
        effectsUndecodable: effectsUndecodable,
        slot: slot,
        feeLamports: fee,
        feePayer: keys.first,
        error: error,
        warnings: warnings,
        funds: funds,
        accounts: accounts,
        nfts: nfts,
      ),
    );
  }

  /// The addresses [lookups] load, writable then read-only as the runtime
  /// orders them. Tables the cache covers are not read again.
  Future<List<String>> _resolveLookups(
    String chain,
    List<MessageAddressTableLookup> lookups,
  ) async {
    await _lookupTables.load();
    final contents = <String, List<String>>{};
    final unread = <String>[];
    for (final lookup in lookups) {
      final table = lookup.accountKey.toBase58();
      if (contents.containsKey(table) || unread.contains(table)) continue;
      final indexes = [...lookup.writableIndexes, ...lookup.readonlyIndexes];
      final cached = _lookupTables.addresses(
        chain,
        table,
        covering: indexes.isEmpty ? 0 : indexes.reduce(max) + 1,
      );
      if (cached != null) {
        contents[table] = cached;
      } else {
        unread.add(table);
      }
    }
    if (unread.isNotEmpty) {
      final result = _map(
        await _rpc(chain, 'getMultipleAccounts', [
          unread,
          {'encoding': 'base64', 'commitment': 'confirmed'},
        ]),
      );
      final values = result['value'] as List;
      for (var i = 0; i < unread.length; i++) {
        final value = _map(values[i]);
        final data = _accountBytes(value);
        if (value['owner'] != _lookupProgram ||
            data == null ||
            data.length < 56 ||
            (data.length - 56) % 32 != 0) {
          throw const FormatException();
        }
        final addresses = [
          for (var at = 56; at < data.length; at += 32)
            base58encode(data.sublist(at, at + 32)),
        ];
        contents[unread[i]] = addresses;
        _lookupTables.store(chain, unread[i], addresses);
      }
    }
    final writable = <String>[];
    final readonly = <String>[];
    for (final lookup in lookups) {
      final addresses = contents[lookup.accountKey.toBase58()]!;
      writable.addAll(lookup.writableIndexes.map((i) => addresses[i]));
      readonly.addAll(lookup.readonlyIndexes.map((i) => addresses[i]));
    }
    return [...writable, ...readonly];
  }

  /// The DAS records for [ids], each one an object naming a requested id.
  /// Null when there are none to ask for or DAS is unavailable.
  Future<List<Map<String, Object?>>?> _assetBatch(
    String chain,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return null;
    try {
      final result = await _rpc(chain, 'getAssetBatch', [ids]);
      return [
        for (final raw in result as List)
          if (_map(raw) case final asset
              when asset['id'] is String && ids.contains(asset['id']))
            asset,
      ];
    } catch (_) {
      // Metadata is decoration; unavailable DAS must not hide effects.
      return null;
    }
  }

  /// The fee for [tx]'s message, for a node whose simulation leaves it out.
  Future<int?> _feeForMessage(
    String chain,
    SignedTx tx,
    List<String> warnings,
  ) async {
    try {
      final result = _map(
        await _rpc(chain, 'getFeeForMessage', [
          base64Encode(tx.compiledMessage.toByteArray().toList()),
          {'commitment': 'confirmed'},
        ]),
      );
      return result['value'] as int?;
    } catch (_) {
      warnings.add('Network fee is unavailable.');
      return null;
    }
  }

  /// Gives the funds' mints and [actionMints] (tokens whose permissions change
  /// without any moving) their precision. Returns the single-supply,
  /// zero-decimal mints among them: NFTs.
  ///
  /// Precision comes from [decimals], which the node read from each mint for
  /// the simulation's token balances; supply, needed only for a zero-decimal
  /// mint, from the DAS [assets]. Only a mint neither answers for is read from
  /// the chain.
  Future<Set<String>> _resolveAssets(
    String chain,
    List<FundChange> funds,
    List<NftChange> nfts,
    List<String> warnings,
    Iterable<String> actionMints, {
    required Map<String, int> decimals,
    required List<Map<String, Object?>>? assets,
  }) async {
    final singleSupply = <String>{};
    final mints = {
      ...funds
          .where((f) => f.asset.id != solanaNativeMint && !_isUnknownMint(f))
          .map((f) => f.asset.id),
      ...actionMints.where((id) => id != solanaNativeMint),
    }.take(100).toList();
    if (mints.isEmpty) return singleSupply;
    final supplies = <String, BigInt>{
      for (final asset in assets ?? const <Map<String, Object?>>[])
        if (_map(asset['token_info'])['supply'] case final int supply
            when supply >= 0)
          asset['id'] as String: BigInt.from(supply),
    };
    final resolved = <String, ({int decimals, BigInt? supply})>{};
    for (final mint in mints) {
      final precision = decimals[mint];
      if (precision != null && (precision > 0 || supplies[mint] != null)) {
        resolved[mint] = (decimals: precision, supply: supplies[mint]);
      }
    }
    final unread = mints.where((m) => !resolved.containsKey(m)).toList();
    if (unread.isNotEmpty) {
      try {
        final result = _map(
          await _rpc(chain, 'getMultipleAccounts', [
            unread,
            {'encoding': 'base64', 'commitment': 'confirmed'},
          ]),
        );
        final values = result['value'] as List;
        for (var m = 0; m < unread.length; m++) {
          final account = _map(values[m]);
          final bytes = _accountBytes(account);
          if (!_isTokenProgram(account['owner']) ||
              bytes == null ||
              bytes.length < 82 ||
              bytes[45] != 1)
            continue;
          resolved[unread[m]] = (decimals: bytes[44], supply: _u64(bytes, 36));
        }
      } catch (_) {
        warnings.add(
          'Token precision and NFT identity could not be verified. Raw amounts are shown.',
        );
      }
    }
    for (final mint in mints) {
      final info = resolved[mint];
      if (info == null) continue;
      final (:decimals, :supply) = info;
      final single = decimals == 0 && supply == BigInt.one;
      if (single) singleSupply.add(mint);
      for (var i = 0; i < funds.length; i++) {
        final fund = funds[i];
        if (fund.asset.id != mint) continue;
        funds[i] = FundChange(
          asset: ReviewAsset(id: mint, symbol: 'Token', decimals: decimals),
          address: fund.address,
          rawAmount: fund.rawAmount,
          evidence: fund.evidence,
          from: fund.from,
          to: fund.to,
          isNet: fund.isNet,
        );
        if (single && fund.isNet && fund.rawAmount.abs() == BigInt.one)
          nfts.add(
            NftChange(
              kind: NftChangeKind.transfer,
              assetId: mint,
              description: fund.rawAmount.isNegative
                  ? 'Single-supply token leaves wallet'
                  : 'Single-supply token enters wallet',
              evidence: ReviewEvidence.simulatedState,
              from: fund.rawAmount.isNegative ? fund.address : null,
              to: fund.rawAmount.isNegative ? null : fund.address,
            ),
          );
      }
    }
    return singleSupply;
  }
}

/// The signer's SOL change and every token change on accounts it owns, from
/// a simulation's own pre- and post-balances. Indexes run over the static
/// keys, then the addresses the node reports its tables loaded. Null when the
/// node reported no balances, or ones that do not fit the transaction.
List<FundChange>? _simulatedAmounts(
  Map<String, Object?> value,
  SignedTx tx,
  String address,
) {
  final pre = value['preBalances'];
  final post = value['postBalances'];
  final preTokens = value['preTokenBalances'];
  final postTokens = value['postTokenBalances'];
  if (pre is! List ||
      post is! List ||
      preTokens is! List ||
      postTokens is! List)
    return null;
  final loaded = _map(value['loadedAddresses']);
  final keys = [
    for (final key in tx.compiledMessage.accountKeys) key.toBase58(),
    ...?(loaded['writable'] as List?),
    ...?(loaded['readonly'] as List?),
  ];
  if (pre.length != keys.length ||
      post.length != keys.length ||
      keys.any((k) => k is! String) ||
      pre.any((b) => b is! int) ||
      post.any((b) => b is! int))
    return null;
  final funds = <FundChange>[];
  final signer = keys.indexOf(address);
  if (signer >= 0) {
    funds.add(
      FundChange(
        asset: _sol,
        address: address,
        rawAmount: BigInt.from((post[signer] as int) - (pre[signer] as int)),
        evidence: ReviewEvidence.simulatedState,
        isNet: true,
      ),
    );
  }
  Map<int, ({String mint, String owner, BigInt amount})>? byAccount(
    List<Object?> rows,
  ) {
    final out = <int, ({String mint, String owner, BigInt amount})>{};
    for (final row in rows) {
      if (_map(row) case {
        'accountIndex': final int index,
        'mint': final String mint,
        'owner': final String owner,
        'uiTokenAmount': {'amount': final String raw},
      } when index >= 0 && index < keys.length) {
        final amount = BigInt.tryParse(raw);
        if (amount == null || amount.isNegative) return null;
        out[index] = (mint: mint, owner: owner, amount: amount);
      } else {
        return null;
      }
    }
    return out;
  }

  final before = byAccount(preTokens);
  final after = byAccount(postTokens);
  if (before == null || after == null) return null;
  final changes = <(int, String), BigInt>{};
  void add(int index, String mint, BigInt amount) =>
      changes.update((index, mint), (v) => v + amount, ifAbsent: () => amount);
  for (final index in {...before.keys, ...after.keys}.toList()..sort()) {
    final old = before[index];
    final next = after[index];
    if (old != null && old.owner == address) add(index, old.mint, -old.amount);
    if (next != null && next.owner == address)
      add(index, next.mint, next.amount);
  }
  for (final MapEntry(key: (index, mint), :value) in changes.entries) {
    if (value == BigInt.zero) continue;
    funds.add(
      FundChange(
        asset: ReviewAsset(id: mint, symbol: 'Token'),
        address: keys[index] as String,
        rawAmount: value,
        evidence: ReviewEvidence.simulatedState,
        isNet: true,
      ),
    );
  }
  return funds;
}

/// Mint precision from a simulation's token balances, which the node reads
/// from each mint on chain. Empty when the node reports none.
Map<String, int> _tokenBalanceDecimals(Map<String, Object?> value) => {
  for (final key in const ['preTokenBalances', 'postTokenBalances'])
    if (value[key] case final List<Object?> rows)
      for (final row in rows)
        if (_map(row) case {
          'mint': final String mint,
          'uiTokenAmount': {'decimals': final int decimals},
        } when decimals >= 0 && decimals <= 255)
          mint: decimals,
};

Uri _inspectorUrl(String chain, SignedTx tx) =>
    Uri.https('explorer.solana.com', '/tx/inspector', {
      if (chain == 'solana:devnet') 'cluster': 'devnet',
      'message': base64Encode(tx.compiledMessage.toByteArray().toList()),
    });

/// An NFT's image: its `links.image`, else the first file that declares an
/// image type (the first file of an animated NFT is often its video).
String? _nftImage(Map<String, Object?> content) {
  final image = _map(content['links'])['image'];
  if (image is String && image.isNotEmpty) return image;
  final files = content['files'];
  if (files is! List) return null;
  for (final raw in files) {
    final file = _map(raw);
    final mime = file['mime'];
    if (mime is! String || !mime.startsWith('image/')) continue;
    final uri = file['cdn_uri'] ?? file['uri'];
    if (uri is String && uri.isNotEmpty) return uri;
  }
  return null;
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : <String, Object?>{};
bool _isTokenProgram(Object? program) =>
    program == solanaTokenProgram || program == solanaToken2022Program;
Uint8List? _accountBytes(Map<String, Object?> account) {
  final data = account['data'];
  if (data is! List ||
      data.length < 2 ||
      data[0] is! String ||
      data[1] != 'base64')
    return null;
  try {
    return base64Decode(data[0] as String);
  } catch (_) {
    return null;
  }
}

BigInt _u64(Uint8List bytes, int offset) {
  var value = BigInt.zero;
  for (var i = 7; i >= 0; i--) {
    value = (value << 8) | BigInt.from(bytes[offset + i]);
  }
  return value;
}

typedef _TokenState = ({
  String mint,
  String owner,
  BigInt amount,
  String? delegate,
  BigInt delegatedAmount,
  bool frozen,
});
_TokenState? _tokenState(Map<String, Object?> account) {
  if (!_isTokenProgram(account['owner'])) return null;
  final bytes = _accountBytes(account);
  if (bytes == null ||
      bytes.length < 165 ||
      (bytes[108] != 1 && bytes[108] != 2))
    return null;
  return (
    mint: base58encode(bytes.sublist(0, 32)),
    owner: base58encode(bytes.sublist(32, 64)),
    amount: _u64(bytes, 64),
    delegate: bytes[72] == 1 ? base58encode(bytes.sublist(76, 108)) : null,
    delegatedAmount: _u64(bytes, 121),
    frozen: bytes[108] == 2,
  );
}

/// Requested instructions are intent, never presented as verified state deltas.
///
/// A transfer is given a direction only when the bytes prove one: out when
/// the wallet is the source or the authority that signs for it, in when the
/// destination is the wallet or a token account that is provably its own.
/// Any other transfer is another account's and is listed without one.
///
/// [instructions] are calls another program made, from a simulation; without
/// them the transaction's own instructions are read. [nfts] receives the
/// compressed NFTs the instructions move.
void decodeSolanaInstructions(
  SignedTx tx,
  List<String> keys,
  Map<String, Map<String, Object?>> before,
  List<FundChange> funds,
  List<AccountChange> accounts,
  List<String> warnings,
  String signer, {
  List<CompiledInstruction>? instructions,
  List<NftChange>? nfts,
}) {
  const evidence = ReviewEvidence.requestedInstruction;
  // A program's own calls between accounts that are not the wallet's are its
  // plumbing; only the transaction's own instructions are listed as such.
  final topLevel = instructions == null;
  for (final instruction in instructions ?? tx.compiledMessage.instructions) {
    final program = keys[instruction.programIdIndex];
    final data = Uint8List.fromList(instruction.data.toList());
    final indexes = instruction.accountKeyIndexes;
    String at(int i) => keys[indexes[i]];
    // An account that may be missing: one loaded from a lookup table that
    // could not be resolved has an index past the known keys.
    String? named(int i) => i < indexes.length && indexes[i] < keys.length
        ? keys[indexes[i]]
        : null;
    // The wallet is one of the accounts the instruction names, so its
    // signature reaches it. A call another program makes carries the
    // signature on with it.
    bool namesWallet() =>
        indexes.any((i) => i < keys.length && keys[i] == signer);

    // SOL that [from] sends [to]. [authorised] is the wallet signing for an
    // account that is not its own address: one derived from it, a nonce
    // account, a stake account.
    void sol(
      String? from,
      String? to,
      BigInt lamports, {
      bool authorised = false,
    }) {
      if (from == signer && to == signer) return;
      if (to == signer || from == signer) {
        funds.add(
          FundChange(
            asset: _sol,
            address: signer,
            rawAmount: to == signer ? lamports : -lamports,
            evidence: evidence,
            from: from,
            to: to,
          ),
        );
      } else if (authorised && from != null) {
        funds.add(
          FundChange(
            asset: _sol,
            address: from,
            rawAmount: -lamports,
            evidence: evidence,
            from: from,
            to: to,
          ),
        );
      } else if (from == null) {
        throw RangeError('account');
      } else if (topLevel) {
        accounts.add(
          AccountChange(
            kind: AccountChangeKind.close,
            address: from,
            program: program,
            description:
                'Transfer of ${formatReviewAmount(lamports, 9)} SOL between other accounts',
            beneficiary: to,
            evidence: evidence,
          ),
        );
      }
    }

    // A new account funded by [from] and owned by [owner]. The deposit
    // leaves the wallet for an account another program controls, so it is a
    // movement as well as an account change.
    void create(String? from, String account, BigInt lamports, String owner) {
      accounts.add(
        AccountChange(
          kind: AccountChangeKind.create,
          address: account,
          program: program,
          description:
              'Create account; rent deposit ${formatReviewAmount(lamports, 9)} SOL',
          beneficiary: owner,
          evidence: evidence,
        ),
      );
      if (from == signer && lamports > BigInt.zero) {
        funds.add(
          FundChange(
            asset: _sol,
            address: signer,
            rawAmount: -lamports,
            evidence: evidence,
            from: from,
            to: account,
          ),
        );
      }
    }

    void assign(String account, String owner) => accounts.add(
      AccountChange(
        kind: AccountChangeKind.authority,
        address: account,
        program: program,
        description: 'Assign account to a program',
        beneficiary: owner,
        evidence: evidence,
      ),
    );

    // A System or Token instruction that was not read. It gets a caution
    // when the wallet is one of its accounts and it is one that can move or
    // re-assign holdings, or one with no name at all. Any other is named in
    // the program calls and needs none: upkeep of a mint, or an instruction
    // about accounts that are not the wallet's. Returns whether it cautioned.
    bool unread() {
      if (!namesWallet() || !solanaUnreadInstructionIsRisky(program, data)) {
        return false;
      }
      warnings.add(solanaUnreadInstructionWarning(program, data));
      return true;
    }

    // The System Program ignores bytes after an instruction's own, so an
    // instruction with more than [length] of them is read as the program
    // runs it. The review still says they are there, when it is the
    // wallet's instruction.
    void extraBytes(int length) {
      if (data.length > length && namesWallet()) {
        warnings.add(solanaExtraBytesWarning(program, data));
      }
    }

    try {
      if (program == solanaSystemProgram) {
        final tag = data.length >= 4
            ? ByteData.sublistView(data).getUint32(0, Endian.little)
            : null;
        // Where a seeded instruction's fields resume after its base address
        // and its seed (a length, then that many bytes).
        int afterSeed(int lengthAt) {
          final length = _u64(data, lengthAt);
          if (length > BigInt.from(32)) throw RangeError('seed');
          return lengthAt + 8 + length.toInt();
        }

        if (tag == 2 && data.length >= 12 && indexes.length >= 2) {
          sol(named(0), named(1), _u64(data, 4));
          extraBytes(12);
        } else if (tag == 0 && data.length >= 52 && indexes.length >= 2) {
          create(
            named(0),
            at(1),
            _u64(data, 4),
            base58encode(data.sublist(20, 52)),
          );
          extraBytes(52);
        } else if (tag == 3 && indexes.length >= 2) {
          // CreateAccountWithSeed: base, seed, lamports, space, owner.
          final rest = afterSeed(36);
          create(
            named(0),
            at(1),
            _u64(data, rest),
            base58encode(data.sublist(rest + 16, rest + 48)),
          );
        } else if (tag == 1 && data.length >= 36 && indexes.isNotEmpty) {
          assign(at(0), base58encode(data.sublist(4, 36)));
          extraBytes(36);
        } else if (tag == 9 && indexes.isNotEmpty) {
          // AllocateWithSeed: base, seed, space, owner.
          final rest = afterSeed(36);
          assign(at(0), base58encode(data.sublist(rest + 8, rest + 40)));
        } else if (tag == 10 && indexes.isNotEmpty) {
          // AssignWithSeed: base, seed, owner.
          final rest = afterSeed(36);
          assign(at(0), base58encode(data.sublist(rest, rest + 32)));
        } else if (tag == 11 && data.length >= 12 && indexes.length >= 3) {
          // TransferWithSeed: [from, base, to]. The base signs for an
          // account derived from it.
          sol(named(0), named(2), _u64(data, 4), authorised: at(1) == signer);
        } else if (tag == 5 && data.length >= 12 && indexes.length >= 5) {
          // WithdrawNonceAccount: [nonce, to, sysvars…, authority].
          sol(named(0), named(1), _u64(data, 4), authorised: at(4) == signer);
          extraBytes(12);
        } else if (tag == 7 && data.length >= 36 && indexes.length >= 2) {
          // AuthorizeNonceAccount: [nonce, authority]; the new authority.
          final next = base58encode(data.sublist(4, 36));
          extraBytes(36);
          if (at(1) == signer && next != signer) {
            accounts.add(
              AccountChange(
                kind: AccountChangeKind.authority,
                address: at(0),
                program: program,
                description: 'Control of a nonce account changes',
                beneficiary: next,
                evidence: evidence,
              ),
            );
          }
        } else {
          unread();
        }
      } else if (_isTokenProgram(program)) {
        final tag = data.isEmpty ? null : data[0];
        // Token-2022's TransferCheckedWithFee is TransferChecked with the
        // expected fee after it.
        final withFee =
            program == solanaToken2022Program &&
            tag == 26 &&
            data.length >= 11 &&
            data[1] == 1;
        final checked = tag == 12 || withFee;
        // Whether the instruction was left unread without a caution.
        var stepped = false;
        if (((tag == 3 || tag == 12) &&
                data.length >= 9 &&
                indexes.length >= (checked ? 4 : 3)) ||
            (withFee && indexes.length >= 4)) {
          final source = at(0);
          final destination = named(checked ? 2 : 1);
          final authority = named(checked ? 3 : 2);
          final state = _tokenState(before[source] ?? const {});
          final destinationState = destination == null
              ? null
              : _tokenState(before[destination] ?? const {});
          final mint = checked
              ? named(1)
              : state?.mint ?? destinationState?.mint;
          final amount = _u64(data, withFee ? 2 : 1);
          // The Token programs ignore bytes after an instruction's own, so
          // TransferChecked's decimals are there whatever follows them.
          final decimals = withFee
              ? data[10]
              : tag == 12 && data.length >= 10
              ? data[9]
              : null;
          final outgoing = state?.owner == signer || authority == signer;
          final incoming =
              !outgoing &&
              destination != null &&
              (destinationState?.owner == signer ||
                  (mint != null &&
                      solanaAssociatedTokenAddress(signer, mint, program) ==
                          destination));
          if (outgoing || incoming) {
            funds.add(
              FundChange(
                // A plain Transfer names no mint. With no account state to
                // read it from, the token account stands in for it (see
                // [_isUnknownMint]), so the transfer is still shown.
                asset: ReviewAsset(
                  id: mint ?? source,
                  symbol: 'Token',
                  decimals: decimals,
                ),
                address: outgoing ? source : destination!,
                rawAmount: outgoing ? -amount : amount,
                evidence: evidence,
                from: source,
                to: destination,
              ),
            );
          } else if (topLevel) {
            accounts.add(
              AccountChange(
                kind: AccountChangeKind.close,
                address: source,
                program: program,
                assetId: mint,
                description:
                    'Transfer of ${formatReviewAmount(amount, decimals)}${decimals == null ? ' of a token' : ' tokens'} between other accounts',
                beneficiary: destination,
                evidence: evidence,
              ),
            );
          }
        } else if ((tag == 8 || tag == 15) &&
            data.length >= 9 &&
            indexes.length >= 3) {
          // Burn and BurnChecked: [account, mint, authority].
          final source = at(0);
          final state = _tokenState(before[source] ?? const {});
          if (state?.owner == signer || named(2) == signer) {
            funds.add(
              FundChange(
                asset: ReviewAsset(
                  id: named(1) ?? state?.mint ?? source,
                  symbol: 'Token',
                  decimals: tag == 15 && data.length >= 10 ? data[9] : null,
                ),
                address: source,
                rawAmount: -_u64(data, 1),
                evidence: evidence,
                from: source,
              ),
            );
          }
        } else if ((tag == 4 || tag == 13) && data.length >= 9) {
          final state = _tokenState(before[at(0)] ?? const {});
          accounts.add(
            AccountChange(
              kind: AccountChangeKind.approve,
              address: at(0),
              program: program,
              assetId: tag == 13 ? at(1) : state?.mint,
              description: 'Token spending permission',
              beneficiary: at(tag == 13 ? 2 : 1),
              rawAllowance: _u64(data, 1),
              balance: state?.amount,
              evidence: evidence,
            ),
          );
        } else if (tag == 5) {
          accounts.add(
            AccountChange(
              kind: AccountChangeKind.revoke,
              address: at(0),
              program: program,
              assetId: _tokenState(before[at(0)] ?? const {})?.mint,
              description: 'Revoke token spending permission',
              evidence: evidence,
            ),
          );
        } else if ((tag == 10 || tag == 11) && indexes.length >= 2) {
          accounts.add(
            AccountChange(
              kind: tag == 10
                  ? AccountChangeKind.freeze
                  : AccountChangeKind.thaw,
              address: at(0),
              program: program,
              assetId: at(1),
              description: tag == 10
                  ? 'Freeze token account'
                  : 'Thaw token account',
              evidence: evidence,
            ),
          );
        } else if (tag == 6 && data.length >= 3) {
          // SetAuthority: the authority's type, then whether a new one
          // follows: 0 removes the authority, 1 hands it to the 32 bytes
          // after. The program ignores whatever comes after those, so more
          // bytes must not turn "handed on" into "removed". Anything else is
          // not an instruction the program runs, and is not given a meaning.
          final String next;
          if (data[2] == 0) {
            next = 'Remove authority';
          } else if (data[2] == 1 && data.length >= 35) {
            next = base58encode(data.sublist(3, 35));
          } else {
            throw const FormatException('authority');
          }
          accounts.add(
            AccountChange(
              kind: AccountChangeKind.authority,
              address: at(0),
              program: program,
              description: 'Change token authority (type ${data[1]})',
              beneficiary: next,
              evidence: evidence,
            ),
          );
        } else if (tag == 9) {
          // An account that did not exist before the transaction was opened
          // by it, so closing it only returns the rent this transaction paid
          // in. An account missing from the read stays shown.
          final old = before[at(0)];
          if (old == null || (old.isNotEmpty && old['lamports'] != 0))
            accounts.add(
              AccountChange(
                kind: AccountChangeKind.close,
                address: at(0),
                program: program,
                description: 'Close token account and refund rent',
                beneficiary: at(1),
                evidence: evidence,
              ),
            );
        } else {
          stepped = !unread();
        }
        // Extensions act on tokens that move or change hands. An instruction
        // stepped over above does neither to the wallet's, so it does not
        // bring this caution with it.
        if (program == solanaToken2022Program && !stepped)
          warnings.add('Token-2022 extensions may cause additional effects.');
      } else if (program != _computeBudgetProgram) {
        accounts.add(
          AccountChange(
            kind: AccountChangeKind.contractCall,
            address: program,
            program: program,
            description:
                'Program call: effects may include funds, NFTs or permissions',
            evidence: evidence,
          ),
        );
        final effect = decodeSolanaAssetInstruction(program, data, named);
        if (effect != null) {
          _applyAssetEffect(
            effect,
            signer,
            namesWallet(),
            funds,
            accounts,
            nfts ?? <NftChange>[],
            warnings,
          );
        }
      }
    } catch (_) {
      warnings.add(
        'An instruction references accounts or data that could not be decoded.',
      );
    }
  }
}

/// Adds what an asset program's instruction does to the review, when it
/// concerns the wallet: its compressed NFT moves or gets a delegate, its Core
/// NFT gets one, or something it controls is handed on or withdrawn. Another
/// account's are left out. [namesWallet] is whether the wallet is among the
/// instruction's accounts, which decides whether one that could not be read
/// is its concern.
void _applyAssetEffect(
  SolanaAssetEffect effect,
  String signer,
  bool namesWallet,
  List<FundChange> funds,
  List<AccountChange> accounts,
  List<NftChange> nfts,
  List<String> warnings,
) {
  const evidence = ReviewEvidence.requestedInstruction;
  switch (effect) {
    case CompressedNftTransfer(:final assetId, :final owner, :final to):
      if (owner == to || (owner != signer && to != signer)) return;
      nfts.add(
        NftChange(
          kind: NftChangeKind.transfer,
          assetId: assetId,
          description: 'Compressed NFT ownership changes',
          evidence: evidence,
          from: owner,
          to: to,
        ),
      );
    case CompressedNftBurn(:final assetId, :final owner):
      if (owner != signer) return;
      nfts.add(
        NftChange(
          kind: NftChangeKind.burn,
          assetId: assetId,
          description: 'Compressed NFT burned',
          evidence: evidence,
          from: owner,
        ),
      );
    case CompressedNftDelegation(
      :final assetId,
      :final owner,
      :final delegate,
      :final freeze,
    ):
      if (owner != signer) return;
      // Naming the owner as its own delegate is how one is removed.
      final revoked = delegate == owner;
      accounts.add(
        AccountChange(
          kind: revoked ? AccountChangeKind.revoke : AccountChangeKind.approve,
          address: assetId,
          program: solanaBubblegumProgram,
          assetId: assetId,
          description: revoked
              ? 'Compressed NFT delegate removed'
              : 'Compressed NFT delegate',
          beneficiary: revoked ? null : delegate,
          rawAllowance: revoked ? null : BigInt.one,
          evidence: evidence,
        ),
      );
      if (freeze) {
        accounts.add(
          AccountChange(
            kind: AccountChangeKind.freeze,
            address: assetId,
            program: solanaBubblegumProgram,
            assetId: assetId,
            description: 'Freeze compressed NFT',
            evidence: evidence,
          ),
        );
      }
    case CoreNftDelegation(
      :final assetId,
      :final owner,
      :final delegate,
      :final power,
    ):
      // The wallet signs for the asset, and names someone else.
      if (owner != signer || delegate == signer) return;
      accounts.add(
        AccountChange(
          kind: AccountChangeKind.approve,
          address: assetId,
          program: solanaCoreProgram,
          assetId: assetId,
          description: 'Core NFT ${power.name} delegate',
          beneficiary: delegate,
          rawAllowance: BigInt.one,
          power: power,
          evidence: evidence,
        ),
      );
    case AuthorityHandover(
      :final program,
      :final account,
      :final what,
      :final current,
      :final next,
    ):
      // Only what the wallet controls now, and would not afterwards.
      if (current != signer || next == signer) return;
      accounts.add(
        AccountChange(
          kind: AccountChangeKind.authority,
          address: account,
          program: program,
          description: 'Control of $what changes',
          beneficiary: next ?? 'Remove authority',
          evidence: evidence,
        ),
      );
    case StakeWithdrawal(
      :final account,
      :final authority,
      :final to,
      :final lamports,
    ):
      if (authority != signer) return;
      funds.add(
        FundChange(
          asset: _sol,
          // To the wallet it is the wallet's own balance that changes; to
          // anyone else it leaves the stake account, which no balance of the
          // wallet's shows (see [_isOffBalance]).
          address: to == signer ? signer : account,
          rawAmount: to == signer ? lamports : -lamports,
          evidence: evidence,
          from: account,
          to: to,
        ),
      );
    case UnreadAssetInstruction(:final program):
      if (namesWallet) warnings.add(solanaUnreadAssetWarning(program));
  }
}

/// What a System call the node parsed itself does to something the wallet
/// controls outside its own balance. A node reports the calls a program makes
/// in its own form, named fields and no data, for the programs it can parse,
/// the System Program among them: inside another program's call these arrive
/// only like this, so a reader of bytes alone never sees them.
///
/// The wallet's own SOL is in the simulation's balances already, and a
/// program's upkeep of its own accounts is its plumbing. Neither is listed.
/// What is: SOL the wallet signs out of a nonce account or an account derived
/// from it, the wallet's own account or one derived from it handed to a
/// program, and a nonce account's authority handed on.
void _applyParsedSystemCall(
  Object? parsed,
  String signer,
  List<FundChange> funds,
  List<AccountChange> accounts,
  List<String> warnings,
) {
  if (parsed is! Map) return;
  final type = parsed['type'];
  final info = parsed['info'] is Map
      ? (parsed['info'] as Map).cast<String, Object?>()
      : const <String, Object?>{};
  String? text(String key) {
    final value = info[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  const program = solanaSystemProgram;
  const evidence = ReviewEvidence.requestedInstruction;
  void unread(String name) =>
      warnings.add(solanaUnreadNamedInstructionWarning(program, name));

  // SOL that [authority] signs out of [from], an account that is not the
  // wallet's own address. What reaches the wallet is in its balance.
  void offBalance(String name, String? from, String? to, String? authority) {
    if (authority != signer || from == signer || to == signer) return;
    final lamports = switch (info['lamports']) {
      final int value when value >= 0 => BigInt.from(value),
      final String value => BigInt.tryParse(value),
      _ => null,
    };
    if (from == null || lamports == null || lamports.isNegative) {
      return unread(name);
    }
    funds.add(
      FundChange(
        asset: _sol,
        address: from,
        rawAmount: -lamports,
        evidence: evidence,
        from: from,
        to: to,
      ),
    );
  }

  void handOver(String name, String? account, String? next, String what) {
    if (account == null || next == null) return unread(name);
    accounts.add(
      AccountChange(
        kind: AccountChangeKind.authority,
        address: account,
        program: program,
        description: what,
        beneficiary: next,
        evidence: evidence,
      ),
    );
  }

  switch (type) {
    case 'withdrawFromNonce':
      offBalance(
        'WithdrawNonceAccount',
        text('nonceAccount'),
        text('destination'),
        text('nonceAuthority'),
      );
    case 'transferWithSeed':
      offBalance(
        'TransferWithSeed',
        text('source'),
        text('destination'),
        text('sourceBase'),
      );
    case 'assign':
      // A program assigns its own new accounts in every other call it makes.
      // The wallet's own account handed to a program is the one that matters.
      if (text('account') == signer) {
        handOver(
          'Assign',
          signer,
          text('owner'),
          'Assign account to a program',
        );
      }
    case 'assignWithSeed' || 'allocateWithSeed':
      // An account derived from the wallet: only its signature assigns it.
      if (text('base') == signer) {
        handOver(
          type == 'assignWithSeed' ? 'AssignWithSeed' : 'AllocateWithSeed',
          text('account'),
          text('owner'),
          'Assign account to a program',
        );
      }
    case 'authorizeNonce':
      final next = text('newAuthorized');
      if (text('nonceAuthority') == signer && next != signer) {
        handOver(
          'AuthorizeNonceAccount',
          text('nonceAccount'),
          next,
          'Control of a nonce account changes',
        );
      }
    case 'allocate':
      // On the wallet's own account: it could no longer send SOL.
      if (text('account') == signer) unread('Allocate');
  }
}

/// SOL the wallet signs out of an account that is not its own address: a
/// stake account, a nonce account, an account derived from it. A simulation's
/// balances for the wallet do not include it, so the review keeps the
/// requested amount beside them.
bool _isOffBalance(FundChange fund, String signer) =>
    fund.asset.id == solanaNativeMint &&
    fund.address != signer &&
    fund.rawAmount.isNegative;

/// A token movement whose mint the instruction does not name and no account
/// state supplied. Its asset id is the token account it moves from, which is
/// never a mint, so it is kept out of every mint lookup and shown as an
/// unknown token.
bool _isUnknownMint(FundChange fund) =>
    fund.evidence == ReviewEvidence.requestedInstruction &&
    fund.asset.id == fund.address;

/// The compressed NFTs a review's changes name. They are NFTs whatever an
/// asset lookup says of them, and have no mint account to read.
Set<String> _compressedAssetIds(
  List<AccountChange> accounts,
  List<NftChange> nfts,
) => {
  for (final account in accounts)
    if (account.program == solanaBubblegumProgram) ?account.assetId,
  for (final nft in nfts)
    if (nft.description.startsWith('Compressed NFT')) nft.assetId,
};

/// The Core NFTs a review's changes give a delegate. They are NFTs whatever
/// an asset lookup says of them, and have no mint account to read.
Set<String> _coreDelegatedAssetIds(List<AccountChange> accounts) => {
  for (final account in accounts)
    if (account.program == solanaCoreProgram && account.power != null)
      ?account.assetId,
};

/// Whether the wallet's signature reaches an instruction of a program this
/// review has no reader for. System and Token instructions are read, or
/// flagged one by one; so are those of the asset programs, except Core: only
/// its delegates are read from the instruction, and the rest of what it does
/// is known from the simulation's accounts or not at all. Compute Budget,
/// Memo and creating an associated token account do nothing to what a wallet
/// already holds.
bool solanaSignsUnreadProgram(SignedTx tx, List<String> keys, String signer) {
  for (final instruction in tx.compiledMessage.instructions) {
    if (instruction.programIdIndex >= keys.length) continue;
    final program = keys[instruction.programIdIndex];
    if (program == solanaSystemProgram ||
        program == _computeBudgetProgram ||
        _isTokenProgram(program) ||
        _memoPrograms.contains(program) ||
        (isSolanaAssetProgram(program) && program != solanaCoreProgram)) {
      continue;
    }
    final data = instruction.data.toList();
    // Create and CreateIdempotent; RecoverNested moves tokens.
    if (program == solanaAssociatedTokenProgram &&
        (data.isEmpty || (data.length == 1 && data[0] <= 1))) {
      continue;
    }
    if (instruction.accountKeyIndexes.any(
      (i) => i < keys.length && keys[i] == signer,
    )) {
      return true;
    }
  }
  return false;
}

/// A hardware reply must prove it belongs to the approved account. Attaching
/// the database address to returned bytes does not establish signer identity.
Future<void> verifyDappSignature(
  List<int> message,
  List<int> signature,
  String address,
) async {
  final valid = await isValidEd25519Signature(message, signature, address);
  if (!valid)
    throw const DappException(
      4100,
      'The signature does not belong to the approved wallet.',
    );
}

/// Base ownership/creation/closure deltas for Metaplex Core AssetV1. Plugins,
/// compressed assets and collection-wide authority remain explicitly partial.
List<NftChange> decodeCoreAssetDelta(
  String assetId,
  Map<String, Object?> before,
  Map<String, Object?> after,
  String signer,
) {
  final old = _coreState(before);
  final next = _coreState(after);
  if (old?.owner != signer && next?.owner != signer) return const [];
  if (old == null &&
      next != null &&
      (before.isEmpty || before['lamports'] == 0)) {
    return [
      NftChange(
        kind: NftChangeKind.mint,
        assetId: assetId,
        description: 'Core NFT created',
        evidence: ReviewEvidence.simulatedState,
        to: next.owner,
      ),
    ];
  }
  if (old != null &&
      next == null &&
      (after.isEmpty || after['lamports'] == 0)) {
    return [
      NftChange(
        kind: NftChangeKind.burn,
        assetId: assetId,
        description: 'Core NFT burned / asset account closed',
        evidence: ReviewEvidence.simulatedState,
        from: old.owner,
      ),
    ];
  }
  if (old == null || next == null) return const [];
  return [
    if (old.owner != next.owner)
      NftChange(
        kind: NftChangeKind.transfer,
        assetId: assetId,
        description: 'Core NFT ownership changes',
        evidence: ReviewEvidence.simulatedState,
        from: old.owner,
        to: next.owner,
      ),
    if (old.authority != next.authority ||
        old.authorityKind != next.authorityKind)
      NftChange(
        kind: NftChangeKind.authority,
        assetId: assetId,
        description: switch (next.authorityKind) {
          _CoreAuthority.none => 'Update authority removed',
          _CoreAuthority.address => 'Update authority moves to an address',
          _CoreAuthority.collection => 'Update authority moves to a collection',
        },
        evidence: ReviewEvidence.simulatedState,
        from: old.authority,
        to: next.authority,
      ),
  ];
}

/// Who holds a Core asset's update authority: no one, an address, or the
/// collection the asset belongs to.
enum _CoreAuthority { none, address, collection }

/// [authority] is the bare address, null when [authorityKind] is
/// [_CoreAuthority.none].
({String owner, _CoreAuthority authorityKind, String? authority, String? name})?
_coreState(Map<String, Object?> account) {
  if (account['owner'] != solanaCoreProgram) return null;
  final bytes = _accountBytes(account);
  if (bytes == null || bytes.length < 43 || bytes[0] != 1 || bytes[33] > 2)
    return null;
  var offset = bytes[33] == 0 ? 34 : 66;
  if (bytes.length < offset + 9) return null;
  final authorityKind = _CoreAuthority.values[bytes[33]];
  final authority = bytes[33] == 0 ? null : base58encode(bytes.sublist(34, 66));
  String? name;
  for (var field = 0; field < 2; field++) {
    if (offset + 4 > bytes.length) return null;
    final length = ByteData.sublistView(bytes).getUint32(offset, Endian.little);
    offset += 4;
    if (length > bytes.length - offset) return null;
    if (field == 0)
      name = utf8.decode(
        bytes.sublist(offset, offset + length),
        allowMalformed: true,
      );
    offset += length;
  }
  if (offset >= bytes.length ||
      bytes[offset] > 1 ||
      (bytes[offset] == 1 && offset + 9 > bytes.length))
    return null;
  return (
    owner: base58encode(bytes.sublist(1, 33)),
    authorityKind: authorityKind,
    authority: authority,
    name: name == null || name.isEmpty ? null : name,
  );
}

/// An inner instruction from a simulation, with its reported stack height.
///
/// [instruction] is null for a call the node parsed itself, which reports no
/// data; [name] is then the node's name for it and [parsed] what it reported:
/// `{"type", "info"}`, the fields named.
typedef SolanaInnerInstruction = ({
  String program,
  CompiledInstruction? instruction,
  String? name,
  int? depth,
  Object? parsed,
});

/// One inner instruction as `simulateTransaction` reports it, or null when it
/// is malformed or names a program outside [keys].
///
/// Nodes report inner instructions in the `jsonParsed` form whatever the
/// requested encoding: `{"programId", "parsed": {"type"}}` for a program
/// they can parse (System, Token, Associated Token Account and others), and
/// `{"programId", "accounts", "data"}` with addresses and base58 data for any
/// other. The compiled form, `{"programIdIndex", "accounts", "data"}` with
/// key indexes, is read too.
SolanaInnerInstruction? parseSimulationInnerInstruction(
  Map<String, Object?> ix,
  List<String> keys,
) {
  final depth = ix['stackHeight'] is int ? ix['stackHeight'] as int : null;
  try {
    final index = ix['programIdIndex'];
    if (index is int) {
      if (index < 0 || index >= keys.length) return null;
      return (
        program: keys[index],
        instruction: CompiledInstruction(
          programIdIndex: index,
          accountKeyIndexes: (ix['accounts'] as List).cast<int>(),
          data: ByteArray(base58decode(ix['data'] as String)),
        ),
        name: null,
        depth: depth,
        parsed: null,
      );
    }
    final program = ix['programId'];
    if (program is! String) return null;
    final parsed = ix['parsed'];
    if (parsed != null) {
      final type = parsed is Map ? parsed['type'] : null;
      // "transferChecked" is "TransferChecked" in every table and log.
      final name = type is String && type.isNotEmpty
          ? type[0].toUpperCase() + type.substring(1)
          : null;
      return (
        program: program,
        instruction: null,
        name: name != null && ProgramLabelService.isInstructionName(name)
            ? name
            : null,
        depth: depth,
        parsed: parsed,
      );
    }
    final data = base58decode(ix['data'] as String);
    final accounts = [
      for (final account in (ix['accounts'] as List).cast<String>())
        keys.indexOf(account),
    ];
    final programIndex = keys.indexOf(program);
    return (
      program: program,
      // Decodable only when every address it names is a known key.
      instruction: programIndex < 0 || accounts.contains(-1)
          ? null
          : CompiledInstruction(
              programIdIndex: programIndex,
              accountKeyIndexes: accounts,
              data: ByteArray(data),
            ),
      name: null,
      depth: depth,
      parsed: null,
    );
  } catch (_) {
    // State deltas remain available when an inner call is malformed.
    return null;
  }
}

/// For each account whose delegate or authority a call sets, the programs of
/// the top-level instructions that did so: the program itself when the
/// transaction calls it directly, else the program whose calls reached it.
/// [inner] holds the simulation's inner instructions by top-level index.
///
/// Traced, each under the account the review reports the change on: a token
/// `Approve`, `ApproveChecked` or `SetAuthority`, under the token account; a
/// System instruction that assigns an account or hands on a nonce account,
/// under that account; a compressed or Core NFT's delegate, under its asset
/// id; a stake account's authority, a program's upgrade authority, a name's
/// owner and a tree's delegate, under the account that changes hands.
///
/// A call the node parsed for itself has no account list. An approval it
/// parsed names the token account as its `source`, which traces it the same
/// way. Any other that may be one of these adds its top-level program to
/// every account's set, and to [kUntracedDelegations] so that a batch's other
/// transactions count it too: that can only add a program to a set, never
/// stand in for a traced call. So does an instruction that could not be read
/// and may have set one: an asset program's, a System or Token instruction
/// with no name, and a Token-2022 batch.
Map<String, Set<String>> solanaDelegationOrigins(
  List<CompiledInstruction> instructions,
  List<String> keys,
  Map<int, List<SolanaInnerInstruction>> inner,
) {
  final origins = <String, Set<String>>{};
  final untraced = <String>{};
  for (final (i, top) in instructions.indexed) {
    if (top.programIdIndex >= keys.length) continue;
    final origin = keys[top.programIdIndex];
    void record(String account) =>
        origins.putIfAbsent(account, () => {}).add(origin);
    final calls = <SolanaInnerInstruction>[
      (program: origin, instruction: top, name: null, depth: 1, parsed: null),
      ...?inner[i],
    ];
    for (final call in calls) {
      final instruction = call.instruction;
      if (isSolanaAssetProgram(call.program)) {
        if (instruction == null) {
          untraced.add(origin);
          continue;
        }
        final indexes = instruction.accountKeyIndexes;
        final effect = decodeSolanaAssetInstruction(
          call.program,
          Uint8List.fromList(instruction.data.toList()),
          (i) => i < indexes.length && indexes[i] < keys.length
              ? keys[indexes[i]]
              : null,
        );
        switch (effect) {
          case CompressedNftDelegation(:final assetId) ||
              CoreNftDelegation(:final assetId):
            record(assetId);
          case AuthorityHandover(:final account):
            record(account);
          case UnreadAssetInstruction():
            // It may have set a delegate or an authority, on an account
            // this cannot name.
            untraced.add(origin);
          default:
        }
        continue;
      }
      final system = call.program == solanaSystemProgram;
      if (!system && !_isTokenProgram(call.program)) continue;
      if (instruction == null) {
        final name = call.name;
        if (name != null && !system && name.startsWith('Approve')) {
          final parsed = call.parsed;
          final info = parsed is Map ? parsed['info'] : null;
          final source = info is Map ? info['source'] : null;
          if (source is String && source.isNotEmpty) {
            record(source);
            continue;
          }
        }
        if (name == null ||
            (system
                ? _systemHandoverNames.any(name.startsWith)
                : name.startsWith('Approve') ||
                      name.startsWith('SetAuthority'))) {
          untraced.add(origin);
        }
        continue;
      }
      final data = Uint8List.fromList(instruction.data.toList());
      // System: Assign, AuthorizeNonceAccount, AllocateWithSeed and
      // AssignWithSeed. Token: Approve, SetAuthority and ApproveChecked.
      final sets = system
          ? data.length >= 4 &&
                const {1, 7, 9, 10}.contains(
                  ByteData.sublistView(data).getUint32(0, Endian.little),
                )
          : data.isNotEmpty && const {4, 6, 13}.contains(data[0]);
      if (!sets) {
        // An instruction the compiled-in tables have no name for, and a
        // batch, which runs other token instructions inside itself, may set
        // a delegate or an authority where this cannot see it.
        final name = solanaBuiltInInstructionName(call.program, data);
        if (name == null || name == 'Batch') untraced.add(origin);
        continue;
      }
      final account = instruction.accountKeyIndexes.firstOrNull;
      if (account == null || account >= keys.length) {
        untraced.add(origin);
      } else {
        record(keys[account]);
      }
    }
  }
  return {
    for (final MapEntry(:key, :value) in origins.entries)
      key: {...value, ...untraced},
    if (untraced.isNotEmpty) kUntracedDelegations: untraced,
  };
}

/// How a node names the System instructions that hand an account to a
/// program or a nonce account to a new authority, capitalised as
/// [parseSimulationInnerInstruction] reports them.
const _systemHandoverNames = ['Assign', 'AllocateWithSeed', 'AuthorizeNonce'];

/// One instruction as it runs: a top-level instruction has depth 1, and a
/// call it makes has its simulation-reported stack height. [data] is null,
/// and [name] the node's name for it, for an inner call the node parsed.
typedef SolanaInvocation = ({
  String program,
  Uint8List? data,
  String? name,
  int? depth,
});

/// The transaction's instructions with the simulation's inner instructions
/// after the top-level one that made them: the order they run in.
List<SolanaInvocation> solanaInvocations(
  List<CompiledInstruction> instructions,
  List<String> keys, [
  Map<int, List<SolanaInnerInstruction>> inner = const {},
]) => [
  for (final (i, ix) in instructions.indexed)
    if (ix.programIdIndex < keys.length) ...[
      (
        program: keys[ix.programIdIndex],
        data: Uint8List.fromList(ix.data.toList()),
        name: null,
        depth: 1,
      ),
      for (final call in inner[i] ?? const <SolanaInnerInstruction>[])
        (
          program: call.program,
          data: call.instruction == null
              ? null
              : Uint8List.fromList(call.instruction!.data.toList()),
          name: call.name,
          depth: call.depth,
        ),
    ],
];

/// [call]'s name from its data in [tables], else the node's own name for it.
String? _invocationName(ProgramInstructions tables, SolanaInvocation call) {
  final data = call.data;
  return (data == null ? null : tables.nameOf(call.program, data)) ?? call.name;
}

/// Published instruction tables with known public fallbacks, including when
/// the service is not registered (tests, a build without the list).
ProgramInstructions _publishedInstructions() =>
    GetIt.I.isRegistered<ProgramLabelService>()
    ? GetIt.I<ProgramLabelService>().instructions
    : ProgramInstructions.builtIn;

/// Requested calls named from their data alone, for a transaction whose
/// simulation produced no logs. [instructions] defaults to the published
/// tables.
List<ReviewProgramCall> solanaProgramCalls(
  List<SolanaInvocation> calls, [
  ProgramInstructions? instructions,
]) {
  final tables = instructions ?? _publishedInstructions();
  return [
    for (final call in calls)
      ReviewProgramCall(
        program: call.program,
        instruction: _invocationName(tables, call),
      ),
  ];
}

/// Attribute instruction logs to the active invocation, including nested CPIs.
///
/// [invocations], in the order they run, name the calls the logs leave
/// unnamed — System, Compute Budget, Token Metadata and the Token Program
/// log no `Instruction:` line — from their data, for programs [instructions]
/// has a table for (default: the published tables), or else from the name
/// the node gave a call it parsed. A program's own log line wins: only it
/// can log inside its frame. Each logged invocation takes the next unclaimed
/// one for the same program and depth, so an instruction the logs leave out
/// shifts nothing after it. Calls absent from the logs remain in order and
/// are named from their data; the list describes requested calls, including
/// instructions a failed simulation may not reach.
List<ReviewProgramCall> parseSimulationProgramCalls(
  List<String> logs, {
  List<SolanaInvocation> invocations = const [],
  ProgramInstructions? instructions,
}) {
  final tables = instructions ?? _publishedInstructions();
  final calls = <ReviewProgramCall>[];
  final stack = <_Frame>[];
  final invoke = RegExp(r'^Program (\w+) invoke \[(\d+)\]$');
  final end = RegExp(r'^Program (\w+) (?:success|failed:)');
  final instruction = RegExp(r'^Program log: Instruction: (.+)$');
  var cursor = 0;
  for (final log in logs) {
    final start = invoke.firstMatch(log);
    if (start != null) {
      final program = start[1]!;
      final depth = int.tryParse(start[2]!) ?? 1;
      while (stack.length >= depth && stack.isNotEmpty) {
        stack.removeLast();
      }
      String? decoded;
      for (var i = cursor; i < invocations.length; i++) {
        final candidate = invocations[i];
        if (candidate.program == program &&
            (candidate.depth == null || candidate.depth == depth)) {
          calls.addAll(
            solanaProgramCalls(invocations.sublist(cursor, i), tables),
          );
          decoded = _invocationName(tables, candidate);
          cursor = i + 1;
          break;
        }
      }
      stack.add(_Frame(program, calls.length));
      calls.add(ReviewProgramCall(program: program, instruction: decoded));
      continue;
    }
    final finish = end.firstMatch(log);
    if (finish != null) {
      final i = stack.lastIndexWhere((frame) => frame.program == finish[1]);
      if (i >= 0) stack.removeRange(i, stack.length);
      continue;
    }
    // Any program can log any text here, so only a bare identifier, the
    // form the published names must take too, may name its call. Bidi
    // controls, look-alike letters or a sentence leave the call as decoded.
    final name = instruction.firstMatch(log)?[1]?.trim();
    if (name != null &&
        ProgramLabelService.isInstructionName(name) &&
        stack.isNotEmpty) {
      final frame = stack.last;
      if (!frame.logged) {
        frame.logged = true;
        calls[frame.index] = ReviewProgramCall(
          program: frame.program,
          instruction: name,
        );
      } else {
        calls.add(ReviewProgramCall(program: frame.program, instruction: name));
      }
    }
  }
  calls.addAll(solanaProgramCalls(invocations.sublist(cursor), tables));
  return calls;
}

/// A running invocation in [parseSimulationProgramCalls]: its entry in the
/// call list, and whether its first log line has named it yet.
class _Frame {
  _Frame(this.program, this.index);
  final String program;
  final int index;
  bool logged = false;
}

/// One review for a batch approved as a whole. Each transaction was simulated
/// on its own, so the parts are added up rather than replayed in order:
///
/// * net balance changes sum per asset and account, outflows and inflows
///   apart: the site chooses which signed transactions it broadcasts, so
///   one part's receipt may never land and cannot offset another part's
///   spend. Each part's own net change is kept whole; across parts the
///   review shows what can leave and what may arrive as separate rows;
/// * a transaction that has no net changes contributes its requested
///   transfers instead, so no part's movements drop out of the hero;
/// * every account, NFT and permission change, warning and metadata entry is
///   kept;
/// * execution is the worst of the parts, coverage is complete only when
///   every part's is, and the fee is the total, unknown if any part's is;
/// * [SimulationReview.transactions] keeps each part's program calls and
///   Explorer link, in order.
///
/// [error] replaces the error composed from the parts. A single review comes
/// back unchanged.
SimulationReview combineSolanaReviews(
  List<SimulationReview> parts, {
  String? error,
}) {
  if (parts.isEmpty) throw ArgumentError.value(parts, 'parts', 'is empty');
  if (parts.length == 1 && error == null) return parts.single;
  final first = parts.first;
  final executions = parts.map((p) => p.execution).toSet();
  final execution = executions.contains(SimulationExecution.failed)
      ? SimulationExecution.failed
      : executions.contains(SimulationExecution.unavailable)
      ? SimulationExecution.unavailable
      : SimulationExecution.succeeded;
  final coverages = parts.map((p) => p.coverage).toSet();
  final coverage = coverages.length == 1
      ? coverages.single
      : SimulationCoverage.partial;

  final funds = <FundChange>[];
  // Keyed by asset and account; each holds that key's outflow and inflow
  // totals, which are never added to each other.
  final net = <String, ({FundChange? out, FundChange? into})>{};
  FundChange add(FundChange? previous, FundChange fund) => previous == null
      ? fund
      : FundChange(
          asset: previous.asset.decimals != null ? previous.asset : fund.asset,
          address: fund.address,
          rawAmount: previous.rawAmount + fund.rawAmount,
          evidence: _weaker(previous.evidence, fund.evidence),
          isNet: true,
        );
  final anyNet = parts.any((p) => p.funds.any((f) => f.isNet));
  for (final part in parts) {
    final hasNet = part.funds.any((f) => f.isNet);
    for (final fund in part.funds) {
      if (fund.isNet) {
        final key = '${fund.asset.id}:${fund.address}';
        final previous = net[key] ?? (out: null, into: null);
        net[key] = fund.rawAmount.isNegative
            ? (out: add(previous.out, fund), into: previous.into)
            : (out: previous.out, into: add(previous.into, fund));
      } else if (anyNet && !hasNet) {
        // The review shows net changes whenever there are any; without this,
        // a part whose simulation did not run would vanish from it.
        funds.add(
          FundChange(
            asset: fund.asset,
            address: fund.address,
            rawAmount: fund.rawAmount,
            evidence: fund.evidence,
            from: fund.from,
            to: fund.to,
            isNet: true,
          ),
        );
      } else {
        funds.add(fund);
      }
    }
  }

  int? fee = 0;
  for (final part in parts) {
    final lamports = part.feeLamports;
    fee = fee == null || lamports == null ? null : fee + lamports;
  }
  // With mixed fee payers, every fee is counted as the wallet's whenever it
  // pays any: the step-up estimate may overcount but never undercount.
  final feePayer = parts.every((p) => p.feePayer == first.feePayer)
      ? first.feePayer
      : parts.any((p) => p.feePayer == first.address)
      ? first.address
      : null;

  return SimulationReview(
    payloadDigest: sha256
        .convert(utf8.encode(parts.map((p) => p.payloadDigest).join(',')))
        .toString(),
    origin: first.origin,
    walletId: first.walletId,
    address: first.address,
    chain: first.chain,
    simulatedAt: parts
        .map((p) => p.simulatedAt)
        .reduce((a, b) => a.isBefore(b) ? a : b),
    execution: execution,
    coverage: coverage,
    effectsUndecodable: parts.any((p) => p.effectsUndecodable),
    feeLamports: execution == SimulationExecution.succeeded ? fee : null,
    feePayer: feePayer,
    error: error ?? _batchError(parts),
    nftMetadata: _mergeNftMetadata(parts),
    tokenMetadata: {for (final part in parts) ...part.tokenMetadata},
    assets: {for (final part in parts) ...part.assets},
    programCalls: [for (final part in parts) ...part.programCalls],
    transactions: [
      for (final part in parts)
        ReviewTransaction(
          execution: part.execution,
          explorerUrl: part.explorerUrl,
          programCalls: part.programCalls,
        ),
    ],
    warnings: {for (final part in parts) ...part.warnings}.toList(),
    funds: [
      for (final change in net.values) ...[?change.out, ?change.into],
      ...funds,
    ],
    accounts: [for (final part in parts) ...part.accounts],
    nfts: [for (final part in parts) ...part.nfts],
    delegatedBy: {
      for (final account in {
        for (final part in parts) ...part.delegatedBy.keys,
      })
        account: {for (final part in parts) ...?part.delegatedBy[account]},
    },
  );
}

/// Every part's NFT names and images. Parts look an NFT up separately, so
/// one may know it only as a placeholder; what any part learned is kept.
Map<String, ReviewNftMetadata> _mergeNftMetadata(List<SimulationReview> parts) {
  final merged = <String, ReviewNftMetadata>{};
  for (final part in parts) {
    for (final MapEntry(key: id, value: next) in part.nftMetadata.entries) {
      final previous = merged[id];
      merged[id] = previous == null
          ? next
          : ReviewNftMetadata(
              name: previous.name ?? next.name,
              imageUrl: previous.imageUrl ?? next.imageUrl,
            );
    }
  }
  return merged;
}

/// The less certain of two sources, ranked as the review's caption ranks
/// them: inferred, then requested, then program-reported, then simulated.
ReviewEvidence _weaker(ReviewEvidence a, ReviewEvidence b) {
  int rank(ReviewEvidence e) => switch (e) {
    ReviewEvidence.simulatedState => 0,
    ReviewEvidence.event => 1,
    ReviewEvidence.requestedInstruction => 2,
    ReviewEvidence.inferred => 3,
  };
  return rank(a) >= rank(b) ? a : b;
}

/// The parts' errors, each named by its transaction's place in the batch.
String? _batchError(List<SimulationReview> parts) {
  final count = parts.length;
  final failed = [
    for (var i = 0; i < count; i++)
      if (parts[i].execution == SimulationExecution.failed) i,
  ];
  if (failed.isNotEmpty) {
    const prefix = 'Simulation failed: ';
    final details = [
      for (final i in failed)
        switch (parts[i].error) {
          final String e when e.startsWith(prefix) =>
            'Transaction ${i + 1}: ${e.substring(prefix.length)}',
          _ => 'Transaction ${i + 1} failed',
        },
    ];
    return '$prefix${details.join('\n')}';
  }
  final unavailable = [
    for (var i = 0; i < count; i++)
      if (parts[i].execution == SimulationExecution.unavailable) i + 1,
  ];
  if (unavailable.isEmpty) return null;
  if (unavailable.length == count) {
    return 'Simulation is unavailable. The effects and cost of these transactions could not be verified.';
  }
  final names = unavailable.length == 1
      ? 'transaction ${unavailable.single}'
      : 'transactions ${unavailable.sublist(0, unavailable.length - 1).join(', ')} and ${unavailable.last}';
  return 'Simulation is unavailable for $names of $count. ${unavailable.length == 1 ? 'Its' : 'Their'} effects and cost could not be verified.';
}
