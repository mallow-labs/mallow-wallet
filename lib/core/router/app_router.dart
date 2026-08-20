import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../shared/theme/mallow_theme.dart';
import '../../shared/widgets/flow_unavailable_sheet.dart';
import '../../shared/widgets/mallow_svg_icon.dart';
import '../config/remote_config.dart';
import '../../features/accounts/screens/add_account_screen.dart';
import '../../features/accounts/screens/add_wallet_screen.dart';
import '../../features/accounts/screens/import_private_key_screen.dart';
import '../../features/accounts/screens/import_wallets_from_phrase_screen.dart';
import '../../features/accounts/screens/watch_address_screen.dart';
import '../../features/activity/screens/activity_screen.dart';
import '../../features/offers/screens/offers_screen.dart';
import '../../features/ledger/screens/ledger_scan_screen.dart';
import '../../features/moderation/screens/blocked_accounts_screen.dart';
import '../../features/notifications/screens/notifications_screen.dart';
import '../../features/settings/screens/about_screen.dart';
import '../../features/settings/screens/active_networks_screen.dart';
import '../../features/settings/screens/account_privacy_screen.dart';
import '../../features/settings/screens/change_pin_screen.dart';
import '../../features/settings/screens/delete_account_screen.dart';
import '../../features/settings/screens/private_key_reveal_screen.dart';
import '../../features/settings/screens/private_key_warning_screen.dart';
import '../../features/settings/screens/recovery_phrase_screen.dart';
import '../../features/settings/screens/recovery_phrase_warning_screen.dart';
import '../../features/settings/screens/recovery_phrase_words_screen.dart';
import '../../features/settings/screens/show_secrets_screen.dart';
import '../../features/settings/screens/report_bug_screen.dart';
import '../../features/settings/screens/reset_app_screen.dart';
import '../../features/settings/screens/security_privacy_screen.dart';
import '../../features/settings/screens/edit_account_screen.dart';
import '../../features/settings/screens/edit_accounts_screen.dart';
import '../../features/settings/screens/edit_profiles_screen.dart';
import '../../features/settings/screens/edit_wallet_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/settings/screens/preferences_screen.dart';
import '../../features/settings/screens/priority_fee_screen.dart';
import '../../features/settings/screens/display_language_screen.dart';
import '../../features/settings/screens/preferred_explorer_screen.dart';
import '../../features/settings/screens/currency_screen.dart';
import '../../features/settings/screens/app_theme_screen.dart';
import '../../features/artwork/screens/artwork_detail_screen.dart';
import '../../features/artwork/screens/transfer_artwork_chooser_screen.dart';
import '../../features/onboarding/screens/biometric_setup_screen.dart';
import '../../features/onboarding/screens/import_wallet_screen.dart';
import '../../features/onboarding/screens/pin_setup_screen.dart';
import '../../features/onboarding/screens/seed_phrase_display_screen.dart';
import '../../features/onboarding/screens/wallet_intro_screen.dart';
import '../../features/onboarding/screens/wallet_recovery_screen.dart';
import '../../features/onboarding/screens/welcome_screen.dart';
import '../../features/portfolio/services/portfolio_bloc.dart';
import '../../features/profile/screens/collection_screen.dart';
import '../../features/profile/screens/followers_screen.dart';
import '../../features/profile/services/followers_bloc.dart' show FollowersTab;
import '../../features/profile/screens/edit_profile_screen.dart';
import '../../features/profile/screens/user_profile_screen.dart';
import '../../features/collection/screens/manage_collection_artworks_screen.dart';
import '../../features/mint/screens/edit_nft_screen.dart';
import '../../features/mint/screens/mint_1of1_screen.dart';
import '../../features/mint/screens/mint_type_chooser_screen.dart';
import '../../features/auction/screens/auction_form_screen.dart';
import '../../features/fixed_price/screens/fixed_price_form_screen.dart';
import '../../features/sell/screens/sell_type_chooser_screen.dart';
import 'auth_state_notifier.dart';
import 'nav_bar_state.dart';
import 'tab_navigator.dart';

import '../../shared/utils/chain.dart';

/// Route paths used throughout the app.
abstract class AppRoutes {
  // Onboarding
  static const walletRecovery = '/wallet-recovery';
  static const welcome = '/welcome';
  static const walletIntro = '/onboarding/wallet-intro';
  static const seedPhraseDisplay = '/onboarding/seed-phrase';
  static const importWallet = '/onboarding/import';
  static const biometricSetup = '/onboarding/biometric';
  static const pinSetup = '/onboarding/pin';

