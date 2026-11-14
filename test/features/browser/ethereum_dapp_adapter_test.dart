import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/eip712.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/simulation_review.dart';
import 'package:mallow_wallet/core/network/ethereum_rpc_service.dart';
import 'package:mallow_wallet/core/network/evm_simulation_decoder.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/browser_transaction_tracker.dart';
import 'package:mallow_wallet/features/browser/services/browser_signing_service.dart'
    show estimateEthereumOutgoingUsd;
import 'package:mallow_wallet/features/browser/services/ethereum_dapp_adapter.dart';
import 'package:mallow_wallet/features/send/models/eth_gas.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wallet/wallet.dart' show EtherAmount, EthereumAddress;
import 'package:web3dart/web3dart.dart' show Transaction, hexToBytes, keccak256;

class _WalletManager extends Mock implements WalletManager {}

String _hex(List<int> bytes) =>
    '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

// The key whose address is the EIP-712 example's "Cow"; expected signatures
// below were produced by viem with the same key.
final _cowKey = keccak256(Uint8List.fromList(utf8.encode('cow')));
const _cow = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';
const _bob = '0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB';
const _usdc = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48';
const _spender = '0x1111111254eeb25477b68fb85ed929f73a960582';

const _viemSigned =
    '0x02f87201078459682f008506fc23ac0082520894bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb87038d7ea4c6800080c080a0c2c51129d9a622c872ce3e802363e1f620a3260c84f02344898c61f96bddb684a051230784a02250dde579eda3da22f765524c0e70eeec572f6d61991a6448c7c2';
const _viemUnsigned =
    '0x02ef01078459682f008506fc23ac0082520894bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb87038d7ea4c6800080c0';

Transaction _viemTransaction() => Transaction(
  to: EthereumAddress.fromHex(_bob),
  value: EtherAmount.inWei(BigInt.from(1000000000000000)),
  data: Uint8List(0),
  maxGas: 21000,
  maxFeePerGas: EtherAmount.inWei(BigInt.from(30000000000)),
  maxPriorityFeePerGas: EtherAmount.inWei(BigInt.from(1500000000)),
  nonce: 7,
);

Map<String, Object?> _mail({Object chainId = 1}) => {
  'types': {
    'EIP712Domain': [
      {'name': 'name', 'type': 'string'},
      {'name': 'version', 'type': 'string'},
      {'name': 'chainId', 'type': 'uint256'},
      {'name': 'verifyingContract', 'type': 'address'},
    ],
    'Person': [
      {'name': 'name', 'type': 'string'},
      {'name': 'wallet', 'type': 'address'},
    ],
    'Mail': [
      {'name': 'from', 'type': 'Person'},
      {'name': 'to', 'type': 'Person'},
      {'name': 'contents', 'type': 'string'},
    ],
  },
  'primaryType': 'Mail',
  'domain': {
    'name': 'Ether Mail',
    'version': '1',
    'chainId': chainId,
    'verifyingContract': '0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC',
  },
  'message': {
    'from': {'name': 'Cow', 'wallet': _cow},
    'to': {'name': 'Bob', 'wallet': _bob},
    'contents': 'Hello, Bob!',
  },
};

