import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../core/models/account.dart';
import '../../../shared/utils/chain.dart' show Chain, apiOwnerAddress;

/// Id prefix of the synthetic wallets [ProfileLookupService.buildProfileGroups]
/// mints for profile-linked addresses the user never imported. See
/// [isViewOnlyPlaceholder].
const _placeholderIdPrefix = 'view-only:';

/// True when [wallet] is a synthetic placeholder rather than a wallet the user
/// holds — i.e. it has **no row in the wallets table**.
///
/// 🛑 The test that matters before handing a wallet to
/// `WalletManager.switchWalletById` or any other id-keyed DB lookup, which
/// throws on a placeholder. `accountId == null` is NOT a substitute: the column
/// is nullable and a legacy Keychain graph can restore a real row with no
/// account (see `WalletRepository.restoreFromGraph`, and the orphan branch in
/// `SessionManager.switchToWallet`), so testing on it would skip a wallet that
/// is perfectly activatable.
bool isViewOnlyPlaceholder(WalletInfo wallet) =>
    wallet.id.startsWith(_placeholderIdPrefix);

/// Resolves wallet addresses to mallow user profiles via POST /v1/user/bulk.
///
/// - Results are cached in memory — re-run on wallet import/delete or
///   explicit pull-to-refresh.
/// - Profile groupings are ephemeral (not persisted to DB); rebuild from
///   backend on every session.
@lazySingleton
class ProfileLookupService {
  ProfileLookupService(this._api);

  final MallowApiClient _api;

  /// In-memory cache of the last successful bulk lookup response.
  BulkUserLookupResponse? _lastResponse;

  /// Perform a bulk lookup for [addresses] against the backend.
  ///
  /// Returns the full [BulkLookupResult] with matched users and unlinked
  /// addresses. Caches the response for [buildProfileGroups].
  Future<BulkLookupResult> bulkLookup(List<String> addresses) async {
    if (addresses.isEmpty) {
      return const BulkLookupResult();
    }

    debugPrint(
      '[ProfileLookupService] bulkLookup for ${addresses.length} addresses',
    );

    final response = await _api.bulkLookupUsers(
      BulkUserLookupRequest(addresses: addresses),
    );

    _lastResponse = response;
    return response.result;
  }

  /// Build [ProfileGroup] and anon-group lists from [wallets] and a
  /// [BulkUserLookupResponse].
  ///
  /// - Each user in the response becomes a [ProfileGroup] with their linked
  ///   wallets populated from [wallets].
  /// - Wallets in [response.result.unlinkedAddresses] (or not found at all)
  ///   go into the anon group.
  ///
  /// Returns `(profileGroups, anonGroup)`.
  (List<ProfileGroup>, ProfileGroup) buildProfileGroups(
    List<WalletInfo> wallets,
    BulkUserLookupResponse response,
  ) {
    // Match backend addresses to local wallets on the normalized form: EVM
    // addresses come back lowercase from the API but are stored EIP-55
    // checksummed locally, so raw-string matching would treat a held (imported)
    // Ethereum wallet as un-held and render it as a view-only placeholder.
    final walletByAddress = {
      for (final w in wallets) apiOwnerAddress(w.address): w,
    };
    final assignedAddresses = <String>{};

    final profileGroups = <ProfileGroup>[];

    final anonFromProfiles = <WalletInfo>[];

    for (final entry in response.result.users) {
      final user = entry.user;

      // Normalize the entry's linked set once — every match below keys on this
      // form, so there is a single place the normalization can be forgotten.
      final linkedKeys = entry.linkedAddresses.map(apiOwnerAddress).toList();

      // The linked wallets the user actually holds locally, in display order.
      final heldWallets =
          linkedKeys
              .map((key) => walletByAddress[key])
              .whereType<WalletInfo>()
              .toList()
            ..sort((a, b) => (a.sortIndex ?? 0).compareTo(b.sortIndex ?? 0));

      // The lookup is seeded with local addresses, so a returned profile
      // normally holds at least one. Skip the defensive empty case.
      if (heldWallets.isEmpty) continue;

      assignedAddresses.addAll(linkedKeys);

      // Users with no username/displayName are anonymous — merge into anon
      // group. Only their held wallets go there; we never materialize
      // placeholders into anon (the anon group feeds the accounts list).
      if (user.username == null && user.displayName == null) {
        anonFromProfiles.addAll(heldWallets);
        continue;
      }

      // A profile always shows its full linked set. The profile's complete
      // wallet list is `user.addresses` (the lookup's `linkedAddresses` only
      // echoes the *submitted* addresses that matched, so it can't be used
      // here — with one wallet imported it would contain just that one). Any
      // linked address the user hasn't imported becomes a synthetic view-only
      // placeholder. These are never persisted — they live only inside this
      // ProfileGroup, so they stay out of the accounts list. Once the address
      // is imported for real the next lookup finds a held wallet and the
      // placeholder disappears (the "upgrade to the imported type" is
      // automatic, not a migration).
      final heldAddresses = {
        for (final w in heldWallets) apiOwnerAddress(w.address),
      };
      final seen = <String>{};
      final placeholders = <WalletInfo>[];
      for (final addr in user.addresses) {
        final key = apiOwnerAddress(addr);
        if (heldAddresses.contains(key) || !seen.add(key)) continue;
        placeholders.add(_viewOnlyPlaceholder(addr));
      }

      profileGroups.add(
        ProfileGroup(
          userId: _profileIdFor(user),
          username: user.username,
          displayName: user.displayName,
          imageUrl: user.imageUrl,
          wallets: [...heldWallets, ...placeholders],
          isAnon: false,
        ),
      );
    }

    // Wallets not matched to any profile go into the anon group
    final anonWallets = [
      ...anonFromProfiles,
      ...wallets.where(
        (w) => !assignedAddresses.contains(apiOwnerAddress(w.address)),
      ),
    ]..sort((a, b) => (a.sortIndex ?? 0).compareTo(b.sortIndex ?? 0));

    final anonGroup = ProfileGroup(wallets: anonWallets, isAnon: true);

    return (profileGroups, anonGroup);
  }

