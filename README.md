# mallow wallet

A security-first, self-custody mobile wallet for Solana, Ethereum, and Tezos.
Built with Flutter.

This is the source for the mallow wallet app. It is here so you can check what
it does with your keys rather than take our word for it.

The App Store and Google Play listings are not live yet. Until they are, the
only official builds are **TestFlight** and **Google Play closed testing**, both
by invitation. Ask for one at <https://wallet-beta.mallow.art>, and see
[SECURITY.md](SECURITY.md) for how to tell a genuine build from a fork.

---

## The security model

Everything below is verifiable in this repository. The file references are the
starting points.

**Keys you create or import never leave the device.** Mnemonics and imported
private keys do *not* go through `flutter_secure_storage`. They go to
`MnemonicVault`, a native store written for this app, with one implementation
per platform:

- **iOS** — a Keychain item under the service `art.mallow.vault`, marked
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: unreadable while the device is
  locked, never synced to iCloud, never in a device backup.
- **Android** — a per-secret **AES-256-GCM key generated inside AndroidKeystore**
  and non-exportable, hardware-backed wherever a TEE or StrongBox exists. Only
  the ciphertext and its IV are written to disk (a `MODE_PRIVATE`
  SharedPreferences file, `mallow_vault_prefs`); the key that decrypts them
  never leaves the Keystore and dies with the app's uninstall.

Neither platform prompts on a vault read — the app's own lock screen is the
user-facing gate, not an OS prompt. `flutter_secure_storage` is still used, for
the smaller items: the PIN hash, session tokens, and the database encryption
key. For these wallets there is no escrow, no server-side backup, and no code
path that transmits key material. See
[`lib/core/security/`](lib/core/security/) — `secure_storage.dart` and
`mnemonic_vault.dart`, plus `ios/Runner/MnemonicVaultChannel.swift` and
`android/app/src/main/kotlin/com/mallow/wallet/android/MnemonicVaultChannel.kt`
— and [docs/security.md](docs/security.md).

**Wallets created by social sign-in are different, and you should know how.**
Signing in with Google or Apple derives its keys through Web3Auth (MetaMask
Embedded Wallets): the key is reconstructed from an MPC network inside that
SDK, deterministically from your social identity, and this build enables no
additional user-held factor. It is stored and used locally afterwards, and it
never travels on the OAuth redirect — but it is *reproducible off this device*
by whoever controls the identity, which is what makes "restore by logging in
again" work. That is a real recovery capability and, equally, a real trust
dependency on your social account and on Web3Auth. A self-custody purist
should create or import a wallet instead. One secp256k1 key backs both the
Ethereum and Tezos addresses of a social wallet, so the two share a fate. See
`lib/core/services/social_auth_service.dart` and
[docs/security.md](docs/security.md).

**Signing is gated by app lock, and by a value threshold you control.** The
floor is the lock screen — biometric-first with a PIN fallback, on cold start
and after 60 seconds in the background. On top of that, `TransactionAuthGate`
can demand a second factor per transaction: it is **opt-in and off by
default**, and once enabled it prompts when a transaction's USD outflow exceeds
a threshold you set (default $100), or whenever that value cannot be computed.
So a default install does not prompt per signature — the honest summary is that
an unlocked device can sign, and the controls that change this are in
Settings → Security & Privacy. Arbitrary message signing is not value-gated at
all. [docs/security.md](docs/security.md) has the full table.

**Nothing sensitive is logged.** `debugPrint` is not stripped from release
builds — its output still reaches the platform log (logcat on Android, OSLog on
iOS), where anything printed is readable off the device. The crash reporter is
explicitly configured *not* to turn those calls into telemetry
(`enablePrintBreadcrumbs = false` in `lib/core/services/sentry_service.dart`),
so they stay local rather than being uploaded.
`tool/lint/check_sensitive_debug_print.sh` runs in CI on top of that. Be clear
about what it is: a **structural** ban, not a content scan. It fails the build
on *any* bare `debugPrint` inside the key- and auth-handling paths it lists —
it does not inspect what is being printed, and it says nothing about the rest of
`lib/`. The reasoning is that those paths have no line that is worth logging to
a device-readable log, so banning the call is cheaper and harder to fool than
guessing at its arguments. Everywhere else, that judgement is yours and the
reviewer's.

