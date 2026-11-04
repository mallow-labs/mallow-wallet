import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/walletconnect/services/walletconnect_codec.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

void main() {
  const solana = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
  const payer = '4Nd1mBQtrMJVYVfKf2PJy9NZUZdTAsp7D4xWLs4gDB4T';
  const ethereum = '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';
  const tezos = 'tz1KqTpEZ7Yob7QbPE4Hy4Wo8fHG8LhKxZSx';

  WalletConnectCall decode(
    String namespace,
    String method,
    Object? params, {
    String address = solana,
    String chain = 'solana:mainnet',
  }) => decodeWalletConnectRequest(
    namespace: namespace,
    method: method,
    params: params,
    address: address,
    chain: chain,
  );

  test('Account and chain queries answer from the session alone', () {
    expect(
      (decode('eip155', 'eth_accounts', const [], address: ethereum)
              as WalletConnectAnswer)
          .result,
      [ethereum],
    );
    expect(
      (decode('eip155', 'eth_chainId', const [], address: ethereum)
              as WalletConnectAnswer)
          .result,
      '0x1',
    );
    expect(
      (decode('solana', 'solana_getAccounts', const {}) as WalletConnectAnswer)
          .result,
      [
        {'pubkey': solana},
      ],
    );
  });

  test('Switching to any chain but Ethereum mainnet is refused', () {
    expect(
      (decode('eip155', 'wallet_switchEthereumChain', const [
                {'chainId': '0x1'},
              ], address: ethereum)
              as WalletConnectAnswer)
          .result,
      isTrue,
    );
    expect(
      () => decode('eip155', 'wallet_switchEthereumChain', const [
        {'chainId': '0x89'},
      ], address: ethereum),
      throwsA(isA<DappException>().having((e) => e.code, 'code', 4902)),
    );
  });

  test('personal_sign takes either parameter order and checks the account', () {
    for (final params in [
      ['0x68656c6c6f', ethereum],
      [ethereum.toLowerCase(), '0x68656c6c6f'],
    ]) {
      final call =
          decode('eip155', 'personal_sign', params, address: ethereum)
              as WalletConnectCoordinatorCall;
      expect(call.namespace, 'eip155');
      expect(call.params, {'message': '0x68656c6c6f', 'address': ethereum});
      expect(call.result({'signature': '0xsig'}), '0xsig');
    }
    expect(
      () => decode('eip155', 'personal_sign', [
        '0x68656c6c6f',
        '0x0000000000000000000000000000000000000001',
      ], address: ethereum),
      throwsA(isA<DappException>().having((e) => e.code, 'code', 4100)),
    );
  });

  test('eth_sign is never answered', () {
    expect(
      () => decode('eip155', 'eth_sign', [ethereum, '0x00'], address: ethereum),
      throwsA(isA<DappException>().having((e) => e.code, 'code', 5101)),
    );
  });

  test('Typed data under either method name becomes v4', () {
    final call =
        decode('eip155', 'eth_signTypedData', [
              ethereum,
              '{"types":{}}',
            ], address: ethereum)
            as WalletConnectCoordinatorCall;
    expect(call.method, 'eth_signTypedData_v4');
    expect(call.params['typedData'], '{"types":{}}');
  });

  test('A transaction from another account is refused', () {
    expect(
      () => decode('eip155', 'eth_sendTransaction', [
        {'from': '0x0000000000000000000000000000000000000001', 'to': ethereum},
      ], address: ethereum),
      throwsA(isA<DappException>().having((e) => e.code, 'code', 4100)),
    );
    final call =
        decode('eip155', 'eth_sendTransaction', [
              {'from': ethereum, 'to': ethereum, 'value': '0x1'},
            ], address: ethereum)
            as WalletConnectCoordinatorCall;
    expect(call.result({'hash': '0xhash'}), '0xhash');
  });

  test('solana_signMessage sends base64 and answers base58', () {
    final message = Uint8List.fromList(utf8.encode('hello'));
    final call =
        decode('solana', 'solana_signMessage', {
              'message': base58encode(message),
              'pubkey': solana,
            })
            as WalletConnectCoordinatorCall;
    expect(call.namespace, isNull);
    expect(call.params['message'], base64Encode(message));
    final signature = List<int>.filled(64, 7);
    expect(call.result({'signature': base64Encode(signature)}), {
      'signature': base58encode(signature),
    });
    expect(
      () => decode('solana', 'solana_signMessage', {
        'message': base58encode(message),
        'pubkey': payer,
      }),
      throwsA(isA<DappException>().having((e) => e.code, 'code', 4100)),
    );
  });

  test('solana_signTransaction answers with the wallet\'s own signature', () {
    final wallet = Ed25519HDPublicKey.fromBase58(solana);
    final feePayer = Ed25519HDPublicKey.fromBase58(payer);
    final compiled =
        Message.only(
          SystemInstruction.transfer(
            fundingAccount: wallet,
            recipientAccount: feePayer,
            lamports: 1,
          ),
        ).compile(
          recentBlockhash: '11111111111111111111111111111111',
          feePayer: feePayer,
        );
    final signed = SignedTx(
      signatures: [
        Signature(List<int>.filled(64, 1), publicKey: feePayer),
        Signature(List<int>.filled(64, 2), publicKey: wallet),
      ],
      compiledMessage: compiled,
    ).encode();
    final call =
        decode('solana', 'solana_signTransaction', {'transaction': signed})
            as WalletConnectCoordinatorCall;
    expect(call.method, 'signTransaction');
    expect(call.params['chain'], 'solana:mainnet');
    expect(call.result({'transaction': signed}), {
      'signature': base58encode(List<int>.filled(64, 2)),
      'transaction': signed,
    });
  });

  test('solana_signAndSendTransaction passes its send options', () {
    final call =
        decode('solana', 'solana_signAndSendTransaction', {
              'transaction': 'AA==',
              'sendOptions': {'skipPreflight': true},
            })
            as WalletConnectCoordinatorCall;
    expect(call.params['options'], {'skipPreflight': true});
    expect(call.result({'signature': 'sig'}), {'signature': 'sig'});
  });

  test('Tezos requests map onto the Beacon-shaped coordinator calls', () {
    final accounts =
        decode('tezos', 'tezos_getAccounts', const {}, address: tezos)
            as WalletConnectCoordinatorCall;
    expect(accounts.method, 'connect');
    expect(accounts.result({'publicKey': 'edpk'}), [
      {'algo': 'ed25519', 'address': tezos, 'pubkey': 'edpk'},
    ]);
    final sign =
        decode('tezos', 'tezos_sign', {
              'account': tezos,
              'payload': '0x0501',
            }, address: tezos)
            as WalletConnectCoordinatorCall;
    expect(sign.params, {
      'payload': '0501',
      'signingType': 'micheline',
      'sourceAddress': tezos,
    });
    final send =
        decode('tezos', 'tezos_send', {
              'account': tezos,
              'operations': [
                {'kind': 'transaction'},
              ],
            }, address: tezos)
            as WalletConnectCoordinatorCall;
    expect(send.method, 'sendOperations');
    expect(send.result({'hash': 'oo'}), {'operationHash': 'oo', 'hash': 'oo'});
    expect(
      () => decode('tezos', 'tezos_send', {
        'account': 'tz1other',
        'operations': const <Object>[],
      }, address: tezos),
      throwsA(isA<DappException>().having((e) => e.code, 'code', 4100)),
    );
  });
}
