import 'dart:convert';
import 'dart:typed_data';

import 'package:solana/base58.dart';
import 'package:solana/encoder.dart' show SignedTx;

import '../../browser/models/dapp_request.dart';

/// What a WalletConnect request becomes: either an answer the wallet gives at
/// once, from the session alone, or a request for the browser's coordinator,
/// which owns every review, approval and signature.
sealed class WalletConnectCall {
  const WalletConnectCall();
}

/// Answered without the coordinator: nothing is signed or revealed beyond
/// what the session already holds.
class WalletConnectAnswer extends WalletConnectCall {
  const WalletConnectAnswer(this.result);
  final Object? result;
}

/// A coordinator request. [namespace] is the coordinator's (`null` for
/// Solana), and [result] turns its answer into the WalletConnect result.
class WalletConnectCoordinatorCall extends WalletConnectCall {
  const WalletConnectCoordinatorCall({
    required this.namespace,
    required this.method,
    required this.params,
    required this.result,
  });
  final String? namespace;
  final String method;
  final Map<String, Object?> params;
  final Object? Function(Map<Object?, Object?> result) result;
}

/// Translates one session request into a [WalletConnectCall].
///
/// [address] is the session's account for the request's namespace, and
/// [chain] the coordinator's id for the request's chain. Throws a
/// [DappException] for a request this wallet will not answer.
WalletConnectCall decodeWalletConnectRequest({
  required String namespace,
  required String method,
  required Object? params,
  required String address,
  required String chain,
}) => switch (namespace) {
  'solana' => _solana(method, params, address, chain),
  'eip155' => _ethereum(method, params, address),
  'tezos' => _tezos(method, params, address),
  _ => throw const DappException(5101, 'Unsupported method'),
};

WalletConnectCall _solana(
  String method,
  Object? params,
  String address,
  String chain,
) {
  if (method == 'solana_getAccounts' || method == 'solana_requestAccounts') {
    return WalletConnectAnswer([
      {'pubkey': address},
    ]);
  }
  final map = _map(params);
  final account = {'account': address, 'chain': chain};
  switch (method) {
    case 'solana_signTransaction':
      return WalletConnectCoordinatorCall(
        namespace: null,
        method: 'signTransaction',
        params: {'transaction': map['transaction'], ...account},
        result: (result) {
          final transaction = result['transaction'] as String;
          return {
            'signature': solanaSignatureOf(base64Decode(transaction), address),
            'transaction': transaction,
          };
        },
      );
    case 'solana_signAllTransactions':
      return WalletConnectCoordinatorCall(
        namespace: null,
        method: 'signAllTransactions',
        params: {'transactions': map['transactions'], ...account},
        result: (result) => {'transactions': result['transactions']},
      );
    case 'solana_signAndSendTransaction':
      return WalletConnectCoordinatorCall(
        namespace: null,
        method: 'signAndSendTransaction',
        params: {
          'transaction': map['transaction'],
          ...account,
          if (map['sendOptions'] != null) 'options': map['sendOptions'],
        },
        result: (result) => {'signature': result['signature']},
      );
    case 'solana_signMessage':
      final pubkey = map['pubkey'];
      if (pubkey != null && pubkey != address) {
        throw const DappException(
          4100,
          'Requested account does not match the connected wallet',
        );
      }
      final message = map['message'];
      if (message is! String || message.length > 90000) {
        throw const DappException(-32602, 'Invalid message');
      }
      final List<int> bytes;
      try {
        bytes = base58decode(message);
      } catch (_) {
        throw const DappException(-32602, 'Invalid message');
      }
      return WalletConnectCoordinatorCall(
        namespace: null,
        method: 'signMessage',
        params: {'message': base64Encode(bytes), 'account': address},
        result: (result) => {
          'signature': base58encode(
            base64Decode(result['signature'] as String),
          ),
        },
      );
  }
  throw const DappException(5101, 'Unsupported method');
}

