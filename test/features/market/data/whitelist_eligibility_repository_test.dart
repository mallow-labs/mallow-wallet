import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/market/data/whitelist_eligibility_repository.dart';
import 'package:mocktail/mocktail.dart';

// An on-chain whitelist phase has TWO paths and either one qualifies a
// buyer: the wallet Merkle allowlist (`POST /v0/whitelist/checkEligibility`)
// and the holder-only token gate (`POST /v0/getHolderOnlyMint`). Both are
// different lists from `Nft.offChainWhitelistMerkleRoot`.
//
// What matters here is that neither check collapses "the server says no" into
// "I could not ask": the first may contribute to disabling Buy, the second
// must never do so, because a false "Not allowlisted" during a supply-limited
// drop is unrecoverable while an extra signing prompt is not.

class _MockApi extends Mock implements MallowApiClient {}

const _root = 'B2rootB2rootB2rootB2rootB2rootB2rootB2rootB2';
const _address = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
const _listingPda = 'PdA11111111111111111111111111111111111111111';
const _gatingMint = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

void main() {
  late _MockApi api;
  late WhitelistEligibilityRepository repo;

  setUpAll(() {
    registerFallbackValue(
      const WhitelistEligibilityRequest(merkleRoots: [], address: ''),
    );
    registerFallbackValue(
      const HolderOnlyMintRequest(address: '', listingAddress: ''),
    );
  });

  setUp(() {
    api = _MockApi();
    repo = WhitelistEligibilityRepository(api);
  });

  test(
    'a non-empty eligible-root set means the wallet IS allowlisted',
    () async {
      when(() => api.checkWhitelistEligibility(any())).thenAnswer(
        (_) async => const ApiResponse<List<String>>(result: [_root]),
      );
      expect(
        await repo.isWalletAllowlisted(walletsRoot: _root, address: _address),
        isTrue,
      );
      final sent =
          verify(
                () => api.checkWhitelistEligibility(captureAny()),
              ).captured.single
              as WhitelistEligibilityRequest;
      expect(sent.merkleRoots, [_root]);
      expect(sent.address, _address);
    },
  );

  test(
    'an empty eligible-root set is a definitive exclusion, not unknown',
    () async {
      when(
        () => api.checkWhitelistEligibility(any()),
      ).thenAnswer((_) async => const ApiResponse<List<String>>(result: []));
      expect(
        await repo.isWalletAllowlisted(walletsRoot: _root, address: _address),
        isFalse,
      );
    },
  );

  test(
    'a failed check reports UNKNOWN rather than exclusion (fails open)',
    () async {
      when(
        () => api.checkWhitelistEligibility(any()),
      ).thenThrow(Exception('offline'));
      expect(
        await repo.isWalletAllowlisted(walletsRoot: _root, address: _address),
        isNull,
      );
    },
  );

  test(
    'a listing with no WALLET allowlist is not asked about, and reports "this '
    'path does not qualify you" rather than unknown',
    () async {
      // The backend stringifies `walletsRoot` unconditionally, so a listing
      // whose whitelist config only carries a holder-only token gate arrives as
      // the default pubkey. It must not read as *unknown*, or the holder gate
      // below would be neutralised by the fail-open rule and a token-gated drop
      // would be inert. The webapp returns plain `false` here too.
      for (final root in <String?>[null, '', kDefaultPubkey]) {
        expect(
          await repo.isWalletAllowlisted(walletsRoot: root, address: _address),
          isFalse,
          reason: 'root=$root',
        );
      }
      verifyNever(() => api.checkWhitelistEligibility(any()));
    },
  );

  test('no connected address is unknown, not exclusion', () async {
    expect(
      await repo.isWalletAllowlisted(walletsRoot: _root, address: ''),
      isNull,
    );
    expect(
      await repo.holdsGatingNft(listingPda: _listingPda, address: ''),
      isNull,
    );
    verifyNever(() => api.checkWhitelistEligibility(any()));
    verifyNever(() => api.getHolderOnlyMint(any()));
  });

  group('holder-only token gate', () {
    test('a returned mint means the wallet holds a qualifying NFT', () async {
      when(() => api.getHolderOnlyMint(any())).thenAnswer(
        (_) async => const HolderOnlyMintResponse(result: _gatingMint),
      );
      expect(
        await repo.holdsGatingNft(listingPda: _listingPda, address: _address),
        isTrue,
      );
      // The route keys on the LISTING PDA — passing the mint would resolve a
      // different (or no) WhitelistConfig and silently qualify nobody.
      final sent =
          verify(() => api.getHolderOnlyMint(captureAny())).captured.single
              as HolderOnlyMintRequest;
      expect(sent.listingAddress, _listingPda);
      expect(sent.address, _address);
    });

    test(
      'a null result is a definitive "this path does not qualify you"',
      () async {
        // The backend returns null both for "you hold nothing that qualifies"
        // and for "this listing has no holder gate". They are indistinguishable
        // on the wire and the webapp does not distinguish them either.
        when(
          () => api.getHolderOnlyMint(any()),
        ).thenAnswer((_) async => const HolderOnlyMintResponse());
        expect(
          await repo.holdsGatingNft(listingPda: _listingPda, address: _address),
          isFalse,
        );
      },
    );

    test(
      'a failed check reports UNKNOWN rather than exclusion (fails open)',
      () async {
        when(
          () => api.getHolderOnlyMint(any()),
        ).thenThrow(Exception('offline'));
        expect(
          await repo.holdsGatingNft(listingPda: _listingPda, address: _address),
          isNull,
        );
      },
    );
  });

  group('isWhitelistPhaseBlocked', () {
    // The webapp's composition verbatim: `isWhitelistPhase && !(holderOnlyMint
    // != null || isWalletWhitelisted)`. Exclusion needs BOTH paths to say no.
    test('either path qualifying is enough to let the buyer through', () {
      expect(
        isWhitelistPhaseBlocked(
          phaseActive: true,
          walletAllowlisted: true,
          holdsGatingNft: false,
        ),
        isFalse,
      );
      expect(
        isWhitelistPhaseBlocked(
          phaseActive: true,
          walletAllowlisted: false,
          holdsGatingNft: true,
        ),
        isFalse,
      );
    });

    test('both paths definitively saying no is the only blocking case', () {
      expect(
        isWhitelistPhaseBlocked(
          phaseActive: true,
          walletAllowlisted: false,
          holdsGatingNft: false,
        ),
        isTrue,
      );
    });

    test('an unknown verdict on either path never blocks', () {
      // Half the gate failing to answer cannot prove exclusion — and the cost
      // of guessing wrong is losing the drop.
      expect(
        isWhitelistPhaseBlocked(
          phaseActive: true,
          walletAllowlisted: false,
          holdsGatingNft: null,
        ),
        isFalse,
      );
      expect(
        isWhitelistPhaseBlocked(
          phaseActive: true,
          walletAllowlisted: null,
          holdsGatingNft: false,
        ),
        isFalse,
      );
    });

    test('nothing gates once the phase is over', () {
      expect(
        isWhitelistPhaseBlocked(
          phaseActive: false,
          walletAllowlisted: false,
          holdsGatingNft: false,
        ),
        isFalse,
      );
    });
  });
}
