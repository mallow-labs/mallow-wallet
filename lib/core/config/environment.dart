import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

enum Environment { development, staging, production }

/// Cast receiver id used when `CAST_RECEIVER_APP_ID` is unset — mallow's own
/// registered receiver. Kept next to the enum rather than inside [Config] so
/// the Android Gradle build, which reads this value out of the dart-defines
/// long before Dart runs, has one obvious place to keep in step with.
const String kDefaultCastReceiverAppId = '3B14DCF8';

/// Application configuration, compiled in at build time via `--dart-define`.
///
/// Builds pass the whole set with `--dart-define-from-file=.env`, plus an
/// explicit `--dart-define=ENV=<env>`. Nothing here is read from disk at
/// runtime: `.env` is deliberately NOT a bundled asset, because a bundled asset
/// ships as plaintext inside the IPA/APK and any user can unzip it.
///
/// Note this hardens packaging, not secrecy — a `--dart-define` value is still
/// compiled into the binary and recoverable from the snapshot. Anything that
/// must stay secret belongs behind a server-side proxy (see [rpcProxyBaseUrl]),
/// not in this file.
class Config {
  const Config._();

  /// Test-only config overrides, consulted ahead of `--dart-define`.
  ///
  /// Every value below is fixed at compile time, so a test cannot vary one the
  /// way it could with a runtime `.env`. Tests that need a per-case value —
  /// chiefly pointing an RPC getter at an ephemeral local HTTP server whose
  /// port is only known at runtime — write it here and clear it in `tearDown`.
  /// Production never writes to this map.
  @visibleForTesting
  static final Map<String, String> debugOverrides = <String, String>{};

  /// Resolves [key] from [debugOverrides], else the compiled-in `--dart-define`.
  ///
  /// [dartDefine] must be passed as `const String.fromEnvironment(key)` with the
  /// same literal [key]: `fromEnvironment` is const-only, so it cannot be looked
  /// up from a variable inside this helper.
  static String _env(String key, String dartDefine) =>
      debugOverrides[key] ?? dartDefine;

  // ---------------------------------------------------------------------------
  // Environment
  // ---------------------------------------------------------------------------

  /// Which deployment tier this build targets, from
  /// `--dart-define=ENV=development|staging|production`.
  ///
  /// **Defaults to `production`, and an unrecognised value resolves there too.**
  /// It is the only setting whose wrong value is *invisible*: everything it
  /// switches keeps working, just against the wrong network.
  ///
  /// | It switches | Non-production | Production |
  /// | --- | --- | --- |
  /// | [solanaRpcUrl] | `?network=devnet` appended | no cluster parameter |
  /// | [web3AuthNetwork] | `sapphire_devnet` | `sapphire_mainnet` |
  /// | [storeCdnBaseUrl] | `/store/dev` | `/store` |
  /// | `explorerUrl` | `?cluster=devnet` appended | no cluster parameter |
  ///
  /// 🛑 [web3AuthNetwork] is **part of the social key derivation**: the same
  /// social account yields a *different address* on each network. That is why
  /// an unset variable must not silently pick a network — a build that guessed
  /// devnet would hand a user one set of addresses and a correctly-configured
  /// build another, with no error in between.
  ///
  /// Defaulting to `production` rather than throwing is deliberate (and rather
  /// than to `development`, which is what this used to do). An unconfigured
  /// build is then the *ordinary* build — mainnet, the real key derivation, the
  /// real store — so nothing about it is a special case a reader has to know
  /// about. Internal and CI builds select the other tiers explicitly; see
  /// `.env.example`.
  static Environment get environment {
    final env = _env(
      'ENV',
      const String.fromEnvironment('ENV', defaultValue: 'production'),
    );
    return Environment.values.firstWhere(
      (e) => e.name == env,
      orElse: () => Environment.production,
    );
  }

  static bool get isDevelopment => environment == Environment.development;
  static bool get isStaging => environment == Environment.staging;
  static bool get isProduction => environment == Environment.production;

  // ---------------------------------------------------------------------------
  // API URLs
  // ---------------------------------------------------------------------------

  /// Base URL of the backend this build talks to. **Required — there is no
  /// compiled-in fallback for any environment.**
  ///
  /// A deployment host baked into the binary is a default that outlives the
  /// build it was right for: a fork that forgets the variable silently talks to
  /// someone else's backend, and a mis-built first-party binary silently talks
  /// to the wrong tier. Unset it returns empty, and the client that needs it
  /// raises [missingApiBaseUrl] naming the variable — the same fail-loud shape
  /// as [ethereumSimulationUrl].
  static String get apiBaseUrl {
    final value = _env(
      'API_BASE_URL',
      const String.fromEnvironment('API_BASE_URL'),
    );
    if (value.isEmpty) {
      debugPrint('[Config] API_BASE_URL is not set — API calls will fail');
    }
    return value;
  }

  /// Thrown by the API layer when [apiBaseUrl] is unset. Names the variable so
  /// the failure reads as configuration, not as a network fault.
  ///
  /// It names both ways to satisfy it, because "there is no default backend"
  /// on its own reads as "you must first write a backend". The second path —
  /// point it at the base URL issued with a [mallowApiKey] — is the short one.
  /// Neither the host nor the key appears here: a host in an error string is a
  /// compiled-in deployment host by another route, and a key in one is a
  /// credential in every log that captures the throw.
  static StateError get missingApiBaseUrl => StateError(
    'API_BASE_URL is not configured. Set it in .env (see .env.example) — '
    'there is no default backend. Point it at a backend implementing the '
    'vendored OpenAPI contract, or, if you hold a mallow API key, at the base '
    'URL issued with it (set MALLOW_API_KEY alongside).',
  );

