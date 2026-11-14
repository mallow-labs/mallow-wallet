import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';
import 'package:wallet/wallet.dart' show EtherAmount, EthereumAddress;
import 'package:web3dart/web3dart.dart' show Transaction, keccak256;

import '../../../core/config/environment.dart';
import '../../../core/crypto/derivation.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/data/mallow_tokens.dart'
    show ethMint, mallowTokenMints, tokenByMint;
import '../../../core/models/simulation_review.dart';
import '../../../core/network/ethereum_rpc_service.dart';
import '../../../core/network/kept_alive_http.dart';
import '../../../core/network/evm_simulation_decoder.dart';
import '../../../core/services/pending_evm_tx_tracker.dart';
import '../../../core/services/preferences_service.dart';
import '../../portfolio/services/portfolio_received_reporter.dart';
import '../../send/models/eth_gas.dart';
import '../models/dapp_message_review.dart';
import '../models/dapp_request.dart';
import 'browser_transaction_tracker.dart';
import '../../../core/crypto/eip712.dart';

/// The one EVM network the browser serves. Ethereum is mainnet-only in every
/// environment, so unlike Solana there is no devnet here.
const ethereumMainnet = 'eip155:1';

/// The token registry keys ETH by its bridged mint. Native ETH borrows that id
/// so a review shows the registry's symbol, logo and price for it.
const evmNativeAssetId = ethMint;

// Fivefold headroom tolerates estimate drift while flagging excessive exposure.
const _gasLimitWarningMultiple = 5;

// Fivefold market fees allow urgency without hiding unusually expensive tips.
const _siteFeeWarningMultiple = 5;

const _native = ReviewAsset(
  id: evmNativeAssetId,
  symbol: 'ETH',
  decimals: 18,
  verified: true,
);

/// The bluest-chip ERC-20s, shown as verified with their own symbol. Any other
/// contract is an unverified token, whatever symbol it reports.
const _knownTokens = <String, ReviewAsset>{
  '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2': ReviewAsset(
    id: '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2',
    symbol: 'WETH',
    decimals: 18,
    verified: true,
  ),
  '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48': ReviewAsset(
    id: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
    symbol: 'USDC',
    decimals: 6,
    verified: true,
  ),
  '0xdac17f958d2ee523a2206206994597c13d831ec7': ReviewAsset(
    id: '0xdac17f958d2ee523a2206206994597c13d831ec7',
    symbol: 'USDT',
    decimals: 6,
    verified: true,
  ),
  '0x6b175474e89094c44da98b954eedeac495271d0f': ReviewAsset(
    id: '0x6b175474e89094c44da98b954eedeac495271d0f',
    symbol: 'DAI',
    decimals: 18,
    verified: true,
  ),
};

/// Uniswap's Permit2: a signature for it is a spending permission.
const permit2Address = '0x000000000022d473030f116ddee9f6b43ac78ba3';

/// Symbols an unverified token may not borrow (see [ReviewTokenMetadata]).
final Set<String> _reservedSymbols = {
  'eth',
  for (final token in _knownTokens.values) token.symbol.toLowerCase(),
  for (final mint in mallowTokenMints) ?tokenByMint(mint)?.symbol.toLowerCase(),
};

final _zero = '0x${'0' * 40}';
final _uint256Max = (BigInt.one << 256) - BigInt.one;

/// ERC-20 calls made on the token itself: `transfer`, `approve`,
/// `transferFrom`, `increaseAllowance` and `decreaseAllowance`.
const _tokenCallSelectors = {
  '0xa9059cbb',
  '0x095ea7b3',
  '0x23b872dd',
  '0x39509351',
  '0xa457c2d7',
};

typedef EthereumDappRpc =
    Future<Object?> Function(String method, List<Object?> params);
typedef EthereumDappSimulate =
    Future<EvmSimulationResult> Function({
      required String from,
      required String to,
      required String data,
      String value,
    });

/// Only the structured RPC error reaches a website: a node's message can name
/// its own URL or upstream, so it is never forwarded verbatim. Revert data is
/// kept because a website needs it to decode its own contract's error.
class EthereumDappRpcException implements Exception {
  const EthereumDappRpcException(this.code, {this.revertData, this.message});
  final int code;
  final String? revertData;

  /// The node's own text, kept only to classify a broadcast failure (the
  /// codes are not standardised across clients). Never shown or returned.
  final String? message;
}

/// The read-only methods a page may run through the wallet's node, as an
/// injected provider must for libraries that route every call through it.
/// Nothing here can sign, send, or change node state.
const ethereumReadMethods = {
  'eth_blockNumber',
  'eth_call',
  'eth_estimateGas',
  'eth_feeHistory',
  'eth_gasPrice',
  'eth_getBalance',
  'eth_getBlockByHash',
  'eth_getBlockByNumber',
  'eth_getCode',
  'eth_getLogs',
  'eth_getStorageAt',
  'eth_getTransactionByHash',
  'eth_getTransactionCount',
  'eth_getTransactionReceipt',
  'eth_maxPriorityFeePerGas',
};

/// A website's `eth_sendTransaction` request, validated. Gas and fee values
/// are the website's suggestions; the nonce is never taken from the website.
class EthereumDappTransactionRequest {
  EthereumDappTransactionRequest._({
    required this.from,
    required this.to,
    required this.value,
    required Uint8List data,
    this.gas,
    this.maxFeePerGas,
    this.maxPriorityFeePerGas,
    this.gasPrice,
  }) : data = Uint8List.fromList(data).asUnmodifiableView();

  /// [account] is the connected address, which a request without `from`
  /// defaults to and a request with one must name.
  factory EthereumDappTransactionRequest.parse(
    Object? raw, {
    required String account,
  }) {
    if (raw is! Map) {
      throw const DappException(-32602, 'Transaction must be an object.');
    }
    for (final key in raw.keys) {
      if (_refused.contains(key)) {
        // EIP-7702 delegation hands the account's code to a contract; blob
        // transactions are not a website flow. Neither is ever signed here.
        throw const DappException(
          4200,
          'This transaction type is not supported.',
        );
      }
    }
    final type = raw['type'];
    if (type != null && type != '0x2' && type != '0x0' && type != '0x02') {
      throw const DappException(
        4200,
        'This transaction type is not supported.',
      );
    }
    final chainId = raw['chainId'];
    if (chainId != null && _quantity(chainId, 'chainId') != BigInt.one) {
      throw const DappException(4901, 'Switch to Ethereum mainnet first.');
    }
    final from = raw['from'] == null
        ? account.toLowerCase()
        : _address(raw['from'], 'from');
    if (from != account.toLowerCase()) {
      throw const DappException(
        4100,
        'The transaction is not from the connected account.',
      );
    }
    if (raw['to'] == null) {
      throw const DappException(4200, 'Contract deployment is not supported.');
    }
    final dataField = raw['data'] ?? raw['input'];
    if (raw['data'] != null &&
        raw['input'] != null &&
        raw['data'] != raw['input']) {
      throw const DappException(-32602, 'data and input disagree.');
    }
    final data = dataField == null ? Uint8List(0) : _bytes(dataField, 'data');
    if (data.length > 131072) {
      throw const DappException(-32602, 'Transaction data is too large.');
    }
    final gas = raw['gas'] ?? raw['gasLimit'];
    return EthereumDappTransactionRequest._(
      from: from,
      to: _address(raw['to'], 'to'),
      value: raw['value'] == null
          ? BigInt.zero
          : _quantity(raw['value'], 'value'),
      data: data,
      gas: gas == null ? null : _quantity(gas, 'gas'),
      maxFeePerGas: raw['maxFeePerGas'] == null
          ? null
          : _quantity(raw['maxFeePerGas'], 'maxFeePerGas'),
      maxPriorityFeePerGas: raw['maxPriorityFeePerGas'] == null
          ? null
          : _quantity(raw['maxPriorityFeePerGas'], 'maxPriorityFeePerGas'),
      gasPrice: raw['gasPrice'] == null
          ? null
          : _quantity(raw['gasPrice'], 'gasPrice'),
    );
  }

  /// Lower-cased addresses.
  final String from;
  final String to;
  final BigInt value;
  final Uint8List data;
  final BigInt? gas;
  final BigInt? maxFeePerGas;
  final BigInt? maxPriorityFeePerGas;
  final BigInt? gasPrice;

  static const _refused = {
    'authorizationList',
    'blobVersionedHashes',
    'blobs',
    'maxFeePerBlobGas',
    'sidecars',
  };

  /// The canonical form the coordinator digests and the adapter re-parses, so
  /// the bytes approved are the bytes prepared.
  Map<String, Object?> toJson() => {
    'from': from,
    'to': to,
    'value': _hexQuantity(value),
    'data': _hexBytes(data),
    if (gas != null) 'gas': _hexQuantity(gas!),
    if (maxFeePerGas != null) 'maxFeePerGas': _hexQuantity(maxFeePerGas!),
    if (maxPriorityFeePerGas != null)
      'maxPriorityFeePerGas': _hexQuantity(maxPriorityFeePerGas!),
    if (gasPrice != null) 'gasPrice': _hexQuantity(gasPrice!),
  };
}