**EVM transfers are simulated, and the simulation is a hard gate.** They run
through `eth_simulateV1`, and signing is blocked unless the only asset movement
is the one you asked for. It fails **closed**: if the simulation endpoint is
unreachable, the transfer errors rather than proceeding unchecked. See
`ethereumSimulationUrl` in
[`lib/core/config/environment.dart`](lib/core/config/environment.dart) and
`_assertSimulation` in
[`lib/features/send/services/ethereum_transfer_service.dart`](lib/features/send/services/ethereum_transfer_service.dart).

**Solana has no equivalent gate, and that is the honest boundary of this
model.** Solana flows do simulate before you confirm, but the result is
*advisory* — it is shown to you, and a failed simulation does not stop the
signature. For the transactions the backend builds (mint, listing, market, swap,
raffle) the client checks no instruction contents at all: it decodes, refreshes
the blockhash, signs, and broadcasts. See `signSendConfirm` in
[`lib/core/services/transaction_signing.dart`](lib/core/services/transaction_signing.dart).

**What holds that up is scope, not inspection.** The wallet signs only what its
own flows produce — there is no WalletConnect, no Mobile Wallet Adapter, no
in-app browser and no deep-link signing intent, so no third-party site or app
can put a transaction in front of you. The trust that remains is trust in the
backend: it cannot produce a signature or move funds by itself, but on Solana a
hostile or compromised one could hand you a transaction you did not intend and
the client would not catch it. Adding any third-party signing surface would
make decoded-instruction confirmation a prerequisite, not a nice-to-have.
[docs/security.md](docs/security.md) states this scope and what it defers.

### What this repository does not prove

**Builds are not reproducible.** You cannot take a distributed binary and verify
it was compiled from this source. We would rather say so than imply a
guarantee we do not have. What we do offer is auditable source, and a definitive
list of where we publish builds — see [SECURITY.md](SECURITY.md).

Found a vulnerability? [SECURITY.md](SECURITY.md) — please do not open a public
issue.

---

## Supported platforms

**iOS and Android.** There is no web or desktop build.

---

## Getting it running

You need the Flutter SDK at the version in [CONTRIBUTING.md](CONTRIBUTING.md).
`dart format` output differs between SDK releases, so a different version will
fail the format check on files you never touched.

```bash
flutter pub get
./di.sh                  # code generation — NOT bare build_runner, see below
cp .env.example .env     # then read it
touch .env.local
flutter test
```

**Always run `./di.sh`, never `dart run build_runner build` at the repository
root.** No generated file is checked in, so codegen is required, not optional.
The root's generated mocks reference types from the packages under `packages/`,
so those must build first — build the root first and mockito silently falls back
to `dynamic`, producing a wall of `invalid_override` errors that look like your
fault and are not.

`flutter analyze` and `flutter test` need no configuration at all. Nothing reads
config from disk at runtime.

### To actually launch the app

Three things stand between `flutter test` passing and a useful app on a device.
They fail in different ways, which is worth knowing before you start debugging
the wrong one.

**1. A backend — `API_BASE_URL`. The hard requirement.** It is the one variable
with **no default of any kind**, because a backend host compiled into a binary
outlives the build it was right for. Unset, the app still starts and local
wallet operations still work — create a wallet, import one, reveal a recovery
phrase — but every request to the API is rejected at send time with a
`StateError` naming the variable (`Config.missingApiBaseUrl`, raised by
`ApiBaseUrlInterceptor`). So the failure is loud and it names itself; it is not
a blank screen.

There are two ways to satisfy it.

*Point it at your own backend.* The contract is the vendored OpenAPI spec at
`packages/mallow_api/openapi/openapi.yaml`. That is the honest, long path.

*Or use a mallow-issued API key.* If you hold one, you get a running app against
the real backend without writing a line of server code. The key and the base URL
are a **pair** — neither does anything alone, and no API host is compiled into
this source, so set both:

```bash
# .env
API_BASE_URL=https://api.mallow.art
MALLOW_API_KEY=<the key issued to you>
```

