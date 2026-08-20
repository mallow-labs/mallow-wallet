import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/avatar_palette.dart';

void main() {
  test('palette is the six brand hues, evenly spaced across DiceBear 19', () {
    // Why: the picker promises an even spread of "the main 6 colours"; these are
    // indices 0,4,7,11,14,18 of identicon's default 19-colour list. Changing
    // them silently recolours the whole avatar system.
    expect(kAvatarPalette, [
      'e45e4d',
      '9b9312',
      '15a876',
      '1499da',
      '9975ea',
      'e25a75',
    ]);
  });

  test('avatarColorIndex is deterministic and in range', () {
    // Why: the colour is derived from the seed (not stored), so the SAME seed
    // must map to the SAME colour on every device/run or an account's avatar
    // would change colour between render sites.
    for (final seed in ['abc', 'a-uuid-1234', '', 'ZZZ']) {
      final index = avatarColorIndex(seed);
      expect(index, inInclusiveRange(0, kAvatarPalette.length - 1));
      expect(avatarColorIndex(seed), index); // stable across calls
    }
    expect(avatarRowColor('abc'), kAvatarPalette[avatarColorIndex('abc')]);
  });
}
