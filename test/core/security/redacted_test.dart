import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/redacted.dart';
import 'package:mallow_wallet/features/accounts/services/import_private_key_bloc.dart';
import 'package:mallow_wallet/features/accounts/services/import_wallets_bloc.dart';

/// The wallet-import blocs carry a raw mnemonic / private key through freezed
/// events and states. freezed generates `toString()` on each *concrete* union
/// member and interpolates every field, so the moment a `BlocObserver` is
/// registered — or someone drops a `print(state)` while debugging — those
/// secrets become log lines, Sentry breadcrumbs, and crash-report context.
///
/// These tests fail if a future edit un-wraps one of those fields.
void main() {
  // Dummy values only — the all-`abandon` BIP-39 test vector and hand-typed
  // filler. Never use a real phrase or key in a test.
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon abandon abandon about';
  const privateKey = '4Nd1mQ7fakePrivateKeyMaterialForTestsOnly99xyz';

  group('Redacted', () {
    test('masks the value in toString but still exposes it via .value', () {
      const secret = Redacted(mnemonic);

      expect(secret.toString(), '***');
      expect('$secret', isNot(contains('abandon')));
      expect(secret.value, mnemonic);
    });

    test('keeps value equality so freezed == and copyWith still work', () {
      expect(const Redacted(mnemonic), const Redacted(mnemonic));
      expect(
        const Redacted(mnemonic).hashCode,
        const Redacted<String>(mnemonic).hashCode,
      );
      expect(const Redacted('a'), isNot(const Redacted('b')));
    });
  });

  group('import bloc secrets never reach toString', () {
    test('ImportWalletsEvent.loadFromMnemonic', () {
      const event = ImportWalletsEvent.loadFromMnemonic(Redacted(mnemonic));

      expectNoSecret(event.toString(), mnemonic.split(' '));
    });

    test('ImportPrivateKeyEvent.validateKey', () {
      const event = ImportPrivateKeyEvent.validateKey(Redacted(privateKey));

      expectNoSecret(event.toString(), const [privateKey]);
      // The union is Diagnosticable, so the devtools/inspector path needs the
      // same guarantee as the plain toString.
      final props = DiagnosticPropertiesBuilder();
      event.debugFillProperties(props);
      expectNoSecret(
        props.properties.map((p) => p.toString()).join(' '),
        const [privateKey],
      );
    });

    test(
      'ImportPrivateKeyState.validated holds the key for a whole screen',
      () {
        const state = ImportPrivateKeyState.validated(
          address: 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH',
          rawInput: Redacted(privateKey),
        );

        expectNoSecret(state.toString(), const [privateKey]);
        // The address is not a secret and stays visible — the redaction must be
        // targeted, or nobody will be able to debug the import flow.
        expect(state.toString(), contains('HN7c'));
      },
    );
  });
}

/// Assert none of [secrets] (nor, for a phrase, any word of it) survives in
/// [rendered].
void expectNoSecret(String rendered, List<String> secrets) {
  for (final secret in secrets) {
    expect(
      rendered,
      isNot(contains(secret)),
      reason: 'secret leaked into toString: $rendered',
    );
  }
}
