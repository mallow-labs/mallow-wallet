# keystone_ur

The QR codec for the [Keystone](https://keyst.one) air-gapped hardware wallet,
in pure Dart.

Keystone talks to a phone only through QR codes. Each code carries a
[Uniform Resource](https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md)
(UR): a CBOR message, encoded as bytewords, split into fountain-coded parts so
a long message can be shown as an animated QR and scanned in any order, with
missed frames. This package implements both halves:

| Layer | What it covers |
|---|---|
| **UR codec** (`UrEncoder`, `UrDecoder`) | Bytewords, CRC-32, xoshiro256**, the fountain encoder and decoder — a port of the Blockchain Commons `bc-ur` reference implementation, pinned to its test vectors |
| **Solana** | `SolSignRequest` (1101) out, `SolSignature` (1102) in, `KeystoneMultiAccounts` (1103) account export → `solanaAccountsFromExport` |
| **Ethereum** | `EthSignRequest` (401) out, `EthSignature` (402) in, `classifyEthExport` / `ethStandardXpubFromUr` for the three Keystone account layouts |
| **Shared** | `KeystoneKeypath` (crypto-keypath, 304), `KeystoneHdKey` (crypto-hdkey, 303) |

Keystone uses the original Blockchain Commons tags (303, 304, 311, 37), not the
later 40000-range ones. Every encoder writes the same bytes as Keystone's own
SDKs; the tests pin that against Keystone's published vectors.

It depends only on [`cbor`](https://pub.dev/packages/cbor) and
[`crypto`](https://pub.dev/packages/crypto), and runs on the Dart VM and AOT
(Android, iOS, desktop). It does not run on the web: xoshiro256** needs 64-bit
integers.

## Usage

Show a request, read the reply:

```dart
final request = SolSignRequest(
  requestId: SolSignRequest.newRequestId(),
  signData: compiledMessage,
  path: solanaKeypath(KeystoneSolanaPath.standard, index, masterFingerprint),
);

final encoder = UrEncoder(request.toUr());
// Every kKeystoneFrameInterval: render encoder.nextPart() as a QR code.

final decoder = UrDecoder(expectedTypes: {'sol-signature'});
// For every string the camera reads:
if (decoder.receivePart(scanned) && decoder.isComplete) {
  final reply = SolSignature.fromUr(decoder.result!);
  // Check reply.requestId, then verify reply.signature against the account's
  // public key over compiledMessage before using it.
}
```

Import accounts:

```dart
final export = KeystoneMultiAccounts.fromUr(decoder.result!);
final accounts = solanaAccountsFromExport(export); // index, scheme, publicKey
```

## Things to know

- **Verify every signature.** A `sol-signature` does not say which key signed.
  A different device or path returns a valid signature from another key, so
  match the request id and verify the signature before it is used.
- **Scanned codes are untrusted input.** Every decode path throws only
  `UrDecodeException`. Its `kind` (`UrDecodeErrorKind`) distinguishes
  `unexpectedType`, `malformed` (including invalid registry data),
  `inconsistentPart`, `limitExceeded` and `checksumMismatch`, so callers can
  choose guidance without parsing the diagnostic `message`. The message-only
  constructor still works and defaults to `generic`. The decoder caps fragment
  count, message size, key count and CBOR nesting, and rejects duplicate integer map keys. Mixed fountain
  equations are bounded by both their count and total indexes; excess
  equations are ignored. `receivePart` returns `false` for a QR code that is
  not a UR, so a scanner can ignore stray codes. After a fountain checksum
  failure, every subsequent call throws; create a new decoder to retry.
- **Request ids** are 16 random bytes with the UUID v4 bits set.
- **Solana accounts** come in three shapes: standard `m/44'/501'/i'/0'`,
  legacy `m/44'/501'/i'` and root `m/44'/501'`. The device keeps indexes 0–49.

## Licence

The `bc-ur` port (`lib/src/bc_ur/`, `lib/src/ur.dart`), its ported tests
(`test/bc_ur_test.dart`) and the reference vectors in
`test/vectors/bc_ur_vectors.dart` are BSD-2-Clause-Patent; `crc32.dart` is
also available under BSD-3-Clause; the rest is MIT.
See [LICENSE](LICENSE) and [NOTICE](NOTICE).
