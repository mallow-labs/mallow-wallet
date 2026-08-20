import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_toggle.dart';

void _noop(bool _) {}

void main() {
  testWidgets('builds, animates, and toggles without throwing', (tester) async {
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => MallowToggle(
                value: value,
                onChanged: (v) => setState(() => value = v),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    // Accessibility: the unlabeled toggle exposes a 40×40 touch target even
    // though the rendered pill is roughly half that.
    expect(tester.getSize(find.byType(MallowToggle)), const Size(40, 40));

    await tester.tap(find.byType(MallowToggle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  // The asset's shapes are colored at runtime via theme-driven ValueDelegates.
  // If the keypaths failed to resolve, the baked colors would show instead — in
  // particular the knob would stay the asset's white rather than bgPrimary. In
  // dark mode bgPrimary is near-black (#121212), the opposite of the baked
  // white, so a near-black opaque pixel proves the knob keypath resolved.
  testWidgets('recolors the knob from the active theme (delegate resolves)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.darkTheme,
        home: const Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: Key('toggle-boundary'),
              child: MallowToggle(value: true, onChanged: _noop),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('toggle-boundary')),
    );
    ui.Image? image;
    ByteData? bytes;
    await tester.runAsync(() async {
      image = await boundary.toImage(pixelRatio: 3);
      bytes = await image!.toByteData();
    });

    final data = bytes!.buffer.asUint8List();
    var foundDarkOpaque = false;
    for (var i = 0; i + 3 < data.length; i += 4) {
      final r = data[i], g = data[i + 1], b = data[i + 2], a = data[i + 3];
      if (a > 200 && r < 50 && g < 50 && b < 50) {
        foundDarkOpaque = true;
        break;
      }
    }
    expect(
      foundDarkOpaque,
      isTrue,
      reason:
          'knob should render in dark bgPrimary, not the baked white — '
          'confirms the [knob, knob-group, knob-fill] keypath resolves',
    );
  });
}
