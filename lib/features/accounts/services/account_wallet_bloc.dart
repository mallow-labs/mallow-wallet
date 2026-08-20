import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/models/account.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../portfolio/data/wallet_balance_totals.dart';
import '../../profile/data/user_profile_repository.dart';

part 'account_wallet_bloc.freezed.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

@freezed
abstract class AccountWalletEvent with _$AccountWalletEvent {
  const factory AccountWalletEvent.load() = _Load;
  const factory AccountWalletEvent.switchWallet(String walletId) =
      _SwitchWallet;
  const factory AccountWalletEvent.toggleAccountExpanded(String accountId) =
      _ToggleAccountExpanded;
  const factory AccountWalletEvent.refreshBalances() = _RefreshBalances;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@freezed
abstract class AccountWalletState with _$AccountWalletState {
  const factory AccountWalletState.initial() = _Initial;
  const factory AccountWalletState.loading() = _Loading;
  const factory AccountWalletState.loaded({
    required List<Account> accounts,
    required String? activeWalletId,
    required String? activeAccountId,
    @Default({}) Set<String> expandedAccountIds,
  }) = AccountWalletLoaded;
  const factory AccountWalletState.error(String message) = _Error;
}

// ---------------------------------------------------------------------------
// BLoC
// ---------------------------------------------------------------------------

@injectable
class AccountWalletBloc extends Bloc<AccountWalletEvent, AccountWalletState> {
  AccountWalletBloc(
    this._walletRepo,
    this._walletManager,
    this._authService,
    this._userProfileRepo,
  ) : super(const AccountWalletState.initial()) {
    on<_Load>(_onLoad);
    on<_SwitchWallet>(_onSwitchWallet);
    on<_ToggleAccountExpanded>(_onToggleExpanded);
    on<_RefreshBalances>(_onRefreshBalances);
  }

  final WalletRepository _walletRepo;
  final WalletManager _walletManager;
  final AuthService _authService;
  final UserProfileRepository _userProfileRepo;

  /// Enrich accounts with profile data (avatar, username) from the API.
  Future<List<Account>> _enrichWithProfiles(List<Account> accounts) async {
    try {
      final enriched = await Future.wait(
        accounts.map((account) async {
          final wallet = account.primaryWallet;
          if (wallet == null) return account;
          try {
            final profile = await _userProfileRepo.getUserProfile(
              wallet.address,
            );
            return account.copyWith(
              profileImageUrl: profile.avatarUrl.isNotEmpty
                  ? profile.avatarUrl
                  : null,
              profileName: profile.username != 'Unknown'
                  ? profile.username
                  : null,
            );
          } catch (_) {
            return account;
          }
        }),
      );
      return enriched;
    } catch (_) {
      return accounts;
    }
  }

  Future<void> _onLoad(_Load event, Emitter<AccountWalletState> emit) async {
    emit(const AccountWalletState.loading());
    try {
      final accounts = await _walletRepo.getAccountViews();
      final selection = await _walletRepo.getActiveSelection();

      // Emit immediately with DB data so the UI renders without waiting
      // for network calls.
      final expandedIds = selection != null
          ? {selection.$1.id}
          : const <String>{};
      emit(
        AccountWalletState.loaded(
          accounts: accounts,
          activeWalletId: selection?.$2.id,
          activeAccountId: selection?.$1.id,
          expandedAccountIds: expandedIds,
        ),
      );

      // Enrich with cached balances immediately.
      final addresses = accounts
          .expand((a) => a.wallets)
          .map((w) => w.address)
          .toList();
      final cachedBalances = await _loadCachedBalances(addresses);
      var enriched = _enrichAccountBalances(accounts, cachedBalances);

      // Then enrich with profile data from the API in the background.
      enriched = await _enrichWithProfiles(enriched);
      emit(
        AccountWalletState.loaded(
          accounts: enriched,
          activeWalletId: selection?.$2.id,
          activeAccountId: selection?.$1.id,
          expandedAccountIds: expandedIds,
        ),
      );

      // Fetch fresh balances from API.
      final freshBalances = await _fetchFreshBalances(addresses);
      if (freshBalances.isNotEmpty) {
        final current = state;
        if (current is AccountWalletLoaded) {
          emit(
            current.copyWith(
              accounts: _enrichAccountBalances(current.accounts, freshBalances),
            ),
          );
        }
      }
    } catch (e) {
      // For `unknown` kinds AppFailure.message is error.toString(), which can
      // carry exception/PII detail — surface fixed copy instead and keep the
      // raw detail in debug logs only. Validation copy stays verbatim.
      final failure = AppFailure.from(e);
      AppLogger.debug('AccountWalletBloc', 'load error: ${failure.message}');
      final message = failure.kind == AppFailureKind.validation
          ? failure.message
          : 'Could not load your accounts. Please try again.';
      emit(AccountWalletState.error(message));
    }
  }

