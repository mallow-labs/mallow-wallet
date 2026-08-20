import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/cast/models/cast_display_type.dart';
import '../../features/cast/models/cast_queue.dart';
import '../../features/search/models/recently_viewed_item.dart';

/// Persists user preferences to shared storage.
///
/// Registered as an async `@preResolve` singleton in [di_module.dart];
/// created via [PreferencesService.create] during `configureDependencies()`.
class PreferencesService {
  PreferencesService._(this._prefs)
    : themeNotifier = ValueNotifier<ThemeMode>(_loadThemeMode(_prefs)),
      showNsfwNotifier = ValueNotifier<bool>(
        _prefs.getBool(_kShowNsfw) ?? false,
      );

  final SharedPreferences _prefs;

  // Live notifier so MaterialApp reacts immediately to theme changes.
  final ValueNotifier<ThemeMode> themeNotifier;

  // Live notifier so on-screen NSFW blur overlays react immediately when the
  // setting flips (settings toggle or the first-reveal warning sheet).
  final ValueNotifier<bool> showNsfwNotifier;

  /// Bumped by [clearAll]. The two notifiers above are re-seeded inline, but
  /// services that cached a preference into their own state at construction
  /// (`PriorityFeeService`) have no other way to learn the value under them was
  /// wiped, and would keep applying — and re-persisting — the old one.
  final ValueNotifier<int> clearGeneration = ValueNotifier<int>(0);

  // ── Keys ──────────────────────────────────────────────────────────────────

