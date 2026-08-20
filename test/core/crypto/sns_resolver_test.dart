import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/sns_resolver.dart';

/// Every fixture below is a real mainnet account, captured so the decode +
/// selection rules can be exercised without a network round trip.
///
/// - `sloth.sol` — plain domain, resolves to its registry owner.
/// - `bobtoshi.sol` — carries a Solana-validated SNS-IP-5 `SOL` record.
/// - `chiba.sol` — wrapped as an NFT: its registry owner is the tokenizer PDA,
///   which is off-curve and cannot receive funds.
/// - `vesting_lsdai_team2.sol` — carries a legacy signed `SOL` record whose
///   content differs from the registry owner and whose signature still checks
///   out, so the record (not the owner) is the payable address.
const _slothRegistry =
    'PVPCSzg2DtOBOiPfst/YIKtYIct5KaONLqqyUug4JZUM5QlDopVhrM93Fsvi85zWS5M4MnFe'
    '2+ugZYdFIdDLcwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _slothOwner = 'sLTHMt3rEnnKNe6ixeSR41wNSDxVuDkfE1sKe9wfhFQ';

const _bobtoshiRegistry =
    'PVPCSzg2DtOBOiPfst/YIKtYIct5KaONLqqyUug4JZVQ14uNAb3PI3OJLYgrpACsh+XRLFQk'
    '69dFkqVCgR9s6QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _bobtoshiSolRecordV2 =
    '3zWMi4fz0qfjw1FM3alelznsr0h2M1xt1B2dS2I3Xxwa/X4WPHX766nOooHJFCwMxS6M+OTJ'
    '1WbsupZ/EhPyqhr9fhY8dfvrqc6igckULAzFLoz45MnVZuy6ln8SE/KqAQABACAAAABQ14uN'
    'Ab3PI3OJLYgrpACsh+XRLFQk69dFkqVCgR9s6VDXi40Bvc8jc4ktiCukAKyH5dEsVCTr10WS'
    'pUKBH2zpUNeLjQG9zyNziS2IK6QArIfl0SxUJOvXRZKlQoEfbOk=';
const _bobtoshiOwner = '6SaFDExM2vpHrByZsQiox75iaWAbtyQdcbBKX9vrBbsE';

const _chibaRegistry =
    'PVPCSzg2DtOBOiPfst/YIKtYIct5KaONLqqyUug4JZUAAetKKzXTfdllV2q+0PuJg2OKo41K'
    'Za0XwSpEhE2g8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _chibaNftRecord =
    'Av+BZqyhGxnYwpebBKHjFN6HCSN4AldEnahtXnFwjGm2VTohJ+bEgAB0JgEeg9+NpVkkpgEq'
    'NwsSUbFrLbheRib98cAQIRi4IrMwNrcldGl4nfsCfh/CDNOX50qAP/rB3M8=';
const _chibaNftMint = 'HGh7mRwADH6YecGpTgnGDpW9WKQZcLqrkbZPGNQHdgRc';

const _vestingSolRecordV1 =
    'JCJU2R8mmvNcOCdEFQ5GkiDKg3p4nwUCPTWa/T93tEvvvJJk9DA96wWxl/tt4LT1N+joEL7C'
    'IA5dpjmYqr6qyQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAOmZH7r8mU7G/UbmO'
    'kpaUk9p+gNFsdaRy78ELD/Ry8HFtlvafC2a34P5GTdlJVQuGf3yzmlmltyIfiHqB4lZD5gm1'
    'MhK8I1C82vMJZmb2VRCtji8JHxOWJxRs0CAOiN8M';
const _vestingRecordContent = '4vy73qsxstL6q5rXWyCLEMJtdwrLH9vqacYm5Sbht8eU';

/// Header of `vesting_lsdai_team2.sol`'s registry. Only the owner (bytes
/// 32..64) participates in resolution, so a header is enough.
List<int> _registryOwnedBy(String ownerBase58) => [
  ...List<int>.filled(32, 0),
  ..._base58Decode(ownerBase58),
  ...List<int>.filled(32, 0),
];

const _vestingOwner = 'H8qDPn7iMZCs8EBwhCHpBrXjvxWgnX6GUmsC2qQvmKvp';

