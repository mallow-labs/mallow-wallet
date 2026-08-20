import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart'
    show EditionWhitelistConfig, MallowApiClient;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/market/data/whitelist_eligibility_repository.dart'
    show kDefaultPubkey;
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_buy_edition_sheet.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/no_verified_list_database.dart';

// An edition listing can be gated three different ways, and they are three
// different lists:
//
//   * OFF-chain — `Nft.offChainWhitelistMerkleRoot`, surfaced as
//     `ArtworkDetails.offChainWhitelistDenied`. No on-chain account, no proof;
//     the tx builder alone enforces it and returns a 400.
//   * ON-chain wallet allowlist — `WhitelistConfig.walletsRoot`, which the
//     mallow-market program verifies against a per-buyer `proofs` PDA.
//   * ON-chain holder-only token gate — `WhitelistConfig.collectionsOrCreators`,
//     satisfied by owning an NFT from one of them.
//
// The two on-chain paths are ORed (either qualifies the buyer); the off-chain
// flag is a separate term on top. Mobile used to gate on the off-chain flag
// ANDed with the on-chain phase flag — the wrong list — so an on-chain
// ineligible buyer got an enabled Buy, a biometric prompt and a guaranteed
// on-chain failure. These tests pin the composition against the webapp
// (`useWhitelistConfig` + `EditionBox`), which
// shows the SAME "Not allowlisted" copy for every one of them.

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class _FakeMallowApiClient extends Fake implements MallowApiClient {}

class _MockAuthService extends Mock implements AuthService {}

const _walletsRoot = 'B2rootB2rootB2rootB2rootB2rootB2rootB2rootB2';

ArtworkDetails _artwork({bool? offChainWhitelistDenied}) => ArtworkDetails(
  mintAccount: 'mint1',
  title: 'T',
  imageUrl: '',
  description: null,
  artistName: 'A',
  artistAddress: 'artist1',
  price: 1000000000,
  listingType: ListingType.buyNow,
  supplyType: SupplyType.limitedEdition,
  offChainWhitelistDenied: offChainWhitelistDenied,
);

EditionPurchaseStats _stats({
  required bool phaseActive,
  String walletsRoot = _walletsRoot,
}) => EditionPurchaseStats(
  whitelistConfig: EditionWhitelistConfig(
    walletsRoot: walletsRoot,
    durationSec: 3600,
    isActive: phaseActive,
  ),
);

