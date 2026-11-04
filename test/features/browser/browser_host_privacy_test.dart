import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/features/browser/data/browser_repository.dart';
import 'package:mallow_wallet/features/browser/models/browser_models.dart';
import 'package:mallow_wallet/features/browser/services/browser_lock.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/browser_domain_policy.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_address_bar.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_host_text.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_page_menu.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_tab_switcher.dart';
import 'package:mallow_wallet/features/browser/widgets/start_continue_card.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

const _phish = 'jup.ag.claim-verify.xyz';

Future<BrowserSession> _session() async {
  FlutterSecureStorage.setMockInitialValues({});
  final session = BrowserSession(
    BrowserRepository(
      SecureWalletStorage(const FlutterSecureStorage(), MnemonicVault()),
    ),
  );
  await session.load();
  return session;
}

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 4, 4),
    Paint()..color = const Color(0xFF808080),
  );
  final image = await recorder.endRecording().toImage(4, 4);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Every visible host string in the tree: none may cut the domain's end.
Iterable<String> _texts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '');

void _expectEndKept(WidgetTester tester) {
  final hosts = _texts(tester).where((t) => t.contains('.xyz'));
  expect(hosts, isNotEmpty);
  for (final text in hosts) {
    expect(text, endsWith('claim-verify.xyz'), reason: text);
  }
}

void main() {
  setUpAll(BrowserDomainPolicy.initialize);
  group('registrable domain', () {
    test('keeps the part that names the site', () {
      expect(browserRegistrableDomain('app.jup.ag'), 'jup.ag');
      expect(browserRegistrableDomain(_phish), 'claim-verify.xyz');
      expect(browserRegistrableDomain('www.bbc.co.uk'), 'bbc.co.uk');
      expect(browserRegistrableDomain('shop.example.ne.jp'), 'example.ne.jp');
      expect(browserRegistrableDomain('alice.github.io'), 'alice.github.io');
      expect(browserRegistrableDomain('a.b.ck'), 'a.b.ck');
      expect(browserRegistrableDomain('www.ck'), 'www.ck');
      expect(
        browserRegistrableDomain('shop.example.unknownsuffix'),
        'shop.example.unknownsuffix',
      );
      expect(browserRegistrableDomain('mallow.art'), 'mallow.art');
      expect(browserRegistrableDomain('127.0.0.1'), '127.0.0.1');
    });
  });

  group('host elision', () {
    const style = TextStyle(fontSize: 15);
    test('elides from the start, never the end', () {
      // The test font draws every glyph 15 px wide: 19 characters fit.
      expect(
        browserElideHost(_phish, style, TextScaler.noScaling, 290),
        '…g.claim-verify.xyz',
      );
      // Too narrow even for the registrable domain: it is kept whole.
      expect(
        browserElideHost(_phish, style, TextScaler.noScaling, 60),
        '…claim-verify.xyz',
      );
      expect(
        browserElideHost(_phish, style, TextScaler.noScaling, 1000),
        _phish,
      );
    });
  });

  Widget app(Widget child, {double scale = 2}) => MaterialApp(
    theme: MallowTheme.lightTheme,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child,
      ),
    ),
  );

  testWidgets('long hosts keep their domain end at 320 dp and 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    BrowserAddressBar bar({required bool compact}) => BrowserAddressBar(
      compact: compact,
      host: _phish,
      blank: false,
      loading: false,
      onAddress: () {},
      onTabs: () {},
      onReloadOrStop: () {},
      onExpand: () {},
    );
    for (final compact in [false, true]) {
      await tester.pumpWidget(app(Scaffold(body: bar(compact: compact))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      _expectEndKept(tester);
    }

    await tester.pumpWidget(
      app(
        Scaffold(
          body: SingleChildScrollView(
            child: BrowserPageMenu(
              url: Uri.parse('https://$_phish/claim?wallet=1'),
              title: 'Jupiter airdrop',
              bookmarked: false,
              loading: false,
              wallet: null,
              connected: false,
            ),
          ),
        ),
        // The shared menu rows do not wrap the test font's extra-wide glyphs
        // at 2x; the host line is what is under test here.
        scale: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    _expectEndKept(tester);

    final session = await _session();
    session.open(Uri.parse('https://$_phish/'));
    session.update(session.activeId!, title: 'Jupiter');
    await tester.pumpWidget(
      app(
        BrowserTabSwitcher(
          session: session,
          connectedTabs: const {},
          onClose: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    _expectEndKept(tester);

    await tester.pumpWidget(
      app(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: StartContinueCard(
              tab: BrowserTab(
                id: 't',
                url: Uri.parse('https://$_phish/'),
                title: 'Jupiter',
              ),
              tabCount: 1,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    _expectEndKept(tester);
  });

  testWidgets('a short host is followed by the page title', (tester) async {
    await tester.pumpWidget(
      app(const Scaffold(body: BrowserHostText('jup.ag', detail: 'Swap'))),
    );
    expect(find.text('jup.ag'), findsOneWidget);
    expect(find.text(' · Swap'), findsOneWidget);
  });

  group('lock', () {
    test('drops screenshots on lock without creating a session', () async {
      dropBrowserThumbnailsOnLock(const AppLockState.locked());
      expect(BrowserSession.existing, isNull);

      final session = await _session();
      session.open(Uri.parse('https://jup.ag'));
      final id = session.activeId!;
      session.setThumbnail(id, Uint8List.fromList([1, 2, 3]));
      dropBrowserThumbnailsOnLock(
        const AppLockState.unlocked(),
        session: session,
      );
      expect(session.thumbnail(id), isNotNull);
      dropBrowserThumbnailsOnLock(
        const AppLockState.locked(),
        session: session,
      );
      expect(session.thumbnail(id), isNull);
    });

    testWidgets('dropped screenshots leave the image cache too', (
      tester,
    ) async {
      final session = await _session();
      session.open(Uri.parse('https://jup.ag'));
      final id = session.activeId!;
      final bytes = (await tester.runAsync(_png))!;
      session.setThumbnail(id, bytes);
      await tester.pumpWidget(Image.memory(bytes));
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(bytes),
          tester.element(find.byType(Image)),
        ),
      );
      final cache = PaintingBinding.instance.imageCache;
      expect(cache.statusForKey(MemoryImage(bytes)).tracked, isTrue);
      session.clearThumbnails();
      expect(cache.statusForKey(MemoryImage(bytes)).tracked, isFalse);
    });
  });
}
