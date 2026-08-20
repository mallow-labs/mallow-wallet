import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/features/send/models/recipient_advisory.dart';
import 'package:mallow_wallet/features/send/widgets/send_confirm_step.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/generic_confirmation_sheet.dart';
import 'package:mocktail/mocktail.dart';

class _MockAvatarService extends Mock implements AvatarService {}

// The send sheet sizes itself from a probe render of this step, then hands the
// resulting height back to the visible copy. Both halves of that contract are
// load-bearing: if the probe stopped reporting the step's *natural* height, a
// late "Transaction may fail" warning would be scrolled out of sight inside a
// sheet that never grew — the failure the two modes exist to prevent.
void main() {
  const failed = SimulationResult(success: false, error: 'insufficient funds');

  setUp(() {
    final avatars = _MockAvatarService();
    when(() => avatars.cachedFile(any())).thenReturn(null);
    when(() => avatars.avatarFile(any())).thenAnswer((_) async => null);
    GetIt.I.registerSingleton<AvatarService>(avatars);
  });

  tearDown(() => GetIt.I.reset());

  Widget step({
    required bool intrinsic,
    SimulationBannerState? simulation,
    RecipientAdvisory? advisory,
    int? previousSendCount,
    VoidCallback? onSend,
  }) => SendConfirmStep(
    amountText: '1 SOL',
    amountFiatText: r'$100',
    tokenName: 'Solana',
    recipientName: 'recipient',
    recipientImageUrl: null,
    recipientAddress: 'So11111111111111111111111111111111111111112',
    feeText: '0.000005',
    feeFiatText: r'$0.01',
    simulation: simulation,
    isSending: false,
    onBack: () {},
    onCancel: () {},
    onSend: onSend ?? () {},
    recipientAdvisory: advisory,
    previousSendCount: previousSendCount,
    intrinsicHeight: intrinsic,
  );

  Future<void> pump(WidgetTester tester, Widget child) async {
    // Phone-sized so the step lays out the way it does on a device.
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          // Loosely constrained in height, like the sheet's sizing stack: the
          // step is free to report the height it wants.
          body: Center(child: child),
        ),
      ),
    );
  }

  testWidgets('the height probe grows when the simulation warning appears', (
    tester,
  ) async {
    await pump(tester, step(intrinsic: true));
    final quiet = tester.getSize(find.byType(SendConfirmStep)).height;

    await pump(
      tester,
      step(
        intrinsic: true,
        simulation: const SimulationBannerState(
          isSimulating: false,
          result: failed,
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(SendConfirmStep)).height,
      greaterThan(quiet),
      reason: 'the probe must ask the sheet for the taller height it needs',
    );
    expect(find.text('Transaction may fail'), findsOneWidget);
  });

  testWidgets('the visible copy pins its CTA and scrolls the overflow', (
    tester,
  ) async {
    // 300px is less than the step needs — standing in for the sheet having
    // grown as far as the cap allows.
    await pump(tester, SizedBox(height: 300, child: step(intrinsic: false)));

    final box = tester.getRect(find.byType(SendConfirmStep));
    expect(
      tester.getRect(find.text('Send')).bottom,
      lessThanOrEqualTo(box.bottom),
      reason: 'the Send CTA stays pinned inside the height it was given',
    );
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).last)
          .position
          .maxScrollExtent,
      greaterThan(0),
      reason: 'the body — not the CTA — absorbs what no longer fits',
    );
  });

  group('recipient advisory', () {
    const advisory = RecipientAdvisory(
      RecipientAdvisoryKind.unfunded,
      'This wallet is empty, please confirm the address is correct',
    );

    testWidgets('an advisory never gates the Send CTA', (tester) async {
      // The invariant the whole feature rests on: every account class the
      // advisory flags — PDA, contract wallet, brand-new wallet — is a
      // legitimate destination, so blocking here would be wrong and would
      // generate support load. One careless `canSend &&` away from violation.
      var sent = 0;
      await pump(
        tester,
        step(intrinsic: true, advisory: advisory, onSend: () => sent++),
      );

      await tester.tap(find.text('Send'));
      await tester.pump();

      expect(sent, 1, reason: 'the warning informs the user, it does not stop');
    });

    testWidgets('no advisory contributes no height', (tester) async {
      await pump(tester, step(intrinsic: true));
      final quiet = tester.getSize(find.byType(SendConfirmStep)).height;

      await pump(tester, step(intrinsic: true, advisory: advisory));

      expect(find.text(advisory.message), findsOneWidget);
      expect(
        tester.getSize(find.byType(SendConfirmStep)).height,
        greaterThan(quiet),
        reason:
            'the notice grows the sheet when it fires, and reserves nothing '
            'on the ordinary sends where it does not',
      );
    });

    testWidgets('a simulation failure and an advisory both render, the '
        'advisory with the recipient it describes', (tester) async {
      await pump(
        tester,
        step(
          intrinsic: true,
          advisory: advisory,
          simulation: const SimulationBannerState(
            isSimulating: false,
            result: failed,
          ),
        ),
      );

      expect(find.text('Transaction may fail'), findsOneWidget);
      expect(
        tester.getRect(find.text(advisory.message)).top,
        lessThan(tester.getRect(find.text('Transaction may fail')).top),
        reason:
            'the advisory sits with the recipient block it is about; the '
            'transaction-level banner stays down by the CTA',
      );
    });
  });

  group('previous sends label', () {
    testWidgets('a never-used recipient says so', (tester) async {
      await pump(tester, step(intrinsic: true, previousSendCount: 0));
      expect(find.text('No previous sends'), findsOneWidget);
    });

    testWidgets('one send is singular', (tester) async {
      await pump(tester, step(intrinsic: true, previousSendCount: 1));
      expect(find.text('1 previous send'), findsOneWidget);
    });

    testWidgets('more than one is plural', (tester) async {
      await pump(tester, step(intrinsic: true, previousSendCount: 4));
      expect(find.text('4 previous sends'), findsOneWidget);
    });

    testWidgets('the label costs no height — it shares the Recipient row', (
      tester,
    ) async {
      await pump(tester, step(intrinsic: true));
      final unlabelled = tester.getSize(find.byType(SendConfirmStep)).height;

      await pump(tester, step(intrinsic: true, previousSendCount: 12));

      expect(
        tester.getSize(find.byType(SendConfirmStep)).height,
        unlabelled,
        reason:
            'the sizing probe omits the count, so it must not change the '
            'height the sheet was floored at',
      );
    });
  });
}
