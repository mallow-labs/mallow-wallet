import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/features/curations/services/curation_attribution_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The store is the only link between "the buyer browsed this artwork inside a
/// curation" and the curator's referral credit — the backend has no other
/// source for it. So each rule here protects money, not tidiness: a stale or
/// wrong slug credits the wrong curator, and a dropped one silently pays
/// nobody.
void main() {
  const mintA = 'MintAAA1111111111111111111111111111111111111';
  const mintB = 'MintBBB1111111111111111111111111111111111111';

  late PreferencesService prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await PreferencesService.create();
  });

  /// A store whose clock is pinned to [now], so TTL behaviour is exercised
  /// without waiting out the 7-day window.
  CurationAttributionStore storeAt(DateTime now) =>
      CurationAttributionStore(prefs)..clock = (() => now);

  test('a recorded view is returned for that mint and no other', () {
    final store = storeAt(DateTime(2026, 8, 11))
      ..record(mintAccount: mintA, shareSlug: 'ABCDEFGH');

    expect(store.shareSlugFor(mintA), 'ABCDEFGH');
    expect(store.shareSlugFor(mintB), isNull);
  });

  test('last touch wins — a later curation replaces the earlier one', () {
    // Browsing the same artwork from a second curation moves the credit: the
    // curation that actually drove the purchase is the most recent one.
    final store = storeAt(DateTime(2026, 8, 11))
      ..record(mintAccount: mintA, shareSlug: 'AAAAAAAA')
      ..record(mintAccount: mintA, shareSlug: 'BBBBBBBB');

    expect(store.shareSlugFor(mintA), 'BBBBBBBB');
  });

  test('a view older than the TTL is not attributable', () {
    final viewedAt = DateTime(2026, 8, 11);
    final store = storeAt(viewedAt)
      ..record(mintAccount: mintA, shareSlug: 'ABCDEFGH');

    // One tick inside the window still credits…
    store.clock = () =>
        viewedAt.add(CurationAttributionStore.ttl - const Duration(seconds: 1));
    expect(store.shareSlugFor(mintA), 'ABCDEFGH');

    // …and at the boundary the link is gone, not merely unreported: a buy
    // weeks after the browse was not driven by the curation.
    store.clock = () => viewedAt.add(CurationAttributionStore.ttl);
    expect(store.shareSlugFor(mintA), isNull);
    expect(store.shareSlugFor(mintA), isNull);
  });

  test('the map is capped, evicting the oldest view first', () {
    final store = storeAt(DateTime(2026, 8, 11));
    // One past the cap: the very first mint recorded must be the one dropped.
    for (var i = 0; i <= CurationAttributionStore.maxEntries; i++) {
      store.record(mintAccount: 'mint-$i', shareSlug: 'SLUGAAA$i');
    }

    expect(store.shareSlugFor('mint-0'), isNull);
    expect(store.shareSlugFor('mint-1'), isNotNull);
    expect(
      store.shareSlugFor('mint-${CurationAttributionStore.maxEntries}'),
      isNotNull,
    );
  });

  test('records survive a restart', () async {
    storeAt(DateTime(2026, 8, 11))
      ..record(mintAccount: mintA, shareSlug: 'ABCDEFGH')
      // A purchase usually happens in a later session than the browse, so the
      // whole feature depends on the blob surviving process death.
      ..record(mintAccount: mintB, shareSlug: 'IJKLMNOP');
    await Future<void>.delayed(Duration.zero);

    final revived = storeAt(DateTime(2026, 8, 12));
    expect(revived.shareSlugFor(mintA), 'ABCDEFGH');
    expect(revived.shareSlugFor(mintB), 'IJKLMNOP');
  });

  test('the app-reset preference wipe clears every recorded view', () async {
    storeAt(DateTime(2026, 8, 11))
      ..record(mintAccount: mintA, shareSlug: 'ABCDEFGH')
      ..record(mintAccount: mintB, shareSlug: 'IJKLMNOP');
    await Future<void>.delayed(Duration.zero);

    // Browsing history is per-identity: a reset onboards a new user, who must
    // not inherit the previous one's attributions.
    await prefs.clearAll();

    final revived = storeAt(DateTime(2026, 8, 11));
    expect(revived.shareSlugFor(mintA), isNull);
    expect(revived.shareSlugFor(mintB), isNull);
  });

  test('a corrupt blob reads as empty instead of throwing', () async {
    await prefs.setCurationAttributions('not json');

    expect(storeAt(DateTime(2026, 8, 11)).shareSlugFor(mintA), isNull);
  });
}
