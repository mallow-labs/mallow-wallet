import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/widgets/paged_section.dart';
import 'package:mallow_wallet/shared/widgets/loading_indicator.dart';

// PagedSection backs the artwork History / Offers tabs. The behaviour these
// tests pin is the anti-flicker contract: once rows are on screen, a
// `refreshToken` bump must re-pull page 0 *without* tearing the rows down
// into the empty-state spinner. Before this contract the section was
// remounted on every indexer refresh, so listing an artwork flashed the
// History list back to a loading indicator even though results already
// existed — exactly what a user reported. A regression here (e.g. clearing
// `_items` before the refresh lands, or reintroducing the spinner) is what
// these tests must catch.

/// Drives a [PagedSection] whose page-0 fetch is controlled by the test so
/// we can hold a refresh in-flight and inspect what is on screen meanwhile.
class _Harness extends StatefulWidget {
  const _Harness({required this.pages, required this.completers, super.key});

  /// pages[token] is the page-0 payload returned for that refreshToken.
  final List<List<String>> pages;

  /// completers[token], when non-null, gates that fetch until completed —
  /// lets a test assert what renders while the refresh is still pending.
  final List<Completer<void>?> completers;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  int _token = 0;

  void bump() => setState(() => _token++);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PagedSection<String>(
            refreshToken: _token,
            identity: (s) => s,
            emptyLabel: 'empty',
            rowBuilder: (s) => Text(s, key: ValueKey('row-$s')),
            fetchPage: (page) async {
              final token = _token;
              final gate = widget.completers[token];
              if (gate != null) await gate.future;
              return (items: widget.pages[token], nextPage: null);
            },
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('shows the spinner only on the initial empty load', (
    tester,
  ) async {
    final gate = Completer<void>();
    await tester.pumpWidget(
      _Harness(
        pages: const [
          ['a', 'b'],
        ],
        completers: [gate],
      ),
    );
    // Fetch in flight, nothing loaded yet → spinner.
    await tester.pump();
    expect(find.byType(MallowLoadingIndicator), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(MallowLoadingIndicator), findsNothing);
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('a refreshToken bump keeps rows visible with no spinner flash', (
    tester,
  ) async {
    final refreshGate = Completer<void>();
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      _Harness(
        key: key,
        pages: const [
          ['a', 'b'],
          ['c', 'a', 'b'], // refresh adds 'c' at the top
        ],
        completers: [null, refreshGate],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);

    // Bump the token: the refresh fetch is held open by refreshGate.
    key.currentState!.bump();
    await tester.pump();

    // The whole point: while the background refresh is in flight the
    // existing rows stay put and NO spinner replaces them.
    expect(find.byType(MallowLoadingIndicator), findsNothing);
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);

    // Let the refresh land: the new row animates in and joins the list.
    refreshGate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(MallowLoadingIndicator), findsNothing);
    expect(find.text('c'), findsOneWidget);
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
  });

  // Why this matters: this section backs the artwork History tab, which is a
  // provenance surface. "No history yet." is a factual claim about the chain.
  // Making a dropped request render that claim tells a buyer an artwork has
  // never traded when the app simply couldn't ask — the failure mode CLAUDE.md
  // Rule 12 exists to prevent. The failed state must be distinguishable, and
  // recoverable without leaving the screen.
  testWidgets('a failed first page reads as failed, not empty, and retries', (
    tester,
  ) async {
    var attempt = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PagedSection<String>(
              emptyLabel: 'No history yet.',
              errorLabel: "Couldn't load history.",
              rowBuilder: (s) => Text(s, key: ValueKey('row-$s')),
              fetchPage: (page) async {
                if (attempt++ == 0) throw Exception('network down');
                return (items: const ['a'], nextPage: null);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load history."), findsOneWidget);
    expect(find.text('No history yet.'), findsNothing);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load history."), findsNothing);
    expect(find.text('a'), findsOneWidget);
  });

  testWidgets('a genuinely empty first page still reads as empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PagedSection<String>(
              emptyLabel: 'No history yet.',
              errorLabel: "Couldn't load history.",
              rowBuilder: (s) => Text(s),
              fetchPage: (page) async => (items: <String>[], nextPage: null),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No history yet.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });
}
