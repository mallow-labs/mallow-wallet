# Build variables

Everything the app reads is a `--dart-define`, compiled in from `.env` at build
time. [`.env.example`](../.env.example) is the copyable template with the
per-variable detail; the tables below are the map — what each one controls,
whether you need it, and where a value comes from.

Nothing here is read from disk at runtime, and `flutter analyze` / `flutter test`
need none of it.

⚠️ **A `--dart-define` is not a secret.** Every value below is recoverable from
the compiled binary. Nothing that must stay secret belongs in this file — that is
what the RPC proxy and the backend are for.

[docs/backend.md](backend.md) goes further: one row per external service, what it
does, and exactly what breaks when it is missing. Read it before concluding
something is broken.

## Start here

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `API_BASE_URL` | The backend every API call resolves against — `/v0` (session login), `/v1`, and the handful of unversioned routes; `/v2` derives from it unless set. | **Required.** No default. Unset, local wallet operations work and every API call is rejected naming this variable. | Your own backend implementing `packages/mallow_api/openapi/openapi.yaml` — or, if you hold a `MALLOW_API_KEY`, the base URL issued with your key. Set the two together. |
| `MALLOW_API_KEY` | Authenticates this build against a mallow-operated backend, sent as `x-api-key` to the `API_BASE_URL` hosts only. | Optional — the short path to a running app instead of writing a backend. Useless without `API_BASE_URL`. | Ask in the mallow Discord — <https://mallow.art/discord> — or email <support@mallow.art>. |
| `RPC_PROXY_BASE_URL` | Solana JSON-RPC **and DAS**. Drives the portfolio, every NFT list, and every compressed-NFT proof. | Optional. Strongly recommended — the default is Solana's public mainnet node, which has no DAS, so lists come back empty with no error. | A DAS-capable provider: [Helius](https://www.helius.dev), [Triton](https://triton.one), [QuickNode](https://www.quicknode.com) — or your own proxy in front of one. |
| `WEB3AUTH_CLIENT_ID` | Sign in with Google / Apple. | Optional. Unset, the first social login attempt throws naming the variable; creating and importing wallets is unaffected. | A project in the MetaMask Embedded Wallets dashboard: <https://dashboard.web3auth.io>. One project per environment — `ENV` picks the network, and the network is part of the key derivation. |
| `ENV` | `development` \| `staging` \| `production`. Selects the Solana cluster, the explorer cluster parameter, the Web3Auth network, and the rewards-store path. | Optional. **Defaults to `production`.** | You choose. 🛑 The Web3Auth network is part of the social key derivation — the same social account yields a *different address* on `sapphire_devnet` than on `sapphire_mainnet`, so this must never change for a deployment once it is live. |

Treat `MALLOW_API_KEY` as spendable, not secret: a `--dart-define` value is
recoverable from a shipped binary, so it is a rate-limiting and attribution
mechanism, not a credential you can hide. Keep it out of commits and screenshots
anyway.