  /// Base URL for `/v2` routes including the `/v2` path segment (currently the
  /// realtime invalidations WebSocket; future v2 REST endpoints should resolve
  /// through here too). Callers append the route suffix directly, e.g.
  /// `'$apiV2BaseUrl/ws/invalidations'`.
  ///
  /// Resolution order: `--dart-define=API_V2_BASE_URL`, then derived from
  /// [apiBaseUrl] — local dev backends (http://) get their port swapped to
  /// `8090` (the v2 service runs as a separate process during development),
  /// while staging/prod (https://) reuse the same host since v2 is fronted
  /// alongside v1. The `/v2` suffix is appended in all derived cases.
  static String get apiV2BaseUrl {
    final value = _env(
      'API_V2_BASE_URL',
      const String.fromEnvironment('API_V2_BASE_URL'),
    );
    if (value.isNotEmpty) {
      debugPrint('[Config] API_V2_BASE_URL from --dart-define: $value');
      return value;
    }

    final base = apiBaseUrl;
    // Nothing to derive from. Returning `/v2` here would turn a missing
    // API_BASE_URL into a relative path the HTTP client resolves against
    // whatever it likes, which reads as a routing bug rather than as the
    // configuration error it is.
    if (base.isEmpty) return '';
    final host = base.startsWith('http://')
        ? Uri.parse(base).replace(port: 8090).toString()
        : base;
    final derived = '$host/v2';
    debugPrint('[Config] API_V2_BASE_URL derived from apiBaseUrl: $derived');
    return derived;
  }

  /// Extra hosts a build declares first-party, from
  /// `--dart-define=FIRST_PARTY_HOSTS` (comma-separated, e.g.
  /// `rpc.example.com,pin.example.com`).
  ///
  /// Additive to the derived API hosts, never a replacement. The API hosts are
  /// first-party by construction — they are whatever this build was pointed
  /// at. Nothing else can be derived that way: every other endpoint below
  /// ([rpcProxyBaseUrl], [jupiterBaseUrl], [ipfsUploadUrl], …) is equally
  /// likely to be a deployment's own proxy or a third party's public API, and
  /// only the operator knows which. Unlisted means untrusted, so a build that
  /// sets nothing here simply never sends the client-id header off its own
  /// backend.
  ///
  /// Exact host match, lower-cased, ports ignored — no wildcards and no suffix
  /// rules. A wildcard here would be a wildcard on where a credential travels,
  /// and there is no reading of `*.example.com` under which handing the header
  /// to whoever registered `evil.example.com` is the intent.
  ///
  /// This widens the *client-id* gate only. It cannot widen the session gate:
  /// the `Cookie` header is pinned to [sessionHosts], which this never feeds.
  static Set<String> get extraFirstPartyHosts {
    final raw = _env(
      'FIRST_PARTY_HOSTS',
      const String.fromEnvironment('FIRST_PARTY_HOSTS'),
    );
    return raw
        .split(',')
        .map((host) => host.trim().toLowerCase())
        .where((host) => host.isNotEmpty)
        .toSet();
  }

  /// The only hosts that may receive the user's session credentials: the v1 and
  /// v2 API hosts, derived from whatever [apiBaseUrl] / [apiV2BaseUrl] a build
  /// is pointed at.
  ///
  /// 🛑 **Not configurable, on purpose.** This is deliberately *not* a union
  /// with [extraFirstPartyHosts], and must never become one. `AuthService`'s
  /// interceptor attaches the session `Cookie` — the login token plus one
  /// wallet-signature JWT per address in the session — and those identify the
  /// *user*, not the build. Every other first-party header identifies only the
  /// build, which is why those may widen and this may not.
  ///
  /// The consequence is a guarantee worth keeping: no value of
  /// `FIRST_PARTY_HOSTS`, no misconfiguration, and no operator convenience can
  /// route a live session to anything but the backend the build already talks
  /// to. Adding a proxy to `FIRST_PARTY_HOSTS` shares a build identifier with
  /// it and nothing more. If some future host genuinely needs the session, it
  /// needs to become an API host — not an entry in a list.
  ///
  /// Host only, never port: a local dev backend splits v1 and v2 across
  /// `localhost:8100` / `:8090`, which is one host.
  ///
  /// Empty entries are dropped: with `API_BASE_URL` unset both parses yield the
  /// empty host, and a set containing `''` would make every host comparison
  /// against an unparseable URL succeed.
  static Set<String> get sessionHosts =>
      {Uri.parse(apiBaseUrl).host, Uri.parse(apiV2BaseUrl).host}
        ..removeWhere((h) => h.isEmpty);

  /// Hosts that count as first-party for the *build-identifying* request
  /// headers — the client-id header and `App-Version`: the derived API hosts
  /// ([sessionHosts]) plus whatever [extraFirstPartyHosts] adds.
  ///
  /// The app's HTTP client is one shared `Dio` that also carries third-party
  /// traffic — Jupiter's public token search and the rewards CDN read through
  /// the very same instance — so these headers are attached by a host-guarded
  /// interceptor rather than by `BaseOptions`. The clients that do not ride
  /// that chain at all — raw `RpcClient`s, the per-service `Dio`s,
  /// `package:http` — go through [clientIdHeadersFor], which reads this set.
  ///
  /// 🛑 This does **not** gate the session `Cookie`; [sessionHosts] does, and
  /// it is narrower. Do not collapse the two back into one set to "keep the
  /// guards from drifting" — they are different policies because the headers
  /// carry different things. A host here learns which app build is calling.
  ///
  /// The union shape is deliberate and must stay. `FIRST_PARTY_HOSTS` can only
  /// *add*; no value of it can drop the derived API hosts, so a typo (or an
  /// attacker who gets to influence the build config) cannot turn the app's
  /// own backend into a third party and silently strip the header off every
  /// request to it.
  static Set<String> get firstPartyHosts => {
    ...sessionHosts,
    ...extraFirstPartyHosts,
  };

