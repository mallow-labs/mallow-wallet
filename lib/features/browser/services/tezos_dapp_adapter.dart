import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:pointycastle/digests/blake2b.dart';
import 'package:solana/base58.dart' as base58;

import '../../../core/crypto/derivation.dart';
import '../../../core/crypto/tezos_forge.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/data/mallow_tokens.dart' show xtzMint;
import '../../../core/models/account.dart' show WalletType;
import '../../../core/models/simulation_review.dart';
import '../../../core/network/tezos_rpc_service.dart';
import '../../../shared/utils/tezos_address.dart';
import '../../portfolio/services/portfolio_received_reporter.dart';
import '../models/dapp_message_review.dart';
import '../models/dapp_request.dart';
import 'browser_transaction_tracker.dart';

const tezosMainnet = 'tezos:NetXdQprcVkpaWU';
const _chainId = 'NetXdQprcVkpaWU';

// The largest fee the protocol minimum can demand for a batch this adapter
// accepts is about 0.137 XTZ: 100 mutez + 0.1 mutez per gas over the 1,040,000
// gas cap + 1 mutez per byte of a 32 KiB operation. Tezos has no fee auction,
// so nothing legitimate needs more. 1 XTZ leaves about 7x headroom over that
// worst case and is about 1,000x a plain transfer's fee.
final _maxTotalFeeMutez = BigInt.from(1000000);

// Same multiple as the Ethereum site-fee warning. Above it, the extra fee only
// enriches the baker.
const _siteFeeWarningMultiple = 5;
const _xtz = ReviewAsset(
  id: xtzMint,
  symbol: 'XTZ',
  decimals: 6,
  verified: true,
);

bool tezosBrowserCanSign(WalletType type) => switch (type) {
  WalletType.hd ||
  WalletType.importedKey ||
  WalletType.social ||
  WalletType.ledger => true,
  _ => false,
};

/// Only locally forgeable manager operations are accepted. Counter and source
/// are owned by the wallet; every other accepted field survives canonicalizing.
class TezosDappOperationRequest {
  TezosDappOperationRequest._(this._operations);
  final List<Map<String, dynamic>> _operations;
  List<Map<String, dynamic>> toJson() =>
      (jsonDecode(jsonEncode(_operations)) as List)
          .cast<Map<String, dynamic>>();

  factory TezosDappOperationRequest.parse(
    Object? raw, {
    required String account,
  }) {
    if (raw is! List || raw.isEmpty || raw.length > 20) {
      throw const DappException(-32602, 'Request 1 to 20 Tezos operations.');
    }
    final operations = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map)
        throw const DappException(-32602, 'Invalid Tezos operation.');
      final kind = item['kind'];
      if (kind != 'transaction' && kind != 'delegation') {
        throw const DappException(
          4200,
          'This Tezos operation kind is not supported.',
        );
      }
      if (item['source'] != null && item['source'] != account) {
        throw const DappException(
          4100,
          'The operation is not from the connected account.',
        );
      }
      final allowed = {
        'kind',
        'source',
        'counter',
        'fee',
        'gas_limit',
        'storage_limit',
        if (kind == 'transaction') ...['destination', 'amount', 'parameters'],
        if (kind == 'delegation') 'delegate',
      };
      if (item.keys.any((key) => !allowed.contains(key))) {
        throw const DappException(-32602, 'Unsupported Tezos operation field.');
      }
      final operation = <String, dynamic>{'kind': kind};
      for (final field in ['fee', 'gas_limit', 'storage_limit']) {
        if (item[field] != null)
          operation[field] = _nat(item[field], field).toString();
      }
      if (kind == 'transaction') {
        operation['destination'] = _address(item['destination']);
        operation['amount'] = _nat(item['amount'], 'amount').toString();
        final params = item['parameters'];
        if (params != null) {
          if (params is! Map ||
              params.length != 2 ||
              params['entrypoint'] is! String ||
              params['value'] == null) {
            throw const DappException(-32602, 'Invalid contract parameters.');
          }
          final entrypoint = params['entrypoint'] as String;
          if (!RegExp(r'^[A-Za-z0-9_.%@]{1,31}$').hasMatch(entrypoint)) {
            throw const DappException(-32602, 'Invalid contract entrypoint.');
          }
          operation['parameters'] = {
            'entrypoint': entrypoint,
            'value': MichelineJson(params['value'] as Object).toJson(),
          };
        }
      } else if (item['delegate'] != null) {
        final delegate = _address(item['delegate']);
        if (!isValidTezosImplicitAddress(delegate))
          throw const DappException(-32602, 'Invalid delegate.');
        operation['delegate'] = delegate;
      }
      operations.add(operation);
    }
    return TezosDappOperationRequest._(operations);
  }
}

