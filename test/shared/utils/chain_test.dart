import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

void main() {
  group('Chain', () {
    test('every value round-trips through its wire string', () {
      for (final chain in Chain.values) {
        expect(Chain.tryParse(chain.toDbString()), chain);
        expect(Chain.fromDbString(chain.toDbString()), chain);
      }
    });

    // The two parsers differ ONLY here, and the difference is the reason
    // `tryParse` exists: `fromDbString` claims Solana for anything it doesn't
    // recognise, which is right for a DB column this app wrote but wrong for
    // server data — a `chain: 'polygon'` artwork silently becoming Solana is
    // how an unsupported asset reaches a Solana-only signing path.
    test(
      'tryParse reports an unmodelled chain, fromDbString claims Solana',
      () {
        expect(Chain.tryParse('polygon'), isNull);
        expect(Chain.fromDbString('polygon'), Chain.solana);
      },
    );

    test('tryParse treats null and empty as unknown', () {
      expect(Chain.tryParse(null), isNull);
      expect(Chain.tryParse(''), isNull);
    });

    test('fromAddress infers the chain from the address shape', () {
      expect(
        Chain.fromAddress('0xAbCdEf0123456789AbCdEf0123456789AbCdEf01'),
        Chain.ethereum,
      );
      expect(
        Chain.fromAddress('tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb'),
        Chain.tezos,
      );
      expect(
        Chain.fromAddress('KT1RJ6PbjHpwc3M5rw5s2Nbmefwbuwbdxton'),
        Chain.tezos,
      );
      // Base58 has no distinguishing prefix, so Solana is the default.
      expect(
        Chain.fromAddress('So11111111111111111111111111111111111111112'),
        Chain.solana,
      );
    });

    // The receive sheets render all three marks at a matched size, which needs
    // a padded Solana glyph; the portfolio badge uses the full-bleed one. The
    // two must not be collapsed — doing so visibly resizes one surface.
    test('paddedIconAsset diverges from iconAsset only for Solana', () {
      expect(Chain.solana.paddedIconAsset, isNot(Chain.solana.iconAsset));
      expect(Chain.ethereum.paddedIconAsset, Chain.ethereum.iconAsset);
      expect(Chain.tezos.paddedIconAsset, Chain.tezos.iconAsset);
    });
  });

  // The shared per-chain gate behind the recipient fields' username search:
  // it decides "already an address on this chain" (suppress the search) and
  // "can this profile wallet receive here" (offer the row). A wrong answer
  // either hides the search or drops an unsendable address into the field.
  group('Chain.isValidAddress', () {
    const solana = 'So11111111111111111111111111111111111111112';
    const ethereum = '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';
    const tezos = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';

    test('accepts only the address belonging to that chain', () {
      const byChain = {
        Chain.solana: solana,
        Chain.ethereum: ethereum,
        Chain.tezos: tezos,
      };
      for (final chain in Chain.values) {
        for (final entry in byChain.entries) {
          expect(
            chain.isValidAddress(entry.value),
            chain == entry.key,
            reason: '${chain.name} vs ${entry.value}',
          );
        }
      }
    });

    // The reason this is not [Chain.fromAddress]: that one defaults every
    // unrecognised string to Solana, so a mistyped base58 recipient would be
    // waved through. Both non-EVM arms here are real decodes.
    test('rejects a mistyped address that still has the right shape', () {
      // Right length and alphabet, but decodes to the wrong byte count.
      expect(
        Chain.solana.isValidAddress(
          'So1111111111111111111111111111111111111111',
        ),
        isFalse,
      );
      // Correct tz1 prefix, corrupted Base58Check payload.
      expect(
        Chain.tezos.isValidAddress('tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjc'),
        isFalse,
      );
    });

    // Deliberate asymmetry: the EVM arm is shape-only because it also
    // classifies server-owned (lower-cased) addresses, where there is no
    // checksum to verify. [evmRecipientError] is the stricter gate for an
    // address the user typed — the two must not be collapsed into one.
    test('the Ethereum arm carries no EIP-55 checksum enforcement', () {
      final flipped = _flipFirstLetterCase(ethereum);
      expect(Chain.ethereum.isValidAddress(flipped), isTrue);
      expect(evmRecipientError(flipped), kEvmChecksumFailedMessage);
    });
  });

  group('chainLabel', () {
    test('maps each known wire value to its display label', () {
      expect(chainLabel(Chain.solana.toDbString()), 'Solana');
      expect(chainLabel(Chain.ethereum.toDbString()), 'Ethereum');
      expect(chainLabel(Chain.tezos.toDbString()), 'Tezos');
    });

    test('null defaults to "Solana" (most artworks are Solana)', () {
      expect(chainLabel(null), 'Solana');
    });

    test('unknown wire value falls back to the raw string', () {
      // Guards against an empty row in the artwork detail panel when the
      // API ships a new chain we haven't mapped yet.
      expect(chainLabel('cosmos'), 'cosmos');
      expect(chainLabel('btc'), 'btc');
    });
  });

  group('isEthereumAddress', () {
    test('accepts canonical lowercase 0x + 40 hex chars', () {
      expect(
        isEthereumAddress('0xabcdef0123456789abcdef0123456789abcdef01'),
        isTrue,
      );
    });

    test('accepts mixed-case checksummed addresses', () {
      expect(
        isEthereumAddress('0xAbCdEf0123456789AbCdEf0123456789AbCdEf01'),
        isTrue,
      );
    });

    test('rejects address missing the 0x prefix', () {
      expect(
        isEthereumAddress('abcdef0123456789abcdef0123456789abcdef01'),
        isFalse,
      );
    });

    test('rejects addresses with wrong hex length', () {
      expect(isEthereumAddress('0xabc'), isFalse);
      expect(
        isEthereumAddress('0xabcdef0123456789abcdef0123456789abcdef0123'),
        isFalse,
      );
    });

    test('rejects non-hex characters', () {
      expect(
        isEthereumAddress('0xgggggg0123456789abcdef0123456789abcdef01'),
        isFalse,
      );
    });
  });

  group('evmRecipientError', () {
    // Canonical vectors from the EIP-55 spec's test-case list.
    const checksummed = [
      '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
      '0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359',
      '0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB',
      '0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb',
    ];

    test('accepts every EIP-55 checksummed vector', () {
      for (final address in checksummed) {
        expect(evmRecipientError(address), isNull, reason: address);
      }
    });

    // The point of the whole check: one mistyped/mis-cased character in an
    // address the user typed is unrecoverable loss, and no downstream guard can
    // see it (the calldata assertion compares against this same string). Case
    // is the only signal EIP-55 gives us, so flipping exactly one character
    // must fail — for every vector, not just a lucky one.
    test('rejects a single-character case flip of each vector', () {
      for (final address in checksummed) {
        final flipped = _flipFirstLetterCase(address);
        expect(
          evmRecipientError(flipped),
          kEvmChecksumFailedMessage,
          reason: '$address → $flipped',
        );
      }
    });

    // All-lowercase carries no checksum information at all, and it is the form
    // our own backend and most block explorers hand out — rejecting it would
    // make pasting a legitimate address impossible.
    test('accepts all-lowercase addresses (no checksum information)', () {
      expect(
        evmRecipientError('0xde709f2102306220921060314715629080e2fb77'),
        isNull,
      );
      for (final address in checksummed) {
        expect(evmRecipientError(address.toLowerCase()), isNull);
      }
    });

    test('accepts all-uppercase addresses (no checksum information)', () {
      // EIP-55 vectors given in all caps by the spec.
      expect(
        evmRecipientError('0x52908400098527886E0F7030069857D2E4169EE7'),
        isNull,
      );
      expect(
        evmRecipientError('0x8617E340B3D01FA5F11F306F4090FD50E238070D'),
        isNull,
      );
    });

    test(
      'rejects wrong length / missing prefix / non-hex before checksumming',
      () {
        expect(
          evmRecipientError('0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAe'),
          'Invalid Ethereum address',
        );
        expect(
          evmRecipientError('0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAedd'),
          'Invalid Ethereum address',
        );
        expect(
          evmRecipientError('5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'),
          'Invalid Ethereum address',
        );
        expect(
          evmRecipientError('0xZZAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'),
          'Invalid Ethereum address',
        );
        expect(evmRecipientError(''), 'Invalid Ethereum address');
      },
    );

    // Containment net for the upstream primitive this gate deliberately avoids.
    //
    // web3dart 2.x's `EthereumAddress.fromHex` threw on a mixed-case address
    // whose EIP-55 checksum did not match, even with `enforceEip55: false`.
    // web3dart 3.x re-homed that type in `package:wallet`, which:
    //   * only checksums when `enforceEip55: true` (it defaults to false), and
    //   * uses `^(0x)?[0-9a-f]{40}` — no trailing `$` — so a valid address with
    //     hex appended parses into a >20-byte address, guarded only by an
    //     `assert` that release builds strip.
    // Both were confirmed accepted by wallet 0.0.18 directly. That makes
    // `evmRecipientError` the only remaining enforcement, so these two shapes
    // must stay rejected here no matter what the dependency does. If anyone
    // reimplements this gate (or `isEthereumAddress`) on top of
    // `EthereumAddress.fromHex`, this test is what fails.
    test('rejects the shapes the upstream address parser now lets through', () {
      // Mixed case, one character flipped — a wrong EIP-55 checksum.
      expect(
        evmRecipientError('0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD'),
        kEvmChecksumFailedMessage,
      );
      // A valid checksummed address with hex garbage appended.
      expect(
        evmRecipientError('0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeddeadbeef'),
        'Invalid Ethereum address',
      );
    });
  });

  group('apiOwnerAddress', () {
    // The backend indexes owners lowercased, so a checksummed EVM address sent
    // verbatim never matches and holdings silently drop out — the whole reason
    // this helper exists. Lowercasing must happen for EVM and ONLY for EVM.
    test('lowercases a checksummed EVM address', () {
      expect(
        apiOwnerAddress('0xAbCdEf0123456789AbCdEf0123456789AbCdEf01'),
        '0xabcdef0123456789abcdef0123456789abcdef01',
      );
    });

    test('leaves a case-sensitive Solana (base58) address untouched', () {
      const solana = 'So11111111111111111111111111111111111111112';
      expect(apiOwnerAddress(solana), solana);
    });

    test('leaves a case-sensitive Tezos address untouched', () {
      const tezos = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';
      expect(apiOwnerAddress(tezos), tezos);
    });

    test('passes through a non-address string unchanged', () {
      // Not a valid 0x/40-hex address, so it is not treated as EVM.
      expect(apiOwnerAddress('ETH_ADDR'), 'ETH_ADDR');
    });
  });

  group('isEthereumAsset', () {
    test('accepts <contract>-<tokenId> form', () {
      expect(
        isEthereumAsset('0xabcdef0123456789abcdef0123456789abcdef01-42'),
        isTrue,
      );
    });

    test('rejects bare contract address (no token id)', () {
      expect(
        isEthereumAsset('0xabcdef0123456789abcdef0123456789abcdef01'),
        isFalse,
      );
    });

    test('rejects non-numeric token id', () {
      expect(
        isEthereumAsset('0xabcdef0123456789abcdef0123456789abcdef01-abc'),
        isFalse,
      );
    });
  });

  group('isTezosAsset', () {
    test('returns true for any KT1-prefixed string', () {
      expect(isTezosAsset('KT1RJ6PbjHpwc3M5rw5s2Nbmefwbuwbdxton'), isTrue);
      // Heuristic-only: even a malformed KT1-prefixed string returns true.
      // This guards against tightening unrelated to the artwork-routing rule.
      expect(isTezosAsset('KT1'), isTrue);
    });

    test('rejects Solana-style and Ethereum-style identifiers', () {
      expect(
        isTezosAsset('So11111111111111111111111111111111111111112'),
        isFalse,
      );
      expect(
        isTezosAsset('0xabcdef0123456789abcdef0123456789abcdef01'),
        isFalse,
      );
    });
  });

  group('isEvmOrTezosArtwork', () {
    test('true when chain is explicitly ethereum', () {
      expect(
        isEvmOrTezosArtwork(
          mintAccount: 'irrelevant',
          chain: Chain.ethereum.toDbString(),
        ),
        isTrue,
      );
    });

    test('true when chain is explicitly tezos', () {
      expect(
        isEvmOrTezosArtwork(
          mintAccount: 'irrelevant',
          chain: Chain.tezos.toDbString(),
        ),
        isTrue,
      );
    });

    test('infers EVM from <contract>-<tokenId> mint shape', () {
      expect(
        isEvmOrTezosArtwork(
          mintAccount: '0xabcdef0123456789abcdef0123456789abcdef01-7',
        ),
        isTrue,
      );
    });

    test('infers Tezos from KT1 prefix', () {
      expect(
        isEvmOrTezosArtwork(
          mintAccount: 'KT1RJ6PbjHpwc3M5rw5s2Nbmefwbuwbdxton',
        ),
        isTrue,
      );
    });

    test('Solana mint without chain hint is NOT classified as EVM/Tezos', () {
      expect(
        isEvmOrTezosArtwork(
          mintAccount: '8DkNB1234567890123456789012345678901RYfS4',
        ),
        isFalse,
      );
    });

    test('explicit solana chain overrides nothing — defers to shape check', () {
      // A solana-chain artwork with an EVM-shaped mint would still match the
      // shape check; documented to guard against accidental short-circuit.
      expect(
        isEvmOrTezosArtwork(
          mintAccount: '0xabcdef0123456789abcdef0123456789abcdef01-1',
          chain: Chain.solana.toDbString(),
        ),
        isTrue,
      );
    });
  });
}

/// Flips the case of the first alphabetic hex character in [address] (after the
/// `0x`), producing an address that is still 40 valid hex chars but can no
/// longer match its EIP-55 checksum. Derived rather than hardcoded so the
/// vectors and their corrupted twins can never drift apart.
String _flipFirstLetterCase(String address) {
  for (var i = 2; i < address.length; i++) {
    final c = address[i];
    final upper = c.toUpperCase();
    final lower = c.toLowerCase();
    if (upper == lower) continue; // a digit — case carries nothing
    final flipped = c == lower ? upper : lower;
    return address.replaceRange(i, i + 1, flipped);
  }
  throw ArgumentError('no cased character in $address');
}
