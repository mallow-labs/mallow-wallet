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
      // The copy must say why this wallet cannot sign here, and must not
      // suggest signing in again: that opens a different wallet.
      expect(ex.message, contains('cannot sign on this device'));
      expect(ex.message, contains('would open a different wallet'));
      expect(ex.toString(), startsWith('LegacySocialWalletException: '));
    });

    test('SocialAccountMismatchException names the account the wallet '
        'needs', () {
      // A vault had to be reopened and another account answered. The message
      // names the right one (by the email last seen for it, when known) and
      // says nothing was changed: no answer from the wrong account is acted
      // on.
      final named = SocialAccountMismatchException(
        provider: 'google',
        expectedEmail: 'owner@example.test',
      );
      expect(named, isA<LegacySocialWalletException>());
      expect(
        named.message,
        'This wallet belongs to owner@example.test. Sign in with that account '
        'to use it. Nothing was changed.',
      );
      expect(named.toString(), startsWith('SocialAccountMismatchException: '));

      final unnamed = SocialAccountMismatchException(provider: 'apple');
      expect(
        unnamed.message,
        contains('the Apple account it was created with'),
      );
      // It never sends the user to the older sign-in or to a phrase: the
      // wallet's vault may well be intact.
      expect(unnamed.message, isNot(contains('older')));
      expect(unnamed.message, isNot(contains('backup')));
    });

    test('LegacySocialKeyUnavailableException says how to get the wallet '
        'back', () {
      // A wallet from the older sign-in whose stored key is gone. The app has
      // no older sign-in, so the message is the whole recovery path: the
      // website, an export there, an import here.
      final ex = LegacySocialKeyUnavailableException();
      expect(ex, isA<LegacySocialWalletException>());
      expect(
        ex.message,
        allOf(
          contains('older Google sign-in'),
          contains('not on this device'),
          contains('sign in on the mallow website with the older sign-in'),
          contains('export the wallet’s keys there'),
          contains('Import wallet'),
        ),
      );
      // The existing row has to go first: an import at an address a wallet
      // already holds is refused as a duplicate.
      expect(ex.message, contains('remove this wallet here'));
      // No host is named; the website is whichever one a deployment serves.
      expect(ex.message, isNot(contains('http')));
      expect(ex.message, isNot(matches(RegExp(r'\.(art|com|io|app)\b'))));
      expect(
        ex.toString(),
        startsWith('LegacySocialKeyUnavailableException: '),
      );

      expect(
        LegacySocialKeyUnavailableException(provider: 'apple').message,
        contains('older Apple sign-in'),
      );
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
