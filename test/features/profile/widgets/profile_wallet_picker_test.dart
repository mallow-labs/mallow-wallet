import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/profile/services/wallet_link_selection.dart';
import 'package:mallow_wallet/features/profile/widgets/profile_wallet_picker.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/wallet_type_badge.dart';
import 'package:mocktail/mocktail.dart';

class _MockDio extends Mock implements Dio {}

/// The "Select wallets" step lists bare addresses, so nothing on the row says
/// where a wallet's key lives. Linking a Ledger has different consequences from
/// linking a Google login — every signature needs the device on hand — and the
/// user has to see that before they pick.
void main() {
  // The card header renders an identicon (AccountAvatar), which resolves
  // AvatarService via GetIt. An unstubbed mock Dio fails every fetch, so the
  // avatar falls back to anon — fine, the badges are what's under test.
  setUpAll(() {
    sl.registerLazySingleton<AvatarService>(
      () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
    );
  });
  tearDownAll(() => sl.unregister<AvatarService>());

  WalletInfo wallet(String address, WalletType type) => WalletInfo(
    id: 'w-$address',
    address: address,
    name: address,
    walletType: type,
    chain: 'solana',
  );

  Future<void> pumpCard(WidgetTester tester, List<WalletInfo> wallets) async {
    final account = Account(id: 'a1', name: 'Account 1', wallets: wallets);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: ProfileWalletPickerCard(
            account: LinkableAccount(
              account: account,
              wallets: [
                for (final w in wallets)
                  LinkableWallet(wallet: w, linkedToProfile: false),
              ],
            ),
            selectedWalletIds: const {},
            lockedWalletIds: const {},
            atCapacity: false,
            onToggleWallet: (_) {},
            onToggleAccount: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder badgeOf(WalletBadge badge) =>
      find.byWidgetPredicate((w) => w is WalletTypeBadge && w.badge == badge);

  testWidgets('a Ledger wallet row is marked as hardware', (tester) async {
    await pumpCard(tester, [wallet('7xKX', WalletType.ledger)]);

    expect(badgeOf(WalletBadge.hardware), findsOneWidget);
  });

  testWidgets('a social wallet row carries its provider mark', (tester) async {
    // Google and Apple are distinct providers, not one "social" bucket — the
    // user picks the row by recognising which login it came from.
    await pumpCard(tester, [
      const WalletInfo(
        id: 'w-google',
        address: '9pLm',
        name: '9pLm',
        walletType: WalletType.social,
        chain: 'solana',
        socialProvider: 'google',
      ),
    ]);

    expect(badgeOf(WalletBadge.google), findsOneWidget);
    expect(badgeOf(WalletBadge.apple), findsNothing);
  });

  testWidgets('a plain HD wallet row carries no mark', (tester) async {
    // Guards against badging every row off the account's type: an HD wallet
    // has no provenance to show, and a blanket icon would be a lie.
    await pumpCard(tester, [wallet('4bNq', WalletType.hd)]);

    expect(
      find.byWidgetPredicate((w) => w is WalletTypeBadge && w.badge != null),
      findsNothing,
    );
  });

  testWidgets('each row is badged from its own wallet, not the account', (
    tester,
  ) async {
    // Account.typeBadge resolves one badge for the whole account off the
    // primary wallet. Reaching for it here compiles and looks right on a
    // uniform account, but stamps the first wallet's provenance onto every row.
    await pumpCard(tester, [
      wallet('7xKX', WalletType.ledger),
      wallet('4bNq', WalletType.hd),
    ]);

    expect(badgeOf(WalletBadge.hardware), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is WalletTypeBadge && w.badge != null),
      findsOneWidget,
    );
  });
}
