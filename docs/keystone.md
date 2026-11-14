# Keystone

mallow can hold Solana and Ethereum wallets whose keys live on a [Keystone](https://keyst.one), an air-gapped hardware wallet. The app and the device share no cable, no Bluetooth and no network: every exchange is a QR code shown on one screen and scanned by the other camera. The key never leaves the device, and nothing secret is stored in the app.

## What works

| | |
|---|---|
| Chains | Solana and Ethereum. **Tezos is not possible** — the firmware has no Tezos support. |
| Import | Scan any code the device shows from **Connect Software Wallet**, and as many as needed: the app reads whatever Solana accounts and Ethereum key each one carries and adds them to one picker. All three Solana paths are accepted; Ethereum is accepted in the BIP-44 standard layout (see [Ethereum](#ethereum)). |
| Signing | Every Keystone Solana transaction signs through `WalletManager.signCompiledTx` → `KeystoneSignService`, and every Ethereum transaction through `WalletManager.signEthereumTransaction` → `KeystoneSignService`. Client-built SOL/SPL sends, marketplace, mint, staking and swaps use `TransactionExecutor` → `TransactionPipeline.signAndBroadcast` → `signSendConfirm`; the in-app browser calls `signCompiledTx` directly with its pinned wallet. |
| Login | The backend's ownership proof: the device signs the challenge text verbatim, as Seed Vault does. An Ethereum row signs it as an EIP-191 personal message. |
| Browser | Solana: transactions, `solana:signMessage`, `solana:signOffchainMessage` and `solana:signIn`. The device signs a site's message bytes as given, showing a `\xffsolana offchain` message structurally and anything else as UTF-8 or hex. Ethereum: EIP-1559 transactions, `personal_sign` and `eth_signTypedData_v4`. |

## Connecting a Keystone

1. On the Keystone, open **Connect Software Wallet**. For Solana, choose **Solflare** or **Backpack**; for Ethereum, **MetaMask** or **Backpack**. The import screen says just that.
2. In mallow, choose **Connect hardware wallet** (or **Use a hardware wallet** during setup), then **Keystone**, and scan the animated code.
3. To add the other chain, tap **Scan another code** in the picker and scan the other entry's code. Codes can come in either order.
4. Pick the accounts to import.

Each code is read for what it holds (`crypto-multi-accounts`, `crypto-hdkey` or `crypto-account`), not for the entry that made it. Every code in one import must come from the same device; a code from another Keystone is refused until the user taps **Start over**.

The device has no generic "other wallet" entry, but the export it shows for a named wallet is ordinary UR data any app can read, and its signing does not check which app is asking. Solflare's entry is named because it exports the **Sub-account Path**, `m/44'/501'/i'/0'` — the path most Solana wallets use and the one mallow calls `standard`. Other entries default to the **Account-based Path** (`m/44'/501'/i'`, `legacy`); those exports import too, as legacy accounts.

| Keystone's name | Path | `SolanaDerivationScheme` |
|---|---|---|
| Sub-account Path | `m/44'/501'/i'/0'` | `standard` |
| Account-based Path | `m/44'/501'/i'` | `legacy` |
| Single Account Path | `m/44'/501'` | `root` |

The device keeps public keys for indexes 0–49 only, so the import refuses anything above 49.

## Signing

```
SOL/SPL send, marketplace, mint, staking
  → TransactionExecutor.execute
  → TransactionPipeline.signAndBroadcast
  → signSendConfirm
  → WalletManager.signCompiledTx        also called directly by the browser
  → KeystoneSignService.signSolana      builds sol-sign-request from the row
  → KeystoneSignController              (no BuildContext) → app shell listener
  → KeystoneSignSheet                   1. animated QR of the request
                                        2. camera reads the device's sol-signature
  → KeystoneSignService                 request id matches? Ed25519 verifies
                                        against the row's address?
  → 64-byte signature into the tx's signer slot
```

The request carries the compiled message bytes, a keypath built from the row's own derivation index and scheme, and the device's master fingerprint. Like Ledger and Seed Vault, the device returns a detached signature over the bytes as given, so a backend-built transaction keeps its blockhash, lookup tables and co-signatures.

**Every reply is verified before it is used.** The device's reply does not say which key produced it, and a request that named the wrong path or the wrong device comes back with a perfectly valid signature — from a different address. The sheet passes every scanned code to `KeystoneSignService`, which accepts it only if its request id is the one just shown and it verifies with Ed25519 against the wallet's address over the exact bytes sent. A stale signature from an earlier request, or one from another Keystone, is refused on the sheet with the reason, and the scanner stays open.

**Slow Keystone signatures are checked before broadcast.** A QR round trip can take longer than a transaction stays valid. A transaction with no pre-attached signature gets a fresh blockhash just before signing. If signing takes more than 10 seconds, `signSendConfirm` checks that blockhash's on-chain validity once the Keystone signature comes back. An expired signature is discarded unsent; a failed validity check still allows broadcast, with confirmation determining the outcome. Fast signing and other signer types make no extra validity query.

For a transaction only its builder can freshen — co-signed by the backend, or creating a lookup table — the executor checks a supplied builder staleness tracker after Keystone signing. If it aged past the 30-second window meanwhile, the signature is discarded unsent and the builder is asked again. The tracker covers the first transaction by default; later transactions are covered only when the caller asserts that rebuilding returns just the remaining work. For ordinary client-refreshable transactions, the executor instead retries the same transaction with another fresh blockhash. Either retry shows: "That took too long, so the transaction expired before it was sent. Approve it again on your Keystone." After two retries the flow stops with a readable error. Other signers still broadcast after crossing the conservative tracker window, which is shorter than the blockhash lifetime.

Mint and edit use no builder tracker: each real build inserts an upload record, and subsidized builds reserve a subsidy slot before returning. Automatically replaying a build can lose the subsidy and change who pays. For co-signed transactions without a tracker, signing longer than 10 seconds instead checks the original blockhash's on-chain validity. Known-expired signatures are discarded unsent and the flow immediately reports "That took too long, so the transaction expired. Try again." The executor does not re-sign those same bytes. This also covers a co-signed cNFT edit after its lookup-table setup transaction has confirmed; the setup remains on-chain. A failed validity query still allows broadcast and confirmation to decide the outcome. Unsigned mints retain the client-refresh retry path. Mint/edit do not automatically rebuild lookup-table setup instructions or check their embedded slot's age; a blockhash refresh alone does not freshen that slot.

The signing helper throws `SignedTooLateException` before broadcasting an expired Keystone signature; callers outside the executor must surface its user-facing message. Browser transactions use their own pinned `signCompiledTx` call and do not use these checks or retries.

Each transaction in a batch is its own round trip. The device has no Solana batch request. For batches run through `TransactionExecutor`, the sheet shows "Transaction k of n" near the title. A rebuilt transaction keeps its position, and the expiry notice applies only to its retry; later transactions and unrelated signing requests do not inherit it.

### Login

Keystone signs the login challenge bytes verbatim and shows the text, so the ordinary `{address, message, signature}` verify body works, as for Seed Vault. Background login never signs with a hardware wallet. The 401 retry asks for consent on the app's own sheet first, and only then opens the QR exchange.

### Swaps

Other wallets swap through Jupiter Ultra, whose order is signed verbatim — it can carry a market maker's signature, so its blockhash cannot be refreshed — and is valid for seconds. A QR round trip is far longer, so an Ultra swap would fail after the user approved it on the device.

A Keystone wallet therefore swaps on Jupiter's classic API instead. `SwapBloc` quotes a Keystone taker with `GET /swap/v1/quote`, and at execute time asks `POST /swap/v1/swap` for the unsigned transaction. That transaction needs only the user's signature, and the route and minimum output live in the swap instruction, so nothing about it expires but the blockhash. It runs through `TransactionExecutor` on the mainnet RPC: the blockhash is refreshed before the QR is shown, and a signature that comes back after it expired is retried on a fresh one, as for any client-refreshable transaction. The Ultra path keeps a backstop that refuses to sign an order with a Keystone.

mallow's swap fee follows the Keystone too. The classic API sends the fee to a token account of the input or output mint: the referral account's associated token account for that mint (classic token program, then Token-2022), where it already holds the fees Ultra collects. A missing account would fail the swap on-chain, where Ultra just skips the fee, so `SwapRepository` checks that one exists and quotes fee-free when none does.

## Ethereum

A Keystone Ethereum wallet lives on the same (fingerprint, index) account as its Solana wallet, at `m/44'/60'/0'/0/index` — the BIP-44 standard layout, the one `MultiChainDerivation` uses for seed phrases. Its address is derived in the app from the account xpub (`m/44'/60'/0'`) the device exports; the device never sends addresses.

The Ethereum key says nothing about which account indexes the user holds, so the picker lists an Ethereum wallet at every index it knows for the device: the Solana accounts scanned in this import, and the device's Keystone accounts already in mallow (matched by master fingerprint). The key comes from **MetaMask → BIP44 Standard** (one `crypto-hdkey`) or from an entry whose code carries both chains (Backpack's does; it exports Solana at the Account-based `legacy` path).

- **Ethereum code first, nothing to attach it to.** The key is kept and the scanner asks for a Solana code; the Ethereum rows appear once it is scanned.
- **Ethereum for accounts already imported.** Scan the MetaMask code on its own: each of the device's accounts shows an Ethereum row. Importing rows that all join existing accounts leaves the active account where it is and re-reads it, so the new wallet shows without switching.

Exports in the Ledger Live or Ledger Legacy layouts are refused for Ethereum: their addresses sit at other paths.

Signing sends an `eth-sign-request` (tag 401) built from the row's fingerprint and index:

| What | Data type | Sent | Checked against |
|---|---|---|---|
| Transaction | 4, typed transaction | the `0x02`-prefixed unsigned EIP-1559 serialization | `keccak256` of what was sent |
| `personal_sign`, login | 3, personal message | the raw message | the EIP-191 digest |
| `eth_signTypedData_v4` | 2, typed data | JSON rebuilt from the canonical values the review hashed (integers as decimal strings, bytes and addresses as hex) | the EIP-712 digest the review computed |

**The device ignores the address field and signs by path**, so the reply proves nothing by arriving. `KeystoneSignService.signEthereum` recovers the signer from the `eth-signature` over the digest computed in the app and accepts it only when it is the row's address. The same check refuses a typed-data signature over JSON the device hashed differently. The device writes `v` as 0/1, 27/28 or in EIP-155 form; it is normalised to 27/28, and a transaction's envelope is reassembled exactly as for a Ledger. Legacy (pre-EIP-1559) transactions are refused.

## What is stored

| Where | What |
|---|---|
| `Wallets` row | address, `walletType = 'keystone'`, `chain`, `derivationIndex`, `derivationScheme`, `masterFingerprint` |
| `Accounts` row | `kind = 'keystone'`, `derivationIndex`, `masterFingerprint` |
| Recovery graph | the same fields, so a restored row can still build a request |

Keystone accounts are keyed by (fingerprint, index), because two Keystones both export index 0. Nothing is written to either secret store, so removing a Keystone wallet deletes no secret.

## The protocol

Keystone speaks Blockchain Commons **Uniform Resources** (UR): CBOR payloads in `ur:<type>/…` strings, split into fountain-coded parts when they do not fit one QR code. `packages/keystone_ur/` is a pure-Dart implementation of the parts mallow needs.

Keystone uses the **original** registry tags — `crypto-hdkey` 303, `crypto-keypath` 304, `uuid` 37 — not their 40303/40304 replacements.

| Type | Tag | Map |
|---|---|---|
| `sol-sign-request` | 1101 | 1: request id `#6.37(bytes16)` · 2: sign data · 3: `#6.304` keypath with the master fingerprint · 5: origin · 6: 1 transaction / 2 message |
| `sol-signature` | 1102 | 1: request id · 2: 64-byte Ed25519 signature |
| `crypto-multi-accounts` | 1103 | 1: master fingerprint · 2: `[#6.303 crypto-hdkey]` · 3: device · 4: device id · 5: version |
| `eth-sign-request` | 401 | 1: request id · 2: sign data · 3: data type · 4: chain id · 5: keypath with the master fingerprint · 6: address (ignored by the firmware) · 7: origin |
| `eth-signature` | 402 | 1: request id · 2: `r ‖ s ‖ v` |

Key 4 of `sol-sign-request` (address) is never sent: the firmware ignores it, and Keystone's own SDKs disagree on its encoding. Key 6 is also ignored by the firmware, which works out for itself whether the bytes are a transaction or a message. Animated codes use 200-byte fragments at 150 ms per frame, in upper case so the QR uses alphanumeric mode.

## Not yet

- Ethereum accounts in the Ledger Live or Ledger Legacy layouts.
- Verification of Ethereum signing on a physical Keystone 3 Pro, including how the device shows typed data and personal messages.
- Key Derivation Call, where the app shows a request for the paths it wants and the device answers with an export.

## References

- [BCR-2020-005: Uniform Resources](https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md)
- [BCR-2020-006: UR type registry](https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-006-urtypes.md)
- [Keystone SDK (Rust registry)](https://github.com/KeystoneHQ/keystone-sdk-rust/tree/master/libs/ur-registry)
- [Keystone 3 firmware](https://github.com/KeystoneHQ/keystone3-firmware)