  // Main tabs
  static const home = '/';
  static const tokens = '/tokens';
  static const portfolio = '/portfolio';

  // Detail screens
  static const artworkDetail = '/artwork/:mint';
  static const activity = '/activity';
  static const notifications = '/notifications';
  static const offers = '/offers';

  // Profile
  static const profile = '/profile/:address';
  static const profileByUsername = '/profile/u/:username';
  static const followers = '/profile/:address/followers';
  static const editProfile = '/profile/edit';

  // Deep-link entry points — mirror mallow.art's canonical web URLs so a
  // tapped universal/app link resolves to the same screen as the in-app
  // `/profile/*` routes. See DeepLinkService.
  static const collection = '/collection/:id';
  static const deepLinkProfile = '/a/:address';
  static const deepLinkProfileByUsername = '/u/:username';

  /// Build the deep-link path for a collection by id (collection mint).
  static String collectionPath(String id) => '/collection/$id';

  /// Build the deep-link path for a profile by wallet address.
  static String deepLinkProfilePath(String address) => '/a/$address';

  /// Build the deep-link path for a profile by username.
  static String deepLinkProfileByUsernamePath(String username) =>
      '/u/$username';

  // Phase 2: Tokens/Wallet (confirmation via modal sheets)
  static const tokenDetail = '/token/:mint';

  // Mint flow (NFT creation)
  static const mintChooser = '/mint';
  static const mint1Of1 = '/mint/1of1';
  static const mintEditions = '/mint/editions';
  static const mintCollection = '/mint/collection';

  /// Edit an existing NFT — `:mint` is the mint account.
  static const editNft = '/edit/:mint';

  /// Build the path for navigating to the edit screen.
  static String editNftPath(String mintAccount) => '/edit/$mintAccount';

  /// Edit an existing collection NFT — `:mint` is the collection mint.
  static const editCollection = '/edit-collection/:mint';

  /// Build the path for navigating to the edit-collection screen.
  static String editCollectionPath(String mintAccount) =>
      '/edit-collection/$mintAccount';

  /// Add artworks to a collection — `:mint` is the collection mint.
  static const collectionArtworks = '/collection/:mint/artworks';

  /// Build the path for the add-artworks-to-collection screen.
  static String collectionArtworksPath(String mintAccount) =>
      '/collection/$mintAccount/artworks';

  // Transfer flow (send an owned artwork) — FAB entry point. Picks an
  // artwork, then runs the transfer flow on top.
  static const transferChooser = '/transfer';

  // Sell flow (sale creation)
  static const sellChooser = '/sell';
  static const sellAuction = '/sell/auction';
  static const sellFixedPrice = '/sell/fixed-price';

  // Settings
  static const settings = '/settings';
  static const activeNetworks = '/settings/active-networks';
  static const aboutMallow = '/settings/about';
  static const securityPrivacy = '/settings/security-privacy';
  static const preferences = '/settings/preferences';
  static const displayLanguage = '/settings/preferences/language';
  static const preferredExplorer = '/settings/preferences/explorer';
  static const currency = '/settings/preferences/currency';
  static const appTheme = '/settings/preferences/theme';
  static const priorityFee = '/settings/preferences/priority-fee';
  static const changePin = '/settings/security-privacy/change-pin';
  static const accountPrivacy = '/settings/security-privacy/account-privacy';
  static const recoveryPhrase = '/settings/security-privacy/recovery-phrase';
  static const recoveryPhraseWarning =
      '/settings/security-privacy/recovery-phrase/warning';
  static const recoveryPhraseWords =
      '/settings/security-privacy/recovery-phrase/words';
  static const privateKeyWarning =
      '/settings/security-privacy/recovery-phrase/private-key/warning';
  static const privateKeyReveal =
      '/settings/security-privacy/recovery-phrase/private-key/reveal';
  static const reportBug = '/settings/security-privacy/report-bug';
  static const resetApp = '/settings/security-privacy/reset-app';

  /// Management screen for the viewer's block list (`GET /v2/blocks`). Lives
  /// under Security & Privacy, which is already behind the reauth gate.
  static const blockedAccounts = '/settings/security-privacy/blocked-accounts';

