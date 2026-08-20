# What a fork must provide

This app is a client. It talks to a backend and to several external services,
and none of them are in this repository.

This page is written for someone who cloned this and wants it to work. It is a
setup guide, not an infrastructure map: for each dependency it says what the
thing does, which variable points at it, and what visibly breaks when it is
missing.

Everything here is set in `.env` and compiled in at build time with
`--dart-define-from-file`. Start from `.env.example`, which carries the same
list with blank values.

---

## The contract

The interface a backend must implement is the vendored OpenAPI spec:

```
packages/mallow_api/openapi/openapi.yaml
```

That file is the source of truth for routes, request shapes, and response
shapes. It is **generated from private schemas**, so you cannot regenerate it
from this repository — treat the vendored copy as the definition and edit it
directly if you are changing the contract for your own backend. `./di.sh`
regenerates the Dart client from it.

The API is split across two services. `API_BASE_URL` serves the older one —
which carries three path prefixes, not one: `/v1`, `/v0` (where session login
lives, along with likes, follows and wallet linking), and a few unversioned
routes such as `/home`. `API_V2_BASE_URL` serves `/v2`, the transaction
builders and the on-chain reads. The two are configured separately so they can
point at different services. Implement every prefix the spec declares — a
backend that serves only `/v1` cannot log a user in. See [api.md](api.md).

### Authentication

First-party builds identify themselves with a request header. **The header name
and value are not configured in this repository** — both are blank by default,
and blank means the header is omitted entirely rather than sent empty.

If your backend expects such a header, set `CLIENT_ID_HEADER` to its name and
`CLIENT_ID_IOS` / `CLIENT_ID_ANDROID` to the per-platform values. If it does
not, leave all three unset and nothing is sent.

The header is a credential, and the HTTP client it rides on also carries
third-party traffic, so it is host-gated rather than set globally.

A mallow-operated backend takes a different credential: `MALLOW_API_KEY`, sent
as the `x-api-key` header — the `ApiKeyAuth` scheme the vendored spec declares.
It is the short path to a running app if you hold a key, and it is a spendable
per-holder credential rather than a build identifier, so it goes to your
`API_BASE_URL` / `API_V2_BASE_URL` hosts only, on the same narrow gate as the
session cookie below. Set it together with `API_BASE_URL`; neither does
anything alone. If you run your own backend, implement whichever scheme you
prefer — the spec declares this one.

User sessions use a separate login token and wallet-signature JWT, carried as
cookies. Those are gated **more narrowly** — see below.

### Which hosts receive your credentials

There are two gates, not one, and the difference is the important part.

**Session credentials and `MALLOW_API_KEY` — your API hosts only, and not
configurable.** The login token, the per-address wallet-signature JWTs and the
`x-api-key` header go to your `API_BASE_URL` and `API_V2_BASE_URL` hosts, and
nowhere else. No variable widens this. It is a property of the code rather than
of your configuration, because these identify the *user* or the *key holder*: a
misconfiguration should not be able to put a live session, or a spendable key,
in someone else's access logs.

**Build-identifying headers — widenable.** `FIRST_PARTY_HOSTS` is a
comma-separated list of additional hosts that may receive the client-id header
and `App-Version`:

```
FIRST_PARTY_HOSTS=rpc.example.com,pin.example.com
```

A listed host learns which app build is calling. It never receives a session.
Requests that do not use the shared HTTP client (the Solana and EVM RPC calls,
the DAS reads, the gas and simulation endpoints, the IPFS upload) apply the
same check themselves and send the client-id header only to a listed host.

**What the rules are.**

- Your `API_BASE_URL` / `API_V2_BASE_URL` hosts are first-party automatically.
  You never list them, and nothing you put in this variable can remove them.
  The variable only ever adds.
- Matching is on the exact host, lower-cased. No wildcards, no suffix rules,
  and the port is ignored — `example.com` does not cover
  `sub.example.com`.
- Unset is the safe default. Nothing breaks in a way that hides: calls to your
  other endpoints simply go out unidentified, and are handled as anonymous
  traffic.

**What to list.** Hosts you operate — typically the proxies `RPC_PROXY_BASE_URL`
and `IPFS_UPLOAD_URL` point at, when those point at you. Do not list a
third-party endpoint you merely use. No session ever reaches a listed host, but
the client-id header is still a credential: a backend may accept it in place of
an API key, so a host you list can read your build's identifier out of its own
access logs and replay it. That is a reasonable thing to hand your own
infrastructure and an unreasonable thing to hand anyone else's. If you front a
third-party API with a proxy of your own, listing that proxy is fine — the
traffic and the logs are both yours.

