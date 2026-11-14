import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/features/wallets/services/wallet_link_service.dart';
import 'package:mocktail/mocktail.dart';

class _MockApi extends Mock implements MallowApiClient {}

class _MockAuth extends Mock implements AuthService {}

class _MockDb extends Mock implements MallowDatabase {}

class _FakeWallet extends Fake implements Wallet {
  _FakeWallet(this.id);

  @override
  final String id;
}

const _active = 'ACTIVE_ADDR';
const _newWallet = 'NEW_ADDR';
const _profileWallet = 'PROFILE_ADDR';

void main() {
  late _MockApi api;
  late _MockAuth auth;
  late _MockDb db;
  late WalletLinkService service;
  late List<String> loginsForLink;

  setUpAll(() {
    registerFallbackValue(const ApproveLinkRequestV2Body(address: _newWallet));
  });

  setUp(() {
    api = _MockApi();
    auth = _MockAuth();
    db = _MockDb();
    loginsForLink = [];
    when(
      () => db.getWalletByAddress(_newWallet),
    ).thenAnswer((_) async => _FakeWallet('w-new'));
    when(
      () => db.getWalletByAddress(_profileWallet),
    ).thenAnswer((_) async => _FakeWallet('w-profile'));
    when(() => auth.currentAddress).thenReturn(_active);
    when(() => auth.loginForLinkFlow(any())).thenAnswer((i) async {
      loginsForLink.add(i.positionalArguments.first as String);
    });
    when(
      () => auth.signAndVerifyForWallet(any(), any()),
    ).thenAnswer((_) async {});
    when(() => api.approveLinkRequestV2(any())).thenAnswer((_) async {});
    when(() => auth.linkFlowActive).thenReturn(true);
    when(() => auth.loginTokenIsFor(any())).thenReturn(true);
    when(() => auth.abandonLinkFlowToken()).thenAnswer((_) async {});
    service = WalletLinkService(api, auth, db);
  });

  test('a successful link puts the active wallet\'s login back', () async {
    await service.linkWallet(_newWallet, _profileWallet);

    expect(loginsForLink, [_profileWallet, _active]);
  });

  // The flow installs the target profile's login token. While it is in, the
  // resume refresh and the background reads stand down, so a link that threw
  // part-way (a dismissed Seed Vault approval) must still put it back.
  test('a cancelled link puts the active wallet\'s login back too', () async {
    when(
      () => auth.signAndVerifyForWallet('w-new', _newWallet),
    ).thenThrow(HardwareVerificationCancelledException());

    await expectLater(
      service.linkWallet(_newWallet, _profileWallet),
      throwsA(isA<HardwareVerificationCancelledException>()),
    );
    expect(loginsForLink, [_profileWallet, _active]);
    verifyNever(() => api.approveLinkRequestV2(any()));
  });

  // Left in place, the swapped token would keep the resume refresh and the
  // background reads off, and log every "Please log in" retry in as the
  // linked profile, until a switch or logout. Dropped, the next request logs
  // the active wallet in the ordinary way.
  test('a failed restore drops the swapped token, and the link still '
      'succeeds', () async {
    when(() => auth.loginForLinkFlow(_active)).thenThrow(Exception('offline'));

    await service.linkWallet(_newWallet, _profileWallet);

    verify(() => api.approveLinkRequestV2(any())).called(1);
    verify(() => auth.abandonLinkFlowToken()).called(1);
  });

  test(
    'with no logged-in address to restore, the swapped token is dropped',
    () async {
      when(() => auth.currentAddress).thenReturn(null);

      await service.linkWallet(_newWallet, _profileWallet);

      expect(loginsForLink, [_profileWallet]);
      verify(() => auth.abandonLinkFlowToken()).called(1);
    },
  );

  test('a restore that works keeps the token it installed', () async {
    await service.linkWallet(_newWallet, _profileWallet);

    verifyNever(() => auth.abandonLinkFlowToken());
  });

  test('nothing to restore when no token was swapped', () async {
    when(() => auth.linkFlowActive).thenReturn(false);

    await service.linkWallet(_newWallet, _profileWallet);

    expect(loginsForLink, [_profileWallet]);
    verifyNever(() => auth.abandonLinkFlowToken());
  });

  // approveLinkRequestV2 acts on whoever the login token names. A wallet
  // switch while the signatures were up replaced it, and the approve would
  // link the new wallet to that account.
  test('a wallet switch mid-flow fails the link without approving', () async {
    var reads = 0;
    when(
      () => auth.currentAddress,
    ).thenAnswer((_) => reads++ == 0 ? _active : 'SWITCHED_ADDR');

    await expectLater(
      service.linkWallet(_newWallet, _profileWallet),
      throwsA(isA<WalletLinkInterruptedException>()),
    );
    verifyNever(() => api.approveLinkRequestV2(any()));
  });

  test(
    'a login token that no longer names the profile fails the link',
    () async {
      when(() => auth.loginTokenIsFor(_profileWallet)).thenReturn(false);

      await expectLater(
        service.linkWallet(_newWallet, _profileWallet),
        throwsA(isA<WalletLinkInterruptedException>()),
      );
      verifyNever(() => api.approveLinkRequestV2(any()));
    },
  );

  // Step 1 can swap the token in and still throw (its own verify step). The
  // restore has to run for that too.
  test('a step 1 that throws still restores the active login', () async {
    when(
      () => auth.loginForLinkFlow(_profileWallet),
    ).thenThrow(Exception('verify failed'));

    await expectLater(
      service.linkWallet(_newWallet, _profileWallet),
      throwsA(isA<Exception>()),
    );
    expect(loginsForLink, [_active]);
  });
}
