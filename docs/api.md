# API integration

How the app talks to its backend. For *what a fork must provide* — every
external service and what breaks without it — see [backend.md](backend.md).

## The two services, and the path prefixes they carry

There are two API services, and picking the wrong one is a common first
mistake. They have separate base URLs and separate clients:

| | Older service | `/v2` service |
|---|---|---|
| Client | `packages/mallow_api/lib/src/client.dart` | `packages/mallow_api/lib/src/client_v2.dart` |
| Base URL | `Config.apiBaseUrl` | `Config.apiV2BaseUrl` |
| Path prefixes | `/v0`, `/v1`, and a few unversioned routes | `/v2` |
| Covers | The older read and write surface, plus **all of session auth** | Transaction builders (`/tx/*`) and on-chain reads |

**The older service carries more than `/v1`**, and the part that surprises
people is that `/v0` is where the session lives. `POST /v0/login`,
`POST /v0/authToken` and `POST /v0/authToken/verify` open a session; likes,
follows, hides, wallet linking, whitelist eligibility and the marketplace-event
reads sit there too. `/home`, `/exhibitions/explore` and `/exhibitions/{slug}`
carry no version segment at all. All of them resolve against
`Config.apiBaseUrl` through the same client, so a backend that implements "the
`/v1` surface" and nothing else cannot log a user in. The vendored spec is the
authority on which prefix each operation has — it declares every one of them.

**`Config.apiV2BaseUrl` already includes the `/v2` path segment**, so method
paths in `client_v2.dart` omit it — `/tx/assets/burn` resolves to
`<host>/v2/tx/assets/burn` on the wire. Getting this wrong produces a `/v2/v2/`
path and a 404.

Both base URLs are configurable. `API_V2_BASE_URL` falls back to a value
derived from `API_BASE_URL`: an `http://` base (local development) has its port
swapped, because the v2 service runs as a separate process; an `https://` base
reuses the same host. Set both explicitly if your deployment differs.

## Response envelope

`{ "result": ... }` is the **common** shape, modelled by `ApiResponse<T>`
(`models/api_response.dart`), and callers read `.result`. It is **not universal** —
do not assume it. Roughly half the older service's methods and a quarter of the
`/v2` ones return something else. The shapes you will meet:

| Shape | When | Dart return type |
|---|---|---|
| `{ "result": T }` | most single-object reads and every `/tx/*` builder | `ApiResponse<T>` |
| `{ "result": [...], <siblings> }` | paginated reads, and any response with a field that is a peer of `result` rather than a member of it | a bare page model — `ActivityListResponse` (`result` + `pagination`), `PortfolioArtworksResponse` / `OffersPage` / `MarketActivityEventsPage` (`result` + `total` + `nextPage`), `BuyEditionTxsResponse` (`result` + `setupTx`) |
| no body | mutations that return nothing — `deleteUser`, `blockAddress`, `createReport`, the like / follow / curation writes (22 on the older service — 11 of them `/v0` — and 5 on `/v2`) | `Future<void>` |

A handful of the bare models are not paginated at all — `HolderOnlyMintResponse`
is `{ result }` and nothing else, modelled separately only because
`ApiResponse<T>` declares `required T result` and cannot express the null
payload that endpoint returns — and three legacy methods still return
`Future<dynamic>`.

The second row is the one that bites: wrapping a paginated read in
`ApiResponse<List<T>>` parses the rows and silently drops the sibling, so
pagination looks broken with no error anywhere. `BuyEditionTxsResponse` says why
in its own doc comment — `setupTx` is a sibling of `result`, not a member of it,
so the raw envelope is the return type. When you add a method, check the vendored
spec for what actually comes back rather than reaching for `ApiResponse<T>` by
reflex.

v2 request and response bodies are **camelCase** on the wire. Sending a
snake_case key makes the server reject the body with a 400/422 — the failure is
silent from the UI's point of view, so the wire shape is pinned by tests such as
`packages/mallow_api/test/models/transfer_tx_test.dart`.

## Request pattern (Retrofit)

The clients are `retrofit` interfaces; `./di.sh` generates the implementations.

```dart
@RestApi()
abstract class MallowApiClient {
  factory MallowApiClient(Dio dio, {String baseUrl}) = _MallowApiClient;

  @GET('/v1/artwork/byMint/{mint}')
  Future<ApiResponse<Artwork>> getArtwork(@Path('mint') String mint);
}
```

Most models are generated from the vendored OpenAPI spec
(`packages/mallow_api/openapi/openapi.yaml`). A handful stay hand-written where
the generator cannot express the shape; each says why at the top of its file.
Prefer the generated model — do not add a hand-rolled twin without a stated
reason.

## Error handling

Repositories and blocs do not catch `DioException` directly. Wrap the call in
`Result.guard(...)`, which classifies the failure into `AppFailure` and lets a
bloc distinguish "user cancelled" from "request failed" from "no results":

```dart
final result = await Result.guard(() => _api.getArtwork(mint));

switch (result) {
  case ResultSuccess(:final value):
    emit(MyState.loaded(value.result));
  case ResultFailure(:final error):
    emit(MyState.error(error.message));
}
```

Swallowing a transport error into an empty list is a bug, not a convenience: it
renders a network failure as an indistinguishable blank screen. See
[architecture.md](architecture.md) for the full pattern.

## Authentication

Sessions are established by signing a timestamped message with a local wallet;
the resulting login token and wallet-signature JWT are carried as cookies.

Nothing credential-bearing is set globally — the same `Dio` instance also
carries third-party traffic — so each header is attached by a host-guarded
interceptor. Three headers, but only **two** gates — and the difference
between the gates is the part that matters:

| Header | Gate | Configurable? |
|---|---|---|
| Session `Cookie` (login token, wallet-sig JWTs) | `Config.sessionHosts` — your configured API hosts, and nothing else | **No** |
| `x-api-key` (`MALLOW_API_KEY`) | `Config.sessionHosts` — the same narrow set | **No** |
| Client-id header, `App-Version` | `Config.firstPartyHosts` — the API hosts plus any host in `FIRST_PARTY_HOSTS` | Yes, additive only |

**Session credentials go to your API hosts and nowhere else.** That is a
property of the code, not of your configuration: no value of
`FIRST_PARTY_HOSTS` can widen it. The cookies identify the *user*, so listing a
proxy shares a build identifier with it and never a live session.

`MALLOW_API_KEY` rides the same narrow gate, for the neighbouring reason: the
client-id header says which *build* is calling, while the key is spendable by
whoever holds it, so a line of build configuration must not be able to hand it
to a declared RPC or IPFS proxy. `Config.apiKeyHeadersFor` is the single
expression that decides where it may travel — see
`lib/core/network/api_key_interceptor.dart`.

`FIRST_PARTY_HOSTS` is additive only in the other direction too — no value of it
can *remove* the API hosts, so a typo cannot silently strip authentication off
your own backend.

Requests that do not ride the shared `Dio` — the RPC clients, the IPFS uploader,
the EVM gas and simulation calls — apply the client-id gate through
`Config.clientIdHeadersFor(url)`; see [backend.md](backend.md).