  static const _kLanguage = 'pref_language';
  static const _kExplorer = 'pref_explorer';
  static const _kEthExplorer = 'pref_eth_explorer';
  static const _kCurrency = 'pref_currency';
  static const _kTheme = 'pref_theme';
  static const _kPushNotifications = 'pref_push_notifications';
  // Device-scoped: tracks whether we've triggered the OS push-permission
  // dialog. Not cleared on logout — OS permission state is also device-scoped.
  static const _kHasPromptedForPushPermission =
      'pref_has_prompted_for_push_permission';
  static const _kProfileGroupOrder = 'pref_profile_group_order';
  static const _kLikedCurations = 'pref_liked_curations';
  // Device-scoped: JSON-encoded `{mint: {slug, at}}` map recording which
  // curation surfaced each artwork, read at buy time for referral attribution
  // (managed by `CurationAttributionStore`). One key, not one per mint, so the
  // whole map prunes atomically.
  static const _kCurationAttributions = 'pref_curation_attributions';
  static const _kRecentSearches = 'pref_recent_searches';
  static const _maxRecentSearches = 5;
  static const _kRecentlyViewed = 'pref_recently_viewed';
  static const _maxRecentlyViewed = 5;
  static const _kCastIntervalSeconds = 'pref_cast_interval_seconds';
  static const _kCastShowCaption = 'pref_cast_show_caption';
  static const _kCastShowQr = 'pref_cast_show_qr';
  static const _kCastShuffle = 'pref_cast_shuffle';
  static const _kCastRepeatMode = 'pref_cast_repeat_mode';
  static const _kCastLastDeviceId = 'pref_cast_last_device_id';
  static const _kCastDisplayType = 'pref_cast_display_type';
  // Device-scoped: once the user has acknowledged the
  // "device appears rooted/jailbroken" warning, we don't show the blocking
  // ack screen again for any wallet-creation/import attempt on this install.
  // Survives logout because the device's compromise status doesn't change
  // when the user signs out.
  static const _kCompromisedDeviceAck = 'pref_compromised_device_ack';
  // Mirrors the profile's showNsfw flag in signed-login sessions (server wins
  // on login); purely device-local otherwise. OFF = NSFW artwork stays
  // blurred.
  static const _kShowNsfw = 'pref_show_nsfw';
  // Device-scoped one-time acknowledgement: set once the first per-artwork
  // "Reveal artwork" tap has shown the NSFW warning sheet.
  static const _kNsfwWarningShown = 'pref_nsfw_warning_shown';
  // Device-scoped: analytics opt-out (OFF = analytics enabled). On-by-default
  // per the taxonomy spec; the Settings toggle flips this.
  static const _kAnalyticsOptOut = 'pref_analytics_opt_out';
  // Device-scoped: JSON-encoded offline analytics event queue.
  static const _kAnalyticsQueue = 'pref_analytics_queue';
  // Device-scoped: epoch ms of the last `Logged In` event, for its throttle.
  static const _kLoggedInTrackedAt = 'pref_analytics_logged_in_at';
  static const _kTokenMetadataCache = 'pref_token_metadata_cache';
  static const _kSwapSlippageBps = 'pref_swap_slippage_bps';
  static const _kPriorityFeeLamports = 'pref_priority_fee_lamports';
  static const _kSwapPriorityFeeLamports = 'pref_swap_priority_fee_lamports';
  static const _kDismissedMaintenance = 'pref_dismissed_maintenance';
  static const _kDismissedNotice = 'pref_dismissed_notice';
  static const _kDismissedStakingSeason = 'pref_dismissed_staking_season';
  static const _kEthGasMode = 'pref_eth_gas_mode';
  static const _kEthGasMaxBaseFeeGwei = 'pref_eth_gas_max_base_fee_gwei';
  static const _kEthGasPriorityFeeGwei = 'pref_eth_gas_priority_fee_gwei';
  static const _kEthGasLimit = 'pref_eth_gas_limit';
  // App-scoped (not per-wallet): recent send recipients are shared between
  // all wallets on the device.
  static const _kRecentSendAddresses = 'pref_recent_send_addresses';
  static const _maxRecentSendAddresses = 10;
  // App-scoped, one key per recipient: how many times this device has sent to
  // an address. Deliberately NOT derived from [_kRecentSendAddresses] — that
  // list is capped at [_maxRecentSendAddresses] and would report the 11th-oldest
  // recipient as never-seen, which is precisely the case the confirm step's
  // "previous sends" label exists to distinguish. O(1) per lookup.
  static const _kSendCountPrefix = 'pref_send_count_';
  // Recency-ordered roster of the counter keys above, so the per-recipient keys
  // can be evicted. The ceiling is deliberately generous — SharedPreferences is
  // parsed into memory whole at startup, and forgetting a recipient downgrades
  // them to "No previous sends", so the cap is a backstop against unbounded
  // growth (airdrops, batch transfers), not a working-set limit.
  static const _kSendCountKeys = 'pref_send_count_keys';
  static const _maxSendCountKeys = 500;
  // Per-account memory of the last-used Solana signing wallet, for accounts
  // that hold more than one Solana wallet (legacy derivation paths). Keyed by
  // account id so the choice sticks per account.
  static const _kLastSolanaWalletPrefix = 'pref_last_solana_wallet_';
  // App-scoped: when ON, the import-from-phrase picker also derives and lists
  // the legacy/root Solana derivation-scheme addresses as additional selectable
  // rows. Only affects the import picker — does not retroactively change
  // already-imported accounts. Defaults OFF.
  static const _kShowLegacySolanaImport = 'pref_show_legacy_solana_import';
  // App-scoped: the next number to assign to a newly created account. A single
  // monotonic counter shared by every account kind, so accounts are named
  // `Account NN` sequentially regardless of type. Seeding (from existing names)
  // and allocation live in WalletRepository — this only stores the raw int.
  // Cleared on full wallet wipe so a fresh install/onboard restarts at 1.
  static const _kNextAccountNumber = 'pref_next_account_number';

  // ── Factory ───────────────────────────────────────────────────────────────

  static Future<PreferencesService> create() async {
    final prefs = await SharedPreferences.getInstance();
    return PreferencesService._(prefs);
  }

  // ── Language ──────────────────────────────────────────────────────────────

  String get language => _prefs.getString(_kLanguage) ?? 'en_US';

  Future<void> setLanguage(String locale) =>
      _prefs.setString(_kLanguage, locale);

  // ── Explorer ──────────────────────────────────────────────────────────────

  String get explorer => _prefs.getString(_kExplorer) ?? 'solscan';

  Future<void> setExplorer(String key) => _prefs.setString(_kExplorer, key);

