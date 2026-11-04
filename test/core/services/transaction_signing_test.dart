import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/analytics/analytics_events.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/solana_v1_transaction.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/transaction_signing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../../support/recording_analytics.dart';
import '../../support/solana_v1_fixture.dart';

class _MockWalletManager extends Mock implements WalletManager {}

class _MockSolanaRpcService extends Mock implements SolanaRpcService {}

class _MockLedgerService extends Mock implements LedgerService {}

class _FakeSignedTx extends Fake implements SignedTx {}

class _FakeV1Tx extends Fake implements SolanaV1Transaction {}

/// Auth gate that always allows — these tests focus on the sign/broadcast
/// pipeline, not the gate itself (see transaction_auth_gate_test.dart).
class _AllowAllAuthGate implements TransactionAuthGate {
  @override
  bool requiresAuth(double? usdValue) => false;
  @override
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async => TransactionAuthOutcome.allowed;
}

/// Build a one-signer legacy [SignedTx] with the given blockhash.
///
/// `preSigned` controls whether the signature slot already has a non-zero
/// signature (server pre-signed) or is the all-zero placeholder
/// (truly unsigned).
SignedTx _buildSignedTx({
  required String blockhash,
  required Ed25519HDPublicKey signer,
  required Ed25519HDPublicKey recipient,
  required bool preSigned,
}) {
  // SystemInstruction.transfer keeps us out of the private MessageHeader
  // export — Message.compile builds the header for us.
  final instr = SystemInstruction.transfer(
    fundingAccount: signer,
    recipientAccount: recipient,
    lamports: 1,
  );
  final compiled = Message.only(
    instr,
  ).compile(recentBlockhash: blockhash, feePayer: signer);
  final required = compiled.requiredSignatureCount;
  final sigBytes = preSigned
      ? List<int>.filled(64, 7)
      : List<int>.filled(64, 0);
  return SignedTx(
    signatures: List<Signature>.generate(
      required,
      (_) => Signature(sigBytes, publicKey: signer),
    ),
    compiledMessage: compiled,
  );
}

/// 32 zero bytes encoded as base58 — usable as a placeholder blockhash.
String get _placeholderBlockhash => base58encode(Uint8List(32));

/// Pick a different valid base58 32-byte blockhash so we can detect rewrites.
String get _freshBlockhash => base58encode(Uint8List(32)..fillRange(0, 32, 9));

/// The ALT program's `CreateLookupTable` instruction, byte-identical in shape
/// to what `solana_sdk::address_lookup_table::instruction::create_lookup_table`
/// emits and what the backend's `alt::create_and_extend_ixs` puts on the
/// wire: a bincode u32 little-endian variant index (0), the `recent_slot` the
/// runtime checks against `SlotHashes`, and the derivation bump.
Instruction _createLookupTableIx({
  required Ed25519HDPublicKey payer,
  required Ed25519HDPublicKey table,
  int recentSlot = 400000000,
}) => Instruction(
  programId: Ed25519HDPublicKey.fromBase58(addressLookupTableProgramId),
  accounts: [
    AccountMeta.writeable(pubKey: table, isSigner: false),
    AccountMeta.writeable(pubKey: payer, isSigner: true),
  ],
  data: ByteArray.merge([
    ByteArray.u32(0),
    ByteArray.u64(recentSlot),
    ByteArray.u8(255),
  ]),
);

/// `ExtendLookupTable` — bincode variant 2. The top-up path emits only these,
/// and they bake no slot, so they must NOT be mistaken for a create.
Instruction _extendLookupTableIx({
  required Ed25519HDPublicKey payer,
  required Ed25519HDPublicKey table,
}) => Instruction(
  programId: Ed25519HDPublicKey.fromBase58(addressLookupTableProgramId),
  accounts: [
    AccountMeta.writeable(pubKey: table, isSigner: false),
    AccountMeta.writeable(pubKey: payer, isSigner: true),
  ],
  data: ByteArray.merge([
    ByteArray.u32(2),
    ByteArray.u64(1),
    ByteArray(payer.bytes),
  ]),
);