class TezosMessageReview extends DappMessageReview {
  TezosMessageReview({
    required Uint8List payload,
    required this.origin,
    required this.address,
    required this.walletId,
    required this.signingType,
  }) : payload = Uint8List.fromList(payload).asUnmodifiableView() {
    if (!{'micheline', 'raw'}.contains(signingType) ||
        payload.length < 6 ||
        payload.length > 65536 ||
        payload[0] != 5 ||
        payload[1] != 1 ||
        ByteData.sublistView(payload).getUint32(2) != payload.length - 6) {
      throw const DappException(
        4200,
        'Only packed Tezos text messages can be signed.',
      );
    }
    utf8.decode(payload.sublist(6));
  }
  final Uint8List payload;
  final String walletId;
  final String signingType;
  @override
  final String origin;
  @override
  final String address;
  // The raw bytes panel shows every signed byte, including the pack header.
  @override
  Uint8List get bytes => payload;
  @override
  String get text => utf8.decode(payload.sublist(6));
  @override
  String get digestLabel => 'Blake2b-256 hash';
  @override
  String get digest =>
      bytesToHex(Blake2bDigest(digestSize: 32).process(payload));
  @override
  Map<String, String> get signInFields => const {};
  @override
  String? get signInStatement => null;
}

class PreparedTezosOperation {
  PreparedTezosOperation({
    required this.forgedHex,
    required this.review,
    required this.publicKey,
    required this.details,
  });
  final String forgedHex;
  final String publicKey;
  final SimulationReview review;
  final String details;
}

class TezosDappAdapter {
  TezosDappAdapter({
    required this.walletManager,
    required this.rpc,
    BrowserTransactionTracker? tracker,
    void Function({required String opHash, required String address})? onApplied,
  }) : tracker = tracker ?? BrowserTransactionTracker.instance,
       onApplied = onApplied ?? reportTezosReceived;
  final WalletManager walletManager;
  final TezosRpcService rpc;
  final BrowserTransactionTracker tracker;

  /// Called once when an operation [sendSigned] broadcast for a `recipient`
  /// lands applied. Defaults to reporting it to the backend, which refreshes
  /// the tokens the operation delivered so a purchase shows in My Art.
  final void Function({required String opHash, required String address})
  onApplied;
  final _publicKeys = <String, String>{};
  String? cachedPublicKey(String walletId, String address) =>
      _publicKeys['$walletId:$address'];

  Future<String> publicKey(
    String walletId,
    String address,
    void Function() ensureActive, {
    Future<void>? cancelled,
  }) async {
    ensureActive();
    final cacheKey = '$walletId:$address';
    final cached = _publicKeys[cacheKey];
    if (cached != null) return cached;
    final key = await walletManager.getTezosPublicKey(
      walletId,
      expectedAddress: address,
      ensureActive: ensureActive,
      cancelled: cancelled,
    );
    ensureActive();
    final raw = _checkedBase58(key, const [13, 15, 37, 217], 32);
    if (MultiChainDerivation.tezosAddressFromPublicKey(raw) != address) {
      throw const DappException(
        4100,
        'The signing key does not match the connected account.',
      );
    }
    _publicKeys[cacheKey] = key;
    return key;
  }