The key is sent as the `x-api-key` header — the `ApiKeyAuth` scheme the vendored
spec already declares — and **only** to the `API_BASE_URL` / `API_V2_BASE_URL`
hosts. No amount of `FIRST_PARTY_HOSTS` configuration can widen that, for the
same reason it cannot widen where the session cookie goes. Request a key in the
mallow Discord (<https://mallow.art/discord>) or by email to
<support@mallow.art>.

Treat the key as spendable, not secret: a `--dart-define` value is recoverable
from a shipped binary, so it is a rate-limiting and attribution mechanism, not a
credential you can hide. Keep it out of commits and screenshots anyway.

**2. Firebase config. The one that stops the build.** The `google-services`
Gradle plugin fails the Android build outright when its config file is missing,
and `Firebase.initializeApp()` throws on iOS. Both real files are gitignored. To
get booting immediately, use the shipped placeholders — every value in them is
obviously fake and grants nothing:

```bash
cp test/e2e/google-services.placeholder.json      android/app/google-services.json
cp test/e2e/GoogleService-Info.placeholder.plist  ios/Runner/GoogleService-Info.plist
```

With the placeholders, push notifications and crash reporting are inert and
everything else works. For real Firebase behaviour, create a project at the
[Firebase Console](https://console.firebase.google.com/) and download the
genuine files to the same two paths.

**3. A Solana RPC endpoint with DAS. The one that fails quietly.** Unlike the
first two, this one has a default and the app starts without it — which is
exactly the problem.

`RPC_PROXY_BASE_URL` defaults to Solana's public mainnet node. That default
keeps an unconfigured build *consistent* with everything else here; it is not
one that makes the app work. The node is rate-limited and, critically, **does
not implement the DAS extensions** — and neither does any other stock Solana
node.

Without `searchAssets`, `getAsset`, and `getAssetProof`, the portfolio, every
NFT list, and every compressed-NFT proof come back empty. Nothing errors: an
empty list is a well-formed answer, so the app looks broken instead of telling
you why. Sign up with a DAS-capable provider — [Helius](https://www.helius.dev),
[Triton](https://triton.one), and [QuickNode](https://www.quicknode.com) all
offer it — and put its endpoint in `.env`.

Then:

```bash
./run.sh                    # default device
./run.sh -d <device_id>     # any flutter run flag is passed through
```

`./run.sh` is `flutter run` with `.env` and `.env.local` compiled in. Use it
rather than a hand-written `flutter run`, which will compile in nothing.

### Build variables

Everything the app reads is a `--dart-define`, compiled in from `.env` at build
time. `.env.example` is the copyable template with the per-variable detail; the
table below is the map — what each one controls, whether you need it, and where
a value comes from.

Nothing here is read from disk at runtime, and `flutter analyze` / `flutter
test` need none of it.

⚠️ **A `--dart-define` is not a secret.** Every value below is recoverable from
the compiled binary. Nothing that must stay secret belongs in this file — that
is what the RPC proxy and the backend are for.

#### Start here

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `API_BASE_URL` | The backend every API call resolves against — `/v0` (session login), `/v1`, and the handful of unversioned routes; `/v2` derives from it unless set. | **Required.** No default. Unset, local wallet operations work and every API call is rejected naming this variable. | Your own backend implementing `packages/mallow_api/openapi/openapi.yaml` — or `https://api.mallow.art` if you hold a `MALLOW_API_KEY`. Set the two together. |
| `MALLOW_API_KEY` | Authenticates this build against a mallow-operated backend, sent as `x-api-key` to the `API_BASE_URL` hosts only. | Optional — the short path to a running app instead of writing a backend. Useless without `API_BASE_URL`. | Ask in the mallow Discord — <https://mallow.art/discord> — or email <support@mallow.art>. |
| `RPC_PROXY_BASE_URL` | Solana JSON-RPC **and DAS**. Drives the portfolio, every NFT list, and every compressed-NFT proof. | Optional but you almost certainly want it. Defaults to Solana's public mainnet node, which has no DAS — lists come back empty with no error. | A DAS-capable provider: [Helius](https://www.helius.dev), [Triton](https://triton.one), [QuickNode](https://www.quicknode.com) — or your own proxy in front of one. |
| `WEB3AUTH_CLIENT_ID` | Sign in with Google / Apple. | Optional. Unset, the first social login attempt throws naming the variable; creating and importing wallets is unaffected. | A project in the MetaMask Embedded Wallets dashboard: <https://dashboard.web3auth.io>. One project per environment — `ENV` picks the network, and the network is part of the key derivation. |
| `ENV` | `development` \| `staging` \| `production`. Selects the Solana cluster, the explorer cluster parameter, the Web3Auth network, and the rewards-store path. | Optional. **Defaults to `production`.** | You choose. 🛑 The Web3Auth network is part of the social key derivation — the same social account yields a *different address* on `sapphire_devnet` than on `sapphire_mainnet`, so this must never change for a deployment once it is live. |

#### Chains

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `SOLANA_MAINNET_RPC_URL` | Mainnet-pinned Solana RPC, used whatever `ENV` says: `.sol` name resolution and native staking, both mainnet-only. | Optional. Defaults to Solana's public mainnet node, which answers these correctly and is only rate-limited. No DAS needed here. | Any Solana mainnet RPC. Point it at the same provider as above to get the throughput back. |
| `ETH_RPC_URL` | Ethereum mainnet JSON-RPC for money movement — balance, nonce, `estimateGas`, broadcast, receipts. | Optional. Defaults to a public keyless node. | Any Ethereum mainnet RPC: Alchemy, Infura, publicnode, your own. |
| `EVM_SIMULATION_URL` | The EVM transfer **safety gate**: an `eth_simulateV1` call that blocks signing if anything but the intended asset would move. | **Required for EVM transfers.** No default, and it fails **closed** — unset, transfers error rather than proceed unsimulated. | Any endpoint implementing `eth_simulateV1` (Alchemy's node API does; a plain node may not). |
| `EVM_GAS_API_URL` | The Edit Gas Fee sheet's Low / Market / High tiers — one `GET <base>/suggestedGasFees` returns ready-made tiers with wait-time estimates. | Optional. No default. Unset, the Edit affordance is hidden and the send is priced from the node's own fee data. | An Infura account with the Gas API enabled (`gas.api.infura.io`), or any endpoint serving the same route. |
| `TEZOS_RPC_URL` | Tezos node RPC for the send flow. | Optional. Defaults to TzKT's public mainnet node. | Any Tezos node that permits the `run_operation` simulation POST — some public nodes return 401 on it, which surfaces as a failure at the confirm step. |

#### Media, CDN and gateways

Each of these fronts a host that serves **your** bandwidth. Every one defaults
to the public upstream it would proxy, so an unconfigured build works — just
without your cache in front of it.

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `IMAGE_CDN_BASE_URL` | An image-resizing CDN serving `/{size}x{size}/{fit}/{encoded-source}` and `/original/{encoded-source}`. | Optional. Unset, images load from their own origin at full size. Nothing breaks — the in-memory decode is still capped — but every thumbnail pulls the whole asset. | You host it, or run a resizer that implements those two routes (Cloudflare Images, imgproxy, thumbor). |
| `ASSET_CDN_BASE_URL` | Rewards-store metadata under `/store`, plus the `/status.json` and `/notification-v2.json` operator feeds behind the maintenance and broadcast banners. | Optional. Unset, the store has no metadata and the banners never show. Both already fail safe. | Any static host you control. |
| `IPFS_UPLOAD_URL` | Where the mint flow uploads media and metadata JSON. | Optional, but minting needs it. **No default, deliberately** — a compiled-in pinner would have every unconfigured build writing into somebody else's storage. Unset, the mint flow reports the missing variable. | Your own pinning service. It carries no key of its own; it authenticates with the `CLIENT_ID_*` header, so list its host in `FIRST_PARTY_HOSTS`. |
| `IPFS_GATEWAY_URL` | An **extra** gateway raced in the video and download fallback ladders. Not the primary resolver — `ipfs://` always resolves through `ipfs.io` first, because that string is the image CDN's cache key. | Optional. Defaults to `ipfs.io`, which makes the extra rung a no-op. | A gateway that reliably holds your pinned CIDs. Leave it unset to keep the app off your own gateway entirely. |
| `ARWEAVE_GATEWAY_URL` | The mirror tried when the asset's own Arweave gateway refuses the fetch. | Optional. Defaults to `arweave.net` itself, making the mirror step a no-op rather than a second host to trust. | Any Arweave gateway. |
| `AVATAR_SERVICE_URL` | A DiceBear-compatible identicon service (`/10.x/identicon/svg?seed=…`) for generated avatars. | Optional. Defaults to DiceBear's public API. | Self-host DiceBear, or proxy it. |
| `CANONICAL_ASSET_URLS` | Emit `ipfs://` / `ar://` inside the resize path instead of the gateway form, so the CDN edge key does not fragment per gateway. | Optional. Off unless set to `true`/`1`. | A choice, not a credential. Set it if your resizer understands those schemes. |

#### Token data, prices, swaps

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `JUPITER_BASE_URL` | Swap quotes and execution, token metadata, token search. Sub-paths match Jupiter's own, so a proxy only has to forward. | Optional. Defaults to Jupiter's public API. | Jupiter: <https://dev.jup.ag>. Set this to a proxy of yours that attaches a plan key. |
| `COINGECKO_BASE_URL` | Token prices and OHLC charts, under `/api/v3`. | Optional. Defaults to the public API — rate-limited, no plan. | A plan key at <https://www.coingecko.com/en/api/pricing>, fronted by a proxy that attaches it. |
| `QUOTE_API_BASE` | Default base URL of `JupiterAggregatorClient` (Jupiter Ultra) **when it is constructed with no `baseUrl`**. | Optional and **inert in this app** — `di_module.dart` always passes an explicit base derived from `JUPITER_BASE_URL`. It exists for `packages/jupiter_aggregator` used standalone. | Jupiter, as above. Prefer `JUPITER_BASE_URL`. |
| `CLASSIC_SWAP_API_BASE` | The same, for `JupiterSwapInstructionsClient` (Jupiter classic swap). | Optional and inert in this app, for the same reason. | Jupiter, as above. Prefer `JUPITER_BASE_URL`. |

#### Host trust and build identification

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `API_V2_BASE_URL` | Base URL of the `/v2` surface, **including** the `/v2` path segment. It is a separate service from `/v1`. | Optional. Derived from `API_BASE_URL` when unset: an `http://` base gets its port swapped to `8090`, an `https://` base reuses the host. | Set it explicitly only if your deployment matches neither shape. |
| `FIRST_PARTY_HOSTS` | Extra hosts that receive the client-id header and `App-Version`. Comma-separated, exact host match, no wildcards, no ports. | Optional. Additive only — the API hosts are first-party by construction and cannot be removed here. | Hosts *you* operate: typically whatever `RPC_PROXY_BASE_URL` and `IPFS_UPLOAD_URL` point at. 🛑 It cannot widen where the session cookie or `MALLOW_API_KEY` go; those are pinned to the API hosts. |
| `CLIENT_ID_HEADER`, `CLIENT_ID_IOS`, `CLIENT_ID_ANDROID` | A header naming which build is calling, sent to `FIRST_PARTY_HOSTS`. Blank means the header is omitted entirely, not sent empty. | Optional. | **There is no value for you to obtain.** mallow's backend does not issue these to third parties — `MALLOW_API_KEY` is the credential a reader is given instead. If you run your own backend, invent your own header name and values. |

#### Telemetry

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `SENTRY_DSN` | Crash and error reporting. | Optional. Unset, nothing is sent. | <https://sentry.io>. |
| `ANALYTICS_ENABLED` | Build-level analytics kill switch. Events go to the backend, which holds the provider credential — there is no client-side analytics token. | Optional. **On by default**; set `false` to hard-disable a build. The per-user Settings opt-out is a separate gate on top. | A choice, not a credential. |

#### Not for forks, and build-only knobs

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `JUPITER_REFERRAL_ACCOUNT` | The referral account collecting the swap fee. | Optional. Unset, swaps run with no integrator fee. | **Not something you obtain from us** — it is mallow's own account. Create your own at <https://referral.jup.ag> if you want to collect a fee, or leave it unset. |
| `CAST_RECEIVER_APP_ID` | The Chromecast receiver the app launches on a TV. | Optional. Defaults to mallow's own registered receiver, so casting works unconfigured. | **Register your own** at the [Google Cast Developer Console](https://cast.google.com/publish) before distributing a fork — otherwise your users cast into mallow's receiver, on mallow's bandwidth and branding. Not a secret; a sender broadcasts it on the local network. |
| `SHOW_UNRELEASED` | Reveals surfaces hidden from store builds. | Optional. Defaults to `true` in debug builds and `false` in release. | A build-time choice. |
| `E2E_DISABLE_GL` | Swaps the onboarding 3D carousel for a non-GL fallback. | Optional, off by default. Set only by automated device tests — `flutter_angle` hard-crashes on headless software-GL emulators. | A build-time choice. Do not set it in a shipping build. |

[docs/backend.md](docs/backend.md) goes further: one row per external service,
what it does, and exactly what breaks when it is missing. Read it before
concluding something is broken.

---

## Forking this

You are welcome to. A `MALLOW_API_KEY` exists so you can *evaluate* the app
against our backend without writing one first — but a fork you **distribute**
runs against **your** backend, not ours.

The contract your backend has to implement is the vendored OpenAPI spec at
`packages/mallow_api/openapi/openapi.yaml`. It is generated from private
schemas, so you cannot regenerate it here — treat the vendored copy as the
interface definition.

Two things you should know before you distribute a build:

- **You must rename and reskin.** The MIT license covers the code. It does not
  cover the mallow name, wordmark, logo, or the brand material in `assets/`.
  [TRADEMARK.md](TRADEMARK.md) explains what to change and why a wallet in
  particular draws that line.
- **Store-delivery tooling is not in this repository.** Signing lanes and export
  options are internal; bring your own.

---

## Reusable packages

The Dart packages under `packages/` are written to stand alone and may be useful
outside this app:

| Package | What it does |
|---|---|
| `ledger_solana` | Solana app bindings for Ledger hardware wallets |
| `ledger_ethereum` | Ethereum app bindings for Ledger hardware wallets |
| `ledger_tezos` | Tezos app bindings for Ledger hardware wallets |
| `jupiter_aggregator` | Typed client for Jupiter's Ultra, classic swap, and price APIs |

They are path dependencies today rather than published packages. If you want one
on pub.dev, open an issue — it is easier to justify with a user asking.

---

## Derivation paths

Paths are **per-account-index**. `$index` is the account index shown in the
import picker. Canonical source:
[`lib/core/crypto/derivation.dart`](lib/core/crypto/derivation.dart).

| Chain | Path | Curve |
|---|---|---|
| Solana (standard) | `m/44'/501'/$index'/0'` | Ed25519 — matches Phantom and Solflare |
| Solana (legacy) | `m/44'/501'/$index'` | Ed25519 — import only |
| Solana (root) | `m/44'/501'` | Ed25519 — index-less, so index 0 only |
| Ethereum / EVM | `m/44'/60'/0'/0/$index` | secp256k1 — index is the **last** component |
| Tezos (tz1) | `m/44'/1729'/$index'/0'` | SLIP-0010 Ed25519 |

🛑 **The Solana scheme is part of a wallet's identity.** Derive with the wrong
one and you produce a *valid signature from a different address* — it does not
throw and it does not look broken. The scheme must round-trip through the stored
wallet record.

---

## Documentation

| | |
|---|---|
| [docs/backend.md](docs/backend.md) | What a fork must provide, service by service |
| [docs/security.md](docs/security.md) | Biometric gates, signing, storage |
| [docs/architecture.md](docs/architecture.md) | Structure, naming, state management |
| [docs/api.md](docs/api.md) | Endpoints and the `/v1` vs `/v2` split |
| [docs/workflow.md](docs/workflow.md) | CLI commands and testing |
| [docs/artwork_state.md](docs/artwork_state.md) | How an artwork's action state is derived |
| [docs/keystone.md](docs/keystone.md) | Keystone hardware-wallet QR support — a design note for work not yet built |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Build steps, CI gates, DCO sign-off |
| [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) | Bundled third-party material and its licences |

---

## License

MIT — see [LICENSE](LICENSE). The name, logo, and brand assets are excluded; see
[TRADEMARK.md](TRADEMARK.md).
