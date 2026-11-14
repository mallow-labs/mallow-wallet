<p align="center">
  <img src="assets/icon/app_icon.png" alt="" width="96">
</p>

# mallow wallet

A security-first, self-custody wallet for Solana, Ethereum, and Tezos. iOS and
Android, built with Flutter. There is no web or desktop build.

[![CI](https://github.com/mallow-labs/mallow-wallet/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mallow-labs/mallow-wallet/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.44.8-02569B?logo=flutter&logoColor=white)](CONTRIBUTING.md)

Get it on the [App Store](https://apps.apple.com/app/id6758995397),
[Google Play](https://play.google.com/store/apps/details?id=com.mallow.wallet.android)
or the Solana dApp Store. [SECURITY.md](SECURITY.md) lists the official builds
and how to tell one from a copy.

<p align="center">
  <img src="docs/images/gallery.webp" width="320"
       alt="A grid of collected artworks across Solana, Ethereum and Tezos">
</p>

<p align="center"><em>All your SOL/ETH/TEZ artworks in one place.</em></p>

---

## Security model

Each claim names what proves it; [docs/security.md](docs/security.md) has the full model.

- **Keys you create or import never leave the device.** Mnemonics and imported
  private keys go to `MnemonicVault` ([`lib/core/security/`](lib/core/security/)),
  not `flutter_secure_storage`: an iOS Keychain item marked
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (no iCloud, no device backup),
  and on Android a non-exportable AES-256-GCM key generated inside
  AndroidKeystore, with only ciphertext on disk. No escrow, no server-side
  backup, no code path that transmits key material.
- **Hardware wallets keep their key off the phone entirely.** A Ledger signs over
  BLE; a Keystone signs Solana and Ethereum transactions air-gapped, by QR code
  in both directions ([docs/keystone.md](docs/keystone.md)); and on Android a
  wallet can be backed by the device's own Seed Vault (Solana Mobile) —
  Android-only, and Solana-only, because Seed Vault defines exactly one signing
  purpose. In every case mallow stores no key and no signature is produced
  without an approval the user gives outside this app. The Seed Vault
  option only appears when the OS actually provides one, decided by a runtime
  probe rather than by the device model, which any ROM can claim.
- **Social sign-in wallets have a different custody model**
  ([`lib/core/social_vault/`](lib/core/social_vault/)). A Google or Apple
  wallet is a recovery phrase kept in a *social vault*: the backend stores it
  encrypted and cannot open it. Your sign-in finds the vault; a key only your
  devices hold opens it — a secret in your iCloud Keychain or Google backup
  (end-to-end encrypted), or a passkey. So the wallet comes back after a
  reinstall or on a new device, and someone with only your Google or Apple
  account cannot open it — but someone with that account *and* your device
  backup or a passkey can, and if you lose the account itself only an exported
  recovery phrase brings the wallet back (Settings → Security & Privacy → Show
  secrets). On iOS 16 and 17 no passkey can be added, so the web needs one from
  an iOS 18 or Android device. Create or import a wallet instead if you want
  none of this.
- **Wallets from the older sign-in are a different thing again.** Before the
  vault, Google and Apple sign-in ran through Web3Auth, and for such a wallet
  the Google or Apple account alone reproduces the keys. The app no longer
  contains Web3Auth and never moves such a wallet into a vault. One that is
  already on a phone keeps working from its stored keys, carries a small mark
  on its Google or Apple icon, and says what it is on its own screens. If the
  phone is lost, it is recovered on the mallow website with the older sign-in:
  export its keys there and import them in the app.
- **Signing is gated by app lock; per-transaction auth is opt-in and off by
  default.** The floor is the lock screen — biometric-first with a PIN fallback,
  on cold start and after 60 seconds backgrounded. `TransactionAuthGate` can
  demand a second factor per transaction, but it is off unless you enable it in
  Settings → Security & Privacy. A default install does not prompt per signature.
- **EVM transfers are simulated, and the gate fails closed.** They run through
  `eth_simulateV1`, and signing is blocked unless the only asset movement is the
  one you asked for; an unreachable simulation endpoint errors the transfer
  rather than proceeding unchecked
  (`_assertSimulation` in [`ethereum_transfer_service.dart`](lib/features/send/services/ethereum_transfer_service.dart)).
- **Websites ask for signatures through the in-app browser or WalletConnect.**
  There is no Mobile Wallet Adapter endpoint and no `mallowwallet://` signing
  intent. Another app can open a web page in the browser (the share sheet does
  this) or hand over a WalletConnect `wc:` link, as can a QR code on another
  device; either way the most it starts is a connection you must approve. A
  website can then ask to sign on Solana, Ethereum and Tezos. In the browser the
  origin comes from the platform rather than the page; over WalletConnect the
  website names itself, so the proposal shows WalletConnect's Verify result and
  an unmatched domain needs a press-and-hold. A connection is granted per origin
  (or per session) and per address. Both surfaces share one request lane, the
  same kill switches and step-up auth, and nothing is signed without your
  approval on a native review screen. Transactions are simulated and shown as
  decoded effects; if the simulation service is unreachable the review says so
  and the transaction can still be signed. Each signature is checked against
  the approved address before it is returned. WalletConnect exists only in a
  build with `WALLETCONNECT_PROJECT_ID` set. See
  [docs/security.md](docs/security.md#scope-first-party-flows-the-in-app-browser-and-walletconnect).
  Seed Vault adds no surface: it is a key store the app calls into, not a
  service the app offers, so a website reaches a Seed Vault wallet only through
  those two, and the OS then shows its own approval as well.

### What this repository does not prove

- **Builds are not reproducible.** You cannot take a distributed binary and
  verify it was compiled from this source. What this repository offers is
  auditable source and a definitive list of where builds are published —
  [SECURITY.md](SECURITY.md).
- **Solana signing is not instruction-checked.** Solana flows simulate before you
  confirm, but the result is advisory — a failed simulation does not stop the
  signature. For transactions the backend builds, the client decodes, refreshes
  the blockhash, signs and broadcasts without inspecting instruction contents, so
  a hostile backend could hand you a transaction you did not intend. What limits
  that is scope, not inspection.
  → `signSendConfirm` in [`lib/core/services/transaction_signing.dart`](lib/core/services/transaction_signing.dart)
- **The debugPrint guard is structural, not a content scan.** `debugPrint` is not
  stripped from release builds, so its output reaches the platform log (logcat,
  OSLog). `tool/lint/check_sensitive_debug_print.sh` bans the call outright inside
  the key- and auth-handling paths it lists, whatever the argument, and checks
  nothing outside them.

[docs/security.md](docs/security.md) enumerates the rest under "Known gaps". Found
a vulnerability? [SECURITY.md](SECURITY.md) — please do not open a public issue.

## Getting it running

Use the Flutter SDK version pinned in [CONTRIBUTING.md](CONTRIBUTING.md) —
`dart format` output differs between releases, so another version fails the
format check on files you never touched.

```bash
flutter pub get
./di.sh                  # code generation — NOT bare build_runner
cp .env.example .env     # then read it
touch .env.local
flutter test
```

**Always run `./di.sh`, never `dart run build_runner build` at the repository
root.** Nothing generated is checked in, so codegen is required. The root's mocks
reference types from `packages/`, which must build first; root-first makes
mockito fall back to `dynamic` and produces a wall of `invalid_override` errors
that look like your fault and are not.

`flutter analyze` and `flutter test` need no configuration. Three things stand
between that and a working app on a device:

1. **A backend — `API_BASE_URL`.** The one variable with no default of any kind.
   Unset, the app starts and local wallet operations work, but every API request
   is rejected with a `StateError` naming the variable. Point it at your own
   backend implementing `packages/mallow_api/openapi/openapi.yaml`, or use a
   `MALLOW_API_KEY` with the base URL issued alongside it.

2. **Firebase config.** The `google-services` Gradle plugin fails the Android
   build outright without its config file, and `Firebase.initializeApp()` throws
   on iOS. Both real files are gitignored; the shipped placeholders boot
   immediately and every value in them is obviously fake:

   ```bash
   cp test/e2e/google-services.placeholder.json      android/app/google-services.json
   cp test/e2e/GoogleService-Info.placeholder.plist  ios/Runner/GoogleService-Info.plist
   ```

3. **A Solana RPC endpoint with DAS** — the one that fails quietly.
   `RPC_PROXY_BASE_URL` defaults to Solana's public mainnet node, which has no
   DAS extensions. Without `searchAssets`, `getAsset` and `getAssetProof` the
   portfolio and every NFT list come back empty and nothing errors.

Then `./run.sh` (any `flutter run` flag passes through) — it is `flutter run`
with `.env` and `.env.local` compiled in, which a hand-written `flutter run` is
not. [docs/backend.md](docs/backend.md) has one section per external service and
exactly what breaks when it is missing.

## Build variables

Everything the app reads is a `--dart-define`, compiled in from `.env` at build
time. ⚠️ **A `--dart-define` is not a secret** — every value is recoverable from
the compiled binary.

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `API_BASE_URL` | The backend every API call resolves against. | **Required.** No default. | Your own backend implementing `packages/mallow_api/openapi/openapi.yaml` — or `https://api.mallow.art` if you hold a `MALLOW_API_KEY`. Set the two together. |
| `MALLOW_API_KEY` | Authenticates this build against a mallow-operated backend, sent as `x-api-key` to the `API_BASE_URL` hosts only. | Optional. The short path to a running app instead of writing a backend. | Ask in the mallow [Discord](https://mallow.art/discord) or email <support@mallow.art>. |
| `RPC_PROXY_BASE_URL` | Solana JSON-RPC **and DAS**. Drives the portfolio and every NFT list. | Optional, strongly recommended. The default has no DAS. | A DAS-capable provider: [Helius](https://www.helius.dev), [Triton](https://triton.one), [QuickNode](https://www.quicknode.com). |
| `GOOGLE_SERVER_CLIENT_ID`, `GOOGLE_IOS_CLIENT_ID`, `APPLE_SERVICES_ID` | Sign in with Google / Apple (the social vault). | Optional. Unset, that button reports it is not configured. | Your Google Cloud OAuth clients and Apple Services ID; your backend must accept their ID tokens. |
| `PASSKEY_RP_ID` | The domain social-vault passkeys belong to. | Optional. Unset, no passkeys are offered. | A domain you serve association files from. |
| `ENV` | Cluster, explorer, rewards-store path. | Optional. Defaults to `production`. | You choose. |

[docs/configuration.md](docs/configuration.md) documents all of them; [`.env.example`](.env.example) is the template.

## Forking

You are welcome to. Three things to know before you distribute a build:

- **You must rename and reskin.** The MIT license covers the code, not the mallow
  name, wordmark, logo, or the brand material in `assets/`. See
  [TRADEMARK.md](TRADEMARK.md).
- **A fork you distribute runs against your backend, not ours.** The contract is
  the vendored OpenAPI spec at `packages/mallow_api/openapi/openapi.yaml`,
  generated from private schemas — treat the vendored copy as the interface
  definition. See [docs/backend.md](docs/backend.md).
- **Store-delivery tooling is not in this repository.** Signing lanes and export
  options are internal; bring your own.

## Documentation

| | |
|---|---|
| [docs/configuration.md](docs/configuration.md) | Every build variable, what it controls, where a value comes from |
| [docs/backend.md](docs/backend.md) | What a fork must provide, service by service |
| [docs/security.md](docs/security.md) | Storage, signing gates, derivation paths, known gaps |
| [docs/architecture.md](docs/architecture.md) | Structure, naming, state management, the standalone packages |
| [docs/api.md](docs/api.md) | Endpoints and the `/v1` vs `/v2` split |
| [docs/workflow.md](docs/workflow.md) | CLI commands and testing |
| [docs/keystone.md](docs/keystone.md) | Keystone hardware wallets: connecting, QR signing, what is stored |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Build steps, CI gates, DCO sign-off |
| [SECURITY.md](SECURITY.md) | Disclosure policy and how to verify a genuine build |
| [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) | Bundled third-party material and its licences |

## License

MIT — see [LICENSE](LICENSE). The name, logo, and brand assets are excluded; see
[TRADEMARK.md](TRADEMARK.md).