  // ---------------------------------------------------------------------------
  // Media, CDN and gateway hosts
  //
  // Every entry below used to be a deployment host compiled into the source.
  // They are configuration for one reason each build should be able to answer
  // for itself: they carry *this deployment's* bandwidth. A fork that inherits
  // them serves its users' images, avatars and IPFS reads off infrastructure
  // somebody else pays for, and cannot repoint them without patching Dart.
  //
  // The defaults are the public upstream each first-party host proxies, so an
  // unconfigured build still works — slower, and without the resize and
  // originals cache, which is the honest trade. The two with no public
  // equivalent ([imageCdnBaseUrl], [assetCdnBaseUrl]) default to empty and
  // degrade the feature rather than guessing a host.
  // ---------------------------------------------------------------------------

  /// Origin of the image-resizing CDN — the `/{size}x{size}/{fit}/…` resize
  /// route and the `/original/` route.
  ///
  /// Empty (the default) turns both into pass-throughs: images load from their
  /// own origin at full size. Nothing breaks visually — `MallowNetworkImage`
  /// still caps the decode with `memCacheWidth` — but every tile pulls the full
  /// asset, so set this if you serve a resizer.
  static String get imageCdnBaseUrl => _trimTrailingSlash(
    _env(
      'IMAGE_CDN_BASE_URL',
      const String.fromEnvironment('IMAGE_CDN_BASE_URL'),
    ),
  );

  /// Every host below is concatenated with a path by its consumer, so a value
  /// that ends in `/` would produce `//store` or `//ipfs/`. Normalise once here
  /// rather than trusting nine call sites to remember.
  static String _trimTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  /// Origin of the static asset CDN: the rewards-store metadata under
  /// `/store`, and the operator status and notice feeds.
  ///
  /// Empty (the default) disables the rewards store's metadata reads and the
  /// status/notice banners. Those banners fail safe already — a feed that does
  /// not answer shows nothing — so an unset value costs a feature, not
  /// correctness.
  static String get assetCdnBaseUrl => _trimTrailingSlash(
    _env(
      'ASSET_CDN_BASE_URL',
      const String.fromEnvironment('ASSET_CDN_BASE_URL'),
    ),
  );

  /// Base URL for the rewards store metadata CDN. Devnet (development/staging
  /// backends) serves under `/store/dev`; production under `/store`.
  ///
  /// Empty when [assetCdnBaseUrl] is unset — callers must treat that as "no
  /// store metadata available" rather than building a relative path.
  static String get storeCdnBaseUrl {
    final base = assetCdnBaseUrl;
    if (base.isEmpty) return '';
    return isProduction ? '$base/store' : '$base/store/dev';
  }

  /// An additional IPFS gateway to race in the asset fallback ladder.
  ///
  /// 🛑 **Not the primary resolver.** An `ipfs://` source always resolves to
  /// the public `ipfs.io` first — that string is the image CDN's cache key and
  /// must match what the web client emits (see `AssetUrl._primaryGateway`) —
  /// and every render goes through the CDN's `/original/` or resize route
  /// before any gateway is contacted directly. This host is only tried when
  /// that fails, in the video and download ladders.
  ///
  /// Defaults to `ipfs.io`, which makes the extra rung a no-op the candidate
  /// list de-duplicates away. Set it to a gateway that reliably holds your
  /// pinned CIDs to buy a retry between `ipfs.io` and `dweb.link`; leave it
  /// unset to keep the app off your own gateway entirely.
  static String get ipfsGatewayUrl {
    final value = _env(
      'IPFS_GATEWAY_URL',
      const String.fromEnvironment('IPFS_GATEWAY_URL'),
    );
    return value.isNotEmpty ? _trimTrailingSlash(value) : 'https://ipfs.io';
  }

  /// Arweave gateway used as the mirror when the asset's own gateway refuses
  /// the fetch — `arweave.net` returns 403 for particular clients and regions
  /// even for data it serves fine elsewhere.
  ///
  /// Defaults to `arweave.net` itself, which makes the mirror step a no-op
  /// (the candidate list de-duplicates) rather than a second host to trust.
  static String get arweaveGatewayUrl {
    final value = _env(
      'ARWEAVE_GATEWAY_URL',
      const String.fromEnvironment('ARWEAVE_GATEWAY_URL'),
    );
    return value.isNotEmpty ? _trimTrailingSlash(value) : 'https://arweave.net';
  }

  /// Origin of the DiceBear-compatible identicon service used for generated
  /// avatars. Defaults to DiceBear's own public API, which is what a
  /// first-party deployment proxies anyway, so the path shape is identical.
  static String get avatarServiceUrl {
    final value = _env(
      'AVATAR_SERVICE_URL',
      const String.fromEnvironment('AVATAR_SERVICE_URL'),
    );
    return value.isNotEmpty
        ? _trimTrailingSlash(value)
        : 'https://api.dicebear.com';
  }

  // ---------------------------------------------------------------------------
  // Canonical asset URLs
  // ---------------------------------------------------------------------------