  // Preferred Ethereum explorer (separate from the Solana explorer above).
  // Tezos has a single explorer (tzkt), so it needs no stored preference.
  String get ethExplorer => _prefs.getString(_kEthExplorer) ?? 'etherscan';

  Future<void> setEthExplorer(String key) =>
      _prefs.setString(_kEthExplorer, key);

  // ── Currency ──────────────────────────────────────────────────────────────

  String get currency => _prefs.getString(_kCurrency) ?? 'USD';

  Future<void> setCurrency(String code) => _prefs.setString(_kCurrency, code);

  // ── Analytics ───────────────────────────────────────────────────────────────

  /// OFF = analytics enabled (on-by-default). The Settings toggle flips this.
  bool get analyticsOptOut => _prefs.getBool(_kAnalyticsOptOut) ?? false;

  Future<void> setAnalyticsOptOut(bool value) =>
      _prefs.setBool(_kAnalyticsOptOut, value);

  /// JSON-encoded offline analytics event queue (managed by AnalyticsService).
  String? get analyticsQueue => _prefs.getString(_kAnalyticsQueue);

  Future<void> setAnalyticsQueue(String json) =>
      _prefs.setString(_kAnalyticsQueue, json);

  /// When `Logged In` was last emitted. Persisted rather than held in memory so
  /// the throttle survives a restart — login runs on every cold start, and an
  /// in-memory stamp would let a force-quit loop re-emit it every launch.
  DateTime? get lastLoggedInTrackedAt {
    final ms = _prefs.getInt(_kLoggedInTrackedAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setLastLoggedInTrackedAt(DateTime at) =>
      _prefs.setInt(_kLoggedInTrackedAt, at.millisecondsSinceEpoch);

  /// JSON-encoded `{mint: {symbol, decimals, imageUrl, fetchedAt}}` map of
  /// token metadata resolved from DAS for mints the static registry doesn't
  /// key (managed by `TokenMetadataService`). One key, not one per mint, so
  /// the whole cache prunes and migrates atomically.
  String? get tokenMetadataCache => _prefs.getString(_kTokenMetadataCache);

  Future<void> setTokenMetadataCache(String json) =>
      _prefs.setString(_kTokenMetadataCache, json);

  // ── Theme ─────────────────────────────────────────────────────────────────

  ThemeMode get themeMode => themeNotifier.value;

  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs.setString(_kTheme, mode.name);
    themeNotifier.value = mode;
  }

  // ── Push Notifications ───────────────────────────────────────────────────

  bool get pushNotificationsEnabled =>
      _prefs.getBool(_kPushNotifications) ?? true;

  Future<void> setPushNotificationsEnabled(bool enabled) =>
      _prefs.setBool(_kPushNotifications, enabled);

  bool get hasPromptedForPushPermission =>
      _prefs.getBool(_kHasPromptedForPushPermission) ?? false;

  Future<void> setHasPromptedForPushPermission(bool value) =>
      _prefs.setBool(_kHasPromptedForPushPermission, value);

  // ── Profile Group Order ─────────────────────────────────────────────────

  List<String>? get profileGroupOrder =>
      _prefs.getStringList(_kProfileGroupOrder);

  Future<void> setProfileGroupOrder(List<String> order) =>
      _prefs.setStringList(_kProfileGroupOrder, order);

  // ── Curation View ───────────────────────────────────────────────────────

  /// Whether [curationId] is in the device-local liked set. Stand-in until
  /// mallow_api exposes a curation-like endpoint: not synced to the server
  /// and not scoped per profile, so it only reflects likes made on this
  /// device (see CurationScreen._toggleCurationLike).
  bool isCurationLiked(String curationId) =>
      (_prefs.getStringList(_kLikedCurations) ?? []).contains(curationId);

  Future<void> setCurationLiked(String curationId, bool liked) async {
    final current = (_prefs.getStringList(_kLikedCurations) ?? [])
      ..remove(curationId);
    if (liked) current.add(curationId);
    await _prefs.setStringList(_kLikedCurations, current);
  }

  /// JSON-encoded `{mint: {slug, at}}` map of which curation the user opened
  /// each artwork from (managed by `CurationAttributionStore`).
  String? get curationAttributions => _prefs.getString(_kCurationAttributions);

  Future<void> setCurationAttributions(String json) =>
      _prefs.setString(_kCurationAttributions, json);

  // ── Recent Searches ──────────────────────────────────────────────────────

  List<String> get recentSearches =>
      _prefs.getStringList(_kRecentSearches) ?? [];

  /// Saves a search term, keeping the list unique and most-recent-first.
  ///
  /// Matching is case-insensitive: re-searching an existing term moves it to
  /// the front rather than adding a duplicate. Max [_maxRecentSearches] kept.
  Future<void> saveRecentSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final lower = trimmed.toLowerCase();

    final current = recentSearches
      ..removeWhere((existing) => existing.toLowerCase() == lower);

    // Insert at front
    current.insert(0, trimmed);

    // Cap at max
    if (current.length > _maxRecentSearches) {
      current.removeRange(_maxRecentSearches, current.length);
    }

    await _prefs.setStringList(_kRecentSearches, current);
  }