  Future<String> signMessage(
    TezosMessageReview review,
    void Function() ensureActive, {
    Future<void>? cancelled,
  }) async {
    final key = await publicKey(
      review.walletId,
      review.address,
      ensureActive,
      cancelled: cancelled,
    );
    ensureActive();
    final signature = await walletManager.signTezosPayloadForWallet(
      review.walletId,
      review.payload,
      expectedAddress: review.address,
      ensureActive: ensureActive,
      cancelled: cancelled,
    );
    ensureActive();
    await _verify(signature, key, review.payload);
    ensureActive();
    return signature;
  }

  Future<PreparedTezosOperation> prepareOperation({
    required TezosDappOperationRequest request,
    required String walletId,
    required String address,
    required String origin,
    required void Function() ensureActive,
    Future<void>? cancelled,
  }) async {
    try {
      final key = await publicKey(
        walletId,
        address,
        ensureActive,
        cancelled: cancelled,
      );
      final reads = await Future.wait<Object?>([
        rpc.getBranchHash(),
        rpc.getChainId(),
        rpc.nextCounter(address),
        rpc.getManagerKey(address),
      ]);
      ensureActive();
      if (reads[1] != _chainId)
        throw const DappException(4901, 'Switch to Tezos mainnet first.');
      final branch = reads[0] as String;
      _checkedBase58(branch, const [1, 52], 32);
      if (reads[3] != null && reads[3] != key) {
        throw const DappException(
          4100,
          'The revealed key does not match this wallet.',
        );
      }
      final counter = reads[2] as int;
      final operations = request.toJson();
      final reveal = reads[3] == null;
      final count = operations.length + (reveal ? 1 : 0);
      // Split the block's gas budget across the whole batch, including reveal.
      final gasCap = 1000000 ~/ count;
      List<TezosOperationContent> build(
        List<BigInt> fees,
        List<int> gas,
        List<int> storage,
      ) {
        var next = counter;
        var i = 0;
        final out = <TezosOperationContent>[];
        if (reveal) {
          out.add(
            TezosReveal(
              source: address,
              publicKey: key,
              fee: fees[i],
              counter: BigInt.from(next++),
              gasLimit: BigInt.from(gas[i]),
              storageLimit: BigInt.from(storage[i]),
            ),
          );
          i++;
        }
        for (final operation in operations) {
          final fee = fees[i];
          final g = BigInt.from(gas[i]);
          final s = BigInt.from(storage[i]);
          if (operation['kind'] == 'delegation') {
            out.add(
              TezosDelegation(
                source: address,
                delegate: operation['delegate'] as String?,
                fee: fee,
                counter: BigInt.from(next++),
                gasLimit: g,
                storageLimit: s,
              ),
            );
          } else {
            final params = operation['parameters'] as Map?;
            out.add(
              TezosTransaction(
                source: address,
                destination: operation['destination'] as String,
                amount: BigInt.parse(operation['amount'] as String),
                fee: fee,
                counter: BigInt.from(next++),
                gasLimit: g,
                storageLimit: s,
                parameters: params == null
                    ? null
                    : TezosTransactionParameters(
                        entrypoint: params['entrypoint'] as String,
                        value: MichelineJson(params['value'] as Object),
                      ),
              ),
            );
          }
          i++;
        }
        return out;
      }

      final zero = List.filled(count, BigInt.zero);
      final simulated = build(
        zero,
        List.filled(count, gasCap),
        List.generate(count, (i) => reveal && i == 0 ? 0 : 60000),
      );
      final response = await rpc.runOperation(
        branch: branch,
        chainId: _chainId,
        contents: [for (final operation in simulated) operation.toJson()],
      );
      ensureActive();
      final results = _validatedEstimates(response, count);
      final gas = [
        for (final result in results)
          result.gas + TezosRpcService.gasSafetyMargin,
      ];
      final storage = [
        for (final result in results)
          result.storage == 0 ? 0 : result.storage + 10,
      ];
      final fees = List<BigInt>.filled(count, BigInt.zero);
      var siteFee = false;
      for (var j = 0; j < operations.length; j++) {
        final i = j + (reveal ? 1 : 0);
        final op = operations[j];
        if (op['gas_limit'] != null)
          gas[i] = _nat(op['gas_limit'], 'gas_limit').toInt();
        if (op['storage_limit'] != null)
          storage[i] = _nat(op['storage_limit'], 'storage_limit').toInt();
        if (gas[i] < results[i].gas ||
            storage[i] < results[i].storage ||
            gas[i] > 1040000 ||
            storage[i] > 60000) {
          throw const DappException(
            -32602,
            'The requested limits cannot cover this operation.',
          );
        }
        if (op['fee'] != null) {
          fees[i] = _nat(op['fee'], 'fee');
          siteFee = true;
        }
      }
      if (gas.fold<int>(0, (a, b) => a + b) > 1040000)
        throw const DappException(
          -32602,
          'The operation batch exceeds the gas limit.',
        );
      // The minimal fee is checked over the whole batch, so the wallet may put
      // any shortfall on one content. Prefer the reveal it added itself: a site
      // that priced its own operations could not know about the reveal.
      final topUp = reveal
          ? 0
          : operations.indexWhere((op) => op['fee'] == null);
      // Solve the fee/size dependency locally; no node-supplied forged bytes.
      var minimum = BigInt.zero;
      for (var pass = 0; pass < 3; pass++) {
        final built = build(fees, gas, storage);
        final size = forgeOperationGroup(branch, built).length ~/ 2 + 64;
        minimum = BigInt.from(
          TezosRpcService.minimalFeeMutez(
                gasLimit: gas.fold<int>(0, (a, b) => a + b),
                operationSizeBytes: size,
              ) +
              100,
        );
        final total = fees.fold<BigInt>(BigInt.zero, (a, b) => a + b);
        if (total < minimum) {
          if (topUp < 0) {
            throw const DappException(-32602, 'The requested fee is too low.');
          }
          fees[topUp] += minimum - total;
        }
      }
      if (fees.fold<BigInt>(BigInt.zero, (a, b) => a + b) > _maxTotalFeeMutez) {
        throw const DappException(-32602, 'The requested fee is too high.');
      }
      final built = build(fees, gas, storage);
      final finalResponse = await rpc.runOperation(
        branch: branch,
        chainId: _chainId,
        contents: [for (final operation in built) operation.toJson()],
      );
      ensureActive();
      _validatedEstimates(finalResponse, count);
      final forged = forgeOperationGroup(branch, built);
      final totalFee = fees.fold<BigInt>(BigInt.zero, (a, b) => a + b);
      final burn = TezosRpcService.storageBurnMutez(
        results.fold<int>(0, (a, b) => a + b.storage),
      );
      final maxBurn = TezosRpcService.storageBurnMutez(
        storage.fold<int>(0, (a, b) => a + b),
      );
      final plain = operations.every(
        (op) =>
            op['kind'] == 'transaction' &&
            op['parameters'] == null &&
            isValidTezosImplicitAddress(op['destination'] as String),
      );
      return PreparedTezosOperation(
        forgedHex: forged,
        publicKey: key,
        details: const JsonEncoder.withIndent('  ').convert({
          'branch': branch,
          'contents': [for (final op in built) op.toJson()],
        }),
        review: SimulationReview(
          payloadDigest: sha256.convert(hexToBytes(forged)).toString(),
          origin: origin,
          walletId: walletId,
          address: address,
          chain: tezosMainnet,
          simulatedAt: DateTime.now().toUtc(),
          execution: SimulationExecution.succeeded,
          coverage: plain
              ? SimulationCoverage.complete
              : SimulationCoverage.partial,
          effectsUndecodable: !plain,
          networkFee: totalFee + BigInt.from(burn),
          maxNetworkFee: totalFee + BigInt.from(maxBurn),
          feePayer: address,
          warnings: [
            if (reveal) 'This includes the first-time public key reveal.',
            if (siteFee)
              'The website chose a network fee. Check the total before approving.',
            if (siteFee &&
                totalFee > minimum * BigInt.from(_siteFeeWarningMultiple))
              'The website\'s network fee is more than $_siteFeeWarningMultiple times the minimum this operation needs. Review the network fee before approving.',
            if (!plain)
              'Contract effects and token permissions are not fully decoded. Review the operation details.',
          ],
          funds: [
            for (final op in operations)
              if (op['kind'] == 'transaction' &&
                  BigInt.parse(op['amount'] as String) > BigInt.zero)
                FundChange(
                  asset: _xtz,
                  address: address,
                  rawAmount: -BigInt.parse(op['amount'] as String),
                  from: address,
                  to: op['destination'] as String,
                  evidence: ReviewEvidence.requestedInstruction,
                ),
          ],
          accounts: [
            for (final op in operations)
              if (op['kind'] == 'delegation')
                AccountChange(
                  kind: AccountChangeKind.authority,
                  address: address,
                  program: address,
                  description: op['delegate'] == null
                      ? 'Remove baker delegation'
                      : 'Delegate to ${op['delegate']}',
                  evidence: ReviewEvidence.requestedInstruction,
                ),
          ],
          programCalls: [
            for (final op in operations)
              if (op['parameters'] != null ||
                  (op['kind'] == 'transaction' &&
                      !isValidTezosImplicitAddress(
                        op['destination'] as String,
                      )))
                ReviewProgramCall(
                  program: op['destination'] as String,
                  instruction:
                      (op['parameters'] as Map?)?['entrypoint'] as String? ??
                      'default',
                ),
          ],
        ),
      );
    } on DappException {
      rethrow;
    } catch (_) {
      throw const DappException(
        -32000,
        'Could not prepare the Tezos operation. Nothing was signed.',
      );
    }
  }