  /// Whether asset URLs are emitted in canonical form — `ipfs://<CID>[/path]` /
  /// `ar://<TXID>[/path]` embedded in the [imageCdnBaseUrl] resize path.
  ///
  /// Resolved like every other setting here: `--dart-define`, then off. Real
  /// builds set `CANONICAL_ASSET_URLS` in the `.env` that
  /// `--dart-define-from-file` compiles in. A build that passes neither
  /// keeps emitting gateway-form resize URLs and fragments the Cloudflare edge
  /// key per gateway.
  ///
  /// Originals are no longer behind this gate: they always go through
  /// `/original/` (see [MallowImage.originalUrl]).
  ///
  /// Assignable so tests can exercise both sides; production never assigns.
  static bool? _canonicalAssetUrlsOverride;

  static bool get canonicalAssetUrls =>
      _canonicalAssetUrlsOverride ??
      _isTruthy(const String.fromEnvironment('CANONICAL_ASSET_URLS'));

  static set canonicalAssetUrls(bool value) =>
      _canonicalAssetUrlsOverride = value;

  static bool _isTruthy(String value) {
    final v = value.trim().toLowerCase();
    return v == 'true' || v == '1';
  }

  // ---------------------------------------------------------------------------
  // First-party client identification
  // ---------------------------------------------------------------------------

  /// Name of the request header a build sends to identify itself to the
  /// backend and the proxies it fronts.
  ///
  /// Blank by default, and blank means **omitted**: a build that does not
  /// configure both this and [clientIdValue] sends no such header at all
  /// rather than an empty one. Set both via `--dart-define` to whatever the
  /// deployment this app points at expects.
  static String get clientIdHeaderName => _env(
    'CLIENT_ID_HEADER',
    const String.fromEnvironment('CLIENT_ID_HEADER'),
  );

  /// Per-platform value for [clientIdHeaderName]. Deployments that attribute
  /// or authorize traffic per platform register a distinct value for each, so
  /// iOS and Android are configured separately.
  static String get clientIdValue => Platform.isIOS
      ? _env('CLIENT_ID_IOS', const String.fromEnvironment('CLIENT_ID_IOS'))
      : _env(
          'CLIENT_ID_ANDROID',
          const String.fromEnvironment('CLIENT_ID_ANDROID'),
        );

  /// Client-identification header for outbound first-party requests, or an
  /// empty map when either half is unconfigured.
  ///
  /// Spread into a request's headers (`...Config.clientIdHeaders`) so an
  /// unconfigured build sends nothing at all — an empty header value is a
  /// different thing on the wire from an absent header, and gateways are
  /// entitled to reject it as malformed rather than treat it as anonymous.
  static Map<String, String> get clientIdHeaders {
    final name = clientIdHeaderName;
    final value = clientIdValue;
    if (name.isEmpty || value.isEmpty) return const {};
    return {name: value};
  }

  /// [clientIdHeaders] when [url]'s host is in [firstPartyHosts], an empty map
  /// otherwise.
  ///
  /// 🛑 The only sanctioned way to attach the client-id header outside the
  /// shared `Dio`'s `ClientIdInterceptor`. That interceptor guards on the host
  /// of every request it sees, but plenty of traffic never reaches it: each
  /// raw `RpcClient`, per-service `Dio` and `package:http` call builds its own
  /// headers, and a header hand-written into `BaseOptions` carries no guard at
  /// all. This header is a credential — the backend takes it in place of an
  /// API key on the open `/v2` routes — so an ungated spread hands it to
  /// whichever endpoint a deployment happened to configure, including a public
  /// third-party RPC or pinning service.
  ///
  /// `test/core/config/client_id_usage_guard_test.dart` fails the build if
  /// [clientIdHeaders] is named anywhere in `lib/` other than here and the
  /// interceptor.
  static Map<String, String> clientIdHeadersFor(Uri url) =>
      firstPartyHosts.contains(url.host) ? clientIdHeaders : const {};

  // ---------------------------------------------------------------------------
  // Backend API key
  // ---------------------------------------------------------------------------

  /// Name of the API-key header. Not an invention: it is the `ApiKeyAuth`
  /// scheme the vendored OpenAPI contract already declares, so a reader who
  /// implements the contract gets the same mechanism for free.
  static const String apiKeyHeaderName = 'x-api-key';

  /// Key authenticating this build against a mallow-operated backend, from
  /// `--dart-define=MALLOW_API_KEY`. Empty by default, and empty means the
  /// header is omitted entirely.
  ///
  /// It exists so a reader does not have to write a backend before running the
  /// app: a key is issued together with the base URL to use it against, and the
  /// two are set together ([apiBaseUrl] keeps its no-default behaviour, so
  /// neither one alone does anything).
  ///
  /// 🛑 **Never log it** — not in a `debugPrint`, a breadcrumb, or an error
  /// message body. Unlike the client-id header, which identifies a build, this
  /// is a per-holder credential: whoever reads it out of a log can spend the
  /// issuing account's quota until it is revoked. [printStatus] deliberately
  /// prints only whether it is set.
  static String get mallowApiKey =>
      _env('MALLOW_API_KEY', const String.fromEnvironment('MALLOW_API_KEY'));