/// A website transaction filled, simulated and priced, ready to review. The
/// simulation does not depend on the fee, so [EthereumDappAdapter.applyGas]
/// re-prices it without simulating again.
class PreparedEthereumTransaction {
  PreparedEthereumTransaction({
    required this.request,
    required this.transaction,
    required this.review,
    required this.nonce,
    required this.gasLimit,
    required this.maxFeePerGas,
    required this.maxPriorityFeePerGas,
    required this.estimatedGas,
    required this.defaultGasLimit,
    this.market,
    this.selection,
    this.baseFee,
    this.feeFromSite = false,
    this.baseWarnings = const [],
  });
  final EthereumDappTransactionRequest request;
  final Transaction transaction;
  final SimulationReview review;
  final int nonce;
  final int gasLimit;
  final BigInt maxFeePerGas;
  final BigInt maxPriorityFeePerGas;

  /// The node's gas estimate, or the website's limit when estimating failed.
  final BigInt estimatedGas;

  /// The limit used unless the user sets one: the estimate with headroom, or
  /// the website's own.
  final int defaultGasLimit;

  /// The live fee market. Null when the gas API is unavailable, and then the
  /// fee cannot be edited.
  final EthGasMarket? market;

  /// The fee choice in force, as the Edit Gas Fee sheet expresses it. Null
  /// exactly when [market] is.
  final EthGasSelection? selection;
  final BigInt? baseFee;

  /// The fee is the one the website suggested, not one the user picked.
  final bool feeFromSite;

  /// Review warnings that do not depend on the fee.
  final List<String> baseWarnings;

  bool get canEditFee => market != null && selection != null;
}

/// One transaction's preparation, from [EthereumDappAdapter.startTransaction].
class EthereumPreparation {
  EthereumPreparation._(this._reviewed, this._signable);

  final Future<PreparedEthereumTransaction> Function() _reviewed;
  final Future<PreparedEthereumTransaction> Function() _signable;
  Future<PreparedEthereumTransaction>? _reviewedFuture;
  Future<PreparedEthereumTransaction>? _signableFuture;

  /// Simulated, with the full review.
  Future<PreparedEthereumTransaction> get reviewed =>
      _reviewedFuture ??= _reviewed();

  /// Signable without the simulation: nonce, gas and fee filled, effects
  /// taken from the request alone.
  Future<PreparedEthereumTransaction> get signable =>
      _signableFuture ??= _signable();
}

/// The reads one transaction's preparation needs, each started once.
class _EthereumReads {
  _EthereumReads({
    required this.nonce,
    required this.market,
    required this.estimate,
    required this.simulation,
    required this.code,
    required Future<BigInt?> Function() baseFee,
  }) : _readBaseFee = baseFee;

  final Future<Object?> nonce;
  final Future<EthGasMarket> market;
  final Future<Object?> estimate;
  final Future<EvmSimulationResult> simulation;
  final Future<Object?>? code;

  /// Token reads this review has made, so the one started with the
  /// simulation is the one the review awaits.
  final tokens = <String, Future<(ReviewAsset, String?)>>{};
  final Future<BigInt?> Function() _readBaseFee;
  Future<BigInt?>? _baseFee;

  /// Read on first use: only a review without a fee market needs it.
  Future<BigInt?> get baseFee => _baseFee ??= _readBaseFee();
}