/// Wrap [instructions] into an unsigned single-signer [SignedTx].
SignedTx _unsignedTxWith(
  List<Instruction> instructions, {
  required Ed25519HDPublicKey feePayer,
}) {
  final compiled = Message(
    instructions: instructions,
  ).compile(recentBlockhash: _placeholderBlockhash, feePayer: feePayer);
  return SignedTx(
    signatures: List<Signature>.generate(
      compiled.requiredSignatureCount,
      (_) => Signature(List<int>.filled(64, 0), publicKey: feePayer),
    ),
    compiledMessage: compiled,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeSignedTx());
    registerFallbackValue(_FakeV1Tx());
  });

  late _MockWalletManager wallet;
  late _MockSolanaRpcService rpc;
  late TransactionAuthGate authGate;
  late Ed25519HDPublicKey signer;
  late Ed25519HDPublicKey recipient;

  setUp(() async {
    wallet = _MockWalletManager();
    rpc = _MockSolanaRpcService();
    authGate = _AllowAllAuthGate();
    // Stable test signer + recipient derived from fixed seeds.
    final signerKp = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: Uint8List(32)..fillRange(0, 32, 0x11),
    );
    final recipientKp = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: Uint8List(32)..fillRange(0, 32, 0x22),
    );
    signer = signerKp.publicKey;
    recipient = recipientKp.publicKey;
  });

  // Why this matters: a LUT `setupTx` is the FIRST transaction of a cNFT buy,
  // list, cancel or settle. `_refreshBlockhashIfSafe` happily rewrites its
  // blockhash — nothing has pre-signed it — so the tx keeps looking fresh
  // while the `recent_slot` baked into `create_lookup_table` ages past the
  // ~512-slot (~3.4 min) `SlotHashes` window. The user then sends a
  // transaction that fails on-chain for a reason nothing on screen explains.
  // Detecting the create ix is what lets the executor send it back to the
  // builder instead of merely refreshing it.
  group('createsLookupTable', () {
    late Ed25519HDPublicKey payer;
    late Ed25519HDPublicKey table;

    setUp(() async {
      payer = (await Ed25519HDKeyPair.fromPrivateKeyBytes(
        privateKey: Uint8List(32)..fillRange(0, 32, 0x31),
      )).publicKey;
      table = (await Ed25519HDKeyPair.fromPrivateKeyBytes(
        privateKey: Uint8List(32)..fillRange(0, 32, 0x32),
      )).publicKey;
    });

    test('true for a setup tx that creates a lookup table', () {
      final tx = _unsignedTxWith([
        _createLookupTableIx(payer: payer, table: table),
        _extendLookupTableIx(payer: payer, table: table),
      ], feePayer: payer);

      expect(createsLookupTable(tx), isTrue);
    });

    test('false for an extend-only top-up — it bakes no slot, so a blockhash '
        'refresh is sufficient and a rebuild would be a wasted round-trip', () {
      final tx = _unsignedTxWith([
        _extendLookupTableIx(payer: payer, table: table),
      ], feePayer: payer);

      expect(createsLookupTable(tx), isFalse);
    });

    test('false for an ordinary transfer', () {
      final tx = _buildSignedTx(
        blockhash: _placeholderBlockhash,
        signer: payer,
        recipient: table,
        preSigned: false,
      );

      expect(createsLookupTable(tx), isFalse);
    });
  });

  group('hasPreAttachedSignature', () {
    test('returns false when every signature byte is zero', () {
      final tx = _buildSignedTx(
        blockhash: _placeholderBlockhash,
        signer: signer,
        recipient: recipient,
        preSigned: false,
      );
      expect(hasPreAttachedSignature(tx), isFalse);
    });

    test('returns true when any signature byte is non-zero', () {
      final tx = _buildSignedTx(
        blockhash: _placeholderBlockhash,
        signer: signer,
        recipient: recipient,
        preSigned: true,
      );
      expect(hasPreAttachedSignature(tx), isTrue);
    });

    test('handles empty signatures list (false)', () {
      final tx = SignedTx(
        compiledMessage: _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
          preSigned: false,
        ).compiledMessage,
      );
      expect(hasPreAttachedSignature(tx), isFalse);
    });
  });

  group('signSendConfirm — Keystone staleness discard', () {
    for (final stale in <bool?>[null, false, true]) {
      test('consults the signer only when discard verdict is $stale', () async {
        final tx = _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
          preSigned: true,
        );
        when(
          () => wallet.signCompiledTx(
            unsignedTx: any(named: 'unsignedTx'),
            additionalSigners: any(named: 'additionalSigners'),
          ),
        ).thenAnswer((_) async => tx);
        when(
          () => wallet.activeSignerIsKeystone(),
        ).thenAnswer((_) async => true);
        when(() => rpc.sendTransaction(any())).thenAnswer((_) async => 'sig');
        when(
          () => rpc.awaitConfirmationOrThrow(
            any(),
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).thenAnswer((_) async {});
        var signedNotice = false;

        final result = signSendConfirm(
          tx.encode(),
          walletManager: wallet,
          rpcService: rpc,
          authGate: authGate,
          usdValue: null,
          flow: const FlowKey.solana(AppFlow.editionBuy),
          discardSignatureIf: stale == null ? null : () => stale,
          onSigned: () => signedNotice = true,
        );

        if (stale == true) {
          await expectLater(result, throwsA(isA<SignedTooLateException>()));
          verify(() => wallet.activeSignerIsKeystone()).called(1);
          verifyNever(() => rpc.sendTransaction(any()));
          verifyNever(
            () => rpc.awaitConfirmationOrThrow(
              any(),
              rebroadcast: any(named: 'rebroadcast'),
            ),
          );
          expect(signedNotice, isFalse);
        } else {
          expect(await result, 'sig');
          verifyNever(() => wallet.activeSignerIsKeystone());
          verify(() => rpc.sendTransaction(any())).called(1);
          expect(signedNotice, isTrue);
        }
        verifyNever(() => wallet.isLocalSigner());
      });
    }
  });

  group('signSendConfirm — slow signing validity', () {
    late SignedTx unsigned;
    var onSignedFired = false;

    setUp(() {
      unsigned = _buildSignedTx(
        blockhash: _placeholderBlockhash,
        signer: signer,
        recipient: recipient,
        preSigned: false,
      );
      onSignedFired = false;
      when(
        () => rpc.getLatestBlockhash(),
      ).thenAnswer((_) async => _freshBlockhash);
      when(
        () => wallet.signCompiledTx(
          unsignedTx: any(named: 'unsignedTx'),
          additionalSigners: any(named: 'additionalSigners'),
        ),
      ).thenAnswer((invocation) async {
        final tx = invocation.namedArguments[#unsignedTx] as SignedTx;
        return SignedTx(
          signatures: [Signature(List<int>.filled(64, 7), publicKey: signer)],
          compiledMessage: tx.compiledMessage,
        );
      });
      when(() => wallet.activeSignerIsKeystone()).thenAnswer((_) async => true);
      when(() => rpc.sendTransaction(any())).thenAnswer((_) async => 'sig');
      when(
        () => rpc.awaitConfirmationOrThrow(
          any(),
          rebroadcast: any(named: 'rebroadcast'),
        ),
      ).thenAnswer((_) async {});
    });

    Future<String> sign({
      Duration threshold = Duration.zero,
      bool Function()? discardSignatureIf,
    }) => signSendConfirm(
      unsigned.encode(),
      walletManager: wallet,
      rpcService: rpc,
      authGate: authGate,
      usdValue: 0,
      flow: const FlowKey.solana(AppFlow.nftTransfer),
      slowSigningThreshold: threshold,
      discardSignatureIf: discardSignatureIf,
      onSigned: () => onSignedFired = true,
    );

    test(
      'expired blockhash after slow Keystone signing is discarded unsent',
      () async {
        when(
          () => rpc.isBlockhashStillValid(_freshBlockhash),
        ).thenAnswer((_) async => false);

        await expectLater(sign(), throwsA(isA<SignedTooLateException>()));

        verify(() => rpc.isBlockhashStillValid(_freshBlockhash)).called(1);
        verifyNever(() => rpc.sendTransaction(any()));
        verifyNever(
          () => rpc.awaitConfirmationOrThrow(
            any(),
            rebroadcast: any(named: 'rebroadcast'),
          ),
        );
        expect(onSignedFired, isFalse);
      },
    );

    test(
      'slow Keystone signing with a still-valid blockhash broadcasts',
      () async {
        when(
          () => rpc.isBlockhashStillValid(_freshBlockhash),
        ).thenAnswer((_) async => true);

        expect(await sign(), 'sig');

        verify(() => rpc.isBlockhashStillValid(_freshBlockhash)).called(1);
        verify(() => rpc.sendTransaction(any())).called(1);
        expect(onSignedFired, isTrue);
      },
    );

    test(
      'fast signing never consults the signer type or validity RPC',
      () async {
        expect(await sign(threshold: const Duration(seconds: 10)), 'sig');

        verifyNever(() => wallet.activeSignerIsKeystone());
        verifyNever(() => rpc.isBlockhashStillValid(any()));
        verify(() => rpc.sendTransaction(any())).called(1);
      },
    );

    test(
      'slow non-Keystone signing never queries blockhash validity',
      () async {
        when(
          () => wallet.activeSignerIsKeystone(),
        ).thenAnswer((_) async => false);

        expect(await sign(), 'sig');

        verify(() => wallet.activeSignerIsKeystone()).called(1);
        verifyNever(() => rpc.isBlockhashStillValid(any()));
        verify(() => rpc.sendTransaction(any())).called(1);
      },
    );

    test(
      'validity RPC failure still broadcasts and waits for confirmation',
      () async {
        when(
          () => rpc.isBlockhashStillValid(_freshBlockhash),
        ).thenThrow(StateError('RPC unavailable'));

        expect(await sign(), 'sig');

        verify(() => rpc.isBlockhashStillValid(_freshBlockhash)).called(1);
        verify(() => rpc.sendTransaction(any())).called(1);
        verify(
          () => rpc.awaitConfirmationOrThrow(
            'sig',
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).called(1);
      },
    );

    group('pre-attached signatures', () {
      setUp(() {
        unsigned = _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
          preSigned: true,
        );
      });

      test('expired untracked co-signature is discarded unsent', () async {
        when(
          () => rpc.isBlockhashStillValid(_placeholderBlockhash),
        ).thenAnswer((_) async => false);

        await expectLater(sign(), throwsA(isA<SignedTooLateException>()));

        verify(
          () => rpc.isBlockhashStillValid(_placeholderBlockhash),
        ).called(1);
        verifyNever(() => rpc.getLatestBlockhash());
        verifyNever(() => rpc.sendTransaction(any()));
        expect(onSignedFired, isFalse);
      });

      test(
        'valid co-signature broadcasts without changing its message',
        () async {
          when(
            () => rpc.isBlockhashStillValid(_placeholderBlockhash),
          ).thenAnswer((_) async => true);

          expect(await sign(), 'sig');

          verifyNever(() => rpc.getLatestBlockhash());
          verify(
            () => rpc.isBlockhashStillValid(_placeholderBlockhash),
          ).called(1);
          final sent =
              verify(() => rpc.sendTransaction(captureAny())).captured.single
                  as SignedTx;
          expect(
            sent.compiledMessage.toByteArray(),
            unsigned.compiledMessage.toByteArray(),
          );
        },
      );

      test('validity probe failure still broadcasts and confirms', () async {
        when(
          () => rpc.isBlockhashStillValid(_placeholderBlockhash),
        ).thenThrow(StateError('RPC unavailable'));

        expect(await sign(), 'sig');

        verify(
          () => rpc.isBlockhashStillValid(_placeholderBlockhash),
        ).called(1);
        verify(() => rpc.sendTransaction(any())).called(1);
        verify(
          () => rpc.awaitConfirmationOrThrow(
            'sig',
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).called(1);
      });

      test(
        'tracked co-signature leaves staleness to the builder path',
        () async {
          expect(await sign(discardSignatureIf: () => false), 'sig');

          verifyNever(() => wallet.activeSignerIsKeystone());
          verifyNever(() => rpc.isBlockhashStillValid(any()));
          verify(() => rpc.sendTransaction(any())).called(1);
        },
      );

      test('fast co-signing makes no validity probe', () async {
        expect(await sign(threshold: const Duration(seconds: 10)), 'sig');

        verifyNever(() => wallet.activeSignerIsKeystone());
        verifyNever(() => rpc.isBlockhashStillValid(any()));
      });

      test('slow non-Keystone co-signing makes no validity probe', () async {
        when(
          () => wallet.activeSignerIsKeystone(),
        ).thenAnswer((_) async => false);

        expect(await sign(), 'sig');

        verifyNever(() => rpc.isBlockhashStillValid(any()));
      });
    });
  });

  group('signSendConfirm — blockhash freshness', () {
    test(
      'unsigned tx: refreshes blockhash before signing, then sign+send+confirm',
      () async {
        final unsigned = _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
          preSigned: false,
        );

        final fresh = _freshBlockhash;
        when(() => rpc.getLatestBlockhash()).thenAnswer((_) async => fresh);

        // Capture what the wallet sees for signing — it must carry the
        // fresh blockhash, not the original placeholder.
        SignedTx? receivedByWallet;
        when(
          () => wallet.signCompiledTx(
            unsignedTx: any(named: 'unsignedTx'),
            additionalSigners: any(named: 'additionalSigners'),
          ),
        ).thenAnswer((invocation) async {
          receivedByWallet = invocation.namedArguments[#unsignedTx] as SignedTx;
          return receivedByWallet!;
        });

        when(
          () => rpc.sendTransaction(any()),
        ).thenAnswer((_) async => 'sigXYZ');
        when(
          () => rpc.awaitConfirmationOrThrow(
            any(),
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).thenAnswer((_) async {});

        var onSignedFired = false;
        final sig = await signSendConfirm(
          unsigned.encode(),
          walletManager: wallet,
          rpcService: rpc,
          authGate: authGate,
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
          onSigned: () => onSignedFired = true,
        );

        expect(sig, 'sigXYZ');
        expect(
          onSignedFired,
          isTrue,
          reason: 'onSigned must fire between sign and broadcast',
        );
        expect(receivedByWallet, isNotNull);
        expect(
          receivedByWallet!.compiledMessage.recentBlockhash,
          fresh,
          reason: 'unsigned tx must be re-blockhashed before signing',
        );

        verify(() => rpc.getLatestBlockhash()).called(1);
        verify(() => rpc.sendTransaction(any())).called(1);
        verify(
          () => rpc.awaitConfirmationOrThrow(
            'sigXYZ',
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).called(1);
      },
    );

    test(
      'pre-signed tx: keeps original blockhash so server signature stays valid',
      () async {
        const originalBh =
            // 32 distinct bytes encoded as base58, valid pubkey-shaped string
            // so the message round-trips.
            '11111111111111111111111111111111';
        final unsigned = _buildSignedTx(
          blockhash: originalBh,
          signer: signer,
          recipient: recipient,
          preSigned: true,
        );

        SignedTx? receivedByWallet;
        when(
          () => wallet.signCompiledTx(
            unsignedTx: any(named: 'unsignedTx'),
            additionalSigners: any(named: 'additionalSigners'),
          ),
        ).thenAnswer((invocation) async {
          receivedByWallet = invocation.namedArguments[#unsignedTx] as SignedTx;
          return receivedByWallet!;
        });

        when(
          () => rpc.sendTransaction(any()),
        ).thenAnswer((_) async => 'sigPRE');
        when(
          () => rpc.awaitConfirmationOrThrow(
            any(),
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).thenAnswer((_) async {});

        await signSendConfirm(
          unsigned.encode(),
          walletManager: wallet,
          rpcService: rpc,
          authGate: authGate,
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
        );

        expect(receivedByWallet, isNotNull);
        expect(
          receivedByWallet!.compiledMessage.recentBlockhash,
          originalBh,
          reason: 'pre-signed tx must be passed through unchanged',
        );
        verifyNever(() => rpc.getLatestBlockhash());
      },
    );
  });

  group('signSendConfirm — confirmation is not optional', () {
    /// The signature is the app's "it worked" token: callers emit success,
    /// apply optimistic balance deltas and prod the indexer with it. Returning
    /// it for a transaction that was never confirmed is the double-send bug —
    /// the user saw "Transaction sent", an unchanged balance, and sent again.
    test('propagates the unconfirmed exception instead of returning the '
        'signature', () async {
      final unsigned = _buildSignedTx(
        blockhash: _placeholderBlockhash,
        signer: signer,
        recipient: recipient,
        preSigned: false,
      );
      when(
        () => rpc.getLatestBlockhash(),
      ).thenAnswer((_) async => _freshBlockhash);
      when(
        () => wallet.signCompiledTx(
          unsignedTx: any(named: 'unsignedTx'),
          additionalSigners: any(named: 'additionalSigners'),
        ),
      ).thenAnswer(
        (invocation) async =>
            invocation.namedArguments[#unsignedTx] as SignedTx,
      );
      when(
        () => rpc.sendTransaction(any()),
      ).thenAnswer((_) async => 'sigSTUCK');
      when(
        () => rpc.awaitConfirmationOrThrow(
          any(),
          rebroadcast: any(named: 'rebroadcast'),
        ),
      ).thenThrow(const SolanaTransactionUnconfirmedException('sigSTUCK'));

      await expectLater(
        () => signSendConfirm(
          unsigned.encode(),
          walletManager: wallet,
          rpcService: rpc,
          authGate: authGate,
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
        ),
        throwsA(isA<SolanaTransactionUnconfirmedException>()),
      );
    });

    test('propagates an on-chain failure instead of returning the '
        'signature', () async {
      final unsigned = _buildSignedTx(
        blockhash: _placeholderBlockhash,
        signer: signer,
        recipient: recipient,
        preSigned: false,
      );
      when(
        () => rpc.getLatestBlockhash(),
      ).thenAnswer((_) async => _freshBlockhash);
      when(
        () => wallet.signCompiledTx(
          unsignedTx: any(named: 'unsignedTx'),
          additionalSigners: any(named: 'additionalSigners'),
        ),
      ).thenAnswer(
        (invocation) async =>
            invocation.namedArguments[#unsignedTx] as SignedTx,
      );
      when(() => rpc.sendTransaction(any())).thenAnswer((_) async => 'sigFAIL');
      when(
        () => rpc.awaitConfirmationOrThrow(
          any(),
          rebroadcast: any(named: 'rebroadcast'),
        ),
      ).thenThrow(
        const SolanaTransactionFailedException(
          'sigFAIL',
          'Instruction 2 failed: Custom error 6003',
        ),
      );

      await expectLater(
        () => signSendConfirm(
          unsigned.encode(),
          walletManager: wallet,
          rpcService: rpc,
          authGate: authGate,
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
        ),
        throwsA(isA<SolanaTransactionFailedException>()),
      );
    });

    test('hands the signed transaction to the confirmation wait so it can be '
        're-broadcast — a first broadcast dropped under load is otherwise '
        'never retried', () async {
      final unsigned = _buildSignedTx(
        blockhash: _placeholderBlockhash,
        signer: signer,
        recipient: recipient,
        preSigned: false,
      );
      final fresh = _freshBlockhash;
      when(() => rpc.getLatestBlockhash()).thenAnswer((_) async => fresh);
      when(
        () => wallet.signCompiledTx(
          unsignedTx: any(named: 'unsignedTx'),
          additionalSigners: any(named: 'additionalSigners'),
        ),
      ).thenAnswer(
        (invocation) async =>
            invocation.namedArguments[#unsignedTx] as SignedTx,
      );
      when(() => rpc.sendTransaction(any())).thenAnswer((_) async => 'sigOK');
      SignedTx? handedForResend;
      when(
        () => rpc.awaitConfirmationOrThrow(
          any(),
          rebroadcast: any(named: 'rebroadcast'),
        ),
      ).thenAnswer((invocation) async {
        handedForResend = invocation.namedArguments[#rebroadcast] as SignedTx?;
      });

      await signSendConfirm(
        unsigned.encode(),
        walletManager: wallet,
        rpcService: rpc,
        authGate: authGate,
        usdValue: 0,
        flow: const FlowKey.solana(AppFlow.nftTransfer),
      );

      // The re-broadcast payload must be the tx that was actually sent — the
      // re-blockhashed one, not the caller's original bytes, or every resend
      // would carry a blockhash nobody signed over.
      expect(handedForResend, isNotNull);
      expect(handedForResend!.compiledMessage.recentBlockhash, fresh);
    });
  });

  group('signSendConfirm — Ledger signing-state stream', () {
    test('forwards every state to onLedgerSigning while signing', () async {
      final unsigned = _buildSignedTx(
        blockhash: _placeholderBlockhash,
        signer: signer,
        recipient: recipient,
        preSigned: false,
      );
      when(
        () => rpc.getLatestBlockhash(),
      ).thenAnswer((_) async => _freshBlockhash);
      when(() => rpc.sendTransaction(any())).thenAnswer((_) async => 'sig');
      when(
        () => rpc.awaitConfirmationOrThrow(
          any(),
          rebroadcast: any(named: 'rebroadcast'),
        ),
      ).thenAnswer((_) async {});

      final controller = StreamController<LedgerSigningState>.broadcast(
        sync: true,
      );
      final ledger = _MockLedgerService();
      when(() => ledger.signingState).thenAnswer((_) => controller.stream);

      // Emit two states from inside signCompiledTx so the subscription
      // is in place when they fire.
      when(
        () => wallet.signCompiledTx(
          unsignedTx: any(named: 'unsignedTx'),
          additionalSigners: any(named: 'additionalSigners'),
        ),
      ).thenAnswer((invocation) async {
        controller.add(LedgerSigningState.waitingForConfirmation);
        controller.add(LedgerSigningState.confirmed);
        return invocation.namedArguments[#unsignedTx] as SignedTx;
      });

      final received = <LedgerSigningState>[];
      await signSendConfirm(
        unsigned.encode(),
        walletManager: wallet,
        rpcService: rpc,
        authGate: authGate,
        usdValue: 0,
        flow: const FlowKey.solana(AppFlow.nftTransfer),
        ledgerService: ledger,
        onLedgerSigning: received.add,
      );

      expect(received, [
        LedgerSigningState.waitingForConfirmation,
        LedgerSigningState.confirmed,
      ]);

      // After signSendConfirm returns, the listener must be cancelled —
      // emitting again should not deliver to `received`.
      controller.add(LedgerSigningState.idle);
      expect(
        received,
        hasLength(2),
        reason: 'subscription must be torn down once signing finishes',
      );

      await controller.close();
    });

    test('cancels the Ledger subscription even when signing throws', () async {
      final unsigned = _buildSignedTx(
        blockhash: _placeholderBlockhash,
        signer: signer,
        recipient: recipient,
        preSigned: false,
      );
      when(
        () => rpc.getLatestBlockhash(),
      ).thenAnswer((_) async => _freshBlockhash);
      final controller = StreamController<LedgerSigningState>.broadcast(
        sync: true,
      );
      final ledger = _MockLedgerService();
      when(() => ledger.signingState).thenAnswer((_) => controller.stream);

      when(
        () => wallet.signCompiledTx(
          unsignedTx: any(named: 'unsignedTx'),
          additionalSigners: any(named: 'additionalSigners'),
        ),
      ).thenThrow(StateError('user rejected'));

      final received = <LedgerSigningState>[];
      await expectLater(
        () => signSendConfirm(
          unsigned.encode(),
          walletManager: wallet,
          rpcService: rpc,
          authGate: authGate,
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
          ledgerService: ledger,
          onLedgerSigning: received.add,
        ),
        throwsA(isA<StateError>()),
      );

      // After throw the listener should be torn down — emit a state and
      // confirm nothing flows through.
      controller.add(LedgerSigningState.rejected);
      expect(received, isEmpty);

      await controller.close();
    });
  });

  // Every flow on the executor reaches the analytics transaction ledger only
  // through here, so this is where a missing or double report would hide.
  group('signSendConfirm — transaction ledger', () {
    late RecordingAnalytics analytics;

    setUp(() async {
      analytics = await RecordingAnalytics.install();
      when(
        () => rpc.getLatestBlockhash(),
      ).thenAnswer((_) async => _freshBlockhash);
      when(
        () => wallet.signCompiledTx(
          unsignedTx: any(named: 'unsignedTx'),
          additionalSigners: any(named: 'additionalSigners'),
        ),
      ).thenAnswer(
        (invocation) async =>
            invocation.namedArguments[#unsignedTx] as SignedTx,
      );
      when(() => wallet.getAddress()).thenAnswer((_) async => 'walletAddr');
      when(() => rpc.sendTransaction(any())).thenAnswer((_) async => 'sig1');
    });

    tearDown(RecordingAnalytics.uninstall);

    Future<void> run() => signSendConfirm(
      _buildSignedTx(
        blockhash: _placeholderBlockhash,
        signer: signer,
        recipient: recipient,
        preSigned: false,
      ).encode(),
      walletManager: wallet,
      rpcService: rpc,
      authGate: authGate,
      usdValue: 0,
      flow: const FlowKey.solana(AppFlow.raffleBuyTickets),
    );

    void stubConfirmation(Future<void> Function() answer) => when(
      () => rpc.awaitConfirmationOrThrow(
        any(),
        rebroadcast: any(named: 'rebroadcast'),
      ),
    ).thenAnswer((_) => answer());

    test('a confirmed tx is reported once, with its flow and signer', () async {
      stubConfirmation(() async {});

      await run();
      await pumpEventQueue();

      final event = analytics.submitted.single;
      expect(event[AnalyticsProp.flow], 'solana:raffle-buy-tickets');
      expect(event[AnalyticsProp.signature], 'sig1');
      expect(event[AnalyticsProp.walletAddress], 'walletAddr');
      expect(event[AnalyticsProp.confirmation], 'confirmed');
    });

    test(
      'an unconfirmed tx is reported as pending — it may still land',
      () async {
        stubConfirmation(
          () async => throw const SolanaTransactionUnconfirmedException('sig1'),
        );

        await expectLater(
          run(),
          throwsA(isA<SolanaTransactionUnconfirmedException>()),
        );
        await pumpEventQueue();

        expect(
          analytics.submitted.single[AnalyticsProp.confirmation],
          'pending',
        );
      },
    );

    test('a tx that failed on-chain is not reported', () async {
      stubConfirmation(
        () async => throw const SolanaTransactionFailedException('sig1', 'x'),
      );

      await expectLater(
        run(),
        throwsA(isA<SolanaTransactionFailedException>()),
      );
      await pumpEventQueue();

      expect(analytics.submitted, isEmpty);
    });
  });

  // The `solana` package cannot decode a v1 transaction, so one that reached
  // the `SignedTx` path would throw before the wallet ever saw it. A v1 tx is
  // recognised by its 0x81 prefix and goes through as bytes from end to end.
  group('signSendConfirm — v1 transactions', () {
    late List<SolanaV1Transaction> signedInputs;

    setUp(() {
      signedInputs = [];
      when(
        () => rpc.getLatestBlockhash(),
      ).thenAnswer((_) async => _freshBlockhash);
      when(
        () => wallet.signV1Tx(
          unsignedTx: any(named: 'unsignedTx'),
          additionalSigners: any(named: 'additionalSigners'),
        ),
      ).thenAnswer((invocation) async {
        final tx =
            invocation.namedArguments[#unsignedTx] as SolanaV1Transaction;
        signedInputs.add(tx);
        return tx.withSignature(v1Payer, List<int>.filled(64, 7));
      });
      when(
        () => rpc.sendWireTransaction(any()),
      ).thenAnswer((_) async => 'v1-sig');
      when(
        () => rpc.awaitWireConfirmationOrThrow(
          any(),
          rebroadcast: any(named: 'rebroadcast'),
        ),
      ).thenAnswer((_) async {});
    });

    Future<String> send(String hex) => signSendConfirm(
      base64Encode(hexBytes(hex)),
      walletManager: wallet,
      rpcService: rpc,
      authGate: authGate,
      usdValue: null,
      flow: const FlowKey.solana(AppFlow.nftTransfer),
    );

    test('signs, sends and confirms the bytes without SignedTx', () async {
      expect(await send(v1Unsigned), 'v1-sig');

      final sent =
          verify(() => rpc.sendWireTransaction(captureAny())).captured.single
              as SolanaV1Transaction;
      expect(sent.signatures.first, List<int>.filled(64, 7));
      verify(
        () => rpc.awaitWireConfirmationOrThrow('v1-sig', rebroadcast: sent),
      ).called(1);
      verifyNever(() => rpc.sendTransaction(any()));
      verifyNever(
        () => wallet.signCompiledTx(
          unsignedTx: any(named: 'unsignedTx'),
          additionalSigners: any(named: 'additionalSigners'),
        ),
      );
    });

    test('refreshes the blockhash of a tx nobody has signed', () async {
      await send(v1Unsigned);

      expect(signedInputs.single.recentBlockhash, _freshBlockhash);
    });

    test('keeps the blockhash under an existing co-signature', () async {
      await send(v1Signed);

      expect(signedInputs.single.recentBlockhash, v1Blockhash);
      verifyNever(() => rpc.getLatestBlockhash());
    });
  });
}