  Future<String> signPrepared(
    PreparedTezosOperation prepared,
    void Function() ensureActive, {
    Future<void>? cancelled,
  }) async {
    if (DateTime.now().toUtc().difference(prepared.review.simulatedAt) >
        const Duration(minutes: 2)) {
      throw const DappException(
        4001,
        'This review expired. Request the operation again.',
      );
    }
    ensureActive();
    final signed = await walletManager.signTezosOperation(
      prepared.review.walletId,
      prepared.forgedHex,
      expectedAddress: prepared.review.address,
      ensureActive: ensureActive,
      cancelled: cancelled,
    );
    ensureActive();
    final raw = _checkedBase58(signed.signature, const [
      9,
      245,
      205,
      134,
      18,
    ], 64);
    if (signed.signedOperationHex.toLowerCase() !=
        prepared.forgedHex.toLowerCase() + bytesToHex(raw)) {
      throw const DappException(
        -32603,
        'The signed operation changed. Nothing was sent.',
      );
    }
    await _verify(
      signed.signature,
      prepared.publicKey,
      Uint8List.fromList([3, ...hexToBytes(prepared.forgedHex)]),
    );
    ensureActive();
    return signed.signedOperationHex;
  }

  /// Broadcasts [signed] and tracks it. [recipient] is the wallet that sent
  /// it, whose received tokens [onApplied] reports once it lands applied.
  Future<String> sendSigned(String signed, {String? recipient}) async {
    final hash = tezosOperationHash(signed);
    var reported = false;
    tracker.start(
      signature: hash,
      chain: tezosMainnet,
      lookup: (_, signature) async {
        final inclusion = await rpc.getOperationInclusion(signature);
        if (inclusion != null &&
            inclusion.applied &&
            recipient != null &&
            !reported) {
          reported = true;
          onApplied(opHash: signature, address: recipient);
        }
        return {
          'value': [
            if (inclusion != null)
              {
                'confirmationStatus': 'confirmed',
                'err': inclusion.applied ? null : true,
                'slot': inclusion.level,
              },
          ],
        };
      },
    );
    try {
      final result = await rpc.injectOperation(signed);
      if (result != hash) throw const FormatException();
      return hash;
    } catch (_) {
      // A timeout can follow acceptance. Never retry an ambiguous injection.
      tracker.markUncertain(tezosMainnet, hash);
      throw const DappException(
        -32000,
        'The submission could not be confirmed. Check the transaction before trying again.',
      );
    }
  }
}

