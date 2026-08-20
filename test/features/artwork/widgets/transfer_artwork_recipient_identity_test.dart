import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show UserPreview;
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/services/transfer_artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/widgets/transfer_artwork_flow.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/address_utils.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Who the artwork transfer flow says you are sending to.
///
/// Two defects, both from this flow never adopting the account-level lookup the
/// send sheet uses:
///
///  * The confirm pill named the recipient from `WalletInfo.name` — the
///    **wallet row's** label, an internal per-chain-key detail. Social login
///    stores its wallets as "Apple Wallet"/"Google Wallet"
///    (`SocialAuthService`), so transferring to your own account reviewed under
///    the name of your *login provider*. The account's own label ("Account 2")
///    is what the accounts list and the send sheet show, and it comes from
///    `WalletRepository.accountsForAddresses`.
///  * The recents list never resolved local accounts at all — it ran the
///    profile lookup only, so an address you own could show a mallow username
///    or a bare hash and nothing else.
///
/// Both surfaces rank the sources mallow profile → local account → truncated
/// address, the order `RecentRecipient.displayName` and the send confirm pill
/// already use.

class _MockTransferBloc
    extends MockBloc<TransferArtworkEvent, TransferArtworkState>
    implements TransferArtworkBloc {}

class _MockRemoteConfig extends Fake implements RemoteConfigService {
  @override
  final ValueListenable<RemoteConfig> config = ValueNotifier(
    RemoteConfig.permissive,
  );

  @override
  Future<void> refreshIfStale() async {}
}

class _FakeWalletManager extends Fake implements WalletManager {
  @override
  Future<String> getAddress({Chain chain = Chain.solana}) async => _solSelf;
}

class _FakeSessionManager extends Fake implements SessionManager {
  @override
  Future<String?> activeAddress(Chain chain) async => _solSelf;
}

class _FakeTokenPriceService extends Fake implements TokenPriceService {
  @override
  double? priceOf(String? mint) => null;

  @override
  double? usdValueOfRaw(num? rawAmount, String? mint) => null;
}

/// The wallets table. [accounts] is what `accountsForAddresses` answers — the
/// **account** label. [walletName] is the label on the wallet *row*, which
/// `getAllWallets` answers and which must never reach the UI as a recipient
/// name; social login sets it to "Apple Wallet".
class _FakeWalletRepository extends Fake implements WalletRepository {
  _FakeWalletRepository({this.accounts = const {}, this.walletName});

  final Map<String, ({String name, String avatarSeed})> accounts;
  final String? walletName;

  @override
  Future<Map<String, ({String name, String avatarSeed})>> accountsForAddresses(
    List<String> addresses,
  ) async {
    final rows = {
      for (final e in accounts.entries) e.key.toLowerCase(): e.value,
    };
    return {
      for (final address in addresses)
        if (rows[address.toLowerCase()] case final row?) address: row,
    };
  }

  @override
  Future<List<WalletInfo>> getAllWallets() async => [
    for (final address in accounts.keys)
      WalletInfo(
        id: 'wallet-$address',
        address: address,
        name: walletName ?? 'Wallet',
        walletType: WalletType.hd,
        chain: Chain.solana.toDbString(),
      ),
  ];
}

class _FakeProfileLookupService extends Fake implements ProfileLookupService {
  _FakeProfileLookupService([this.usernames = const {}]);

  final Map<String, String> usernames;

  @override
  Future<Map<String, UserPreview>> profilesForAddresses(
    List<String> addresses,
  ) async => {
    for (final address in addresses)
      if (usernames[apiOwnerAddress(address)] case final name?)
        apiOwnerAddress(address): UserPreview(
          username: name,
          addresses: [apiOwnerAddress(address)],
        ),
  };
}

const _solSelf = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
const _solRecipient = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
const _solMint = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