  /// Confirmation screen for `POST /v2/user/delete`. Under Security & Privacy
  /// (so it inherits the reauth gate) and beside [resetApp], which it must not
  /// be confused with — this deletes the mallow profile, not the wallets.
  static const deleteAccount = '/settings/security-privacy/delete-account';

  // Edit wallet
  static const editWallet = '/settings/edit-wallet/:walletId';
  static String editWalletPath(String walletId) =>
      '/settings/edit-wallet/$walletId';

  // Edit accounts (account-level management from the drawer)
  static const editAccounts = '/settings/edit-accounts';
  static const editAccount = '/settings/edit-account/:accountId';
  static String editAccountPath(String accountId) =>
      '/settings/edit-account/$accountId';

  // Edit profiles (profile-level management from the drawer Profiles tab)
  static const editProfiles = '/settings/edit-profiles';

  // Wallet management (new routes — preferred)
  static const addWalletGlobal = '/wallets/add';
  static const createSeedPhrase = '/wallets/create-seed';
  static const importSeedPhrase = '/wallets/import-seed';
  static const selectPhraseForImport = '/wallets/select-phrase';
  static const importFromPhraseGlobal =
      '/wallets/import-from-phrase/:seedPhraseId';
  static const importPrivateKeyGlobal = '/wallets/import-private-key';
  static const watchAddressGlobal = '/wallets/watch-address';

  // Ledger hardware wallet
  static const ledgerScan = '/wallets/ledger-scan';

  /// Generate import-from-phrase route for a seed phrase.
  static String importFromPhraseGlobalPath(String seedPhraseId) =>
      '/wallets/import-from-phrase/$seedPhraseId';

  // Account management (legacy `/accounts/*` routes, superseded by the
  // `/wallets/*` paths above — kept so links held by older builds still
  // resolve. Remove once those builds have aged out.)
  static const addAccount = '/accounts/add';
  static const createAccountSeed = '/accounts/create-seed';
  static const importAccountSeed = '/accounts/import-seed';
  static const addWallet = '/accounts/:accountId/add-wallet';
  static const importFromPhrase = '/accounts/:accountId/import-from-phrase';
  static const importRecoveryPhrase =
      '/accounts/:accountId/import-recovery-phrase';
  static const importPrivateKey = '/accounts/:accountId/import-private-key';
  static const watchAddress = '/accounts/:accountId/watch-address';

  /// Generate artwork detail route with mint address
  static String artworkDetailPath(String mint) => '/artwork/$mint';

  /// Generate token detail route with mint address
  static String tokenDetailPath(String mint) => '/token/$mint';

  /// Generate profile route with wallet address
  static String profilePath(String address) => '/profile/$address';

  /// Generate followers route for a profile address
  static String followersPath(String address) => '/profile/$address/followers';

  /// Generate profile route with username
  static String profileByUsernamePath(String username) =>
      '/profile/u/$username';

  /// Generate add-wallet route for an account
  static String addWalletPath(String accountId) =>
      '/accounts/$accountId/add-wallet';

  /// Generate import-from-phrase route for an account
  static String importFromPhrasePath(String accountId) =>
      '/accounts/$accountId/import-from-phrase';

  /// Generate import-recovery-phrase route for an account
  static String importRecoveryPhrasePath(String accountId) =>
      '/accounts/$accountId/import-recovery-phrase';

  /// Generate import-private-key route for an account
  static String importPrivateKeyPath(String accountId) =>
      '/accounts/$accountId/import-private-key';

  /// Generate watch-address route for an account
  static String watchAddressPath(String accountId) =>
      '/accounts/$accountId/watch-address';

  /// Root navigator key for overlay dialogs (action menu, etc.)
  static final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');
}

