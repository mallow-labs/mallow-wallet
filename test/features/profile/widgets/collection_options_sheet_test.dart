import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/profile/widgets/collection_options_sheet.dart';
import 'package:mallow_wallet/shared/widgets/loading_indicator.dart';

void main() {
  Future<void> openSheet(
    WidgetTester tester,
    Future<ArtworkPermissions> permissionsFuture,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCollectionOptionsSheet(
                context,
                title: 'Collection',
                isCreator: true,
                canCast: false,
                canDownload: false,
                permissionsFuture: permissionsFuture,
              ),
              child: const Text('Open options'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open options'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Finder actionDetector(String label) =>
      find.byKey(ValueKey('collection-action-$label'));

  testWidgets(
    'Given pending permissions, When opened, Then gated actions shimmer',
    (tester) async {
      final resolution = Completer<ArtworkPermissions>();

      await openSheet(tester, resolution.future);

      expect(
        find.byKey(const ValueKey('collection-actions-loading')),
        findsOneWidget,
      );
      expect(find.byType(ShimmerBox), findsNWidgets(12));
      for (final label in [
        'Share collection',
        'Sync token',
        'Export holders',
        'Add artworks',
        'Edit collection',
        'Burn collection',
      ]) {
        expect(find.text(label), findsNothing);
      }
    },
  );

  testWidgets(
    'Given resolved permissions, When opened, Then actions reflect permissions',
    (tester) async {
      await openSheet(
        tester,
        Future.value(
          const ArtworkPermissions(
            canTransfer: false,
            canEdit: true,
            canBurn: false,
            canList: false,
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('collection-actions-loading')),
        findsNothing,
      );
      expect(find.text('Add artworks'), findsOneWidget);
      expect(find.text('Edit collection'), findsOneWidget);
      expect(find.text('Burn collection'), findsOneWidget);
      expect(
        tester.widget<GestureDetector>(actionDetector('Add artworks')).onTap,
        isNotNull,
      );
      expect(
        tester.widget<GestureDetector>(actionDetector('Edit collection')).onTap,
        isNotNull,
      );
      expect(
        tester.widget<GestureDetector>(actionDetector('Burn collection')).onTap,
        isNull,
      );
    },
  );

  testWidgets(
    'Given a permission error, When it resolves, Then actions fail closed',
    (tester) async {
      final resolution = Completer<ArtworkPermissions>();
      await openSheet(tester, resolution.future);

      resolution.completeError(StateError('Permission lookup unavailable'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('collection-actions-loading')),
        findsNothing,
      );
      for (final label in [
        'Add artworks',
        'Edit collection',
        'Burn collection',
      ]) {
        expect(find.text(label), findsOneWidget);
        expect(
          tester.widget<GestureDetector>(actionDetector(label)).onTap,
          isNull,
        );
      }
    },
  );
}
