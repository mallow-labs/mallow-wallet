import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:mallow_wallet/shared/widgets/mallow_refresh_indicator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'mallow_loader.json parses and matches the hardcoded loop duration',
    () async {
      // MallowRefreshIndicator drives the Lottie with its own
      // AnimationController pinned to ~2167ms (130 frames @ 60fps). If the
      // composition is re-exported with different timing, the loop speed
      // silently drifts — fail here instead.
      final bytes = File(
        'assets/animations/mallow_loader.json',
      ).readAsBytesSync();
      final composition = await LottieComposition.fromBytes(bytes);
      expect(composition.duration.inMilliseconds, closeTo(2167, 20));
    },
  );

  testWidgets('release past the arm threshold triggers onRefresh', (
    tester,
  ) async {
    final refreshDone = Completer<void>();
    var refreshCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MallowRefreshIndicator(
            onRefresh: () {
              refreshCalls++;
              return refreshDone.future;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [SizedBox(height: 1200)],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Drag short of the 100px arm threshold: the mark shows but releasing
    // here must not refresh.
    final gesture = await tester.startGesture(const Offset(200, 300));
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(find.byType(Lottie), findsOneWidget);

    // Keep pulling past the threshold, then release: refresh fires and the
    // indicator loops until onRefresh completes.
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    await gesture.up();
    // The indicator settles to its resting position before onRefresh fires;
    // pump a handful of frames to run that animation to completion.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(refreshCalls, 1);

    refreshDone.complete();
    await tester.pumpAndSettle();
    expect(refreshCalls, 1);
  });
}
