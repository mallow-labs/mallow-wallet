import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/priority_fee_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Two prefs, one resolve point: Settings → Priority Fee writes the general
/// ceiling every client-built Solana tx uses, the swap sheet writes an override
/// that applies to swaps only and falls back to the general value. These pin
/// that resolution order, and the floor that keeps a too-small pref from
/// crashing the tx builder.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PreferencesService prefs;
  late PriorityFeeService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await PreferencesService.create();
    service = PriorityFeeService(prefs);
  });

  test('defaults to Auto, resolved to the webapp default ceiling', () {
    expect(service.isAuto, isTrue);
    expect(service.ceilingLamports, kAutoPriorityFeeLamports);
    expect(service.ceilingLamports, 50000);
  });

  test('Auto stays null for a router that does its own estimation', () {
    // Pinning 50 000 for Jupiter would strip it of the real-time estimation
    // Auto exists to use — Auto means "you decide", not "spend 50 000".
    expect(service.routerLamports, isNull);
  });

  test('the presets are the webapp tiers, 1x / 20x / 200x', () {
    expect(PriorityFeeTier.auto.lamports, 50000);
    expect(PriorityFeeTier.high.lamports, 50000 * 20);
    expect(PriorityFeeTier.turbo.lamports, 50000 * 200);
  });

  test('a selection persists and survives a restart', () async {
    await service.set(PriorityFeeTier.high.lamports);
    expect(prefs.priorityFeeLamports, 1000000);
    expect(PriorityFeeService(prefs).ceilingLamports, 1000000);
  });

  test('clamps a manual entry at 1 SOL', () async {
    // A fat-fingered extra zero on a priority fee is money that is gone.
    await service.set(5000000000);
    expect(service.ceilingLamports, kMaxPriorityFeeLamports);
  });

  test('a non-positive entry folds back to Auto, not a zero ceiling', () async {
    await service.set(PriorityFeeTier.turbo.lamports);
    await service.set(0);
    expect(service.isAuto, isTrue);
    expect(service.routerLamports, isNull);
  });

  test('notifies listeners so open surfaces re-read the ceiling', () async {
    var notifications = 0;
    service.selection.addListener(() => notifications++);
    await service.set(PriorityFeeTier.turbo.lamports);
    // A no-op write must not churn listeners (the swap sheet persists on every
    // dismissal path, including ones where nothing changed).
    await service.set(PriorityFeeTier.turbo.lamports);
    expect(notifications, 1);
  });

  // `SolanaRpcService.computeBudgetIxs` clamps the network's recommendation
  // into `[15 000, ceiling]` lamports, and `num.clamp` THROWS ArgumentError
  // when the bounds are inverted — outside any try/catch on the tx-build path.
  // A ceiling under the floor would therefore break *every* client-built
  // Solana transaction, so the resolve path floors it rather than trusting the
  // stored value.
  group('the 15 000-lamport floor', () {
    test('floors a too-small general ceiling on read', () async {
      await service.set(10000);
      expect(service.ceilingLamports, kMinPriorityFeeLamports);
      expect(service.ceilingLamports, 15000);
    });

    test('floors a too-small swap override on read', () async {
      await service.setSwap(10000);
      expect(service.routerLamports, 15000);
    });

    test('leaves the stored pref as the user entered it', () async {
      // Floor at read, not at write: no migration, and the settings field
      // still shows back the number that was typed.
      await service.set(10000);
      expect(prefs.priorityFeeLamports, 10000);
    });

    test('a 10 000-lamport pref still builds a compute budget', () async {
      // The regression this whole floor exists for: `computeBudgetIxs` clamps
      // into `[floor, ceiling]` and `num.clamp` throws ArgumentError on
      // inverted bounds, so before the floor this call blew up and took every
      // client-built Solana transaction with it.
      await service.set(10000);
      if (sl.isRegistered<PriorityFeeService>()) {
        await sl.unregister<PriorityFeeService>();
      }
      sl.registerSingleton<PriorityFeeService>(service);
      addTearDown(() => sl.unregister<PriorityFeeService>());

      final ixs = SolanaRpcService.computeBudgetIxs(computeBudget: 200000);
      // 15 000 lamports over a 200k CU budget = 75 000 microLamports/CU — the
      // floored ceiling, not the stored 10 000 (which would be 50 000).
      final data = ixs.first.data.toList();
      expect(data.first, 3); // SetComputeUnitPrice
      var unitPrice = 0;
      for (var i = 8; i >= 1; i--) {
        unitPrice = (unitPrice << 8) | data[i];
      }
      expect(unitPrice, 75000);
    });

    test('does not invent a fee for Auto', () async {
      // Auto (50 000) already clears the floor, and the router must still get
      // null so Jupiter does its own estimation.
      expect(service.ceilingLamports, kAutoPriorityFeeLamports);
      expect(service.routerLamports, isNull);
    });
  });

  // Read resolution for swaps is swap key → general key → Auto; general reads
  // never consult the swap key. The swap key predates the general one, so a
  // user who set a custom swap fee keeps it with no migration.
  group('two-key resolution', () {
    test('a swap override wins over the general ceiling', () async {
      await service.set(PriorityFeeTier.high.lamports);
      await service.setSwap(PriorityFeeTier.turbo.lamports);
      expect(service.routerLamports, PriorityFeeTier.turbo.lamports);
    });

    test('swaps fall back to the general ceiling when unset', () async {
      await service.set(PriorityFeeTier.high.lamports);
      expect(service.swapSelection.value, isNull);
      expect(service.routerLamports, PriorityFeeTier.high.lamports);
    });

    test('swaps fall back to Auto when both are unset', () {
      expect(service.routerLamports, isNull);
    });

    test('the general ceiling never reads the swap key', () async {
      await service.setSwap(PriorityFeeTier.turbo.lamports);
      // A send must not silently inherit a fee raised for one swap.
      expect(service.ceilingLamports, kAutoPriorityFeeLamports);
      expect(service.isAuto, isTrue);
    });

    test(
      'each key persists under its own pref and survives a restart',
      () async {
        await service.set(PriorityFeeTier.high.lamports);
        await service.setSwap(PriorityFeeTier.turbo.lamports);
        expect(prefs.priorityFeeLamports, PriorityFeeTier.high.lamports);
        expect(prefs.swapPriorityFeeLamports, PriorityFeeTier.turbo.lamports);

        final restarted = PriorityFeeService(prefs);
        expect(restarted.ceilingLamports, PriorityFeeTier.high.lamports);
        expect(restarted.routerLamports, PriorityFeeTier.turbo.lamports);
      },
    );

    test(
      'clearing the swap override falls back, it does not force Auto',
      () async {
        await service.set(PriorityFeeTier.high.lamports);
        await service.setSwap(PriorityFeeTier.turbo.lamports);
        await service.setSwap(null);
        expect(service.routerLamports, PriorityFeeTier.high.lamports);
      },
    );

    // Settings → "Reset app" wipes the preference store, but both values were
    // cached into notifiers at construction. Without a re-seed the service
    // keeps applying the pre-reset ceiling to every Solana tx, Settings keeps
    // displaying it, and `set` early-returns on equality — so re-picking that
    // same value is a no-op and the pref can never be re-persisted for the rest
    // of the session.
    test('a preference wipe re-seeds both keys back to Auto', () async {
      await service.set(PriorityFeeTier.turbo.lamports);
      await service.setSwap(PriorityFeeTier.high.lamports);

      await prefs.clearAll();

      expect(service.isAuto, isTrue);
      expect(service.ceilingLamports, kAutoPriorityFeeLamports);
      expect(service.selection.value, isNull);
      expect(service.routerLamports, isNull);

      // The state is consistent again, so the wiped value is re-persistable.
      await service.set(PriorityFeeTier.turbo.lamports);
      expect(prefs.priorityFeeLamports, PriorityFeeTier.turbo.lamports);
    });

    test('the swap key keeps its legacy name so nobody is reset', () async {
      // Renaming it (as the Tier-C diff first did) silently reset every user
      // with a custom swap fee back to Auto.
      SharedPreferences.setMockInitialValues({
        'pref_swap_priority_fee_lamports': 123456,
      });
      final legacy = PriorityFeeService(await PreferencesService.create());
      expect(legacy.routerLamports, 123456);
    });
  });
}
