import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/services/browser_domain_policy.dart';
import 'package:mallow_wallet/features/browser/services/browser_site_icons.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_site_tile.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_network_image.dart';

/// A 1x1 transparent PNG with its IHDR size patched to [width] x [height].
Uint8List _png({int width = 1, int height = 1}) {
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );
  ByteData.sublistView(bytes)
    ..setUint32(16, width)
    ..setUint32(20, height);
  return bytes;
}

String _dataUrl(Uint8List bytes) =>
    'data:image/png;base64,${base64Encode(bytes)}';

void main() {
  setUpAll(BrowserDomainPolicy.initialize);
  tearDown(BrowserSiteIcons.instance.clear);

  group('decodeBrowserIconCapture', () {
    test('accepts a small PNG data URL', () {
      final bytes = _png(width: 128, height: 128);
      expect(decodeBrowserIconCapture(_dataUrl(bytes)), bytes);
    });

    test('refuses failures, other formats and oversized images', () {
      expect(decodeBrowserIconCapture(''), isNull);
      expect(decodeBrowserIconCapture(null), isNull);
      expect(decodeBrowserIconCapture(42), isNull);
      expect(
        decodeBrowserIconCapture(
          'data:image/svg+xml;base64,${base64Encode(utf8.encode('<svg/>'))}',
        ),
        isNull,
      );
      expect(decodeBrowserIconCapture('data:image/png;base64,%%%'), isNull);
      // Claims to be PNG but is not.
      expect(
        decodeBrowserIconCapture(
          _dataUrl(Uint8List.fromList(List.filled(40, 1))),
        ),
        isNull,
      );
      // A tiny file declaring a huge canvas must never reach the decoder.
      expect(
        decodeBrowserIconCapture(_dataUrl(_png(width: 30000, height: 30000))),
        isNull,
      );
      expect(decodeBrowserIconCapture(_dataUrl(_png(width: 0))), isNull);
      expect(
        decodeBrowserIconCapture('data:image/png;base64,${'A' * 300000}'),
        isNull,
      );
    });
  });

  testWidgets('a drawn icon replaces the CDN fetch for its URL', (
    tester,
  ) async {
    final icon = Uri.parse('https://app.example.com/favicon.ico');
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Center(
            child: BrowserSiteTile(
              host: 'app.example.com',
              iconUrl: icon,
              size: 44,
            ),
          ),
        ),
      ),
    );
    final drawn = find.byWidgetPredicate(
      (widget) => widget is Image && widget.image is MemoryImage,
    );
    expect(find.byType(MallowNetworkImage), findsOneWidget);
    expect(drawn, findsNothing);

    BrowserSiteIcons.instance.put(icon, _png());
    await tester.pump();
    expect(find.byType(MallowNetworkImage), findsNothing);
    expect(drawn, findsOneWidget);

    // Clearing browsing data drops it again.
    BrowserSiteIcons.instance.clear();
    await tester.pump();
    expect(find.byType(MallowNetworkImage), findsOneWidget);
  });

  group('stored icons', () {
    late Directory dir;
    final defaultDirectory = BrowserSiteIcons.directory;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('site_icons');
      BrowserSiteIcons.directory = () async => dir;
    });
    tearDown(() async {
      await BrowserSiteIcons.instance.clear();
      BrowserSiteIcons.directory = defaultDirectory;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test(
      'a drawn icon survives a restart and returns on first lookup',
      () async {
        final icons = BrowserSiteIcons.instance;
        final icon = Uri.parse('https://app.example.com/favicon.ico');
        final bytes = _png(width: 64, height: 64);
        icons.put(icon, bytes);
        await icons.settled;
        // A restart: memory is empty, the file is not.
        await icons.clear();
        final restored = Completer<void>();
        void listener() {
          if (!restored.isCompleted) restored.complete();
        }

        icons.addListener(listener);
        expect(icons[icon], isNull);
        await restored.future.timeout(const Duration(seconds: 5));
        icons.removeListener(listener);
        expect(icons[icon], bytes);
      },
    );

    test('preload reads stored icons before they are shown', () async {
      final icons = BrowserSiteIcons.instance;
      final icon = Uri.parse('https://app.example.com/favicon.ico');
      icons.put(icon, _png());
      await icons.clear();
      await icons.preload([icon, null]);
      expect(icons[icon], isNotNull);
    });

    test('clearing browsing data deletes the files', () async {
      final icons = BrowserSiteIcons.instance;
      final icon = Uri.parse('https://app.example.com/favicon.ico');
      icons.put(icon, _png());
      await icons.settled;
      expect(dir.listSync(), hasLength(1));
      await icons.clear(stored: true);
      expect(dir.existsSync(), isFalse);
      await icons.preload([icon]);
      expect(icons[icon], isNull);
    });

    test('a stored file that is not a small PNG is ignored', () async {
      final icons = BrowserSiteIcons.instance;
      final icon = Uri.parse('https://app.example.com/favicon.ico');
      icons.put(icon, _png());
      await icons.settled;
      await icons.clear();
      dir.listSync().whereType<File>().single.writeAsBytesSync(
        _png(width: 4096, height: 4096),
      );
      await icons.preload([icon]);
      expect(icons[icon], isNull);
    });
  });

  test('keeps a bounded number of icons, oldest out first', () {
    final icons = BrowserSiteIcons.instance;
    for (var i = 0; i < 70; i++) {
      icons.put(Uri.parse('https://s$i.example/i.png'), _png());
    }
    expect(icons[Uri.parse('https://s0.example/i.png')], isNull);
    expect(icons[Uri.parse('https://s69.example/i.png')], isNotNull);
  });
}