void main() {
  group('SnsResolver.isSolDomain', () {
    test('accepts a normal .sol domain', () {
      expect(SnsResolver.isSolDomain('mallow.sol'), isTrue);
    });

    test('rejects bare ".sol" with no name (length <= 4)', () {
      // The guard requires length > 4 to keep the resolver from issuing a
      // request for an empty name.
      expect(SnsResolver.isSolDomain('.sol'), isFalse);
    });

    test('rejects strings without the .sol suffix', () {
      expect(SnsResolver.isSolDomain('mallow'), isFalse);
      expect(SnsResolver.isSolDomain('mallow.eth'), isFalse);
      expect(SnsResolver.isSolDomain(''), isFalse);
    });

    test('is case-insensitive and trims surrounding whitespace', () {
      expect(SnsResolver.isSolDomain('MALLOW.SOL'), isTrue);
      expect(SnsResolver.isSolDomain('  mallow.sol  '), isTrue);
      expect(SnsResolver.isSolDomain('mallow.Sol'), isTrue);
    });

    test('a Solana base58 address is NOT a .sol domain', () {
      expect(
        SnsResolver.isSolDomain('So11111111111111111111111111111111111111112'),
        isFalse,
      );
    });
  });

  group('SnsResolver.deriveAccountKeys', () {
    // A wrong derivation reads someone else's account, so these are pinned to
    // addresses verified against mainnet.
    test('derives the registry account of a second-level domain', () async {
      final keys = await SnsResolver.deriveAccountKeys('sloth.sol');
      expect(
        keys!.registry.toBase58(),
        'BQZBBSk1bXEqrRPJrsZSHxTVdFcEGFb8UeLSUoTKFoxY',
      );
    });

    test('derives the nft record and both SOL record accounts', () async {
      final keys = await SnsResolver.deriveAccountKeys('bonfida.sol');
      expect(
        keys!.registry.toBase58(),
        'Crf8hzfthWGbGbLTVCiqRqV5MVnbpHB1L9KQMd6gsinb',
      );
      expect(
        keys.nftRecord.toBase58(),
        'ET1ZtHQxL7oii4R4aMqvd2Rqf6cxwwbJZPHJNqSFLWZn',
      );
      // V1 and V2 records are distinct accounts under different label prefixes
      // and name classes — swapping them silently reads the wrong record.
      expect(
        keys.solRecordV1.toBase58(),
        '5WCZ6uhXPXJ7UrzBvXBnE9biZykq1ezJ6JhYe6CHgA7d',
      );
      expect(
        keys.solRecordV2.toBase58(),
        'ETARvCjLwjyM6Jux1ndxuXuYEYy56Nf5uvU3abL1WyW6',
      );
    });

    test('derives a subdomain under its parent, not the root', () async {
      // Matches the SNS SDK's own derivation test vector.
      final keys = await SnsResolver.deriveAccountKeys('dex.bonfida.sol');
      expect(
        keys!.registry.toBase58(),
        'HoFfFXqFHAC8RP3duuQNzag1ieUwJRBv1HtRNiWFq4Qu',
      );
    });

    test('is case- and whitespace-insensitive', () async {
      final keys = await SnsResolver.deriveAccountKeys('  SLOTH.SOL ');
      expect(
        keys!.registry.toBase58(),
        'BQZBBSk1bXEqrRPJrsZSHxTVdFcEGFb8UeLSUoTKFoxY',
      );
    });

    test(
      'rejects malformed domains rather than deriving a stray account',
      () async {
        // SNS supports one level of subdomain; anything deeper is not a domain.
        expect(
          await SnsResolver.deriveAccountKeys('deep.sub.alice.sol'),
          isNull,
        );
        expect(await SnsResolver.deriveAccountKeys('.sol'), isNull);
        expect(await SnsResolver.deriveAccountKeys('sub..sol'), isNull);
      },
    );
  });

  group('SnsResolver.resolveFromAccounts', () {
    late SnsAccountKeys slothKeys;
    late SnsAccountKeys chibaKeys;
    late SnsAccountKeys bobtoshiKeys;
    late SnsAccountKeys vestingKeys;

    setUpAll(() async {
      slothKeys = (await SnsResolver.deriveAccountKeys('sloth.sol'))!;
      chibaKeys = (await SnsResolver.deriveAccountKeys('chiba.sol'))!;
      bobtoshiKeys = (await SnsResolver.deriveAccountKeys('bobtoshi.sol'))!;
      vestingKeys = (await SnsResolver.deriveAccountKeys(
        'vesting_lsdai_team2.sol',
      ))!;
    });

    test('a plain domain resolves to its registry owner', () async {
      final result = await SnsResolver.resolveFromAccounts(
        keys: slothKeys,
        registry: base64Decode(_slothRegistry),
        nftRecord: null,
        solRecordV1: null,
        solRecordV2: null,
      );
      expect(result, isA<SnsResolvedAddress>());
      expect((result as SnsResolvedAddress).address, _slothOwner);
    });

    test('a missing registry does not resolve', () async {
      final result = await SnsResolver.resolveFromAccounts(
        keys: slothKeys,
        registry: null,
        nftRecord: null,
        solRecordV1: null,
        solRecordV2: null,
      );
      expect(result, isA<SnsUnresolvable>());
    });

    test(
      'a tokenized domain resolves through its NFT, not the registry owner',
      () async {
        // chiba.sol's registry owner is the tokenizer PDA. Paying it would burn
        // the transfer, so the mint must be surfaced for a holder lookup.
        final result = await SnsResolver.resolveFromAccounts(
          keys: chibaKeys,
          registry: base64Decode(_chibaRegistry),
          nftRecord: base64Decode(_chibaNftRecord),
          solRecordV1: null,
          solRecordV2: null,
        );
        expect(result, isA<SnsTokenizedDomain>());
        expect((result as SnsTokenizedDomain).nftMint, _chibaNftMint);
      },
    );

    test('an off-curve registry owner is refused, never returned', () async {
      // Same domain with the NFT record absent: the owner on file is a program
      // address that cannot sign, so resolution must fail instead of handing
      // back an unspendable destination.
      final result = await SnsResolver.resolveFromAccounts(
        keys: chibaKeys,
        registry: base64Decode(_chibaRegistry),
        nftRecord: null,
        solRecordV1: null,
        solRecordV2: null,
      );
      expect(result, isA<SnsUnresolvable>());
    });

    test('an inactive NFT record falls back to the registry owner', () async {
      // Tag 3 (InactiveRecord) means the domain was unwrapped.
      final unwrapped = base64Decode(_chibaNftRecord);
      unwrapped[0] = 3;
      final result = await SnsResolver.resolveFromAccounts(
        keys: slothKeys,
        registry: base64Decode(_slothRegistry),
        nftRecord: unwrapped,
        solRecordV1: null,
        solRecordV2: null,
      );
      expect((result as SnsResolvedAddress).address, _slothOwner);
    });

    test('a valid SNS-IP-5 record resolves to its content', () async {
      final result = await SnsResolver.resolveFromAccounts(
        keys: bobtoshiKeys,
        registry: base64Decode(_bobtoshiRegistry),
        nftRecord: null,
        solRecordV1: null,
        solRecordV2: base64Decode(_bobtoshiSolRecordV2),
      );
      expect((result as SnsResolvedAddress).address, _bobtoshiOwner);
    });

    test('a stale SNS-IP-5 record is ignored, not obeyed', () async {
      // The record's staleness id no longer matches the registry owner, which
      // is what a domain transfer looks like: the previous owner's routing must
      // not survive the sale.
      final result = await SnsResolver.resolveFromAccounts(
        keys: bobtoshiKeys,
        registry: _registryOwnedBy(_slothOwner),
        nftRecord: null,
        solRecordV1: null,
        solRecordV2: base64Decode(_bobtoshiSolRecordV2),
      );
      expect((result as SnsResolvedAddress).address, _slothOwner);
    });

    test('an unverified SNS-IP-5 record blocks resolution', () async {
      // Validation kind 0 (None) proves nothing about the destination. Falling
      // back to the owner would quietly ignore what the domain says.
      final unverified = base64Decode(_bobtoshiSolRecordV2);
      unverified[96] = 0;
      final result = await SnsResolver.resolveFromAccounts(
        keys: bobtoshiKeys,
        registry: base64Decode(_bobtoshiRegistry),
        nftRecord: null,
        solRecordV1: null,
        solRecordV2: unverified,
      );
      expect(result, isA<SnsUnresolvable>());
    });

    test(
      'a signed legacy record resolves to its content, not the owner',
      () async {
        final result = await SnsResolver.resolveFromAccounts(
          keys: vestingKeys,
          registry: _registryOwnedBy(_vestingOwner),
          nftRecord: null,
          solRecordV1: base64Decode(_vestingSolRecordV1),
          solRecordV2: null,
        );
        expect((result as SnsResolvedAddress).address, _vestingRecordContent);
        expect(result.address, isNot(_vestingOwner));
      },
    );

    test('a legacy record signed by a former owner falls through', () async {
      // Signatures are checked against the *current* owner, so a record left
      // behind by a previous owner cannot redirect the funds.
      final result = await SnsResolver.resolveFromAccounts(
        keys: vestingKeys,
        registry: _registryOwnedBy(_slothOwner),
        nftRecord: null,
        solRecordV1: base64Decode(_vestingSolRecordV1),
        solRecordV2: null,
      );
      expect((result as SnsResolvedAddress).address, _slothOwner);
    });

    test(
      'a legacy record verified against the wrong record key is rejected',
      () async {
        // The signed payload commits to the record's own address; verifying with
        // another domain's record key must not pass.
        final result = await SnsResolver.resolveFromAccounts(
          keys: slothKeys,
          registry: _registryOwnedBy(_vestingOwner),
          nftRecord: null,
          solRecordV1: base64Decode(_vestingSolRecordV1),
          solRecordV2: null,
        );
        expect((result as SnsResolvedAddress).address, _vestingOwner);
      },
    );
  });
}

/// Minimal base58 decode for the fixture owners above.
List<int> _base58Decode(String input) {
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  var value = BigInt.zero;
  for (final char in input.split('')) {
    value = value * BigInt.from(58) + BigInt.from(alphabet.indexOf(char));
  }
  final bytes = <int>[];
  var remaining = value;
  while (remaining > BigInt.zero) {
    bytes.insert(0, (remaining % BigInt.from(256)).toInt());
    remaining = remaining ~/ BigInt.from(256);
  }
  for (final char in input.split('')) {
    if (char != '1') break;
    bytes.insert(0, 0);
  }
  return bytes;
}
