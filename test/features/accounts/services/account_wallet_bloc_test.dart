import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/features/accounts/services/account_wallet_bloc.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'account_wallet_bloc_test.mocks.dart';

@GenerateMocks([
  WalletRepository,
  WalletManager,
  AuthService,
  UserProfileRepository,
])
void main() {
  late MockWalletRepository mockWalletRepo;
  late MockWalletManager mockWalletManager;
  late MockAuthService mockAuthService;
  late MockUserProfileRepository mockUserProfileRepo;

  // An account with no wallets keeps the load happy-path free of balance and
  // profile network calls (the address list is empty), so the test isolates
  // the DB-load → loaded emission rather than the enrichment fan-out.
  const testAccount = Account(id: 'acc1', name: 'Account 1');

  setUp(() {
    mockWalletRepo = MockWalletRepository();
    mockWalletManager = MockWalletManager();
    mockAuthService = MockAuthService();
    mockUserProfileRepo = MockUserProfileRepository();
  });

  AccountWalletBloc buildBloc() => AccountWalletBloc(
    mockWalletRepo,
    mockWalletManager,
    mockAuthService,
    mockUserProfileRepo,
  );

  group('load', () {
    blocTest<AccountWalletBloc, AccountWalletState>(
      'emits loading then loaded with the DB accounts',
      setUp: () {
        when(
          mockWalletRepo.getAccountViews(),
        ).thenAnswer((_) async => [testAccount]);
        when(mockWalletRepo.getActiveSelection()).thenAnswer((_) async => null);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(const AccountWalletEvent.load()),
      expect: () => [
        const AccountWalletState.loading(),
        isA<AccountWalletLoaded>()
            .having((s) => s.accounts, 'accounts', [testAccount])
            .having((s) => s.activeWalletId, 'activeWalletId', isNull),
      ],
    );

    blocTest<AccountWalletBloc, AccountWalletState>(
      'emits loading then sanitized error when the DB read throws',
      setUp: () {
        when(mockWalletRepo.getAccountViews()).thenThrow(Exception('boom'));
      },
      build: buildBloc,
      act: (bloc) => bloc.add(const AccountWalletEvent.load()),
      expect: () => [
        const AccountWalletState.loading(),
        // AppFailure.from(Exception('boom')) → unknown kind, whose message is
        // the throwable's toString. The bloc must NOT surface that raw text
        // (exception/PII detail) — it emits fixed user-facing copy instead.
        isA<AccountWalletState>()
            .having((s) => s.toString(), 'state', isNot(contains('boom')))
            .having(
              (s) => s,
              'state',
              const AccountWalletState.error(
                'Could not load your accounts. Please try again.',
              ),
            ),
      ],
    );
  });

  group('toggleAccountExpanded', () {
    blocTest<AccountWalletBloc, AccountWalletState>(
      'adds an account id to the expanded set',
      build: buildBloc,
      seed: () => const AccountWalletState.loaded(
        accounts: [testAccount],
        activeWalletId: null,
        activeAccountId: null,
      ),
      act: (bloc) =>
          bloc.add(const AccountWalletEvent.toggleAccountExpanded('acc1')),
      expect: () => [
        isA<AccountWalletLoaded>().having(
          (s) => s.expandedAccountIds,
          'expandedAccountIds',
          {'acc1'},
        ),
      ],
    );
  });
}
