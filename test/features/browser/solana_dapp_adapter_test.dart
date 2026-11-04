import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:solana/encoder.dart';
import 'package:solana/base58.dart';
import 'package:solana/solana.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/simulation_review.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_adapter.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_transaction.dart';
import 'package:mallow_wallet/features/browser/services/solana_lookup_table_cache.dart';
import 'package:mallow_wallet/features/browser/services/browser_signing_service.dart';
import 'package:mallow_wallet/features/browser/services/browser_transaction_tracker.dart';

import '../../support/solana_v1_fixture.dart';

class _Wallet extends Mock implements WalletManager {}

final _signer = Ed25519HDPublicKey(List.filled(32, 1));
final _other = Ed25519HDPublicKey(List.filled(32, 2));
final _system = Ed25519HDPublicKey.fromBase58(solanaSystemProgram);
SignedTx _tx({bool v0 = false, bool coSigner = false}) {
  final keys = [_signer, _other, _system];
  final data = Uint8List(12);
  ByteData.sublistView(data)
    ..setUint32(0, 2, Endian.little)
    ..setUint64(4, 1000000000, Endian.little);
  return SignedTx.fromBytes([
    coSigner ? 2 : 1,
    ...List.filled(64, 0),
    if (coSigner) ...List.filled(64, 7),
    if (v0) 128,
    coSigner ? 2 : 1,
    0,
    1,
    keys.length,
    for (final key in keys) ...key.bytes,
    ..._other.bytes,
    1,
    2,
    2,
    0,
    1,
    data.length,
    ...data,
    if (v0) 0,
  ]);
}

Uint8List _wire(SignedTx tx) => Uint8List.fromList(tx.toByteArray().toList());
Map<String, Object?> _account(int lamports) => {
  'lamports': lamports,
  'owner': solanaSystemProgram,
  'data': ['', 'base64'],
};

/// A transaction whose nested calls delegate and freeze a token account
/// for the asset [_other], reviewed with [assets] as the DAS batch reply.
Future<SimulationReview> _nestedDelegateReview(
  List<Map<String, Object?>> assets,
) async {
  final tx = _tx();
  final message = tx.compiledMessage;
  final tokenProgram = Ed25519HDPublicKey.fromBase58(solanaTokenProgram);
  final keys = [...message.accountKeys, tokenProgram];
  final expanded = tx.copyWith(
    compiledMessage: message.copyWith(accountKeys: keys),
  );
  Map<String, Object?> token({required bool frozen}) {
    final bytes = Uint8List(165);
    bytes.setRange(0, 32, _other.bytes);
    bytes.setRange(32, 64, _signer.bytes);
    bytes[64] = 1;
    bytes[108] = frozen ? 2 : 1;
    if (frozen) {
      bytes[72] = 1;
      bytes.setRange(76, 108, _other.bytes);
      bytes[121] = 1;
    }
    return {
      'owner': solanaTokenProgram,
      'lamports': 1,
      'data': [base64Encode(bytes), 'base64'],
    };
  }

  final adapter = SolanaDappAdapter(
    walletManager: _Wallet(),
    rpc: (chain, method, params) async {
      if (method == 'getMultipleAccounts')
        return {
          'context': {'slot': 10},
          'value': [
            _account(2),
            token(frozen: false),
            _account(1),
            _account(1),
          ],
        };
      if (method == 'getFeeForMessage') return {'value': 5000};
      if (method == 'getAssetBatch') {
        expect(params.first, contains(_other.toBase58()));
        return assets;
      }
      return {
        'context': {'slot': 10},
        'value': {
          'err': null,
          'accounts': [
            _account(1),
            token(frozen: true),
            _account(1),
            _account(1),
          ],
          'logs': [
            'Program Outer invoke [1]',
            'Program log: Instruction: Lock',
            'Program $solanaTokenProgram invoke [2]',
            'Program log: Instruction: FreezeAccount',
            'Program $solanaTokenProgram success',
            'Program Outer success',
          ],
          'innerInstructions': [
            {
              'index': 0,
              'instructions': [
                {
                  'programIdIndex': 3,
                  'accounts': [1, 1, 0],
                  'data': base58encode([4, 1, 0, 0, 0, 0, 0, 0, 0]),
                },
                {
                  'programIdIndex': 3,
                  'accounts': [1, 1, 0],
                  'data': base58encode([10]),
                },
              ],
            },
          ],
        },
      };
    },
  );
  final result = await adapter.prepareTransaction(
    transaction: _wire(expanded),
    walletId: 'wallet',
    address: _signer.toBase58(),
    origin: 'https://site.example',
    chain: 'solana:mainnet',
  );
  return result.review;
}

