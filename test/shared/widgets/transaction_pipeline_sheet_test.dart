import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_wallet/core/services/signing_copy.dart';
import 'package:mallow_wallet/core/services/social_auth_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/transaction_pipeline_sheet.dart';

/// The in-flight sheet is the user's only signal that a signed transaction is
/// still being worked on. Steps that poll a backend — mint's finalize wait
/// polls the indexer and can outlast a minute — otherwise hold one frozen
/// label the whole time, which reads as a hung app and invites a force-quit
/// on a transaction that is already on-chain. So the invariant here: while a
/// step provides reassurance copy, the sublabel must keep changing, must not
/// wrap back to the opening line (that reads as the wait restarting), and must
/// start over when the pipeline actually moves to a new step.
void main() {
  const cycle = ['Still working on it…', 'Just a moment more…'];

  const interval = Duration(seconds: 5);

  // Advances the fake clock past one cycle interval and lets the sublabel's
  // roll animation land. Can't use pumpAndSettle: the striped panel's stripe
  // loop never settles.
  Future<void> tick(WidgetTester tester) async {
    await tester.pump(interval);
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpSheet(
    WidgetTester tester, {
    required String label,
    List<String> sublabelCycle = cycle,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: TransactionPipelineSheet(
            phase: TransactionPipelinePhase.progress,
            label: label,
            sublabel: 'This may take a moment',
            sublabelCycle: sublabelCycle,
            sublabelCycleInterval: interval,
          ),
        ),
      ),
    );
  }

  testWidgets('cycles the sublabel while one step runs long, then holds', (
    tester,
  ) async {
    await pumpSheet(tester, label: 'Finalizing…');
    expect(find.text('This may take a moment'), findsOneWidget);

    await tick(tester);
    expect(find.text(cycle[0]), findsOneWidget);
    expect(find.text('This may take a moment'), findsNothing);

    await tick(tester);
    expect(find.text(cycle[1]), findsOneWidget);

    // Past the end of the list the last line holds — looping back to the
    // opening copy would read as the wait having started over.
    await tick(tester);
    await tick(tester);
    expect(find.text(cycle[1]), findsOneWidget);
    expect(find.text('This may take a moment'), findsNothing);
  });

  testWidgets('restarts the sequence when the pipeline moves to a new step', (
    tester,
  ) async {
    await pumpSheet(tester, label: 'Finalizing…');
    await tick(tester);
    expect(find.text(cycle[0]), findsOneWidget);

    // A later step must not inherit the previous step's elapsed reassurance.
    await pumpSheet(tester, label: 'Confirming transaction…');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('This may take a moment'), findsOneWidget);
    expect(find.text(cycle[0]), findsNothing);
  });

  testWidgets('leaves the sublabel fixed when no cycle is supplied', (
    tester,
  ) async {
    await pumpSheet(tester, label: 'Finalizing…', sublabelCycle: const []);

    await tick(tester);
    await tick(tester);
    expect(find.text('This may take a moment'), findsOneWidget);
  });

  // The above exercise the mechanism with stand-in copy. This one wires the
  // real Solana confirming copy through the real helper at the real 10 s
  // interval, so the shipped confirming step is covered end to end: the
  // constants, `sublabelCycleFor`'s subtitle match, and the sheet's timer have
  // to agree or a Solana confirmation sits frozen on "a few seconds".
  //
  // `sublabelCycle` is deliberately **not** passed — that is how every flow but
  // mint ships, so the derivation from `sublabel` is part of what's under test.
  // Passing it here would test a path no caller takes.
  testWidgets('the shipped Solana confirming step walks back its promise', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const Scaffold(
          body: TransactionPipelineSheet(
            phase: TransactionPipelinePhase.progress,
            label: kConfirmingLabel,
            sublabel: kConfirmingSublabelSolana,
          ),
        ),
      ),
    );
    expect(find.text(kConfirmingSublabelSolana), findsOneWidget);

    // The production interval is 10 s (the sheet's default), not the 5 s the
    // other cases override to — a regression there would strand the user on
    // the opening line for twice as long.
    Future<void> tickTen() async {
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 500));
    }

    await tickTen();
    expect(find.text('Just a bit longer'), findsOneWidget);

    await tickTen();
    expect(find.text('Network is busier than usual'), findsOneWidget);

    // Holds there — a confirmation this slow is not going to get a *shorter*
    // promise back.
    await tickTen();
    expect(find.text('Network is busier than usual'), findsOneWidget);
    expect(find.text(kConfirmingSublabelSolana), findsNothing);
  });

  // The failure reason is the only copy in this sheet with no length bound: a
  // chain error or an operator message can run several lines. Pinning the body
  // to one height clipped it — the user then reads a bare "Transaction failed"
  // with the part that says *why* cut off, and no way to reveal it.
  group('a long failure message', () {
    const long =
        'Transaction simulation failed: Error processing Instruction 3: '
        'custom program error: 0x1771. The account has insufficient funds '
        'for the rent-exempt reserve plus the transfer amount, so nothing '
        'was sent and no fee was charged.';

    /// Pumps [sheet] at a phone-width sheet, in [available] vertical space —
    /// the room a modal sheet has to grow into.
    Future<void> pumpSized(
      WidgetTester tester,
      Widget sheet, {
      double available = 600,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          theme: MallowTheme.lightTheme,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 360,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: available),
                  child: sheet,
                ),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> pumpError(
      WidgetTester tester,
      String? errorSublabel, {
      double available = 600,
    }) {
      return pumpSized(
        tester,
        TransactionPipelineSheet(
          phase: TransactionPipelinePhase.error,
          label: 'Sending',
          errorSublabel: errorSublabel,
          onRetry: () {},
          onClose: () {},
        ),
        available: available,
      );
    }

    double sheetHeight(WidgetTester tester) =>
        tester.getSize(find.byType(TransactionPipelineSheet)).height;

    testWidgets('grows the sheet instead of overflowing it', (tester) async {
      await pumpError(tester, 'Insufficient funds');
      final short = sheetHeight(tester);

      await pumpError(tester, long);

      // An overflow is a test failure in itself (the framework throws), so the
      // growth assertion is what proves the sheet took the extra lines rather
      // than the message having been silently clipped or shortened.
      expect(
        sheetHeight(tester),
        greaterThan(short),
        reason: 'the wrapped failure reason must make the sheet taller',
      );
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('scrolls only once the sheet has run out of room', (
      tester,
    ) async {
      // Growth is capped by the space the sheet has (in the app, by
      // [maxSheetHeight]). Past it the reason scrolls rather than overflowing,
      // and the Back / Try again row stays pinned and reachable.
      await pumpError(tester, long, available: 180);

      expect(sheetHeight(tester), moreOrLessEquals(180, epsilon: 0.5));
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position
            .maxScrollExtent,
        greaterThan(0),
      );
      expect(find.text('Try again'), findsOneWidget);
    });

    // The error phase is the one phase the sheet lets the user drag away, and
    // the reason now sits in a scroll view — the two compete for the same
    // downward drag. Reading the reason must win while there is more of it to
    // read; dismissal must survive when there isn't.
    group('drag', () {
      Future<void> openError(WidgetTester tester, String? errorSublabel) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: MallowTheme.lightTheme,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => showTransactionPipelineSheet(
                      context: context,
                      builder: (_) => TransactionPipelineSheet(
                        phase: TransactionPipelinePhase.error,
                        label: 'Sending',
                        errorSublabel: errorSublabel,
                        onRetry: () {},
                        onClose: () {},
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }

      testWidgets('dismisses the sheet when the reason fits', (tester) async {
        await openError(tester, 'Insufficient funds');

        await tester.fling(
          find.text('Transaction failed'),
          const Offset(0, 400),
          1000,
        );
        await tester.pumpAndSettle();

        expect(find.text('Transaction failed'), findsNothing);
      });

      testWidgets('scrolls the reason instead when it does not', (
        tester,
      ) async {
        // Short enough that the reason cannot fit even a full-screen sheet.
        tester.view.physicalSize = const Size(360, 300);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await openError(tester, long);

        final position = tester
            .state<ScrollableState>(find.byType(Scrollable).last)
            .position;
        expect(position.maxScrollExtent, greaterThan(0));

        await tester.drag(
          find.text('Transaction failed'),
          const Offset(0, -60),
        );
        await tester.pumpAndSettle();

        expect(position.pixels, greaterThan(0));
        expect(find.text('Transaction failed'), findsOneWidget);
      });
    });

    testWidgets('holds the shared minimum height when it is short', (
      tester,
    ) async {
      // Progress and error must measure the same when neither needs the extra
      // room — the sheet resizing under the user as a transaction resolves is
      // what the fixed height was there to prevent.
      await pumpError(tester, null);
      final errorHeight = sheetHeight(tester);

      await pumpSized(
        tester,
        const TransactionPipelineSheet(
          phase: TransactionPipelinePhase.progress,
          label: 'Sending',
          sublabel: 'This may take a moment',
        ),
      );

      expect(sheetHeight(tester), errorHeight);
    });
  });

  // A social signature can block on an interactive re-login when the wallet's
  // stored key is missing, and that only resolves when the OAuth tab returns.
  // Abandoning that tab leaves the approval step spinning with nothing to press
  // — the sheet blocks both back and drag-dismiss while in flight, so without
  // this the only way out is force-quitting the app mid-transaction.
  group('cancel affordance while a social signature is pending', () {
    late _FakeSocialAuthService fake;

    setUp(() {
      fake = _FakeSocialAuthService();
      GetIt.instance.registerSingleton<SocialAuthService>(fake);
    });

    tearDown(() => GetIt.instance.reset());

    Future<void> pumpApproval(
      WidgetTester tester, {
      String? progressActionLabel,
      VoidCallback? onProgressAction,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          theme: MallowTheme.lightTheme,
          home: Scaffold(
            body: TransactionPipelineSheet(
              phase: TransactionPipelinePhase.progress,
              label: kExternalSigningLabel,
              sublabel: kExternalSigningSublabel,
              progressActionLabel: progressActionLabel,
              onProgressAction: onProgressAction,
            ),
          ),
        ),
      );
    }

    testWidgets('offers Cancel only while a request is in flight', (
      tester,
    ) async {
      await pumpApproval(tester);
      expect(find.text('Cancel'), findsNothing);

      fake.pending.value = true;
      await tester.pump();
      expect(find.text('Cancel'), findsOneWidget);

      fake.pending.value = false;
      await tester.pump();
      expect(find.text('Cancel'), findsNothing);
    });

    testWidgets('tapping Cancel stops the app waiting on the relay', (
      tester,
    ) async {
      fake.pending.value = true;
      await pumpApproval(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pump();

      expect(fake.cancelCalls, 1);
    });

    testWidgets('a host early-exit keeps the slot', (tester) async {
      // "Done" on a broadcast EVM tx is more specific than a generic cancel,
      // and the two cannot share the one action slot.
      fake.pending.value = true;
      var doneTaps = 0;
      await pumpApproval(
        tester,
        progressActionLabel: 'Done',
        onProgressAction: () => doneTaps++,
      );

      expect(find.text('Cancel'), findsNothing);
      await tester.tap(find.text('Done'));
      await tester.pump();

      expect(doneTaps, 1);
      expect(fake.cancelCalls, 0);
    });
  });
}

class _FakeSocialAuthService extends SocialAuthService {
  final pending = ValueNotifier<bool>(false);
  int cancelCalls = 0;

  @override
  ValueListenable<bool> get requestPending => pending;

  @override
  void cancelPendingRequest() => cancelCalls++;
}
