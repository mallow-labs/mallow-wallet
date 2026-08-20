import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/security/biometric_auth.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mocktail/mocktail.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockBiometric extends Mock implements BiometricAuthService {}

class _MockStorage extends Mock implements SecureWalletStorage {}

/// Stands in for the live config poller. Only [config] is ever read by the
/// gate, so everything else stays unimplemented on purpose.
class _FakeRemoteConfigService extends Fake implements RemoteConfigService {
  final ValueNotifier<RemoteConfig> notifier = ValueNotifier(
    RemoteConfig.permissive,
  );

  @override
  ValueListenable<RemoteConfig> get config => notifier;
}

/// An implemented, never-killed cell. Every pre-existing test uses it so its
/// behaviour is exactly what it was before the kill switch landed.
const _swap = FlowKey.solana(AppFlow.tokenSwap);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockBiometric biometric;
  late _MockStorage storage;
  late _FakeRemoteConfigService remoteConfig;
  late List<FlowKey> unsupportedReports;
  late TransactionAuthGate gate;

  setUp(() {
    biometric = _MockBiometric();
    storage = _MockStorage();
    remoteConfig = _FakeRemoteConfigService();
    unsupportedReports = [];
    gate = TransactionAuthGate.withReporter(
      biometric,
      storage,
      remoteConfig,
      unsupportedReports.add,
    );

    // Default for the enabled-path tests: the gate is turned on and no
    // custom threshold is configured (falls back to
    // kTransactionAuthThresholdUsd, $100). The off-by-default behaviour is
    // covered explicitly in its own group below.
    when(
      () => storage.loadTransactionAuthEnabled(),
    ).thenAnswer((_) async => true);
    when(
      () => storage.loadTransactionAuthThresholdUsd(),
    ).thenAnswer((_) async => null);
  });

  group('authorize (master switch)', () {
    test(
      'off by default: never prompts, ignores value and threshold',
      () async {
        when(
          () => storage.loadTransactionAuthEnabled(),
        ).thenAnswer((_) async => false);

        // A large value AND a null value (which normally fails closed) both
        // pass straight through when the gate is disabled.
        expect(
          await gate.authorize(usdValue: 10000.0, flow: _swap),
          TransactionAuthOutcome.allowed,
        );
        expect(
          await gate.authorize(usdValue: null, flow: _swap),
          TransactionAuthOutcome.allowed,
        );
        verifyZeroInteractions(biometric);
        // Disabled short-circuits before reading the threshold or PIN state.
        verifyNever(() => storage.loadTransactionAuthThresholdUsd());
        verifyNever(() => storage.hasPin());
      },
    );
  });

  group('authorize (remote kill switch — the signing backstop)', () {
    /// Kill [flow] on [chain] with [message], the way a live config refresh
    /// would.
    void kill(
      Chain chain,
      AppFlow flow, {
      String message = 'Swaps are paused while we fix a router bug.',
    }) {
      remoteConfig.notifier.value = RemoteConfig(
        disabledMessages: {'${chain.toDbString()}:${flow.wire}': message},
      );
    }

    test('rejects a killed cell with step-up auth DISABLED and a sub-threshold '
        'value — the check must run before BOTH early returns', () async {
      // This is the regression test for the dead-backstop bug. The master
      // opt-in is off (its production default) AND the value is far below
      // the threshold, so *both* of authorize()'s pre-existing early
      // returns would hand back `allowed`. The only way this test passes is
      // if the kill check runs ahead of both of them. It fails the moment
      // someone moves it below either one — which would leave the backstop
      // inert for every user who has never enabled step-up auth, i.e. almost
      // all of them.
      when(
        () => storage.loadTransactionAuthEnabled(),
      ).thenAnswer((_) async => false);
      kill(Chain.solana, AppFlow.tokenSwap);

      final outcome = await gate.authorize(usdValue: 1.0, flow: _swap);

      expect(outcome.isFlowDisabled, isTrue);
      expect(
        outcome.disabledMessage,
        'Swaps are paused while we fix a router bug.',
      );
      // And it short-circuits before touching auth state at all.
      verifyZeroInteractions(biometric);
      verifyNever(() => storage.loadTransactionAuthEnabled());
      verifyNever(() => storage.loadTransactionAuthThresholdUsd());
    });

    test('surfaces the operator message verbatim to the caller', () async {
      kill(Chain.solana, AppFlow.tokenSwap, message: 'Down for maintenance.');

      final outcome = await gate.authorize(usdValue: 5.0, flow: _swap);

      // Callers render this through the kill-specific exception — never the
      // cancel one — so the operator's copy, not a generic "cancelled",
      // is what the user reads.
      final message = outcome.disabledMessage;
      expect(message, isNotNull);
      expect(
        TransactionFlowDisabledException(message!).toString(),
        'Down for maintenance.',
      );
    });

    test('falls back to generic copy when the message is empty', () async {
      kill(Chain.solana, AppFlow.tokenSwap, message: '');

      final outcome = await gate.authorize(usdValue: 5.0, flow: _swap);

      expect(outcome.disabledMessage, kFlowDisabledFallbackMessage);
    });

    test(
      'a killed cell does not kill the same flow on another chain',
      () async {
        // The per-chain granularity claim, as a test rather than a comment.
        kill(Chain.ethereum, AppFlow.nativeSend);

        expect(
          await gate.authorize(
            usdValue: 1.0,
            flow: const FlowKey(Chain.ethereum, AppFlow.nativeSend),
          ),
          isA<TransactionAuthOutcome>().having(
            (o) => o.isFlowDisabled,
            'isFlowDisabled',
            isTrue,
          ),
        );
        expect(
          await gate.authorize(
            usdValue: 1.0,
            flow: const FlowKey.solana(AppFlow.nativeSend),
          ),
          TransactionAuthOutcome.allowed,
        );
      },
    );

    test(
      'an escape hatch stays signable while its create-path twin is killed',
      () async {
        // Killing broken listing *creation* must never strand listed
        // assets by also killing delisting.
        kill(Chain.solana, AppFlow.fixedPriceCreate);

        expect(
          await gate.authorize(
            usdValue: 1.0,
            flow: const FlowKey.solana(AppFlow.fixedPriceCancel),
          ),
          TransactionAuthOutcome.allowed,
        );
      },
    );

    test('a non-killed cell is unaffected by the check', () async {
      // Nothing killed: the gate behaves exactly as it did before, including
      // the master opt-in short-circuit.
      when(
        () => storage.loadTransactionAuthEnabled(),
      ).thenAnswer((_) async => false);

      expect(
        await gate.authorize(usdValue: 10000.0, flow: _swap),
        TransactionAuthOutcome.allowed,
      );
      expect(unsupportedReports, isEmpty);
    });

    test(
      'an unimplemented cell reports and returns a visible error rather than '
      'failing silently',
      () async {
        // The UI should never have offered `tezos:token-swap` — swaps are
        // Solana-only. Reaching the backstop with one is a bug, so it must be
        // reported AND surfaced — not silently allowed, and not silently
        // blocked. (This case used to be spelled `tezos:token-send`, which is
        // now a real cell; the assertion needs a cell this build genuinely
        // cannot do.)
        when(
          () => storage.loadTransactionAuthEnabled(),
        ).thenAnswer((_) async => false);
        const cell = FlowKey(Chain.tezos, AppFlow.tokenSwap);

        final outcome = await gate.authorize(usdValue: 1.0, flow: cell);

        expect(outcome.isFlowDisabled, isTrue);
        expect(outcome.disabledMessage, kUnsupportedFlowMessage);
        expect(unsupportedReports, [cell]);
        verifyZeroInteractions(biometric);
      },
    );
  });

  group('requiresAuth (pure threshold)', () {
    test('returns false for usd values at or below \$100', () {
      expect(gate.requiresAuth(0), isFalse);
      expect(gate.requiresAuth(99.99), isFalse);
      // Exact threshold is allowed — the check is `>`, not `>=`. This is
      // intentional so the rule reads as "above \$100".
      expect(gate.requiresAuth(100), isFalse);
    });

    test('returns true for usd values strictly above \$100', () {
      expect(gate.requiresAuth(100.01), isTrue);
      expect(gate.requiresAuth(500), isTrue);
      expect(gate.requiresAuth(1e9), isTrue);
    });

    test(
      'returns true when usd value is null (fail-closed when price is unknown)',
      () {
        // This is the rule that protects flows where the token price isn't
        // cached yet — we can't safely classify the tx as "small" without a
        // price reference, so we always demand the second factor.
        expect(gate.requiresAuth(null), isTrue);
      },
    );
  });

  group('authorize (no auth path)', () {
    test('allows without prompting when below threshold', () async {
      // Reads the enabled flag and the configured threshold, then
      // short-circuits without ever prompting for a second factor.
      final outcome = await gate.authorize(usdValue: 50.0, flow: _swap);
      expect(outcome, TransactionAuthOutcome.allowed);
      verifyZeroInteractions(biometric);
      verify(() => storage.loadTransactionAuthEnabled()).called(1);
      verify(() => storage.loadTransactionAuthThresholdUsd()).called(1);
      verifyNoMoreInteractions(storage);
    });

    test(
      'allows without prompting at exact \$100 (boundary is inclusive-below)',
      () async {
        final outcome = await gate.authorize(usdValue: 100.0, flow: _swap);
        expect(outcome, TransactionAuthOutcome.allowed);
        verifyZeroInteractions(biometric);
        verify(() => storage.loadTransactionAuthEnabled()).called(1);
        verify(() => storage.loadTransactionAuthThresholdUsd()).called(1);
        verifyNoMoreInteractions(storage);
      },
    );
  });

  group('authorize (above threshold)', () {
    test(
      'returns allowed when biometric is enabled and the user passes',
      () async {
        when(
          () => storage.loadBiometricEnabled(),
        ).thenAnswer((_) async => true);
        when(
          () => biometric.authenticateForTransaction(),
        ).thenAnswer((_) async => BiometricAuthResult.success);

        final outcome = await gate.authorize(usdValue: 150.0, flow: _swap);

        expect(outcome, TransactionAuthOutcome.allowed);
        verify(() => biometric.authenticateForTransaction()).called(1);
      },
    );

    test(
      'returns allowed when usdValue is null and biometric passes',
      () async {
        // Fail-closed: unknown USD forces the prompt, and a passing prompt
        // unlocks signing.
        when(
          () => storage.loadBiometricEnabled(),
        ).thenAnswer((_) async => true);
        when(
          () => biometric.authenticateForTransaction(),
        ).thenAnswer((_) async => BiometricAuthResult.success);

        final outcome = await gate.authorize(usdValue: null, flow: _swap);

        expect(outcome, TransactionAuthOutcome.allowed);
        verify(() => biometric.authenticateForTransaction()).called(1);
      },
    );

    test(
      'returns cancelled when the user cancels the biometric prompt',
      () async {
        when(
          () => storage.loadBiometricEnabled(),
        ).thenAnswer((_) async => true);
        when(
          () => biometric.authenticateForTransaction(),
        ).thenAnswer((_) async => BiometricAuthResult.failed);

        final outcome = await gate.authorize(usdValue: 150.0, flow: _swap);

        expect(outcome, TransactionAuthOutcome.cancelled);
        // We must NOT fall back to PIN when the user actively cancelled —
        // that would feel like the app is second-guessing their "no".
        verifyNever(() => storage.hasPin());
      },
    );

    test(
      'returns unavailable when biometric is disabled and no PIN is set',
      () async {
        when(
          () => storage.loadBiometricEnabled(),
        ).thenAnswer((_) async => false);
        when(() => storage.hasPin()).thenAnswer((_) async => false);

        final outcome = await gate.authorize(usdValue: 150.0, flow: _swap);

        expect(outcome, TransactionAuthOutcome.unavailable);
        // Biometric must not be prompted when not enabled.
        verifyNever(() => biometric.authenticateForTransaction());
      },
    );

    test(
      'falls back from notAvailable biometric to PIN sheet (unavailable when no nav context)',
      () async {
        // Biometric is "enabled" in settings but the OS says it isn't
        // currently usable (e.g. permission revoked). The gate must then
        // try the PIN fallback.
        when(
          () => storage.loadBiometricEnabled(),
        ).thenAnswer((_) async => true);
        when(
          () => biometric.authenticateForTransaction(),
        ).thenAnswer((_) async => BiometricAuthResult.notAvailable);
        when(() => storage.hasPin()).thenAnswer((_) async => true);

        // No widget tree is mounted in this unit test, so the navigator
        // key has no current context — the gate should fail-closed with
        // [unavailable] rather than silently allow.
        final outcome = await gate.authorize(usdValue: 150.0, flow: _swap);

        expect(outcome, TransactionAuthOutcome.unavailable);
      },
    );
  });

  group('authorize (configured threshold)', () {
    test('a value below the user-raised threshold does not prompt', () async {
      // User raised their gate to \$500. A \$150 tx that would have
      // prompted under the \$100 default must now pass untouched.
      when(
        () => storage.loadTransactionAuthThresholdUsd(),
      ).thenAnswer((_) async => 500.0);

      final outcome = await gate.authorize(usdValue: 150.0, flow: _swap);

      expect(outcome, TransactionAuthOutcome.allowed);
      verifyZeroInteractions(biometric);
    });

    test('a value above the user-lowered threshold prompts', () async {
      // User lowered their gate to \$10. A \$50 tx that would have passed
      // under the \$100 default must now demand the second factor.
      when(
        () => storage.loadTransactionAuthThresholdUsd(),
      ).thenAnswer((_) async => 10.0);
      when(() => storage.loadBiometricEnabled()).thenAnswer((_) async => true);
      when(
        () => biometric.authenticateForTransaction(),
      ).thenAnswer((_) async => BiometricAuthResult.success);

      final outcome = await gate.authorize(usdValue: 50.0, flow: _swap);

      expect(outcome, TransactionAuthOutcome.allowed);
      verify(() => biometric.authenticateForTransaction()).called(1);
    });
  });
}
