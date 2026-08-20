import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

/// Solana's system-program id, which is what `Pubkey::default()` base58-encodes
/// to. The edition read stringifies `WhitelistConfig.walletsRoot`
/// unconditionally, so a listing with
/// a whitelist config but no *wallet* allowlist (e.g. a holder-only token gate)
/// arrives as this value rather than as null.
const kDefaultPubkey = '11111111111111111111111111111111';

/// The two halves of an on-chain whitelist phase.
///
/// A `WhitelistConfig` can qualify a buyer by EITHER path and the webapp ORs
/// them into one verdict — `holderOnlyNftMint != null || isWalletWhitelisted`
/// (`useWhitelistConfig`):
///
///  * **wallet allowlist** — `WhitelistConfig.walletsRoot`, a Merkle root of
///    addresses, checked via `POST /v0/whitelist/checkEligibility`;
///  * **holder-only token gate** — `WhitelistConfig.collectionsOrCreators`,
///    satisfied by owning an NFT from one of those collections/creators,
///    checked via `POST /v0/getHolderOnlyMint`.
///
/// Both are distinct from `Nft.offChainWhitelistMerkleRoot`
/// (`ArtworkDetails.offChainWhitelistDenied`), which has no on-chain account
/// and is enforced only inside the tx builder — callers keep that as its own
/// term (`EditionBox`).
@lazySingleton
class WhitelistEligibilityRepository {
  WhitelistEligibilityRepository(this._api);

  final api.MallowApiClient _api;

  /// Whether the **wallet allowlist** path qualifies [address].
  ///
  /// `true` = on the list. `false` = this path does not qualify the wallet —
  /// either the server returned an empty eligible-root set, or the listing has
  /// no wallet allowlist at all ([walletsRoot] absent/default), which is
  /// exactly what the webapp's query returns for `walletsRoot.equals(
  /// PublicKey.default)` (`useWhitelistConfig`). **null = unknown**:
  /// the request failed, or there is no address to ask about.
  ///
  /// `false` is safe here only because it is never blocking on its own — see
  /// [isWhitelistPhaseBlocked], which requires BOTH paths to say no.
  ///
  /// See [holdsGatingNft] for why null must not block.
  Future<bool?> isWalletAllowlisted({
    required String? walletsRoot,
    required String address,
  }) async {
    if (address.isEmpty) return null;
    if (walletsRoot == null ||
        walletsRoot.isEmpty ||
        walletsRoot == kDefaultPubkey) {
      return false;
    }
    try {
      final response = await _api.checkWhitelistEligibility(
        api.WhitelistEligibilityRequest(
          merkleRoots: [walletsRoot],
          address: address,
        ),
      );
      return response.result.isNotEmpty;
    } catch (e) {
      debugPrint('[WhitelistEligibilityRepository] checkEligibility: $e');
      return null;
    }
  }

  /// Whether the **holder-only token gate** qualifies [address] on the listing
  /// at [listingPda] (`["listing", mint]` — derive it with
  /// `MarketAccountRepository.deriveListingPda`, NOT the mint itself).
  ///
  /// `true` = the wallet holds a qualifying NFT. `false` = it does not — which
  /// the backend also returns when the listing defines no holder gate at all;
  /// the two are indistinguishable on the wire and the webapp does not
  /// distinguish them either (`holderOnlyNftMint != null` is the whole test).
  /// **null = unknown**: the request failed, or there is nothing to ask about.
  ///
  /// Callers MUST treat null as "do not block", the same posture as
  /// [isWalletAllowlisted] and for the same reason: these routes are one
  /// round-trip on mobile data behind an authenticated session, the on-chain
  /// program is the authority either way, and the asymmetry is stark. A false
  /// "Not allowlisted" during the one minute of a drop that matters costs a
  /// qualified collector the drop, with no retry affordance; letting an
  /// unqualified one through costs at worst a single signing prompt on a
  /// transaction the program rejects — which is precisely today's behaviour
  /// with no gate at all. This is a deliberate divergence from the webapp,
  /// whose react-query `initialData` fails closed; consistency between the two
  /// halves of this gate matters more than matching that.
  Future<bool?> holdsGatingNft({
    required String listingPda,
    required String address,
  }) async {
    if (listingPda.isEmpty || address.isEmpty) return null;
    try {
      final response = await _api.getHolderOnlyMint(
        api.HolderOnlyMintRequest(address: address, listingAddress: listingPda),
      );
      return response.result != null;
    } catch (e) {
      debugPrint('[WhitelistEligibilityRepository] getHolderOnlyMint: $e');
      return null;
    }
  }
}

/// Whether an active whitelist phase blocks this wallet from buying.
///
/// The webapp's composition, verbatim: `isWhitelistPhase && !isWhitelisted`
/// where `isWhitelisted = holderOnlyNftMint != null || isWalletWhitelisted`
/// (`EditionBox`, `useWhitelistConfig`). Outside the
/// phase the listing is public and neither path gates anything.
///
/// The one deliberate divergence is the treatment of an **unknown** verdict:
/// exclusion requires BOTH paths to definitively say no. If either check could
/// not be performed we cannot conclude the wallet is excluded, so it is not
/// blocked — see [WhitelistEligibilityRepository.holdsGatingNft] for the
/// reasoning. `false` from a single path is therefore never blocking by
/// itself, which is what lets "no wallet allowlist on this listing" be
/// modelled as `false` rather than as unknown: a token-gated drop with a
/// default `walletsRoot` is still gated, by the holder check.
bool isWhitelistPhaseBlocked({
  required bool phaseActive,
  required bool? walletAllowlisted,
  required bool? holdsGatingNft,
}) {
  if (!phaseActive) return false;
  if (walletAllowlisted == true || holdsGatingNft == true) return false;
  return walletAllowlisted == false && holdsGatingNft == false;
}