  Future<void> clearRecentSearches() => _prefs.remove(_kRecentSearches);

  // ── Recently Viewed ──────────────────────────────────────────────────────

  /// Content the user has recently opened (artwork / profile / collection /
  /// curation / token), most-recent-first. Malformed or unknown-type entries
  /// are skipped rather than crashing the list.
  List<RecentlyViewedItem> get recentlyViewed =>
      (_prefs.getStringList(_kRecentlyViewed) ?? [])
          .map((raw) {
            try {
              return RecentlyViewedItem.fromJson(
                jsonDecode(raw) as Map<String, dynamic>,
              );
            } catch (_) {
              return null;
            }
          })
          .whereType<RecentlyViewedItem>()
          .toList();

  /// Records [item] as the most recently viewed content, deduplicating by
  /// [RecentlyViewedItem.dedupeKey] (re-viewing moves it to the front) and
  /// capping the list at [_maxRecentlyViewed].
  Future<void> saveRecentlyViewed(RecentlyViewedItem item) async {
    final key = item.dedupeKey;
    final current = recentlyViewed
      ..removeWhere((existing) => existing.dedupeKey == key);

    current.insert(0, item);

    if (current.length > _maxRecentlyViewed) {
      current.removeRange(_maxRecentlyViewed, current.length);
    }

    await _prefs.setStringList(
      _kRecentlyViewed,
      current.map((e) => e.encoded).toList(),
    );
  }

  Future<void> clearRecentlyViewed() => _prefs.remove(_kRecentlyViewed);

  // ── Cast ─────────────────────────────────────────────────────────────────

  int get castIntervalSeconds => _prefs.getInt(_kCastIntervalSeconds) ?? 30;

  Future<void> setCastIntervalSeconds(int seconds) =>
      _prefs.setInt(_kCastIntervalSeconds, seconds);

  bool get castShowCaption => _prefs.getBool(_kCastShowCaption) ?? true;

  Future<void> setCastShowCaption(bool show) =>
      _prefs.setBool(_kCastShowCaption, show);

  bool get castShowQr => _prefs.getBool(_kCastShowQr) ?? true;

  Future<void> setCastShowQr(bool show) => _prefs.setBool(_kCastShowQr, show);

  bool get castShuffle => _prefs.getBool(_kCastShuffle) ?? false;

  Future<void> setCastShuffle(bool shuffle) =>
      _prefs.setBool(_kCastShuffle, shuffle);