class EthereumMessageReview extends DappMessageReview {
  EthereumMessageReview({
    required Uint8List bytes,
    required this.origin,
    required this.address,
    required this.walletId,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  @override
  final Uint8List bytes;
  @override
  final String origin;
  @override
  final String address;
  final String walletId;

  Uint8List get personalDigest =>
      MultiChainDerivation.ethereumPersonalMessageDigest(bytes);

  @override
  String get digestLabel => 'EIP-191 hash';
  @override
  String get digest => _hexBytes(personalDigest).substring(2);

  /// Sign In With Ethereum (EIP-4361) fields; see [parseSignInMessage].
  @override
  Map<String, String> get signInFields => _signIn?.fields ?? const {};
  @override
  String? get signInStatement => _signIn?.statement;

  @override
  String? get signInNetworkWarning {
    final chainId = signInFields['Chain ID'];
    if (chainId == null || chainId == '1') return null;
    return 'The message asks to sign in on Chain ID $chainId, but this wallet uses Ethereum mainnet (Chain ID 1).';
  }

  SignInMessage? get _signIn => parseSignInMessage(
    text,
    address: address,
    chain: 'Ethereum',
    resources: true,
    caseInsensitive: true,
  );
}

/// What a typed-data signature authorizes, as far as this wallet can tell.
/// [generic] is everything it does not recognise: the review lists the signed
/// fields but cannot say what the contract will do with them, so it is
/// treated as cautiously as the kinds known to move assets.
enum TypedDataKind { generic, permit, permit2, transfer, order }

/// A spending permission a typed-data signature grants once submitted.
class TypedDataPermission {
  const TypedDataPermission({
    required this.token,
    required this.spender,
    this.amount,
    this.expires,
  });

  /// Lower-cased token contract.
  final String token;
  final String spender;

  /// Null when unlimited.
  final BigInt? amount;
  final DateTime? expires;
}

/// A token transfer a typed-data signature authorizes once submitted
/// (EIP-3009 `TransferWithAuthorization` / `ReceiveWithAuthorization`).
class TypedDataTransfer {
  const TypedDataTransfer({
    required this.token,
    required this.from,
    required this.recipient,
    required this.amount,
    this.validFrom,
    this.expires,
  });

  /// Lower-cased token contract: the domain's `verifyingContract`.
  final String token;

  /// Lower-cased account the tokens leave.
  final String from;
  final String recipient;
  final BigInt amount;

  /// When the authorization starts to be valid; null when it already is
  /// (`validAfter` of zero).
  final DateTime? validFrom;

  /// When it stops (`validBefore`); null when that is not a readable time.
  final DateTime? expires;
}

/// The fields of an EIP-3009 authorization and their types. A payload is
/// summarised as a transfer only when its primary type declares exactly
/// these, so every value the transfer card shows is one the digest covers
/// under the meaning the card gives it.
const _transferAuthorizationFields = {
  'from': 'address',
  'to': 'address',
  'value': 'uint256',
  'validAfter': 'uint256',
  'validBefore': 'uint256',
  'nonce': 'bytes32',
};

bool _isTransferAuthorization(Eip712TypedData data) {
  if (data.primaryType != 'TransferWithAuthorization' &&
      data.primaryType != 'ReceiveWithAuthorization') {
    return false;
  }
  final fields = data.types[data.primaryType]!;
  return fields.length == _transferAuthorizationFields.length &&
      fields.every(
        (field) => _transferAuthorizationFields[field.name] == field.type,
      );
}

class EthereumTypedDataReview {
  EthereumTypedDataReview({
    required this.data,
    required this.origin,
    required this.address,
    required this.walletId,
    required this.kind,
    this.permissions = const [],
    this.transfers = const [],
    this.unsummarizedPermissionCount = 0,
    this.tokens = const {},
  });
  final Eip712TypedData data;
  final String origin;
  final String address;
  final String walletId;
  final TypedDataKind kind;
  final List<TypedDataPermission> permissions;
  final List<TypedDataTransfer> transfers;

  /// Payload entries omitted by the summary cap or not decoded as permissions.
  final int unsummarizedPermissionCount;

  /// Display assets for the token contracts in permissions and transfers.
  final Map<String, ReviewAsset> tokens;
}

/// Ethereum counterpart of the browser's Solana adapter: reads through the
/// configured Ethereum node, simulates through the configured simulation
/// endpoint, and signs only through [WalletManager]. Every signature is
/// recovered and checked against the approved address before it leaves.
class EthereumDappAdapter {
  EthereumDappAdapter({
    required this.walletManager,
    EthereumDappRpc? rpc,
    EthereumDappSimulate? simulate,
    Future<EthGasMarket> Function()? gasMarket,
    PreferencesService? preferences,
    BrowserTransactionTracker? tracker,
    void Function(PendingEvmBroadcast)? onBroadcast,
    void Function({required String txHash, required String address})?
    onNftReceived,
  }) : _rpc = rpc ?? _defaultRpc,
       // A cache belongs to the node it was read from.
       _tokenInfo = rpc == null ? _sharedTokenInfo : {},
       _simulate = simulate ?? _defaultSimulate,
       _gasMarket = gasMarket ?? _defaultGasMarket,
       _preferences = preferences,
       _tracker = tracker ?? BrowserTransactionTracker.instance,
       _onBroadcast = onBroadcast ?? notifyPendingEvmBroadcast,
       _onNftReceived = onNftReceived ?? reportEthereumReceived;
  final WalletManager walletManager;
  final EthereumDappRpc _rpc;
  final EthereumDappSimulate _simulate;

  /// Decimals and symbols already read, by contract, oldest first. A token's
  /// do not change in practice, so a later review of it does not read them
  /// again. Only a read that found the decimals is kept.
  final Map<String, (ReviewAsset, String?)> _tokenInfo;
  static final _sharedTokenInfo = <String, (ReviewAsset, String?)>{};
  final Future<EthGasMarket> Function() _gasMarket;
  final PreferencesService? _preferences;
  final BrowserTransactionTracker _tracker;
  final void Function(PendingEvmBroadcast) _onBroadcast;

  /// Called once when a transaction [sendSigned] broadcast mines successfully
  /// and moved an NFT to the signing wallet. Defaults to reporting it to the
  /// backend, which indexes the token so a purchase shows in My Art.
  final void Function({required String txHash, required String address})
  _onNftReceived;

  BrowserTransactionTracker get tracker => _tracker;

  /// One client for every adapter, so a review's calls reuse one kept-alive
  /// connection instead of each paying for its own TLS handshake.
  static final _dio = keptAliveDio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  /// Opens the connections a review reads through: three to the node, for
  /// the nonce, gas estimate and code reads that go out together, and the
  /// simulation endpoint's.
  static Future<void> warmConnections() => Future.wait([
    openConnections(dioHead(_dio), Config.ethereumRpcUrl, connections: 3),
    if (GetIt.I.isRegistered<EthereumRpcService>())
      GetIt.I<EthereumRpcService>().warmConnections(),
  ]);

  static Future<Object?> _defaultRpc(
    String method,
    List<Object?> params,
  ) async {
    final url = Config.ethereumRpcUrl;
    final response = await _dio.post<Object?>(
      url,
      data: {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params},
      options: Options(headers: Config.clientIdHeadersFor(Uri.parse(url))),
    );
    final body = _map(response.data);
    final error = body['error'];
    if (error != null) {
      final code = _map(error)['code'];
      final data = _map(error)['data'];
      final message = _map(error)['message'];
      throw EthereumDappRpcException(
        code is int ? code : -32000,
        message: message is String ? message : null,
        revertData:
            data is String &&
                data.length <= 65538 &&
                RegExp(r'^0x[0-9a-fA-F]*$').hasMatch(data)
            ? data
            : null,
      );
    }
    if (!body.containsKey('result')) throw const FormatException();
    return body['result'];
  }

  static Future<EthGasMarket> _defaultGasMarket() =>
      EthGasMarket.fetch(GetIt.I<EthereumRpcService>());

  static Future<EvmSimulationResult> _defaultSimulate({
    required String from,
    required String to,
    required String data,
    String value = '0x0',
  }) => GetIt.I<EthereumRpcService>().simulateAssetChanges(
    from: from,
    to: to,
    data: data,
    value: value,
  );

  /// A page's read through the wallet's node. Methods outside
  /// [ethereumReadMethods] never reach the network.
  Future<Object?> read(String method, List<Object?> params) async {
    if (!ethereumReadMethods.contains(method)) {
      throw const DappException(4200, 'Unsupported method.');
    }
    try {
      return await _rpc(method, params);
    } on EthereumDappRpcException catch (error) {
      if (error.code == 3 || error.revertData != null) {
        throw DappException(3, 'execution reverted', data: error.revertData);
      }
      throw const DappException(-32603, 'The Ethereum node request failed.');
    } catch (_) {
      throw const DappException(-32603, 'The Ethereum node request failed.');
    }
  }

  // --- Messages -----------------------------------------------------------

  EthereumMessageReview prepareMessage({
    required Uint8List bytes,
    required String origin,
    required String address,
    required String walletId,
  }) {
    if (bytes.length > 65536) {
      throw const DappException(-32602, 'Message is too large.');
    }
    return EthereumMessageReview(
      bytes: bytes,
      origin: origin,
      address: address,
      walletId: walletId,
    );
  }

  Future<Uint8List> signMessage(
    EthereumMessageReview review, {
    required void Function() ensureActive,
    Future<void>? cancelled,
  }) async {
    ensureActive();
    final signature = await walletManager.signEthereumPersonalMessageForWallet(
      review.walletId,
      review.bytes,
      expectedAddress: review.address,
      ensureActive: ensureActive,
      cancelled: cancelled,
    );
    ensureActive();
    verifyEthereumSignature(review.personalDigest, signature, review.address);
    return signature;
  }

  // --- Typed data ---------------------------------------------------------

  Future<EthereumTypedDataReview> prepareTypedData({
    required Object? typedData,
    required String origin,
    required String address,
    required String walletId,
  }) async {
    final Eip712TypedData data;
    try {
      data = Eip712TypedData.parse(typedData);
    } on Eip712Exception catch (error) {
      throw DappException(-32602, error.message);
    }
    final chainId = data.chainId;
    if (chainId != null && chainId != BigInt.one) {
      throw const DappException(4901, 'This signature is for another network.');
    }
    final contract = data.verifyingContract;
    final message = data.message;
    var kind = TypedDataKind.generic;
    final permissions = <TypedDataPermission>[];
    final transfers = <TypedDataTransfer>[];
    var unsummarizedPermissionCount = 0;
    if (contract == permit2Address) {
      kind = TypedDataKind.permit2;
      permissions.addAll(_permit2Permissions(data));
      final details = message['details'] ?? message['permitted'];
      unsummarizedPermissionCount =
          (details is List ? details.length : 1) - permissions.length;
    } else if (data.primaryType == 'Permit' &&
        contract != null &&
        message['spender'] is String) {
      // EIP-2612 carries `value` and `deadline`; the DAI variant carries
      // `allowed` and `expiry`, and `allowed: true` is unlimited.
      kind = TypedDataKind.permit;
      final value = eip712Integer(message['value']);
      final allowed = message['allowed'];
      final deadline = eip712Integer(message['deadline'] ?? message['expiry']);
      // An unrecognised amount stays in the exact data; null on a permission
      // means unlimited, so it must never stand for an unknown amount.
      if (allowed is bool || value != null) {
        permissions.add(
          TypedDataPermission(
            token: contract,
            spender: (message['spender'] as String).toLowerCase(),
            amount: allowed is bool
                ? (allowed ? null : BigInt.zero)
                : (value == _uint256Max ? null : value),
            expires: _timestamp(deadline),
          ),
        );
      }
    } else if (contract != null && _isTransferAuthorization(data)) {
      kind = TypedDataKind.transfer;
      transfers.add(
        TypedDataTransfer(
          token: contract,
          from: (message['from'] as String).toLowerCase(),
          recipient: (message['to'] as String).toLowerCase(),
          amount: eip712Integer(message['value'])!,
          validFrom: _timestamp(eip712Integer(message['validAfter'])),
          expires: _timestamp(eip712Integer(message['validBefore'])),
        ),
      );
    } else if (data.primaryType == 'OrderComponents' ||
        data.primaryType == 'Order' ||
        data.primaryType == 'BulkOrder') {
      kind = TypedDataKind.order;
    }
    final tokens = <String, ReviewAsset>{};
    final reads = {
      for (final token in {
        ...permissions.map((p) => p.token),
        ...transfers.map((t) => t.token),
      }.take(10))
        token: _knownTokens[token] != null
            ? Future.value(_knownTokens[token]!)
            : _token(token).then((info) => info.$1),
    };
    for (final MapEntry(:key, :value) in reads.entries) {
      tokens[key] = await value;
    }
    return EthereumTypedDataReview(
      data: data,
      origin: origin,
      address: address,
      walletId: walletId,
      kind: kind,
      permissions: permissions,
      transfers: transfers,
      unsummarizedPermissionCount: unsummarizedPermissionCount,
      tokens: tokens,
    );
  }

  List<TypedDataPermission> _permit2Permissions(Eip712TypedData data) {
    final message = data.message;
    final spender = message['spender'];
    if (spender is! String) return const [];
    final deadline = _timestamp(
      eip712Integer(message['sigDeadline'] ?? message['deadline']),
    );
    TypedDataPermission? from(Object? details) {
      if (details is! Map || details['token'] is! String) return null;
      final amount = eip712Integer(details['amount']);
      final expiration = _timestamp(eip712Integer(details['expiration']));
      return TypedDataPermission(
        token: (details['token'] as String).toLowerCase(),
        spender: spender.toLowerCase(),
        // uint160 max is Permit2's "unlimited".
        amount: amount == null || amount >= (BigInt.one << 160) - BigInt.one
            ? null
            : amount,
        expires: expiration ?? deadline,
      );
    }

    final details = message['details'] ?? message['permitted'];
    return [
      if (details is List)
        for (final item in details.take(20)) ?from(item)
      else
        ?from(details),
    ];
  }

  Future<Uint8List> signTypedData(
    EthereumTypedDataReview review, {
    required void Function() ensureActive,
    Future<void>? cancelled,
  }) async {
    ensureActive();
    final digest = review.data.digest;
    final signature = await walletManager.signEthereumTypedDataForWallet(
      review.walletId,
      review.data,
      expectedAddress: review.address,
      ensureActive: ensureActive,
      cancelled: cancelled,
    );
    ensureActive();
    verifyEthereumSignature(digest, signature, review.address);
    return signature;
  }

  // --- Transactions -------------------------------------------------------

  /// Fills nonce, gas and fees, simulates, and builds the review. The
  /// simulation decides nothing here: like the Solana review, a failed one
  /// shows as failed and an unavailable one as unavailable, and the review
  /// sheet and step-up gate take it from there.
  Future<PreparedEthereumTransaction> prepareTransaction({
    required EthereumDappTransactionRequest request,
    required String walletId,
    required String address,
    required String origin,
  }) => startTransaction(
    request: request,
    walletId: walletId,
    address: address,
    origin: origin,
  ).reviewed;

  /// Starts preparing [request], with both outcomes drawn from one set of
  /// reads: [EthereumPreparation.reviewed] as [prepareTransaction] returns it,
  /// and [EthereumPreparation.signable], ready as soon as nonce, gas and fee
  /// are, for a user who approves without waiting for the review.
  EthereumPreparation startTransaction({
    required EthereumDappTransactionRequest request,
    required String walletId,
    required String address,
    required String origin,
  }) {
    final from = request.from;
    final dataHex = _hexBytes(request.data);
    final valueHex = _hexQuantity(request.value);
    // None of these reads needs another's answer, so all go out at once and
    // are awaited in order. Each is held until its await, so one that fails
    // while an earlier one is awaited is not reported as unhandled.
    Future<T> start<T>(Future<T> Function() read) =>
        Future.sync(read)..ignore();
    final reads = _EthereumReads(
      nonce: start(() => _call('eth_getTransactionCount', [from, 'pending'])),
      market: start(_gasMarket),
      estimate: start(
        () => _call('eth_estimateGas', [
          {'from': from, 'to': request.to, 'value': valueHex, 'data': dataHex},
        ]),
      ),
      simulation: start(
        () => _simulate(
          from: from,
          to: request.to,
          data: dataHex,
          value: valueHex,
        ),
      ),
      // Only a plain transfer to an address with no code is fully decoded.
      code: request.data.isEmpty
          ? start(() => _call('eth_getCode', [request.to, 'latest']))
          : null,
      baseFee: _baseFee,
    );
    // A token's own call names the token, so its decimals and symbol are
    // read with the simulation rather than after it. The read never fails.
    if (request.data.length >= 4 &&
        _tokenCallSelectors.contains(_hexBytes(request.data.sublist(0, 4))) &&
        _knownTokens[request.to] == null) {
      (reads.tokens[request.to] = _token(request.to)).ignore();
    }
    Future<PreparedEthereumTransaction> prepare({required bool simulated}) =>
        _prepare(
          request: request,
          walletId: walletId,
          address: address,
          origin: origin,
          reads: reads,
          simulated: simulated,
        );
    return EthereumPreparation._(
      () => prepare(simulated: true),
      () => prepare(simulated: false),
    );
  }

  Future<PreparedEthereumTransaction> _prepare({
    required EthereumDappTransactionRequest request,
    required String walletId,
    required String address,
    required String origin,
    required _EthereumReads reads,
    required bool simulated,
  }) async {
    final from = request.from;
    final warnings = <String>[];
    final funds = <FundChange>[];
    final accounts = <AccountChange>[];
    final nfts = <NftChange>[];
    String? error;

    final nonce = _int(await reads.nonce, 'nonce');
    // The same fee market the app's own Ethereum sends price against. Without
    // it the fee is the node-derived default and cannot be edited.
    EthGasMarket? market;
    try {
      market = await reads.market;
      // A tier with no fee is a malformed response, not a free network.
      if (market.low.maxFeePerGas <= BigInt.zero ||
          market.market.maxFeePerGas <= BigInt.zero) {
        market = null;
      }
    } catch (_) {
      market = null;
    }
    var gasLimit = request.gas;
    BigInt? estimate;
    try {
      estimate = _quantity(await reads.estimate, 'gas');
      // A fifth of headroom: state can move between estimate and inclusion.
      gasLimit ??= estimate + estimate ~/ BigInt.from(5);
    } on DappException {
      rethrow;
    } catch (_) {
      if (gasLimit == null) {
        throw const DappException(
          -32000,
          'Gas could not be estimated. This transaction would likely fail.',
        );
      }
      warnings.add('Gas could not be estimated. This transaction may fail.');
    }
    _checkGasLimit(gasLimit);

    var execution = SimulationExecution.unavailable;
    var effectsUndecodable = false;
    if (!simulated) {
      error = 'Approved before the simulation finished.';
    } else {
      try {
        final result = await reads.simulation;
        if (result.error != null) {
          execution = SimulationExecution.failed;
          final detail = result.error!;
          error =
              'Simulation failed: ${detail.length > 400 ? detail.substring(0, 400) : detail}';
        } else {
          execution = SimulationExecution.succeeded;
          _applySimulation(result.changes, from, funds, accounts, nfts);
          // A successful response can omit native traces. It must still show
          // the requested value leaving before its effects can be trusted.
          if (request.value > BigInt.zero &&
              request.to != from &&
              !result.changes.any(
                (change) =>
                    change.assetType == 'NATIVE' &&
                    !change.isApprove &&
                    change.from?.toLowerCase() == from &&
                    (BigInt.tryParse(change.rawAmount ?? '') ?? BigInt.zero) >=
                        request.value,
              )) {
            throw const EvmSimulationDecodeException(
              'Simulation omitted the requested native transfer.',
            );
          }
        }
      } on EvmSimulationDecodeException {
        execution = SimulationExecution.unavailable;
        effectsUndecodable = true;
        error = 'The simulation returned effects this wallet could not decode.';
      } on EthereumRpcException {
        error =
            'Simulation is unavailable. The effects and cost could not be verified.';
      } catch (_) {
        execution = SimulationExecution.unavailable;
        effectsUndecodable = true;
        error = 'The simulation returned effects this wallet could not decode.';
      }
    }
    if (execution != SimulationExecution.succeeded) {
      // Without a simulation, the request itself is the only evidence.
      if (request.value > BigInt.zero) {
        funds.add(
          FundChange(
            asset: _native,
            address: from,
            rawAmount: -request.value,
            evidence: ReviewEvidence.requestedInstruction,
            from: from,
            to: request.to,
            isNet: true,
          ),
        );
      }
    }
    final call = decodeEvmCall(request.to, request.data, from);
    // Successful simulations can omit permission events. Keep the request's
    // permission unless the simulation already describes that asset/spender.
    for (final permission in call.accounts) {
      final reported = accounts.any(
        (account) =>
            (account.kind == AccountChangeKind.approve ||
                account.kind == AccountChangeKind.revoke) &&
            account.assetId?.split(':').first == permission.assetId &&
            account.beneficiary == permission.beneficiary,
      );
      if (!reported) accounts.add(permission);
    }
    if (execution != SimulationExecution.succeeded) {
      funds.addAll(call.funds);
    }

    var complete = false;
    if (execution == SimulationExecution.succeeded && reads.code != null) {
      try {
        final code = await reads.code;
        complete = code == '0x';
      } catch (_) {
        // A contract recipient can do anything; unknown stays partial.
      }
    }
    if (!complete) {
      warnings.add(
        'Some effects could not be decoded. A contract call can change permissions or state that a simulation does not report as asset movements.',
      );
    }

    // Without a market, the base fee comes from the latest block, read once
    // for both the default fee and the estimate, beside the token reads.
    final baseFeeRead = market == null ? reads.baseFee : null;
    final tokenMetadata = <String, ReviewTokenMetadata>{};
    final assets = <String, ReviewAsset>{};
    // Token names and precision are for the review, which an early approval
    // never shows.
    if (simulated) {
      await _resolveTokens(
        funds,
        accounts,
        tokenMetadata,
        assets,
        warnings,
        reads.tokens,
      );
    }

    final siteFee = request.maxFeePerGas != null || request.gasPrice != null;
    final (maxFee, priority) = await _fees(request, market, baseFeeRead);
    final baseFee = market?.baseFeeWei ?? await baseFeeRead;
    final defaultGasLimit = gasLimit.toInt();
    // A website's own fee is honoured as an Advanced choice the user can
    // still change; otherwise the user's saved tier applies, as in-app.
    final selection = market == null
        ? null
        : siteFee
        ? EthGasSelection(
            mode: EthGasMode.custom,
            maxFeePerGas: maxFee,
            maxPriorityFeePerGas: priority,
            gasLimit: defaultGasLimit,
          )
        : EthGasSelection.resolveFromPrefs(
            prefs: _preferences ?? GetIt.I<PreferencesService>(),
            market: market,
            defaultGasLimit: defaultGasLimit,
          );
    final review = SimulationReview(
      programCalls: [
        if (request.data.isNotEmpty)
          ReviewProgramCall(program: request.to, instruction: call.name),
      ],
      tokenMetadata: tokenMetadata,
      assets: assets,
      payloadDigest: '',
      origin: origin,
      walletId: walletId,
      address: address,
      chain: ethereumMainnet,
      simulatedAt: DateTime.now().toUtc(),
      execution: execution,
      effectsUndecodable: effectsUndecodable,
      coverage: complete
          ? SimulationCoverage.complete
          : SimulationCoverage.partial,
      feePayer: address,
      error: error,
      warnings: warnings,
      funds: funds,
      accounts: accounts,
      nfts: nfts,
    );
    return _priced(
      PreparedEthereumTransaction(
        request: request,
        transaction: Transaction(),
        review: review,
        nonce: nonce,
        gasLimit: defaultGasLimit,
        maxFeePerGas: maxFee,
        maxPriorityFeePerGas: priority,
        estimatedGas: estimate ?? gasLimit,
        defaultGasLimit: defaultGasLimit,
        market: market,
        selection: selection,
        baseFee: baseFee,
        feeFromSite: siteFee,
        baseWarnings: List.unmodifiable(warnings),
      ),
      maxFee: selection?.maxFeePerGas ?? maxFee,
      priority: selection?.maxPriorityFeePerGas ?? priority,
      gasLimit: selection?.gasLimit ?? defaultGasLimit,
    );
  }

  /// [prepared] re-priced with the fee the user chose on the Edit Gas Fee
  /// sheet. The simulation, nonce and calldata are unchanged; the signed
  /// bytes, the reviewed digest and the fee lines all follow the new fee.
  PreparedEthereumTransaction applyGas(
    PreparedEthereumTransaction prepared,
    EthGasSelection selection,
  ) {
    if (selection.maxFeePerGas <= BigInt.zero ||
        selection.maxPriorityFeePerGas.isNegative ||
        selection.maxPriorityFeePerGas > selection.maxFeePerGas) {
      throw const DappException(-32602, 'Invalid network fee.');
    }
    _checkGasLimit(BigInt.from(selection.gasLimit));
    return _priced(
      PreparedEthereumTransaction(
        request: prepared.request,
        transaction: prepared.transaction,
        review: prepared.review,
        nonce: prepared.nonce,
        gasLimit: selection.gasLimit,
        maxFeePerGas: selection.maxFeePerGas,
        maxPriorityFeePerGas: selection.maxPriorityFeePerGas,
        estimatedGas: prepared.estimatedGas,
        defaultGasLimit: prepared.defaultGasLimit,
        market: prepared.market,
        selection: selection,
        baseFee: prepared.baseFee,
        feeFromSite:
            prepared.feeFromSite &&
            selection.maxFeePerGas == prepared.maxFeePerGas &&
            selection.maxPriorityFeePerGas == prepared.maxPriorityFeePerGas,
        baseWarnings: prepared.baseWarnings,
      ),
      maxFee: selection.maxFeePerGas,
      priority: selection.maxPriorityFeePerGas,
      gasLimit: selection.gasLimit,
    );
  }

  /// Builds the transaction to sign and the fee-dependent half of the review
  /// for one fee choice.
  PreparedEthereumTransaction _priced(
    PreparedEthereumTransaction base, {
    required BigInt maxFee,
    required BigInt priority,
    required int gasLimit,
  }) {
    final request = base.request;
    final transaction = Transaction(
      from: EthereumAddress.fromHex(request.from),
      to: EthereumAddress.fromHex(request.to),
      value: EtherAmount.inWei(request.value),
      data: request.data.isEmpty
          ? Uint8List(0)
          : Uint8List.fromList(request.data),
      maxGas: gasLimit,
      maxFeePerGas: EtherAmount.inWei(maxFee),
      maxPriorityFeePerGas: EtherAmount.inWei(priority),
      nonce: base.nonce,
    );
    final unsigned = MultiChainDerivation.unsignedEip1559Payload(
      transaction,
      1,
    );
    final limit = BigInt.from(gasLimit);
    final used = base.estimatedGas < limit ? base.estimatedGas : limit;
    final maxNetworkFee = limit * maxFee;
    final marketTier = base.market?.market;
    final referenceMaxFee =
        marketTier?.maxFeePerGas ??
        (base.baseFee == null
            ? null
            : base.baseFee! * BigInt.two + _defaultTip);
    final referenceTip = marketTier?.maxPriorityFeePerGas ?? _defaultTip;
    final feeReference = marketTier == null
        ? 'the node-derived default'
        : 'the Market tier';
    final review = base.review;
    return PreparedEthereumTransaction(
      request: request,
      transaction: transaction,
      nonce: base.nonce,
      gasLimit: gasLimit,
      maxFeePerGas: maxFee,
      maxPriorityFeePerGas: priority,
      estimatedGas: base.estimatedGas,
      defaultGasLimit: base.defaultGasLimit,
      market: base.market,
      selection: base.selection,
      baseFee: base.baseFee,
      feeFromSite: base.feeFromSite,
      baseWarnings: base.baseWarnings,
      review: SimulationReview(
        programCalls: review.programCalls,
        nftMetadata: review.nftMetadata,
        tokenMetadata: review.tokenMetadata,
        assets: review.assets,
        payloadDigest: _hexBytes(keccak256(unsigned)),
        origin: review.origin,
        walletId: review.walletId,
        address: review.address,
        chain: review.chain,
        simulatedAt: review.simulatedAt,
        execution: review.execution,
        effectsUndecodable: review.effectsUndecodable,
        coverage: review.coverage,
        // Expected: the estimate at the current base fee plus the tip. A
        // failed simulation has no meaningful expected fee.
        networkFee: review.execution == SimulationExecution.failed
            ? null
            : used * _effective(maxFee, priority, base.baseFee),
        maxNetworkFee: maxNetworkFee,
        feePayer: review.feePayer,
        error: review.error,
        warnings: [
          if (limit < base.estimatedGas)
            'The gas limit is below the estimate. The transaction may run out of gas and still pay its fee.',
          if (limit > base.estimatedGas * BigInt.from(_gasLimitWarningMultiple))
            'The gas limit is more than $_gasLimitWarningMultiple times the estimate. A contract can consume the full limit, so the network fee could reach ${formatReviewAmount(maxNetworkFee, 18)} ETH.',
          if (base.feeFromSite) ...[
            if (referenceMaxFee != null &&
                maxFee > referenceMaxFee * BigInt.from(_siteFeeWarningMultiple))
              'The website\'s maximum fee is more than $_siteFeeWarningMultiple times $feeReference. Review the maximum network fee before approving.',
            if (request.maxPriorityFeePerGas != null &&
                priority > referenceTip * BigInt.from(_siteFeeWarningMultiple))
              'The website\'s priority fee is more than $_siteFeeWarningMultiple times $feeReference. Review the maximum network fee before approving.',
          ],
          ...base.baseWarnings,
        ],
        funds: review.funds,
        accounts: review.accounts,
        nfts: review.nfts,
      ),
    );
  }

  static void _checkGasLimit(BigInt gasLimit) {
    if (gasLimit > BigInt.from(30000000) || gasLimit < BigInt.from(21000)) {
      throw const DappException(-32602, 'Invalid gas limit.');
    }
  }

  /// The fee before the user changes anything: the website's suggestion when
  /// it made one (within a cap), else the market tier the caller resolves, or
  /// with no market a node-derived default.
  Future<(BigInt, BigInt)> _fees(
    EthereumDappTransactionRequest request,
    EthGasMarket? market,
    Future<BigInt?>? baseFee,
  ) async {
    final cap = BigInt.from(10000) * BigInt.from(1000000000);
    final defaultTip = market?.market.maxPriorityFeePerGas ?? _defaultTip;
    BigInt maxFee;
    BigInt priority;
    if (request.maxFeePerGas != null) {
      maxFee = request.maxFeePerGas!;
      priority = request.maxPriorityFeePerGas ?? defaultTip;
      if (priority > maxFee) priority = maxFee;
    } else if (request.gasPrice != null) {
      // A legacy price becomes a type-2 cap: never more per gas than offered.
      maxFee = request.gasPrice!;
      priority = maxFee < defaultTip ? maxFee : defaultTip;
    } else if (market != null) {
      maxFee = market.market.maxFeePerGas;
      priority = market.market.maxPriorityFeePerGas;
    } else {
      final base = await (baseFee ?? _baseFee());
      if (base == null) {
        throw const DappException(-32603, 'Network fees are unavailable.');
      }
      priority = _defaultTip;
      maxFee = base * BigInt.two + priority;
    }
    if (maxFee <= BigInt.zero || maxFee > cap) {
      throw const DappException(-32602, 'Invalid network fee.');
    }
    return (maxFee, priority);
  }

  static final _defaultTip = BigInt.from(1500000000);

  Future<BigInt?> _baseFee() async {
    try {
      final block = _map(
        await _call('eth_getBlockByNumber', ['latest', false]),
      );
      final base = block['baseFeePerGas'];
      return base == null ? null : _quantity(base, 'baseFeePerGas');
    } catch (_) {
      return null;
    }
  }

  BigInt _effective(BigInt maxFee, BigInt priority, BigInt? base) {
    if (base == null) return maxFee;
    final expected = base + priority;
    return expected < maxFee ? expected : maxFee;
  }

  void _applySimulation(
    List<EvmAssetChange> changes,
    String me,
    List<FundChange> funds,
    List<AccountChange> accounts,
    List<NftChange> nfts,
  ) {
    final net = <String, BigInt>{};
    final counterparties = <String, Set<String>>{};
    for (final change in changes) {
      final from = change.from?.toLowerCase();
      final to = change.to?.toLowerCase();
      final contract = change.contractAddress?.toLowerCase();
      if (change.isApprove) {
        if (from != me || contract == null) continue;
        final revoked = to == null || to == _zero;
        if (change.assetType == 'ERC20') {
          final amount = BigInt.tryParse(change.rawAmount ?? '');
          accounts.add(
            AccountChange(
              kind: revoked || amount == BigInt.zero
                  ? AccountChangeKind.revoke
                  : AccountChangeKind.approve,
              address: contract,
              program: contract,
              assetId: contract,
              description: revoked || amount == BigInt.zero
                  ? 'Token allowance revoked'
                  : 'Token spending permission',
              beneficiary: revoked ? null : to,
              rawAllowance: amount,
              evidence: ReviewEvidence.simulatedState,
            ),
          );
        } else if (change.tokenId == null) {
          accounts.add(
            AccountChange(
              kind: revoked
                  ? AccountChangeKind.revoke
                  : AccountChangeKind.approve,
              address: contract,
              program: contract,
              assetId: contract,
              description: revoked
                  ? 'Collection permission revoked'
                  : 'Permission to transfer every NFT you hold in this collection',
              beneficiary: revoked ? null : to,
              evidence: ReviewEvidence.simulatedState,
            ),
          );
        } else if (!revoked) {
          // A zero spender is the approval every ERC-721 transfer clears.
          accounts.add(
            AccountChange(
              kind: AccountChangeKind.approve,
              address: contract,
              program: contract,
              assetId: '$contract:${change.tokenId}',
              description: 'Permission to transfer one NFT',
              beneficiary: to,
              evidence: ReviewEvidence.simulatedState,
            ),
          );
        }
        continue;
      }
      if (from != me && to != me) continue;
      if (change.assetType == 'ERC721' || change.assetType == 'ERC1155') {
        if (contract == null || change.tokenId == null) continue;
        final copies = change.assetType == 'ERC1155'
            ? ' (${change.rawAmount ?? '?'} copies)'
            : '';
        nfts.add(
          NftChange(
            kind: from == _zero
                ? NftChangeKind.mint
                : to == _zero
                ? NftChangeKind.burn
                : NftChangeKind.transfer,
            assetId: '$contract:${change.tokenId}',
            description: from == me
                ? 'NFT leaves wallet$copies'
                : 'NFT enters wallet$copies',
            evidence: ReviewEvidence.simulatedState,
            from: from,
            to: to,
            quantity: change.assetType == 'ERC1155'
                ? BigInt.tryParse(change.rawAmount ?? '')
                : null,
            isMultiCopy: change.assetType == 'ERC1155',
          ),
        );
        continue;
      }
      final id = change.assetType == 'NATIVE' ? evmNativeAssetId : contract;
      final amount = BigInt.tryParse(change.rawAmount ?? '');
      if (id == null || amount == null) continue;
      final signed = from == me && to == me
          ? BigInt.zero
          : from == me
          ? -amount
          : amount;
      net.update(id, (value) => value + signed, ifAbsent: () => signed);
      counterparties.putIfAbsent(id, () => {}).add((from == me ? to : from)!);
    }
    for (final entry in net.entries) {
      if (entry.value == BigInt.zero) continue;
      final parties = counterparties[entry.key]!;
      final party = parties.length == 1 ? parties.single : null;
      funds.add(
        FundChange(
          asset: entry.key == evmNativeAssetId
              ? _native
              : _knownTokens[entry.key] ??
                    ReviewAsset(id: entry.key, symbol: 'Token'),
          address: me,
          rawAmount: entry.value,
          evidence: ReviewEvidence.simulatedState,
          from: entry.value.isNegative ? me : party,
          to: entry.value.isNegative ? party : me,
          isNet: true,
        ),
      );
    }
  }

  /// Decimals and symbols for the ERC-20s a review names. Known tokens keep
  /// their own; any other contract's are read from the chain and shown only as
  /// an unverified token's.
  Future<void> _resolveTokens(
    List<FundChange> funds,
    List<AccountChange> accounts,
    Map<String, ReviewTokenMetadata> metadata,
    Map<String, ReviewAsset> assets,
    List<String> warnings,
    Map<String, Future<(ReviewAsset, String?)>> tokens,
  ) async {
    final contracts = {
      ...funds.map((f) => f.asset.id),
      ...accounts
          .where((a) => a.rawAllowance != null)
          .map((a) => a.assetId)
          .whereType<String>(),
    }.where((id) => id.startsWith('0x')).take(10).toList();
    // Every unknown contract's decimals and symbol are read at once, unless
    // they already were with the simulation; neither read throws.
    final reads = {
      for (final contract in contracts)
        if (_knownTokens[contract] == null)
          contract: tokens[contract] ??= _token(contract),
    };
    for (final contract in contracts) {
      final known = _knownTokens[contract];
      if (known != null) {
        assets[contract] = known;
        continue;
      }
      final (asset, symbol) = await reads[contract]!;
      assets[contract] = asset;
      if (asset.decimals == null) {
        warnings.add(
          'Token precision could not be verified. Raw amounts are shown.',
        );
      }
      final shown = ReviewTokenMetadata.fromCreator(
        symbol: symbol,
        image: null,
        reservedSymbols: _reservedSymbols,
      );
      if (shown != null) metadata[contract] = shown;
      for (var i = 0; i < funds.length; i++) {
        final fund = funds[i];
        if (fund.asset.id != contract) continue;
        funds[i] = FundChange(
          asset: asset,
          address: fund.address,
          rawAmount: fund.rawAmount,
          evidence: fund.evidence,
          from: fund.from,
          to: fund.to,
          isNet: fund.isNet,
        );
      }
    }
  }

  /// [contract]'s decimals and symbol, from [_tokenInfo] or the chain.
  /// Never fails: what could not be read is null.
  Future<(ReviewAsset, String?)> _token(String contract) async {
    final cached = _tokenInfo.remove(contract);
    if (cached != null) return _tokenInfo[contract] = cached;
    final info = await (_tokenAsset(contract), _symbol(contract)).wait;
    if (info.$1.decimals != null) {
      _tokenInfo[contract] = info;
      if (_tokenInfo.length > 256) _tokenInfo.remove(_tokenInfo.keys.first);
    }
    return info;
  }

  Future<ReviewAsset> _tokenAsset(String contract) async {
    final known = _knownTokens[contract];
    if (known != null) return known;
    int? decimals;
    try {
      final raw = await _call('eth_call', [
        {'to': contract, 'data': '0x313ce567'},
        'latest',
      ]);
      final value = _quantity(raw, 'decimals');
      if (value <= BigInt.from(77)) decimals = value.toInt();
    } catch (_) {
      // Unknown precision stays unknown: amounts show in base units.
    }
    return ReviewAsset(id: contract, symbol: 'Token', decimals: decimals);
  }

  Future<String?> _symbol(String contract) async {
    try {
      final raw = await _call('eth_call', [
        {'to': contract, 'data': '0x95d89b41'},
        'latest',
      ]);
      return raw is String ? decodeAbiSymbol(raw) : null;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> signPrepared(
    PreparedEthereumTransaction prepared, {
    required void Function() ensureActive,
    Future<void>? cancelled,
  }) async {
    ensureActive();
    if (DateTime.now().difference(prepared.review.simulatedAt) >
        const Duration(minutes: 2)) {
      throw const DappException(
        4001,
        'Review expired. Request a new transaction.',
      );
    }
    final unsigned = MultiChainDerivation.unsignedEip1559Payload(
      prepared.transaction,
      1,
    );
    if (_hexBytes(keccak256(unsigned)) != prepared.review.payloadDigest) {
      throw const DappException(-32602, 'Transaction changed after review.');
    }
    final signed = await walletManager.signEthereumTransaction(
      prepared.review.walletId,
      prepared.transaction,
      chainId: 1,
      ensureActive: ensureActive,
      cancelled: cancelled,
    );
    ensureActive();
    verifySignedEip1559(unsigned, signed, prepared.review.address);
    return signed;
  }

  /// Broadcasts and hands the transaction to both trackers: the browser's
  /// receipt list and the app's pending-EVM list, which offers speed-up and
  /// cancel. The hash returned is computed locally, so the website gets the
  /// identity of what was signed even if the node's reply is lost.
  Future<String> sendSigned(
    Uint8List signed,
    PreparedEthereumTransaction prepared,
  ) async {
    final hash = ethereumTransactionHash(signed);
    final recipient = prepared.review.address.toLowerCase();
    var reported = false;
    _tracker.start(
      signature: hash,
      chain: ethereumMainnet,
      lookup: (_, hash) async {
        final receipt = await _rpc('eth_getTransactionReceipt', [hash]);
        if (!reported &&
            receipt is Map &&
            receipt['status'] == '0x1' &&
            receiptDeliversNft(receipt, recipient)) {
          reported = true;
          _onNftReceived(txHash: hash, address: recipient);
        }
        return receiptStatusOf(receipt);
      },
    );
    final uncertain = DappException(
      -32000,
      'Broadcast status is uncertain. Check transaction $hash before trying again.',
    );
    try {
      final result = await _rpc('eth_sendRawTransaction', [_hexBytes(signed)]);
      if (result is! String || result.toLowerCase() != hash) {
        throw const FormatException();
      }
    } on EthereumDappRpcException catch (error) {
      switch (classifyEthereumBroadcastFailure(error)) {
        case EthereumBroadcastFailure.alreadyKnown:
          // The node already holds these exact bytes: the broadcast happened.
          break;
        case EthereumBroadcastFailure.rejected:
          _tracker.markRejected(ethereumMainnet, hash);
          throw const DappException(
            -32000,
            'The network rejected this transaction before broadcast. Request a new transaction.',
          );
        case EthereumBroadcastFailure.uncertain:
          _tracker.markUncertain(ethereumMainnet, hash);
          _register(prepared, hash);
          throw uncertain;
      }
    } catch (_) {
      // It may be in the mempool, so the pending list must still own it.
      _tracker.markUncertain(ethereumMainnet, hash);
      _register(prepared, hash);
      throw uncertain;
    }
    _register(prepared, hash);
    return hash;
  }

  void _register(PreparedEthereumTransaction prepared, String hash) =>
      _onBroadcast(
        PendingEvmBroadcast(
          walletAddress: prepared.review.address,
          nonce: prepared.nonce,
          chainId: 1,
          kind: PendingEvmTxKind.other,
          role: PendingTxCandidateRole.original,
          toAddress: prepared.transaction.to!.with0x,
          valueWei: prepared.transaction.value?.getInWei ?? BigInt.zero,
          data: _hexBytes(prepared.transaction.data ?? Uint8List(0)),
          gasLimit: prepared.gasLimit,
          maxFeePerGas: prepared.maxFeePerGas,
          maxPriorityFeePerGas: prepared.maxPriorityFeePerGas,
          hash: hash,
        ),
      );

  Future<Object?> _call(String method, List<Object?> params) =>
      _rpc(method, params);
}

enum EthereumBroadcastFailure { alreadyKnown, rejected, uncertain }

/// What a failed `eth_sendRawTransaction` means for a transaction that may or
/// may not be in the mempool. Clients share the wording but not the codes
/// (most use -32000 for everything), so the node's text decides, and anything
/// unrecognised stays uncertain: wrongly calling a broadcast "rejected" would
/// invite the user to send it again.
EthereumBroadcastFailure classifyEthereumBroadcastFailure(
  EthereumDappRpcException error,
) {
  final message = (error.message ?? '').toLowerCase();
  if (message.contains('already known')) {
    return EthereumBroadcastFailure.alreadyKnown;
  }
  const refusals = [
    'insufficient funds',
    'nonce too low',
    'intrinsic gas too low',
    'underpriced',
    'exceeds block gas limit',
    'invalid sender',
    'less than block base fee',
    'fee cap less than',
    'max fee per gas less than',
    'gas limit reached',
  ];
  if (refusals.any(message.contains) ||
      (error.code == -32602 && message.isEmpty)) {
    return EthereumBroadcastFailure.rejected;
  }
  return EthereumBroadcastFailure.uncertain;
}

/// The hash a signed transaction will have on chain.
String ethereumTransactionHash(Uint8List signed) =>
    _hexBytes(keccak256(signed));

/// A receipt lookup in the shape [BrowserTransactionTracker] reads: no receipt
/// is "not seen yet", a receipt is confirmed, and status `0x0` is a failure.
Future<Object?> receiptStatus(EthereumDappRpc rpc, String hash) async =>
    receiptStatusOf(await rpc('eth_getTransactionReceipt', [hash]));

/// [receiptStatus] for a receipt already fetched (`null` when not mined).
Object? receiptStatusOf(Object? receipt) {
  if (receipt is! Map)
    return {
      'value': <Object?>[null],
    };
  final block = receipt['blockNumber'];
  return {
    'value': [
      {
        'confirmationStatus': 'confirmed',
        'err': receipt['status'] == '0x1' ? null : 'reverted',
        'slot': block is String
            ? int.tryParse(block.substring(2), radix: 16)
            : null,
      },
    ],
  };
}

/// ERC-721 `Transfer(address,address,uint256)`. ERC-20 shares the signature
/// but indexes only two arguments, so its logs have three topics, not four.
const _erc721TransferTopic =
    '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';

/// ERC-1155 `TransferSingle(address,address,address,uint256,uint256)`.
const _erc1155TransferSingleTopic =
    '0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62';

/// ERC-1155 `TransferBatch(address,address,address,uint256[],uint256[])`.
const _erc1155TransferBatchTopic =
    '0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb';

/// Whether [receipt] has an NFT transfer to [address]: an ERC-721 `Transfer`
/// with the recipient in `topics[2]`, or an ERC-1155 `TransferSingle` /
/// `TransferBatch` with it in `topics[3]`. Only such a transaction is worth
/// reporting: every other one would cost the backend a receipt read for
/// nothing. Topics are lowercase hex, so [address] is compared lowercased.
bool receiptDeliversNft(Map<Object?, Object?> receipt, String address) {
  final hex = address.toLowerCase().replaceFirst('0x', '');
  if (hex.length != 40) return false;
  final target = '0x${hex.padLeft(64, '0')}';
  final logs = receipt['logs'];
  if (logs is! List) return false;
  for (final log in logs) {
    if (log is! Map || log['removed'] == true) continue;
    final topics = log['topics'];
    if (topics is! List || topics.length != 4) continue;
    final normalized = [
      for (final topic in topics) topic is String ? topic.toLowerCase() : '',
    ];
    final recipient = switch (normalized[0]) {
      _erc721TransferTopic => normalized[2],
      _erc1155TransferSingleTopic ||
      _erc1155TransferBatchTopic => normalized[3],
      _ => null,
    };
    if (recipient == target) return true;
  }
  return false;
}

/// Throws unless [signature] over [digest] recovers to [address].
void verifyEthereumSignature(
  Uint8List digest,
  Uint8List signature,
  String address,
) {
  final recovered = MultiChainDerivation.recoverEthereumAddress(
    digest,
    signature,
  );
  if (recovered == null || recovered != address.toLowerCase()) {
    throw const DappException(
      4100,
      'The signature does not belong to the approved wallet.',
    );
  }
}

/// Checks a signed type-2 envelope against the [unsigned] payload it should
/// carry: every reviewed field identical, and the signature recovering to
/// [address]. A Ledger reassembly or a derivation mix-up fails here rather
/// than broadcasting from another account.
void verifySignedEip1559(Uint8List unsigned, Uint8List signed, String address) {
  const failure = DappException(
    -32602,
    'Signed transaction does not match the reviewed transaction.',
  );
  if (signed.isEmpty || signed.first != 0x02 || unsigned.first != 0x02) {
    throw failure;
  }
  final List<Object> fields, reviewed;
  try {
    fields = rlpDecodeList(signed.sublist(1));
    reviewed = rlpDecodeList(unsigned.sublist(1));
  } on FormatException {
    throw failure;
  }
  const equality = DeepCollectionEquality();
  if (fields.length != 12 ||
      reviewed.length != 9 ||
      !equality.equals(fields.sublist(0, 9), reviewed)) {
    throw failure;
  }
  final parity = fields[9], r = fields[10], s = fields[11];
  if (parity is! Uint8List ||
      r is! Uint8List ||
      s is! Uint8List ||
      parity.length > 1 ||
      r.length > 32 ||
      s.length > 32) {
    throw failure;
  }
  final signature = Uint8List(65)
    ..setRange(32 - r.length, 32, r)
    ..setRange(64 - s.length, 64, s)
    ..[64] = parity.isEmpty ? 0 : parity.first;
  verifyEthereumSignature(keccak256(unsigned), signature, address);
}

/// Decodes one RLP list. Strings come back as [Uint8List], lists as
/// [List<Object>]; trailing bytes or a non-canonical length are errors.
List<Object> rlpDecodeList(Uint8List input) {
  final (value, end) = _rlpItem(input, 0, 0);
  if (end != input.length || value is! List<Object>) {
    throw const FormatException('Not a single RLP list');
  }
  return value;
}

(Object, int) _rlpItem(Uint8List input, int offset, int depth) {
  if (depth > 8 || offset >= input.length) {
    throw const FormatException('RLP out of range');
  }
  final prefix = input[offset];
  int length(int start, int size) {
    if (size > 4 || start + size > input.length || input[start] == 0) {
      throw const FormatException('RLP length');
    }
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = (value << 8) | input[start + i];
    }
    if (value < 56) throw const FormatException('RLP length');
    return value;
  }

  Uint8List bytes(int start, int size) {
    if (start + size > input.length) throw const FormatException('RLP short');
    return Uint8List.sublistView(input, start, start + size);
  }

  if (prefix < 0x80) return (Uint8List.fromList([prefix]), offset + 1);
  if (prefix <= 0xb7) {
    final size = prefix - 0x80;
    final value = bytes(offset + 1, size);
    if (size == 1 && value.first < 0x80) {
      throw const FormatException('RLP non-canonical byte');
    }
    return (value, offset + 1 + size);
  }
  if (prefix <= 0xbf) {
    final sizeOfSize = prefix - 0xb7;
    final size = length(offset + 1, sizeOfSize);
    final start = offset + 1 + sizeOfSize;
    return (bytes(start, size), start + size);
  }
  final int start, end;
  if (prefix <= 0xf7) {
    start = offset + 1;
    end = start + prefix - 0xc0;
  } else {
    final sizeOfSize = prefix - 0xf7;
    start = offset + 1 + sizeOfSize;
    end = start + length(offset + 1, sizeOfSize);
  }
  if (end > input.length) throw const FormatException('RLP short');
  final items = <Object>[];
  var cursor = start;
  while (cursor < end) {
    final (item, next) = _rlpItem(input, cursor, depth + 1);
    items.add(item);
    cursor = next;
  }
  if (cursor != end) throw const FormatException('RLP overrun');
  return (items, end);
}

/// What a call's calldata asks for, read from the request itself. Permissions
/// supplement simulation events; fund movements are a fallback when simulation
/// did not succeed. Both carry requested-instruction evidence.
class DecodedEvmCall {
  const DecodedEvmCall({
    required this.name,
    this.accounts = const [],
    this.funds = const [],
  });
  final String name;
  final List<AccountChange> accounts;
  final List<FundChange> funds;
}

DecodedEvmCall decodeEvmCall(String to, Uint8List data, String me) {
  if (data.length < 4) return const DecodedEvmCall(name: 'Contract call');
  final selector = _hexBytes(data.sublist(0, 4));
  BigInt word(int i) {
    final start = 4 + i * 32;
    if (data.length < start + 32) throw const FormatException();
    var value = BigInt.zero;
    for (final byte in data.sublist(start, start + 32)) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  String address(int i) =>
      '0x${(word(i) & ((BigInt.one << 160) - BigInt.one)).toRadixString(16).padLeft(40, '0')}';
  try {
    switch (selector) {
      case '0x095ea7b3': // approve(address,uint256)
      case '0x39509351': // increaseAllowance(address,uint256)
        final spender = address(0);
        final amount = word(1);
        // ERC-721 shares approve's selector: zero may be a real token ID.
        final revoke = spender == _zero;
        return DecodedEvmCall(
          name: selector == '0x095ea7b3' ? 'approve' : 'increaseAllowance',
          accounts: [
            AccountChange(
              kind: revoke
                  ? AccountChangeKind.revoke
                  : AccountChangeKind.approve,
              address: to,
              program: to,
              assetId: to,
              description: revoke
                  ? 'Token allowance revoked'
                  : selector == '0x095ea7b3' && amount == BigInt.zero
                  ? 'Token approval (allowance or NFT token ID)'
                  : 'Token spending permission',
              beneficiary: revoke ? null : spender,
              rawAllowance: amount,
              evidence: ReviewEvidence.requestedInstruction,
            ),
          ],
        );
      case '0xa22cb465': // setApprovalForAll(address,bool)
        final operator = address(0);
        final granted = word(1) != BigInt.zero;
        return DecodedEvmCall(
          name: 'setApprovalForAll',
          accounts: [
            AccountChange(
              kind: granted
                  ? AccountChangeKind.approve
                  : AccountChangeKind.revoke,
              address: to,
              program: to,
              assetId: to,
              description: granted
                  ? 'Permission to transfer every NFT you hold in this collection'
                  : 'Collection permission revoked',
              beneficiary: granted ? operator : null,
              evidence: ReviewEvidence.requestedInstruction,
            ),
          ],
        );
      case '0xa9059cbb': // transfer(address,uint256)
        return DecodedEvmCall(
          name: 'transfer',
          funds: [
            FundChange(
              asset: _knownTokens[to] ?? ReviewAsset(id: to, symbol: 'Token'),
              address: me,
              rawAmount: -word(1),
              evidence: ReviewEvidence.requestedInstruction,
              from: me,
              to: address(0),
              isNet: true,
            ),
          ],
        );
      case '0x23b872dd': // transferFrom(address,address,uint256)
        return const DecodedEvmCall(name: 'transferFrom');
      case '0x42842e0e': // safeTransferFrom(address,address,uint256)
      case '0xb88d4fde': // safeTransferFrom(address,address,uint256,bytes)
      case '0xf242432a': // safeTransferFrom(address,address,uint256,uint256,bytes)
        return const DecodedEvmCall(name: 'safeTransferFrom');
      case '0x87517c45': // Permit2 approve(address,address,uint160,uint48)
        if (to != permit2Address) break;
        final amount = word(2);
        final revoke = amount == BigInt.zero;
        return DecodedEvmCall(
          name: 'approve',
          accounts: [
            AccountChange(
              kind: revoke
                  ? AccountChangeKind.revoke
                  : AccountChangeKind.approve,
              address: address(0),
              program: to,
              assetId: address(0),
              description: revoke
                  ? 'Permit2 allowance revoked'
                  : 'Permit2 spending permission',
              beneficiary: revoke ? null : address(1),
              rawAllowance: amount,
              evidence: ReviewEvidence.requestedInstruction,
            ),
          ],
        );
    }
  } on FormatException {
    // Malformed arguments: show the call by its selector only.
  }
  return DecodedEvmCall(name: 'Call $selector');
}

/// An ERC-20 `symbol()` return value: an ABI string, or the bytes32 some
/// early tokens return. Null for anything else.
String? decodeAbiSymbol(String hex) {
  final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
  if (clean.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(clean)) {
    return null;
  }
  final bytes = Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
  if (bytes.length == 32) {
    final end = bytes.indexOf(0);
    final raw = bytes.sublist(0, end < 0 ? 32 : end);
    return raw.isEmpty ? null : utf8.decode(raw, allowMalformed: false);
  }
  if (bytes.length < 64) return null;
  BigInt at(int offset) {
    var value = BigInt.zero;
    for (final byte in bytes.sublist(offset, offset + 32)) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  final offset = at(0);
  if (offset > BigInt.from(bytes.length - 32)) return null;
  final start = offset.toInt();
  final length = at(start);
  if (length > BigInt.from(64) || start + 32 + length.toInt() > bytes.length) {
    return null;
  }
  try {
    return utf8.decode(bytes.sublist(start + 32, start + 32 + length.toInt()));
  } on FormatException {
    return null;
  }
}

DateTime? _timestamp(BigInt? seconds) =>
    seconds == null ||
        seconds <= BigInt.zero ||
        seconds > BigInt.from(253402300799)
    ? null
    : DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000, isUtc: true);

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : <String, Object?>{};

final _hexPattern = RegExp(r'^0x[0-9a-fA-F]*$');

BigInt _quantity(Object? value, String name) {
  if (value is String && value.length <= 66 && _hexPattern.hasMatch(value)) {
    return value.length == 2
        ? BigInt.zero
        : BigInt.parse(value.substring(2), radix: 16);
  }
  throw DappException(-32602, '$name must be a hex quantity.');
}

int _int(Object? value, String name) {
  final number = _quantity(value, name);
  if (number > BigInt.from(0x7fffffff)) {
    throw DappException(-32602, '$name is out of range.');
  }
  return number.toInt();
}

String _address(Object? value, String name) {
  if (value is String && value.length == 42 && _hexPattern.hasMatch(value)) {
    return value.toLowerCase();
  }
  throw DappException(-32602, '$name must be an address.');
}

Uint8List _bytes(Object? value, String name) {
  if (value is! String || !_hexPattern.hasMatch(value) || value.length.isOdd) {
    throw DappException(-32602, '$name must be hex bytes.');
  }
  return Uint8List.fromList([
    for (var i = 2; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ]);
}

String _hexQuantity(BigInt value) => '0x${value.toRadixString(16)}';

String _hexBytes(List<int> bytes) =>
    '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