void main() {
  tearDown(() async {
    Config.debugOverrides.clear();
    BrowserTransactionTracker.instance.clear();
    await SolanaLookupTableCache.instance.clear();
  });
  for (final v0 in [false, true]) {
    test(
      'canonical ${v0 ? 'v0' : 'legacy'} bytes and co-signatures survive parsing',
      () {
        final tx = _tx(v0: v0, coSigner: true);
        final parsed = parseDappTransaction(
          _wire(tx),
          signer: _signer.toBase58(),
        );
        expect(_wire(parsed), _wire(tx));
        expect(parsed.signatures[1].bytes, List.filled(64, 7));
      },
    );
  }
  test(
    'v0 lookup resolution preserves wire bytes and existing co-signatures',
    () async {
      final base = _tx(v0: true, coSigner: true);
      final message = base.compiledMessage as CompiledMessageV0;
      final table = Ed25519HDPublicKey(List.filled(32, 4));
      final loaded = Ed25519HDPublicKey(List.filled(32, 5));
      final tx = base.copyWith(
        compiledMessage: message.copyWith(
          addressTableLookups: [
            MessageAddressTableLookup(
              accountKey: table,
              writableIndexes: [0],
              readonlyIndexes: [],
            ),
          ],
          instructions: [
            message.instructions.single.copyWith(accountKeyIndexes: [0, 3]),
          ],
        ),
      );
      final bytes = _wire(tx);
      final adapter = SolanaDappAdapter(
        walletManager: _Wallet(),
        rpc: (_, method, params) async {
          if (method == 'getMultipleAccounts') {
            final addresses = params.first as List;
            if (addresses.length == 1 && addresses.first == table.toBase58())
              return {
                'value': [
                  {
                    'owner': 'AddressLookupTab1e1111111111111111111111111',
                    'data': [
                      base64Encode([...List.filled(56, 0), ...loaded.bytes]),
                      'base64',
                    ],
                  },
                ],
              };
            expect(addresses, contains(loaded.toBase58()));
            return {
              'context': {'slot': 10},
              'value': [for (final _ in addresses) _account(2000000000)],
            };
          }
          if (method == 'getFeeForMessage') return {'value': 5000};
          return {
            'context': {'slot': 10},
            'value': {
              'err': null,
              'accounts': [
                _account(999995000),
                _account(2000000000),
                _account(2000000000),
                _account(3000000000),
              ],
            },
          };
        },
      );
      final result = await adapter.prepareTransaction(
        transaction: bytes,
        walletId: 'wallet',
        address: _signer.toBase58(),
        origin: 'https://site.example',
        chain: 'solana:mainnet',
      );
      expect(result.bytes, bytes);
      expect(
        parseDappTransaction(result.bytes).signatures[1].bytes,
        List.filled(64, 7),
      );
      expect(result.review.funds.first.to, loaded.toBase58());
    },
  );
  test('missing simulation context cannot claim complete coverage', () async {
    final adapter = SolanaDappAdapter(
      walletManager: _Wallet(),
      rpc: (_, method, _) async {
        if (method == 'getMultipleAccounts')
          return {
            'value': [_account(2), _account(1), _account(1)],
          };
        if (method == 'getFeeForMessage') return {'value': 5000};
        return {
          'value': {
            'err': null,
            'accounts': [_account(1), _account(2), _account(1)],
          },
        };
      },
    );
    final result = await adapter.prepareTransaction(
      transaction: _wire(_tx()),
      walletId: 'wallet',
      address: _signer.toBase58(),
      origin: 'https://site.example',
      chain: 'solana:mainnet',
    );
    expect(result.review.coverage, SimulationCoverage.partial);
    expect(estimateBrowserOutgoingUsd(result.review, (_) => 100), isNull);
  });
  test('a CPI allowance increase for the same delegate is visible', () async {
    Map<String, Object?> token(BigInt allowance) {
      final bytes = Uint8List(165);
      bytes.setRange(0, 32, _other.bytes);
      bytes.setRange(32, 64, _signer.bytes);
      bytes[72] = 1;
      bytes.setRange(76, 108, _other.bytes);
      bytes[108] = 1;
      for (var i = 0; i < 8; i++) {
        bytes[121 + i] = ((allowance >> (i * 8)) & BigInt.from(255)).toInt();
      }
      return {
        'owner': solanaTokenProgram,
        'lamports': 1,
        'data': [base64Encode(bytes), 'base64'],
      };
    }

    final adapter = SolanaDappAdapter(
      walletManager: _Wallet(),
      rpc: (_, method, _) async {
        if (method == 'getMultipleAccounts')
          return {
            'context': {'slot': 10},
            'value': [_account(2), token(BigInt.one), _account(1)],
          };
        if (method == 'getFeeForMessage') return {'value': 5000};
        return {
          'context': {'slot': 10},
          'value': {
            'err': null,
            'accounts': [
              _account(1),
              token(BigInt.parse('18446744073709551615')),
              _account(1),
            ],
          },
        };
      },
    );
    final result = await adapter.prepareTransaction(
      transaction: _wire(_tx()),
      walletId: 'wallet',
      address: _signer.toBase58(),
      origin: 'https://site.example',
      chain: 'solana:mainnet',
    );
    expect(
      result.review.accounts.single.rawAllowance,
      BigInt.parse('18446744073709551615'),
    );
    expect(result.review.accounts.single.beneficiary, _other.toBase58());
    // The pre-transaction balance travels with it, so the review can tell a
    // whole-balance delegation from a partial one.
    expect(result.review.accounts.single.balance, BigInt.zero);
  });
  test('a Core update-authority change carries the bare address', () {
    Map<String, Object?> asset(int tag, [Ed25519HDPublicKey? authority]) => {
      'owner': solanaCoreProgram,
      'lamports': 1,
      'data': [
        base64Encode([
          1,
          ..._signer.bytes,
          tag,
          ...?authority?.bytes,
          ...List.filled(9, 0),
        ]),
        'base64',
      ],
    };
    final toCollection = decodeCoreAssetDelta(
      'asset',
      asset(1, _signer),
      asset(2, _other),
      _signer.toBase58(),
    ).single;
    expect(toCollection.kind, NftChangeKind.authority);
    expect(toCollection.description, 'Update authority moves to a collection');
    expect(toCollection.from, _signer.toBase58());
    expect(toCollection.to, _other.toBase58());

    final removed = decodeCoreAssetDelta(
      'asset',
      asset(1, _other),
      asset(0),
      _signer.toBase58(),
    ).single;
    expect(removed.description, 'Update authority removed');
    expect(removed.from, _other.toBase58());
    expect(removed.to, isNull);

    // The same key, now held as a collection rather than an address.
    expect(
      decodeCoreAssetDelta(
        'asset',
        asset(1, _other),
        asset(2, _other),
        _signer.toBase58(),
      ).single.description,
      'Update authority moves to a collection',
    );
  });

  test(
    'closing a token account opened in the same transaction is not shown',
    () {
      final keys = [_signer.toBase58(), _other.toBase58(), solanaTokenProgram];
      final close = CompiledInstruction(
        programIdIndex: 2,
        accountKeyIndexes: [1, 0, 0],
        data: ByteArray([9]),
      );
      List<AccountChange> closes(Map<String, Map<String, Object?>> before) {
        final accounts = <AccountChange>[];
        decodeSolanaInstructions(
          _tx(),
          keys,
          before,
          [],
          accounts,
          [],
          _signer.toBase58(),
          instructions: [close],
        );
        return accounts;
      }

      // Read as missing before the transaction: it opens the account itself.
      expect(closes({_other.toBase58(): {}}), isEmpty);
      expect(closes({_other.toBase58(): _account(0)}), isEmpty);
      // An existing account, or one the read did not cover, is still shown.
      expect(
        closes({_other.toBase58(): _account(2039280)}).single.kind,
        AccountChangeKind.close,
      );
      expect(closes({}).single.beneficiary, _signer.toBase58());
    },
  );
  test('Core owner, mint and closure changes validate program and layout', () {
    Map<String, Object?> asset(Ed25519HDPublicKey owner) => {
      'owner': solanaCoreProgram,
      'lamports': 1,
      'data': [
        base64Encode([1, ...owner.bytes, 0, ...List.filled(9, 0)]),
        'base64',
      ],
    };
    final before = asset(_signer), after = asset(_other);
    expect(
      decodeCoreAssetDelta(
        'asset',
        before,
        after,
        _signer.toBase58(),
      ).single.kind,
      NftChangeKind.transfer,
    );
    expect(
      decodeCoreAssetDelta('asset', {}, before, _signer.toBase58()).single.kind,
      NftChangeKind.mint,
    );
    expect(
      decodeCoreAssetDelta('asset', before, {}, _signer.toBase58()).single.kind,
      NftChangeKind.burn,
    );
    expect(
      decodeCoreAssetDelta(
        'asset',
        {...before, 'owner': solanaSystemProgram},
        after,
        _signer.toBase58(),
      ),
      isEmpty,
    );
    expect(
      decodeCoreAssetDelta(
        'asset',
        {
          'owner': solanaCoreProgram,
          'data': [
            base64Encode([1, ..._signer.bytes]),
            'base64',
          ],
        },
        after,
        _signer.toBase58(),
      ),
      isEmpty,
    );
  });
  test(
    'trailing bytes, wrong signer and signature/header mismatch are rejected',
    () {
      expect(
        () => parseDappTransaction(Uint8List.fromList([..._wire(_tx()), 0])),
        throwsA(isA<DappException>()),
      );
      expect(
        () => parseDappTransaction(_wire(_tx()), signer: _other.toBase58()),
        throwsA(isA<DappException>()),
      );
      final invalid = SignedTx(
        compiledMessage: _tx().compiledMessage,
        signatures: [],
      );
      expect(
        () => parseDappTransaction(_wire(invalid)),
        throwsA(isA<DappException>()),
      );
    },
  );
  test(
    'transaction envelopes and spendable compiled messages are refused as messages',
    () {
      final adapter = SolanaDappAdapter(walletManager: _Wallet());
      for (final bytes in [
        _wire(_tx()),
        Uint8List.fromList(_tx().compiledMessage.toByteArray().toList()),
      ]) {
        expect(
          () => adapter.prepareMessage(
            bytes: bytes,
            origin: 'https://site.example',
            address: _signer.toBase58(),
            walletId: 'wallet',
            chain: 'solana:mainnet',
          ),
          throwsA(isA<DappException>()),
        );
      }
      final review = adapter.prepareMessage(
        bytes: Uint8List.fromList([255, 0, 254]),
        origin: 'https://site.example',
        address: _signer.toBase58(),
        walletId: 'wallet',
        chain: 'solana:mainnet',
      );
      expect(review.display, 'ff00fe');
      expect(review.text, isNull);
    },
  );
  test('v1 transactions and messages are refused as messages', () {
    final adapter = SolanaDappAdapter(walletManager: _Wallet());
    SolanaMessageReview prepare(List<int> bytes) => adapter.prepareMessage(
      bytes: Uint8List.fromList(bytes),
      origin: 'https://site.example',
      address: _signer.toBase58(),
      walletId: 'wallet',
      chain: 'solana:mainnet',
    );
    // A v1 message may run past the 1,232-byte legacy and v0 limit.
    final longMessage = [...hexBytes(v1Message), ...List.filled(2000, 0)];
    expect(longMessage.length, greaterThan(1232));
    for (final bytes in [
      hexBytes(v1Message),
      hexBytes(v1Unsigned),
      hexBytes(v1Signed),
      longMessage,
      // Any versioned prefix (v0 to v63) that no parser here understands.
      [0x80, ...List.filled(40, 1)],
      [0x82, ...List.filled(200, 1)],
      [0xbf, 0x41],
    ]) {
      expect(
        isSolanaSigningPayload(Uint8List.fromList(bytes)),
        isTrue,
        reason: bytes.take(4).toString(),
      );
      expect(() => prepare(bytes), throwsA(isA<DappException>()));
    }
    // Text that starts with a non-ASCII character, and the off-chain message
    // signing domain, are still messages.
    expect(
      prepare(utf8.encode('\u00e9t\u00e9 sign-in')).text,
      '\u00e9t\u00e9 sign-in',
    );
    expect(prepare(utf8.encode('\u{1f600} hello')).text, isNotNull);
    expect(
      isSolanaSigningPayload(
        Uint8List.fromList([0xff, ...utf8.encode('solana offchain'), 0, 0]),
      ),
      isFalse,
    );
  });
  test(
    'recognized SIWS renders fields without hiding the exact original message',
    () {
      final text =
          'site.example wants you to sign in with your Solana account:\n${_signer.toBase58()}\n\nHello\n\nURI: https://site.example\nVersion: 1\nChain ID: mainnet\nNonce: abc12345';
      final review = SolanaMessageReview(
        bytes: Uint8List.fromList(utf8.encode(text)),
        origin: 'https://site.example',
        address: _signer.toBase58(),
        walletId: 'wallet',
        chain: 'solana:mainnet',
      );
      expect(review.signInFields['Nonce'], 'abc12345');
      expect(review.signInFields['Domain'], 'site.example');
      expect(review.signInStatement, 'Hello');
      expect(review.display, text);
    },
  );
  test('SIWS is recognized only when the whole message fits the grammar', () {
    SolanaMessageReview review(String body) => SolanaMessageReview(
      bytes: Uint8List.fromList(
        utf8.encode(
          'site.example wants you to sign in with your Solana account:\n${_signer.toBase58()}$body',
        ),
      ),
      origin: 'https://site.example',
      address: _signer.toBase58(),
      walletId: 'wallet',
      chain: 'solana:mainnet',
    );
    // Well-formed: bare, statement only, fields only, statement + fields.
    for (final body in [
      '',
      '\n\nHello',
      '\n\nURI: https://site.example\nNonce: abc12345',
      '\n\nHello\n\nURI: https://site.example\nNonce: abc12345',
    ]) {
      expect(review(body).signInFields, isNotEmpty, reason: body);
    }
    // Anything else falls back to the raw message view.
    for (final body in [
      // Trailing arbitrary lines hidden after a friendly statement.
      '\n\nSign in\nTransfer all USDC to Hk3P\n\nNonce: abc12345',
      '\n\nHello\n\nNonce: abc12345\nI authorize an order to sell 100 SOL',
      '\n\nNonce: abc12345\n\nextra',
      '\n\nNonce: abc12345\nNonce: other',
      '\n\nHello\n',
      '\nHello',
      '\n\n\nHello',
    ]) {
      final parsed = review(body);
      expect(parsed.signInFields, isEmpty, reason: body);
      expect(parsed.signInStatement, isNull, reason: body);
    }
  });
  test(
    'mainnet RPC stays mainnet in staging and unsupported networks are refused',
    () {
      Config.debugOverrides['ENV'] = 'staging';
      expect(
        SolanaDappAdapter.rpcUrl('solana:mainnet'),
        Config.solanaMainnetRpcUrl,
      );
      expect(SolanaDappAdapter.rpcUrl('solana:devnet'), contains('devnet'));
      Config.debugOverrides['ENV'] = 'production';
      expect(
        () => SolanaDappAdapter.rpcUrl('solana:devnet'),
        throwsA(isA<DappException>()),
      );
      expect(
        () => SolanaDappAdapter.rpcUrl('solana:testnet'),
        throwsA(isA<DappException>()),
      );
    },
  );
  test(
    'simulation uses exact original bytes on requested cluster and typed deltas',
    () async {
      final calls = <String>[];
      final wire = _wire(_tx());
      final adapter = SolanaDappAdapter(
        walletManager: _Wallet(),
        rpc: (chain, method, params) async {
          expect(chain, 'solana:mainnet');
          calls.add(method);
          switch (method) {
            case 'getMultipleAccounts':
              return {
                'context': {'slot': 100},
                'value': [_account(2000000000), _account(0), _account(1)],
              };
            case 'simulateTransaction':
              expect(params[0], base64Encode(wire));
              expect((params[1] as Map)['replaceRecentBlockhash'], false);
              expect(params[1] as Map, isNot(contains('minContextSlot')));
              return {
                'context': {'slot': 100},
                'value': {
                  'err': null,
                  'accounts': [
                    _account(999995000),
                    _account(1000000000),
                    _account(1),
                  ],
                },
              };
            case 'getFeeForMessage':
              return {'value': 5000};
          }
          throw StateError(method);
        },
      );
      final prepared = await adapter.prepareTransaction(
        transaction: wire,
        walletId: 'wallet',
        address: _signer.toBase58(),
        origin: 'https://site.example',
        chain: 'solana:mainnet',
      );
      expect(prepared.bytes, wire);
      expect(prepared.review.execution, SimulationExecution.succeeded);
      expect(prepared.review.coverage, SimulationCoverage.complete);
      expect(
        prepared.review.funds.singleWhere((f) => f.isNet).rawAmount,
        BigInt.from(-1000005000),
      );
      expect(prepared.review.feeLamports, 5000);
      // The simulation goes out with the read, not after it; a node that
      // leaves the fee out of the simulation is asked for it.
      expect(calls, [
        'simulateTransaction',
        'getMultipleAccounts',
        'getFeeForMessage',
      ]);
      expect(() => prepared.bytes[0] = 2, throwsUnsupportedError);
    },
  );
  test(
    'failed simulation is a warning with no fabricated delta or fee',
    () async {
      final adapter = SolanaDappAdapter(
        walletManager: _Wallet(),
        rpc: (_, method, __) async => method == 'getMultipleAccounts'
            ? {
                'context': {'slot': 10},
                'value': [_account(2), _account(0), _account(1)],
              }
            : {
                'context': {'slot': 11},
                'value': {
                  'err': {
                    'InstructionError': [0, 'Custom'],
                  },
                  'accounts': [_account(0)],
                },
              },
      );
      final prepared = await adapter.prepareTransaction(
        transaction: _wire(_tx()),
        walletId: 'wallet',
        address: _signer.toBase58(),
        origin: 'https://site.example',
        chain: 'solana:mainnet',
      );
      expect(prepared.review.execution, SimulationExecution.failed);
      expect(prepared.review.error, contains('InstructionError'));
      expect(prepared.review.feeLamports, isNull);
      expect(prepared.review.funds.where((f) => f.isNet), isEmpty);
    },
  );
  test(
    'unavailable simulation stays reviewable with an explicit warning',
    () async {
      final adapter = SolanaDappAdapter(
        walletManager: _Wallet(),
        rpc: (_, __, ___) async => throw const FormatException(),
      );
      final prepared = await adapter.prepareTransaction(
        transaction: _wire(_tx()),
        walletId: 'wallet',
        address: _signer.toBase58(),
        origin: 'https://site.example',
        chain: 'solana:mainnet',
      );
      expect(prepared.review.execution, SimulationExecution.unavailable);
      expect(prepared.review.coverage, SimulationCoverage.partial);
      expect(prepared.review.error, contains('unavailable'));
    },
  );
  test(
    'send options retain typed dapp preflight, context and retry policy',
    () async {
      final tx = _tx();
      final signed = SignedTx(
        compiledMessage: tx.compiledMessage,
        signatures: [Signature(List.filled(64, 1), publicKey: _signer)],
      );
      final adapter = SolanaDappAdapter(
        walletManager: _Wallet(),
        rpc: (_, method, params) async {
          expect(method, 'sendTransaction');
          expect(params[1], {
            'encoding': 'base64',
            'skipPreflight': true,
            'preflightCommitment': 'finalized',
            'minContextSlot': 123,
            'maxRetries': 0,
          });
          return signed.id;
        },
      );
      final signature = await adapter.sendSigned(
        _wire(signed),
        'solana:mainnet',
        options: {
          'skipPreflight': true,
          'preflightCommitment': 'finalized',
          'minContextSlot': 123,
          'maxRetries': 0,
        },
      );
      expect(signature, signed.id);
      expect(
        SolanaDappSendOptions.fromMap({
          'commitment': 'processed',
        }).preflightCommitment,
        'processed',
      );
    },
  );
  test('invalid send option types and nonzero retries are rejected', () {
    for (final options in <Map<String, Object?>>[
      {'skipPreflight': 'true'},
      {'preflightCommitment': 1},
      {'commitment': 'rooted'},
      {'minContextSlot': -1},
      {'minContextSlot': 1.5},
      {'minContextSlot': null},
      {'maxRetries': 1},
      {'maxRetries': false},
    ]) {
      expect(
        () => SolanaDappSendOptions.fromMap(options),
        throwsA(isA<DappException>()),
      );
    }
  });
  test(
    'known preflight rejection is failed while transport status stays uncertain',
    () async {
      final tx = _tx();
      final signed = SignedTx(
        compiledMessage: tx.compiledMessage,
        signatures: [Signature(List.filled(64, 1), publicKey: _signer)],
      );
      final tracker = BrowserTransactionTracker();
      addTearDown(tracker.dispose);
      var calls = 0;
      final adapter = SolanaDappAdapter(
        walletManager: _Wallet(),
        tracker: tracker,
        rpc: (_, _, _) async {
          calls++;
          throw const SolanaDappRpcException(-32002);
        },
      );
      await expectLater(
        adapter.sendSigned(_wire(signed), 'solana:mainnet'),
        throwsA(
          isA<DappException>().having(
            (e) => e.message,
            'message',
            contains('before broadcast'),
          ),
        ),
      );
      expect(calls, 1);
      expect(tracker.records.single.status, BrowserTransactionStatus.failed);
    },
  );
  test(
    'broadcast is once-only and does not silently retry an uncertain result',
    () async {
      var calls = 0;
      final tx = _tx();
      final signed = SignedTx(
        compiledMessage: tx.compiledMessage,
        signatures: [Signature(List.filled(64, 1), publicKey: _signer)],
      );
      final adapter = SolanaDappAdapter(
        walletManager: _Wallet(),
        rpc: (_, method, params) async {
          calls++;
          expect(method, 'sendTransaction');
          expect((params[1] as Map)['maxRetries'], 0);
          throw const FormatException();
        },
      );
      await expectLater(
        adapter.sendSigned(_wire(signed), 'solana:mainnet'),
        throwsA(
          isA<DappException>().having(
            (e) => e.message,
            'message',
            contains(signed.id),
          ),
        ),
      );
      expect(calls, 1);
    },
  );
  test('a detached signature from another hardware key is rejected', () async {
    final selected = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: List.filled(32, 3),
    );
    final other = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: List.filled(32, 4),
    );
    final bytes = [1, 2, 3];
    final wrong = await other.sign(bytes);
    await expectLater(
      verifyDappSignature(bytes, wrong.bytes, selected.address),
      throwsA(isA<DappException>()),
    );
    final correct = await selected.sign(bytes);
    await verifyDappSignature(bytes, correct.bytes, selected.address);
    await expectLater(
      verifyDappSignature([1, 2, 4], correct.bytes, selected.address),
      throwsA(isA<DappException>()),
    );
  });
  test('outgoing USD uses gross outgoing and fee despite incoming netting', () {
    const asset = ReviewAsset(id: solanaNativeMint, symbol: 'SOL', decimals: 9);
    final review = SimulationReview(
      payloadDigest: 'digest',
      origin: 'https://site.example',
      walletId: 'wallet',
      address: 'addr',
      chain: 'solana:mainnet',
      simulatedAt: DateTime.now(),
      execution: SimulationExecution.succeeded,
      coverage: SimulationCoverage.complete,
      feeLamports: 5000,
      feePayer: 'addr',
      funds: [
        FundChange(
          asset: asset,
          address: 'addr',
          rawAmount: BigInt.from(-10000000000),
          evidence: ReviewEvidence.requestedInstruction,
        ),
        FundChange(
          asset: asset,
          address: 'addr',
          rawAmount: BigInt.from(-100000000),
          evidence: ReviewEvidence.simulatedState,
          isNet: true,
        ),
      ],
    );
    expect(
      estimateBrowserOutgoingUsd(review, (_) => 100),
      closeTo(1000.0005, 0.000001),
    );
    expect(estimateBrowserOutgoingUsd(review, (_) => double.infinity), isNull);
    expect(estimateBrowserOutgoingUsd(review, (_) => null), isNull);
  });
  test('log instructions retain nested and repeated program attribution', () {
    final calls = parseSimulationProgramCalls([
      'Program log: Instruction: Unattributed',
      'Program Outer invoke [1]',
      'Program log: Instruction: Lock',
      'Program Token invoke [2]',
      'Program log: Instruction: Approve',
      'Program Token success',
      'Program Token invoke [2]',
      'Program log: Instruction: FreezeAccount',
      'Program Token failed: custom error',
      'Program log: Instruction: Cleanup',
      'Program Outer success',
      'Program log: Instruction: Ignore',
    ]);
    expect(calls.map((c) => (c.program, c.instruction)).toList(), [
      ('Outer', 'Lock'),
      ('Token', 'Approve'),
      ('Token', 'FreezeAccount'),
      ('Outer', 'Cleanup'),
    ]);
  });

  for (final chain in ['solana:mainnet', 'solana:devnet']) {
    test('Explorer inspector preserves original message and $chain', () async {
      Config.debugOverrides['ENV'] = 'staging';
      final tx = _tx();
      final adapter = SolanaDappAdapter(
        walletManager: _Wallet(),
        rpc: (_, _, _) async => throw StateError('unavailable'),
      );
      final prepared = await adapter.prepareTransaction(
        transaction: _wire(tx),
        walletId: 'wallet',
        address: _signer.toBase58(),
        origin: 'https://site.example',
        chain: chain,
      );
      final url = prepared.review.explorerUrl!;
      expect(url.path, '/tx/inspector');
      expect(
        url.queryParameters['cluster'],
        chain == 'solana:devnet' ? 'devnet' : null,
      );
      expect(
        base64Decode(url.queryParameters['message']!),
        tx.compiledMessage.toByteArray().toList(),
      );
    });
  }
  test(
    'nested delegate and freeze effects resolve NFT identity and metadata',
    () async {
      final review = await _nestedDelegateReview([
        {
          'id': _other.toBase58(),
          'interface': 'V1_NFT',
          'content': {
            'metadata': {'name': 'Moon Garden'},
            'links': {'image': 'https://example.com/nft.png'},
          },
        },
      ]);
      final actions = review.accounts
          .where(
            (a) =>
                a.kind == AccountChangeKind.approve ||
                a.kind == AccountChangeKind.freeze,
          )
          .toList();
      expect(actions, hasLength(4));
      expect(actions.every((a) => a.assetId == _other.toBase58()), isTrue);
      expect(
        actions.where((a) => a.evidence == ReviewEvidence.simulatedState),
        hasLength(2),
      );
      expect(review.nftMetadata[_other.toBase58()]?.name, 'Moon Garden');
      expect(
        review.nftMetadata[_other.toBase58()]?.imageUrl,
        'https://example.com/nft.png',
      );
      expect(review.programCalls.last.instruction, 'FreezeAccount');
      expect(review.programCalls.last.program, solanaTokenProgram);
    },
  );

  for (final interface in ['MplBubblegumV2', 'Custom']) {
    test('DAS $interface assets retain NFT review metadata', () async {
      final review = await _nestedDelegateReview([
        {
          'id': _other.toBase58(),
          'interface': interface,
          'content': {
            'metadata': {'name': 'Moon Garden'},
            'links': {'image': 'https://example.com/nft.png'},
          },
        },
      ]);
      expect(review.nftMetadata[_other.toBase58()]?.name, 'Moon Garden');
      expect(
        review.nftMetadata[_other.toBase58()]?.imageUrl,
        'https://example.com/nft.png',
      );
      expect(review.tokenMetadata, isEmpty);
    });
  }

  test('unverified fungible tokens carry their own symbol and image', () async {
    final review = await _nestedDelegateReview([
      {
        'id': _other.toBase58(),
        'interface': 'FungibleToken',
        'content': {
          'metadata': {'symbol': 'MOON'},
          'links': {'image': 'https://example.com/moon.png'},
        },
      },
    ]);
    final metadata = review.tokenMetadata[_other.toBase58()];
    expect(metadata?.symbol, 'MOON');
    expect(metadata?.imageUrl, 'https://example.com/moon.png');
    expect(review.nftMetadata, isEmpty);
  });

  test('a token claiming a known symbol shows none of its metadata', () async {
    final review = await _nestedDelegateReview([
      {
        'id': _other.toBase58(),
        'interface': 'FungibleToken',
        'content': {
          'metadata': {'symbol': 'usdc'},
          'links': {'image': 'https://example.com/usdc.png'},
        },
      },
    ]);
    expect(review.tokenMetadata, isEmpty);
  });
  test(
    'message signing hands the request cancellation to the signer',
    () async {
      // A Keystone message signature is a QR exchange; when the website's
      // request is abandoned its sheet must close rather than block the queue.
      registerFallbackValue(<int>[]);
      final key = await Ed25519HDKeyPair.fromPrivateKeyBytes(
        privateKey: List<int>.filled(32, 5),
      );
      final bytes = Uint8List.fromList(utf8.encode('Sign in to example'));
      final wallet = _Wallet();
      final cancelled = Completer<void>().future;
      when(
        () => wallet.signMessageForWallet(
          'wallet',
          any(),
          expectedAddress: key.address,
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      ).thenAnswer((_) => key.sign(bytes));
      final adapter = SolanaDappAdapter(walletManager: wallet);

      await adapter.signMessage(
        SolanaMessageReview(
          bytes: bytes,
          origin: 'https://site.example',
          address: key.address,
          walletId: 'wallet',
          chain: 'solana:mainnet',
        ),
        ensureActive: () {},
        cancelled: cancelled,
      );

      final call = verify(
        () => wallet.signMessageForWallet(
          'wallet',
          any(),
          expectedAddress: key.address,
          ensureActive: any(named: 'ensureActive'),
          cancelled: captureAny(named: 'cancelled'),
        ),
      );
      expect(call.captured.single, same(cancelled));
    },
  );
  test(
    'the simulation goes out without waiting for the account read',
    () async {
      final read = Completer<Object?>();
      final calls = <String>[];
      final adapter = SolanaDappAdapter(
        walletManager: _Wallet(),
        rpc: (_, method, params) {
          calls.add(method);
          if (method == 'getMultipleAccounts') return read.future;
          if (method == 'simulateTransaction') {
            return Future.value({
              'context': {'slot': 10},
              'value': {
                'err': null,
                'fee': 5000,
                'accounts': [_account(1), _account(2), _account(1)],
              },
            });
          }
          throw StateError(method);
        },
      );
      final prepared = adapter.prepareTransaction(
        transaction: _wire(_tx()),
        walletId: 'wallet',
        address: _signer.toBase58(),
        origin: 'https://site.example',
        chain: 'solana:mainnet',
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['simulateTransaction', 'getMultipleAccounts']);

      read.complete({
        'context': {'slot': 10},
        'value': [_account(2), _account(1), _account(1)],
      });
      final review = (await prepared).review;
      expect(review.execution, SimulationExecution.succeeded);
      expect(review.feeLamports, 5000);
    },
  );
  test(
    'a simulation that fails before the read answers is held for it',
    () async {
      final read = Completer<Object?>();
      final adapter = SolanaDappAdapter(
        walletManager: _Wallet(),
        rpc: (_, method, _) => method == 'getMultipleAccounts'
            ? read.future
            : Future.error(const SolanaDappRpcException(-32000)),
      );
      final prepared = adapter.prepareTransaction(
        transaction: _wire(_tx()),
        walletId: 'wallet',
        address: _signer.toBase58(),
        origin: 'https://site.example',
        chain: 'solana:mainnet',
      );
      await Future<void>.delayed(Duration.zero);
      read.complete({
        'context': {'slot': 10},
        'value': [_account(2), _account(1), _account(1)],
      });
      final review = (await prepared).review;
      expect(review.execution, SimulationExecution.unavailable);
      expect(review.error, contains('unavailable'));
      // The requested transfer is still shown, from the request itself.
      expect(
        review.funds.where(
          (f) => f.evidence == ReviewEvidence.requestedInstruction,
        ),
        isNotEmpty,
      );
    },
  );
  group('token precision', () {
    final mint = Ed25519HDPublicKey(List.filled(32, 9)).toBase58();

    /// A review of a transaction that takes [spent] base units of [mint]
    /// from the signer's token account, with [simulation] merged into the
    /// simulation's value and [assets] as the DAS reply.
    Future<(SimulationReview, List<List<Object?>>)> review({
      required BigInt spent,
      Map<String, Object?> simulation = const {},
      List<Map<String, Object?>> assets = const [],
      int mintDecimals = 6,
      int mintSupply = 1000000,
    }) async {
      Map<String, Object?> token(BigInt amount) {
        final bytes = Uint8List(165);
        bytes.setRange(0, 32, base58decode(mint));
        bytes.setRange(32, 64, _signer.bytes);
        ByteData.sublistView(
          bytes,
        ).setUint64(64, amount.toInt(), Endian.little);
        bytes[108] = 1;
        return {
          'owner': solanaTokenProgram,
          'lamports': 1,
          'data': [base64Encode(bytes), 'base64'],
        };
      }

      final reads = <List<Object?>>[];
      final adapter = SolanaDappAdapter(
        walletManager: _Wallet(),
        rpc: (_, method, params) async {
          switch (method) {
            case 'getMultipleAccounts':
              final addresses = params.first! as List;
              reads.add(addresses);
              if (addresses.length == 1 && addresses.single == mint) {
                final bytes = Uint8List(82);
                ByteData.sublistView(
                  bytes,
                ).setUint64(36, mintSupply, Endian.little);
                bytes[44] = mintDecimals;
                bytes[45] = 1;
                return {
                  'value': [
                    {
                      'owner': solanaTokenProgram,
                      'data': [base64Encode(bytes), 'base64'],
                    },
                  ],
                };
              }
              return {
                'context': {'slot': 10},
                'value': [_account(2), token(BigInt.from(5)), _account(1)],
              };
            case 'simulateTransaction':
              return {
                'context': {'slot': 10},
                'value': {
                  'err': null,
                  'fee': 5000,
                  'accounts': [
                    _account(1),
                    token(BigInt.from(5) - spent),
                    _account(1),
                  ],
                  ...simulation,
                },
              };
            case 'getAssetBatch':
              return assets;
          }
          throw StateError(method);
        },
      );
      final prepared = await adapter.prepareTransaction(
        transaction: _wire(_tx()),
        walletId: 'wallet',
        address: _signer.toBase58(),
        origin: 'https://site.example',
        chain: 'solana:mainnet',
      );
      return (prepared.review, reads);
    }

    Map<String, Object?> balance(int decimals) => {
      'accountIndex': 1,
      'mint': mint,
      'owner': _signer.toBase58(),
      'uiTokenAmount': {'amount': '5', 'decimals': decimals},
    };

    FundChange spend(SimulationReview review) =>
        review.funds.singleWhere((f) => f.asset.id == mint);

    test('comes from the simulation, with no read of the mint', () async {
      final (result, reads) = await review(
        spent: BigInt.from(3),
        simulation: {
          'postTokenBalances': [balance(6)],
        },
      );
      expect(spend(result).asset.decimals, 6);
      expect(spend(result).rawAmount, BigInt.from(-3));
      expect(reads, hasLength(1), reason: 'only the accounts before');
    });
    test('of a zero-decimal mint takes its supply from DAS', () async {
      final (result, reads) = await review(
        spent: BigInt.one,
        simulation: {
          'preTokenBalances': [balance(0)],
        },
        assets: [
          {
            'id': mint,
            'interface': 'V1_NFT',
            'token_info': {'supply': 1, 'decimals': 0},
          },
        ],
      );
      expect(spend(result).asset.decimals, 0);
      expect(
        result.nfts.single.description,
        'Single-supply token leaves wallet',
      );
      expect(reads, hasLength(1));
    });
    test('is read from the mint when neither source has it', () async {
      final (result, reads) = await review(
        spent: BigInt.one,
        mintDecimals: 0,
        mintSupply: 1,
      );
      expect(reads.last, [mint]);
      expect(spend(result).asset.decimals, 0);
      expect(
        result.nfts.single.description,
        'Single-supply token leaves wallet',
      );
    });
    test('of a zero-decimal mint DAS does not know is read too', () async {
      final (result, reads) = await review(
        spent: BigInt.from(2),
        simulation: {
          'postTokenBalances': [balance(0)],
        },
        mintDecimals: 0,
        mintSupply: 40,
      );
      expect(reads.last, [mint]);
      expect(spend(result).asset.decimals, 0);
      expect(result.nfts, isEmpty);
    });
  });
  group('lookup tables', () {
    final table = Ed25519HDPublicKey(List.filled(32, 4));
    final loaded = Ed25519HDPublicKey(List.filled(32, 5));

    /// A v0 transfer to the address at index 0 of [table].
    Uint8List lookupTransfer() {
      final base = _tx(v0: true);
      final message = base.compiledMessage as CompiledMessageV0;
      return _wire(
        base.copyWith(
          compiledMessage: message.copyWith(
            addressTableLookups: [
              MessageAddressTableLookup(
                accountKey: table,
                writableIndexes: [0],
                readonlyIndexes: [],
              ),
            ],
            instructions: [
              message.instructions.single.copyWith(accountKeyIndexes: [0, 3]),
            ],
          ),
        ),
      );
    }

    late SolanaLookupTableCache cache;
    late List<String> reads;
    setUp(() {
      cache = SolanaLookupTableCache(
        file: () async => throw const FileSystemException('memory only'),
      );
      reads = [];
    });

    SolanaDappAdapter adapter({List<String>? reportedLoaded}) =>
        SolanaDappAdapter(
          walletManager: _Wallet(),
          lookupTables: cache,
          rpc: (_, method, params) async {
            if (method == 'getMultipleAccounts') {
              final addresses = (params.first! as List).cast<String>();
              if (addresses.length == 1 &&
                  addresses.single == table.toBase58()) {
                reads.add('table');
                return {
                  'value': [
                    {
                      'owner': 'AddressLookupTab1e1111111111111111111111111',
                      'data': [
                        base64Encode([...List.filled(56, 0), ...loaded.bytes]),
                        'base64',
                      ],
                    },
                  ],
                };
              }
              reads.add('accounts');
              return {
                'context': {'slot': 10},
                'value': [for (final _ in addresses) _account(2)],
              };
            }
            if (method == 'simulateTransaction') {
              return {
                'context': {'slot': 10},
                'value': {
                  'err': null,
                  'fee': 5000,
                  'accounts': [for (var i = 0; i < 4; i++) _account(2)],
                  'loadedAddresses': {
                    'writable': reportedLoaded ?? [loaded.toBase58()],
                    'readonly': <String>[],
                  },
                },
              };
            }
            throw StateError(method);
          },
        );

    Future<SimulationReview> review(SolanaDappAdapter adapter) async =>
        (await adapter.prepareTransaction(
          transaction: lookupTransfer(),
          walletId: 'wallet',
          address: _signer.toBase58(),
          origin: 'https://site.example',
          chain: 'solana:mainnet',
        )).review;

    test('a table read once is not read again', () async {
      final first = await review(adapter());
      expect(first.funds.first.to, loaded.toBase58());
      expect(reads, ['table', 'accounts']);

      reads.clear();
      final second = await review(adapter());
      expect(second.funds.first.to, loaded.toBase58());
      expect(reads, ['accounts']);
      expect(cache.addresses('solana:mainnet', table.toBase58(), covering: 1), [
        loaded.toBase58(),
      ]);
    });

    test('a node that loads other addresses drops the cached table', () async {
      cache.store('solana:mainnet', table.toBase58(), [_other.toBase58()]);
      final result = await review(adapter(reportedLoaded: [loaded.toBase58()]));
      expect(reads, ['accounts']);
      expect(
        result.warnings,
        contains(
          'Address lookup tables could not be resolved. Some affected accounts are unknown.',
        ),
      );
      expect(
        cache.addresses('solana:mainnet', table.toBase58(), covering: 1),
        isNull,
      );
    });
  });
  group('amounts from the simulation', () {
    final mint = Ed25519HDPublicKey(List.filled(32, 9)).toBase58();

    /// Reviews [_tx]: the read before reports [readLamports] for the signer
    /// at slot 10, the simulation runs at slot 11 with [simulation] merged
    /// into its value.
    Future<SimulationReview> review(
      Map<String, Object?> simulation, {
      int readLamports = 3000000000,
    }) async {
      final adapter = SolanaDappAdapter(
        walletManager: _Wallet(),
        rpc: (_, method, params) async => switch (method) {
          'getMultipleAccounts' => {
            'context': {'slot': 10},
            'value': [_account(readLamports), _account(0), _account(1)],
          },
          'simulateTransaction' => {
            'context': {'slot': 11},
            'value': {
              'err': null,
              'fee': 5000,
              'accounts': [_account(1), _account(1000000000), _account(1)],
              ...simulation,
            },
          },
          'getAssetBatch' => <Object?>[],
          _ => throw StateError(method),
        },
      );
      return (await adapter.prepareTransaction(
        transaction: _wire(_tx()),
        walletId: 'wallet',
        address: _signer.toBase58(),
        origin: 'https://site.example',
        chain: 'solana:mainnet',
      )).review;
    }

    Map<String, Object?> token(int amount, {String? owner}) => {
      'accountIndex': 1,
      'mint': mint,
      'owner': owner ?? _signer.toBase58(),
      'uiTokenAmount': {'amount': '$amount', 'decimals': 6},
    };

    test('carry the signer\'s SOL and its tokens, at one slot', () async {
      final result = await review({
        'preBalances': [2000000000, 0, 1],
        'postBalances': [999995000, 1000000000, 1],
        'preTokenBalances': [token(5)],
        'postTokenBalances': [token(2)],
      });
      final sol = result.funds.singleWhere(
        (f) => f.isNet && f.asset.id == solanaNativeMint,
      );
      // From the simulation, not the read's 3 SOL.
      expect(sol.rawAmount, BigInt.from(-1000005000));
      final spent = result.funds.singleWhere((f) => f.asset.id == mint);
      expect(spent.rawAmount, BigInt.from(-3));
      expect(spent.asset.decimals, 6);
      expect(spent.address, _other.toBase58());
      expect(result.warnings, isNot(contains(kSimulationSnapshotSlotsWarning)));
    });

    test('a plain transfer stays complete across slots', () async {
      final result = await review({
        'preBalances': [2000000000, 0, 1],
        'postBalances': [999995000, 1000000000, 1],
        'preTokenBalances': <Object?>[],
        'postTokenBalances': <Object?>[],
      });
      expect(result.coverage, SimulationCoverage.complete);
    });

    test('a token account changing owner counts as leaving', () async {
      final result = await review({
        'preBalances': [2000000000, 0, 1],
        'postBalances': [999995000, 1000000000, 1],
        'preTokenBalances': [token(5)],
        'postTokenBalances': [token(5, owner: _other.toBase58())],
      });
      expect(
        result.funds.singleWhere((f) => f.asset.id == mint).rawAmount,
        BigInt.from(-5),
      );
    });

    test('fall back to the read when the node leaves them out', () async {
      for (final partial in <Map<String, Object?>>[
        {},
        {
          'preBalances': [2000000000, 0, 1],
          'postBalances': [999995000, 1000000000],
          'preTokenBalances': <Object?>[],
          'postTokenBalances': <Object?>[],
        },
        {
          'preBalances': [2000000000, 0, 1],
          'postBalances': [999995000, 1000000000, 1],
          'preTokenBalances': [
            {'accountIndex': 1, 'mint': mint},
          ],
          'postTokenBalances': <Object?>[],
        },
      ]) {
        final result = await review(partial);
        final sol = result.funds.singleWhere(
          (f) => f.isNet && f.asset.id == solanaNativeMint,
        );
        expect(sol.rawAmount, BigInt.from(1 - 3000000000));
        expect(result.warnings, contains(kSimulationSnapshotSlotsWarning));
      }
    });
  });
}