  /// The `x-api-key` header for [url] when [url] is one of [sessionHosts], an
  /// empty map otherwise.
  ///
  /// 🛑 **[sessionHosts], not [firstPartyHosts] — and this must not "drift"
  /// into the wider set.** `FIRST_PARTY_HOSTS` is build configuration: it lets
  /// a deployment declare its RPC, gas or IPFS proxies first-party so they
  /// receive the client-id header, which tells them only which build is
  /// calling. This key is a working credential for *one* backend, so gating it
  /// there would let a line of configuration hand a third-party proxy a key it
  /// can spend. That is the exact distinction [sessionHosts] was created for —
  /// the session `Cookie` is pinned the same way, for the same reason.
  ///
  /// Spread into a request's headers so an unconfigured build sends no header
  /// at all rather than an empty one — same rule as [clientIdHeaders].
  static Map<String, String> apiKeyHeadersFor(Uri url) {
    final key = mallowApiKey;
    if (key.isEmpty || !sessionHosts.contains(url.host)) return const {};
    return {apiKeyHeaderName: key};
  }

  // ---------------------------------------------------------------------------
  // Solana RPC proxy
  // ---------------------------------------------------------------------------

  /// Base URL of the Solana JSON-RPC endpoint, set with
  /// `--dart-define=RPC_PROXY_BASE_URL`.
  ///
  /// 🛑 **The default is deliberately not good enough to ship on.** It is
  /// Solana's public mainnet node: rate-limited, and — the part that matters —
  /// it does **not** implement the DAS extensions. It is a default that keeps
  /// an unconfigured build *consistent*, not one that makes it work.
  ///
  /// It used to be the public **devnet** node, so that a misconfigured build
  /// landed on devnet rather than transacting on mainnet. That was traded away
  /// on purpose. A default that is wrong-but-harmless teaches people to leave
  /// configuration alone, and it made the unconfigured build useless for
  /// judging the app: devnet answers every call and holds none of the reader's
  /// assets, so the app looked empty and broken for a reason no error named.
  /// Mainnet is what a reader expects, and what every other default here now
  /// assumes ([environment] defaults to production, so nothing else selects a
  /// test cluster either).
  ///
  /// ⚠️ **The trade-off, stated plainly: an unconfigured or misconfigured build
  /// now talks to mainnet.** What is left in its place is documentation — `ENV`
  /// and every other build variable are documented in `.env.example` and the
  /// README — and the fact that signing still needs a funded wallet the reader
  /// controls and a biometric confirmation per operation. The safety net of
  /// "wrong config lands on devnet" is gone by choice, not by oversight; do not
  /// reinstate it.
  ///
  /// Whatever you point this at MUST implement `searchAssets`, `getAsset`, and
  /// `getAssetProof`. Without them the portfolio, every NFT list, and every
  /// compressed-NFT proof come back empty, and the app looks broken rather than
  /// erroring. A stock Solana RPC node — **the default here included** — does
  /// not implement them. Sign up with a DAS-capable provider (Helius,
  /// Triton, QuickNode and others offer it) and point this at that endpoint, or
  /// at your own proxy in front of one.
  ///
  /// Fronting it with a proxy is what lets the app ship no RPC secret: the
  /// proxy injects the upstream key server-side and the app identifies itself
  /// with [clientIdHeadersFor] instead — list the proxy's host in
  /// `FIRST_PARTY_HOSTS` or the header is withheld. Non-production builds
  /// select the cluster with `?network=devnet`, which a proxy is expected to
  /// honour and a plain node ignores.
  static String get rpcProxyBaseUrl {
    final value = _env(
      'RPC_PROXY_BASE_URL',
      const String.fromEnvironment('RPC_PROXY_BASE_URL'),
    );
    return value.isNotEmpty ? value : 'https://api.mainnet-beta.solana.com';
  }

  /// Whether the active environment targets Solana devnet (dev/staging).
  /// Production runs mainnet-beta.
  static bool get isDevnet => environment != Environment.production;

  /// Solana JSON-RPC + DAS endpoint, routed through [rpcProxyBaseUrl].
  /// Non-production builds add `network=devnet` so the proxy targets devnet;
  /// production omits it (the proxy defaults to mainnet-beta).
  ///
  /// The parameter is *merged* into whatever query string the base URL already
  /// carries rather than appended after a literal `?`. DAS-capable providers
  /// hand out endpoints that keep the API key in the query
  /// (`https://<host>/?api-key=<key>`), and a second `?` glues the cluster onto
  /// the key (`...?api-key=<key>?network=devnet`) — the whole thing parses as
  /// one bad key value and every RPC call 401s.
  static String get solanaRpcUrl {
    final base = rpcProxyBaseUrl;
    if (!isDevnet) return base;
    final uri = Uri.parse(base);
    return uri
        .replace(
          queryParameters: {
            ...uri.queryParametersAll,
            'network': const ['devnet'],
          },
        )
        .toString();
  }

  /// Mainnet-pinned Solana JSON-RPC, independent of the app environment, set
  /// with `--dart-define=SOLANA_MAINNET_RPC_URL`.
  ///
  /// Two consumers pin here rather than following [solanaRpcUrl]: `.sol` name
  /// resolution (`SnsResolver` — SNS registry accounts exist only on mainnet)
  /// and `SolanaRpcService.mainnet`, because native staking can only delegate
  /// to mallow's mainnet validator. Pointed at devnet, both fail *quietly* —
  /// an unregistered domain and an empty stake list are ordinary answers, not
  /// errors — which is why this is its own variable and not an alias.
  ///
  /// Unlike [rpcProxyBaseUrl], the default is fine to ship on. These callers
  /// make plain JSON-RPC account reads with **no DAS involved**, so Solana's
  /// public mainnet node answers them correctly; it is only rate-limited.
  /// Point this at the same proxy in production to get the throughput back.
  static String get solanaMainnetRpcUrl {
    final value = _env(
      'SOLANA_MAINNET_RPC_URL',
      const String.fromEnvironment('SOLANA_MAINNET_RPC_URL'),
    );
    return value.isNotEmpty ? value : 'https://api.mainnet-beta.solana.com';
  }