/// Creates and configures the app router.
///
/// Uses GoRouter with [AuthStateNotifier] for reactive auth state handling.
/// When auth state changes (wallet created, PIN set, etc.), the router
/// automatically reevaluates redirects.
GoRouter createRouter({required AuthStateNotifier authStateNotifier}) {
  return GoRouter(
    navigatorKey: AppRoutes.rootNavigatorKey,
    initialLocation: _getInitialLocation(authStateNotifier),
    refreshListenable: authStateNotifier,
    observers: [navBarRouteObserver],
    redirect: (context, state) {
      final isOnboarding =
          state.matchedLocation.startsWith('/onboarding') ||
          state.matchedLocation == AppRoutes.welcome ||
          state.matchedLocation == AppRoutes.walletRecovery;

      // Import routes used by both onboarding ("I already have a wallet")
      // and post-onboarding add-wallet flows. Excluded from `isOnboarding`
      // so they don't bounce post-onboarding users to home, but allowed
      // through the no-wallet guard below.
      final isWalletImportRoute =
          state.matchedLocation == AppRoutes.importPrivateKeyGlobal ||
          state.matchedLocation == AppRoutes.ledgerScan;

      final hasWallet = authStateNotifier.hasWallet;
      final hasCompletedOnboarding = authStateNotifier.hasCompletedOnboarding;
      final hasStaleKeychain = authStateNotifier.hasStaleKeychain;

      // Stale Keychain detected — redirect to recovery screen
      if (hasStaleKeychain &&
          state.matchedLocation != AppRoutes.walletRecovery) {
        return AppRoutes.walletRecovery;
      }

      // If no wallet and trying to access main app, redirect to welcome
      if (!hasWallet && !isOnboarding && !isWalletImportRoute) {
        return AppRoutes.welcome;
      }

      // If has wallet but hasn't completed onboarding, continue onboarding
      // (This handles app restart during onboarding)
      if (hasWallet && !hasCompletedOnboarding && !isOnboarding) {
        return AppRoutes.biometricSetup;
      }

      // If fully onboarded and on onboarding screens, redirect to home
      // (but not when stale keychain is active — recovery screen IS onboarding)
      if (hasCompletedOnboarding && isOnboarding && !hasStaleKeychain) {
        return AppRoutes.home;
      }

      return null; // No redirect needed
    },
    errorBuilder: (context, state) =>
        _ErrorScreen(error: state.error?.toString() ?? 'Page not found'),
    routes: [
      // Recovery route (stale Keychain after iOS reinstall)
      GoRoute(
        path: AppRoutes.walletRecovery,
        builder: (context, state) => const WalletRecoveryScreen(),
      ),

      // Onboarding routes (outside shell)
      GoRoute(
        path: AppRoutes.welcome,
        builder: (context, state) => const WelcomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.walletIntro,
        builder: (context, state) => const WalletIntroScreen(),
      ),
      GoRoute(
        path: AppRoutes.seedPhraseDisplay,
        builder: (context, state) {
          // Accepts String (legacy) or Map with isAddingAccount flag
          final extra = state.extra;
          String mnemonic = '';
          bool isAddingAccount = false;

          if (extra is String) {
            mnemonic = extra;
          } else if (extra is Map) {
            mnemonic = extra['mnemonic'] as String? ?? '';
            isAddingAccount = extra['isAddingAccount'] as bool? ?? false;
          }

          return SeedPhraseDisplayScreen(
            mnemonic: mnemonic,
            isAddingAccount: isAddingAccount,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.importWallet,
        builder: (context, state) {
          final extra = state.extra;
          bool isAddingAccount = false;
          String? accountId;

          if (extra is Map) {
            isAddingAccount = extra['isAddingAccount'] as bool? ?? false;
            accountId = extra['accountId'] as String?;
          }

          return ImportWalletScreen(
            isAddingAccount: isAddingAccount,
            accountId: accountId,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.biometricSetup,
        builder: (context, state) => const BiometricSetupScreen(),
      ),
      GoRoute(
        path: AppRoutes.pinSetup,
        builder: (context, state) => const PinSetupScreen(),
      ),

      // Main app with bottom navigation
      // TabNavigator handles tab switching with transitions internally
      GoRoute(
        path: AppRoutes.home,
        pageBuilder: (context, state) =>
            const NoTransitionPage(child: TabNavigator()),
      ),
      GoRoute(
        path: AppRoutes.portfolio,
        pageBuilder: (context, state) =>
            const NoTransitionPage(child: TabNavigator(initialTab: 1)),
      ),
      GoRoute(
        path: AppRoutes.tokens,
        pageBuilder: (context, state) =>
            const NoTransitionPage(child: TabNavigator(initialTab: 2)),
      ),

      // Detail routes (outside shell, full screen)
      GoRoute(
        path: AppRoutes.artworkDetail,
        builder: (context, state) {
          final mint = state.pathParameters['mint']!;
          // Optional shared-element tag threaded from the originating tile so
          // the artwork image can fly in as a Hero. Only a String is honoured;
          // any other `extra` payload is ignored.
          final heroTag = state.extra is String ? state.extra as String : null;
          return ArtworkDetailScreen(mintAccount: mint, heroTag: heroTag);
        },
      ),

      // Activity route (outside shell, full screen)
      GoRoute(
        path: AppRoutes.activity,
        builder: (context, state) => const ActivityScreen(),
      ),

      // Offers route (outside shell, full screen)
      GoRoute(
        path: AppRoutes.offers,
        builder: (context, state) => const OffersScreen(),
      ),

      // Notifications route (outside shell, full screen)
      GoRoute(
        path: AppRoutes.notifications,
        builder: (context, state) => const NotificationsScreen(),
      ),

      // Settings route
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),

      // Edit Wallet route
      GoRoute(
        path: AppRoutes.editWallet,
        builder: (context, state) {
          final walletId = state.pathParameters['walletId']!;
          return EditWalletScreen(walletId: walletId);
        },
      ),

      // Edit Accounts routes (account-level management from the drawer)
      GoRoute(
        path: AppRoutes.editAccounts,
        builder: (context, state) => const EditAccountsScreen(),
      ),
      GoRoute(
        path: AppRoutes.editAccount,
        builder: (context, state) {
          final accountId = state.pathParameters['accountId']!;
          return EditAccountScreen(accountId: accountId);
        },
      ),
      GoRoute(
        path: AppRoutes.editProfiles,
        builder: (context, state) => const EditProfilesScreen(),
      ),

      // Active Networks route
      GoRoute(
        path: AppRoutes.activeNetworks,
        builder: (context, state) => const ActiveNetworksScreen(),
      ),

      // About mallow route
      GoRoute(
        path: AppRoutes.aboutMallow,
        builder: (context, state) => const AboutScreen(),
      ),

      // Security & Privacy route
      GoRoute(
        path: AppRoutes.securityPrivacy,
        builder: (context, state) => const SecurityPrivacyScreen(),
      ),

      // Account Privacy route
      GoRoute(
        path: AppRoutes.accountPrivacy,
        builder: (context, state) => const AccountPrivacyScreen(),
      ),

      // Change PIN route
      GoRoute(
        path: AppRoutes.changePin,
        builder: (context, state) => const ChangePinScreen(),
      ),

      // Recovery Phrase / secrets routes
      GoRoute(
        path: AppRoutes.recoveryPhrase,
        // `extra == true` only from the gated in-app "Show secrets" tap; any
        // other entry (deep link, programmatic push) leaves it null and the
        // screen self-gates before revealing secrets.
        builder: (context, state) =>
            ShowSecretsScreen(preAuthenticated: state.extra == true),
      ),
      GoRoute(
        path: AppRoutes.recoveryPhraseWarning,
        builder: (context, state) {
          final words = state.extra as List<String>;
          return RecoveryPhraseWarningScreen(words: words);
        },
      ),
      GoRoute(
        path: AppRoutes.recoveryPhraseWords,
        builder: (context, state) {
          final words = state.extra as List<String>;
          return RecoveryPhraseWordsScreen(words: words);
        },
      ),
      GoRoute(
        path: AppRoutes.privateKeyWarning,
        builder: (context, state) {
          final key = state.extra as String;
          return PrivateKeyWarningScreen(privateKey: key);
        },
      ),
      GoRoute(
        path: AppRoutes.privateKeyReveal,
        builder: (context, state) {
          final key = state.extra as String;
          return PrivateKeyRevealScreen(privateKey: key);
        },
      ),

      // Report a Bug route
      GoRoute(
        path: AppRoutes.reportBug,
        builder: (context, state) => const ReportBugScreen(),
      ),

      // Reset App route
      GoRoute(
        path: AppRoutes.resetApp,
        builder: (context, state) => const ResetAppScreen(),
      ),

      // Blocked accounts route
      GoRoute(
        path: AppRoutes.blockedAccounts,
        builder: (context, state) => const BlockedAccountsScreen(),
      ),

      // Delete account route
      GoRoute(
        path: AppRoutes.deleteAccount,
        builder: (context, state) => const DeleteAccountScreen(),
      ),

      // Preferences routes
      GoRoute(
        path: AppRoutes.preferences,
        builder: (context, state) => const PreferencesScreen(),
      ),
      GoRoute(
        path: AppRoutes.displayLanguage,
        builder: (context, state) => const DisplayLanguageScreen(),
      ),
      GoRoute(
        path: AppRoutes.preferredExplorer,
        builder: (context, state) => const PreferredExplorerScreen(),
      ),
      GoRoute(
        path: AppRoutes.currency,
        builder: (context, state) => const CurrencyScreen(),
      ),
      GoRoute(
        path: AppRoutes.appTheme,
        builder: (context, state) => const AppThemeScreen(),
      ),
      GoRoute(
        path: AppRoutes.priorityFee,
        builder: (context, state) => const PriorityFeeScreen(),
      ),

      // Profile routes
      GoRoute(
        path: AppRoutes.profileByUsername,
        builder: (context, state) {
          final username = state.pathParameters['username']!;
          return UserProfileScreen(username: username);
        },
      ),
      // Declared before `/profile/:address` so the static "edit" segment is
      // not captured as an address path parameter.
      GoRoute(
        path: AppRoutes.editProfile,
        builder: (context, state) => EditProfileScreen(
          forceCreate: state.uri.queryParameters['create'] == 'true',
        ),
      ),
      GoRoute(
        path: AppRoutes.profile,
        builder: (context, state) {
          final address = state.pathParameters['address']!;
          return UserProfileScreen(address: address);
        },
      ),
      GoRoute(
        path: AppRoutes.followers,
        builder: (context, state) {
          final address = state.pathParameters['address']!;
          // All linked addresses are passed via extra when available so the
          // lists cover the full profile (matches the webapp's
          // profileUserAddresses); fall back to the path address.
          final extra = state.extra;
          final addresses = extra is List<String> && extra.isNotEmpty
              ? extra
              : [address];
          // `?tab=following` opens straight on the Following list — the
          // profile header's Following count links there, matching the
          // webapp's follower-manager modal opening on its `initialTab`.
          return FollowersScreen(
            addresses: addresses,
            initialTab: state.uri.queryParameters['tab'] == 'following'
                ? FollowersTab.following
                : FollowersTab.all,
          );
        },
      ),

      // Deep-link routes — match mallow.art's canonical web paths so verified
      // universal/app links resolve to the same screens. Handled by
      // DeepLinkService; not used for in-app navigation.
      GoRoute(
        path: AppRoutes.deepLinkProfileByUsername,
        builder: (context, state) {
          final username = state.pathParameters['username']!;
          return UserProfileScreen(username: username);
        },
      ),
      GoRoute(
        path: AppRoutes.deepLinkProfile,
        builder: (context, state) {
          final address = state.pathParameters['address']!;
          return UserProfileScreen(address: address);
        },
      ),
      GoRoute(
        path: AppRoutes.collection,
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          // Minimal group — CollectionScreen fetches the name, creator and
          // artworks itself via getCollectionByMint(collectionMint).
          return CollectionScreen(
            group: ArtGroup(
              id: id,
              type: ArtGroupType.collection,
              name: '',
              thumbnailUrl: null,
              artworkCount: 0,
              collectionMint: id,
            ),
          );
        },
      ),

      // Mint flow (NFT creation)
      GoRoute(
        path: AppRoutes.mintChooser,
        builder: (context, state) => const MintTypeChooserScreen(),
      ),
      GoRoute(
        path: AppRoutes.mint1Of1,
        builder: (context, state) => flowGatedScreen(const [
          FlowKey.solana(AppFlow.nftMint),
        ], () => const Mint1Of1Screen()),
      ),
      GoRoute(
        path: AppRoutes.mintEditions,
        builder: (context, state) => flowGatedScreen(const [
          FlowKey.solana(AppFlow.editionMint),
        ], () => const Mint1Of1Screen(mintType: MintCreateType.editions)),
      ),
      GoRoute(
        path: AppRoutes.mintCollection,
        builder: (context, state) => flowGatedScreen(const [
          FlowKey.solana(AppFlow.collectionMint),
        ], () => const Mint1Of1Screen(mintType: MintCreateType.collection)),
      ),
      GoRoute(
        path: AppRoutes.editNft,
        builder: (context, state) {
          final mint = state.pathParameters['mint']!;
          // Minting and editing are separate builders (`/tx/nft/mint` vs
          // `/tx/nft/edit`), hence separate cells — killing a broken mint must
          // leave owners able to fix their metadata.
          return flowGatedScreen(const [
            FlowKey.solana(AppFlow.nftEdit),
          ], () => EditNftScreen(mintAccount: mint));
        },
      ),
      GoRoute(
        path: AppRoutes.editCollection,
        builder: (context, state) {
          final mint = state.pathParameters['mint']!;
          return flowGatedScreen(const [
            FlowKey.solana(AppFlow.collectionEdit),
          ], () => EditNftScreen(mintAccount: mint, isCollection: true));
        },
      ),
      GoRoute(
        path: AppRoutes.collectionArtworks,
        builder: (context, state) {
          final mint = state.pathParameters['mint']!;
          return flowGatedScreen(
            const [FlowKey.solana(AppFlow.collectionArtworksEdit)],
            () => ManageCollectionArtworksScreen(
              collectionMint: mint,
              collectionName: state.uri.queryParameters['name'],
            ),
          );
        },
      ),

      // Transfer flow (send an owned artwork) — FAB entry point.
      GoRoute(
        path: AppRoutes.transferChooser,
        // The chooser spans both transferable chains and no artwork has been
        // picked yet, so it closes only when neither chain can transfer. The
        // per-artwork cell is enforced inside `runTransferArtworkFlow`, which
        // knows the chain.
        builder: (context, state) => flowGatedScreen(const [
          FlowKey.solana(AppFlow.nftTransfer),
          FlowKey(Chain.ethereum, AppFlow.nftTransfer),
        ], () => const TransferArtworkChooserScreen()),
      ),

      // Sell flow (sale creation)
      GoRoute(
        path: AppRoutes.sellChooser,
        builder: (context, state) {
          final mint = state.uri.queryParameters['mint'];
          final supplyType = _parseSupplyType(
            state.uri.queryParameters['supplyType'],
          );
          // Fronts both sale kinds — stays open while either is live, and each
          // destination route below re-checks its own cell.
          return flowGatedScreen(
            const [
              FlowKey.solana(AppFlow.fixedPriceCreate),
              FlowKey.solana(AppFlow.auctionCreate),
            ],
            () => SellTypeChooserScreen(
              mintAccount: mint,
              supplyType: supplyType,
            ),
          );
        },
      ),
      GoRoute(
        path: AppRoutes.sellAuction,
        builder: (context, state) {
          final mintAccount = state.uri.queryParameters['mint'];
          return flowGatedScreen(const [
            FlowKey.solana(AppFlow.auctionCreate),
          ], () => AuctionFormScreen(mintAccount: mintAccount));
        },
      ),
      GoRoute(
        path: AppRoutes.sellFixedPrice,
        builder: (context, state) {
          final mintAccount = state.uri.queryParameters['mint'];
          return flowGatedScreen(const [
            FlowKey.solana(AppFlow.fixedPriceCreate),
          ], () => FixedPriceFormScreen(mintAccount: mintAccount));
        },
      ),

      // Account management routes
      GoRoute(
        path: AppRoutes.addAccount,
        builder: (context, state) => const AddAccountScreen(),
      ),
      GoRoute(
        path: AppRoutes.createAccountSeed,
        builder: (context, state) =>
            const SeedPhraseDisplayScreen(mnemonic: '', isAddingAccount: true),
      ),
      GoRoute(
        path: AppRoutes.importAccountSeed,
        builder: (context, state) =>
            const ImportWalletScreen(isAddingAccount: true),
      ),
      GoRoute(
        path: AppRoutes.addWallet,
        builder: (context, state) {
          final accountId = state.pathParameters['accountId']!;
          return AddWalletScreen(accountId: accountId);
        },
      ),
      GoRoute(
        path: AppRoutes.importFromPhrase,
        builder: (context, state) {
          final seedPhraseId = state.pathParameters['accountId']!;
          final mnemonic = state.extra as String?;
          return ImportWalletsFromPhraseScreen(
            seedPhraseId: mnemonic == null ? seedPhraseId : null,
            mnemonic: mnemonic,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.importRecoveryPhrase,
        builder: (context, state) {
          final accountId = state.pathParameters['accountId']!;
          return ImportWalletScreen(accountId: accountId);
        },
      ),
      GoRoute(
        path: AppRoutes.importPrivateKey,
        builder: (context, state) {
          final accountId = state.pathParameters['accountId']!;
          return ImportPrivateKeyScreen(accountId: accountId);
        },
      ),
      GoRoute(
        path: AppRoutes.watchAddress,
        builder: (context, state) {
          final accountId = state.pathParameters['accountId']!;
          return WatchAddressScreen(accountId: accountId);
        },
      ),

      // -----------------------------------------------------------------------
      // Wallet management routes (current /wallets/* paths — these supersede
      // the legacy /accounts/* aliases)
      // -----------------------------------------------------------------------
      GoRoute(
        path: AppRoutes.addWalletGlobal,
        builder: (context, state) => const AddAccountScreen(),
      ),
      GoRoute(
        path: AppRoutes.createSeedPhrase,
        builder: (context, state) =>
            const SeedPhraseDisplayScreen(mnemonic: '', isAddingAccount: true),
      ),
      GoRoute(
        path: AppRoutes.importSeedPhrase,
        builder: (context, state) =>
            const ImportWalletScreen(isAddingAccount: true),
      ),
      GoRoute(
        path: AppRoutes.selectPhraseForImport,
        builder: (context, state) =>
            const RecoveryPhraseScreen(mode: PhraseListMode.import),
      ),
      GoRoute(
        path: AppRoutes.importFromPhraseGlobal,
        builder: (context, state) {
          final seedPhraseId = state.pathParameters['seedPhraseId']!;
          final mnemonic = state.extra as String?;
          return ImportWalletsFromPhraseScreen(
            seedPhraseId: mnemonic == null ? seedPhraseId : null,
            mnemonic: mnemonic,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.importPrivateKeyGlobal,
        builder: (context, state) =>
            const ImportPrivateKeyScreen(accountId: ''),
      ),
      GoRoute(
        path: AppRoutes.watchAddressGlobal,
        builder: (context, state) => const WatchAddressScreen(accountId: ''),
      ),

      // Ledger hardware wallet
      GoRoute(
        path: AppRoutes.ledgerScan,
        builder: (context, state) => const LedgerScanScreen(),
      ),
    ],
  );
}

/// Maps a `?supplyType=…` query param back to the [SupplyType] enum.
/// Values mirror the `@JsonValue` strings on [SupplyType].
SupplyType? _parseSupplyType(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return switch (raw) {
    '1/1' => SupplyType.oneOfOne,
    'limited-edition' => SupplyType.limitedEdition,
    'open-edition' => SupplyType.openEdition,
    'edition-print' => SupplyType.editionPrint,
    'collection' => SupplyType.collection,
    _ => null,
  };
}

String _getInitialLocation(AuthStateNotifier notifier) {
  if (notifier.hasStaleKeychain) {
    return AppRoutes.walletRecovery;
  }
  if (!notifier.hasWallet) {
    return AppRoutes.welcome;
  }
  if (!notifier.hasCompletedOnboarding) {
    return AppRoutes.biometricSetup;
  }
  return AppRoutes.home;
}

/// Extension for navigation convenience methods.
extension AppRouterExtension on BuildContext {
  /// Navigate to artwork detail screen
  void goToArtwork(String mint) {
    push(AppRoutes.artworkDetailPath(mint));
  }

  /// Navigate to home tab
  void goToHome() {
    go(AppRoutes.home);
  }

  /// Navigate to tokens tab
  void goToTokens() {
    go(AppRoutes.tokens);
  }

  /// Navigate to portfolio tab
  void goToPortfolio() {
    go(AppRoutes.portfolio);
  }

  /// Navigate to activity screen
  void goToActivity() {
    go(AppRoutes.activity);
  }

  /// Navigate to user profile screen
  void goToProfile(String address) {
    push(AppRoutes.profilePath(address));
  }

  /// Navigate to user profile screen by username
  void goToProfileByUsername(String username) {
    push(AppRoutes.profileByUsernamePath(username));
  }

  /// Navigate to a profile's followers screen. Pass all linked [addresses]
  /// when known so the lists cover the full profile. [showFollowing] opens on
  /// the Following tab instead of All.
  void goToFollowers(
    String address, {
    List<String>? addresses,
    bool showFollowing = false,
  }) {
    final path = AppRoutes.followersPath(address);
    push(showFollowing ? '$path?tab=following' : path, extra: addresses);
  }
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: MallowSvgIcon(
            'assets/icons/arrow_left.svg',
            color: context.mallowColors.textPrimary,
          ),
          onPressed: () {
            if (canPop) {
              Navigator.of(context).pop();
            } else {
              context.go(AppRoutes.home);
            }
          },
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(MallowTheme.spacingLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MallowSvgIcon(
                'assets/icons/alert_triangle.svg',
                width: 64,
                height: 64,
                color: context.mallowColors.error,
              ),
              const SizedBox(height: MallowTheme.spacingMd),
              Text('Something went wrong', style: MallowTheme.editorialSubhead),
              const SizedBox(height: MallowTheme.spacingSm),
              Text(
                error,
                style: MallowTheme.uiMeta.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
