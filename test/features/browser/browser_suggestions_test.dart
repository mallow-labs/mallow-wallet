import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/features/browser/data/browser_repository.dart';
import 'package:mallow_wallet/features/browser/models/browser_models.dart';
import 'package:mallow_wallet/features/browser/screens/browser_start_screen.dart';
import 'package:mallow_wallet/features/browser/services/browser_services.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/browser_suggestions.dart';
import 'package:mallow_wallet/features/browser/services/dapp_permission_service.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_address_field.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

BrowserRepository _repository() => BrowserRepository(
  SecureWalletStorage(const FlutterSecureStorage(), MnemonicVault()),
);

Future<BrowserSession> _session() async {
  final session = BrowserSession(_repository());
  await session.load();
  return session;
}

const _catalog = <BrowserPopularSite>[
  BrowserPopularSite(name: 'Jupiter', url: 'https://jup.ag'),
  BrowserPopularSite(name: 'Drift', url: 'https://app.drift.trade'),
  BrowserPopularSite(name: 'Phoenix', url: 'https://www.phoenix.trade'),
  BrowserPopularSite(
    name: 'Solana Explorer',
    url: 'https://explorer.solana.com',
  ),
];

List<String> _hosts(List<BrowserSuggestion> suggestions) => [
  for (final s in suggestions) '${s.url.host}${s.url.path}',
];