  /// CAIP-2 chain id for the active Solana cluster, kept in lock-step with
  /// [solanaRpcUrl]: dev/staging run on devnet, production on mainnet-beta.
  ///
  /// It existed to scope Reown AppKit's remote sign requests to the cluster the
  /// app builds on. Social signing is local now (Web3Auth), so nothing reads
  /// this today — it is kept for the next caller that needs a CAIP-2 id, and
  /// must keep tracking [solanaRpcUrl]'s cluster if one appears.
  static String get solanaChainId => switch (environment) {
    Environment.development => 'solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1',
    Environment.staging => 'solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1',
    Environment.production => 'solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp',
  };

  // ---------------------------------------------------------------------------
  // Tezos RPC (public node)
  // ---------------------------------------------------------------------------

  /// Whether the active environment targets Tezos mainnet — pinned `true` in
  /// every environment. Unlike Solana, the mallow backend serves Tezos balances
  /// from a mainnet-only source (`/v2/tezos/balances`, TzKT), so if the app's
  /// send RPC ran on shadownet the balance a wallet is judged by (mainnet) and
  /// the network the transfer is forged/injected against (shadownet) would
  /// disagree — a valid source would fail to send, or vice-versa. We pin the
  /// send path to mainnet so both halves agree (mirrors the staking
  /// mainnet-pin). Override via `TEZOS_RPC_URL` to point at a testnet node.
  static bool get isTezosMainnet => true;

  /// Default public Tezos RPC nodes. No app-side proxy exists yet (unlike the
  /// Solana [rpcProxyBaseUrl]) — fronting these behind a first-party Tezos
  /// proxy is a follow-up. Mainnet is TzKT's public node (same source as
  /// the balance backend); testnet is Shadownet (teztnets).
  ///
  /// NB: the node MUST permit the `run_operation` simulation POST the send flow
  /// uses to estimate fees. The Tezos Foundation node (`rpc.tzbeta.net`) serves
  /// GET reads but returns HTTP 401 on `run_operation`, which surfaced as a
  /// "Parallel request error" then a 401 at the amount → confirm step. TzKT's
  /// node permits it. The old ECAD defaults (`mainnet.api.tez.ie`,
  /// `ghostnet.ecadinfra.com`) are dead DNS — Ghostnet is decommissioned.
  static const String tezosMainnetRpcUrl = 'https://rpc.tzkt.io/mainnet';
  static const String tezosShadownetRpcUrl =
      'https://rpc.shadownet.teztnets.com';

  /// Base URL of the Tezos node RPC — the mainnet node in every environment
  /// (see [isTezosMainnet]: the backend balance source is mainnet-only, so the
  /// send path is pinned to mainnet to match). Overridable via
  /// `--dart-define=TEZOS_RPC_URL` to point at a self-hosted, testnet, or
  /// alternate public node.
  static String get tezosRpcUrl {
    final value = _env(
      'TEZOS_RPC_URL',
      const String.fromEnvironment('TEZOS_RPC_URL'),
    );
    if (value.isNotEmpty) return value;
    return isTezosMainnet ? tezosMainnetRpcUrl : tezosShadownetRpcUrl;
  }

  // ---------------------------------------------------------------------------
  // Ethereum RPC (public node)
  // ---------------------------------------------------------------------------

  /// Ethereum mainnet chain id (EIP-155), signed into every transaction.
  static const int ethereumChainId = 1;

  /// Ethereum is mainnet-only in every environment — the mallow backend serves
  /// EVM balances from a mainnet-only indexer (`/v2/evm/balances`), so the send
  /// path is pinned to mainnet to match (same rationale as the Tezos
  /// mainnet-pin: the balance a wallet is judged by and the network the
  /// transfer is broadcast to must agree).
  static bool get isEthereumMainnet => true;

  /// Default public Ethereum mainnet JSON-RPC node for money movement — balance,
  /// nonce, `eth_estimateGas`, `eth_sendRawTransaction`, receipt polling.
  /// publicnode serves these without an API key. Gas-fee estimation is sourced
  /// separately from the Infura Gas API via [ethereumGasApiBaseUrl]. Override
  /// via `ETH_RPC_URL`.
  static const String ethereumMainnetRpcUrl =
      'https://ethereum-rpc.publicnode.com';

  /// Base URL of the Ethereum node RPC — the mainnet node in every environment
  /// (see [isEthereumMainnet]). Overridable via `--dart-define=ETH_RPC_URL`.
  static String get ethereumRpcUrl {
    final value = _env(
      'ETH_RPC_URL',
      const String.fromEnvironment('ETH_RPC_URL'),
    );
    return value.isNotEmpty ? value : ethereumMainnetRpcUrl;
  }

  /// Base URL of the Infura Gas API surface (`GET <base>/suggestedGasFees` →
  /// `gas.api.infura.io`, chainId 1). Powers the Edit Gas Fee sheet: one
  /// authenticated GET returns ready-made Low/Market/High tiers with real
  /// wait-time estimates, network congestion, and historical fee ranges.
  ///
  /// **Required — set via `--dart-define=EVM_GAS_API_URL`; there is no default.**
  /// Unset, this is empty and `getSuggestedGasFees` throws naming the variable
  /// rather than guessing a URL. It used to derive one from [rpcProxyBaseUrl],
  /// which only resolves for a deployment whose proxy also serves the Infura gas
  /// route — anywhere else the guess 404s and the sheet reports a proxy error
  /// instead of a missing config value.
  ///
  /// The failure is non-fatal: the send flow catches it, hides the Edit Gas Fee
  /// affordance, and prices the transfer from the node's own `getFeeData`.
  static String get ethereumGasApiBaseUrl =>
      _env('EVM_GAS_API_URL', const String.fromEnvironment('EVM_GAS_API_URL'));