void main() {
  late _WalletManager wallets;
  late BrowserTransactionTracker tracker;
  late Map<String, Object? Function(List<Object?>)> rpc;
  late List<(String, List<Object?>)> calls;
  late List<PendingEvmBroadcast> broadcasts;
  late Future<EvmSimulationResult> Function(
    String to,
    String data,
    String value,
  )
  simulate;

  EthereumDappAdapter adapter() => EthereumDappAdapter(
    walletManager: wallets,
    rpc: (method, params) async {
      calls.add((method, params));
      final handler = rpc[method];
      if (handler == null) throw StateError('unexpected $method');
      return handler(params);
    },
    simulate:
        ({
          required String from,
          required String to,
          required String data,
          String value = '0x0',
        }) => simulate(to, data, value),
    tracker: tracker,
    onBroadcast: broadcasts.add,
  );

  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(
      Eip712TypedData.parse({
        'types': {'EIP712Domain': <Object>[]},
        'primaryType': 'EIP712Domain',
        'domain': <String, Object>{},
        'message': <String, Object>{},
      }),
    );
    registerFallbackValue(_viemTransaction());
  });

  setUp(() {
    wallets = _WalletManager();
    tracker = BrowserTransactionTracker(interval: const Duration(hours: 1));
    calls = [];
    broadcasts = [];
    rpc = {
      'eth_getTransactionCount': (_) => '0x7',
      'eth_getBlockByNumber': (_) => {'baseFeePerGas': '0x3b9aca00'},
      'eth_estimateGas': (_) => '0x5208',
      'eth_getCode': (_) => '0x',
    };
    simulate = (to, data, value) async => EvmSimulationResult(
      changes: [
        EvmAssetChange(
          assetType: 'NATIVE',
          changeType: 'TRANSFER',
          from: _cow.toLowerCase(),
          to: to,
          rawAmount: BigInt.parse(value.substring(2), radix: 16).toString(),
        ),
      ],
    );
  });
  tearDown(() => tracker.dispose());

  group('signing primitives agree with viem', () {
    test('an EIP-1559 transaction signs and hashes identically', () async {
      final unsigned = MultiChainDerivation.unsignedEip1559Payload(
        _viemTransaction(),
        1,
      );
      expect(_hex(unsigned), _viemUnsigned);
      final signed = await MultiChainDerivation.signEthereumTransactionWithKey(
        _cowKey,
        _viemTransaction(),
        1,
      );
      expect(_hex(signed), _viemSigned);
      expect(
        ethereumTransactionHash(signed),
        '0x4ebd52005db53ca85facf2dcabbc2044d0d11e1c623df3344010feceb1c251e9',
      );
    });

    test('the EIP-712 example digest signs to viem\'s signature', () {
      // The Mail digest from the EIP-712 specification.
      final digest = hexToBytes(
        'be609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2',
      );
      expect(
        _hex(
          MultiChainDerivation.signEthereumTypedDataDigestWithKey(
            _cowKey,
            digest,
          ),
        ),
        '0x4355c47d63924e8a72e509b65029052eb6c299d53a04e167c5775fd466751c9d07299936d304c153f6443dfa05f40ff007d72911b6f72307f996231605b915621c',
      );
    });
  });

  group('verifySignedEip1559', () {
    final unsigned = hexToBytes(_viemUnsigned);
    final signed = hexToBytes(_viemSigned);

    test('accepts the reviewed transaction signed by the wallet', () {
      verifySignedEip1559(unsigned, signed, _cow);
    });

    test('refuses a signature from another account', () {
      expect(
        () => verifySignedEip1559(unsigned, signed, _bob),
        throwsA(isA<DappException>().having((e) => e.code, 'code', 4100)),
      );
    });

    test('refuses a signed envelope whose fields differ from review', () {
      final other = MultiChainDerivation.unsignedEip1559Payload(
        _viemTransaction().copyWith(nonce: 8),
        1,
      );
      expect(
        () => verifySignedEip1559(other, signed, _cow),
        throwsA(isA<DappException>().having((e) => e.code, 'code', -32602)),
      );
    });

    test('refuses trailing bytes', () {
      expect(
        () => verifySignedEip1559(
          unsigned,
          Uint8List.fromList([...signed, 0]),
          _cow,
        ),
        throwsA(isA<DappException>()),
      );
    });
  });

  group('messages', () {
    test('personal_sign signature is recovered and checked', () async {
      when(
        () => wallets.signEthereumPersonalMessageForWallet(
          any(),
          any(),
          expectedAddress: any(named: 'expectedAddress'),
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      ).thenAnswer(
        (_) async => hexToBytes(
          await MultiChainDerivation.signEthereumPersonalMessageWithKey(
            _cowKey,
            utf8.encode('hello'),
          ),
        ),
      );
      final review = adapter().prepareMessage(
        bytes: Uint8List.fromList(utf8.encode('hello')),
        origin: 'https://example.org',
        address: _cow,
        walletId: 'w',
      );
      final cancelled = Completer<void>();
      void ensureActive() {}

      expect(
        _hex(
          await adapter().signMessage(
            review,
            ensureActive: ensureActive,
            cancelled: cancelled.future,
          ),
        ),
        '0x2452a50a1b27db559e685e82ef59445ff08ca6843b5089aa1c32a70db206d47d693e5ae94daffccbbf590c5d2a72ad5706994748d2c8d3a8b39355589e16e8751c',
      );
      verify(
        () => wallets.signEthereumPersonalMessageForWallet(
          'w',
          review.bytes,
          expectedAddress: _cow,
          ensureActive: ensureActive,
          cancelled: cancelled.future,
        ),
      ).called(1);
      cancelled.complete();
    });

    test('a signature from another key is never returned', () async {
      when(
        () => wallets.signEthereumPersonalMessageForWallet(
          any(),
          any(),
          expectedAddress: any(named: 'expectedAddress'),
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      ).thenAnswer(
        (_) async => hexToBytes(
          await MultiChainDerivation.signEthereumPersonalMessageWithKey(
            keccak256(Uint8List.fromList(utf8.encode('dog'))),
            utf8.encode('hello'),
          ),
        ),
      );
      final review = adapter().prepareMessage(
        bytes: Uint8List.fromList(utf8.encode('hello')),
        origin: 'https://example.org',
        address: _cow,
        walletId: 'w',
      );
      await expectLater(
        adapter().signMessage(review, ensureActive: () {}),
        throwsA(isA<DappException>().having((e) => e.code, 'code', 4100)),
      );
    });

    EthereumMessageReview siwe(String text) => adapter().prepareMessage(
      bytes: Uint8List.fromList(utf8.encode(text)),
      origin: 'https://example.org',
      address: _cow,
      walletId: 'w',
    );

    const header =
        'example.org wants you to sign in with your Ethereum account:\n${_cow}\n\nSign in to Example.\n\n';

    test('Sign In With Ethereum parses strictly, resources included', () {
      final review = siwe(
        '${header}URI: https://example.org\nVersion: 1\nChain ID: 1\nNonce: abc12345\nIssued At: 2026-10-02T00:00:00Z\nResources:\n- https://example.org/a\n- ipfs://b',
      );
      expect(review.signInFields['Domain'], 'example.org');
      expect(
        review.signInFields['Resources'],
        'https://example.org/a\nipfs://b',
      );
      expect(review.signInStatement, 'Sign in to Example.');
    });

    test('an https scheme before the domain names the same site', () {
      final review = siwe(
        'https://$header'
        'URI: https://example.org\nVersion: 1\nChain ID: 1\nNonce: abc12345',
      );
      expect(review.signInFields['Domain'], 'example.org');
    });

    for (final domain in ['example.org', 'other.example']) {
      test('a statement-less sign-in retains the $domain fields', () {
        final text =
            '$domain wants you to sign in with your Ethereum account:\n$_cow\n\n\nURI: https://$domain\nVersion: 1\nChain ID: 1\nNonce: abc12345\nIssued At: 2026-10-02T00:00:00Z';
        final review = siwe(text);
        expect(review.signInFields, {
          'Domain': domain,
          'Account': _cow,
          'URI': 'https://$domain',
          'Version': '1',
          'Chain ID': '1',
          'Nonce': 'abc12345',
          'Issued At': '2026-10-02T00:00:00Z',
        });
        expect(review.signInStatement, isNull);
        expect(review.display, text);
        expect(siwe('$text\nTransfer all funds').signInFields, isEmpty);
        expect(
          siwe(text.replaceFirst('\n\n\nURI:', '\n\n\n\nURI:')).signInFields,
          isEmpty,
        );
      });
    }

    test('another chain retains the parsed sign-in fields', () {
      final review = siwe('${header}URI: https://example.org\nChain ID: 137');
      expect(review.signInFields['Domain'], 'example.org');
      expect(review.signInFields['Chain ID'], '137');
      expect(review.signInStatement, 'Sign in to Example.');
    });

    test('a trailing line or another account is not a sign-in', () {
      expect(
        siwe(
          '${header}URI: https://example.org\nTransfer all funds',
        ).signInFields,
        isEmpty,
      );
      expect(
        siwe(
          header.replaceFirst(_cow, _bob) + 'URI: https://example.org',
        ).signInFields,
        isEmpty,
      );
      expect(
        siwe('${header}Resources:\n- a\nURI: https://example.org').signInFields,
        isEmpty,
      );
    });
  });

  group('typed data', () {
    Future<EthereumTypedDataReview> prepare(Object data) =>
        adapter().prepareTypedData(
          typedData: jsonEncode(data),
          origin: 'https://example.org',
          address: _cow,
          walletId: 'w',
        );

    test(
      'signs the digest the review parsed, checked against the wallet',
      () async {
        when(
          () => wallets.signEthereumTypedDataForWallet(
            any(),
            any(),
            expectedAddress: any(named: 'expectedAddress'),
            ensureActive: any(named: 'ensureActive'),
            cancelled: any(named: 'cancelled'),
          ),
        ).thenAnswer(
          (invocation) async =>
              MultiChainDerivation.signEthereumTypedDataDigestWithKey(
                _cowKey,
                (invocation.positionalArguments[1] as Eip712TypedData).digest,
              ),
        );
        final review = await prepare(_mail());
        expect(review.kind, TypedDataKind.generic);
        expect(
          _hex(await adapter().signTypedData(review, ensureActive: () {})),
          startsWith('0x4355c47d63924e8a72e509b65029052e'),
        );
      },
    );

    test('a signature for another network is refused', () async {
      await expectLater(
        prepare(_mail(chainId: 137)),
        throwsA(isA<DappException>().having((e) => e.code, 'code', 4901)),
      );
    });

    test('malformed typed data is an invalid-params error', () async {
      final data = _mail();
      (data['message']! as Map).remove('contents');
      await expectLater(
        prepare(data),
        throwsA(isA<DappException>().having((e) => e.code, 'code', -32602)),
      );
    });

    for (final primaryType in [
      'TransferWithAuthorization',
      'ReceiveWithAuthorization',
    ]) {
      test('$primaryType is a token transfer authorization', () async {
        final review = await prepare({
          'types': {
            'EIP712Domain': [
              {'name': 'verifyingContract', 'type': 'address'},
              {'name': 'chainId', 'type': 'uint256'},
            ],
            primaryType: [
              {'name': 'from', 'type': 'address'},
              {'name': 'to', 'type': 'address'},
              {'name': 'value', 'type': 'uint256'},
              {'name': 'validAfter', 'type': 'uint256'},
              {'name': 'validBefore', 'type': 'uint256'},
              {'name': 'nonce', 'type': 'bytes32'},
            ],
          },
          'primaryType': primaryType,
          'domain': {'verifyingContract': _usdc, 'chainId': 1},
          'message': {
            'from': _cow,
            'to': _bob,
            'value': '25000000000',
            'validAfter': 0,
            'validBefore': 1893456000,
            'nonce': '0x${'0' * 64}',
          },
        });
        expect(review.kind, TypedDataKind.transfer);
        final transfer = review.transfers.single;
        expect(transfer.token, _usdc);
        expect(transfer.recipient, _bob.toLowerCase());
        expect(transfer.amount, BigInt.from(25000000000));
        expect(transfer.expires, DateTime.utc(2030));
        expect(review.permissions, isEmpty);
        expect(review.tokens[_usdc]?.symbol, 'USDC');
        expect(review.tokens[_usdc]?.decimals, 6);
      });
    }

    test(
      'an unlimited EIP-2612 permit is a permission for its spender',
      () async {
        final review = await prepare({
          'types': {
            'EIP712Domain': [
              {'name': 'name', 'type': 'string'},
              {'name': 'version', 'type': 'string'},
              {'name': 'chainId', 'type': 'uint256'},
              {'name': 'verifyingContract', 'type': 'address'},
            ],
            'Permit': [
              {'name': 'owner', 'type': 'address'},
              {'name': 'spender', 'type': 'address'},
              {'name': 'value', 'type': 'uint256'},
              {'name': 'nonce', 'type': 'uint256'},
              {'name': 'deadline', 'type': 'uint256'},
            ],
          },
          'primaryType': 'Permit',
          'domain': {
            'name': 'USD Coin',
            'version': '2',
            'chainId': 1,
            'verifyingContract': '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
          },
          'message': {
            'owner': _cow,
            'spender': _spender,
            'value': ((BigInt.one << 256) - BigInt.one).toString(),
            'nonce': 0,
            'deadline': 1893456000,
          },
        });
        expect(review.kind, TypedDataKind.permit);
        final grant = review.permissions.single;
        expect(grant.token, _usdc);
        expect(grant.spender, _spender);
        expect(grant.amount, isNull);
        expect(grant.expires, DateTime.utc(2030));
        expect(review.tokens[_usdc]?.symbol, 'USDC');
      },
    );

    test(
      'a Permit2 signature is a permission whatever its primary type',
      () async {
        final review = await prepare({
          'types': {
            'EIP712Domain': [
              {'name': 'name', 'type': 'string'},
              {'name': 'chainId', 'type': 'uint256'},
              {'name': 'verifyingContract', 'type': 'address'},
            ],
            'PermitDetails': [
              {'name': 'token', 'type': 'address'},
              {'name': 'amount', 'type': 'uint160'},
              {'name': 'expiration', 'type': 'uint48'},
              {'name': 'nonce', 'type': 'uint48'},
            ],
            'PermitSingle': [
              {'name': 'details', 'type': 'PermitDetails'},
              {'name': 'spender', 'type': 'address'},
              {'name': 'sigDeadline', 'type': 'uint256'},
            ],
          },
          'primaryType': 'PermitSingle',
          'domain': {
            'name': 'Permit2',
            'chainId': 1,
            'verifyingContract': '0x000000000022D473030F116dDEE9F6B43aC78BA3',
          },
          'message': {
            'details': {
              'token': _usdc,
              'amount': '1000000',
              'expiration': 1893456000,
              'nonce': 0,
            },
            'spender': _spender,
            'sigDeadline': 1893456000,
          },
        });
        expect(review.kind, TypedDataKind.permit2);
        expect(review.permissions.single.amount, BigInt.from(1000000));
        expect(review.permissions.single.token, _usdc);
      },
    );

    test('a Permit2 signature transfer keeps its deadline', () async {
      final review = await prepare({
        'types': {
          'EIP712Domain': [
            {'name': 'name', 'type': 'string'},
            {'name': 'chainId', 'type': 'uint256'},
            {'name': 'verifyingContract', 'type': 'address'},
          ],
          'TokenPermissions': [
            {'name': 'token', 'type': 'address'},
            {'name': 'amount', 'type': 'uint256'},
          ],
          'PermitTransferFrom': [
            {'name': 'permitted', 'type': 'TokenPermissions'},
            {'name': 'spender', 'type': 'address'},
            {'name': 'nonce', 'type': 'uint256'},
            {'name': 'deadline', 'type': 'uint256'},
          ],
        },
        'primaryType': 'PermitTransferFrom',
        'domain': {
          'name': 'Permit2',
          'chainId': 1,
          'verifyingContract': permit2Address,
        },
        'message': {
          'permitted': {'token': _usdc, 'amount': '1000000'},
          'spender': _spender,
          'nonce': 0,
          'deadline': 1893456000,
        },
      });
      expect(review.kind, TypedDataKind.permit2);
      final permission = review.permissions.single;
      expect(permission.token, _usdc);
      expect(permission.spender, _spender);
      expect(permission.amount, BigInt.from(1000000));
      expect(permission.expires, DateTime.utc(2030));
    });

    for (final (count, unlimited) in [
      (20, false),
      (21, true),
      (21, false),
      (23, true),
    ]) {
      test(
        'a $count-entry Permit2 batch with unlimited=$unlimited '
        'counts unsummarized permissions and signs the full payload',
        () async {
          final amount = ((BigInt.one << 160) - BigInt.one).toString();
          final review = await prepare({
            'types': {
              'EIP712Domain': [
                {'name': 'chainId', 'type': 'uint256'},
                {'name': 'verifyingContract', 'type': 'address'},
              ],
              'PermitDetails': [
                {'name': 'token', 'type': 'address'},
                {'name': 'amount', 'type': 'uint160'},
                {'name': 'expiration', 'type': 'uint48'},
                {'name': 'nonce', 'type': 'uint48'},
              ],
              'PermitBatch': [
                {'name': 'details', 'type': 'PermitDetails[]'},
                {'name': 'spender', 'type': 'address'},
                {'name': 'sigDeadline', 'type': 'uint256'},
              ],
            },
            'primaryType': 'PermitBatch',
            'domain': {'chainId': 1, 'verifyingContract': permit2Address},
            'message': {
              'details': [
                for (var i = 0; i < count; i++)
                  {
                    'token': i < 20 ? _bob : _usdc,
                    'amount': i < 20 || !unlimited ? '0' : amount,
                    'expiration': 1893456000,
                    'nonce': 0,
                  },
              ],
              'spender': _spender,
              'sigDeadline': 1893456000,
            },
          });
          expect(review.kind, TypedDataKind.permit2);
          expect(review.permissions, hasLength(20));
          expect(review.unsummarizedPermissionCount, count - 20);
          expect(
            review.permissions.every((p) => p.amount == BigInt.zero),
            isTrue,
          );
          final details = review.data.message['details']! as List;
          expect(details, hasLength(count));
          expect((details.last as Map)['amount'], unlimited ? amount : '0');
          final signedDigests = <Uint8List>[];
          when(
            () => wallets.signEthereumTypedDataForWallet(
              any(),
              any(),
              expectedAddress: any(named: 'expectedAddress'),
              ensureActive: any(named: 'ensureActive'),
              cancelled: any(named: 'cancelled'),
            ),
          ).thenAnswer((invocation) async {
            final digest =
                (invocation.positionalArguments[1] as Eip712TypedData).digest;
            signedDigests.add(digest);
            return MultiChainDerivation.signEthereumTypedDataDigestWithKey(
              _cowKey,
              digest,
            );
          });
          await adapter().signTypedData(review, ensureActive: () {});
          expect(signedDigests.single, orderedEquals(review.data.digest));
        },
      );
    }

    test(
      'Permit2 entries that cannot be decoded are counted as unsummarized',
      () async {
        final review = await prepare({
          'types': {
            'EIP712Domain': [
              {'name': 'chainId', 'type': 'uint256'},
              {'name': 'verifyingContract', 'type': 'address'},
            ],
            'CustomPermissions': [
              {'name': 'details', 'type': 'bytes[]'},
              {'name': 'spender', 'type': 'address'},
            ],
          },
          'primaryType': 'CustomPermissions',
          'domain': {'chainId': 1, 'verifyingContract': permit2Address},
          'message': {
            'details': ['0x00', '0x01'],
            'spender': _spender,
          },
        });
        expect(review.kind, TypedDataKind.permit2);
        expect(review.permissions, isEmpty);
        expect(review.unsummarizedPermissionCount, 2);
      },
    );

    for (final allowed in [false, true]) {
      test('a DAI permit with allowed=$allowed keeps its allowance', () async {
        const dai = '0x6b175474e89094c44da98b954eedeac495271d0f';
        final review = await prepare({
          'types': {
            'EIP712Domain': [
              {'name': 'chainId', 'type': 'uint256'},
              {'name': 'verifyingContract', 'type': 'address'},
            ],
            'Permit': [
              {'name': 'holder', 'type': 'address'},
              {'name': 'spender', 'type': 'address'},
              {'name': 'nonce', 'type': 'uint256'},
              {'name': 'expiry', 'type': 'uint256'},
              {'name': 'allowed', 'type': 'bool'},
            ],
          },
          'primaryType': 'Permit',
          'domain': {'chainId': 1, 'verifyingContract': dai},
          'message': {
            'holder': _cow,
            'spender': _spender,
            'nonce': 0,
            'expiry': 1893456000,
            'allowed': allowed,
          },
        });
        expect(review.kind, TypedDataKind.permit);
        final permission = review.permissions.single;
        expect(permission.token, dai);
        expect(permission.spender, _spender);
        expect(permission.amount, allowed ? null : BigInt.zero);
        expect(permission.expires, DateTime.utc(2030));
      });
    }

    test('a permit with an unknown amount is not labelled unlimited', () async {
      final review = await prepare({
        'types': {
          'EIP712Domain': [
            {'name': 'chainId', 'type': 'uint256'},
            {'name': 'verifyingContract', 'type': 'address'},
          ],
          'Permit': [
            {'name': 'owner', 'type': 'address'},
            {'name': 'spender', 'type': 'address'},
            {'name': 'amount', 'type': 'uint256'},
            {'name': 'deadline', 'type': 'uint256'},
          ],
        },
        'primaryType': 'Permit',
        'domain': {'chainId': 1, 'verifyingContract': _usdc},
        'message': {
          'owner': _cow,
          'spender': _spender,
          'amount': '1000000',
          'deadline': 1893456000,
        },
      });
      expect(review.kind, TypedDataKind.permit);
      expect(review.permissions, isEmpty);
    });
  });

  group('prepareTransaction', () {
    EthereumDappTransactionRequest request(Map<String, Object?> raw) =>
        EthereumDappTransactionRequest.parse(raw, account: _cow);

    for (final (assetType, rawAmount) in [
      ('ERC1155', '5000'),
      ('ERC1155', '9007199254740993'),
      ('ERC1155', null),
      ('ERC721', null),
    ]) {
      test('$assetType transfer preserves copy count $rawAmount', () async {
        simulate = (to, data, value) async => EvmSimulationResult(
          changes: [
            EvmAssetChange(
              assetType: assetType,
              changeType: 'TRANSFER',
              from: _cow.toLowerCase(),
              to: _bob.toLowerCase(),
              contractAddress: _usdc,
              tokenId: '42',
              rawAmount: rawAmount,
            ),
          ],
        );
        final prepared = await adapter().prepareTransaction(
          request: request({'to': _usdc, 'data': '0x12345678'}),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        );
        final nft = prepared.review.nfts.single;
        expect(nft.kind, NftChangeKind.transfer);
        expect(nft.assetId, '$_usdc:42');
        expect(nft.from, _cow.toLowerCase());
        expect(nft.to, _bob.toLowerCase());
        expect(nft.isMultiCopy, assetType == 'ERC1155');
        expect(
          nft.quantity,
          rawAmount == null ? null : BigInt.parse(rawAmount),
        );
      });
    }

    test('an ETH send to an account is fully simulated and priced', () async {
      final prepared = await adapter().prepareTransaction(
        request: request({'to': _bob, 'value': '0x38d7ea4c68000'}),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
      final review = prepared.review;
      expect(review.chain, 'eip155:1');
      expect(review.execution, SimulationExecution.succeeded);
      expect(review.coverage, SimulationCoverage.complete);
      expect(prepared.nonce, 7);
      // 21000 estimate plus a fifth of headroom.
      expect(prepared.gasLimit, 25200);
      expect(prepared.maxPriorityFeePerGas, BigInt.from(1500000000));
      expect(prepared.maxFeePerGas, BigInt.from(3500000000));
      // The expected fee uses the estimate; the limit only bounds the maximum.
      expect(review.networkFee, BigInt.from(21000 * 2500000000));
      expect(
        review.maxNetworkFee,
        BigInt.from(25200) * BigInt.from(3500000000),
      );
      final fund = review.funds.single;
      expect(fund.asset.symbol, 'ETH');
      expect(fund.asset.decimals, 18);
      expect(fund.rawAmount, -BigInt.from(1000000000000000));
      expect(fund.to, _bob.toLowerCase());
    });

    for (final omitLogs in [false, true]) {
      test(
        'a successful simulation with ${omitLogs ? 'omitted' : 'empty'} logs leaves requested ETH unverified',
        () async {
          simulate = (to, data, value) async => decodeSimulateV1([
            {
              'calls': [
                {'status': '0x1', if (!omitLogs) 'logs': <Object?>[]},
              ],
            },
          ]);
          final value = BigInt.from(5) * BigInt.from(10).pow(18);
          final prepared = await adapter().prepareTransaction(
            request: request({
              'to': _bob,
              'value': '0x${value.toRadixString(16)}',
            }),
            walletId: 'w',
            address: _cow,
            origin: 'https://example.org',
          );
          final review = prepared.review;
          expect(review.execution, SimulationExecution.unavailable);
          expect(review.effectsUndecodable, isTrue);
          expect(review.coverage, SimulationCoverage.partial);
          expect(
            review.error,
            'The simulation returned effects this wallet could not decode.',
          );
          final fund = review.funds.single;
          expect(fund.asset.id, evmNativeAssetId);
          expect(fund.rawAmount, -value);
          expect(fund.from, _cow.toLowerCase());
          expect(fund.to, _bob.toLowerCase());
          expect(fund.evidence, ReviewEvidence.requestedInstruction);
          expect(review.networkFee, isNotNull);
          expect(estimateEthereumOutgoingUsd(review, (_) => 2000), isNull);
        },
      );
    }

    test('a review asks for its independent reads at once', () async {
      final nonce = Completer<Object?>();
      rpc['eth_getTransactionCount'] = (_) => nonce.future;
      var simulated = false;
      final simulateValue = simulate;
      simulate = (to, data, value) {
        simulated = true;
        return simulateValue(to, data, value);
      };
      final prepared = adapter().prepareTransaction(
        request: request({'to': _bob, 'value': '0x38d7ea4c68000'}),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
      await Future<void>.delayed(Duration.zero);
      expect(simulated, isTrue);
      expect(
        calls.map((c) => c.$1),
        containsAll([
          'eth_getTransactionCount',
          'eth_estimateGas',
          'eth_getCode',
        ]),
      );

      nonce.complete('0x7');
      final result = await prepared;
      expect(result.nonce, 7);
      expect(result.review.coverage, SimulationCoverage.complete);
      // Without a fee market, the latest block is read once for both the
      // default fee and the estimate.
      expect(calls.where((c) => c.$1 == 'eth_getBlockByNumber'), hasLength(1));
    });

    test(
      'a smaller native transfer does not verify the requested value',
      () async {
        simulate = (to, data, value) async => EvmSimulationResult(
          changes: [
            EvmAssetChange(
              assetType: 'NATIVE',
              changeType: 'TRANSFER',
              from: _cow,
              to: to,
              rawAmount: '1',
            ),
          ],
        );
        final prepared = await adapter().prepareTransaction(
          request: request({'to': _bob, 'value': '0x2'}),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        );
        final review = prepared.review;
        expect(review.execution, SimulationExecution.unavailable);
        expect(review.effectsUndecodable, isTrue);
        expect(review.coverage, SimulationCoverage.partial);
        expect(
          review.funds
              .singleWhere(
                (fund) => fund.evidence == ReviewEvidence.requestedInstruction,
              )
              .rawAmount,
          -BigInt.two,
        );
        expect(estimateEthereumOutgoingUsd(review, (_) => 2000), isNull);
      },
    );

    test('a self-send needs no outgoing native trace', () async {
      simulate = (to, data, value) async =>
          const EvmSimulationResult(changes: []);
      final prepared = await adapter().prepareTransaction(
        request: request({'to': _cow, 'value': '0x2'}),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
      expect(prepared.review.execution, SimulationExecution.succeeded);
      expect(prepared.review.effectsUndecodable, isFalse);
      expect(prepared.review.coverage, SimulationCoverage.complete);
      expect(prepared.review.funds, isEmpty);
    });

    test('a refunded native transfer still verifies requested value', () async {
      simulate = (to, data, value) async => EvmSimulationResult(
        changes: [
          EvmAssetChange(
            assetType: 'NATIVE',
            changeType: 'TRANSFER',
            from: _cow,
            to: to,
            rawAmount: '2',
          ),
          EvmAssetChange(
            assetType: 'NATIVE',
            changeType: 'TRANSFER',
            from: to,
            to: _cow,
            rawAmount: '2',
          ),
        ],
      );
      final prepared = await adapter().prepareTransaction(
        request: request({
          'to': _spender,
          'value': '0x2',
          'data': '0x12345678',
        }),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
      expect(prepared.review.execution, SimulationExecution.succeeded);
      expect(prepared.review.effectsUndecodable, isFalse);
      expect(prepared.review.funds, isEmpty);
    });

    test(
      'an unlimited approval from the simulation becomes a permission',
      () async {
        simulate = (to, data, value) async => EvmSimulationResult(
          changes: [
            EvmAssetChange(
              assetType: 'ERC20',
              changeType: 'APPROVE',
              from: _cow.toLowerCase(),
              to: _spender,
              contractAddress: _usdc,
              rawAmount: ((BigInt.one << 256) - BigInt.one).toString(),
            ),
          ],
        );
        final data =
            '0x095ea7b3${_spender.substring(2).padLeft(64, '0')}${'f' * 64}';
        final prepared = await adapter().prepareTransaction(
          request: request({'to': _usdc, 'data': data}),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        );
        final review = prepared.review;
        expect(review.coverage, SimulationCoverage.partial);
        final approval = review.accounts.single;
        expect(approval.kind, AccountChangeKind.approve);
        expect(approval.beneficiary, _spender);
        expect(approval.rawAllowance, (BigInt.one << 256) - BigInt.one);
        expect(review.assets[_usdc]?.symbol, 'USDC');
        expect(review.programCalls.single.instruction, 'approve');
      },
    );

    test(
      'a successful simulation without logs keeps a Permit2 approval',
      () async {
        simulate = (to, data, value) async =>
            const EvmSimulationResult(changes: []);
        final amount = (BigInt.one << 160) - BigInt.one;
        final data =
            '0x87517c45'
            '${_usdc.substring(2).padLeft(64, '0')}'
            '${_spender.substring(2).padLeft(64, '0')}'
            '${amount.toRadixString(16).padLeft(64, '0')}'
            '${((BigInt.one << 48) - BigInt.one).toRadixString(16).padLeft(64, '0')}';
        final prepared = await adapter().prepareTransaction(
          request: request({'to': permit2Address, 'data': data}),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        );
        final review = prepared.review;
        expect(review.execution, SimulationExecution.succeeded);
        expect(review.funds, isEmpty);
        final permission = review.accounts.single;
        expect(permission.kind, AccountChangeKind.approve);
        expect(permission.assetId, _usdc);
        expect(permission.program, permit2Address);
        expect(permission.beneficiary, _spender);
        expect(permission.rawAllowance, amount);
        expect(permission.evidence, ReviewEvidence.requestedInstruction);
      },
    );

    test(
      'a successful simulation without logs keeps a Permit2 revocation',
      () async {
        simulate = (to, data, value) async =>
            const EvmSimulationResult(changes: []);
        final data =
            '0x87517c45'
            '${_usdc.substring(2).padLeft(64, '0')}'
            '${_spender.substring(2).padLeft(64, '0')}'
            '${'0' * 128}';
        final prepared = await adapter().prepareTransaction(
          request: request({'to': permit2Address, 'data': data}),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        );
        final review = prepared.review;
        expect(review.execution, SimulationExecution.succeeded);
        expect(review.funds, isEmpty);
        final permission = review.accounts.single;
        expect(permission.kind, AccountChangeKind.revoke);
        expect(permission.description, 'Permit2 allowance revoked');
        expect(permission.assetId, _usdc);
        expect(permission.program, permit2Address);
        expect(permission.beneficiary, isNull);
        expect(permission.rawAllowance, BigInt.zero);
        expect(permission.evidence, ReviewEvidence.requestedInstruction);
        expect(review.coverage, SimulationCoverage.partial);
        expect(estimateEthereumOutgoingUsd(review, (_) => 2000), isNull);
      },
    );

    test(
      'a successful simulation without logs keeps a token approval',
      () async {
        simulate = (to, data, value) async =>
            const EvmSimulationResult(changes: []);
        final data =
            '0x095ea7b3${_spender.substring(2).padLeft(64, '0')}${'f' * 64}';
        final prepared = await adapter().prepareTransaction(
          request: request({'to': _usdc, 'data': data}),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        );
        final permission = prepared.review.accounts.single;
        expect(permission.kind, AccountChangeKind.approve);
        expect(permission.assetId, _usdc);
        expect(permission.beneficiary, _spender);
        expect(permission.evidence, ReviewEvidence.requestedInstruction);
      },
    );

    test(
      'a simulated approval for another spender does not hide the request',
      () async {
        simulate = (to, data, value) async => const EvmSimulationResult(
          changes: [
            EvmAssetChange(
              assetType: 'ERC20',
              changeType: 'APPROVE',
              from: _cow,
              to: _bob,
              contractAddress: _usdc,
              rawAmount: '1000000',
            ),
          ],
        );
        final data =
            '0x095ea7b3${_spender.substring(2).padLeft(64, '0')}${'f' * 64}';
        final prepared = await adapter().prepareTransaction(
          request: request({'to': _usdc, 'data': data}),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        );
        expect(prepared.review.accounts, hasLength(2));
        expect(prepared.review.accounts.map((a) => a.beneficiary), [
          _bob.toLowerCase(),
          _spender,
        ]);
      },
    );

    test(
      'an NFT approval from simulation is not duplicated by calldata',
      () async {
        simulate = (to, data, value) async => const EvmSimulationResult(
          changes: [
            EvmAssetChange(
              assetType: 'ERC721',
              changeType: 'APPROVE',
              from: _cow,
              to: _spender,
              contractAddress: _bob,
              tokenId: '0',
            ),
          ],
        );
        final data =
            '0x095ea7b3${_spender.substring(2).padLeft(64, '0')}${'0' * 64}';
        final prepared = await adapter().prepareTransaction(
          request: request({'to': _bob, 'data': data}),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        );
        final permission = prepared.review.accounts.single;
        expect(permission.kind, AccountChangeKind.approve);
        expect(permission.assetId, '${_bob.toLowerCase()}:0');
        expect(permission.rawAllowance, isNull);
        expect(permission.evidence, ReviewEvidence.simulatedState);
      },
    );

    test(
      'an unavailable simulation keeps approval of NFT token zero as a permission',
      () async {
        simulate = (to, data, value) async =>
            throw const EthereumRpcException('down');
        final data =
            '0x095ea7b3${_spender.substring(2).padLeft(64, '0')}${'0' * 64}';
        final prepared = await adapter().prepareTransaction(
          request: request({'to': _bob, 'data': data}),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        );
        expect(prepared.review.execution, SimulationExecution.unavailable);
        final permission = prepared.review.accounts.single;
        expect(permission.kind, AccountChangeKind.approve);
        expect(permission.beneficiary, _spender);
        expect(permission.description, contains('NFT token ID'));
        expect(permission.evidence, ReviewEvidence.requestedInstruction);
      },
    );

    test('a failed simulation falls back to the request\'s own intent', () async {
      simulate = (to, data, value) async =>
          const EvmSimulationResult(changes: [], error: 'execution reverted');
      final data =
          '0xa22cb465${_spender.substring(2).padLeft(64, '0')}${'1'.padLeft(64, '0')}';
      final prepared = await adapter().prepareTransaction(
        request: request({'to': _bob, 'data': data, 'gas': '0x30000'}),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
      final review = prepared.review;
      expect(review.execution, SimulationExecution.failed);
      expect(review.error, 'Simulation failed: execution reverted');
      expect(review.networkFee, isNull);
      final grant = review.accounts.single;
      expect(grant.evidence, ReviewEvidence.requestedInstruction);
      expect(grant.beneficiary, _spender);
      expect(grant.rawAllowance, isNull);
    });

    test(
      'an undecodable successful Transfer log keeps its fee and unknown value',
      () async {
        simulate = (to, data, value) async => decodeSimulateV1([
          {
            'calls': [
              {
                'status': '0x1',
                'logs': [
                  {
                    'address': _usdc,
                    'topics': [
                      '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
                    ],
                    'data': '0x${'0' * 192}',
                  },
                ],
              },
            ],
          },
        ]);
        final prepared = await adapter().prepareTransaction(
          request: request({'to': _spender, 'data': '0x12345678'}),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        );
        expect(prepared.review.execution, SimulationExecution.unavailable);
        expect(prepared.review.effectsUndecodable, isTrue);
        expect(
          prepared.review.error,
          'The simulation returned effects this wallet could not decode.',
        );
        expect(prepared.review.coverage, SimulationCoverage.partial);
        expect(prepared.review.networkFee, BigInt.from(21000 * 2500000000));
        expect(estimateEthereumOutgoingUsd(prepared.review, (_) => 1), isNull);
        expect(prepared.review.funds, isEmpty);
        final repriced = adapter().applyGas(
          prepared,
          EthGasSelection(
            mode: EthGasMode.custom,
            maxFeePerGas: BigInt.from(4000000000),
            maxPriorityFeePerGas: BigInt.from(2000000000),
            gasLimit: prepared.gasLimit,
          ),
        );
        expect(repriced.review.effectsUndecodable, isTrue);
        expect(repriced.review.networkFee, BigInt.from(21000 * 3000000000));
        expect(estimateEthereumOutgoingUsd(repriced.review, (_) => 1), isNull);
      },
    );

    test(
      'an invalid simulation response keeps its effects unverified',
      () async {
        simulate = (to, data, value) async =>
            throw const FormatException('malformed response');
        final prepared = await adapter().prepareTransaction(
          request: request({'to': _bob, 'value': '0x1'}),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        );
        expect(prepared.review.execution, SimulationExecution.unavailable);
        expect(prepared.review.effectsUndecodable, isTrue);
        expect(
          prepared.review.error,
          'The simulation returned effects this wallet could not decode.',
        );
        expect(prepared.review.networkFee, BigInt.from(21000 * 2500000000));
        expect(estimateEthereumOutgoingUsd(prepared.review, (_) => 1), isNull);
        expect(
          prepared.review.funds.single.evidence,
          ReviewEvidence.requestedInstruction,
        );
      },
    );

    test('an unavailable simulation leaves the review unverified', () async {
      simulate = (to, data, value) async =>
          throw const EthereumRpcException('down');
      final prepared = await adapter().prepareTransaction(
        request: request({'to': _bob, 'value': '0x1'}),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
      expect(prepared.review.execution, SimulationExecution.unavailable);
      expect(
        prepared.review.funds.single.evidence,
        ReviewEvidence.requestedInstruction,
      );
    });

    test(
      'a gas estimate that reverts with no website gas stops here',
      () async {
        rpc['eth_estimateGas'] = (_) =>
            throw const EthereumDappRpcException(3, revertData: '0x');
        await expectLater(
          adapter().prepareTransaction(
            request: request({'to': _bob}),
            walletId: 'w',
            address: _cow,
            origin: 'https://example.org',
          ),
          throwsA(isA<DappException>().having((e) => e.code, 'code', -32000)),
        );
      },
    );

    test('a large website gas limit warns about the maximum cost', () async {
      rpc['eth_estimateGas'] = (_) => '0x7530'; // 30 000
      final prepared = await adapter().prepareTransaction(
        request: request({
          'to': _spender,
          'data': '0x12345678',
          'gas': '0x1c9c380', // 30 000 000
          'maxFeePerGas': '0x174876e800', // 100 gwei
          'maxPriorityFeePerGas': '0x174876e800',
        }),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
      expect(prepared.gasLimit, 30000000);
      expect(prepared.transaction.maxGas, 30000000);
      expect(prepared.review.networkFee, BigInt.from(3000000000000000));
      expect(prepared.review.maxNetworkFee, BigInt.from(3000000000000000000));
      expect(
        prepared.review.warnings,
        contains(
          'The gas limit is more than 5 times the estimate. A contract can consume the full limit, so the network fee could reach 3 ETH.',
        ),
      );
    });

    test('website fee suggestions are honoured within a cap', () async {
      final prepared = await adapter().prepareTransaction(
        request: request({
          'to': _bob,
          'maxFeePerGas': '0x2540be400',
          'maxPriorityFeePerGas': '0x3b9aca00',
        }),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
      expect(prepared.maxFeePerGas, BigInt.from(10000000000));
      expect(prepared.maxPriorityFeePerGas, BigInt.from(1000000000));
      await expectLater(
        adapter().prepareTransaction(
          request: request({'to': _bob, 'gasPrice': '0x${'f' * 20}'}),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        ),
        throwsA(isA<DappException>().having((e) => e.code, 'code', -32602)),
      );
    });
  });

  group('gas editing', () {
    final gwei = BigInt.from(1000000000);
    EthGasMarket market({BigInt? fee, BigInt? tip}) => EthGasMarket(
      baseFeeWei: gwei * BigInt.from(10),
      priorityLowWei: gwei,
      priorityHighWei: gwei * BigInt.two,
      congestion: 0.2,
      historicalBaseFeeMinWei: gwei,
      historicalBaseFeeMaxWei: gwei * BigInt.from(40),
      historicalPriorityMinWei: BigInt.zero,
      historicalPriorityMaxWei: gwei * BigInt.from(3),
      low: EthGasTier(
        mode: EthGasMode.low,
        maxFeePerGas: fee ?? gwei * BigInt.from(12),
        maxPriorityFeePerGas: gwei,
        minWaitMs: 30000,
        maxWaitMs: 60000,
      ),
      market: EthGasTier(
        mode: EthGasMode.market,
        maxFeePerGas: fee ?? gwei * BigInt.from(20),
        maxPriorityFeePerGas: tip ?? gwei * BigInt.two,
        minWaitMs: 15000,
        maxWaitMs: 30000,
      ),
    );
    late PreferencesService prefs;
    late EthGasMarket live;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await PreferencesService.create();
      live = market();
    });

    EthereumDappAdapter priced({bool gasMarketUnavailable = false}) =>
        EthereumDappAdapter(
          walletManager: wallets,
          rpc: (method, params) async => rpc[method]!(params),
          simulate:
              ({
                required String from,
                required String to,
                required String data,
                String value = '0x0',
              }) => simulate(to, data, value),
          gasMarket: () async {
            if (gasMarketUnavailable) {
              throw const EthereumRpcException('Gas market unavailable');
            }
            return live;
          },
          preferences: prefs,
          tracker: tracker,
          onBroadcast: broadcasts.add,
        );

    Future<PreparedEthereumTransaction> prepare(
      Map<String, Object?> raw, [
      EthereumDappAdapter? using,
    ]) => (using ?? priced()).prepareTransaction(
      request: EthereumDappTransactionRequest.parse(raw, account: _cow),
      walletId: 'w',
      address: _cow,
      origin: 'https://example.org',
    );

    test('starts from the saved tier and prices against the market', () async {
      await prefs.setEthGasMode('low');
      final prepared = await prepare({'to': _bob, 'value': '0x1'});
      expect(prepared.canEditFee, isTrue);
      expect(prepared.feeFromSite, isFalse);
      expect(prepared.selection!.mode, EthGasMode.low);
      expect(prepared.maxFeePerGas, gwei * BigInt.from(12));
      expect(prepared.estimatedGas, BigInt.from(21000));
      expect(prepared.defaultGasLimit, 25200);
      // Expected fee: the estimate at base 10 + tip 1 gwei, not the limit.
      expect(
        prepared.review.networkFee,
        BigInt.from(21000) * gwei * BigInt.from(11),
      );
      expect(
        prepared.review.maxNetworkFee,
        BigInt.from(25200) * gwei * BigInt.from(12),
      );
    });

    test('a website\'s own fee is kept, marked as the site\'s', () async {
      final prepared = await prepare({
        'to': _bob,
        'maxFeePerGas': '0x${(gwei * BigInt.from(50)).toRadixString(16)}',
        'maxPriorityFeePerGas':
            '0x${(gwei * BigInt.from(3)).toRadixString(16)}',
      });
      expect(prepared.feeFromSite, isTrue);
      expect(prepared.selection!.mode, EthGasMode.custom);
      expect(prepared.maxFeePerGas, gwei * BigInt.from(50));
    });

    for (final (maxFee, tip, warning) in [
      (101, 2, 'maximum fee'),
      (20, 11, 'priority fee'),
    ]) {
      test(
        'a website $warning above five times market is warned about',
        () async {
          final adapter = priced();
          final prepared = await prepare({
            'to': _bob,
            'maxFeePerGas':
                '0x${(gwei * BigInt.from(maxFee)).toRadixString(16)}',
            'maxPriorityFeePerGas':
                '0x${(gwei * BigInt.from(tip)).toRadixString(16)}',
          }, adapter);
          expect(prepared.maxFeePerGas, gwei * BigInt.from(maxFee));
          expect(prepared.maxPriorityFeePerGas, gwei * BigInt.from(tip));
          expect(
            prepared.review.warnings,
            contains(
              'The website\'s $warning is more than 5 times the Market tier. Review the maximum network fee before approving.',
            ),
          );
          final unchanged = adapter.applyGas(prepared, prepared.selection!);
          expect(unchanged.feeFromSite, isTrue);
          expect(unchanged.review.warnings, prepared.review.warnings);
          expect(unchanged.review.payloadDigest, prepared.review.payloadDigest);
          final gasOnly = adapter.applyGas(
            unchanged,
            EthGasSelection(
              mode: EthGasMode.custom,
              maxFeePerGas: unchanged.maxFeePerGas,
              maxPriorityFeePerGas: unchanged.maxPriorityFeePerGas,
              gasLimit: 30000,
            ),
          );
          expect(gasOnly.feeFromSite, isTrue);
          expect(gasOnly.review.warnings, prepared.review.warnings);
          final edited = adapter.applyGas(
            gasOnly,
            EthGasSelection.fromTier(live.market, gasLimit: prepared.gasLimit),
          );
          expect(edited.feeFromSite, isFalse);
          expect(edited.review.warnings, isEmpty);
          expect(edited.maxFeePerGas, live.market.maxFeePerGas);
        },
      );
    }

    test(
      'website fees at five times market need no excess-fee warning',
      () async {
        final prepared = await prepare({
          'to': _bob,
          'maxFeePerGas': '0x${(gwei * BigInt.from(100)).toRadixString(16)}',
          'maxPriorityFeePerGas':
              '0x${(gwei * BigInt.from(10)).toRadixString(16)}',
        });
        expect(prepared.review.warnings, isEmpty);
      },
    );

    test('legacy website gas prices get the market fee warning', () async {
      final prepared = await prepare({
        'to': _bob,
        'gasPrice': '0x${(gwei * BigInt.from(101)).toRadixString(16)}',
      });
      expect(
        prepared.review.warnings.single,
        contains('website\'s maximum fee is more than 5 times'),
      );
    });

    for (final feeField in ['gasPrice', 'maxFeePerGas']) {
      for (final maxFeeWei in [1000000000, 50000000]) {
        test(
          '$feeField without a tip uses the low market tip capped at $maxFeeWei wei',
          () async {
            final tip = gwei ~/ BigInt.from(10);
            live = market(tip: tip);
            final maxFee = BigInt.from(maxFeeWei);
            final prepared = await prepare({
              'to': _bob,
              feeField: '0x${maxFee.toRadixString(16)}',
            });
            expect(prepared.maxFeePerGas, maxFee);
            expect(prepared.maxPriorityFeePerGas, maxFee < tip ? maxFee : tip);
            expect(prepared.review.warnings, isEmpty);
          },
        );
      }
    }

    test('a gas market outage still warns about excessive website fees', () async {
      final fee = gwei * BigInt.from(10000);
      final prepared = await prepare({
        'to': _bob,
        'gas': '0x5208',
        'maxFeePerGas': '0x${fee.toRadixString(16)}',
        'maxPriorityFeePerGas': '0x${fee.toRadixString(16)}',
      }, priced(gasMarketUnavailable: true));
      expect(prepared.canEditFee, isFalse);
      expect(prepared.maxFeePerGas, fee);
      expect(prepared.maxPriorityFeePerGas, fee);
      expect(prepared.review.maxNetworkFee, BigInt.from(21000) * fee);
      expect(
        prepared.review.warnings,
        containsAll([
          'The website\'s maximum fee is more than 5 times the node-derived default. Review the maximum network fee before approving.',
          'The website\'s priority fee is more than 5 times the node-derived default. Review the maximum network fee before approving.',
        ]),
      );
    });

    test(
      'website fees at five times the node default need no warning',
      () async {
        final prepared = await prepare({
          'to': _bob,
          'maxFeePerGas': '0x${BigInt.from(17500000000).toRadixString(16)}',
          'maxPriorityFeePerGas':
              '0x${BigInt.from(7500000000).toRadixString(16)}',
        }, priced(gasMarketUnavailable: true));
        expect(prepared.canEditFee, isFalse);
        expect(prepared.review.warnings, isEmpty);
      },
    );

    test(
      'the large gas warning follows the edited limit and maximum fee',
      () async {
        final adapter = priced();
        final prepared = await prepare({'to': _bob, 'gas': '0x19a29'}, adapter);
        expect(prepared.gasLimit, 105001);
        expect(
          prepared.review.warnings.single,
          contains('more than 5 times the estimate'),
        );
        final edited = adapter.applyGas(
          prepared,
          EthGasSelection.fromTier(live.market, gasLimit: 105000),
        );
        expect(edited.review.warnings, isEmpty);
        final higher = adapter.applyGas(
          prepared,
          EthGasSelection.custom(
            maxBaseFeeGwei: 30,
            priorityFeeGwei: 5,
            gasLimit: 210000,
          ),
        );
        expect(
          higher.review.warnings.single,
          contains('network fee could reach 0.00735 ETH'),
        );
      },
    );

    test('applying a new fee re-prices the transaction, the review and its '
        'digest without simulating again', () async {
      var simulations = 0;
      final simulateOnce = simulate;
      simulate = (to, data, value) {
        simulations++;
        return simulateOnce(to, data, value);
      };
      final adapter = priced();
      final prepared = await prepare({'to': _bob, 'value': '0x1'}, adapter);
      final custom = EthGasSelection.custom(
        maxBaseFeeGwei: 30,
        priorityFeeGwei: 5,
        gasLimit: 40000,
      );
      final edited = adapter.applyGas(prepared, custom);
      expect(simulations, 1);
      expect(edited.feeFromSite, isFalse);
      expect(edited.selection, custom);
      expect(edited.transaction.maxFeePerGas!.getInWei, gwei * BigInt.from(35));
      expect(
        edited.transaction.maxPriorityFeePerGas!.getInWei,
        gwei * BigInt.from(5),
      );
      expect(edited.transaction.maxGas, 40000);
      expect(edited.transaction.nonce, prepared.nonce);
      expect(edited.review.payloadDigest, isNot(prepared.review.payloadDigest));
      expect(
        edited.review.maxNetworkFee,
        BigInt.from(40000) * gwei * BigInt.from(35),
      );
      expect(edited.review.funds.single.rawAmount, -BigInt.one);
      expect(edited.review.simulatedAt, prepared.review.simulatedAt);
      // The re-priced bytes are the ones that get signed.
      when(
        () => wallets.signEthereumTransaction(
          any(),
          any(),
          chainId: any(named: 'chainId'),
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      ).thenAnswer(
        (invocation) => MultiChainDerivation.signEthereumTransactionWithKey(
          _cowKey,
          invocation.positionalArguments[1] as Transaction,
          1,
        ),
      );
      final cancelled = Completer<void>();
      void ensureActive() {}
      final signed = await adapter.signPrepared(
        edited,
        ensureActive: ensureActive,
        cancelled: cancelled.future,
      );
      verify(
        () => wallets.signEthereumTransaction(
          'w',
          edited.transaction,
          chainId: 1,
          ensureActive: ensureActive,
          cancelled: cancelled.future,
        ),
      ).called(1);
      cancelled.complete();
      verifySignedEip1559(
        MultiChainDerivation.unsignedEip1559Payload(edited.transaction, 1),
        signed,
        _cow,
      );
    });

    test(
      'a gas limit below the estimate is allowed but warned about',
      () async {
        rpc['eth_estimateGas'] = (_) => '0xc350'; // 50 000
        final adapter = priced();
        final prepared = await prepare({'to': _bob}, adapter);
        expect(
          prepared.review.warnings.where((w) => w.contains('below')),
          isEmpty,
        );
        PreparedEthereumTransaction limit(int gas) => adapter.applyGas(
          prepared,
          EthGasSelection.fromTier(live.market, gasLimit: gas),
        );
        expect(
          limit(40000).review.warnings.first,
          contains('below the estimate'),
        );
        expect(
          limit(60000).review.warnings.where((w) => w.contains('below')),
          isEmpty,
        );
        expect(
          limit(40000).review.maxNetworkFee,
          lessThan(limit(60000).review.maxNetworkFee!),
        );
      },
    );

    test('an impossible fee or gas limit is refused', () async {
      final adapter = priced();
      final prepared = await prepare({'to': _bob}, adapter);
      expect(
        () => adapter.applyGas(
          prepared,
          EthGasSelection.custom(
            maxBaseFeeGwei: 10,
            priorityFeeGwei: 1,
            gasLimit: 20999,
          ),
        ),
        throwsA(isA<DappException>()),
      );
      expect(
        () => adapter.applyGas(
          prepared,
          EthGasSelection(
            mode: EthGasMode.custom,
            maxFeePerGas: gwei,
            maxPriorityFeePerGas: gwei * BigInt.two,
            gasLimit: 21000,
          ),
        ),
        throwsA(isA<DappException>()),
      );
    });

    test(
      'without a usable market the fee is the node default and read-only',
      () async {
        live = market(fee: BigInt.zero);
        final prepared = await prepare({'to': _bob});
        expect(prepared.canEditFee, isFalse);
        // 2 × the latest block's base fee (1 gwei) + the 1.5 gwei tip.
        expect(prepared.maxFeePerGas, BigInt.from(3500000000));
      },
    );
  });

  group('sendSigned', () {
    late PreparedEthereumTransaction prepared;
    setUp(() async {
      rpc['eth_getTransactionCount'] = (_) => '0x7';
      prepared = await adapter().prepareTransaction(
        request: EthereumDappTransactionRequest.parse({
          'to': _bob,
          'value': '0x38d7ea4c68000',
        }, account: _cow),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
    });

    test(
      'broadcasts, tracks, and hands the nonce to the pending list',
      () async {
        final signed = hexToBytes(_viemSigned);
        final hash = ethereumTransactionHash(signed);
        rpc['eth_sendRawTransaction'] = (params) {
          expect(params.single, _viemSigned);
          return hash;
        };
        expect(await adapter().sendSigned(signed, prepared), hash);
        expect(
          tracker.recordFor('eip155:1', hash)?.status,
          BrowserTransactionStatus.pending,
        );
        final broadcast = broadcasts.single;
        expect(broadcast.nonce, 7);
        expect(broadcast.hash, hash);
        expect(broadcast.kind, PendingEvmTxKind.other);
      },
    );

    test(
      'a refused submission is marked failed and nothing is tracked',
      () async {
        final signed = hexToBytes(_viemSigned);
        rpc['eth_sendRawTransaction'] = (_) =>
            throw const EthereumDappRpcException(
              -32000,
              message: 'insufficient funds for gas * price + value',
            );
        await expectLater(
          adapter().sendSigned(signed, prepared),
          throwsA(isA<DappException>()),
        );
        expect(
          tracker
              .recordFor('eip155:1', ethereumTransactionHash(signed))
              ?.status,
          BrowserTransactionStatus.failed,
        );
        expect(broadcasts, isEmpty);
      },
    );
  });

  group('Given a broadcast that mines', () {
    late PreparedEthereumTransaction prepared;
    late List<(String, String)> reports;
    final signed = hexToBytes(_viemSigned);
    final hash = ethereumTransactionHash(signed);
    String topicFor(String address) =>
        '0x${address.toLowerCase().substring(2).padLeft(64, '0')}';

    EthereumDappAdapter reporting() => EthereumDappAdapter(
      walletManager: wallets,
      rpc: (method, params) async {
        calls.add((method, params));
        final handler = rpc[method];
        if (handler == null) throw StateError('unexpected $method');
        return handler(params);
      },
      tracker: tracker,
      onBroadcast: broadcasts.add,
      onNftReceived: ({required txHash, required address}) =>
          reports.add((txHash, address)),
    );

    setUp(() async {
      reports = [];
      rpc['eth_sendRawTransaction'] = (_) => hash;
      prepared = await reporting().prepareTransaction(
        request: EthereumDappTransactionRequest.parse({
          'to': _bob,
        }, account: _cow),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
    });

    // The tracker polls an Ethereum broadcast every 12 seconds.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 12));
      await tester.pump();
    }

    Map<String, Object?> receipt(String status, List<List<String>> logs) => {
      'status': status,
      'blockNumber': '0x10',
      'logs': [
        for (final topics in logs) {'topics': topics, 'data': '0x'},
      ],
    };

    testWidgets('an NFT transfer to the wallet reports the hash once', (
      tester,
    ) async {
      rpc['eth_getTransactionReceipt'] = (_) => receipt('0x1', [
        [
          '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
          topicFor(_bob),
          topicFor(_cow),
          '0x${'2a'.padLeft(64, '0')}',
        ],
      ]);

      await reporting().sendSigned(signed, prepared);
      await settle(tester);

      expect(reports, [(hash, _cow.toLowerCase())]);
      expect(
        tracker.recordFor('eip155:1', hash)?.status,
        BrowserTransactionStatus.confirmed,
      );
    });

    testWidgets('an ERC-20 transfer to the wallet reports nothing', (
      tester,
    ) async {
      rpc['eth_getTransactionReceipt'] = (_) => receipt('0x1', [
        [
          '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
          topicFor(_bob),
          topicFor(_cow),
        ],
      ]);

      await reporting().sendSigned(signed, prepared);
      await settle(tester);

      expect(reports, isEmpty);
    });

    testWidgets('a reverted transaction reports nothing', (tester) async {
      rpc['eth_getTransactionReceipt'] = (_) => receipt('0x0', [
        [
          '0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62',
          topicFor(_bob),
          topicFor(_bob),
          topicFor(_cow),
        ],
      ]);

      await reporting().sendSigned(signed, prepared);
      await settle(tester);

      expect(reports, isEmpty);
      expect(
        tracker.recordFor('eip155:1', hash)?.status,
        BrowserTransactionStatus.failed,
      );
    });
  });

  group('receiptDeliversNft', () {
    // Checksummed, as the wallet stores it; topics are lowercase.
    const wallet = _cow;
    final walletTopic =
        '0x${wallet.toLowerCase().substring(2).padLeft(64, '0')}';
    final otherTopic = '0x${('22' * 20).padLeft(64, '0')}';
    Map<String, Object?> withLog(List<String> topics, {bool removed = false}) =>
        {
          'logs': [
            {'topics': topics, 'removed': removed},
          ],
        };
    const transfer =
        '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
    const single =
        '0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62';
    const batch =
        '0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb';
    final id = '0x${'1'.padLeft(64, '0')}';

    test('matches each standard\'s recipient topic, any letter case', () {
      expect(
        receiptDeliversNft(
          withLog([transfer, otherTopic, walletTopic, id]),
          wallet,
        ),
        isTrue,
      );
      expect(
        receiptDeliversNft(
          withLog([
            transfer,
            otherTopic,
            walletTopic.toUpperCase().replaceFirst('0X', '0x'),
            id,
          ]),
          wallet.toLowerCase(),
        ),
        isTrue,
      );
      expect(
        receiptDeliversNft(
          withLog([single, otherTopic, otherTopic, walletTopic]),
          wallet,
        ),
        isTrue,
      );
      expect(
        receiptDeliversNft(
          withLog([batch, otherTopic, otherTopic, walletTopic]),
          wallet,
        ),
        isTrue,
      );
    });

    test('ignores sends, other recipients and removed logs', () {
      expect(
        receiptDeliversNft(
          withLog([transfer, walletTopic, otherTopic, id]),
          wallet,
        ),
        isFalse,
      );
      expect(
        receiptDeliversNft(
          withLog([single, otherTopic, walletTopic, otherTopic]),
          wallet,
        ),
        isFalse,
      );
      expect(
        receiptDeliversNft(
          withLog([transfer, otherTopic, walletTopic, id], removed: true),
          wallet,
        ),
        isFalse,
      );
      expect(receiptDeliversNft({'logs': null}, wallet), isFalse);
    });
  });

  group('broadcast failures', () {
    late PreparedEthereumTransaction prepared;
    final signed = hexToBytes(_viemSigned);
    setUp(() async {
      prepared = await adapter().prepareTransaction(
        request: EthereumDappTransactionRequest.parse({
          'to': _bob,
        }, account: _cow),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
    });

    testWidgets('an uncertain broadcast resolves from a receipt after three '
        'minutes without resubmitting', (tester) async {
      tracker.dispose();
      tracker = BrowserTransactionTracker();
      final hash = ethereumTransactionHash(signed);
      var mined = false;
      rpc['eth_sendRawTransaction'] = (_) =>
          throw const EthereumDappRpcException(
            -32000,
            message: 'upstream timeout',
          );
      rpc['eth_getTransactionReceipt'] = (_) =>
          mined ? {'status': '0x1', 'blockNumber': '0x10'} : null;
      await expectLater(
        adapter().sendSigned(signed, prepared),
        throwsA(isA<DappException>()),
      );
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(seconds: 12));
      }
      expect(
        tracker.recordFor('eip155:1', hash)?.status,
        BrowserTransactionStatus.uncertain,
      );
      expect(
        calls.where((call) => call.$1 == 'eth_getTransactionReceipt'),
        hasLength(14),
      );
      mined = true;
      await tester.pump(const Duration(seconds: 12));
      expect(
        calls.where((call) => call.$1 == 'eth_getTransactionReceipt'),
        hasLength(15),
      );
      expect(
        calls
            .where((call) => call.$1 == 'eth_getTransactionReceipt')
            .map((call) => call.$2.single),
        everyElement(hash),
      );
      expect(
        tracker.recordFor('eip155:1', hash)?.status,
        BrowserTransactionStatus.confirmed,
      );
      expect(tracker.recordFor('eip155:1', hash)?.slot, 16);
      expect(broadcasts.single.hash, hash);
      expect(
        calls.where((call) => call.$1 == 'eth_sendRawTransaction'),
        hasLength(1),
      );
    });

    test('an unrecognised node error leaves the broadcast uncertain and '
        'still tracked', () async {
      rpc['eth_sendRawTransaction'] = (_) =>
          throw const EthereumDappRpcException(
            -32000,
            message: 'upstream timeout',
          );
      await expectLater(
        adapter().sendSigned(signed, prepared),
        throwsA(isA<DappException>()),
      );
      expect(
        tracker.recordFor('eip155:1', ethereumTransactionHash(signed))?.status,
        BrowserTransactionStatus.uncertain,
      );
      expect(broadcasts, hasLength(1));
    });

    test('"already known" is a broadcast that happened', () async {
      rpc['eth_sendRawTransaction'] = (_) =>
          throw const EthereumDappRpcException(
            -32000,
            message: 'already known',
          );
      expect(
        await adapter().sendSigned(signed, prepared),
        ethereumTransactionHash(signed),
      );
      expect(broadcasts, hasLength(1));
    });
  });

  group('read', () {
    test('keeps revert data and nothing else from a node error', () async {
      rpc['eth_call'] = (_) =>
          throw const EthereumDappRpcException(3, revertData: '0x08c379a0');
      await expectLater(
        adapter().read('eth_call', [<String, Object?>{}, 'latest']),
        throwsA(
          isA<DappException>()
              .having((e) => e.code, 'code', 3)
              .having((e) => e.data, 'data', '0x08c379a0'),
        ),
      );
    });

    test('never sends a method outside the read allowlist', () async {
      await expectLater(
        adapter().read('eth_sendRawTransaction', ['0x00']),
        throwsA(isA<DappException>().having((e) => e.code, 'code', 4200)),
      );
      expect(calls, isEmpty);
    });
  });

  test('receipt status maps onto the tracker\'s shape', () async {
    Future<Object?> lookup(Object? receipt) =>
        receiptStatus((_, _) async => receipt, '0x00');
    expect(await lookup(null), {
      'value': [null],
    });
    expect(await lookup({'status': '0x1', 'blockNumber': '0x10'}), {
      'value': [
        {'confirmationStatus': 'confirmed', 'err': null, 'slot': 16},
      ],
    });
    expect(
      ((await lookup({'status': '0x0', 'blockNumber': '0x10'}))!
          as Map)['value'],
      [
        {'confirmationStatus': 'confirmed', 'err': 'reverted', 'slot': 16},
      ],
    );
  });

  test('ERC-20 symbols decode from an ABI string or bytes32', () {
    final string =
        '0x${'20'.padLeft(64, '0')}${'4'.padLeft(64, '0')}${'55534443'.padRight(64, '0')}';
    expect(decodeAbiSymbol(string), 'USDC');
    expect(decodeAbiSymbol('0x${'4d4b52'.padRight(64, '0')}'), 'MKR');
    expect(decodeAbiSymbol('0x1234'), isNull);
  });

  group('calldata addresses', () {
    final paddedSpender = '${'1' * 24}${_bob.substring(2).toLowerCase()}';

    test('approve uses the low 160 bits of the spender', () {
      final decoded = decodeEvmCall(
        _usdc,
        hexToBytes('0x095ea7b3$paddedSpender${'1'.padLeft(64, '0')}'),
        _cow,
      );
      expect(decoded.accounts.single.beneficiary, _bob.toLowerCase());
    });

    test('collection approval uses the low 160 bits of the operator', () {
      final decoded = decodeEvmCall(
        _usdc,
        hexToBytes('0xa22cb465$paddedSpender${'1'.padLeft(64, '0')}'),
        _cow,
      );
      expect(decoded.accounts.single.beneficiary, _bob.toLowerCase());
    });

    test('Permit2 masks both token and spender addresses', () {
      final decoded = decodeEvmCall(
        permit2Address,
        hexToBytes(
          '0x87517c45${'1' * 24}${_usdc.substring(2)}'
          '$paddedSpender${'1'.padLeft(64, '0')}${'0' * 64}',
        ),
        _cow,
      );
      expect(decoded.accounts.single.assetId, _usdc);
      expect(decoded.accounts.single.beneficiary, _bob.toLowerCase());
    });

    test('approve to the zero address is still a revocation', () {
      final decoded = decodeEvmCall(
        _usdc,
        hexToBytes('0x095ea7b3${'0' * 64}${'1'.padLeft(64, '0')}'),
        _cow,
      );
      expect(decoded.accounts.single.kind, AccountChangeKind.revoke);
      expect(decoded.accounts.single.beneficiary, isNull);
    });
  });

  group('token reads', () {
    const token = '0x2222222222222222222222222222222222222222';
    final transfer =
        '0xa9059cbb${_bob.substring(2).toLowerCase().padLeft(64, '0')}'
        '${'1'.padLeft(64, '0')}';
    // ABI-encoded string "TKN".
    final symbol =
        '0x${'20'.padLeft(64, '0')}${'3'.padLeft(64, '0')}'
        '${'544b4e'.padRight(64, '0')}';

    EthereumDappTransactionRequest request(String to, String data) =>
        EthereumDappTransactionRequest.parse({
          'to': to,
          'data': data,
        }, account: _cow);

    List<String> reads() => [
      for (final (method, params) in calls)
        if (method == 'eth_call')
          ((params.first! as Map)['data'] as String).substring(0, 10),
    ];

    setUp(() {
      rpc['eth_call'] = (params) =>
          (params.first! as Map)['data'] == '0x313ce567'
          ? '0x${'12'.padLeft(64, '0')}'
          : symbol;
      simulate = (to, data, value) async => EvmSimulationResult(
        changes: [
          EvmAssetChange(
            assetType: 'ERC20',
            changeType: 'TRANSFER',
            from: _cow.toLowerCase(),
            to: _bob.toLowerCase(),
            contractAddress: token,
            rawAmount: '1',
          ),
        ],
      );
    });

    test('of a token\'s own call go out with the simulation', () async {
      final simulation = Completer<EvmSimulationResult>();
      simulate = (to, data, value) => simulation.future;
      final prepared = adapter().prepareTransaction(
        request: request(token, transfer),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
      await Future<void>.delayed(Duration.zero);
      expect(reads(), unorderedEquals(['0x313ce567', '0x95d89b41']));
      simulation.complete(
        EvmSimulationResult(
          changes: [
            EvmAssetChange(
              assetType: 'ERC20',
              changeType: 'TRANSFER',
              from: _cow.toLowerCase(),
              to: _bob.toLowerCase(),
              contractAddress: token,
              rawAmount: '1',
            ),
          ],
        ),
      );
      final review = (await prepared).review;
      expect(reads(), hasLength(2), reason: 'not read again after it');
      expect(
        review.funds.firstWhere((f) => f.asset.id == token).asset.decimals,
        18,
      );
      expect(review.tokenMetadata[token]?.symbol, 'TKN');
    });

    test('are not made for a call that does not name a token', () async {
      final simulation = Completer<EvmSimulationResult>();
      simulate = (to, data, value) => simulation.future;
      final prepared = adapter().prepareTransaction(
        request: request(_spender, '0x12345678'),
        walletId: 'w',
        address: _cow,
        origin: 'https://example.org',
      );
      await Future<void>.delayed(Duration.zero);
      expect(reads(), isEmpty);
      simulation.complete(const EvmSimulationResult(changes: []));
      await prepared;
    });

    test('are kept for the next review through the same node', () async {
      final ethereum = adapter();
      for (var i = 0; i < 2; i++) {
        await ethereum.prepareTransaction(
          request: request(token, transfer),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        );
      }
      expect(reads(), hasLength(2));
    });

    test('that found no decimals are made again', () async {
      rpc['eth_call'] = (params) =>
          (params.first! as Map)['data'] == '0x313ce567'
          ? throw StateError('reverted')
          : symbol;
      final ethereum = adapter();
      for (var i = 0; i < 2; i++) {
        final review = (await ethereum.prepareTransaction(
          request: request(token, transfer),
          walletId: 'w',
          address: _cow,
          origin: 'https://example.org',
        )).review;
        expect(
          review.warnings,
          contains(
            'Token precision could not be verified. Raw amounts are shown.',
          ),
        );
      }
      expect(reads().where((r) => r == '0x313ce567'), hasLength(2));
    });
  });
}
