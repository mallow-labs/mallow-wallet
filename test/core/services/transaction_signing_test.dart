import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/transaction_signing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

class _MockWalletManager extends Mock implements WalletManager {}

class _MockSolanaRpcService extends Mock implements SolanaRpcService {}

class _MockLedgerService extends Mock implements LedgerService {}

class _FakeSignedTx extends Fake implements SignedTx {}

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

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeSignedTx());
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
}