  /// Endpoint of the EVM simulation surface (`POST` an `eth_simulateV1`
  /// JSON-RPC call). Powers the transfer safety gate: the client simulates the
  /// fully-formed transfer and blocks signing if anything other than the
  /// intended asset would move.
  ///
  /// 🛑 This is a security gate, so it is **required — set via
  /// `--dart-define=EVM_SIMULATION_URL`; there is no default.** It fails
  /// **closed** at every step: unset, `simulateAssetChanges` throws naming the
  /// variable, and configured but not implementing `eth_simulateV1`, it throws
  /// on the non-200. No caller catches either, so EVM transfers stop rather than
  /// proceed unsimulated. That is the intended failure — do not "fix" it by
  /// making the gate optional or by reinstating a default.
  ///
  /// The dropped default was a route on [rpcProxyBaseUrl]. It only resolved for
  /// a deployment whose proxy also serves the simulation route, and silently
  /// aimed a security gate at whatever else answered that path otherwise.
  static String get ethereumSimulationUrl => _env(
    'EVM_SIMULATION_URL',
    const String.fromEnvironment('EVM_SIMULATION_URL'),
  );

  /// Etherscan base for building mainnet transaction links on the EVM
  /// artwork-transfer success screen (`$etherscanBaseUrl/tx/<hash>`).
  static String get etherscanBaseUrl => 'https://etherscan.io';

  // ---------------------------------------------------------------------------
  // Token data services
  // ---------------------------------------------------------------------------

  /// Base URL of the Jupiter API — swap quotes and execution, token metadata,
  /// and token search. Paths below it (`/ultra/v1`, `/swap/v1`, `/price/v3`,
  /// `/tokens/v2`) match Jupiter's own, so a proxy only has to forward.
  ///
  /// Defaults to Jupiter's public API. Override via
  /// `--dart-define=JUPITER_BASE_URL` to route through a proxy that attaches a
  /// plan key or rate limits of your own.
  static String get jupiterBaseUrl {
    final value = _env(
      'JUPITER_BASE_URL',
      const String.fromEnvironment('JUPITER_BASE_URL'),
    );
    return value.isNotEmpty ? value : 'https://api.jup.ag';
  }

  /// Base URL of the CoinGecko API — token prices and OHLC chart data, called
  /// under `/api/v3`.
  ///
  /// Defaults to CoinGecko's public API, which is rate-limited and carries no
  /// paid plan. Override via `--dart-define=COINGECKO_BASE_URL` to route
  /// through a proxy holding a plan key.
  static String get coinGeckoBaseUrl {
    final value = _env(
      'COINGECKO_BASE_URL',
      const String.fromEnvironment('COINGECKO_BASE_URL'),
    );
    return value.isNotEmpty ? value : 'https://api.coingecko.com';
  }

  // ---------------------------------------------------------------------------
  // API Keys (compiled in via --dart-define)
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Web3Auth / MetaMask Embedded Wallets (social sign-in)
  // ---------------------------------------------------------------------------

  /// Web3Auth client ID for MetaMask Embedded Wallets social sign-in.
  ///
  /// Get one at: https://dashboard.web3auth.io
  static String get web3AuthClientId => _env(
    'WEB3AUTH_CLIENT_ID',
    const String.fromEnvironment('WEB3AUTH_CLIENT_ID'),
  );

  /// Web3Auth network name, kept in lock-step with [environment]: dev/staging
  /// on sapphire_devnet, production on sapphire_mainnet.
  ///
  /// Plain string, not the SDK enum, so this file stays SDK-free; the mapping
  /// lives in `SocialAuthService`. The network is part of the key derivation —
  /// switching it later changes every social address, so it must never change
  /// for an environment once live.
  static String get web3AuthNetwork => switch (environment) {
    Environment.development => 'sapphire_devnet',
    Environment.staging => 'sapphire_devnet',
    Environment.production => 'sapphire_mainnet',
  };

  // ---------------------------------------------------------------------------
  // IPFS pinning (NFT mint flow)
  // ---------------------------------------------------------------------------

  /// Endpoint of the IPFS pinning service the mint flow uploads media and
  /// metadata JSON to. Set with `--dart-define=IPFS_UPLOAD_URL`.
  ///
  /// **No default, deliberately.** A pinning endpoint accepts writes, so a
  /// compiled-in one would have every unconfigured build uploading its users'
  /// media into somebody else's storage. Unset, the mint flow reports that
  /// `IPFS_UPLOAD_URL` is missing instead.
  ///
  /// The uploader carries no key of its own: it authenticates with
  /// [clientIdHeadersFor] like every other first-party route, so a deployment
  /// that runs its own pinner must list this host in `FIRST_PARTY_HOSTS`. The
  /// API key this once sent was never a secret — it shipped inside the public
  /// web bundle and inside every app binary, so it kept nobody out — and the
  /// pinner no longer reads it.
  static String get ipfsUploadUrl {
    final value = _env(
      'IPFS_UPLOAD_URL',
      const String.fromEnvironment('IPFS_UPLOAD_URL'),
    );
    return value;
  }

  // ---------------------------------------------------------------------------
  // Jupiter swap (referral fee)
  // ---------------------------------------------------------------------------

