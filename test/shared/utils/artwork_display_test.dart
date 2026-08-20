import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/artwork_display.dart';

/// [formatArtworkName] is responsible for keeping printed editions
/// distinguishable from their master in every UI surface that renders the
/// artwork title. Misformatting here is visible everywhere.
void main() {
  group('formatArtworkName', () {
    test('returns the bare name when editionNumber is null', () {
      expect(formatArtworkName(name: 'My Artwork'), 'My Artwork');
    });

    test('appends "#N" suffix when editionNumber is provided', () {
      expect(
        formatArtworkName(name: 'My Artwork', editionNumber: 5),
        'My Artwork #5',
      );
    });

    test('handles edition #1 (first print) correctly', () {
      expect(
        formatArtworkName(name: 'Edition Genesis', editionNumber: 1),
        'Edition Genesis #1',
      );
    });

    test('handles large edition numbers without altering formatting', () {
      expect(
        formatArtworkName(name: 'Mass Edition', editionNumber: 9999),
        'Mass Edition #9999',
      );
    });

    test('preserves empty name (does not synthesize a default)', () {
      expect(formatArtworkName(name: '', editionNumber: 3), ' #3');
    });

    test('edition 0 still appends "#0" — does not treat 0 as absent', () {
      // We have no production data with edition 0, but the contract is "null
      // means no edition", not "falsy means no edition". This pins the
      // boundary so a future refactor can't quietly change it.
      expect(formatArtworkName(name: 'Zeroth', editionNumber: 0), 'Zeroth #0');
    });
  });
}
