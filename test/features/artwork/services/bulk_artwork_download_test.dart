import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/services/bulk_artwork_download.dart';
import 'package:mallow_wallet/features/profile/services/collection_download_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// The progress sheet is non-dismissible — no swipe, no barrier tap, no back
/// gesture — so Cancel is the user's only way out of it. It used to close only
/// when the batch's future resolved, which made that exit conditional on work
/// completing: a stalled gateway or a photo-library write parked behind the
/// system "Select More Photos" alert left the sheet up with a Cancel button
/// that visibly did nothing, and the app needing a force-quit.
///
/// The sheet never reaches a settled frame — its loader spins and its progress
/// bar runs indeterminate until a count arrives — so these pump explicitly
/// rather than with `pumpAndSettle`.
void main() {
  const settle = Duration(milliseconds: 400);

  Future<void> showSheet(
    WidgetTester tester, {
    required Future<CollectionDownloadProgress> future,
    required VoidCallback onCancel,
    required Stream<CollectionDownloadProgress> progress,
    String behind = 'behind',
  }) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        navigatorKey: navigator,
        home: Scaffold(body: Text(behind)),
      ),
    );
    unawaited(
      showModalBottomSheet<void>(
        context: navigator.currentContext!,
        isDismissible: false,
        enableDrag: false,
        builder: (_) => PopScope(
          canPop: false,
          child: DownloadProgressSheet(
            title: 'Saving to Photos',
            progressStream: progress,
            future: future,
            onCancel: onCancel,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(settle);
  }

  group('DownloadProgressSheet cancel', () {
    testWidgets('closes the sheet even when the batch never finishes', (
      tester,
    ) async {
      // Never completed on purpose: this is the hung batch the old sheet had no
      // answer for. If closing still waits on the future, the pop never lands.
      final stuck = Completer<CollectionDownloadProgress>();
      final progress = StreamController<CollectionDownloadProgress>.broadcast();
      var cancelled = false;

      await showSheet(
        tester,
        future: stuck.future,
        onCancel: () => cancelled = true,
        progress: progress.stream,
      );
      expect(find.text('Saving to Photos'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(settle);

      expect(cancelled, isTrue, reason: 'the batch must be told to stop');
      expect(
        find.text('Saving to Photos'),
        findsNothing,
        reason:
            'Cancel owns the sheet dismissal; waiting on the batch is what made '
            'it unresponsive when the batch could not finish',
      );

      await progress.close();
    });

    testWidgets('a second tap cannot pop the screen underneath', (
      tester,
    ) async {
      // The button is still on screen through the sheet's close animation, so a
      // double tap must not send a second pop past the sheet into the navigator.
      final stuck = Completer<CollectionDownloadProgress>();
      final progress = StreamController<CollectionDownloadProgress>.broadcast();
      var cancels = 0;

      await showSheet(
        tester,
        future: stuck.future,
        onCancel: () => cancels++,
        progress: progress.stream,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.tap(find.text('Cancel'), warnIfMissed: false);
      await tester.pump(settle);

      expect(cancels, 1, reason: 'the batch is cancelled once, not per tap');
      expect(
        find.text('behind'),
        findsOneWidget,
        reason: 'the screen that launched the download must survive Cancel',
      );

      await progress.close();
    });

    testWidgets('a batch that finishes on its own still closes the sheet', (
      tester,
    ) async {
      final done = Completer<CollectionDownloadProgress>();
      final progress = StreamController<CollectionDownloadProgress>.broadcast();

      await showSheet(
        tester,
        future: done.future,
        onCancel: () {},
        progress: progress.stream,
      );
      expect(find.text('Saving to Photos'), findsOneWidget);

      done.complete(
        const CollectionDownloadProgress(completed: 2, failed: 0, total: 2),
      );
      await tester.pump();
      await tester.pump(settle);

      expect(find.text('Saving to Photos'), findsNothing);

      await progress.close();
    });
  });

  group('DownloadProgressSheet progress', () {
    testWidgets('runs indeterminate until the artwork count is known', (
      tester,
    ) async {
      // The artwork list is walked page by page before the batch starts, so
      // "0 / 0" would be a lie during it — the sheet says Preparing… and leaves
      // the bar unbound instead.
      final progress = StreamController<CollectionDownloadProgress>.broadcast();
      await showSheet(
        tester,
        future: Completer<CollectionDownloadProgress>().future,
        onCancel: () {},
        progress: progress.stream,
      );

      expect(find.text('Preparing…'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );

      progress.add(
        const CollectionDownloadProgress(completed: 1, failed: 1, total: 4),
      );
      await tester.pump();

      expect(find.text('2 / 4'), findsOneWidget);
      expect(find.text('1 failed'), findsOneWidget);

      await progress.close();
    });
  });
}
