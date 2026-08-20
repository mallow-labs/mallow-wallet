import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/network/ethereum_rpc_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_permission_service.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'artwork_permission_service_test.mocks.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';
// Permission logic that mirrors the webapp's `useCanBurn` /
// `useCanTransfer` rules. Worth its own test file because each token
// standard has a different gate, and getting any of them wrong either
// (a) shows a destructive menu item that fails on-chain, or (b) hides
// it from users who *are* allowed to burn. Both are user-visible bugs.

/// Hand-written (not generated): the only members exercised here return
/// nullable types, so an unstubbed call yields null rather than throwing.
class _MockSessionManager extends Mock implements SessionManager {}

@GenerateMocks([
  DasApiService,
  WalletManager,
  WalletRepository,
  ProfileLookupService,
  EthereumRpcService,
])
void main() {
  late MockDasApiService mockDas;
  late MockWalletManager mockWallet;
  late MockWalletRepository mockWalletRepo;
  late MockProfileLookupService mockProfileLookup;
  late MockEthereumRpcService mockEthRpc;
  late _MockSessionManager mockSession;
  late ArtworkPermissionService service;

  const me = 'OwnerWalletAddress11111111111111111111111111';
  const other = 'OtherWalletAddress11111111111111111111111111';
  const mint = 'AssetMint1111111111111111111111111111111111';
  const collectionMint = 'CollectionMint11111111111111111111111111111';

  setUpAll(() {
    // `erc1155BalanceOf` returns a non-nullable BigInt — mockito needs a dummy.
    provideDummy<BigInt>(BigInt.zero);
  });

  WalletInfo wallet(String address, {WalletType type = WalletType.hd}) =>
      WalletInfo(
        id: 'id-$address',
        address: address,
        name: 'wallet',
        walletType: type,
        chain: 'solana',
      );

  Account account(List<WalletInfo> wallets) =>
      Account(id: 'acct', name: 'Account', wallets: wallets);

  // A cached bulk-lookup response describing one profile whose full linked set
  // is [addresses] (as `user.addresses`, the drawer's source of truth).
  BulkUserLookupResponse profileLookup(List<String> addresses) =>
      BulkUserLookupResponse(
        result: BulkLookupResult(
          users: [BulkUserEntry(user: UserPreview(addresses: addresses))],
        ),
      );

  setUp(() {
    mockDas = MockDasApiService();
    mockWallet = MockWalletManager();
    mockWalletRepo = MockWalletRepository();
    mockProfileLookup = MockProfileLookupService();
    mockEthRpc = MockEthereumRpcService();
    service = ArtworkPermissionService(
      mockDas,
      mockWallet,
      mockWalletRepo,
      mockProfileLookup,
      mockEthRpc,
    );
    // The signing gates narrow the active wallet to the session before using
    // it (a Profile must not offer owner actions via a wallet it doesn't
    // link), and the EVM arm resolves its wallet from the session too.
    mockSession = _MockSessionManager();
    if (GetIt.instance.isRegistered<SessionManager>()) {
      GetIt.instance.unregister<SessionManager>();
    }
    GetIt.instance.registerSingleton<SessionManager>(mockSession);
    // Default: an Account session, where the active address is in scope.
    when(mockSession.scopedToSession(me)).thenReturn(me);

    when(mockWallet.getAddress()).thenAnswer((_) async => me);
    // Default: the user controls no wallets, so the download gate is off and
    // the permission tests below exercise only the active-wallet logic.
    when(mockWalletRepo.getAllWallets()).thenAnswer((_) async => []);
    when(mockWalletRepo.getAccountViews()).thenAnswer((_) async => []);
    when(mockProfileLookup.lastResponse).thenReturn(null);
  });

  DigitalAsset asset({
    TokenStandard standard = TokenStandard.nft,
    String? owner = me,
    bool frozen = false,
    bool freezeDelegateFrozen = false,
    bool permanentFreezeDelegateFrozen = false,
    int supply = 0,
    int? currentSize,
    String? updateAuthority,
    String? burnDelegateAuthority,
    String? permanentBurnDelegateAuthority,
    String? collectionKey,
  }) => DigitalAsset(
    id: mint,
    tokenStandard: standard,
    isMutable: true,
    // `frozen` on the parsed model is the OR of ownership.frozen,
    // freezeDelegate.frozen, and permanentFreezeDelegate.frozen —
    // mirror that here so tests look like real DAS state.
    frozen: frozen || freezeDelegateFrozen || permanentFreezeDelegateFrozen,
    supply: supply,
    freezeDelegateFrozen: freezeDelegateFrozen,
    permanentFreezeDelegateFrozen: permanentFreezeDelegateFrozen,
    hasMasterEditionPlugin: false,
    owner: owner,
    updateAuthority: updateAuthority,
    currentSize: currentSize,
    burnDelegateAuthority: burnDelegateAuthority,
    permanentBurnDelegateAuthority: permanentBurnDelegateAuthority,
    collectionKey: collectionKey,
  );

  Future<ArtworkPermissions> checkWith(
    DigitalAsset target, {
    DigitalAsset? collection,
    Set<String> sessionAddresses = const {},
    ListingType? listingType,
    bool inGroupedSale = false,
  }) async {
    when(mockDas.getAsset(mint)).thenAnswer((_) async => target);
    if (collection != null) {
      when(
        mockDas.getAsset(collectionMint),
      ).thenAnswer((_) async => collection);
    }
    return service.checkPermissions(
      mint,
      sessionAddresses: sessionAddresses,
      listingType: listingType,
      inGroupedSale: inGroupedSale,
    );
  }

  group('canBurn', () {
    test('NFT owner with supply==0 can burn', () async {
      final p = await checkWith(asset());
      expect(p.canBurn, isTrue);
    });

    test('NFT non-owner cannot burn', () async {
      final p = await checkWith(asset(owner: other));
      expect(p.canBurn, isFalse);
    });

    test('NFT master with prints (supply>0) cannot burn', () async {
      final p = await checkWith(asset(supply: 3));
      expect(p.canBurn, isFalse);
    });

    test('frozen NFT cannot burn', () async {
      final p = await checkWith(asset(frozen: true));
      expect(p.canBurn, isFalse);
    });

    test('pNFT owner with supply==0 can burn', () async {
      final p = await checkWith(asset(standard: TokenStandard.pnft));
      expect(p.canBurn, isTrue);
    });

    // Webapp's `burnAsset` has no cnft arm and the v2 backend
    // (`/v2/tx/assets/burn`) returns BadRequest for cnft. Hiding the
    // menu item is the only way to avoid a mid-flow failure.
    test('cNFT is never burnable, even for the owner', () async {
      final p = await checkWith(asset(standard: TokenStandard.cnft));
      expect(p.canBurn, isFalse);
    });

    test('Core owner can burn', () async {
      final p = await checkWith(asset(standard: TokenStandard.core));
      expect(p.canBurn, isTrue);
    });

    test('Core non-owner with no delegate cannot burn', () async {
      final p = await checkWith(
        asset(standard: TokenStandard.core, owner: other),
      );
      expect(p.canBurn, isFalse);
    });

    test('Core burnDelegate authority (non-owner) can burn', () async {
      final p = await checkWith(
        asset(
          standard: TokenStandard.core,
          owner: other,
          burnDelegateAuthority: me,
        ),
      );
      expect(p.canBurn, isTrue);
    });

    test(
      'Core asset-level permanentBurnDelegate does NOT unlock burn',
      () async {
        // Webapp `useCanBurn` consults only the asset's regular
        // `burnDelegate` and the parent collection's PERMANENT burn
        // delegate — an asset-level permanent variant is not an arm
        // there, so parity means hiding it here too.
        final p = await checkWith(
          asset(
            standard: TokenStandard.core,
            owner: other,
            permanentBurnDelegateAuthority: me,
          ),
        );
        expect(p.canBurn, isFalse);
      },
    );

    test(
      'Core parent collection regular burnDelegate does NOT unlock burn',
      () async {
        // Same parity rule: only the collection's permanentBurnDelegate
        // cascades burn rights to children in `useCanBurn`.
        final p = await checkWith(
          asset(
            standard: TokenStandard.core,
            owner: other,
            collectionKey: collectionMint,
          ),
          collection: asset(
            standard: TokenStandard.coreCollection,
            owner: other,
            burnDelegateAuthority: me,
          ),
        );
        expect(p.canBurn, isFalse);
      },
    );

    test(
      'Core parent collection permanentBurnDelegate authority can burn',
      () async {
        final p = await checkWith(
          asset(
            standard: TokenStandard.core,
            owner: other,
            collectionKey: collectionMint,
          ),
          collection: asset(
            standard: TokenStandard.coreCollection,
            owner: other,
            permanentBurnDelegateAuthority: me,
          ),
        );
        expect(p.canBurn, isTrue);
      },
    );

    test(
      'Core child blocked when parent collection is permanently frozen',
      () async {
        // The permanent freeze on the collection cascades to every child.
        // Mpl-core rejects burns of children of a frozen collection, so
        // we must block here to avoid a chain-rejected tx.
        final p = await checkWith(
          asset(standard: TokenStandard.core, collectionKey: collectionMint),
          collection: asset(
            standard: TokenStandard.coreCollection,
            permanentFreezeDelegateFrozen: true,
          ),
        );
        expect(p.canBurn, isFalse);
      },
    );

    test('CoreCollection updateAuthority can burn when empty', () async {
      final p = await checkWith(
        asset(
          standard: TokenStandard.coreCollection,
          owner: null,
          currentSize: 0,
          updateAuthority: me,
        ),
      );
      expect(p.canBurn, isTrue);
    });

    test('CoreCollection with currentSize>0 cannot burn', () async {
      // The single-ix burn route fails on-chain when the collection
      // still has members; webapp's BurnModal orchestrates a separate
      // multi-tx remove-then-burn flow we don't support yet.
      final p = await checkWith(
        asset(
          standard: TokenStandard.coreCollection,
          owner: null,
          currentSize: 5,
          updateAuthority: me,
        ),
      );
      expect(p.canBurn, isFalse);
    });

    test(
      'CoreCollection permanentBurnDelegate can burn even without UA',
      () async {
        final p = await checkWith(
          asset(
            standard: TokenStandard.coreCollection,
            owner: null,
            currentSize: 0,
            updateAuthority: other,
            permanentBurnDelegateAuthority: me,
          ),
        );
        expect(p.canBurn, isTrue);
      },
    );

    test('CoreCollection regular burnDelegate does NOT unlock burn', () async {
      // `useCanBurn`'s CoreCollection arm consults only the update
      // authority and the permanent burn delegate.
      final p = await checkWith(
        asset(
          standard: TokenStandard.coreCollection,
          owner: null,
          currentSize: 0,
          updateAuthority: other,
          burnDelegateAuthority: me,
        ),
      );
      expect(p.canBurn, isFalse);
    });
  });

  // A live listing must block transfer (and burn) whatever the on-chain
  // mechanic, mirroring the webapp's `useCanTransfer` refusal when the
  // listing PDA exists. This matters because the frozen bit is NOT a proxy for
  // "listed": only the escrowing/freezing paths (`listNft`, `listCoreAsset`)
  // set it. `listEditionsV2`/`listCoreEditions` install a delegate record and
  // leave the asset unfrozen in the seller's wallet, non-custodial listings
  // never escrow, and external-market listings touch the mallow programs not at
  // all — on all of those the transfer tx CONFIRMS (simulation does not catch
  // it) and orphans the listing. Each case below is one listing mechanic.
  group('listing gate — transfer refused on any live listing', () {
    test('frozen escrow listing (listNft / listCoreAsset): refused', () async {
      final p = await checkWith(
        asset(frozen: true),
        listingType: ListingType.buyNow,
      );
      expect(p.canTransfer, isFalse);
    });

    test('delegate-only editions listing (listEditionsV2) leaves the master '
        'unfrozen and owned — refused only because of listingType', () async {
      // A non-Core master edition listed with `listEditionsV2`: the market gets
      // a token-metadata `print_delegate` record, the token itself stays
      // unfrozen in the seller's ATA. This is the exact shape that used to slip
      // through — the companion expectation below proves the on-chain arms
      // alone still say "yes", so the indexer term is doing the work.
      final listedMaster = asset(supply: 3);
      final listed = await checkWith(
        listedMaster,
        listingType: ListingType.buyNow,
      );
      expect(listed.canTransfer, isFalse);

      final unlisted = await checkWith(listedMaster);
      expect(
        unlisted.canTransfer,
        isTrue,
        reason:
            'frozen bit is unset on a delegate-based listing, so only the '
            'indexed listingType can refuse the transfer',
      );
    });

    test('non-custodial Core editions listing (listCoreEditions): refused '
        'even though the update authority still holds the master', () async {
      final p = await checkWith(
        asset(
          standard: TokenStandard.coreCollection,
          owner: null,
          updateAuthority: me,
        ),
        listingType: ListingType.buyNow,
      );
      expect(p.canTransfer, isFalse);
    });

    test('external-market listing (exchange.art / objkt) sets nothing on the '
        'mallow programs: refused', () async {
      final p = await checkWith(asset(), listingType: ListingType.buyNow);
      expect(p.canTransfer, isFalse);
    });

    test('grouped sale: refused even when listingType is unlisted', () async {
      // Grouped-sale membership is carried separately from the per-artwork
      // listing type, so it needs its own term.
      final p = await checkWith(
        asset(),
        listingType: ListingType.unlisted,
        inGroupedSale: true,
      );
      expect(p.canTransfer, isFalse);
    });

    test('every non-unlisted listing type refuses transfer', () async {
      // Auction / raffle / gumball / store / airdrop / jellybean all commit the
      // asset to a sale flow; none of them may be transferred out from under.
      for (final type in ListingType.values.where(
        (t) => t != ListingType.unlisted,
      )) {
        final p = await checkWith(asset(), listingType: type);
        expect(p.canTransfer, isFalse, reason: 'listingType $type');
      }
    });

    test('burn uses the same gate — listed asset is not burnable', () async {
      final p = await checkWith(asset(), listingType: ListingType.buyNow);
      expect(p.canBurn, isFalse);
    });

    test('unlisted owned artwork is still transferable and burnable', () async {
      final p = await checkWith(asset(), listingType: ListingType.unlisted);
      expect(p.canTransfer, isTrue);
      expect(p.canBurn, isTrue);
    });

    test('a null listingType is treated as unlisted (caller has no listing '
        'info) — deliberate, documented residual gap', () async {
      // Surfaces whose wire row omits listingType must keep working; widening
      // null to "possibly listed" would hide transfer everywhere. Only the
      // on-chain arms defend that window.
      final p = await checkWith(asset());
      expect(p.canTransfer, isTrue);
    });

    test('casting stays available on a listed artwork the user owns', () async {
      // Regression guard for the context menu's cast row, which reads
      // canDownload (owned-or-created, listing-independent) precisely because
      // canTransfer now goes false while listed.
      when(
        mockWalletRepo.getAllWallets(),
      ).thenAnswer((_) async => [wallet(me)]);
      final p = await checkWith(asset(), listingType: ListingType.buyNow);
      expect(p.canTransfer, isFalse);
      expect(p.canDownload, isTrue);
    });
  });

  // Listing escrows the asset, so it needs every movement precondition that
  // transfer and burn need. `canList` used to skip the parent-collection
  // permanent-freeze term that both of those apply, which made the listing gate
  // the loosest of the three on the very same asset — the user could reach the
  // listing form (and sign) for something the chain can't move.
  group('canList', () {
    test(
      'Core child blocked when parent collection is permanently frozen',
      () async {
        final p = await checkWith(
          asset(standard: TokenStandard.core, collectionKey: collectionMint),
          collection: asset(
            standard: TokenStandard.coreCollection,
            permanentFreezeDelegateFrozen: true,
          ),
        );
        expect(p.canList, isFalse);
        // Parity with the two gates it had drifted from.
        expect(p.canTransfer, isFalse);
        expect(p.canBurn, isFalse);
      },
    );

    test('Core child in an unfrozen collection can still be listed', () async {
      final p = await checkWith(
        asset(standard: TokenStandard.core, collectionKey: collectionMint),
        collection: asset(standard: TokenStandard.coreCollection),
      );
      expect(p.canList, isTrue);
    });
  });

  // Download is offered for artworks owned or created by ANY wallet the user
  // controls — resolved from the local DB across every account, not just the
  // active one: imported signers, plus view-only wallets sharing an account
  // (portfolio) with a signer.
  group('canDownload', () {
    test('true when owner is an imported signable wallet', () async {
      when(
        mockWalletRepo.getAllWallets(),
      ).thenAnswer((_) async => [wallet(me)]);
      final p = await checkWith(asset());
      expect(p.canDownload, isTrue);
    });

    test('true when owner is a view-only wallet in an account with a '
        'signer', () async {
      // The artwork is owned by `other`, a view-only wallet grouped in an
      // account (portfolio) that also holds the signable `me`.
      when(mockWalletRepo.getAccountViews()).thenAnswer(
        (_) async => [
          account([wallet(me), wallet(other, type: WalletType.viewOnly)]),
        ],
      );
      final p = await checkWith(asset(owner: other));
      expect(p.canDownload, isTrue);
    });

    test('false when the owner account has no signer', () async {
      // `other` owns the art but its account holds only view-only wallets, so
      // nothing there can prove ownership.
      when(mockWalletRepo.getAccountViews()).thenAnswer(
        (_) async => [
          account([wallet(other, type: WalletType.viewOnly)]),
        ],
      );
      final p = await checkWith(asset(owner: other));
      expect(p.canDownload, isFalse);
    });

    test('true when owner is a profile-linked wallet not imported '
        'locally', () async {
      // `other` is linked to a profile the user holds a signer (`me`) for, but
      // was never imported — so it only exists in the cached bulk lookup.
      when(
        mockWalletRepo.getAllWallets(),
      ).thenAnswer((_) async => [wallet(me)]);
      when(
        mockProfileLookup.lastResponse,
      ).thenReturn(profileLookup([me, other]));
      final p = await checkWith(asset(owner: other));
      expect(p.canDownload, isTrue);
    });

    test('an EVM signer still matches its lowercased profile-linked '
        'address', () async {
      // The bulk lookup returns EVM addresses lowercased (the form the backend
      // stores) while the local wallet holds the EIP-55 checksummed form. A raw
      // membership test misses, which silently drops the ENTIRE profile
      // widening for an EVM signer — `other`'s artwork would stop being
      // downloadable even though the same profile links both wallets.
      const evmLower = '0xabcdef0123456789abcdef0123456789abcdef01';
      const evmChecksummed = '0xAbCdEf0123456789aBcDeF0123456789AbCdEf01';
      when(
        mockWalletRepo.getAllWallets(),
      ).thenAnswer((_) async => [wallet(evmChecksummed)]);
      when(
        mockProfileLookup.lastResponse,
      ).thenReturn(profileLookup([evmLower, other]));
      final p = await checkWith(asset(owner: other));
      expect(p.canDownload, isTrue);
    });

    test('false when the linked profile holds no local signer', () async {
      // The profile links `other`, but the user imported none of its wallets
      // as a signer, so the profile can't prove ownership.
      when(mockProfileLookup.lastResponse).thenReturn(
        profileLookup([other, 'ThirdWallet1111111111111111111111111111111']),
      );
      final p = await checkWith(asset(owner: other));
      expect(p.canDownload, isFalse);
    });

    test(
      'true when creator (updateAuthority) is a controlled wallet',
      () async {
        when(
          mockWalletRepo.getAllWallets(),
        ).thenAnswer((_) async => [wallet(me)]);
        final p = await checkWith(asset(owner: other, updateAuthority: me));
        expect(p.canDownload, isTrue);
      },
    );

    test('false when neither owner nor creator is controlled', () async {
      when(
        mockWalletRepo.getAllWallets(),
      ).thenAnswer((_) async => [wallet(me)]);
      final p = await checkWith(asset(owner: other, updateAuthority: other));
      expect(p.canDownload, isFalse);
    });
  });

  // Hide/unhide is authorized by the backend ONLY against the login wallet's
  // own profile (`req.user.addresses` in hideService). The Hide row must show
  // iff the backend would authorize the write — never a guaranteed 403. This is
  // strictly narrower than canDownload, which spans every session wallet: in
  // Account mode an artwork held by a non-login session wallet is downloadable
  // but NOT hideable, so canHide must gate the row instead of piggybacking on
  // canDownload.
  group('canHide', () {
    test('true when the active (login) wallet is the owner', () async {
      // `asset()` defaults its owner to the active wallet `me`.
      final p = await checkWith(asset());
      expect(p.canHide, isTrue);
    });

    test(
      'true when the active (login) wallet is the creator (updateAuthority)',
      () async {
        final p = await checkWith(asset(owner: other, updateAuthority: me));
        expect(p.canHide, isTrue);
      },
    );

    test('Account mode: a non-login session wallet\'s artwork is downloadable '
        'but NOT hideable', () async {
      // `other` is a second signable wallet the user controls (Account mode:
      // grouped locally, no shared profile with the active login wallet `me`).
      // The backend's /v0/hide authorizes only `me`'s profile, so hiding an
      // artwork owned by `other` while `me` is the login wallet always 403s.
      // Download (session-wide) is fine; Hide must be gated off — this is the
      // exact regression the old `canDownload` piggyback caused.
      when(
        mockWalletRepo.getAllWallets(),
      ).thenAnswer((_) async => [wallet(me), wallet(other)]);
      final p = await checkWith(asset(owner: other));
      expect(p.canDownload, isTrue);
      expect(p.canHide, isFalse);
    });

    test(
      'Profile mode: an artwork owned by a profile-linked wallet IS hideable',
      () async {
        // `me` (active login wallet) and `other` share one mallow profile, so
        // the backend's `req.user.addresses` includes both — hiding `other`'s
        // artwork is authorized.
        when(
          mockProfileLookup.lastResponse,
        ).thenReturn(profileLookup([me, other]));
        final p = await checkWith(asset(owner: other));
        expect(p.canHide, isTrue);
      },
    );

    test('a profile that does not contain the login wallet does not '
        'widen hide', () async {
      // The cached lookup holds a profile for OTHER wallets (not the active
      // login `me`). It must not widen `me`'s login-profile address set, so an
      // artwork owned by `other` stays non-hideable.
      when(mockProfileLookup.lastResponse).thenReturn(
        profileLookup([other, 'ThirdWallet1111111111111111111111111111111']),
      );
      final p = await checkWith(asset(owner: other));
      expect(p.canHide, isFalse);
    });

    test('false when neither owner nor creator is the login wallet', () async {
      final p = await checkWith(asset(owner: other, updateAuthority: other));
      expect(p.canHide, isFalse);
    });
  });

  // An account/profile can hold several wallets; only one is active. The
  // signing gates must widen the OWNER / update-authority arms across the
  // session so an artwork held (or authored) by a non-active session wallet
  // still surfaces its owner actions (the detail screen / edit screen then
  // auto-switches the signer). Delegate arms stay active-only.
  group('session widening — owner spans session wallets', () {
    test('non-active owner is gated off without the session set', () async {
      final p = await checkWith(asset(owner: other));
      expect(p.canTransfer, isFalse);
      expect(p.canBurn, isFalse);
      expect(p.canList, isFalse);
    });

    test('owner in the session set unlocks transfer / burn / list', () async {
      final p = await checkWith(
        asset(owner: other),
        sessionAddresses: const {other},
      );
      expect(p.canTransfer, isTrue);
      expect(p.canBurn, isTrue);
      expect(p.canList, isTrue);
    });

    test('an owner outside the session stays gated off', () async {
      final p = await checkWith(
        asset(owner: other),
        sessionAddresses: const {'a-third-wallet'},
      );
      expect(p.canTransfer, isFalse);
    });

    test('edit widens when a session wallet is the update authority', () async {
      // updateAuthority is a non-active session wallet: canEdit must surface so
      // the edit screen (and mint bloc) can auto-switch the signer to it before
      // building the edit tx.
      final p = await checkWith(
        asset(owner: other, updateAuthority: other),
        sessionAddresses: const {other},
      );
      expect(p.canEdit, isTrue);
    });

    test(
      'edit stays false when the update authority is outside the session',
      () async {
        // The update authority isn't in the session set, so there's no wallet to
        // switch the signer to — the edit item must stay hidden.
        final p = await checkWith(
          asset(owner: other, updateAuthority: other),
          sessionAddresses: const {'a-third-wallet'},
        );
        expect(p.canEdit, isFalse);
      },
    );

    test('active wallet as update authority can still edit', () async {
      final p = await checkWith(
        asset(updateAuthority: me),
        sessionAddresses: const {other},
      );
      expect(p.canEdit, isTrue);
    });

    test('Core delegate arm is unaffected by the session set', () async {
      // A burn authorized via the active wallet's delegate still works; the
      // owner is someone else and not in the session.
      final p = await checkWith(
        asset(
          standard: TokenStandard.core,
          owner: other,
          burnDelegateAuthority: me,
        ),
        sessionAddresses: const {'unrelated'},
      );
      expect(p.canBurn, isTrue);
    });
  });

  group('error handling', () {
    test('denies every permission when DAS lookup fails', () async {
      when(mockDas.getAsset(any)).thenThrow(Exception('boom'));
      final p = await service.checkPermissions(mint);
      expect(p.canTransfer, isFalse);
      expect(p.canEdit, isFalse);
      expect(p.canBurn, isFalse);
      expect(p.canList, isFalse);
      expect(p.canDownload, isFalse);
      expect(p.canHide, isFalse);
    });

    // The Details tab's Royalties row must not state a confident `0%` off a
    // read that never landed, so a thrown read is distinguishable from a read
    // that resolved and found nothing. Flags stay false either way, which is
    // what every other consumer looks at.
    test('marks a thrown DAS read as resolveFailed', () async {
      when(mockDas.getAsset(any)).thenThrow(Exception('boom'));
      final p = await service.checkPermissions(mint);
      expect(p.resolveFailed, isTrue);
      expect(p.onChainRoyaltyBps, isNull);
    });

    test('a resolved read with no permissions is NOT resolveFailed', () async {
      final p = await checkWith(asset(owner: 'someone-else'));
      expect(p.canTransfer, isFalse);
      expect(p.resolveFailed, isFalse);
    });

    test('ArtworkPermissions.none is not a failure marker', () {
      expect(ArtworkPermissions.none.resolveFailed, isFalse);
    });
  });

  group('EVM (erc721/erc1155) — on-chain ownership gate', () {
    const contract = '0x1111111111111111111111111111111111111111';
    const evmMe = '0x2222222222222222222222222222222222222222';
    const evmMint = '$contract-42';

    void stubEvmWallet() {
      // The session's ETH wallet, not the active account's — the account's
      // auto-derived ETH sibling may not be linked to the active Profile.
      when(
        mockSession.sessionWalletForChain(Chain.ethereum),
      ).thenReturn(wallet(evmMe));
    }

    test('canTransfer when the active wallet is the ERC-721 owner', () async {
      stubEvmWallet();
      when(
        mockEthRpc.erc721OwnerOf(contract: contract, tokenId: BigInt.from(42)),
      ).thenAnswer((_) async => evmMe.toLowerCase());

      final p = await service.checkPermissions(evmMint);
      expect(p.canTransfer, isTrue);
      // EVM assets never hit the Solana DAS path.
      verifyNever(mockDas.getAsset(any));
    });

    test('an external-market (OpenSea) listing refuses transfer even though '
        'the owner still holds the token', () async {
      // OpenSea/Seaport listings are recorded by the indexer
      // (`ethereumHelper.applyEthereumNftListingUpdate` → listingType=buy-now)
      // but escrow nothing, so ownership alone would offer a transfer that
      // silently kills the listing. Same gate as the Solana arm.
      stubEvmWallet();
      when(
        mockEthRpc.erc721OwnerOf(contract: contract, tokenId: BigInt.from(42)),
      ).thenAnswer((_) async => evmMe.toLowerCase());

      final p = await service.checkPermissions(
        evmMint,
        listingType: ListingType.buyNow,
      );
      expect(p.canTransfer, isFalse);
      // Download is ownership-only and must survive the listing gate.
      expect(p.canDownload, isTrue);
    });

    test('no transfer when a different wallet owns the ERC-721', () async {
      stubEvmWallet();
      when(
        mockEthRpc.erc721OwnerOf(contract: contract, tokenId: BigInt.from(42)),
      ).thenAnswer((_) async => '0x9999999999999999999999999999999999999999');

      final p = await service.checkPermissions(evmMint);
      expect(p.canTransfer, isFalse);
    });

    test('falls back to ERC-1155 balance when ownerOf reverts', () async {
      stubEvmWallet();
      when(
        mockEthRpc.erc721OwnerOf(contract: contract, tokenId: BigInt.from(42)),
      ).thenThrow(const EthereumRpcException('not erc721'));
      when(
        mockEthRpc.erc1155BalanceOf(
          owner: evmMe,
          contract: contract,
          tokenId: BigInt.from(42),
        ),
      ).thenAnswer((_) async => BigInt.from(3));

      final p = await service.checkPermissions(evmMint);
      expect(p.canTransfer, isTrue);
    });

    test('a non-active session ETH wallet owning the ERC-721 unlocks '
        'transfer', () async {
      stubEvmWallet();
      const evmOther = '0x3333333333333333333333333333333333333333';
      when(
        mockEthRpc.erc721OwnerOf(contract: contract, tokenId: BigInt.from(42)),
      ).thenAnswer((_) async => evmOther);

      // Not the active ETH wallet, but in the session → transferable.
      final p = await service.checkPermissions(
        evmMint,
        sessionAddresses: const {evmOther},
      );
      expect(p.canTransfer, isTrue);
    });

    test('a 0x-prefixed non-address session entry is not treated as an '
        'owner', () async {
      // The strict `isEthereumAddress` filter must reject 0x strings that
      // aren't bare 40-hex addresses — e.g. an EVM asset id (`<contract>-<id>`)
      // leaking into the session set. A loose `startsWith('0x')` would have
      // queried its ERC-1155 balance as if it were a wallet.
      stubEvmWallet();
      when(
        mockEthRpc.erc721OwnerOf(contract: contract, tokenId: BigInt.from(42)),
      ).thenThrow(const EthereumRpcException('not erc721'));
      when(
        mockEthRpc.erc1155BalanceOf(
          owner: evmMe,
          contract: contract,
          tokenId: BigInt.from(42),
        ),
      ).thenAnswer((_) async => BigInt.zero);

      final p = await service.checkPermissions(
        evmMint,
        sessionAddresses: const {evmMint},
      );
      expect(p.canTransfer, isFalse);
      // The asset id must never be used as an ERC-1155 owner.
      verifyNever(
        mockEthRpc.erc1155BalanceOf(
          owner: evmMint,
          contract: anyNamed('contract'),
          tokenId: anyNamed('tokenId'),
        ),
      );
    });
  });
}