→ [backend.md → The contract](backend.md#the-contract) and
[→ Authentication](backend.md#authentication) for what a backend must implement.
[→ Running against nothing](backend.md#running-against-nothing) for what an
unconfigured build can still do.

## Chains

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `SOLANA_MAINNET_RPC_URL` | Mainnet-pinned Solana RPC, used whatever `ENV` says: `.sol` name resolution and native staking, both mainnet-only. | Optional. Defaults to Solana's public mainnet node, which answers these correctly and is only rate-limited. No DAS needed here. | Any Solana mainnet RPC. Point it at the same provider as above to get the throughput back. |
| `ETH_RPC_URL` | Ethereum mainnet JSON-RPC for money movement — balance, nonce, `estimateGas`, broadcast, receipts. | Optional. Defaults to a public keyless node. | Any Ethereum mainnet RPC: Alchemy, Infura, publicnode, your own. |
| `EVM_SIMULATION_URL` | The EVM transfer **safety gate**: an `eth_simulateV1` call that blocks signing if anything but the intended asset would move. | **Required for EVM transfers.** No default, and it fails **closed** — unset, transfers error rather than proceed unsimulated. | Any endpoint implementing `eth_simulateV1` (Alchemy's node API does; a plain node may not). |
| `EVM_GAS_API_URL` | The Edit Gas Fee sheet's Low / Market / High tiers — one `GET <base>/suggestedGasFees` returns ready-made tiers with wait-time estimates. | Optional. No default. Unset, the Edit affordance is hidden and the send is priced from the node's own fee data. | An Infura account with the Gas API enabled, or any endpoint serving the same route. |
| `TEZOS_RPC_URL` | Tezos node RPC for the send flow. | Optional. Defaults to TzKT's public mainnet node. | Any Tezos node that permits the `run_operation` simulation POST — some public nodes return 401 on it, which surfaces as a failure at the confirm step. |

→ [backend.md → The Solana RPC requirement, in detail](backend.md#the-solana-rpc-requirement-in-detail)
and [→ The EVM simulation gate](backend.md#the-evm-simulation-gate).

## Media, CDN and gateways

Each of these fronts a host that serves **your** bandwidth. Every one defaults to
the public upstream it would proxy, so an unconfigured build works — just without
your cache in front of it.

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `IMAGE_CDN_BASE_URL` | An image-resizing CDN serving `/{size}x{size}/{fit}/{encoded-source}` and `/original/{encoded-source}`. | Optional. Unset, images load from their own origin at full size. Nothing breaks — the in-memory decode is still capped — but every thumbnail pulls the whole asset. | You host it, or run a resizer that implements those two routes (Cloudflare Images, imgproxy, thumbor). |
| `ASSET_CDN_BASE_URL` | Rewards-store metadata under `/store`, plus the `/status.json` and `/notification-v2.json` operator feeds behind the maintenance and broadcast banners. | Optional. Unset, the store has no metadata and the banners never show. Both already fail safe. | Any static host you control. |
| `IPFS_UPLOAD_URL` | Where the mint flow uploads media and metadata JSON. | Optional, but minting needs it. **No default, deliberately** — a compiled-in pinner would have every unconfigured build writing into somebody else's storage. Unset, the mint flow reports the missing variable. | Your own pinning service. It carries no key of its own; it authenticates with the `CLIENT_ID_*` header, so list its host in `FIRST_PARTY_HOSTS`. |
| `IPFS_GATEWAY_URL` | The gateway direct IPFS fetches go to, and the **first** rung of the video and download fallback ladders (then `ipfs.io`, then `dweb.link`). Not a cache key: the resize and `/original/` paths embed the canonical `ipfs://<cid>` form, which names the bytes and no host. | Optional. Defaults to `ipfs.io`, which collapses the first two rungs into one. | A gateway that reliably holds your pinned CIDs. The production build points this at a first-party **tiered** gateway — its own pins answered first, a full IPFS node behind the same host as the fallback — so a CID this deployment never pinned still resolves instead of 404ing. That value lives in the private build `.env`, not here. |
| `ARWEAVE_GATEWAY_URL` | The mirror tried when the asset's own Arweave gateway refuses the fetch. | Optional. Defaults to `arweave.net` itself, making the mirror step a no-op rather than a second host to trust. | Any Arweave gateway. |
| `AVATAR_SERVICE_URL` | A DiceBear-compatible identicon service (`/10.x/identicon/svg?seed=…`) for generated avatars. | Optional. Defaults to DiceBear's public API. | Self-host DiceBear, or proxy it. |

→ [backend.md → Media, CDN and gateways](backend.md#media-cdn-and-gateways).

## Token data, prices, swaps

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `JUPITER_BASE_URL` | Swap quotes and execution, token metadata, token search. Sub-paths match Jupiter's own, so a proxy only has to forward. | Optional. Defaults to Jupiter's public API. | Jupiter: <https://dev.jup.ag>. Set this to a proxy of yours that attaches a plan key. |
| `COINGECKO_BASE_URL` | Token prices and OHLC charts, under `/api/v3`. | Optional. Defaults to the public API — rate-limited, no plan. | A plan key at <https://www.coingecko.com/en/api/pricing>, fronted by a proxy that attaches it. |
| `QUOTE_API_BASE` | Default base URL of `JupiterAggregatorClient` (Jupiter Ultra) **when it is constructed with no `baseUrl`**. | Optional and **inert in this app** — `di_module.dart` always passes an explicit base derived from `JUPITER_BASE_URL`. It exists for `packages/jupiter_aggregator` used standalone. | Jupiter, as above. Prefer `JUPITER_BASE_URL`. |
| `CLASSIC_SWAP_API_BASE` | The same, for `JupiterSwapInstructionsClient` (Jupiter classic swap). | Optional and inert in this app, for the same reason. | Jupiter, as above. Prefer `JUPITER_BASE_URL`. |

→ [backend.md → Dependencies](backend.md#dependencies).

## Host trust and build identification

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `API_V2_BASE_URL` | Base URL of the `/v2` surface, **including** the `/v2` path segment. It is a separate service from `/v1`. | Optional. Derived from `API_BASE_URL` when unset: an `http://` base gets its port swapped to `8090`, an `https://` base reuses the host. | Set it explicitly only if your deployment matches neither shape. |
| `FIRST_PARTY_HOSTS` | Extra hosts that receive the client-id header and `App-Version`. Comma-separated, exact host match, no wildcards, no ports. | Optional. Additive only — the API hosts are first-party by construction and cannot be removed here. | Hosts *you* operate: typically whatever `RPC_PROXY_BASE_URL` and `IPFS_UPLOAD_URL` point at. 🛑 It cannot widen where the session cookie or `MALLOW_API_KEY` go; those are pinned to the API hosts. |
| `CLIENT_ID_HEADER`, `CLIENT_ID_IOS`, `CLIENT_ID_ANDROID` | A header naming which build is calling, sent to `FIRST_PARTY_HOSTS`. Blank means the header is omitted entirely, not sent empty. | Optional. | Not issued to third parties — `MALLOW_API_KEY` is the credential a reader is given instead. If you run your own backend, invent your own header name and values. |

→ [backend.md → Which hosts receive your credentials](backend.md#which-hosts-receive-your-credentials).

## Telemetry

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `SENTRY_DSN` | Crash and error reporting. | Optional. Unset, nothing is sent. | <https://sentry.io>. |
| `ANALYTICS_ENABLED` | Build-level analytics kill switch. Events go to the backend, which holds the provider credential — there is no client-side analytics token. | Optional. **On by default**; set `false` to hard-disable a build. The per-user Settings opt-out is a separate gate on top. | A choice, not a credential. |

## Not for forks, and build-only knobs

| Variable | Controls | Required? | Where a value comes from |
|---|---|---|---|
| `JUPITER_REFERRAL_ACCOUNT` | The referral account collecting the swap fee. | Optional. Unset, swaps run with no integrator fee. | mallow's own account. Create your own at <https://referral.jup.ag> if you want to collect a fee, or leave it unset. |
| `CAST_RECEIVER_APP_ID` | The Chromecast receiver the app launches on a TV. | Optional. Defaults to mallow's own registered receiver, so casting works unconfigured. | **Register your own** at the [Google Cast Developer Console](https://cast.google.com/publish) before distributing a fork — otherwise your users cast into mallow's receiver, on mallow's bandwidth and branding. Not a secret; a sender broadcasts it on the local network. |
| `SHOW_UNRELEASED` | Reveals surfaces hidden from store builds. | Optional. Defaults to `true` in debug builds and `false` in release. | A build-time choice. |
| `SHOW_NFT_COMMERCE` | In-app NFT commerce — buy, bid, offer, sell/list, mint, raffle entry. Set `false` and the marketplace is view-only; wallet functions and every cancel/settle/claim path stay. | Optional. Defaults to `true`; the iOS App Store build sets `false` (App Store Guideline 3.1.1). | A build-time choice. |
| `SHOW_SWAP` | Token swap, and liquid staking — the same aggregator swap in both directions. Set `false` and the swap sheet and its three entry points go, and the stake sheet becomes native-only. Sends, transfers, burns, native staking and the marketplace are untouched. | Optional. Defaults to `true`; the iOS App Store build sets `false` (App Store Guideline 3.1.5(ii): an exchange must be offered by the exchange itself). | A build-time choice. |
| `E2E_DISABLE_GL` | Swaps the onboarding 3D carousel for a non-GL fallback. | Optional, off by default. Set only by automated device tests — `flutter_angle` hard-crashes on headless software-GL emulators. | A build-time choice. Do not set it in a shipping build. |

The last four are the ones `tool/lint/check_env_documented.sh` exempts from
`.env.example`. They are set by a developer, by the test harness, or by one
platform's release lane — never by a deployment — so an `.env.example` entry
would tell a fork to configure something that is none of their business.
