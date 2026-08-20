import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Six screens read this enum: the portfolio, the profile artwork tabs, the
// collection and curation screens, the group drilldown, and the search
// drilldown. Four of them keep the mode in local widget state rather than a
// bloc, so the cycle order and the icon mapping are the only shared contract
// between them — pinning them here is what keeps the toggle from meaning
// different things on different screens.
void main() {
  group('ArtworkViewMode.next', () {
    test('cycles masonry -> detail -> grid and wraps', () {
      expect(ArtworkViewMode.masonry.next, ArtworkViewMode.detail);
      expect(ArtworkViewMode.detail.next, ArtworkViewMode.grid);
      expect(ArtworkViewMode.grid.next, ArtworkViewMode.masonry);
    });

    test('returns to the starting mode in exactly three taps', () {
      var mode = ArtworkViewMode.masonry;
      for (var i = 0; i < 3; i++) {
        mode = mode.next;
      }
      expect(mode, ArtworkViewMode.masonry);
    });
  });

  group('ArtworkViewMode.iconAsset', () {
    test('maps each mode to its toggle icon', () {
      expect(ArtworkViewMode.masonry.iconAsset, 'assets/icons/masonry.svg');
      // The icon the Curation screen already used for its detailed mode.
      expect(ArtworkViewMode.detail.iconAsset, 'assets/icons/float.svg');
      expect(ArtworkViewMode.grid.iconAsset, 'assets/icons/grid.svg');
    });

    test('every mode has a distinct icon', () {
      final icons = ArtworkViewMode.values.map((m) => m.iconAsset).toSet();
      expect(icons, hasLength(ArtworkViewMode.values.length));
    });
  });

  group('ArtworkViewMode.fromName', () {
    test('round-trips every mode through its persisted name', () {
      for (final mode in ArtworkViewMode.values) {
        expect(ArtworkViewMode.fromName(mode.name), mode);
      }
    });

    test('falls back to masonry on an unrecognised name', () {
      // A downgrade, or a value written by a future mode, must not throw on a
      // screen that is only trying to lay out a list.
      expect(ArtworkViewMode.fromName('exhibition'), ArtworkViewMode.masonry);
    });
  });

  group('loadArtworkViewMode', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('defaults to masonry with nothing stored', () async {
      expect(await loadArtworkViewMode(), ArtworkViewMode.masonry);
    });

    test('reads the stored mode', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        artworkViewModePrefsKey: 'grid',
      });
      expect(await loadArtworkViewMode(), ArtworkViewMode.grid);
    });

    // Before the split the artwork layout lived in two values — a masonry bool
    // plus a list/grid string under the key that now belongs to art-groups.
    // Dropping the migration would silently reset every existing user.
    group('migrates the pre-split pair', () {
      test('masonry-true wins regardless of the list/grid string', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'portfolio_prefers_masonry': true,
          'portfolio_view_mode': 'list',
        });
        expect(await loadArtworkViewMode(), ArtworkViewMode.masonry);
      });

      test('legacy list becomes detail, the layout that replaced it', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'portfolio_prefers_masonry': false,
          'portfolio_view_mode': 'list',
        });
        expect(await loadArtworkViewMode(), ArtworkViewMode.detail);
      });

      test('legacy grid stays grid', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'portfolio_prefers_masonry': false,
          'portfolio_view_mode': 'grid',
        });
        expect(await loadArtworkViewMode(), ArtworkViewMode.grid);
      });

      test('a stored new-key value wins over the legacy pair', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          artworkViewModePrefsKey: 'masonry',
          'portfolio_prefers_masonry': false,
          'portfolio_view_mode': 'grid',
        });
        expect(await loadArtworkViewMode(), ArtworkViewMode.masonry);
      });
    });
  });

  // The group layout must never be reachable through the artwork key or the
  // reverse — that overlap is exactly what the split removed.
  group('the two layouts persist independently', () {
    test('saving one leaves the other unset', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await saveArtworkViewMode(ArtworkViewMode.detail);
      var prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getString(artworkViewModePrefsKey), 'detail');
      expect(prefs.getString(groupViewModePrefsKey), isNull);

      await saveGroupViewMode(PortfolioViewMode.list);
      prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getString(groupViewModePrefsKey), 'list');
      expect(
        prefs.getString(artworkViewModePrefsKey),
        'detail',
        reason: 'the group write must not clobber the artwork layout',
      );
      expect(await loadArtworkViewMode(), ArtworkViewMode.detail);
      expect(await loadGroupViewMode(), PortfolioViewMode.list);
    });
  });
}
