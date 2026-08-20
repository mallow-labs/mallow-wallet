import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/features/cast/models/cast_display_type.dart';
import 'package:mallow_wallet/features/cast/models/cast_queue.dart';
import 'package:mallow_wallet/features/search/models/recently_viewed_item.dart';
import 'package:mallow_wallet/features/search/models/search_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<PreferencesService> freshPrefs([
    Map<String, Object> initial = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(initial);
    return PreferencesService.create();
  }

  group('defaults', () {
    test('returns sensible defaults when no values are stored', () async {
      final prefs = await freshPrefs();
      expect(prefs.language, 'en_US');
      expect(prefs.explorer, 'solscan');
      expect(prefs.ethExplorer, 'etherscan');
      expect(prefs.currency, 'USD');
      expect(prefs.themeMode, ThemeMode.dark);
      expect(prefs.pushNotificationsEnabled, isTrue);
      expect(prefs.hasPromptedForPushPermission, isFalse);
      expect(prefs.recentSearches, isEmpty);
      expect(prefs.castIntervalSeconds, 30);
      expect(prefs.castShowCaption, isTrue);
      expect(prefs.castShowQr, isTrue);
      expect(prefs.castShuffle, isFalse);
      expect(prefs.castRepeatMode, CastRepeatMode.all);
      expect(prefs.castDisplayType, CastDisplayType.fillScreen);
      expect(prefs.castLastDeviceId, isNull);
      expect(prefs.compromisedDeviceAcknowledged, isFalse);
      expect(prefs.profileGroupOrder, isNull);
    });
  });

  group('theme', () {
    test('themeNotifier is seeded from stored value', () async {
      final prefs = await freshPrefs({'pref_theme': 'dark'});
      expect(prefs.themeMode, ThemeMode.dark);
      expect(prefs.themeNotifier.value, ThemeMode.dark);
    });

    test('setThemeMode updates both storage and notifier', () async {
      final prefs = await freshPrefs();
      var notified = 0;
      prefs.themeNotifier.addListener(() => notified++);
      await prefs.setThemeMode(ThemeMode.light);
      expect(prefs.themeMode, ThemeMode.light);
      expect(notified, 1);
    });

    test('unknown stored theme falls back to the default', () async {
      // Forward-compat: a future build might add new ThemeMode values; an
      // older client must not crash trying to load them.
      final prefs = await freshPrefs({'pref_theme': 'midnight'});
      expect(prefs.themeMode, ThemeMode.dark);
    });
  });

  group('recent searches', () {
    test('inserts at front and trims to max', () async {
      final prefs = await freshPrefs();
      await prefs.saveRecentSearch('one');
      await prefs.saveRecentSearch('two');
      await prefs.saveRecentSearch('three');
      await prefs.saveRecentSearch('four');
      await prefs.saveRecentSearch('five');
      await prefs.saveRecentSearch('six');
      expect(prefs.recentSearches, ['six', 'five', 'four', 'three', 'two']);
    });

    test('ignores empty/whitespace', () async {
      final prefs = await freshPrefs();
      await prefs.saveRecentSearch('   ');
      await prefs.saveRecentSearch('');
      expect(prefs.recentSearches, isEmpty);
    });

    test('moves an exact duplicate to the front (case-insensitive)', () async {
      final prefs = await freshPrefs();
      await prefs.saveRecentSearch('Alpha');
      await prefs.saveRecentSearch('Beta');
      await prefs.saveRecentSearch('alpha');
      expect(prefs.recentSearches, ['alpha', 'Beta']);
    });

    test('keeps distinct terms that share a prefix', () async {
      // "mal" and "mallow" are different queries — both stay in history.
      // Dedup is exact (case-insensitive), not prefix-based, so re-searching
      // only moves the exact match to the front.
      final prefs = await freshPrefs();
      await prefs.saveRecentSearch('mal');
      await prefs.saveRecentSearch('other');
      await prefs.saveRecentSearch('mallow');
      expect(prefs.recentSearches, ['mallow', 'other', 'mal']);
    });

    test('trims surrounding whitespace before saving', () async {
      final prefs = await freshPrefs();
      await prefs.saveRecentSearch('  jeans  ');
      expect(prefs.recentSearches, ['jeans']);
    });

    test('clearRecentSearches empties the list', () async {
      final prefs = await freshPrefs();
      await prefs.saveRecentSearch('a');
      await prefs.clearRecentSearches();
      expect(prefs.recentSearches, isEmpty);
    });
  });

  group('recently viewed', () {
    RecentlyViewedItem artwork(String mint) => RecentlyViewedItem.artwork(
      SearchArtworkResult(title: 'Art $mint', mintAccount: mint),
    );

    test('inserts most-recent-first and caps at 5', () async {
      // The landing shows the last few opened items newest-first; opening a
      // sixth must evict the oldest, not grow without bound.
      final prefs = await freshPrefs();
      for (var i = 1; i <= 6; i++) {
        await prefs.saveRecentlyViewed(artwork('mint$i'));
      }
      final keys = prefs.recentlyViewed.map((e) => e.artwork!.mintAccount);
      expect(keys, ['mint6', 'mint5', 'mint4', 'mint3', 'mint2']);
    });

    test(
      're-viewing the same content promotes it without duplicating',
      () async {
        // Re-opening artwork already in the list must move it to the front and
        // leave a single entry — not stack a second copy.
        final prefs = await freshPrefs();
        await prefs.saveRecentlyViewed(artwork('a'));
        await prefs.saveRecentlyViewed(artwork('b'));
        await prefs.saveRecentlyViewed(artwork('a'));
        final keys = prefs.recentlyViewed.map((e) => e.artwork!.mintAccount);
        expect(keys, ['a', 'b']);
      },
    );

    test(
      'dedupe is scoped by type, so a token and artwork can share an id',
      () async {
        // dedupeKey is namespaced by content type — a token whose mint equals an
        // artwork mint must not evict the artwork.
        final prefs = await freshPrefs();
        await prefs.saveRecentlyViewed(artwork('shared-id'));
        await prefs.saveRecentlyViewed(
          RecentlyViewedItem.token(
            const SearchTokenResult(
              mintAddress: 'shared-id',
              name: 'Token',
              symbol: 'TKN',
            ),
          ),
        );
        expect(prefs.recentlyViewed, hasLength(2));
      },
    );

    test(
      'round-trips every content type through storage with full fidelity',
      () async {
        final prefs = await freshPrefs();
        await prefs.saveRecentlyViewed(
          RecentlyViewedItem.user(
            const SearchUserResult(
              username: 'alice',
              address: '0xabc',
              avatarUrl: 'a.png',
              isVerified: true,
              isAdmin: true,
            ),
          ),
        );
        await prefs.saveRecentlyViewed(
          RecentlyViewedItem.collection(
            const SearchCollectionResult(
              name: 'Col',
              slug: 'col-slug',
              curatorUsername: 'curator',
              curatorAddress: '0xdef',
              thumbnailUrl: 't.png',
            ),
          ),
        );
        await prefs.saveRecentlyViewed(
          RecentlyViewedItem.curation(
            const SearchCurationResult(
              id: 'cur-1',
              name: 'Cur',
              artworkCount: 3,
              thumbnailUrls: ['x.png'],
              ownerAddress: '0xowner',
              ownerUsername: 'owner',
            ),
          ),
        );
        await prefs.saveRecentlyViewed(
          RecentlyViewedItem.token(
            const SearchTokenResult(
              mintAddress: 'mint',
              name: 'Solana',
              symbol: 'SOL',
              iconUrl: 'i.png',
              usdPrice: 1.5,
              priceChange24h: -2.25,
            ),
          ),
        );

        // Re-read through a fresh service over the same mock store so the
        // assertion exercises the decode path, not the in-memory objects.
        final reloaded = (await PreferencesService.create()).recentlyViewed;

        final token = reloaded[0].token!;
        expect(token.mintAddress, 'mint');
        expect(token.symbol, 'SOL');
        expect(token.usdPrice, 1.5);
        expect(token.priceChange24h, -2.25);

        final curation = reloaded[1].curation!;
        expect(curation.id, 'cur-1');
        expect(curation.artworkCount, 3);
        expect(curation.thumbnailUrls, ['x.png']);
        expect(curation.ownerAddress, '0xowner');

        final collection = reloaded[2].collection!;
        expect(collection.slug, 'col-slug');
        expect(collection.curatorUsername, 'curator');

        final user = reloaded[3].user!;
        expect(user.username, 'alice');
        expect(user.isAdmin, isTrue);
        expect(user.isVerified, isTrue);
      },
    );

    test(
      'skips malformed and unknown-type entries instead of crashing',
      () async {
        // Forward-compat: a corrupt row or a type written by a newer build must
        // be dropped, leaving the readable entries intact.
        final good = artwork('ok').encoded;
        final prefs = await freshPrefs({
          'pref_recently_viewed': <String>[
            'not json',
            '{"type":"hologram","hologram":{}}',
            good,
          ],
        });
        final items = prefs.recentlyViewed;
        expect(items, hasLength(1));
        expect(items.single.artwork!.mintAccount, 'ok');
      },
    );

    test('clearRecentlyViewed empties the list', () async {
      final prefs = await freshPrefs();
      await prefs.saveRecentlyViewed(artwork('a'));
      await prefs.clearRecentlyViewed();
      expect(prefs.recentlyViewed, isEmpty);
    });
  });

  group('recent send addresses', () {
    test('inserts at front, dedupes, and caps at 10', () async {
      // The send sheet's Recent list shows the most recent recipient first;
      // re-sending to a known address must promote it, not duplicate it.
      final prefs = await freshPrefs();
      for (var i = 0; i < 11; i++) {
        await prefs.saveRecentSendAddress('address$i');
      }
      await prefs.saveRecentSendAddress('address5');
      expect(prefs.recentSendAddresses.length, 10);
      expect(prefs.recentSendAddresses.first, 'address5');
      expect(prefs.recentSendAddresses.where((a) => a == 'address5').length, 1);
      // address0 fell off the end when address10 was added.
      expect(prefs.recentSendAddresses, isNot(contains('address0')));
    });

    test('ignores empty/whitespace and trims before saving', () async {
      final prefs = await freshPrefs();
      await prefs.saveRecentSendAddress('   ');
      await prefs.saveRecentSendAddress('  abc  ');
      expect(prefs.recentSendAddresses, ['abc']);
    });
  });

  group('per-recipient send counts', () {
    test('counts survive past the recents cap', () async {
      // The whole reason this is a separate store: recentSendAddresses holds
      // 10, so deriving "have I sent here before?" from it would report the
      // 11th-oldest recipient as never-seen — exactly backwards for the
      // confirm step's label.
      final prefs = await freshPrefs();
      await prefs.incrementSendCount('address0');
      for (var i = 1; i < 12; i++) {
        await prefs.saveRecentSendAddress('address$i');
      }
      expect(prefs.recentSendAddresses, isNot(contains('address0')));
      expect(prefs.sendCountFor('address0'), 1);
    });

    test(
      'an unseen recipient counts zero and accumulates from there',
      () async {
        final prefs = await freshPrefs();
        expect(prefs.sendCountFor('abc'), 0);
        await prefs.incrementSendCount('abc');
        await prefs.incrementSendCount('abc');
        expect(prefs.sendCountFor('abc'), 2);
      },
    );

    test('an EVM recipient shares one counter across address casings', () async {
      // web3dart hands back EIP-55 checksummed addresses while other surfaces
      // carry the lowercase form; they are the same account, so a send through
      // one must not read as a first-time send through the other.
      final prefs = await freshPrefs();
      await prefs.incrementSendCount(
        '0xAbC0000000000000000000000000000000000123',
      );
      expect(
        prefs.sendCountFor('0xabc0000000000000000000000000000000000123'),
        1,
      );
    });

    test('a blank address is not counted', () async {
      final prefs = await freshPrefs();
      await prefs.incrementSendCount('   ');
      expect(prefs.sendCountFor('   '), 0);
    });

    test('the store is bounded and evicts least-recently-sent-to', () async {
      // One key per recipient forever would grow without limit on a device that
      // airdrops or batch-transfers, and SharedPreferences is parsed whole at
      // startup. The cap is generous, so what it drops must be the oldest
      // recipient — never the one just sent to.
      final prefs = await freshPrefs();
      await prefs.incrementSendCount('oldest');
      for (var i = 0; i < 500; i++) {
        await prefs.incrementSendCount('address$i');
      }
      expect(prefs.sendCountFor('oldest'), 0);
      expect(prefs.sendCountFor('address0'), 1);
      expect(prefs.sendCountFor('address499'), 1);
    });
  });

  group('cast repeat mode', () {
    test('roundtrips each enum value', () async {
      final prefs = await freshPrefs();
      for (final mode in CastRepeatMode.values) {
        await prefs.setCastRepeatMode(mode);
        expect(prefs.castRepeatMode, mode);
      }
    });

    test('unknown stored value falls back to repeat-all', () async {
      // Default must match CastQueue's documented default so a corrupted
      // pref doesn't suddenly change playback behavior.
      final prefs = await freshPrefs({'pref_cast_repeat_mode': 'reverse'});
      expect(prefs.castRepeatMode, CastRepeatMode.all);
    });
  });

  group('cast display type', () {
    test('roundtrips each enum value', () async {
      final prefs = await freshPrefs();
      for (final type in CastDisplayType.values) {
        await prefs.setCastDisplayType(type);
        expect(prefs.castDisplayType, type);
      }
    });

    test('unknown stored value falls back to fillScreen', () async {
      final prefs = await freshPrefs({'pref_cast_display_type': 'pip'});
      expect(prefs.castDisplayType, CastDisplayType.fillScreen);
    });
  });

  group('simple string/bool/int prefs roundtrip', () {
    test('language/explorer/currency setters persist', () async {
      final prefs = await freshPrefs();
      await prefs.setLanguage('fr_FR');
      await prefs.setExplorer('solanafm');
      await prefs.setEthExplorer('blockscout');
      await prefs.setCurrency('EUR');
      expect(prefs.language, 'fr_FR');
      expect(prefs.explorer, 'solanafm');
      expect(prefs.ethExplorer, 'blockscout');
      expect(prefs.currency, 'EUR');
    });

    test('push notification toggles persist independently', () async {
      final prefs = await freshPrefs();
      await prefs.setPushNotificationsEnabled(false);
      await prefs.setHasPromptedForPushPermission(true);
      expect(prefs.pushNotificationsEnabled, isFalse);
      expect(prefs.hasPromptedForPushPermission, isTrue);
    });

    test('profile group order persists', () async {
      final prefs = await freshPrefs();
      await prefs.setProfileGroupOrder(['a', 'b']);
      expect(prefs.profileGroupOrder, ['a', 'b']);
    });

    test('cast interval/show toggles persist', () async {
      final prefs = await freshPrefs();
      await prefs.setCastIntervalSeconds(15);
      await prefs.setCastShowCaption(false);
      await prefs.setCastShowQr(false);
      await prefs.setCastShuffle(true);
      await prefs.setCastLastDeviceId('chromecast-1');
      expect(prefs.castIntervalSeconds, 15);
      expect(prefs.castShowCaption, isFalse);
      expect(prefs.castShowQr, isFalse);
      expect(prefs.castShuffle, isTrue);
      expect(prefs.castLastDeviceId, 'chromecast-1');
    });

    test('compromisedDeviceAcknowledged persists', () async {
      final prefs = await freshPrefs();
      await prefs.setCompromisedDeviceAcknowledged(true);
      expect(prefs.compromisedDeviceAcknowledged, isTrue);
    });
  });

  group('clearAll', () {
    test('erases identity-bearing history so it cannot leak to the next '
        'person who onboards', () async {
      final prefs = await freshPrefs();
      await prefs.saveRecentSendAddress('So1anaRecipient111');
      await prefs.incrementSendCount('So1anaRecipient111');
      await prefs.saveRecentSearch('my alias');
      await prefs.saveRecentlyViewed(
        RecentlyViewedItem.artwork(
          const SearchArtworkResult(title: 'Art', mintAccount: 'mint1'),
        ),
      );

      await prefs.clearAll();

      // The privacy leak this method exists to close: a reset then re-onboard
      // with a different seed phrase must not suggest the old wallet's
      // recipients (or reveal what the old identity searched for / viewed).
      expect(prefs.recentSendAddresses, isEmpty);
      expect(prefs.sendCountFor('So1anaRecipient111'), 0);
      expect(prefs.recentSearches, isEmpty);
      expect(prefs.recentlyViewed, isEmpty);
    });

    test(
      'erases device-local settings so "Reset app" is a true reset',
      () async {
        final prefs = await freshPrefs();
        await prefs.setExplorer('solanafm');
        await prefs.setCurrency('EUR');
        await prefs.setAnalyticsOptOut(true);
        await prefs.setPushNotificationsEnabled(false);
        await prefs.setNextAccountNumber(7);
        await prefs.setPriorityFeeLamports(50000);

        await prefs.clearAll();

        expect(prefs.explorer, 'solscan');
        expect(prefs.currency, 'USD');
        expect(prefs.analyticsOptOut, isFalse);
        expect(prefs.pushNotificationsEnabled, isTrue);
        expect(prefs.rawNextAccountNumber, isNull);
        expect(prefs.priorityFeeLamports, isNull);
      },
    );

    test('resets the live notifiers, not just the store', () async {
      // Widgets listen to these; leaving them holding the old values would
      // show the wiped theme / NSFW setting until the next app launch.
      final prefs = await freshPrefs();
      await prefs.setThemeMode(ThemeMode.light);
      await prefs.setShowNsfw(true);

      await prefs.clearAll();

      expect(prefs.themeNotifier.value, ThemeMode.dark);
      expect(prefs.themeMode, ThemeMode.dark);
      expect(prefs.showNsfwNotifier.value, isFalse);
      expect(prefs.showNsfw, isFalse);
    });
  });
}