---

## Dependencies

| Dependency | Variable | What breaks without it |
|---|---|---|
| **Backend API** | `API_BASE_URL`, `API_V2_BASE_URL` | Everything except purely local wallet operations. You can still create, import, and hold keys. **`API_BASE_URL` is required — there is no compiled-in default** |
| **mallow-issued API key** | `MALLOW_API_KEY` | Nothing, if you run your own backend. Against a mallow-operated one it is the credential: unset, requests go out unauthenticated. Useless without `API_BASE_URL` |
| **First-party hosts** | `FIRST_PARTY_HOSTS` | Nothing visibly. Your own proxies stop receiving the client-id header and are handled as anonymous traffic. **Read [Which hosts receive your credentials](#which-hosts-receive-your-credentials)** |
| **Solana RPC with DAS** | `RPC_PROXY_BASE_URL` | Portfolio, all NFT lists, compressed-NFT proofs. **Read the section below** |
| **Solana mainnet RPC** | `SOLANA_MAINNET_RPC_URL` | Nothing outright. `.sol` name resolution and native staking run on Solana's public mainnet node instead, at public rate limits |
| **EVM simulation** | `EVM_SIMULATION_URL` | All EVM transfers. No default; fails closed by design |
| **EVM gas API** | `EVM_GAS_API_URL` | The Low/Market/High tiers on the EVM send sheet. No default; sends fall back to node-derived fees |
| **Ethereum RPC** | `ETH_RPC_URL` | EVM balances, nonces, gas estimation, broadcast. Defaults to a public keyless node |
| **Tezos RPC** | `TEZOS_RPC_URL` | Tezos sends. Defaults to a public mainnet node |
| **Jupiter** | `JUPITER_BASE_URL` | Swaps, token metadata, token search. Defaults to Jupiter's public API |
| **CoinGecko** | `COINGECKO_BASE_URL` | Token prices and charts. Defaults to the public API |
| **IPFS pinning** | `IPFS_UPLOAD_URL` | The NFT mint flow. No default — see [Media, CDN and gateways](#media-cdn-and-gateways) |
| **Image CDN** | `IMAGE_CDN_BASE_URL` | Nothing visibly. Images load from their own origin at full size instead of a resized bucket |
| **Static asset CDN** | `ASSET_CDN_BASE_URL` | Rewards-store metadata, and the maintenance/broadcast banners |
| **IPFS gateway** | `IPFS_GATEWAY_URL` | Nothing — an extra rung in the fallback ladder only. Defaults to `ipfs.io` |
| **Arweave gateway** | `ARWEAVE_GATEWAY_URL` | The mirror retry for an Arweave 403. Defaults to `arweave.net`, which makes the retry a no-op |
| **Avatar service** | `AVATAR_SERVICE_URL` | Nothing — defaults to DiceBear's public API |
| **Firebase** | config files, not variables | Android build fails outright; iOS throws at startup |
| **Web3Auth** (MetaMask Embedded Wallets) | `WEB3AUTH_CLIENT_ID` | Social sign-in cannot initialise |
| **Sentry** | `SENTRY_DSN` | No crash reports. Everything else works |

Also available: `JUPITER_REFERRAL_ACCOUNT` (collects an integrator fee on swaps;
without it swaps run fee-free), `ANALYTICS_ENABLED` (set `false` to hard-disable
a build), and `CANONICAL_ASSET_URLS`.

---

## Media, CDN and gateways

Five variables name hosts that serve *your* bandwidth: an image resizer, a
static asset CDN, an IPFS gateway, an Arweave mirror, and an identicon service.
None of them is compiled in.

Each defaults to the public upstream it would otherwise proxy, so an
unconfigured build works — slower, and without your own cache in front. The two
with no public equivalent, `IMAGE_CDN_BASE_URL` and `ASSET_CDN_BASE_URL`,
default to empty and degrade the feature instead of guessing a host: images
load unresized from their own origin, and the store metadata and operator
banners are simply absent.

**IPFS assets are read through the CDN, not through a gateway.** An `ipfs://`
source resolves to `https://ipfs.io/ipfs/<cid>` and that string is embedded in
the CDN's resize path — it is the resizer's cache key, so it must match what
every other client of the same CDN emits. Direct gateway fetches happen only
when the CDN has failed, in the video and download fallback ladders, and
`IPFS_GATEWAY_URL` adds one rung to those.

🛑 **The gateway written into minted metadata is not configurable.** It is
always `ipfs.io`. That URL goes on-chain in the token's metadata and is
resolved by every marketplace and wallet that reads the token, forever — so it
has to be a gateway that serves any CID from the public DHT, and it has to
match what other clients of the same backend write. Neither is something a
build variable should be able to get wrong.

If you run these hosts yourself, list them in `FIRST_PARTY_HOSTS` so they
receive the client-id header — see
[Which hosts receive your credentials](#which-hosts-receive-your-credentials).

---

## The Solana RPC requirement, in detail

This is the dependency that most often makes a fresh clone look broken, so it
gets its own section.

`RPC_PROXY_BASE_URL` defaults to `https://api.mainnet-beta.solana.com` — the
public mainnet node. It is not a default you should ship on: it is rate-limited
and, as below, it does not implement DAS.

Devnet is opt-in, not the fallback. It used to be the default, so that a build
that configured nothing landed on devnet instead of transacting on mainnet; that
was given up deliberately, because it made the unconfigured build useless for
judging the app and trained readers to skip configuration. Select devnet by
setting `ENV=development` (or `staging`), which appends `?network=devnet` to
every RPC call, and point `RPC_PROXY_BASE_URL` at a devnet endpoint. An
unconfigured build now talks to mainnet.

**Whatever you point it at must implement the Metaplex DAS extensions:**
`searchAssets`, `getAsset`, and `getAssetProof`.

A stock Solana JSON-RPC node does not implement them — including
`api.mainnet-beta.solana.com`. Without them:

- the portfolio is empty
- every NFT list is empty
- compressed-NFT transfers cannot build a proof

None of that surfaces as an error. The screens simply render as though the
wallet holds nothing, which is the most confusing possible failure. Providers
offering DAS include [Helius](https://www.helius.dev),
[Triton](https://triton.one), and [QuickNode](https://www.quicknode.com).

### Proxying, and why the app ships no RPC key

The first-party deployment puts a proxy in front of its RPC provider. The proxy
injects the upstream API key server-side, so no RPC credential is compiled into
the app.

This matters more than it looks. A `--dart-define` value is **not a secret** —
it is compiled into the binary and recoverable from the snapshot by anyone who
unzips the artifact. Anything that must stay secret has to sit behind a service
you control. If you put a provider key directly in `RPC_PROXY_BASE_URL`, assume
it is public and scope it accordingly.

Non-production builds append `?network=devnet` to the RPC URL. A proxy is
expected to honour it; a plain node ignores it.

---

## The EVM simulation gate

`EVM_SIMULATION_URL` must accept an `eth_simulateV1` JSON-RPC call.

Before any EVM transfer is signed, the client simulates the fully-formed
transaction and blocks signing unless the only state change is the asset you
intended to move. It is the reason a malicious or compromised backend cannot
get you to sign a transaction that drains something else.

**It fails closed.** `simulateAssetChanges` throws on any non-200, and no caller
catches it — so if this endpoint does not implement `eth_simulateV1`, EVM
transfers error out rather than proceeding unsimulated. That is the intended
behaviour. Do not "fix" it by making the gate optional.

`EVM_SIMULATION_URL` and `EVM_GAS_API_URL` have **no defaults** — set both
explicitly. They used to derive routes from `RPC_PROXY_BASE_URL`, which is a
Solana endpoint, so the guess only resolved if your proxy also served EVM routes
and otherwise aimed a security gate at whatever answered that path. Unset,
`EVM_SIMULATION_URL` blocks every EVM transfer and `EVM_GAS_API_URL` drops the
send sheet back to node-derived fees; both name the variable in the error.

---

## Firebase

Firebase is a **hard requirement to build and launch**, not an optional
integration:

- Android: the `google-services` Gradle plugin fails the build when
  `android/app/google-services.json` is absent.
- iOS: `Firebase.initializeApp()` throws at startup without
  `ios/Runner/GoogleService-Info.plist`.

Both real files are gitignored. Placeholders ship so a clone can build and boot
immediately:

```bash
cp test/e2e/google-services.placeholder.json      android/app/google-services.json
cp test/e2e/GoogleService-Info.placeholder.plist  ios/Runner/GoogleService-Info.plist
```

Every value in them is obviously fake. With the placeholders in place the app
runs and push notifications and crash reporting are inert. For real behaviour,
create your own Firebase project and download the genuine files to those paths.

---

## Running against nothing

You do not need a backend to work on the app. `test/e2e/` contains a fully
local mock backend — no network, no credentials — used by the integration
suites. It is the fastest way to see the app running end to end, and a
reasonable reference for the response shapes the client expects. See
[test/e2e/README.md](../test/e2e/README.md).