WalletConnectCall _ethereum(String method, Object? params, String address) {
  switch (method) {
    case 'eth_accounts':
    case 'eth_requestAccounts':
      return WalletConnectAnswer([address]);
    case 'eth_chainId':
      return const WalletConnectAnswer('0x1');
    case 'wallet_switchEthereumChain':
      final target = _list(params).firstOrNull;
      final id = target is Map ? target['chainId'] : null;
      // EIP-3326 answers null, but the SDK refuses a response with neither
      // result nor error, so the website would read a failure.
      if (id is String && _isMainnet(id)) {
        return const WalletConnectAnswer(true);
      }
      throw const DappException(4902, 'mallow supports Ethereum mainnet only');
  }
  final list = _list(params);
  final lower = address.toLowerCase();
  bool isAccount(Object? value) =>
      value is String && value.toLowerCase() == lower;
  switch (method) {
    case 'personal_sign':
      // [message, address], though some sites send [address, message].
      var message = list.elementAtOrNull(0);
      var account = list.elementAtOrNull(1);
      if (isAccount(message) && !isAccount(account)) {
        (message, account) = (account, message);
      }
      _requireAccount(account, isAccount);
      if (message is! String) {
        throw const DappException(-32602, 'Message must be a string');
      }
      return WalletConnectCoordinatorCall(
        namespace: 'eip155',
        method: 'personal_sign',
        params: {'message': message, 'address': address},
        result: (result) => result['signature'],
      );
    case 'eth_signTypedData_v4':
    case 'eth_signTypedData':
      // [address, typedData]; WalletConnect sends v4 data under both names.
      var account = list.elementAtOrNull(0);
      var typedData = list.elementAtOrNull(1);
      if (!isAccount(account) && isAccount(typedData)) {
        (account, typedData) = (typedData, account);
      }
      _requireAccount(account, isAccount);
      if (typedData == null) {
        throw const DappException(-32602, 'Typed data is required');
      }
      return WalletConnectCoordinatorCall(
        namespace: 'eip155',
        method: 'eth_signTypedData_v4',
        params: {'address': address, 'typedData': typedData},
        result: (result) => result['signature'],
      );
    case 'eth_sendTransaction':
      final transaction = list.firstOrNull;
      if (transaction is! Map) {
        throw const DappException(-32602, 'Invalid transaction');
      }
      _requireAccount(transaction['from'], isAccount);
      return WalletConnectCoordinatorCall(
        namespace: 'eip155',
        method: 'eth_sendTransaction',
        params: {'transaction': transaction},
        result: (result) => result['hash'],
      );
  }
  throw const DappException(5101, 'Unsupported method');
}

WalletConnectCall _tezos(String method, Object? params, String address) {
  final map = _map(params);
  final account = map['account'];
  if (method != 'tezos_getAccounts' && account != address) {
    throw const DappException(
      4100,
      'Requested account does not match the connected wallet',
    );
  }
  switch (method) {
    case 'tezos_getAccounts':
      return WalletConnectCoordinatorCall(
        namespace: 'tezos',
        method: 'connect',
        params: const {},
        result: (result) => [
          {
            'algo': switch (address.substring(0, 3)) {
              'tz2' => 'secp256k1',
              'tz3' => 'p256',
              _ => 'ed25519',
            },
            'address': address,
            'pubkey': result['publicKey'],
          },
        ],
      );
    case 'tezos_sign':
      var payload = map['payload'];
      if (payload is String && payload.startsWith('0x')) {
        payload = payload.substring(2);
      }
      if (payload is! String || payload.isEmpty) {
        throw const DappException(-32602, 'Invalid Tezos message');
      }
      return WalletConnectCoordinatorCall(
        namespace: 'tezos',
        method: 'signPayload',
        params: {
          'payload': payload,
          // WalletConnect names no signing type. A packed Micheline value
          // starts 05; anything else is raw bytes, and the coordinator
          // refuses raw bytes shaped like an operation.
          'signingType': payload.startsWith('05') ? 'micheline' : 'raw',
          'sourceAddress': address,
        },
        result: (result) => {'signature': result['signature']},
      );
    case 'tezos_send':
      return WalletConnectCoordinatorCall(
        namespace: 'tezos',
        method: 'sendOperations',
        params: {
          'operationDetails': map['operations'],
          'sourceAddress': address,
        },
        // `operationHash` is the specified name; some sites read `hash`.
        result: (result) => {
          'operationHash': result['hash'],
          'hash': result['hash'],
        },
      );
  }
  throw const DappException(5101, 'Unsupported method');
}

bool _isMainnet(String chainId) =>
    chainId.toLowerCase() == '0x1' || chainId == '1';

void _requireAccount(Object? account, bool Function(Object?) isAccount) {
  if (account != null && !isAccount(account)) {
    throw const DappException(
      4100,
      'Requested account does not match the connected wallet',
    );
  }
}

Map<String, Object?> _map(Object? params) {
  if (params is Map) return params.cast<String, Object?>();
  throw const DappException(-32602, 'Invalid parameters');
}

List<Object?> _list(Object? params) {
  if (params is List) return params.cast<Object?>();
  throw const DappException(-32602, 'Invalid parameters');
}

/// The base58 signature [address] put on a signed Solana transaction.
///
/// Signatures sit in the order of the message's first account keys, so the
/// wallet's is the one at its key's index; the fee payer's comes first and
/// may belong to someone else.
String solanaSignatureOf(Uint8List transaction, String address) {
  final tx = SignedTx.fromBytes(transaction);
  final keys = tx.compiledMessage.accountKeys;
  final required = tx.compiledMessage.header.numRequiredSignatures;
  for (var i = 0; i < required && i < keys.length; i++) {
    if (keys[i].toBase58() == address && i < tx.signatures.length) {
      return base58encode(tx.signatures[i].bytes);
    }
  }
  throw const DappException(-32603, 'The wallet did not sign');
}