String tezosOperationHash(String signed) => _encodeCheck([
  5,
  116,
  ...Blake2bDigest(digestSize: 32).process(hexToBytes(signed)),
]);
String _encodeCheck(List<int> body) => base58.base58encode([
  ...body,
  ...sha256.convert(sha256.convert(body).bytes).bytes.take(4),
]);
Uint8List _checkedBase58(String encoded, List<int> prefix, int length) {
  final decoded = base58.base58decode(encoded);
  if (decoded.length != prefix.length + length + 4 ||
      List.generate(prefix.length, (i) => decoded[i]).join(',') !=
          prefix.join(',') ||
      _encodeCheck(decoded.sublist(0, decoded.length - 4)) != encoded)
    throw const FormatException();
  return Uint8List.fromList(decoded.sublist(prefix.length, decoded.length - 4));
}

Future<void> _verify(String signature, String key, Uint8List bytes) async {
  final public = _checkedBase58(key, const [13, 15, 37, 217], 32);
  final raw = _checkedBase58(signature, const [9, 245, 205, 134, 18], 64);
  if (!await crypto.Ed25519().verify(
    Blake2bDigest(digestSize: 32).process(bytes),
    signature: crypto.Signature(
      raw,
      publicKey: crypto.SimplePublicKey(
        public,
        type: crypto.KeyPairType.ed25519,
      ),
    ),
  )) {
    throw const DappException(
      -32603,
      'The signature does not match the approved wallet.',
    );
  }
}

