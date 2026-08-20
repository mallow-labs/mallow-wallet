import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';

void main() {
  group('crypto exceptions', () {
    test('NoWalletException defaults and custom message', () {
      expect(
        NoWalletException().message,
        'No wallet found. Please create or import a wallet.',
      );
      expect(
        NoWalletException('custom').toString(),
        'NoWalletException: custom',
      );
    });

    test('InvalidMnemonicException defaults and custom message', () {
      expect(InvalidMnemonicException().message, 'Invalid mnemonic phrase');
      expect(
        InvalidMnemonicException('bad words').toString(),
        'InvalidMnemonicException: bad words',
      );
    });

    test('SigningException defaults and custom message', () {
      expect(SigningException().message, 'Failed to sign transaction');
      expect(
        SigningException('rpc down').toString(),
        'SigningException: rpc down',
      );
    });

    test('DerivationException defaults and custom message', () {
      expect(DerivationException().message, 'Failed to derive keys');
      expect(
        DerivationException('bip44 fail').toString(),
        'DerivationException: bip44 fail',
      );
    });

    test('ViewOnlyWalletException defaults and custom message', () {
      expect(
        ViewOnlyWalletException().message,
        'This wallet is view-only and cannot sign transactions.',
      );
      expect(
        ViewOnlyWalletException('nope').toString(),
        'ViewOnlyWalletException: nope',
      );
    });

    test('InvalidPrivateKeyException defaults and custom message', () {
      expect(
        InvalidPrivateKeyException().message,
        'Invalid private key format.',
      );
      expect(
        InvalidPrivateKeyException('parse fail').toString(),
        'InvalidPrivateKeyException: parse fail',
      );
    });

    test(
      'SocialTransactionSigningNotSupportedException default + toString',
      () {
        final ex = SocialTransactionSigningNotSupportedException();
        expect(ex.message, contains('social wallet is not yet supported'));
        expect(
          ex.toString(),
          startsWith('SocialTransactionSigningNotSupportedException: '),
        );
      },
    );

    test('LegacySocialWalletException default + toString', () {
      final ex = LegacySocialWalletException();
      // The copy must say the wallet is unrecoverable, not merely unsupported —
      // re-signing in produces a different address, so "try again" is wrong.
      expect(ex.message, contains('old sign-in system'));
      expect(ex.message, contains('cannot be recovered'));
      expect(ex.toString(), startsWith('LegacySocialWalletException: '));
    });

    test('NonSolanaSigningWalletException default + toString', () {
      final ex = NonSolanaSigningWalletException();
      // The copy must be actionable: this state is recoverable by switching to
      // a Solana wallet, unlike the unrecoverable legacy-social case.
      expect(ex.message, contains('cannot sign Solana transactions'));
      expect(ex.message, contains('Switch to a Solana wallet'));
      expect(ex.toString(), startsWith('NonSolanaSigningWalletException: '));
    });

    test('all exceptions implement Exception', () {
      expect(NoWalletException(), isA<Exception>());
      expect(InvalidMnemonicException(), isA<Exception>());
      expect(SigningException(), isA<Exception>());
      expect(DerivationException(), isA<Exception>());
      expect(ViewOnlyWalletException(), isA<Exception>());
      expect(InvalidPrivateKeyException(), isA<Exception>());
      expect(SocialTransactionSigningNotSupportedException(), isA<Exception>());
      expect(LegacySocialWalletException(), isA<Exception>());
      expect(NonSolanaSigningWalletException(), isA<Exception>());
    });
  });

  group('AppFailure.from — crypto exceptions', () {
    test('LegacySocialWalletException surfaces as a signing failure', () {
      // Without the mapper entry this falls through to `unknown` and the user
      // sees the raw `LegacySocialWalletException: …` toString.
      final failure = AppFailure.from(LegacySocialWalletException());
      expect(failure.kind, AppFailureKind.signing);
      expect(failure.message, LegacySocialWalletException().message);
    });

    test('NonSolanaSigningWalletException surfaces as a signing failure', () {
      // The Solana loader throws this when the global selection sits on an
      // Ethereum/Tezos row. Unmapped it falls through to `unknown`, which the
      // UI renders as a crash-shaped error instead of the actionable copy.
      final failure = AppFailure.from(NonSolanaSigningWalletException());
      expect(failure.kind, AppFailureKind.signing);
      expect(failure.message, NonSolanaSigningWalletException().message);
    });
  });
}
