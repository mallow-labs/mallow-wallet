import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/store_build.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

/// The remote kill switch must be **disable-only**.
///
/// Apple 2.3.1 prohibits hidden or dormant features activated after review.
/// Disabling a flow remotely is fine; *revealing* one that review never saw is
/// not. This build's App Review notes state, in writing, that its remote
/// configuration "can disable a flow that is already visible; it cannot reveal
/// any surface that review has not seen."
///
/// These tests exist so that sentence is **enforced rather than promised**. If
/// someone later adds an `enabledFlows` list, a feature-reveal boolean, or an
/// `A/B` bucket to [RemoteConfig], one of these fails and the review-notes
/// claim gets revisited before it ships — which is the whole point. A test that
/// merely re-read the current field list off the class it is checking could not
/// do that, so the expectations below are written out longhand.
void main() {
  group('RemoteConfig is structurally disable-only', () {
    test('permissive is the maximum-capability state: nothing is killed', () {
      // The cold-start value, and what a failed first fetch leaves in place.
      // If this is ever NOT the most permissive state, some config value has
      // become capable of turning something on.
      for (final flow in AppFlow.values) {
        for (final chain in flow.chains) {
          expect(
            RemoteConfig.permissive.disabledMessage(chain, flow),
            isNull,
            reason:
                '${chain.toDbString()}:${flow.wire} must be live by default',
          );
        }
      }

      expect(RemoteConfig.permissive.updateRequired, isFalse);
      expect(RemoteConfig.permissive.minimumVersion, isNull);
    });

    test('a populated config can only subtract — never add — a live flow', () {
      const killed = AppFlow.raffleBuyTickets;
      final config = RemoteConfig(
        disabledMessages: Map.unmodifiable({
          '${Chain.solana.toDbString()}:${killed.wire}': 'Raffles are paused.',
        }),
      );

      // The named cell is off...
      expect(
        config.disabledMessage(Chain.solana, killed),
        'Raffles are paused.',
      );

      // ...and every other cell is exactly as live as it was under
      // `permissive`. A config entry can subtract from the live set; there is
      // no shape of payload that adds to it.
      for (final flow in AppFlow.values) {
        for (final chain in flow.chains) {
          if (flow == killed && chain == Chain.solana) continue;
          expect(
            config.disabledMessage(chain, flow),
            RemoteConfig.permissive.disabledMessage(chain, flow),
            reason:
                'killing one cell must not change ${chain.toDbString()}:${flow.wire}',
          );
        }
      }
    });

    test('the wire payload carries no field capable of revealing a surface', () {
      // Longhand on purpose — see the file comment. Adding a reveal-capable
      // field to RemoteConfig without updating this list is exactly the
      // regression this test is here to catch.
      const knownFields = {
        'disabledMessages', // deny-list: presence == disabled
        'minimumVersion', // force-upgrade floor
        'updateRequired', // force-upgrade verdict
        'updateMessage', // force-upgrade copy
      };

      // `toString()` on the freezed class names every field it carries.
      final rendered = RemoteConfig.permissive.toString();
      final named = knownFields.where(rendered.contains).toSet();

      expect(
        named,
        knownFields,
        reason: 'a known field disappeared — re-check the disable-only claim',
      );

      // None of the four can turn anything on: three drive the force-upgrade
      // wall (itself a *block*, not a reveal) and the fourth is a deny-list.
      for (final suspect in [
        'enabled',
        'reveal',
        'feature',
        'experiment',
        'bucket',
      ]) {
        expect(
          rendered.toLowerCase(),
          isNot(contains(suspect)),
          reason:
              'RemoteConfig gained a "$suspect"-shaped field. If it can reveal '
              'a surface App Review never saw, that breaks Apple 2.3.1 and the '
              'written claim in this build\'s review notes.',
        );
      }
    });
  });

  group('store-build flags are compile-time and beyond remote reach', () {
    test('every store-build flag derives from the build-time constant', () {
      // These are `const`, so a release archive tree-shakes the hidden
      // branches entirely — no runtime value, remote or otherwise, can bring
      // them back. The expectation re-derives `SHOW_UNRELEASED` rather than
      // hard-coding `isTrue`, so it compares the flag against the switch it is
      // supposed to read instead of against a literal.
      //
      // Be precise about what that buys, because it is asymmetric. Verified by
      // mutating `store_build.dart`: repointing the flag at a different
      // variable or default (`SHOW_RAFFLE`, `defaultValue: false`) FAILS here,
      // and pinning it to `false` FAILS. Pinning it to `true` PASSES — under
      // `flutter test` the define is unset and `kDebugMode` is true, so a
      // hardcoded `true` is indistinguishable from the real derivation. Nothing
      // asserted at runtime in a debug build can separate those two.
      //
      // So this guards the direction that would hide a surface, not the one
      // that would reveal one. The reveal direction is held by review and by
      // `store_build.dart` being `const` — Dart cannot assert constness from a
      // test. Adding a second flag would make the old cross-check (both read
      // the same source) worth restoring alongside this.
      const showUnreleased = bool.fromEnvironment(
        'SHOW_UNRELEASED',
        defaultValue: kDebugMode,
      );
      expect(
        kShowRaffleEntry,
        showUnreleased,
        reason: 'store-build flags must share one build-time source',
      );
    });
  });

  group('iOS store gate: kShowNftCommerce hides the paid side only', () {
    tearDown(() => debugShowNftCommerceOverride = null);

    test('the commerce set names every paid cell and no escape hatch', () {
      // The paid side — what Apple 3.1.1 is about. Written out longhand so a
      // new paid cell added to AppFlow without being listed here fails this
      // test rather than silently shipping on iOS.
      expect(kStoreCommerceFlows, {
        AppFlow.fixedPriceBuy,
        AppFlow.editionBuy,
        AppFlow.auctionBid,
        AppFlow.offerCreate,
        AppFlow.fixedPriceCreate,
        AppFlow.fixedPriceUpdate,
        AppFlow.auctionCreate,
        AppFlow.offerAccept,
        AppFlow.nftMint,
        AppFlow.editionMint,
        AppFlow.collectionMint,
        AppFlow.raffleBuyTickets,
      });

      // The escape hatches: how a user gets an asset back out. Hiding the
      // paid side must leave every one of these reachable, so none may ever
      // be classified as commerce.
      const hatches = <AppFlow>[
        AppFlow.fixedPriceCancel,
        AppFlow.auctionCancel,
        AppFlow.auctionSettle,
        AppFlow.offerCancel,
        AppFlow.raffleCancel,
        AppFlow.raffleClaimPrize,
        AppFlow.raffleClaimProceeds,
        AppFlow.unstakeNative,
        AppFlow.withdrawStake,
        // Wallet functions and metadata edits stay too. `tokenSwap` and
        // `stakeLiquid` are here because *commerce* never hides them; the
        // separate `kShowSwap` flag does, and its own group below is what
        // asserts that.
        AppFlow.nativeSend,
        AppFlow.tokenSend,
        AppFlow.tokenBurn,
        AppFlow.tokenSwap,
        AppFlow.nftTransfer,
        AppFlow.nftBurn,
        AppFlow.nftEdit,
        AppFlow.collectionEdit,
        AppFlow.collectionArtworksEdit,
        AppFlow.stakeNative,
        AppFlow.stakeLiquid,
      ];

      for (final hatch in hatches) {
        expect(
          hatch.isStoreCommerce,
          isFalse,
          reason: '${hatch.wire} must stay reachable when commerce is hidden',
        );
      }

      // The two lists must exhaust AppFlow between them. This is the part
      // that catches a *new* cell: `isStoreCommerce` is set membership, not an
      // exhaustive switch, so an unlisted flow is non-commerce by default and
      // the compiler says nothing — it would walk straight through the route
      // gate and the signing backstop on iOS.
      final unclassified = AppFlow.values.toSet()
        ..removeAll(kStoreCommerceFlows)
        ..removeAll(hatches);
      expect(
        unclassified,
        isEmpty,
        reason:
            'classify the new cell: commerce or escape hatch — '
            '${unclassified.map((f) => f.wire).join(', ')}',
      );
    });

    test('showNftCommerce honours the test override and defaults to the '
        'compiled flag', () {
      expect(showNftCommerce, kShowNftCommerce);
      debugShowNftCommerceOverride = false;
      expect(showNftCommerce, isFalse);
      debugShowNftCommerceOverride = true;
      expect(showNftCommerce, isTrue);
    });
  });

  group('iOS store gate: kShowSwap hides the aggregator paths only', () {
    tearDown(() {
      debugShowSwapOverride = null;
      debugShowNftCommerceOverride = null;
    });

    test('the swap set is exactly the two aggregator cells', () {
      // Both directions of the liquid staking path are the one `stake-liquid`
      // cell, so this set covers the liquid unstake as well — deliberately;
      // see `kShowSwap` for why that escape hatch goes with it.
      expect(kStoreSwapFlows, {AppFlow.tokenSwap, AppFlow.stakeLiquid});

      // Nothing else may be swept up. Native staking in particular: it stakes
      // to a validator, builds no swap, and must stay signable.
      for (final flow in AppFlow.values) {
        if (kStoreSwapFlows.contains(flow)) continue;
        expect(
          flow.isStoreSwap,
          isFalse,
          reason: '${flow.wire} is not an aggregator swap',
        );
      }
    });

    test('showSwap honours the test override and defaults to the compiled '
        'flag', () {
      expect(showSwap, kShowSwap);
      debugShowSwapOverride = false;
      expect(showSwap, isFalse);
      debugShowSwapOverride = true;
      expect(showSwap, isTrue);
    });

    test('storeHidesFlow reads both flags independently', () {
      // The point of the fold: each flag hides its own cells and neither
      // reaches the other's. A gate that only consulted one would pass every
      // single-flag test and still ship the surface the other flag hides.
      const buy = AppFlow.fixedPriceBuy;
      const swap = AppFlow.tokenSwap;
      const send = AppFlow.tokenSend;

      debugShowNftCommerceOverride = true;
      debugShowSwapOverride = true;
      expect(storeHidesFlow(buy), isFalse);
      expect(storeHidesFlow(swap), isFalse);

      debugShowNftCommerceOverride = false;
      expect(storeHidesFlow(buy), isTrue);
      expect(storeHidesFlow(swap), isFalse);

      debugShowNftCommerceOverride = true;
      debugShowSwapOverride = false;
      expect(storeHidesFlow(buy), isFalse);
      expect(storeHidesFlow(swap), isTrue);

      // A wallet function no flag names stays visible under both.
      debugShowNftCommerceOverride = false;
      expect(storeHidesFlow(send), isFalse);
    });
  });
}
