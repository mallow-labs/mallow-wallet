import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/features/browser/data/browser_repository.dart';
import 'package:mallow_wallet/features/browser/models/browser_models.dart';
import 'package:mallow_wallet/features/browser/services/browser_session.dart';
import 'package:mallow_wallet/features/browser/services/browser_site_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  BrowserRepository repository() => BrowserRepository(
    SecureWalletStorage(const FlutterSecureStorage(), MnemonicVault()),
  );
  test(
    'app wipe before first browser use does not construct a session',
    () async {
      await BrowserSession.resetForAppWipe();
    },
  );

  test('addresses reject schemes and embedded credentials; text searches', () {
    expect(browserInputUri('jup.ag/swap').toString(), 'https://jup.ag/swap');
    expect(browserInputUri('Solana art').host, 'duckduckgo.com');
    expect(
      browserInputUri(
        'Solana art',
        engine: BrowserSearchEngine.google,
      ).toString(),
      'https://www.google.com/search?q=Solana+art',
    );
    for (final url in [
      'javascript:alert(1)',
      'file:///private/key',
      'https://user:pass@example.com',
      'http://example.com',
    ]) {
      expect(() => browserInputUri(url), throwsFormatException);
    }
  });
  test('restart restores safe URLs and explicit complete bookmarks', () async {
    final session = BrowserSession(repository());
    await session.load();
    session.open(Uri.parse('https://example.com/path?token=secret#private'));
    session.bookmark(
      BrowserBookmark(
        url: Uri.parse('https://example.com/art?id=1'),
        title: 'Art',
      ),
    );
    await session.flush();
    final restored = BrowserSession(repository());
    await restored.load();
    expect(restored.activeTab!.url.toString(), 'https://example.com');
    expect(restored.bookmarks.single.url.query, 'id=1');
  });
  test(
    'moving bookmarks saves the order across restart and ignores stale targets',
    () async {
      final session = BrowserSession(repository());
      await session.load();
      final bookmarks = [
        for (var i = 0; i < 4; i++)
          BrowserBookmark(
            url: Uri.parse('https://saved.example/page$i'),
            title: 'Page $i',
            iconUrl: Uri.parse('https://saved.example/icon.png'),
          ),
      ];
      for (final bookmark in bookmarks) {
        session.bookmark(bookmark);
      }
      session.moveBookmark(bookmarks.first.url, bookmarks.last.url);
      final expected = [...bookmarks.skip(1), bookmarks.first];
      expect(session.bookmarks, expected);
      final missing = Uri.parse('https://missing.example');
      session.moveBookmark(missing, bookmarks.first.url);
      session.moveBookmark(bookmarks.first.url, missing);
      session.moveBookmark(bookmarks.first.url, bookmarks.first.url);
      expect(session.bookmarks, expected);
      await session.flush();
      final restored = BrowserSession(repository());
      await restored.load();
      expect(restored.bookmarks.map((b) => b.url), expected.map((b) => b.url));
      expect(
        restored.bookmarks.map((b) => b.title),
        expected.map((b) => b.title),
      );
      expect(
        restored.bookmarks.every((b) => b.iconUrl == bookmarks.first.iconUrl),
        isTrue,
      );
      restored.moveBookmark(bookmarks.first.url, bookmarks[1].url);
      expect(restored.bookmarks.map((b) => b.url), bookmarks.map((b) => b.url));
      await restored.flush();
    },
  );
  test('editing a reordered bookmark keeps its chosen position', () async {
    final session = BrowserSession(repository());
    await session.load();
    final bookmarks = [
      for (var i = 0; i < 3; i++)
        BrowserBookmark(
          url: Uri.parse('https://saved.example/$i'),
          title: 'Page $i',
        ),
    ];
    for (final bookmark in bookmarks) {
      session.bookmark(bookmark);
    }
    session.moveBookmark(bookmarks.last.url, bookmarks.first.url);
    final edited = BrowserBookmark(
      url: Uri.parse('https://edited.example'),
      title: 'Edited',
    );
    session.bookmark(edited, replacing: bookmarks.last.url);
    expect(session.bookmarks, [edited, bookmarks[0], bookmarks[1]]);
    await session.flush();
  });
  test(
    'pending tab destination is never restored before a document commits',
    () async {
      final session = BrowserSession(repository());
      await session.load();
      final requested = Uri.parse('https://example.com/sign-in?token=secret');
      session.openPending(requested);
      final id = session.activeId!;
      expect(session.activeTab?.url, isNull);
      expect(session.pendingUrl(id), requested);
      await session.flush();

      final restored = BrowserSession(repository());
      await restored.load();
      expect(restored.activeTab?.url, isNull);
      expect(restored.pendingUrl(id), isNull);

      session.update(id, url: requested);
      expect(session.pendingUrl(id), isNull);
      await session.flush();
      final committed = BrowserSession(repository());
      await committed.load();
      expect(committed.activeTab?.url.toString(), 'https://example.com');
    },
  );
  for (final keepBookmarks in [false, true]) {
    test(
      'clear while load is pending never restores history (keep bookmarks: $keepBookmarks)',
      () async {
        final initial = repository();
        await initial.save(
          [
            BrowserTab(
              id: 'old',
              url: Uri.parse('https://example.com/private'),
            ),
          ],
          [
            BrowserBookmark(
              url: Uri.parse('https://example.com/bookmark'),
              title: 'Saved',
            ),
          ],
          'old',
        );
        final delayed = _DelayedRepository(initial);
        final session = BrowserSession(delayed);
        final loading = session.load();
        await delayed.started.future;
        session.clear(keepBookmarks: keepBookmarks);
        delayed.resume.complete();
        await loading;
        await session.flush();
        expect(session.tabs, isEmpty);
        expect(session.activeId, isNull);
        expect(session.bookmarks.length, keepBookmarks ? 1 : 0);
        final stored = await initial.load();
        expect(stored.tabs, isEmpty);
        expect(stored.bookmarks.length, keepBookmarks ? 1 : 0);
      },
    );
  }

  test(
    'failed clear is reported and a retry persists the empty snapshot',
    () async {
      final persisted = repository();
      await persisted.save(
        [BrowserTab(id: 'old', url: Uri.parse('https://example.com/private'))],
        const [],
        'old',
      );
      final failing = _FailNextSaveRepository(persisted);
      final session = BrowserSession(failing);
      await session.load();
      failing.failNextSave = true;

      session.clear(keepBookmarks: false);

      await expectLater(session.flush(), throwsA(isA<StateError>()));
      expect((await persisted.load()).tabs, hasLength(1));
      expect(session.error, 'Browsing data could not be saved.');

      session.clear(keepBookmarks: false);
      await session.flush();

      expect((await persisted.load()).tabs, isEmpty);
      expect(session.error, isNull);
    },
  );

  test(
    'retiring supersedes a pending load, clears persistence, and gates writes',
    () async {
      final persisted = repository();
      await persisted.save(
        [BrowserTab(id: 'old', url: Uri.parse('https://example.com/private'))],
        [
          BrowserBookmark(
            url: Uri.parse('https://example.com/bookmark'),
            title: 'Saved',
          ),
        ],
        'old',
      );
      final delayed = _DelayedRepository(persisted);
      final session = BrowserSession(delayed);
      final loading = session.load();
      await delayed.started.future;
      var notifications = 0;
      session.addListener(() => notifications++);

      final retiring = session.retireForAppWipe();
      delayed.resume.complete();
      await Future.wait([loading, retiring]);

      expect(session.tabs, isEmpty);
      expect(session.bookmarks, isEmpty);
      expect(session.activeId, isNull);
      expect(session.isLoaded, isFalse);
      expect(notifications, greaterThan(0));
      expect(() => session.open(null), throwsStateError);
      session.bookmark(
        BrowserBookmark(
          url: Uri.parse('https://example.com/resurrected'),
          title: 'Resurrected',
        ),
      );
      expect((await persisted.load()).bookmarks, isEmpty);
    },
  );

  test(
    'retiring drains an active write before its final empty snapshot',
    () async {
      final persisted = repository();
      final delayed = _DelayedFirstSaveRepository(persisted);
      final session = BrowserSession(delayed);
      await session.load();
      session.open(Uri.parse('https://example.com/private'));
      await delayed.started.future;

      var completed = false;
      final retiring = session.retireForAppWipe();
      unawaited(
        retiring.then<void>((_) {
          completed = true;
        }),
      );
      await Future<void>.value();

      expect(completed, isFalse);
      session.update(session.activeId ?? 'old', title: 'Must not persist');

      delayed.resume.complete();
      await retiring;

      expect((await persisted.load()).tabs, isEmpty);
      expect(delayed.saveCount, 2);
    },
  );

  test('tab cap, close and undo, and clear keep-bookmarks behavior', () async {
    final session = BrowserSession(repository());
    await session.load();
    for (var i = 0; i < 20; i++) {
      session.open(Uri.parse('https://example.com/$i'));
    }
    expect(() => session.open(null), throwsStateError);
    final closed = session.close(session.activeId!)!;
    expect(session.tabs.length, 19);
    session.restore(closed);
    expect(session.activeId, closed.id);
    session.bookmark(
      BrowserBookmark(url: Uri.parse('https://example.com'), title: 'One'),
    );
    session.clear(keepBookmarks: true);
    await session.flush();
    expect(session.tabs, isEmpty);
    expect(session.activeId, isNull);
    expect(session.bookmarks, hasLength(1));
    session.clear(keepBookmarks: false);
    await session.flush();
    expect(session.bookmarks, isEmpty);
  });

  test('records written before site icons existed still load', () async {
    final storage = SecureWalletStorage(
      const FlutterSecureStorage(),
      MnemonicVault(),
    );
    await storage.storeBrowserMetadata(
      jsonEncode({
        'version': 1,
        'activeId': 'a',
        'tabs': [
          {'id': 'a', 'url': 'https://example.com'},
        ],
        'bookmarks': [
          {'url': 'https://example.com/art', 'title': 'Art'},
          {
            'url': 'https://example.com/bad',
            'title': 'Bad icon',
            'iconUrl': 'http://example.com/icon.png',
          },
        ],
      }),
    );
    final data = await BrowserRepository(storage).load();
    expect(data.tabs.single.iconUrl, isNull);
    expect(data.bookmarks, hasLength(2));
    expect(data.bookmarks.every((b) => b.iconUrl == null), isTrue);
  });

  test('site icons persist only as credential-free HTTPS URLs', () async {
    final session = BrowserSession(repository());
    await session.load();
    session.open(Uri.parse('https://example.com'));
    final plain = session.activeId!;
    session.update(plain, iconUrl: Uri.parse('https://cdn.example/icon.png'));
    session.open(Uri.parse('https://other.example'));
    final tokened = session.activeId!;
    session.update(
      tokened,
      iconUrl: Uri.parse('https://other.example/icon.png?session=secret'),
    );
    session.open(Uri.parse('https://third.example'));
    final rejected = session.activeId!;
    session.update(rejected, iconUrl: Uri.parse('http://third.example/i.png'));
    session.update(
      rejected,
      iconUrl: Uri.parse('https://user:pass@third.example/i.png'),
    );
    session.bookmark(
      BrowserBookmark(
        url: Uri.parse('https://example.com'),
        title: 'Example',
        iconUrl: Uri.parse('https://cdn.example/icon.png?v=2'),
      ),
    );
    expect(session.tabs[1].iconUrl?.query, 'session=secret');
    expect(session.tabs[2].iconUrl, isNull);
    await session.flush();

    final restored = BrowserSession(repository());
    await restored.load();
    final icons = {for (final t in restored.tabs) t.id: t.iconUrl?.toString()};
    expect(icons[plain], 'https://cdn.example/icon.png');
    expect(icons[tokened], isNull);
    expect(icons[rejected], isNull);
    expect(
      restored.bookmarks.single.iconUrl.toString(),
      'https://cdn.example/icon.png?v=2',
    );
  });

  test('navigating to another host drops the previous site icon', () async {
    final session = BrowserSession(repository());
    await session.load();
    session.open(Uri.parse('https://example.com'));
    final id = session.activeId!;
    final icon = Uri.parse('https://example.com/icon.png');
    session.update(id, iconUrl: icon);
    session.update(id, url: Uri.parse('https://example.com/other'));
    expect(session.activeTab!.iconUrl, icon);
    session.update(id, title: 'Page');
    expect(session.activeTab!.iconUrl, icon);
    session.update(id, url: Uri.parse('https://evil.example'));
    expect(session.activeTab!.iconUrl, isNull);
  });

  test('sites keep their last title and icon across restarts', () async {
    final session = BrowserSession(repository());
    await session.load();
    final icon = Uri.parse('https://example.com/icon.png');
    session.open(Uri.parse('https://example.com/art'));
    final id = session.activeId!;
    session.update(id, title: 'Example Art', iconUrl: icon);
    // The host placeholder and an empty title never replace a real title.
    session.update(id, title: 'example.com');
    session.update(id, title: '');
    session.open(Uri.parse('https://other.example'));
    session.update(
      session.activeId!,
      title: 'Other',
      iconUrl: Uri.parse('https://other.example/icon.png?session=secret'),
    );
    expect(
      session.site(Uri.parse('https://example.com/elsewhere'))?.title,
      'Example Art',
    );
    expect(session.site(Uri.parse('https://example.com:8443')), isNull);
    await session.flush();

    final restored = BrowserSession(repository());
    await restored.load();
    final site = restored.site(Uri.parse('https://example.com'))!;
    expect(site.title, 'Example Art');
    expect(site.iconUrl, icon);
    final other = restored.site(Uri.parse('https://other.example'))!;
    expect(other.title, 'Other');
    expect(other.iconUrl, isNull);
    // Tabs are stored without their titles and take their site's.
    expect(restored.tabs.map((t) => t.title), ['Example Art', 'Other']);
  });

  test(
    'closing tabs keeps remembered sites; clearing data drops them',
    () async {
      final session = BrowserSession(repository());
      await session.load();
      session.open(Uri.parse('https://example.com'));
      session.update(session.activeId!, title: 'Example');
      session.clear(keepBookmarks: true);
      expect(session.site(Uri.parse('https://example.com'))?.title, 'Example');
      await session.clearAndFlush(keepBookmarks: true);
      expect(session.site(Uri.parse('https://example.com')), isNull);
      final restored = BrowserSession(repository());
      await restored.load();
      expect(restored.site(Uri.parse('https://example.com')), isNull);
    },
  );

  test('a reported site icon reaches the bookmarks on that origin', () async {
    final session = BrowserSession(repository());
    await session.load();
    final page = BrowserBookmark(
      url: Uri.parse('https://example.com/art'),
      title: 'Art',
    );
    final other = BrowserBookmark(
      url: Uri.parse('https://other.example/'),
      title: 'Other',
      iconUrl: Uri.parse('https://other.example/icon.png'),
    );
    session
      ..bookmark(page)
      ..bookmark(other)
      ..open(Uri.parse('https://example.com/'));
    final icon = Uri.parse('https://example.com/icon-512.png');
    session.update(session.activeId!, iconUrl: icon);
    expect(session.bookmarks.map((b) => b.iconUrl), [icon, other.iconUrl]);
    expect(session.bookmarks.first.title, 'Art');
    await session.flush();
    final restored = BrowserSession(repository());
    await restored.load();
    expect(restored.bookmarks.first.iconUrl, icon);
  });

  test('a bookmark saved without an icon takes its site\'s on load', () async {
    final storage = SecureWalletStorage(
      const FlutterSecureStorage(),
      MnemonicVault(),
    );
    await storage.storeBrowserMetadata(
      jsonEncode({
        'version': 1,
        'activeId': null,
        'tabs': <Object>[],
        'bookmarks': [
          {'url': 'https://example.com/art', 'title': 'Art'},
          {'url': 'https://unseen.example/', 'title': 'Unseen'},
        ],
        'sites': [
          {
            'origin': 'https://example.com',
            'iconUrl': 'https://example.com/apple-touch-icon.png',
          },
        ],
      }),
    );
    final session = BrowserSession(BrowserRepository(storage));
    await session.load();
    expect(session.bookmarks.map((b) => b.iconUrl?.toString()), [
      'https://example.com/apple-touch-icon.png',
      null,
    ]);
  });

  test('a removed bookmark is restored where it was', () async {
    final session = BrowserSession(repository());
    await session.load();
    final bookmarks = [
      for (var i = 0; i < 3; i++)
        BrowserBookmark(
          url: Uri.parse('https://saved.example/$i'),
          title: 'Page $i',
        ),
    ];
    bookmarks.forEach(session.bookmark);
    final removed = session.removeBookmark(bookmarks[1].url)!;
    expect(removed.index, 1);
    expect(session.removeBookmark(bookmarks[1].url), isNull);
    expect(session.bookmarks, [bookmarks[0], bookmarks[2]]);
    session.restoreBookmark(removed);
    expect(session.bookmarks, bookmarks);
    // Saved again in the meantime: the undo leaves it alone.
    final again = session.removeBookmark(bookmarks[0].url)!;
    session.bookmark(bookmarks[0]);
    session.restoreBookmark(again);
    expect(session.bookmarks.where((b) => b.url == bookmarks[0].url), [
      bookmarks[0],
    ]);
  });

  test('remembered sites are capped, least recently seen first out', () async {
    final session = BrowserSession(repository());
    await session.load();
    session.open(null);
    final id = session.activeId!;
    for (var i = 0; i <= BrowserRepository.siteCapacity; i++) {
      session.update(id, url: Uri.https('site$i.example'), title: 'Site $i');
    }
    expect(session.site(Uri.https('site0.example')), isNull);
    expect(session.site(Uri.https('site1.example'))?.title, 'Site 1');
    await session.flush();
    final restored = BrowserSession(repository());
    await restored.load();
    expect(restored.site(Uri.https('site0.example')), isNull);
    expect(
      restored.site(Uri.https('site${BrowserRepository.siteCapacity}.example')),
      isNotNull,
    );
  });

  test('a malformed remembered site is skipped, not fatal', () async {
    final storage = SecureWalletStorage(
      const FlutterSecureStorage(),
      MnemonicVault(),
    );
    await storage.storeBrowserMetadata(
      jsonEncode({
        'version': 1,
        'activeId': null,
        'tabs': <Object>[],
        'bookmarks': <Object>[],
        'sites': [
          {'origin': 'http://plain.example', 'title': 'Plain'},
          {'origin': 42},
          'junk',
          {'origin': 'https://ok.example', 'title': 7, 'iconUrl': 'nope:x'},
          {'origin': 'https://good.example', 'title': 'Good'},
        ],
      }),
    );
    final data = await BrowserRepository(storage).load();
    expect(data.sites.map((s) => s.origin), [
      'https://ok.example',
      'https://good.example',
    ]);
    expect(data.sites.first.title, isEmpty);
    expect(data.sites.first.iconUrl, isNull);
  });

  test(
    'restored tabs have their drawn icons before the session loads',
    () async {
      final dir = Directory.systemTemp.createTempSync('site_icons');
      final defaultDirectory = BrowserSiteIcons.directory;
      BrowserSiteIcons.directory = () async => dir;
      addTearDown(() async {
        await BrowserSiteIcons.instance.clear();
        BrowserSiteIcons.directory = defaultDirectory;
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final icon = Uri.parse('https://example.com/icon.png');
      final bytes = Uint8List.fromList([
        ...[137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82],
        ...[0, 0, 0, 1, 0, 0, 0, 1],
      ]);
      final session = BrowserSession(repository());
      await session.load();
      session.open(Uri.parse('https://example.com'));
      session.update(session.activeId!, iconUrl: icon);
      BrowserSiteIcons.instance.put(icon, bytes);
      await session.flush();
      await BrowserSiteIcons.instance.settled;
      await BrowserSiteIcons.instance.clear();

      final restored = BrowserSession(repository());
      await restored.load();
      expect(BrowserSiteIcons.instance[restored.activeTab!.iconUrl], bytes);

      await restored.clearAndFlush(keepBookmarks: true);
      expect(dir.existsSync(), isFalse);
    },
  );

  test('thumbnails stay in memory and are dropped with their tab', () async {
    final storage = SecureWalletStorage(
      const FlutterSecureStorage(),
      MnemonicVault(),
    );
    final session = BrowserSession(BrowserRepository(storage));
    await session.load();
    var notified = 0;
    session.addListener(() => notified++);
    session.open(Uri.parse('https://example.com'));
    final first = session.activeId!;
    session.open(Uri.parse('https://other.example'));
    final second = session.activeId!;
    final bytes = Uint8List.fromList([137, 80, 78, 71]);
    final before = notified;
    session.setThumbnail(first, bytes);
    session.setThumbnail(second, bytes);
    session.setThumbnail('missing', bytes);
    expect(notified, greaterThan(before));
    expect(session.thumbnail(first), bytes);
    expect(session.thumbnail('missing'), isNull);
    await session.flush();
    final saved = jsonDecode((await storage.loadBrowserMetadata())!) as Map;
    for (final tab in saved['tabs'] as List) {
      expect((tab as Map).keys, unorderedEquals(['id', 'url']));
    }

    session.close(first);
    expect(session.thumbnail(first), isNull);
    session.removeThumbnail(second);
    expect(session.thumbnail(second), isNull);
    session.setThumbnail(second, bytes);
    session.clearThumbnails();
    expect(session.thumbnail(second), isNull);

    session.setThumbnail(second, bytes);
    session.clear(keepBookmarks: true);
    expect(session.thumbnail(second), isNull);

    session.open(Uri.parse('https://example.com'));
    final third = session.activeId!;
    session.setThumbnail(third, bytes);
    await session.retireForAppWipe();
    expect(session.thumbnail(third), isNull);
  });
}

class _DelayedRepository implements BrowserRepository {
  _DelayedRepository(this.delegate);
  final BrowserRepository delegate;
  final started = Completer<void>();
  final resume = Completer<void>();
  @override
  Future<BrowserMetadata> load() async {
    final snapshot = await delegate.load();
    started.complete();
    await resume.future;
    return snapshot;
  }

  @override
  Future<void> save(
    List<BrowserTab> tabs,
    List<BrowserBookmark> bookmarks,
    String? activeId, {
    List<BrowserSiteInfo> sites = const [],
  }) => delegate.save(tabs, bookmarks, activeId, sites: sites);
}

class _FailNextSaveRepository implements BrowserRepository {
  _FailNextSaveRepository(this.delegate);

  final BrowserRepository delegate;
  bool failNextSave = false;

  @override
  Future<BrowserMetadata> load() => delegate.load();

  @override
  Future<void> save(
    List<BrowserTab> tabs,
    List<BrowserBookmark> bookmarks,
    String? activeId, {
    List<BrowserSiteInfo> sites = const [],
  }) {
    if (failNextSave) {
      failNextSave = false;
      return Future.error(StateError('write failed'));
    }
    return delegate.save(tabs, bookmarks, activeId, sites: sites);
  }
}

class _DelayedFirstSaveRepository implements BrowserRepository {
  _DelayedFirstSaveRepository(this.delegate);

  final BrowserRepository delegate;
  final started = Completer<void>();
  final resume = Completer<void>();
  int saveCount = 0;

  @override
  Future<BrowserMetadata> load() => delegate.load();

  @override
  Future<void> save(
    List<BrowserTab> tabs,
    List<BrowserBookmark> bookmarks,
    String? activeId, {
    List<BrowserSiteInfo> sites = const [],
  }) async {
    saveCount++;
    if (saveCount == 1) {
      started.complete();
      await resume.future;
    }
    await delegate.save(tabs, bookmarks, activeId, sites: sites);
  }
}