  /// A synthetic, **non-persisted** view-only wallet for a profile-linked
  /// address the user hasn't imported. Exists only inside a [ProfileGroup].
  WalletInfo _viewOnlyPlaceholder(String address) => WalletInfo(
    id: '$_placeholderIdPrefix$address',
    address: address,
    name: 'View-only',
    walletType: WalletType.viewOnly,
    chain: Chain.fromAddress(address).toDbString(),
  );

  /// Resolves [addresses] to mallow user profiles, keyed by linked address.
  ///
  /// Unlike [bulkLookup] this never touches the wallet-drawer cache — use it
  /// for lookups of arbitrary addresses (e.g. recent send recipients) so the
  /// drawer's profile groupings can't be corrupted. Addresses without a
  /// mallow profile are simply absent from the result.
  ///
  /// Keys are normalized with [apiOwnerAddress], like every other join in this
  /// class: the backend echoes EVM addresses lowercase, while the caller looks
  /// the result up by the form it holds — EIP-55 checksummed for a local wallet
  /// or an address pasted out of the account list. Keying on the raw response
  /// missed every Ethereum recipient, so the send confirm step fell back to the
  /// truncated address and a seeded avatar instead of the profile.
  Future<Map<String, UserPreview>> profilesForAddresses(
    List<String> addresses,
  ) async {
    if (addresses.isEmpty) return const {};
    final response = await _api.bulkLookupUsers(
      BulkUserLookupRequest(addresses: addresses),
    );
    return {
      for (final entry in response.result.users)
        for (final address in entry.linkedAddresses)
          apiOwnerAddress(address): entry.user,
    };
  }

  /// The id a looked-up user is known by: `username ?? addresses.first`. Single
  /// source for [ProfileGroup.userId] so every derivation stays in lockstep.
  static String? _profileIdFor(UserPreview user) =>
      user.username ??
      (user.addresses.isNotEmpty ? user.addresses.first : null);

  /// [addresses] mapped to the id of the **named** profile they belong to.
  ///
  /// The id is what [buildProfileGroups] assigns to [ProfileGroup.userId], so
  /// callers can compare against `SessionManager.activeProfile.userId` to tell
  /// "linked to *this* profile" from "linked to *someone else's*".
  ///
  /// A named profile is a looked-up user with a username or display name — the
  /// same definition [buildProfileGroups] uses to separate profiles from the
  /// anon group. Anonymous users (a wallet that has logged in but never claimed
  /// a profile) are excluded, so such wallets stay eligible to back a new
  /// profile. Addresses with no named profile are absent. Like
  /// [profilesForAddresses] this runs a fresh lookup that never touches the
  /// drawer cache.
  Future<Map<String, String>> namedProfileIdForAddresses(
    List<String> addresses,
  ) async {
    final profiles = await profilesForAddresses(addresses);
    final owners = <String, String>{};
    profiles.forEach((address, user) {
      if (user.username == null && user.displayName == null) return;
      final id = _profileIdFor(user);
      // Key on the normalized form so callers matching a local wallet's
      // (EVM-checksummed) address against this map still resolve their profile.
      if (id != null) owners[apiOwnerAddress(address)] = id;
    });
    return owners;
  }

  /// Username linked to [address] — answered from the cached bulk lookup
  /// when present (the wallet drawer populates it with every wallet),
  /// otherwise via a one-off lookup that leaves the cache untouched.
  /// Null when the address has no mallow profile.
  Future<String?> usernameForAddress(String address) async {
    final response =
        _lastResponse ??
        await _api.bulkLookupUsers(BulkUserLookupRequest(addresses: [address]));
    final key = apiOwnerAddress(address);
    for (final entry in response.result.users) {
      if (entry.linkedAddresses.map(apiOwnerAddress).contains(key)) {
        return entry.user.username;
      }
    }
    return null;
  }

  /// Cached response from the last [bulkLookup] call.
  BulkUserLookupResponse? get lastResponse => _lastResponse;

  /// Clear in-memory cache.
  void clearCache() => _lastResponse = null;
}