void main() {
  late _MockTokenBalanceBloc balances;

  setUpAll(() async {
    // Every price row on these sheets resolves its currency through this
    // service. The fixtures are all registry-priced, so it short-circuits on
    // the static table and never issues a DAS request — it only has to exist.
    SharedPreferences.setMockInitialValues({});
    if (!sl.isRegistered<TokenMetadataService>()) {
      final prefs = await PreferencesService.create();
      sl.registerLazySingleton<TokenMetadataService>(
        () => TokenMetadataService(
          DasApiService(),
          prefs,
          NoVerifiedListDatabase(),
        ),
      );
    }
    if (!sl.isRegistered<TokenPriceService>()) {
      sl.registerLazySingleton<TokenPriceService>(
        () => TokenPriceService(_FakeMallowApiClient()),
      );
    }
    final auth = _MockAuthService();
    when(() => auth.currentAddress).thenReturn(null);
    if (!sl.isRegistered<AuthService>()) {
      sl.registerSingleton<AuthService>(auth);
    }
  });

  setUp(() {
    balances = _MockTokenBalanceBloc();
    when(() => balances.state).thenReturn(const TokenBalanceState.initial());
  });

  Future<int> pumpSheet(
    WidgetTester tester, {
    required bool phaseActive,
    bool? onChainAllowlisted,
    bool? holdsGatingNft,
    bool? offChainWhitelistDenied,
    String walletsRoot = _walletsRoot,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var buyTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<TokenBalanceBloc>.value(
            value: balances,
            child: ArtworkBuyEditionSheet(
              artwork: _artwork(
                offChainWhitelistDenied: offChainWhitelistDenied,
              ),
              purchaseStats: _stats(
                phaseActive: phaseActive,
                walletsRoot: walletsRoot,
              ),
              onChainAllowlisted: onChainAllowlisted,
              holdsGatingNft: holdsGatingNft,
              onBuyEdition: () => buyTaps++,
              onMakeOffer: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return buyTaps;
  }

  testWidgets(
    'a wallet neither path qualifies is told it is not allowlisted and cannot '
    'dispatch a buy',
    (tester) async {
      final taps = await pumpSheet(
        tester,
        phaseActive: true,
        onChainAllowlisted: false,
        holdsGatingNft: false,
      );
      expect(find.text('Buy edition'), findsNothing);
      expect(find.text('Not allowlisted'), findsOneWidget);

      // The disabled button must not merely look disabled: tapping it may not
      // reach the bloc, because the whole point is to not burn a signing
      // prompt on a transaction the program will reject.
      await tester.tap(find.text('Not allowlisted'), warnIfMissed: false);
      await tester.pump();
      expect(taps, 0);
    },
  );

  testWidgets(
    'an ON-CHAIN allowlisted wallet is NOT blocked by the unrelated off-chain '
    'root being absent, nor by holding no gating NFT',
    (tester) async {
      await pumpSheet(
        tester,
        phaseActive: true,
        onChainAllowlisted: true,
        holdsGatingNft: false,
      );
      expect(find.text('Buy edition'), findsOneWidget);
      expect(find.text('Not allowlisted'), findsNothing);
    },
  );

  testWidgets(
    'a HOLDER of a gating NFT is qualified by that alone, even when off the '
    'wallet allowlist',
    (tester) async {
      await pumpSheet(
        tester,
        phaseActive: true,
        onChainAllowlisted: false,
        holdsGatingNft: true,
      );
      expect(find.text('Buy edition'), findsOneWidget);
      expect(find.text('Not allowlisted'), findsNothing);
    },
  );

  testWidgets(
    'a token-gated drop with NO wallet allowlist is gated by the holder check '
    'rather than being inert',
    (tester) async {
      // `walletsRoot` is the default pubkey, so the allowlist path reports
      // "does not qualify you" — NOT "unknown". If it reported unknown the
      // fail-open rule would neutralise the holder gate and every non-holder
      // would get an enabled Buy on a drop they cannot buy from.
      final taps = await pumpSheet(
        tester,
        phaseActive: true,
        walletsRoot: kDefaultPubkey,
        onChainAllowlisted: false,
        holdsGatingNft: false,
      );
      expect(find.text('Buy edition'), findsNothing);
      expect(find.text('Not allowlisted'), findsOneWidget);
      await tester.tap(find.text('Not allowlisted'), warnIfMissed: false);
      await tester.pump();
      expect(taps, 0);

      // ...and a holder on that same listing sails through.
      await pumpSheet(
        tester,
        phaseActive: true,
        walletsRoot: kDefaultPubkey,
        onChainAllowlisted: false,
        holdsGatingNft: true,
      );
      expect(find.text('Buy edition'), findsOneWidget);
    },
  );

  testWidgets(
    'the off-chain list stays a SEPARATE term — a wallet the on-chain phase '
    'qualifies but the off-chain root denies is still blocked',
    (tester) async {
      await pumpSheet(
        tester,
        phaseActive: true,
        onChainAllowlisted: true,
        holdsGatingNft: true,
        offChainWhitelistDenied: true,
      );
      expect(find.text('Buy edition'), findsNothing);
      expect(find.text('Not allowlisted'), findsOneWidget);
    },
  );

  testWidgets(
    'an unknown verdict on EITHER path fails OPEN — a flaky check during a '
    'drop must not lock out a collector the program would accept',
    (tester) async {
      // The allowlist check failed; the holder check definitively said no.
      await pumpSheet(tester, phaseActive: true, holdsGatingNft: false);
      expect(find.text('Buy edition'), findsOneWidget);
      expect(find.text('Not allowlisted'), findsNothing);

      // ...and the mirror image: the holder check is what failed.
      await pumpSheet(tester, phaseActive: true, onChainAllowlisted: false);
      expect(find.text('Buy edition'), findsOneWidget);
      expect(find.text('Not allowlisted'), findsNothing);
    },
  );

  testWidgets(
    'once the whitelist phase has ended the listing is public again, so an '
    'unqualified wallet is no longer gated',
    (tester) async {
      await pumpSheet(
        tester,
        phaseActive: false,
        onChainAllowlisted: false,
        holdsGatingNft: false,
      );
      expect(find.text('Buy edition'), findsOneWidget);
      expect(find.text('Not allowlisted'), findsNothing);
    },
  );
}