  /// Jupiter referral-program account that collects mallow's swap fee.
  ///
  /// Created via https://referral.jup.ag — when unset, no referral params are
  /// sent and Jupiter's default fee applies (mallow collects nothing).
  static String get jupiterReferralAccount => _env(
    'JUPITER_REFERRAL_ACCOUNT',
    const String.fromEnvironment('JUPITER_REFERRAL_ACCOUNT'),
  );

  // ---------------------------------------------------------------------------
  // Chromecast
  // ---------------------------------------------------------------------------

  /// Cast receiver application id, from `--dart-define=CAST_RECEIVER_APP_ID`.
  ///
  /// Identifies the HTML receiver the Cast SDK launches on the TV. It is not a
  /// secret — a sender broadcasts it on the local network — but it names a
  /// *specific* registered receiver deployment, so a fork that ships this
  /// default casts into mallow's receiver rather than its own, on mallow's
  /// bandwidth and under mallow's branding. Register your own in the Google
  /// Cast Developer Console and set this.
  ///
  /// 🛑 The default is deliberate and must stay: unlike a base URL, an empty
  /// receiver id is not a degraded mode — the SDK rejects it and casting fails
  /// with an error that names nothing. Every build gets a working id; a fork
  /// changes which one.
  ///
  /// iOS reads it here and passes it over the cast method channel, because the
  /// Swift plugin initialises the SDK lazily on the first `startDiscovery`.
  /// Android cannot: the Cast SDK instantiates `CastOptionsProvider` itself
  /// from a manifest class name before any Dart has run, so the Android build
  /// decodes this same `--dart-define` in `android/app/build.gradle.kts` and
  /// feeds it in as a manifest placeholder. One variable, two paths, because
  /// the two SDKs decide when to initialise at different moments.
  static String get castReceiverAppId {
    final value = _env(
      'CAST_RECEIVER_APP_ID',
      const String.fromEnvironment('CAST_RECEIVER_APP_ID'),
    );
    return value.isEmpty ? kDefaultCastReceiverAppId : value;
  }

  // ---------------------------------------------------------------------------
  // Analytics & Error Tracking (optional)
  // ---------------------------------------------------------------------------

  /// Build-level analytics enable flag. Analytics is on by default (the mobile
  /// project is separated from web, and dev builds route to a dev project);
  /// set `ANALYTICS_ENABLED=false` to hard-disable a build. The per-user
  /// Settings opt-out is a separate gate layered on top of this.
  static bool get analyticsEnabled {
    final value = _env(
      'ANALYTICS_ENABLED',
      const String.fromEnvironment('ANALYTICS_ENABLED'),
    );
    return value.isEmpty || value.toLowerCase() != 'false';
  }

  static String get sentryDsn =>
      _env('SENTRY_DSN', const String.fromEnvironment('SENTRY_DSN'));

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  /// Validates that all required environment variables are configured.
  ///
  /// Returns a list of missing variable names, or empty list if all present.
  /// The app currently has no hard-required secrets: Solana RPC + DAS traffic
  /// is authenticated by the RPC proxy server-side (see [rpcProxyBaseUrl]), so
  /// no client-side RPC key is needed.
  static List<String> validateRequired() {
    final missing = <String>[];

    return missing;
  }

  /// Validates configuration and throws if required variables are missing.
  ///
  /// Call this during app initialization to fail fast with a clear error.
  static void validateOrThrow() {
    final missing = validateRequired();
    if (missing.isNotEmpty) {
      throw MissingConfigException(missing);
    }
  }

  /// Prints configuration status in debug mode.
  static void printStatus() {
    if (!kDebugMode) return;

    debugPrint('┌─────────────────────────────────────────────┐');
    debugPrint('│  mallow wallet Configuration                │');
    debugPrint('├─────────────────────────────────────────────┤');
    debugPrint('│  Environment: ${environment.name.padRight(28)}│');
    debugPrint('│  API Base: ${apiBaseUrl.padRight(31)}│');
    debugPrint('│  RPC Proxy: ${rpcProxyBaseUrl.padRight(30)}│');
    // Presence only. The key itself is a credential and never reaches a log.
    debugPrint(
      '│  API key: ${(mallowApiKey.isNotEmpty ? "✓ configured" : "not set").padRight(32)}│',
    );
    debugPrint(
      '│  Analytics: ${(analyticsEnabled ? "enabled" : "disabled").padRight(30)}│',
    );
    debugPrint(
      '│  Sentry: ${(sentryDsn.isNotEmpty ? "✓ configured" : "not set").padRight(33)}│',
    );
    debugPrint('└─────────────────────────────────────────────┘');
  }
}

/// Exception thrown when required configuration is missing.
class MissingConfigException implements Exception {
  MissingConfigException(this.missingVariables);

  final List<String> missingVariables;

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.writeln();
    buffer.writeln('┌─────────────────────────────────────────────┐');
    buffer.writeln('│  ⚠️  Missing Required Configuration         │');
    buffer.writeln('├─────────────────────────────────────────────┤');

    for (final variable in missingVariables) {
      buffer.writeln(
        '│  $variable is not configured${' ' * (24 - variable.length)}│',
      );
    }

    buffer.writeln('│                                             │');
    buffer.writeln('│  Please create a .env file with:            │');

    for (final variable in missingVariables) {
      buffer.writeln(
        '│  $variable=your_value_here${' ' * (17 - variable.length)}│',
      );
    }

    buffer.writeln('│                                             │');
    buffer.writeln('│  See .env.example for documentation.        │');

    buffer.writeln('└─────────────────────────────────────────────┘');

    return buffer.toString();
  }
}