  CastRepeatMode get castRepeatMode {
    final raw = _prefs.getString(_kCastRepeatMode);
    return CastRepeatMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => CastRepeatMode.all,
    );
  }

  Future<void> setCastRepeatMode(CastRepeatMode mode) =>
      _prefs.setString(_kCastRepeatMode, mode.name);

  /// Stable device id (Cast SDK uuid for Chromecasts, `airplay` for AirPlay,
  /// etc.) of the most recently connected device. Used to auto-select on the
  /// next cast when the same device is rediscovered.
  String? get castLastDeviceId => _prefs.getString(_kCastLastDeviceId);

  Future<void> setCastLastDeviceId(String id) =>
      _prefs.setString(_kCastLastDeviceId, id);

  CastDisplayType get castDisplayType {
    final raw = _prefs.getString(_kCastDisplayType);
    return CastDisplayType.values.firstWhere(
      (t) => t.name == raw,
      orElse: () => CastDisplayType.fillScreen,
    );
  }

  Future<void> setCastDisplayType(CastDisplayType type) =>
      _prefs.setString(_kCastDisplayType, type.name);

  // ── Swap ─────────────────────────────────────────────────────────────────

  /// Slippage tolerance for swaps in basis points; `null` = Auto (Jupiter
  /// picks via real-time slippage estimation).
  int? get swapSlippageBps => _prefs.getInt(_kSwapSlippageBps);

  Future<void> setSwapSlippageBps(int? bps) => bps == null
      ? _prefs.remove(_kSwapSlippageBps)
      : _prefs.setInt(_kSwapSlippageBps, bps);

  // ── Solana priority fee ──────────────────────────────────────────────────

  /// The user's general Solana priority-fee ceiling (Settings → Priority Fee),
  /// in **lamports of priority fee for the whole transaction**; `null` = Auto.
  ///
  /// Applies to every Solana transaction this app builds
  /// (`SolanaRpcService.buildComputeBudgetPrefix`) *except* where the
  /// swap-specific override below takes over. Read both through
  /// `PriorityFeeService`, which owns the Auto default, the 15 000-lamport
  /// floor and the live notifiers — this pair is the storage, not the API.
  int? get priorityFeeLamports => _prefs.getInt(_kPriorityFeeLamports);

  Future<void> setPriorityFeeLamports(int? lamports) => lamports == null
      ? _prefs.remove(_kPriorityFeeLamports)
      : _prefs.setInt(_kPriorityFeeLamports, lamports);

  /// The swap-specific override, written only by the swap settings sheet;
  /// `null` = no override, which falls back to [priorityFeeLamports] (**not**
  /// to Auto).
  ///
  /// This key predates the general one. It stays live and un-migrated so a
  /// user who had set a custom swap fee keeps it: renaming the key would have
  /// silently reset them to Auto.
  int? get swapPriorityFeeLamports => _prefs.getInt(_kSwapPriorityFeeLamports);

  Future<void> setSwapPriorityFeeLamports(int? lamports) => lamports == null
      ? _prefs.remove(_kSwapPriorityFeeLamports)
      : _prefs.setInt(_kSwapPriorityFeeLamports, lamports);

  // ── Status banners ───────────────────────────────────────────────────────

  /// `startsAt` of the maintenance window the user dismissed the banner for.
  /// Value-scoped rather than a boolean so dismissing one announcement can
  /// never suppress the next one.
  String? get dismissedMaintenance => _prefs.getString(_kDismissedMaintenance);

  Future<void> setDismissedMaintenance(String key) =>
      _prefs.setString(_kDismissedMaintenance, key);

  /// `id` of the operator notice the user dismissed. Bumping the id in the
  /// feed re-shows the banner.
  String? get dismissedNotice => _prefs.getString(_kDismissedNotice);

  Future<void> setDismissedNotice(String key) =>
      _prefs.setString(_kDismissedNotice, key);

  /// `season` number whose stake-sheet season banner the user dismissed.
  /// Value-scoped like the two above, so dismissing one season's banner can
  /// never suppress the next season's.
  int? get dismissedStakingSeason => _prefs.getInt(_kDismissedStakingSeason);

  Future<void> setDismissedStakingSeason(int season) =>
      _prefs.setInt(_kDismissedStakingSeason, season);

  // ── Ethereum send gas ────────────────────────────────────────────────────

  /// The user's persisted Ethereum-send fee tier: `'low'`, `'market'`, or
  /// `'custom'`. `null` = never chosen (the confirm step defaults to Market).
  /// The custom knobs below are only meaningful when this is `'custom'`.
  String? get ethGasMode => _prefs.getString(_kEthGasMode);

  Future<void> setEthGasMode(String? mode) => mode == null
      ? _prefs.remove(_kEthGasMode)
      : _prefs.setString(_kEthGasMode, mode);

  /// Custom Advanced-sheet max base fee, in gwei; `null` = unset.
  double? get ethGasMaxBaseFeeGwei => _prefs.getDouble(_kEthGasMaxBaseFeeGwei);

  Future<void> setEthGasMaxBaseFeeGwei(double? gwei) => gwei == null
      ? _prefs.remove(_kEthGasMaxBaseFeeGwei)
      : _prefs.setDouble(_kEthGasMaxBaseFeeGwei, gwei);

  /// Custom Advanced-sheet priority fee, in gwei; `null` = unset.
  double? get ethGasPriorityFeeGwei =>
      _prefs.getDouble(_kEthGasPriorityFeeGwei);

  Future<void> setEthGasPriorityFeeGwei(double? gwei) => gwei == null
      ? _prefs.remove(_kEthGasPriorityFeeGwei)
      : _prefs.setDouble(_kEthGasPriorityFeeGwei, gwei);

  /// Custom Advanced-sheet gas limit. Retained for storage compatibility but no
  /// longer applied: a gas limit is per-transaction (each transfer has its own
  /// padded estimate), so it is never persisted or replayed across transactions
  /// — the confirm step always resolves the gas limit from the current transfer's
  /// fresh estimate. See `EthGasSelection.resolveFromPrefs`.
  int? get ethGasLimit => _prefs.getInt(_kEthGasLimit);

  Future<void> setEthGasLimit(int? limit) => limit == null
      ? _prefs.remove(_kEthGasLimit)
      : _prefs.setInt(_kEthGasLimit, limit);

  // ── Recent Send Recipients ───────────────────────────────────────────────

  /// Addresses the user has successfully sent tokens to, most recent first.
  List<String> get recentSendAddresses =>
      _prefs.getStringList(_kRecentSendAddresses) ?? [];

  /// Records [address] as the most recent send recipient, deduplicating and
  /// capping the list at [_maxRecentSendAddresses].
  Future<void> saveRecentSendAddress(String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return;
    final current = recentSendAddresses
      ..remove(trimmed)
      ..insert(0, trimmed);
    if (current.length > _maxRecentSendAddresses) {
      current.removeRange(_maxRecentSendAddresses, current.length);
    }
    await _prefs.setStringList(_kRecentSendAddresses, current);
  }

  /// How many transfers this device has completed to [address] — 0 for a
  /// recipient never sent to. Shown on the send confirm step so a first-time
  /// recipient reads differently from a familiar one.
  int sendCountFor(String address) {
    final key = _sendCountKey(address);
    if (key == null) return 0;
    return _prefs.getInt(key) ?? 0;
  }

  /// Records one completed transfer to [address]. Called from every send
  /// surface that transfers value (tokens and NFTs alike) — a previous NFT
  /// transfer is still a previous send to that address.
  Future<void> incrementSendCount(String address) async {
    final key = _sendCountKey(address);
    if (key == null) return;
    await _prefs.setInt(key, (_prefs.getInt(key) ?? 0) + 1);
    await _trackSendCountKey(key);
  }

  /// Moves [key] to the front of the recency roster and drops the counters that
  /// fall past [_maxSendCountKeys]. Eviction is by least-recently-sent-to, so
  /// what is forgotten is always the recipient the label matters least for.
  Future<void> _trackSendCountKey(String key) async {
    final tracked = _prefs.getStringList(_kSendCountKeys) ?? <String>[]
      ..remove(key)
      ..insert(0, key);
    if (tracked.length > _maxSendCountKeys) {
      for (final stale in tracked.sublist(_maxSendCountKeys)) {
        await _prefs.remove(stale);
      }
      tracked.removeRange(_maxSendCountKeys, tracked.length);
    }
    await _prefs.setStringList(_kSendCountKeys, tracked);
  }

  /// Null for an empty address (nothing to count). EVM addresses are
  /// case-folded so a checksummed recipient and the same address in lowercase
  /// share one counter — they are the same account.
  static String? _sendCountKey(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return null;
    final normalized = trimmed.startsWith('0x') || trimmed.startsWith('0X')
        ? trimmed.toLowerCase()
        : trimmed;
    return '$_kSendCountPrefix$normalized';
  }

  // ── Last-used Solana wallet (per account) ────────────────────────────────

  /// The wallet id last used to sign a Solana action under [accountId], or
  /// null if the user has never disambiguated (or the account holds a single
  /// Solana wallet). Drives the default selection in the Solana signing picker.
  String? lastSolanaWalletId(String accountId) =>
      _prefs.getString('$_kLastSolanaWalletPrefix$accountId');

  /// Remember [walletId] as the Solana signing wallet for [accountId].
  Future<void> setLastSolanaWalletId(String accountId, String walletId) =>
      _prefs.setString('$_kLastSolanaWalletPrefix$accountId', walletId);

  // ── Legacy Solana derivation in import picker ────────────────────────────

  /// Whether the import-from-phrase picker should also show legacy/root
  /// Solana derivation-scheme addresses as selectable rows. Defaults OFF.
  bool get showLegacySolanaImport =>
      _prefs.getBool(_kShowLegacySolanaImport) ?? false;

  Future<void> setShowLegacySolanaImport(bool value) =>
      _prefs.setBool(_kShowLegacySolanaImport, value);

  // ── Global account counter ───────────────────────────────────────────────

  /// The persisted next-account number, or null if never seeded. Seeding and
  /// allocation are owned by WalletRepository (it needs DB access to seed from
  /// existing account names); this is the raw store.
  int? get rawNextAccountNumber => _prefs.getInt(_kNextAccountNumber);

  Future<void> setNextAccountNumber(int value) =>
      _prefs.setInt(_kNextAccountNumber, value);

  /// Clear the counter so the next seed recomputes from scratch (re-onboarding
  /// after a full wallet wipe restarts numbering at 1).
  Future<void> clearNextAccountNumber() => _prefs.remove(_kNextAccountNumber);

  // ── NSFW ─────────────────────────────────────────────────────────────────

  /// Whether NSFW-flagged artwork renders unblurred. Defaults OFF (blurred).
  bool get showNsfw => showNsfwNotifier.value;

  Future<void> setShowNsfw(bool value) async {
    await _prefs.setBool(_kShowNsfw, value);
    showNsfwNotifier.value = value;
  }

  /// Whether the one-time NSFW warning sheet has already been shown.
  bool get nsfwWarningShown => _prefs.getBool(_kNsfwWarningShown) ?? false;

  Future<void> setNsfwWarningShown(bool value) =>
      _prefs.setBool(_kNsfwWarningShown, value);

  // ── Compromised Device Acknowledgement ───────────────────────────────────

  bool get compromisedDeviceAcknowledged =>
      _prefs.getBool(_kCompromisedDeviceAck) ?? false;

  Future<void> setCompromisedDeviceAcknowledged(bool value) =>
      _prefs.setBool(_kCompromisedDeviceAck, value);

  // ── Full wipe ─────────────────────────────────────────────────────────────

  /// Erase every stored preference (Settings → Reset app).
  ///
  /// "Reset app" is presented as a factory reset, so nothing device-local may
  /// survive it. The privacy-bearing keys are the reason this exists —
  /// [recentSendAddresses], the per-recipient [sendCountFor] counters,
  /// [recentSearches], [recentlyViewed] and the buy history all describe the
  /// *previous* identity, and would otherwise be surfaced to whoever
  /// re-onboards next with a different seed phrase.
  /// Cosmetic keys (theme, explorer, NSFW) go with them rather than leave the
  /// "Reset app" label lying about what it clears.
  ///
  /// The notifiers are re-seeded from the (now empty) store using the same
  /// expressions as the constructor, so listening widgets fall back to
  /// defaults immediately instead of showing the wiped values until restart.
  /// [clearGeneration] carries the same signal to services that hold their own
  /// cached copy of a preference.
  Future<void> clearAll() async {
    await _prefs.clear();
    themeNotifier.value = _loadThemeMode(_prefs);
    showNsfwNotifier.value = _prefs.getBool(_kShowNsfw) ?? false;
    clearGeneration.value++;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static ThemeMode _loadThemeMode(SharedPreferences prefs) {
    final raw = prefs.getString(_kTheme);
    // Default to dark mode until the user explicitly picks a theme.
    return ThemeMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => ThemeMode.dark,
    );
  }
}