void main() {
  late _MockTransferBloc bloc;
  late StreamController<TransferArtworkState> states;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  Future<void> setUpFlow({
    Map<String, ({String name, String avatarSeed})> accounts = const {},
    String? walletName,
    Map<String, String> usernames = const {},
    List<String> recents = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.create();
    for (final address in recents.reversed) {
      await prefs.saveRecentSendAddress(address);
    }
    if (!sl.isRegistered<AnalyticsService>()) {
      sl.registerSingleton<AnalyticsService>(
        AnalyticsService(Dio(), prefs, const FlutterSecureStorage()),
      );
    }

    register<TransferArtworkBloc>(bloc);
    register<RemoteConfigService>(_MockRemoteConfig());
    register<PreferencesService>(prefs);
    register<AvatarService>(AvatarService.forTest(Dio()));
    register<WalletManager>(_FakeWalletManager());
    register<SessionManager>(_FakeSessionManager());
    register<TokenPriceService>(_FakeTokenPriceService());
    register<ProfileLookupService>(_FakeProfileLookupService(usernames));
    register<WalletRepository>(
      _FakeWalletRepository(accounts: accounts, walletName: walletName),
    );
  }

  setUp(() {
    bloc = _MockTransferBloc();
    states = StreamController<TransferArtworkState>.broadcast();
  });

  tearDown(() async {
    await states.close();
    for (final drop in [
      () => sl.unregister<TransferArtworkBloc>(),
      () => sl.unregister<RemoteConfigService>(),
      () => sl.unregister<PreferencesService>(),
      () => sl.unregister<AvatarService>(),
      () => sl.unregister<WalletManager>(),
      () => sl.unregister<SessionManager>(),
      () => sl.unregister<TokenPriceService>(),
      () => sl.unregister<ProfileLookupService>(),
      () => sl.unregister<WalletRepository>(),
    ]) {
      drop();
    }
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  PortfolioArtwork solArtwork() => PortfolioArtwork(
    mintAccount: _solMint,
    title: 'Solana NFT',
    imageUrl: '',
    artistName: 'Artist',
    chain: 'solana',
  );

  /// Opens the flow on the recipient step and, when [then] is given, emits it
  /// so the sheet *transitions* into the confirm step.
  ///
  /// The transition is the point: recipient identity is resolved from the bloc
  /// listener, which fires on a state change and not on the initial state — so
  /// handing `TransferReady` straight to `initialState` reaches the confirm
  /// step with nothing ever looked up, and the test would pass on an empty
  /// screen.
  Future<void> open(
    WidgetTester tester, {
    required TransferArtworkState initial,
    TransferArtworkState? then,
  }) async {
    whenListen(bloc, states.stream, initialState: initial);

    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  runTransferArtworkFlow(context, artwork: solArtwork()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await flush(tester);
    if (then != null) {
      states.add(then);
      await flush(tester);
    }
  }

  testWidgets('the confirm pill names the ACCOUNT, never the wallet row label '
      'social login wrote', (tester) async {
    // "Apple Wallet" is what `SocialAuthService` names the wallet row for an
    // Apple login. Reading `WalletInfo.name` here put the user's login provider
    // on the review screen as the name of the person they were sending to.
    await setUpFlow(
      accounts: const {
        _solRecipient: (name: 'Account 2', avatarSeed: 'seed-account-2'),
      },
      walletName: 'Apple Wallet',
    );
    await open(
      tester,
      initial: const TransferArtworkState.input(),
      then: const TransferArtworkState.ready(recipient: _solRecipient),
    );

    expect(find.text('Apple Wallet'), findsNothing);
    expect(find.text('Account 2'), findsWidgets);
  });

  testWidgets('the confirm pill still prefers the mallow profile over the '
      'local account', (tester) async {
    await setUpFlow(
      accounts: const {
        _solRecipient: (name: 'Account 2', avatarSeed: 'seed-account-2'),
      },
      usernames: const {_solRecipient: 'alice'},
    );
    await open(
      tester,
      initial: const TransferArtworkState.input(),
      then: const TransferArtworkState.ready(recipient: _solRecipient),
    );

    expect(find.text('alice'), findsWidgets);
    expect(find.text('Account 2'), findsNothing);
  });

  testWidgets('the recents list shows local account names', (tester) async {
    // This flow ran the profile lookup over its recents but never the account
    // lookup, so an address the user owns could only ever render as a mallow
    // username or a bare hash.
    await setUpFlow(
      accounts: const {
        _solRecipient: (name: 'Account 2', avatarSeed: 'seed-account-2'),
      },
      recents: const [_solRecipient],
    );
    await open(tester, initial: const TransferArtworkState.input());

    expect(find.text('Account 2'), findsWidgets);
  });

  testWidgets('a recent with no local account still falls back to the '
      'truncated address', (tester) async {
    await setUpFlow(recents: const [_solRecipient]);
    await open(tester, initial: const TransferArtworkState.input());

    expect(find.text(truncateAddress(_solRecipient)), findsWidgets);
  });
}
