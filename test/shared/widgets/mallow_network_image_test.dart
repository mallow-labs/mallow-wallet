import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_network_image.dart';

Widget _host(Widget child) => MaterialApp(
  theme: MallowTheme.lightTheme,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('an empty source shows the error widget without a request', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        MallowNetworkImage(
          imageUrl: '',
          logicalSize: 48,
          width: 48,
          height: 48,
          borderRadius: BorderRadius.circular(24),
          errorBuilder: (_) => const Text('no image'),
        ),
      ),
    );

    expect(find.text('no image'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
    // The caller's shape still applies to the stand-in.
    expect(find.byType(ClipRRect), findsOneWidget);
  });

  testWidgets('an empty override with a source still loads the source', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const MallowNetworkImage(
          imageUrl: 'https://example.com/a.png',
          cdnUrlOverride: '',
          logicalSize: 48,
        ),
      ),
    );

    expect(find.byType(CachedNetworkImage), findsOneWidget);
  });
}