String _address(Object? raw) {
  if (raw is! String || !isValidTezosAddress(raw))
    throw const DappException(-32602, 'Invalid Tezos address.');
  return raw;
}

BigInt _nat(Object? raw, String field) {
  final text = raw is int && raw >= 0 ? '$raw' : raw;
  if (text is! String ||
      text.length > 20 ||
      !RegExp(r'^[0-9]+$').hasMatch(text))
    throw DappException(-32602, 'Invalid $field.');
  final value = BigInt.parse(text);
  if (value > BigInt.parse('9223372036854775807'))
    throw DappException(-32602, '$field is too large.');
  return value;
}

List<TezosContentEstimate> _validatedEstimates(
  Map<String, dynamic> response,
  int count,
) {
  final contents = response['contents'];
  if (contents is! List || contents.length != count)
    throw const DappException(
      -32000,
      'Tezos simulation failed. Nothing was signed.',
    );
  for (final content in contents) {
    final metadata = content is Map ? content['metadata'] : null;
    final result = metadata is Map ? metadata['operation_result'] : null;
    if (result is! Map ||
        result['status'] != 'applied' ||
        result['consumed_milligas'] is! String ||
        !RegExp(r'^[0-9]+$').hasMatch(result['consumed_milligas'] as String)) {
      throw const DappException(
        -32000,
        'Tezos simulation failed. Nothing was signed.',
      );
    }
    final internal = metadata['internal_operation_results'];
    if (internal != null &&
        (internal is! List ||
            internal.any(
              (op) =>
                  op is! Map ||
                  op['result'] is! Map ||
                  (op['result'] as Map)['status'] != 'applied',
            ))) {
      throw const DappException(
        -32000,
        'Tezos simulation failed. Nothing was signed.',
      );
    }
  }
  final results = TezosRpcService.perContentEstimates(response);
  if (results.any(
    (result) => !result.applied || result.gas < 0 || result.storage < 0,
  )) {
    throw const DappException(
      -32000,
      'Tezos simulation failed. Nothing was signed.',
    );
  }
  return results;
}
