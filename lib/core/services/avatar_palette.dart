/// Canonical colour palette for auto-generated **Account** avatars.
///
/// DiceBear's `identicon` foreground is normally picked from its 19-colour
/// default palette by hashing the seed. We pin it instead via the `rowColor`
/// query param so every account avatar is one of six brand hues — these six are
/// evenly spaced across that 19-colour list (indices 0, 4, 7, 11, 14, 18):
/// red, olive, green, blue, purple, rose.
///
/// The colour is derived **from the seed** (not stored on the account) so that
/// every render site — the drawer, the home header, the picker grid — recreates
/// the same colour from just the persisted `avatarSeed` UUID. [avatarColorIndex]
/// is therefore a hard contract: changing it would silently recolour every
/// existing account avatar.
library;

/// The six avatar hues, as DiceBear `rowColor` hex strings (no leading `#`).
const List<String> kAvatarPalette = [
  'e45e4d', // red
  '9b9312', // olive
  '15a876', // green
  '1499da', // blue
  '9975ea', // purple
  'e25a75', // rose
];

/// Deterministic 32-bit FNV-1a hash of [seed].
///
/// Uses an explicit hash rather than [String.hashCode]: the latter is not
/// guaranteed stable across isolates, runs, or platforms, and values derived
/// from this (an account's avatar colour, an avatar's cache filename)
/// permanently key on-disk/visual state.
int avatarSeedHash(String seed) {
  var hash = 0x811c9dc5;
  for (final unit in seed.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// Deterministic `seed → palette index` in `[0, kAvatarPalette.length)`.
int avatarColorIndex(String seed) =>
    avatarSeedHash(seed) % kAvatarPalette.length;

/// The DiceBear `rowColor` (hex, no `#`) for [seed].
String avatarRowColor(String seed) => kAvatarPalette[avatarColorIndex(seed)];