  Future<void> _onSwitchWallet(
    _SwitchWallet event,
    Emitter<AccountWalletState> emit,
  ) async {
    try {
      await _walletManager.switchWalletById(event.walletId);

      // Re-login with new address
      final address = await _walletManager.getAddress();
      await _authService.switchWallet(address);

      // Emit loaded state directly (no intermediate loading() state) so
      // BlocListeners can detect the activeWalletId change in a single
      // loaded→loaded transition.
      final accounts = await _walletRepo.getAccountViews();
      final selection = await _walletRepo.getActiveSelection();
      final expandedIds = selection != null
          ? {selection.$1.id}
          : const <String>{};

      emit(
        AccountWalletState.loaded(
          accounts: accounts,
          activeWalletId: selection?.$2.id,
          activeAccountId: selection?.$1.id,
          expandedAccountIds: expandedIds,
        ),
      );

      // Enrich with profiles in the background
      final enriched = await _enrichWithProfiles(accounts);
      emit(
        AccountWalletState.loaded(
          accounts: enriched,
          activeWalletId: selection?.$2.id,
          activeAccountId: selection?.$1.id,
          expandedAccountIds: expandedIds,
        ),
      );
    } catch (e) {
      AppLogger.debug('AccountWalletBloc', 'switchWallet error: $e');
      add(const AccountWalletEvent.load());
    }
  }

  void _onToggleExpanded(
    _ToggleAccountExpanded event,
    Emitter<AccountWalletState> emit,
  ) {
    final current = state;
    if (current is AccountWalletLoaded) {
      final expanded = Set<String>.from(current.expandedAccountIds);
      if (expanded.contains(event.accountId)) {
        expanded.remove(event.accountId);
      } else {
        expanded.add(event.accountId);
      }
      emit(current.copyWith(expandedAccountIds: expanded));
    }
  }

  Future<void> _onRefreshBalances(
    _RefreshBalances event,
    Emitter<AccountWalletState> emit,
  ) async {
    final current = state;
    if (current is AccountWalletLoaded) {
      final addresses = current.accounts
          .expand((a) => a.wallets)
          .map((w) => w.address)
          .toList();
      final freshBalances = await _fetchFreshBalances(addresses);
      if (freshBalances.isNotEmpty) {
        emit(
          current.copyWith(
            accounts: _enrichAccountBalances(current.accounts, freshBalances),
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Balance helpers
  // ---------------------------------------------------------------------------

  Future<Map<String, double>> _loadCachedBalances(
    List<String> addresses,
  ) async {
    final balances = <String, double>{};
    for (final address in addresses) {
      try {
        final total = await cachedWalletTotalUsd(address);
        if (total != null) {
          balances[address] = total;
        }
      } catch (e) {
        AppLogger.debug(
          'AccountWalletBloc',
          'cached balance error for $address: $e',
        );
      }
    }
    return balances;
  }

  /// 🛑 Routed per chain. This runs for *every* wallet on each app resume, so
  /// sending a `0x…`/`tz1…` address down the Solana path did not just return
  /// nothing — its write-through `cacheBalances(address, [])` deleted that
  /// wallet's real Ethereum/Tezos rows from the shared cache, which is what the
  /// header's cache-first paint reads. See [fetchWalletTotalUsd].
  Future<Map<String, double>> _fetchFreshBalances(
    List<String> addresses,
  ) async {
    final balances = <String, double>{};
    for (final address in addresses) {
      try {
        balances[address] = await fetchWalletTotalUsd(address);
      } catch (e) {
        AppLogger.debug(
          'AccountWalletBloc',
          'fresh balance error for $address: $e',
        );
      }
    }
    return balances;
  }

  List<Account> _enrichAccountBalances(
    List<Account> accounts,
    Map<String, double> balances,
  ) {
    return accounts
        .map(
          (a) => a.copyWith(
            wallets: a.wallets
                .map(
                  (w) => balances.containsKey(w.address)
                      ? w.copyWith(balanceUsd: balances[w.address])
                      : w,
                )
                .toList(),
          ),
        )
        .toList();
  }
}
