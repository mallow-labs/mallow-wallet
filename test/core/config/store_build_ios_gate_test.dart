import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/store_build.dart';

/// Pins the iOS store gates to the defines the iOS release lane passes.
///
/// The lane runs this file under `IOS_STORE_DART_DEFINES` — the same string it
/// appends to `flutter build ipa` — right before the archive. A plain
/// `flutter test` runs it with the defines unset. Each case reads its raw
/// define itself so it can tell the two apart and assert the right thing in
/// each:
///
/// * define absent  → the flag must be `true` (the documented default; Android
///   release builds rely on it);
/// * define present → the flag must follow it, which fails the moment the key
///   in `store_build.dart` is renamed or the derivation stops reading it.
///
/// What it cannot catch is the lane forgetting to run it or to pass the
/// defines to the build — both read the same Ruby constant, which is the tie.
void main() {
  /// One case per platform-scoped flag. [name] is the `--dart-define` key and
  /// [flag] the compile-time constant that must track it.
  void expectFollowsDefine(String name, String raw, bool flag) {
    if (raw.isEmpty) {
      expect(
        flag,
        isTrue,
        reason:
            'With no define $name must be shown: that is the Android release '
            'value, and the iOS lane is the only build that opts out.',
      );
    } else {
      expect(
        flag,
        raw == 'true',
        reason:
            '$name=$raw was passed but the flag did not follow it — the key '
            'it reads no longer matches the lane.',
      );
    }
  }

  test('kShowNftCommerce follows SHOW_NFT_COMMERCE and defaults to shown', () {
    expectFollowsDefine(
      'SHOW_NFT_COMMERCE',
      const String.fromEnvironment('SHOW_NFT_COMMERCE'),
      kShowNftCommerce,
    );
  });

  test('kShowSwap follows SHOW_SWAP and defaults to shown', () {
    expectFollowsDefine(
      'SHOW_SWAP',
      const String.fromEnvironment('SHOW_SWAP'),
      kShowSwap,
    );
  });
}