/// Commits [url] in a fresh tab, as the browser does once a document loads.
void _commit(BrowserSession session, Uri url, {String title = ''}) {
  session.open(null);
  session.update(session.activeId!, url: url, title: title);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('browserSuggestions', () {
    List<BrowserSuggestion> suggest(
      String input, {
      List<BrowserBookmark> bookmarks = const [],
      List<BrowserSiteInfo> typed = const [],
    }) => browserSuggestions(
      input,
      bookmarks: bookmarks,
      typedSites: typed,
      catalog: _catalog,
    );

    test('matches host starts, later labels and names, never the TLD', () {
      expect(_hosts(suggest('ju')), ['jup.ag']);
      expect(_hosts(suggest('https://www.JUP')), ['jup.ag']);
      expect(_hosts(suggest('jup.ag/')), ['jup.ag']);
      expect(_hosts(suggest('drift')), ['app.drift.trade']);
      expect(_hosts(suggest('phoe')), ['www.phoenix.trade']);
      expect(_hosts(suggest('jupiter')), ['jup.ag']);
      expect(_hosts(suggest('explorer')), ['explorer.solana.com']);
      // A later word of a name.
      expect(_hosts(suggest('expl')), ['explorer.solana.com']);
      expect(suggest('trade'), isEmpty);
      expect(suggest('  '), isEmpty);
    });

    test('the user\'s own sites come first and duplicates collapse', () {
      final suggestions = suggest(
        'j',
        bookmarks: [
          BrowserBookmark(url: Uri.parse('https://jup.ag/perps'), title: 'J'),
        ],
        typed: [
          BrowserSiteInfo(origin: 'https://jup.ag', typed: true),
          BrowserSiteInfo(origin: 'https://jupp.example', typed: true),
        ],
      );
      expect(_hosts(suggestions), ['jup.ag/perps', 'jup.ag', 'jupp.example']);
      expect(suggestions.map((s) => s.source), [
        BrowserSuggestionSource.bookmark,
        BrowserSuggestionSource.typed,
        BrowserSuggestionSource.typed,
      ]);
    });

    test('a typed site is never matched on its page title', () {
      final typed = [
        BrowserSiteInfo(
          origin: 'https://lookalike.example',
          title: 'Jupiter',
          typed: true,
        ),
      ];
      expect(_hosts(suggest('jupiter', typed: typed)), ['jup.ag']);
      // A bookmark's title is the user's own words.
      final bookmark = BrowserBookmark(
        url: Uri.parse('https://saved.example'),
        title: 'My swaps',
      );
      expect(_hosts(suggest('swaps', bookmarks: [bookmark])), [
        'saved.example',
      ]);
    });

    test('a better match outranks the source order, and the limit holds', () {
      final suggestions = suggest(
        'p',
        bookmarks: [
          BrowserBookmark(url: Uri.parse('https://x.example'), title: 'Perps'),
        ],
      );
      // Address start (phoenix) beats a bookmark matched only by its title.
      expect(_hosts(suggestions).first, 'www.phoenix.trade');
      final many = [
        for (var i = 0; i < 9; i++)
          BrowserPopularSite(name: 'A$i', url: 'https://a$i.example'),
      ];
      expect(
        browserSuggestions(
          'a',
          bookmarks: const [],
          typedSites: const [],
          catalog: many,
        ),
        hasLength(browserSuggestionLimit),
      );
    });
  });

  group('typed sites', () {
    test('an address the user typed is remembered once its site loads, '
        'across restarts', () async {
      final session = await _session();
      session.noteTyped(Uri.parse('https://example.com'));
      _commit(session, Uri.parse('https://www.example.com/home'), title: 'Ex');
      // A link the user followed is not typed.
      _commit(session, Uri.parse('https://linked.example'), title: 'Linked');
      expect(session.typedSites.map((s) => s.origin), [
        'https://www.example.com',
      ]);
      await session.flush();

      final restored = await _session();
      final typed = restored.typedSites.single;
      expect(typed.origin, 'https://www.example.com');
      expect(typed.title, 'Ex');
      expect(restored.site(Uri.parse('https://linked.example'))?.typed, false);
    });

    test('an address that never loads is not remembered', () async {
      final session = await _session();
      session.noteTyped(Uri.parse('https://typo.example'));
      // The typed load failed; the next document is another site's.
      _commit(session, Uri.parse('https://other.example'));
      // The mark was spent on that commit, not kept for a later visit.
      _commit(session, Uri.parse('https://typo.example'));
      expect(session.typedSites, isEmpty);
    });

    test(
      'a later visit keeps the mark; clearing browsing data drops it',
      () async {
        final session = await _session();
        session.noteTyped(Uri.parse('https://example.com'));
        _commit(session, Uri.parse('https://example.com'));
        session.update(session.activeId!, title: 'Example');
        expect(session.typedSites.single.title, 'Example');
        session.noteTyped(Uri.parse('https://pending.example'));
        session.clear(keepBookmarks: true, forgetSites: true);
        _commit(session, Uri.parse('https://pending.example'));
        expect(session.typedSites, isEmpty);
      },
    );

    test('a full site record forgets untyped sites first', () async {
      final session = await _session();
      session.noteTyped(Uri.parse('https://kept.example'));
      _commit(session, Uri.parse('https://kept.example'));
      for (var i = 0; i < BrowserRepository.siteCapacity + 5; i++) {
        session.update(
          session.activeId!,
          url: Uri.parse('https://site$i.example'),
          title: 'Site $i',
        );
      }
      expect(session.typedSites.single.origin, 'https://kept.example');
      expect(session.site(Uri.parse('https://site0.example')), isNull);
    });
  });

  group('address fields', () {
    Future<void> pump(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: MallowTheme.lightTheme,
          home: Scaffold(body: child),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the start page suggests sites and opens a pick as typed', (
      tester,
    ) async {
      // The bundled list; no list URL is configured under test.
      await tester.runAsync(browserSites.start);
      final session = await tester.runAsync(_session);
      Uri? opened;
      await pump(
        tester,
        BrowserStartScreen(
          session: session,
          inBrowser: true,
          onOpen: (uri) => opened = uri,
          permissions: DappPermissionService(
            read: () async => '',
            write: (_) async {},
          ),
        ),
      );
      expect(find.byKey(const Key('browser-suggestions')), findsNothing);
      await tester.enterText(find.byType(TextField), 'magic');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('browser-suggestions')), findsOneWidget);
      expect(find.text('Magic Eden'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('browser-suggestion-https://magiceden.io')),
      );
      await tester.pumpAndSettle();
      expect(opened, Uri.parse('https://magiceden.io'));
      _commit(session!, Uri.parse('https://magiceden.io/'));
      expect(session.typedSites.single.origin, 'https://magiceden.io');
    });

    testWidgets('a search is never remembered as a typed site', (tester) async {
      final session = await tester.runAsync(_session);
      await pump(
        tester,
        BrowserStartScreen(
          session: session,
          inBrowser: true,
          onOpen: (_) {},
          permissions: DappPermissionService(
            read: () async => '',
            write: (_) async {},
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'example');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      _commit(session!, Uri.parse('https://duckduckgo.com/?q=example'));
      expect(session.typedSites, isEmpty);
    });

    testWidgets('the page address field waits for an edit before suggesting', (
      tester,
    ) async {
      await tester.runAsync(browserSites.start);
      final session = await tester.runAsync(_session);
      Uri? opened;
      await pump(
        tester,
        BrowserAddressField(
          initial: 'https://jup.ag/',
          session: session,
          onOpen: (uri) => opened = uri,
        ),
      );
      expect(find.byKey(const Key('browser-suggestions')), findsNothing);
      await tester.enterText(find.byType(TextField), 'tens');
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('browser-suggestion-https://www.tensor.trade'),
        ),
      );
      expect(opened, Uri.parse('https://www.tensor.trade'));
    });
  });
}
