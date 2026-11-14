# Security

How mallow wallet protects keys, gates sensitive operations, and locks the app. This is engineering reference — keep it current with the code.

## Threat model in one paragraph

Local device compromise (lost/stolen phone with no passcode), shoulder surfers, app-switcher leakage, and OS backup exfiltration. Out of scope: physical extraction with privileged tools, malicious OS, supply-chain compromise of dependencies.

## Scope: first-party flows, the in-app browser and WalletConnect

mallow wallet signs two kinds of payload: those its own flows build (the marketplace, mint, send, swap, auction, fixed-price and raffle flows), and those a website asks for. A website asks through one of two surfaces: the **in-app browser** (`lib/features/browser/`), or **WalletConnect** (`lib/features/walletconnect/`) from a page open in another browser or on another device. Both end in the same request coordinator and review sheets. There is no Mobile Wallet Adapter endpoint and no `mallowwallet://` signing intent.

**Consuming Solana Mobile's Seed Vault does not change that.** On Android the app can hold a wallet whose key lives in the device's Seed Vault, and every such signature is produced by the OS after its own approval screen. That is a *key-custody backend the app calls into* — the opposite direction from a signing surface. See *Hardware wallets* below.

The app also opens web pages that are **not** the in-app browser: explorer links, profile links and the About screen use `launchUrl(..., mode: LaunchMode.inAppBrowserView)`. That is `SFSafariViewController` on iOS and a Chrome Custom Tab on Android — an **out-of-process** browser the OS owns, with no JavaScript bridge into the app. The distinction that matters for this threat model is the bridge, not the chrome around the page.

### First-party payloads

Every instruction list a first-party flow signs was assembled by a mallow server or a vetted client builder, so those confirmation sheets optimize for legibility (truncated recipient, amount, fee) rather than adversarial decoding. That assumption holds **only** for those flows; nothing a website supplies reaches them.

### Website requests (in-app browser)

The browser's WebView injects three providers at document start, in HTTPS main frames only: Solana (`window.solana` and the Wallet Standard) and Ethereum (`window.ethereum`, EIP-1193, announced through EIP-6963), and Tezos (`window.tezos` and the Beacon v2 postMessage transport). Each identifies itself as mallow. Every request crosses one native bridge, and the design treats every byte from the page as hostile:

- **Provenance is native.** The origin comes from the platform's frame metadata (WebKit's frame info, Android's `WebMessageListener` source origin), never from the request body, and a per-document token pins each request to the document that was committed. `DappRequestCoordinator` admits a request only from the active tab's current HTTPS main frame.
- **Connection is a per-origin, per-address grant** (`DappPermissionService`, OS secure store). Grants are independent across chains. Provider disconnect revokes its own grant; the browser's Disconnect revokes the grants for all selected wallets. The wallet picker lists Solana, Ethereum and Tezos addresses. Picking an Ethereum or Tezos address within the current Account or Profile changes that provider's wallet and leaves the app's active wallet alone. Picking one under another Account or Profile also switches the app's session to it, including its active wallet; the session prefers a Solana signer when available.
- **HTTP sign-in details are saved automatically in secure storage** through `SecureWalletStorage`, separately from tabs and bookmarks. Saved details are reused for the same HTTPS protection space (host, port, realm and authentication method); a rejected attempt prompts again without deleting them. Closing tabs leaves them saved. Clear browsing data and app reset delete the saved details and the platform's HTTP credential cache, and invalidate pending prompts so they cannot restore cleared passwords. The WebView's own persistent credential database is not used.
- **The lock and backgrounding hide the page but keep it.** An opaque cover replaces the page while the app is locked, away or briefly inactive, so returning finds the page as it was left. Only a full-screen route over the browser, or the OS ending the page's process, rebuilds the WebView and reloads the site. The kept page goes on running: while it is covered, its requests are refused, its alerts and HTTP sign-ins are cancelled without saved details being sent, and a change of site does not switch the app's wallet until the user is back. No tab screenshot is taken then, and every one is dropped on lock.
- **One serial approval lane.** The signer, its capabilities, the network and the payload digest are pinned when a request is admitted; a wallet switch, revocation, navigation, tab change, lock or app background cancels it, and every wait (review, step-up auth, hardware) re-checks before the next step.
- **Native review of decoded effects.** Transactions are simulated and shown as balance changes, permissions and calls (`SimulationReviewSheet`), with evidence marked as simulated or merely requested. A review whose effects were not checked flips the sheet to reject-first with a press-and-hold to approve, on all three chains: the simulation failed, or it could not run at all. "Could not run" counts on purpose. The website that asks for the signature can make a simulation unavailable (a Solana batch above the ten the wallet simulates, a node it keeps busy), so an unchecked request must never be the easier one to approve. A simulation that ran but whose effects the wallet could not decode takes the same hold on Solana and Ethereum; on Tezos it does not, because a Tezos contract call is never fully decoded and a hold there would stand in front of every one. An unavailable simulation (an outage, a batch too large, or no simulation endpoint configured) is still not a block: the review can be signed, with the hold, so the browser stays usable without that service. What it shows is read from the request's own bytes and marked as requested: SOL and token transfers, compressed-NFT moves, approvals, authority changes and accounts created with lamports. A transfer's direction is stated only when the bytes prove it (out when the wallet is the source or the authority, in when the destination is the wallet or its associated token account), and is a neutral row otherwise. Some moves change no balance a simulation can see, so they are read from the instruction whether or not a simulation ran, at the top level and inside another program's call: a compressed NFT's transfer, delegation and burn, a stake account's authorities and withdrawals, a program's upgrade authority and a name's owner. A System or Token instruction the reader could not read is a caution that names the program, but only when the wallet is among its accounts and the instruction is either one the reader has no name for or one of a short list that can move or re-assign holdings. Routine upkeep instructions get none, on purpose: a caution on every ordinary transaction teaches people to ignore cautions. When an optional account is left out of a Bubblegum instruction the program falls back to the payer, and the reader does the same, so a delegation that names no owner is still read as the wallet's. A name shown for an NFT comes from metadata anyone can write, so control and direction characters are removed and it is cut at 64 characters before it is drawn. When a successful simulation finds the network fee and nothing else, the sheet says so in one line and opens the list of programs called. A permission or a change of authority gets a red card, and a red card takes the same press-and-hold: handing someone a lasting right over an asset is the request most worth a second look, whatever the simulation says. That covers every token approval on Ethereum (a revocation is a plain tap), a baker delegation on Tezos, and on Solana every change of authority and every new delegate with a non-zero allowance. A Metaplex Core NFT's transfer, burn and freeze delegates are read from the instruction for this, because granting one changes neither the owner nor any balance; each power is its own card ("Permission to transfer", "to burn", "to lock"). There is one exception, and it asks nothing extra: a change a listed program made itself. That needs all of these: the simulation ran, every program the transaction called is on the published program list, every call that set this delegate or authority came from a listed program's own code, and the one it names is a program-derived address, which no private key can use. Then there is no card and no hold; the approval stays a row, and a change of authority becomes a plain account row so it does not vanish. A program that only passes its caller's choice through never counts as having made it: the System, Token, Token-2022, Token Metadata, Bubblegum, Core, Stake and Name Service programs, the loaders, and the multisig and governance executors. A site that calls one of those directly picks the delegate itself, and could pick an address of a program it deployed. A delegate someone holds the key to always gets the red card. So the published list decides whether a card and a hold appear, though never whether the transaction can be signed. In a batch, each transaction's grants are kept apart: two approvals of one delegate show the one that will stand, never only the smaller. The sheet opens before the simulation finishes, and its placeholder can be approved without waiting for the review, for users who trust the website. That approval takes a press-and-hold, with Reject as the primary action: nothing has been checked yet, and the website can keep it that way by keeping the node busy, so signing unseen must be deliberate. Nobody is made to wait, because once the result is in a clean review is a plain tap again. A batch too large to simulate has no such placeholder approval, and once a result has arrived the placeholder's Approve does nothing, so an unchecked review is never approved by the plain button. Such an approval signs the transaction as received (on Ethereum, once nonce, gas and fee are known; on Tezos, once the node's run has set the operation's limits), and step-up auth is given no value for it, which it counts as over any threshold. The tap Approve of a finished review counts a tap only from 500 ms after it appears, so a review replacing the placeholder under a finger is not approved by that finger.
- **Tezos operations are locally forged.** Mainnet transactions (including contract calls and batches) and baker delegation are supported for HD, imported-key, social and Ledger tz1 wallets. The wallet supplies source, counter and any initial public-key reveal; the website cannot redirect signing to a custom node. Both estimation and the final operation must simulate successfully. A website-chosen fee is refused above 1 XTZ for the whole batch, and the review warns when it is more than 5 times the minimum the operation needs. The review shows XTZ fees and storage burn plus the exact operation fields, and requires extra caution when contract effects are not fully decoded. Tezos message signing accepts packed Micheline text only, preserving its bytes; arbitrary hashes and raw operation payloads are refused. Beacon peers are bound to the native origin, pairing grants no signing access, and transport keys and peers are cleared with browsing data. Requested signing scopes are saved in the origin/address grant. Ledger keys and signatures are checked against the approved tz1 address, and the Tezos Wallet app is required; the Baking app is refused. Cancellation tears down the device connection, and message signing shows a device approval sheet. Silent restores use a previously verified public key and never launch a Ledger connection prompt. Keystone Tezos signing is not supported.
- **Solana off-chain messages are built by the wallet.** `solana:signOffchainMessage` (version 1 of the off-chain message format, sRFC 38) takes the site's text and its required signers, and the wallet builds the bytes itself: the `\xffsolana offchain` signing domain, the version, the signers sorted and without duplicates, and the UTF-8 text. The connected account must be one of the signers. The leading `0xff` can never start a transaction message, so the signature cannot be replayed as a transaction. The review reads the text and the other signers back from the exact bytes that will be signed, and the site gets those bytes back with the signature. Because the wallet builds the message, a Ledger can sign it (Solana app 1.14 or later), where it cannot sign a site's raw `solana:signMessage` bytes.
- **Sign In With Solana is written by the wallet.** `solana:signIn` (version 1.1.0) takes the site's optional fields and the wallet writes the message itself, with the domain defaulting to the page's own host. The request is accepted only if the review's strict sign-in parser reads the written message back to exactly the requested fields, so a line break inside a field, or a statement that reads as a field, is refused rather than shown in part. A domain that differs from the page still gets the mismatch caution. A request naming another account, or one this wallet cannot sign, is refused before anything is shown. When the page is not yet connected, the ordinary connection sheet comes first and the sign-in review second, and approving the connection keeps it even if the sign-in is then rejected. With `useOffchainMessage` the message is wrapped in a version 1 off-chain message whose only signer is the account. A Ledger can sign in only that way.
- **Signatures are verified before they leave.** Each signature is checked against the approved address (Ed25519 verification on Solana and Tezos, ecrecover on Ethereum), and a signed Ethereum transaction must carry exactly the reviewed fields, so a hardware reply or a derivation mix-up cannot sign from another account.
- **Kill switches and step-up auth apply.** All three chains use the `browser-transaction` and `browser-message` cells, checked first in `TransactionAuthGate.authorize`. A review whose value cannot be priced counts as over the step-up threshold, and a message request always has no value, so with step-up auth on every website message prompts.
- **The first-party UI channel signs nothing and is granted natively.** Pages on the web app's own origins — exactly `https://mallow.art` and `https://www.mallow.art`, on the default port, built into the app rather than configured — also get `window.mallow.ui`: the wallet's theme, and a fire-and-forget `setOverlay` that dims the browser chrome under the page's own bottom sheet. The grant script runs before any page script and checks the document's own origin (on Android the WebView's origin rules gate it too), so a page cannot opt itself in. Every `ui` message is checked again against the committed origin and document token and is otherwise dropped; it never reaches the approval lane. A tap on the dimmed chrome, or Android's back while the chrome is dimmed, is forwarded to the page and does nothing native. Only the page lifts the dim, and the wallet sets no timeout of its own, because a sheet that is locked while its transaction is pending ignores taps and back on purpose. The dim never outlives the document: any navigation or reload ends it, and a user facing a page that never lifts it can always leave the app and return, which restores the chrome and keeps the page. No other subdomain qualifies, because a subdomain can serve anyone's uploads. A development build (`ENV=development`) also grants the channel to local and private addresses over `https` on any port — `localhost` and its subdomains, mDNS `.local` names, Tailscale MagicDNS names, and loopback, private-range, link-local and Tailscale IP addresses — so a developer can run the web app on their own machine; on Android its script then runs on every origin and only the in-page and native origin checks decide, because the platform's origin rules cannot express an address range.

### Website requests (WalletConnect)

A website open elsewhere connects through WalletConnect v2, on Reown's core and sign SDKs (not their WalletKit, which links a payments plugin with its own native binaries). The feature exists only in a build with `WALLETCONNECT_PROJECT_ID` set, and it shares the browser's remote switch. Its threat model differs from the browser's in one way that drives everything else: **the website's identity is its own report.** No WebView commits an origin; the name, URL and icon arrive in the website's proposal.

- **A pairing link is a secret.** A `wc:` URI carries the key that encrypts its pairing, so whoever holds it first can answer the website's proposal. It reaches the app as a QR code (the browser's start screen, its settings, or the send scanner), a pasted link, a `wc:` or `mallowwallet://wc?uri=…` deep link, or a `wc:` navigation by the in-app browser's main frame (on Android, only from a tap; any other frame's link is dropped). Every path hands it straight to WalletConnect: `DeepLinkService` takes it before anything logs, `lib/features/walletconnect/` is a guarded path of `tool/lint/check_sensitive_debug_print.sh`, and an SDK error is never shown, because its text can quote the URI.
- **Verify, then the user.** WalletConnect's Verify service reports whether the request came from the domain the website names. A website it reports as malicious is refused without a prompt. One it could not match is shown with a warning and needs a press-and-hold *Connect anyway*. Unverified ones say so. The website must report an HTTPS URL; it is reduced to its origin, which every later review shows.
- **A session is bound to the wallets approved with it.** The proposal sheet picks one wallet per network from the current Account or Profile. Later requests sign with that wallet whatever wallet is active, because a session outlives any one screen and a signer that followed the active wallet would sign for an address the website never saw. The app keeps its own record of each session's approved addresses: the SDK accepts a `wc_sessionUpdate` that rewrites a session's accounts without checking that the wallet sent it, so a session whose accounts no longer match that record is ended rather than trusted. A session whose wallet leaves the device is ended too. A website can still extend its own session (`wc_sessionExtend`); Disconnect in Browser settings ends it.
- **Grants never cross surfaces.** Each session gets its own `DappRequestCoordinator` and an in-memory grant store holding exactly the approved addresses, so a website reached by WalletConnect never inherits, or leaves behind, a browser connection for its claimed origin.
- **The same lane, limits and review.** Requests go through the coordinator as browser requests do: payload limits, duplicate rejection, the 3-minute timeout, the pinned signer, simulation and review, the `browser-transaction` and `browser-message` kill switches and step-up auth. `eth_sign` is not offered. Every method maps onto a browser method; nothing is signed that the browser would refuse.
- **Nothing shows while the app is locked or away.** Proposals and requests that arrive then wait and are taken up in order once the user is back, unless the request has expired by then (five minutes, the website's own wait), in which case it is never shown. Locking the app cancels a request in review, and an approved one that is still signing stops at the lock or at its expiry. A rejection reaches the website as WalletConnect's standard `5000`.
- **Storage.** The key chain (each pairing and session key, and the client's identity seed) is kept only in the OS secure store, as one entry readable while the device is unlocked; on Android in a namespace of its own that is never reset on a read error, so a decryption failure there cannot wipe the app's other entries. The SDK's own store falls back to shared preferences when the keychain fails; the app replaces that store with one that fails instead. Sessions, pairings and pending requests stay in shared preferences, as the SDK keeps them: they name the connected websites and hold no key. App reset ends every session and erases both.
- **No SDK telemetry.** The core posts usage events to Reown's events server and offers no setting to stop it; the app replaces that component with one that sends nothing. The relay (and Verify) still see the device's IP address and which websites it connects to, as with any WalletConnect wallet.
- **A device that never pairs never connects.** The relay socket opens on the first pairing, and at launch only on a device that has paired before.

Ethereum specifics:

- Mainnet only. `wallet_switchEthereumChain` to anything else fails with 4902, and a transaction or typed-data domain naming another chain is refused.
- `eth_sign`, `eth_signTypedData` v1/v3 and `eth_signTransaction` are not offered: `eth_sign` signs an arbitrary hash and is the classic drain. A WalletConnect session also lists the bare `eth_signTypedData` name, because websites send v4 data under it; it is parsed strictly as v4, so v1/v3 semantics stay unreachable. EIP-7702 authorizations, blob transactions and contract deployments are refused before review.
- `eth_signTypedData_v4` is parsed strictly by a native EIP-712 encoder (no undeclared or missing fields, no lossy JSON numbers) and the review is built from the parsed values whose digest is signed. EIP-2612 permits and Permit2 signatures are shown as spending permissions and marketplace orders as orders, both behind a press-and-hold. Ledger wallets sign typed data on the device: the Ethereum app is sent the same parsed values and computes the digest itself, and the returned signature must recover to the wallet's address over the digest the review was built from. The Ethereum app requires its Raw messages setting (which shows every field) or its Blind signing setting (which shows the domain and the message hash) to be on. Apps older than 1.9.19 sign the domain and message hashes, which the review shows under Exact data and digest.
- `personal_sign` uses the same message review as Solana, with a strict Sign In With Ethereum (EIP-4361) parser: a message that does not fit the grammar exactly is shown verbatim.
- A page's read-only calls (`eth_call`, `eth_getBalance`, …) go through the wallet's configured Ethereum node, restricted to an allowlist. A node error never reaches the page verbatim; only revert data does.
- The nonce is always the wallet's own. A website's fee suggestion is used within a cap, otherwise the user's saved Low/Market/Advanced tier applies, and the review's Speed row opens the same Edit Gas Fee sheet as the app's own sends. A new fee re-prices the reviewed transaction without re-simulating it (the simulation does not depend on the fee), and the signed bytes are checked against the re-priced version. A broadcast is registered with the pending-transaction list, so it can be sped up or cancelled like the app's own sends.

## Deep linking & verified links

> Resolves the unverified-deep-link hazard: `mallowwallet://` could be claimed by any other app.

**The hazard was:** the wallet's only inbound link surface was the `mallowwallet://` custom scheme, and everything rode on it — content links and the social-auth callback alike. Custom schemes are first-come-first-served on both platforms — any other installed app can register `mallowwallet://` and receive links meant for this one. There is no OS-level ownership proof.

**The migration (shipped in-app):** every link that the app *acts* on now arrives over an OS-**verified** deep link on `mallow.art`:

- **Android App Links** — `AndroidManifest.xml` declares an `<intent-filter android:autoVerify="true">` for `https://mallow.art` over the content paths. Android verifies domain ownership against `https://mallow.art/.well-known/assetlinks.json` (must list `com.mallow.wallet.android` with the installed build's signing-cert SHA-256).
- **iOS Universal Links** — `Runner.entitlements` / `Runner-Release.entitlements` declare `applinks:mallow.art`. iOS verifies against `https://mallow.art/.well-known/apple-app-site-association` (must contain an `applinks` block with `YOUR_APPLE_TEAM_ID.com.mallow.wallet.ios`).
- **`mallowwallet://` is demoted to a non-sensitive surface** — it carries the browser handoff (`mallowwallet://browser/open`, below), the WalletConnect wrapper (`mallowwallet://wc?uri=…`, see *Website requests (WalletConnect)*), the fallback form of the X connect callback (`mallowwallet://auth/callback?twitter=…`, below) and serves as an unverified-link fallback. No content link depends on it, no sign-in redirect uses it, and nothing on it signs: the WalletConnect wrapper only starts a pairing, which the user must approve before the website can send any request. It was deliberately kept rather than removed.

**No sign-in answer reaches the app's link handler through a custom scheme.** Google sign-in runs in Google's native sheet on both platforms, and Apple sign-in in Apple's native sheet on iOS. The iOS build does register one more URL scheme, the reversed Google client id (`ios/scripts/google_sign_in_plist.sh` writes it into `Info.plist` from `GOOGLE_IOS_CLIENT_ID`), because Google's SDK requires it. The redirect on that scheme is consumed inside the system's web-authentication session that Google's SDK opens. A link on it that did reach the app's own handler is ignored: `DeepLinkService.isTrustedOrigin` accepts only `mallowwallet://` and the site's HTTPS origin. Android has no native Apple sign-in, so there the app runs Apple's web flow itself, and the answer comes back through a verified App Link (next paragraph). The app once registered `mallowwallet://auth` as the OAuth redirect of a sign-in SDK (Web3Auth) and dropped that redirect on sight in `deep_link_service.dart`. The SDK is no longer in the app, so the redirect, its registration with the provider and the branch that dropped it are gone with it. What is left of the `auth` path:

- **`mallowwallet://auth/callback?twitter=…` is the X connect callback's fallback form, and nothing else uses the `auth` host.** The website's `/auth/callback` page links to it when the app link below opened in the browser instead of the app. `deep_link_service.dart` gives it no branch of its own: it is a trusted-origin link with a `twitter` parameter, so it reaches the same handler as the app link, by the same steps. Any app can send it, which is why the handler acts only on what the next bullet describes.
- **The `https://mallow.art/auth/callback` app link is no longer part of social sign-in — but it is still live, for a different flow.** Social login used it as the Reown link-mode callback, and Reown is gone; the path now serves the **X (Twitter) connect** round trip only. The backend `/v2/twitter/callback` finishes that OAuth exchange server-side and redirects to `https://mallow.art/auth/callback?twitter=confirm&token=…` (or `?twitter=error|error_user_exists`). The callback does not link the account: `TwitterConnectNotifier` does, on the signed `POST /v2/twitter/complete`, which links only for the wallet that started the flow — and only when this install has a connect the user started in the last 30 minutes (room for X's sign-in and the completion that follows), since any page can open the link. The outcome goes to the open `EditProfileScreen`. **The `pathPrefix="/auth/callback"` entry in `AndroidManifest.xml` is therefore load-bearing, not a Reown leftover — do not delete it.** Removing it breaks X connect on Android silently: the browser round trip still succeeds, the app never receives the result, and no test fails (`deep_link_service_test.dart` hands the URI to the handler directly, so it never exercises the manifest).

**Sign in with Apple on Android returns through a verified App Link, and only through one.** `AppleWebSignIn` (`lib/core/social_vault/apple_web_sign_in.dart`) opens Apple's authorize page in a Custom Tab with a random 128-bit `state` and the SHA-256 of a random nonce. Apple form-posts the result to the backend's relay (`API_V2_BASE_URL` + `/social-vault/apple/callback`), which answers `303` to the site's `/auth/apple` page with the posted fields in the URL **fragment**. `AndroidManifest.xml` claims that exact path with `android:autoVerify="true"`, so Android hands the link to this app — and only to a package whose signing certificate the site's `assetlinks.json` lists. That is the point of the design: the link carries an ID token, and a package name alone (which an `intent://…;package=` redirect or a custom scheme would rely on) is not proof of who built the app.

- **There is no custom-scheme path into this flow.** The sign-in plugin's exported `signinwithapple://callback` activity is gone from the manifest, and `mallowwallet://auth/apple` is not a form of the link: `DeepLinkService.isAppleReturnLink` matches `https`, the site's host and the path, exactly.
- **The link is taken before anything else can see it.** It is the first check in `DeepLinkService`, ahead of the debug log line, the origin check, the handler registry and the route map, and it is never logged, routed or stored.
- **An answer is accepted only for a sign-in this app instance started.** With none waiting — a cold start, a duplicate, an answer after the timeout — the link is dropped. A link whose `state` is not the waiting request's (compared in constant time) is dropped too, *without ending the request*, so a forged link cannot cancel a sign-in. An `error` field ends the request as a cancel.
- **The token must carry this request's nonce.** The app decodes the ID token's payload for one comparison — its `nonce` claim against the hash this request sent — and refuses a mismatch, which stops a substituted token even from someone who learned the `state`. It verifies nothing else: the backend does.
- **A request never hangs.** It ends as a cancel after five minutes, or a few seconds after the app is back in front with the tab gone and no answer.
- **What the fallback web page does.** When Android does not hand the redirect to the app — verification is unhealthy on that device, or the browser kept a redirect it did not see a tap behind — the browser opens the site's `/auth/apple` page instead. The fields are in the fragment, which a browser sends to no server and which appears in no access log. The page is a static file outside the web app's bundle (no analytics, no error reporting): it takes the fragment out of the address bar and the history entry, parses, stores and sends nothing, and offers one button, "Open the mallow app", which is the same `https` link again. A tap is a new navigation, which Android can hand to the app — through the same verified link and the same checks above, never a custom scheme. If that does not open the app either, the user closes the tab and the sign-in ends as a cancel.
- **Dependency, stated plainly:** Apple sign-in on Android works only while App Link verification is healthy for the installed build. Each Android package (`play` and `dappstore` are two) needs its own statement in `assetlinks.json` with the certificate that signs it — see *Operational dependency* below. A build whose statement is missing or stale cannot complete an Apple sign-in; Google sign-in and every other wallet are unaffected.

Inbound links are handled by `lib/core/services/deep_link_service.dart`, which, in order:

0. hands the Sign in with Apple return (`/auth/apple` on the site, above) to the waiting sign-in, before every other step;

1. hands a `wc:` or `mallowwallet://wc` link to WalletConnect (see *Website requests (WalletConnect)*), never logged or routed; the OS replay of a cold-start link is dropped rather than paired twice;
2. opens a browser handoff, `mallowwallet://browser/open?url=<https URL>`, in a new in-app browser tab;
3. offers the link to the `DeepLinkHandlerRegistry`, where a feature can claim a path the route map does not know;
4. publishes the X (Twitter) connect callback, in either of its two forms;
5. maps a closed allow-list of `mallow.art` paths (`/artwork`, `/collection`, `/u`, `/a`) to in-app `go_router` locations.

Steps 3–5 are gated on `isTrustedOrigin`; steps 1–2 run ahead of it and ahead of the debug log line, because a WalletConnect link carries its pairing key, and a shared page's query or fragment can hold private data. That log line exists in debug builds only. The deep-link plugin has a log line of its own, though: its Android half writes every link it delivers to the system log at debug level, whole. Release builds therefore strip every `Log.d` and `Log.v` call at build time (`-assumenosideeffects` in `android/app/proguard-rules.pro`, applied by R8 to the app and every library compiled into it), so neither the Apple return's ID token, the X callback's completion token nor a WalletConnect pairing key is written to a release build's platform log. A debug build is not minified and does log them. Unknown paths are ignored, so an arbitrary link can never be turned into an in-app navigation.

**The browser handoff is one of two custom-scheme links that do something, and any app can send it.** (The other is the WalletConnect wrapper above, which any app can send too; it leads only to the proposal sheet.) The Android share target (`ShareTargetActivity`) and the iOS *Open in mallow* share-sheet action (`ios/OpenInMallow/`) produce it when the user shares a page to the wallet, but nothing proves the sender. So `browserOpenLinkUrl` accepts exactly one `url` parameter that must be an `https` URL with a host and no embedded credentials, and refuses whitespace, a port or fragment on the outer link. All it can do is load a page: the page gets no connection grant it did not already have, and every request it makes goes through the approval lane described under *Website requests*. The URL is never logged.

**The handler registry is inert until something registers.** With no handler, every link carries on to steps 5 and 6. A handler sees only links that passed `isTrustedOrigin`, and one that returns `true` consumes the link. It is a singleton of its own, not a field of `DeepLinkService`, because the app rebuilds that service on every boot and a registration made at startup has to outlive it.

**Operational dependency — verification is not self-healing.** App Links / Universal Links only protect users while the hosted association files match the installed app's package/bundle id **and** signing cert. A signing-cert rotation or a stale production deploy of `.well-known` silently drops verification back to the website fallback (no crash, no warning). Re-verify after any cert rotation or association-file change: confirm `assetlinks.json` lists the SHA-256 fingerprints of **every** cert that signs shipped builds — including the **Play App Signing** key from Play Console → App signing, not just the upload key (rotating the upload key but forgetting the Play fingerprint breaks links for store users while local builds keep working) — and that the AASA `applinks.details[].appIDs` still contains `YOUR_APPLE_TEAM_ID.com.mallow.wallet.ios`, then spot-check a fresh install actually opens an `https://mallow.art` link in-app. The association files are hosted alongside the website, not in this repository, so this hazard's mitigation spans two systems.

**There are now two Android packages, and each needs its own `assetlinks.json` entry.** The Android build has two product flavours: `play` (`com.mallow.wallet.android`) and `dappstore` (`art.mallow.twa`, the Solana dApp Store artifact). A different `applicationId` is a **separate statement in `assetlinks.json`, not another fingerprint under the existing one** — Android matches a statement by package name first, so a fingerprint filed under the wrong package verifies nothing and fails in exactly the silent way described above. The dApp Store APK is signed with its *own* keystore (`dappstore-key.properties`; never the Play upload key, which the dApp Store's publishing rules forbid sharing), so it is a different certificate from both the upload key and the Play App Signing key Google re-signs the store build with; the `art.mallow.twa` statement must list that key's SHA-256. A fork shipping a second flavour needs the same: one statement per package, carrying the fingerprint of the key that signs it.

## Secrets at rest

All sensitive material flows through `SecureWalletStorage` (`lib/core/security/secure_storage.dart`). **Never write a key, mnemonic, PIN, or token to `SharedPreferences`, `NSUserDefaults`, or a plain file as plaintext.** The only thing that may be persisted outside an OS keystore is ciphertext whose decryption key lives inside one — which is exactly what the Android vault below does, and why it is not an exception to this rule.

### Two stores behind one class

`SecureWalletStorage` fronts two different backends, and the split is the part most readers get wrong:

| What | Store | Whose native code |
|---|---|---|
| Mnemonics (`storeMnemonicForSeedPhrase`; the legacy single-mnemonic key has no writer left — `storeMnemonic` was deleted as dead — and is only read by `hasWallet` and the Restore screen's fallback, and erased by the wipes), imported private keys (`storePrivateKey`), the recovery graph (`storeAccountGraph`), the PIN hash (`storePinHash`), the biometric-enabled flag (`storeBiometricEnabled`), the backup copy of the DB encryption key | `MnemonicVault` (`lib/core/security/mnemonic_vault.dart`) | ours, in this repo |
| A social vault's data key and recovery phrase (`storeSocialVaultDataKey`, `storeSocialVaultMnemonic`), and the data key set aside for a vault the backend says it does not have (`storeSocialVaultRetiredKey`) | `MnemonicVault` | ours, in this repo |
| A social vault's platform-slot secret — the one secret here that syncs, on purpose (see *Social wallets*) | iCloud Keychain / Block Store, through `PlatformSlotStore` | ours, in this repo |
| Login/auth tokens, session expiry, wallet-sig JWT cache, selection pointers, the onboarding flag, Ledger device ids, PIN-lockout counters, step-up-auth preferences, per-chain network flags, the primary DB encryption key | `flutter_secure_storage` | the plugin's |

**A hardware wallet's key is in neither store — and a Seed Vault wallet leaves nothing behind at all.** A Ledger row puts a device id in the plugin store, which names a BLE peer rather than a secret. A Seed Vault row (Solana Mobile, Android) stores nothing: the seed lives in the OS's own Seed Vault, every signature is produced there behind its approval screen, and mallow persists no Seed Vault secret of any kind. **The seed's auth token is deliberately not persisted either.** It is not stable — it changes on deauthorize/re-authorize, and an invalid token is a first-class result code — so a stored one is a stale capability handle waiting to fail. `SeedVaultService` (`lib/core/services/seed_vault_service.dart`) instead resolves it live on every signing call by reading the vault's own content provider, which raises no UI, matching the wallet's address against the `publicKeyEncoded` the vault reports; the result is cached in memory for the process lifetime only, and re-resolved exactly once if the token is rejected. That buys three things: no new secret at rest, no database migration, and a wallet that heals itself the moment the user re-authorizes the seed.

`storeMnemonicForSeedPhrase`, `storePrivateKey`, `storeAccountGraph`, `storePinHash` and `storeBiometricEnabled` call `_vault.write` — **not** the plugin. The matching reads go through `_vaultReadWithMigration`, which falls back to `flutter_secure_storage` once for installs that predate the vault, migrates the value across on first access, then deletes the legacy item. Three details of that path are load-bearing:

- **The legacy read turns the Android self-heal off** (`_androidOptionsNoReset`, `resetOnError: false`). With it on, an entry the plugin cannot decrypt is *deleted* and reported as null — a transient decrypt failure would destroy the only copy and answer "never stored". Off, it throws, and the callers read a throw as "unknown".
- **A failed migration still returns the value it read.** The vault write and the legacy delete are wrapped in a try/catch that logs; the legacy copy survives a failed migration, because the delete runs only after the write succeeded.
- **Writes are vault-first, then a best-effort drop of the legacy copy** (`_vaultWriteDroppingLegacy`). The vault write is update-or-add, so nothing is deleted before the new value is stored; dropping the legacy copy afterwards is what stops the migration reading a stale value back later. `deletePin`, `deleteBiometricEnabled` and `deleteAccountGraph` delete from **both** stores.

**Why the graph, the PIN hash and the flag moved into the vault.** The plugin store has two failure modes that destroy data (see *Everything else* below), and all three values are unrecoverable if lost: the graph is the only index of the vault's per-seed mnemonics — losing it orphans every dormant seed, and after an iOS reinstall every seed — and losing the PIN hash drops the mandatory app-lock floor (`AppLockBloc` reads `noPinSet` and the app opens unlocked). `_write`, the plugin-store writer, carries a warning to match: nothing load-bearing may be stored through it. What stays there is re-creatable by a fresh login, a fresh onboarding or the next graph sync.

### The vault — mnemonics and private keys

`MnemonicVault` is a `MethodChannel('art.mallow.wallet/mnemonic_vault')` with one native implementation per platform.

- **iOS** (`ios/Runner/MnemonicVaultChannel.swift`) — a `kSecClassGenericPassword` Keychain item under the service `art.mallow.vault`, deliberately distinct from the `mallow_wallet` service the plugin uses so the two key spaces cannot collide. `kSecAttrAccessible` is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; `kSecAttrSynchronizable` is never set. No `SecAccessControl` is attached, so a read is a plain `SecItemCopyMatching` with **no OS biometric/passcode prompt**, and a write has no device-passcode precondition. Writes are **update-or-add** (`SecItemUpdate` when the item exists, `SecItemAdd` otherwise): a failed write leaves the old value. They used to be delete-then-add, where a failed add — `errSecInteractionNotAllowed` while locked, for one — destroyed the stored secret. `listKeys` enumerates every account under the service; only the explicit wipes and the DB-key re-mint diagnosis use it. `delete` reports any status other than success or not-found as `delete_failed`, so an explicit wipe records a failure per step instead of reporting "clean" with a mnemonic still in the Keychain.
- **Android** (`android/app/src/main/kotlin/com/mallow/wallet/android/MnemonicVaultChannel.kt`) — a **per-secret AES-256-GCM key in AndroidKeystore** (alias `mallow_vault_<key>`; hardware-backed on any device with a TEE or StrongBox). `vaultWrite` encrypts the plaintext with that key and persists **only the Base64 ciphertext and IV** (`ct_<key>` / `iv_<key>`) in an ordinary `MODE_PRIVATE` SharedPreferences file, `mallow_vault_prefs`. The prefs edit is `commit()`, not `apply()`, and a failed commit answers `write_failed`: the caller writes the wallet row and the recovery graph as soon as the write returns, so the ciphertext has to be on disk first — an async `apply()` lets a kill leave a row whose secret never landed. The Keystore key is generated **without** `setUserAuthenticationRequired`, so decryption needs no `BiometricPrompt` and no device lock screen — onboarding succeeds on a device with nothing enrolled. `vaultDelete` removes both prefs entries *and* the Keystore alias.

**Why the persisted Android blob is worthless on its own — and why this is not a violation of the rule above.** What lands in `mallow_vault_prefs` is AES-256-GCM ciphertext plus its nonce, never the secret. The key that decrypts it is generated *inside* AndroidKeystore and is **non-exportable**: no API hands its bytes to this app or to any other, so the ciphertext can only be decrypted by a caller the OS permits to use that alias — this app's UID, on this device. Lift the prefs file off the device and you have an opaque blob: the key never leaves the device, and it is destroyed when the app is uninstalled. GCM authenticates as well as encrypts, so a tampered blob fails to decrypt rather than decrypting to attacker-chosen bytes. The rule bans *plaintext* in SharedPreferences; sealing the value under a hardware-held key is the mitigation for that rule, not an exemption from it. For completeness, `flutter_secure_storage` does the same thing on Android — its ciphertext lives in a SharedPreferences file too (see below).

**Neither platform prompts on a vault read or write.** That is deliberate and is stated in all three implementation files: the user-facing gate over this data is the app's own dual-lock (PIN and/or biometric app-lock, `AppLockBloc`), not an OS prompt. The two platforms differ in one respect worth knowing: the iOS item is unreadable while the device is locked (`WhenUnlocked…`), whereas the Android Keystore key carries no `setUnlockedDeviceRequired`, so a running app process can decrypt regardless of lock state.

### Everything else — `flutter_secure_storage`

Platform configuration lives in `SecureWalletStorage._iosOptions` and `_androidOptions`:

- **iOS:** Keychain with `KeychainAccessibility.unlocked_this_device` (= `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), service `mallow_wallet` (the plugin's `accountName` maps to `kSecAttrService`). The `*ThisDeviceOnly` variant is **not** synced to iCloud Keychain and **not** included in iCloud/iTunes device backups. `synchronizable` is never set.
- **Android:** the v10 defaults — **AES-GCM** data encryption under an **RSA-OAEP(SHA-256/MGF1)-wrapped** AndroidKeystore key, with the resulting ciphertext in the plugin's own `FlutterSecureStorage` SharedPreferences file. **Jetpack Security's encrypted-preferences store is not used, and as of v10 is not even an option:** Google deprecated that library, so v10 ignores the legacy `encryptedSharedPreferences` flag entirely and instead reads pre-v10 entries through `migrateOnAlgorithmChange` — pinned `true` here so a future default flip cannot silently strand a pre-vault seed. `resetOnError: true` recreates the store when its Keystore master key is invalidated or corrupted rather than throwing. Keystore-wrapped keys are non-exportable and not included in Google Drive Auto Backup. The manifest sets `android:allowBackup="false"`, `android:fullBackupContent="false"`, and a `data_extraction_rules.xml` that excludes all domains — Android preferences and the on-disk SQLite cache will not restore from a backup after upgrade or device transfer. The manifest also wires `android:networkSecurityConfig="@xml/network_security_config"` enforcing HTTPS-only (`cleartextTrafficPermitted=false`) with a debug overlay that trusts user CAs so Charles/Proxyman work in debug builds; cleartext is permitted only to loopback (`localhost`, `127.0.0.1`, `10.0.2.2`) to preserve local-dev workflows. Certificate pinning is not configured yet; it will land in the same config.

**Two hazards live in this store, and they are why nothing load-bearing may be kept here.**

- **iOS: an overwrite is delete-then-add.** The plugin implements a write over an existing item as `containsKey` → `SecItemUpdate` → *on any non-success status* `SecItemDelete` followed by `SecItemAdd`. Its update query carries `kSecReturnData`, which `SecItemUpdate` does not accept, so the update never succeeds and every overwrite takes the delete-then-add branch. A kill between the two, or an add that fails (`errSecInteractionNotAllowed` while the device is locked), leaves nothing stored. The app's own vault deliberately does the opposite — update-or-add, never delete before add.
- **Android: `resetOnError: true` deletes what it cannot read.** An entry the plugin fails to decrypt is deleted and reported as `null`; an error during `readAll` clears the whole store. That is a usability self-heal, and for a re-creatable token it is the right trade. For a secret it is data loss reported as absence, which is why the one read that must not trade a secret for usability — the legacy fallback in `_vaultReadWithMigration` — passes `resetOnError: false` and lets the failure throw.

Net result: seed phrases and private keys are **not** part of any cloud backup on either platform. A device restore requires the user to re-enter their recovery phrase. The one exception is the social vault's platform slot: a random slot secret, not a key, which opens nothing without the vault ciphertext the backend serves only to the user's Google or Apple sign-in.

### Social wallets have a different custody model — say so, do not blur it

Everything above describes a wallet the user **created or imported**: the key is generated or typed
on the device, and nothing can reproduce it elsewhere.

A wallet that came from **Google or Apple sign-in** is different, and there are **two kinds, with
two custody models**. They must never be described in each other's words:

| | Social vault wallet | Wallet from the older sign-in |
| --- | --- | --- |
| Made by | The Google and Apple buttons in this app, and the website's current sign-in | The sign-in the app used before the vault, run by Web3Auth. This app no longer contains it |
| What it is | A 12-word recovery phrase in a **social vault** | Two raw keys Web3Auth derives for the Google or Apple identity |
| What a takeover of the Google or Apple account gets | Ciphertext it cannot open | **The wallet.** The account alone reproduces the keys |
| How the app marks it | The plain Google or Apple icon | The same icon with a small mark at its bottom right (Web3Auth's logo, white on a blue disc), and the sentence "Older sign-in, run by Web3Auth: your Google account alone can open this wallet." |
| In the code | `WalletInfo.isLegacySocialWallet` is false; `socialVaultId` on its rows while it has a backup | `WalletInfo.isLegacySocialWallet` is true |

There is **no migration** between the two. A wallet from the older sign-in is never placed in a
vault, and nothing in the app calls it backed up or protected by a passkey; the Google and Apple
buttons never look for one, so a person who has one and taps them gets a new, empty vault wallet.
The sign-in sheet does not mention the older sign-in: it does not apply to a new wallet. Someone
trying to restore one is helped by support.

#### Social vault wallets

The wallet lives in a **social vault** (`lib/core/social_vault/`), which the backend stores and
cannot open. It is designed to come back on a new device.

- **What the backend holds.** The wallet secret sealed with AES-256-GCM under a random 32-byte
  **data key**; that data key wrapped once per **slot**; each passkey slot's PRF salt and credential
  id; and the public half of a **vault key** (Ed25519, derived from the data key). Ciphertext,
  wrapped keys and public values only. No request the app makes can carry the data key, a slot
  secret, a PRF output, the recovery phrase or a private key — the generated request models have no
  field for one.
- **What the secret is.** Always a BIP39 recovery phrase (`{"v":1,"kind":"bip39",…}`): format v1
  has no other payload kind, and a payload of any other kind is refused with an error rather than
  read (a misread payload derives a different wallet, silently). The phrase has one spelling —
  trimmed, lower-case, single spaces — and one function produces it
  (`SocialVaultCrypto.normalizeMnemonic`) wherever a phrase is sealed, read out of a payload or
  turned into keys. BIP39 hashes the phrase as text, so a payload another client sealed with a
  double space or a line break must read as the same words here, not as another wallet or as no
  phrase at all; the shared vectors carry such a payload (`nonCanonicalPayload`).
- **What opens it.** A fresh Google or Apple **ID token** locates the vault (the backend verifies it
  and returns the ciphertext; the app never asks for an access token). Opening it needs one slot,
  and every slot secret stays with the user:
  - the **platform slot** — 32 random bytes in iCloud Keychain (a synchronizable item, its own
    service, `kSecAttrAccessibleWhenUnlocked`, `ios/Runner/SocialVaultSlotChannel.swift`) or
    Google Block Store with end-to-end encrypted backup (`SocialVaultSlotChannel.kt`, created
    only when `isEndToEndEncryptionAvailable()` is true, and re-checked ever after: see *The
    Android phone backup is re-checked* below). One entry per (vault, slot), add-only: devices
    sharing one iCloud account or Google backup each add their own, and an entry is deleted only
    once its slot is gone. This reopens the wallet silently after a reinstall. It is **not** a
    general backup: on iOS it reaches other devices only while iCloud Keychain is on for that
    Apple ID; on Android, Block Store restores it only while a new phone is being set up from
    this one's backup, not later. A vault with a platform slot and no passkey is therefore not
    called "backed up" anywhere in the app, and a banner stays on Home until it has a passkey
    (or, on a device that cannot add one, until the user acknowledges the limit).
  - a **passkey** — the WebAuthn PRF output of a passkey on `PASSKEY_RP_ID`, recomputed by the
    authenticator at every unlock. It is what opens the wallet on the web and across platforms.
- **What a Google or Apple account takeover gets.** The ciphertext, and nothing else: without a slot
  it cannot be opened, and without the data key nothing about it can be changed — every write after
  creation (add or remove a slot, delete the vault) must carry a vault-key signature over the method,
  path, vault id, revision, body hash and time. An attacker with the account *and* the user's
  synced iCloud Keychain or Google backup, or one of their passkeys, does get the wallet. That is
  the trust model, stated plainly: the wallet is as safe as the user's Apple/Google device backup
  and passkey provider, not as safe as a phrase on paper. "Your Google account alone can never open
  it" is said of these wallets only.
- **What a lost Google or Apple account costs.** The vault can no longer be located, so the wallet
  survives only where a device still holds it or where the user exported it. **An exported recovery
  phrase is the only recovery** — Show secrets lists it behind the same re-auth gate as every other
  secret.
- **A first sign-in always makes a new wallet — after the user says so.** An identity with no vault
  gets a fresh phrase in a new vault. Nothing is looked up about the identity anywhere else first:
  no older-sign-in login, no history check. But "this account has no wallet" is as often the wrong
  account as a new user, so nothing is created until the user confirms ("No mallow wallet found
  for <email>. Create one?"). When the device already holds a wallet with sign-in keys for that
  provider, the sheet warns instead — this account has no wallet, the one here belongs to that
  account — and leads with "Use another account", which signs in again with an account chooser.
  Declining creates nothing and stores nothing. `open` itself is believed about "no vault" only
  when the answer says it outright: a response without the `vault` field, or with a vault missing
  what a vault carries, is an error (`SocialVaultApi.requireWellFormedOpen`).
- **A vault link names the sign-in identity it belongs to.** `open` returns an opaque, stable
  `identityId` for the account that signed in (not an email, and not derived from one; the app
  never computes it). It is stored with the vault id on every row of the wallet
  (`Wallets.socialIdentityId`) and in the recovery graph, so it survives the loss of the keystore
  and of the plugin store, and it is refreshed at every sign-in that opens the vault. Whenever a
  vault has to be reopened for a wallet already on the device, the sign-in must be that identity.
  Another one — the provider handing over a different account without asking is the usual way —
  stops with `SocialAccountMismatchException`, which names the account the wallet needs, and
  offers to sign in again with an account chooser. A wallet whose rows predate the stored
  identity is given the same treatment whenever the answer is not its own vault.
- **Nothing is deleted on a "no vault" answer.** A sign-in that returns no vault, or another vault,
  cannot tell "this wallet's backup was deleted" from "this is another account". So that answer
  deletes nothing: not this device's copy, and above all not the platform slot entries, whose
  deletion syncs to every device and which may be the only thing that opens a vault that still
  exists. `forgetPlatformEntries` runs in two cases only: after the backend accepted a vault
  delete this device itself signed, and after the backend has answered "not found" for the vault
  for 30 days (next point).
- **A "not found" answer is not acted on at once.** The backend is the only authority on whether a
  vault exists, so the answer cannot be authenticated — and it is exactly what a build pointed at
  the wrong backend, or a backend restored from an older copy, gives for every vault at the same
  time. Believed at once, it would delete the slot secrets of every platform-only wallet while
  the vaults still exist. So the app acts on it slowly, in steps a sign-in can undo:
  1. A status read that answers "not found" is only written down. The wallet is unlinked when a
     later read, **at least 24 hours after the first**, answers "not found" again; any answer in
     between that shows the vault exists (its record, a conflict, a refused or replayed
     signature) starts the count over. Until then nothing changes and nothing is shown.
  2. That unlink **keeps the platform entries** and sets the vault's data key aside (its own
     item in `MnemonicVault`, read by nothing but the checks below). The rows lose their vault
     id, the phrase is kept under the account, and the user is told once: "This wallet’s backup
     is no longer stored with mallow. The wallet stays on this phone: its recovery phrase is now
     the only backup."
  3. The vault is asked about again at most once a day, with a status read signed by the key
     set aside. Its entries are deleted only when the unlink is **at least 30 days old and that
     read answers "not found" again** — never on a network error, a rate limit, a wrong clock
     or any other answer, and never when there is no key left to ask with.
  4. If the vault is there after all, the wallet is linked back: by that daily read (the key
     set aside opens the vault, and every chain address must match), or by signing in again,
     which opens the vault with the entry that was kept and links the rows that are already on
     the device — the same account, no second wallet.

  A Delete wallet backup that the backend answers "not found" is treated the same way: the wallet
  is unlinked, as asked, but the entries are kept, because this device did not see a delete go
  through. Only an accepted delete frees them at once.
- **Only the backend's own "no such vault" counts as "not found" — and only from the backend
  the vault lives on.** Two narrower rules sit under the one above, because the steps it
  describes still end in an unlink and, a month later, in deleted slot secrets:
  - **The answer must carry the backend's code.** "Not found" is an HTTP 404 whose JSON body
    has `error.code` equal to `vault_not_found`, and nothing else. A 404 with no body, with a
    page, or with any other code is what a proxy, a backend that does not have the vault routes
    (an older one, a rolled-back one) or a wrong URL answers. It is a failed request
    (`SocialVaultApiError.unavailable`): nothing is written down, unlinked or deleted, however
    long it lasts. A backend that does not send the code yet is therefore never believed about
    a missing vault; that is the safe side, and there is no fallback to the bare 404.
  - **The answer must come from the backend that showed the vault exists.** Every record the
    app keeps about a vault names that backend by its origin (scheme, host and port, from
    `API_V2_BASE_URL`): the cached vault record, the journal of an unconfirmed creation, and
    the record of a vault whose wallet was unlinked — which must carry it itself, since the
    cached record is gone by then. When the build talks to another origin, the vault is not
    asked about at all, a Delete wallet backup is not sent, and no "not found" has any effect:
    on every backend but its own, every vault is "not found", with the right code. A record
    written before the origin was kept names none. Such a vault is asked about, and takes the
    current origin only from an answer that shows it there — its record, a conflict carrying
    it, or a signature the backend checked against its key (`invalid_vault_signature`,
    `replayed_vault_signature`) — never from a 404. A sign-in that opens the vault names the
    origin too.

  The same code decides what a request that failed leaves behind. A platform entry written for
  a new slot, and the data key kept for a creation, are removed again only when the vault routes
  themselves refused the request: a 4xx carrying one of their codes
  (`SocialVaultApiException.refusedByBackend`). A 4xx with no such code is treated like no
  answer — the request may never have reached the backend that holds the vault, or may have
  been carried out there — so the entry and the key stay, and the sweeps settle them once the
  backend can be asked.
- **An answer must be about the vault that was asked about.** Every vault record taken from the
  backend — a status read, the answer to a write, the vault inside a conflict — is checked
  before anything is done with it: its vault id is the one that was asked about, and it carries
  a revision, the sealed payload, the vault public key and at least one slot (a vault always
  has one; the generated parser reads a missing list as an empty one, so an empty list is
  refused). A record that fails is a failed read: nothing is cached, under either id, no
  revision is taken from it, and no key is dropped on it. A body the parser cannot read at all
  — a conflict without its timestamps, say — is the same typed error, so the cleanup that
  follows a failed request runs for it too.
- **After unlock it behaves like an imported key.** The vault's keys go straight to
  `SecureWalletStorage` in the imported-key format (Solana base58 keypair at `m/44'/501'/0'/0'`,
  Ethereum key at `m/44'/60'/0'/0/0`, Tezos seed at `m/44'/1729'/0'/0'`), and every signature is
  local. The data key and the phrase are kept in `MnemonicVault` under the vault id, for later vault
  writes and for export; neither is ever synced. A non-secret copy of the vault record (revision,
  slot list, email hint) sits in the plugin store and is swept by a reset.
- **A lost stored key is recovered by reopening the vault**: from this device's own copy when it
  still holds the data key, else by signing in again — as the identity recorded with the link —
  and opening the vault with a slot. Every chain address must come out the same, or nothing is
  stored. A silent sign-in whose token the backend refuses as already used (`invalid_id_token`:
  the provider's SDK can hand back a cached one) is followed by one interactive sign-in rather
  than a failure.
- **iOS 16 and 17 cannot evaluate PRF.** Those devices get the platform slot only, and the web cannot
  open such a wallet until a passkey is added from an iOS 18+ or Android device (the Sign-in keys
  screen says so).
- **Profile deletion keeps the vault.** Deleting a profile removes profile data only. The vault —
  the wallet's encrypted backup — and the wallet's link to it are untouched, whatever wallet the
  session is signed in with: the vault is what brings the wallet back on a new device, and losing
  it for a deleted username would trade a profile for a wallet. The backend therefore still holds
  an encrypted blob tied to the sign-in identity after a profile deletion, and the Delete profile
  screen says so for a session signed in with such a wallet: "Your encrypted wallet backup stays
  with mallow, so you can still sign in to this wallet. To delete it too, use Delete wallet backup
  in Sign-in keys."
- **Delete wallet backup is its own action**, on the Sign-in keys screen, behind `requireReauth`.
  Its confirmation says what is lost (mallow can no longer recover the wallet on a new device;
  the wallet stays on this phone; its recovery phrase becomes the only backup) and offers the
  phrase first. Then, in this order: the delete signed by the vault key; once the backend has
  accepted it, the platform entries (they open nothing any more); the phrase copied to the
  account, so Show secrets still exports it; the rows unlinked, and the recovery graph with
  them; and last this device's copy of the vault, data key included
  (`SocialAuthService.deleteWalletBackup` → `unlinkDeletedVault`). Every step can be repeated,
  and the data key goes last on purpose: if the app dies after the backend delete, the wallet is
  still linked to a vault this device can still ask about, and the status reads that follow find
  it gone and finish the unlink (by the "not found" rule above). The unlink itself is written
  down before the rows are touched and crossed out by its last step, because it spans three
  stores — the rows, the recovery graph, this device's copy of the vault — and the graph write
  can fail with the rows already unlinked. Without the record nothing would name the vault any
  more: the data key and a second copy of the phrase would stay under the vault id, the graph
  would keep naming a deleted vault, and asking again would answer "already done". With it, the
  next status check, or the user asking again, writes the graph again and drops the copy — after
  copying the phrase under the account once more (`SocialAuthService._finishUnlinks`). The
  delete is sent only to the backend the vault is known to live on, and a 404 without the
  backend's own code fails it like any other failed request (see the "not found" rules above).
  It is refused when the device does not hold
  the phrase (the backup would be the only copy). What is left is a Google or Apple wallet with
  no vault id and no identity id: it is not a wallet from the older sign-in (the two are told
  apart by a stored mark, not by the missing vault id, below), it shows no mark, and it is offered
  no vault action. Nothing in the app gives it a new backup; its phrase is the way back.
- **Removing a sign-in key rotates the vault**: a new data key and vault key, the same payload
  sealed again, and only the slots the device can re-create on the spot (its own new platform
  slot, and each passkey the user confirms there). Everything else is dropped, and the app lists
  exactly what before confirming. It does not change the wallet's keys: a device that already
  unlocked the wallet keeps them, so a lost or stolen device means moving funds to a new wallet.
  The same goes for the recovery phrase: a rotation seals the *same* phrase under a new key. It
  stops a sign-in key that leaked from opening the vault from then on; it does nothing about a
  vault that was already opened with it.
- **A device whose data key was rotated away notices — and a wrong clock is not mistaken for
  that.** The backend refuses a vault signature with one of three codes, all `401`, and they mean
  different things:
  - `invalid_vault_signature` — the signature does not verify under the vault's current key. The
    only one that says the key may have changed.
  - `stale_vault_timestamp` — the timestamp is more than 300 s from the backend's clock. It says
    nothing about the key. The app shows "Check this device’s date and time, then try again." and
    changes nothing.
  - `replayed_vault_signature` — a valid signature that was already used, so the key is right.
    `SocialVaultApi` signs again with a strictly later timestamp and retries once.

  The data key is dropped only on evidence that the vault key changed, and the evidence is always
  an answer from the backend in hand: `invalid_vault_signature`, or a vault record (from a
  conflict or a status read) whose public key differs from the one the key that signed derives.
  The cached record is this device's memory, not evidence: a key that does not match it reads as
  unusable (`hasUsableDataKey`) and is left for the next read or write to settle. The wallet's
  keys and phrase stay; the next sign-in reopens the vault through a slot.

  Three more rules keep that evidence from being applied to the wrong key, since a status read
  starts whenever the app comes forward — returning from a biometric prompt included — and a
  rotation replaces the key:
  - **One thing at a time per vault.** A status read and every write (settling a creation,
    adding, removing or renaming a slot, a rotation, a delete, cancelling a deletion) go through
    one queue per vault. Each reads this device's data key and record only once it holds the
    queue, and gives it up only after it stored what the answer changed. So a read is never
    signed with a key that a write in flight is replacing, and its answer is never acted on
    after that write. A prompt the user paces is never inside the queue.
  - **A refusal drops the key that was refused, and no other.** The delete is a
    compare-and-delete against the key the refused request was signed with; if another key is
    stored by then, it stays.
  - **An older record never replaces a newer one.** The cached record is replaced only by a
    record of the same or a later revision (a sign-in, which opens the vault afresh, takes the
    record it opened whatever its revision). A status answer older than the cached record is
    ignored altogether: the vault key it names may be one that was since rotated away.

  A key found stale by a status read — which the user did not start and sees nothing of — is
  said once: "This device’s sign-in key for your Google wallet was replaced on another device.
  Your wallet still works here. Sign in again with Google to manage its backup on this device."
  Otherwise the first sign of it would be the
  Sign-in keys screen asking for a sign-in with no reason given, while the checks that warn of a
  pending deletion or a new key had already stopped. A write the user made reports it on the
  spot.
- **The app asks the backend about each backup, without a sign-in.** For every vault wallet whose
  data key this device holds, a status read signed by the vault key runs when the app is unlocked
  or comes to the foreground — at most once every 15 minutes per vault, never in the way of the
  UI, and silent when it fails (`SocialAuthService.checkVaults`). The answer refreshes the cached
  record, and:
  - a vault the backend says it **does not have** is handled by the "not found" rule above: a
    second such answer a day later unlinks the wallet and keeps its platform entries;
  - a vault **under another key** drops the stale data key, and the user is told once (above);
  - a **sign-in key this device has not seen** is announced once: "A sign-in key was added on
    <date>: <label>", with "Review sign-in keys" and "Dismiss". The device keeps the ids of the
    keys it has seen in the cached record; keys it adds itself are seen without a notice, and a
    device with no such list (it never opened the vault, or the record was lost) has nothing to
    compare against — the first record it sees becomes the list, silently. So the owner learns of
    a new key only when they next open the app, and never on a device signing in for the first
    time;
  - a **pending deletion** is a blocking, full-screen warning (below).
- **A deletion the vault key did not sign waits a week, and any holder of the key can refuse it.**
  The backend's operator can file a deletion request for a vault on someone's behalf — the remedy
  for a vault created by whoever held the account before its owner. The request is applied no
  sooner than 7 days later, and the vault record carries it meanwhile (`pendingDeletion`). A device
  that holds the data key shows "Your wallet backup is scheduled for deletion on <date>. If you
  did not ask for this, keep it." over everything, after a status read or a sign-in that returns
  it. "Keep my backup" cancels the request with a write signed by the vault key; "It was me,
  continue" lets it stand and is remembered for that request only.
- **A sign-in key is added only after re-authentication.** The Sign-in keys screen asks for the PIN
  or biometrics before adding one, and so does the passkey offer that follows a sign-in: accepting
  the offer runs the same `requireReauth` before the passkey is created
  (`SocialVaultPrompts.reauthenticate`). Otherwise whoever holds the unlocked phone could bind the
  wallet to a passkey on their own device. The one key added without asking is the device's own
  platform slot, which lives where only the user's devices read it.
- **A sign-in key's name is one line of plain text, by one rule.** A label is written by whoever
  holds a key of the vault, through any client, and every device draws it inside its own rows,
  notices and confirmation questions. `SocialVaultService.normalizeSlotLabel` is the rule for
  writing one, used by the rename field and by `renameSlot` alike: line breaks and tabs become
  a space; every other C0 or C1 control character, and every character that changes the
  direction the text around it is drawn in (U+061C, U+200E, U+200F, U+202A–U+202E,
  U+2066–U+2069), is left out; the ends are trimmed; and what is left is at most 64 Unicode code
  points, counted as the backend counts them (a flag emoji is two). A longer one is refused
  before anything is sent, with `SocialVaultLabelException` — its own error, so the screen can
  say the name is too long instead of blaming the connection. Labels read from the backend are
  cleaned the same way before they are kept or handed out (`displaySlotLabel`), since another
  client may have stored one this app would not.
- **Platform entries are swept, carefully.** Opening a vault deletes this device's entries for
  slots that are no longer live — but never an entry younger than 10 minutes (each entry records
  when it was written; one without a time predates the field and is old). A device writes its
  entry before the vault write that makes the slot live, and on iOS the entry syncs at once, so
  to another device it looks for a moment like an entry of no slot. The slot list an entry is
  checked against is always current: the sweep reads it itself, with a signed status read, or
  takes the record a rotation by this device just returned. It is never the record a sign-in
  fetched before it waited on the user — a passkey sheet can stay up for as long as they like,
  and on a shared iCloud Keychain a device that sat on one would otherwise delete another
  device's new entry, everywhere. When the record cannot be read at that moment, nothing is
  swept. Separately, a vault creation
  this device started and never saw confirmed leaves an entry behind; once it is a day old and no
  wallet here uses the vault, the app asks the backend (a status read signed with the data key it
  kept for the purpose) and deletes the entry only if the vault does not exist. An entry the
  device has no record of creating is never deleted for being unreferenced: it may belong to a
  wallet removed from this device, restored after a reinstall, or living on another device. A
  full Block Store (16 entries) is reported as such.
- **The Android phone backup is re-checked, every time the app comes forward.** Block Store's
  backup is end-to-end encrypted only while the phone has a screen lock, it has no "encrypted or
  not at all" option, and the lock can be removed after an entry was written. An entry in an
  unencrypted backup is a slot secret Google can read — and Google is also the identity provider.
  So `PlatformBackupGuard` (`lib/core/social_vault/platform_backup_guard.dart`) reads
  `isEndToEndEncryptionAvailable()` on every foreground and unlock (the silent half runs even
  while the app is locked) and before every write of an entry:
  - **not encrypted** — every entry this device holds is rewritten device-only (the same bytes,
    `setShouldBackupToCloud(false)`), and Home and the Sign-in keys screen say "Your backup is
    paused: set a screen lock";
  - **encrypted again** — the entries are rewritten with cloud backup on and the notice goes;
  - **not encrypted while an entry was in the cloud backup** — that entry may have been uploaded
    unprotected. Once the encryption is back the app offers, once, "Your phone backup was
    unprotected for a while, with a sign-in key in it. Replacing your sign-in keys stops that key
    from opening your wallet backup from now on. If you think the phone backup was already read,
    move your funds to a new wallet instead.", which leads to a rotation on the Sign-in keys
    screen (new data key, new device key, each passkey re-confirmed); the advice stays there
    until the keys are replaced or the user dismisses it. The words are limited to what a
    rotation does. It makes a new data key and seals the **same** recovery phrase under it, so a
    slot secret read out of the unprotected backup opens nothing afterwards. It cannot help
    against a read that was already used: whoever opened the vault with that secret, while it
    worked, has the phrase, and the phrase is the wallet. Only moving the funds to a new wallet
    answers that, which is why the message says so and why clearing the advice after a rotation
    is honest.

  No Play services, or any error, reads as "not encrypted"; the native side never puts an entry in
  the cloud backup while the answer is not a clear yes, whatever the app asked; nothing in this
  path deletes an entry or can change its value. What the app knows — per entry whether it is in
  the cloud backup, and the two markers — is a small non-secret record in the plugin store, and an
  entry it has no record of counts as in the cloud backup. A slot's label names the phone and
  claims no backup, since the label is written once and the state changes; the Sign-in keys
  screen says where this phone's key is now. **Not verified on a device:** whether Block Store
  drops an already-uploaded copy once an entry is rewritten device-only, and what it does with an
  entry after a screen lock is removed. The design does not depend on the answer, but the size of
  the window it closes does.
- **Android 8 cannot hold a Google or Apple wallet.** End-to-end encrypted Block Store backup and
  passkeys both need Android 9, so on Android 8 and 8.1 a vault would have nothing to be opened
  with. Creation fails closed there, with a message that says it is the Android version rather
  than sending the user to set a screen lock that would change nothing.
- **iOS platform keys are one keychain, not one key per device.** Every device signed in to the
  same Apple ID reads every entry, so removing one on the Sign-in keys screen does not lock a
  lost device out; removing that device from the Apple ID does, and the screen says so.

#### Wallets from the older sign-in

Before the social vault, Google and Apple sign-in in this app ran through Web3Auth (MetaMask
Embedded Wallets). Such a wallet is deterministic per (identity × Web3Auth project × network): an
Ed25519 key for Solana and one secp256k1 key behind both Ethereum and Tezos (Tezos uses its bytes
as an Ed25519 seed). The app stored those keys like imported keys, and they are still there.

- **Web3Auth is not in the app.** No SDK, no client id, no redirect, no network call to it. The
  app cannot run the older sign-in, so it can neither create such a wallet nor fetch one's keys
  again.
- **What a Google or Apple account takeover gets: the wallet.** Whoever can sign in to the account
  can have Web3Auth reproduce the keys, from anywhere the older sign-in still runs. No passkey and
  no device secret stands in the way. The mark on the icon and the sentence above are the whole
  mitigation, and they are honest about it; nobody's assets are moved.
- **A wallet already on a device keeps working exactly as before.** It signs from its stored keys,
  Show secrets exports them (two rows: Solana, and Ethereum-and-Tezos), and it is removed like any
  wallet whose key is stored here.
- **Which wallets these are.** `WalletInfo.isLegacySocialWallet`, the one predicate, reads a
  stored mark (`Wallets.legacySocial`). The schema migration that added the column set it for every
  social wallet without a vault id, which at that point could only be a wallet from the older
  sign-in: no earlier release could create a vault. Nothing sets it afterwards, and the recovery
  graph carries it, so a reinstall keeps it. A vault wallet that later loses its vault id is
  therefore never mistaken for one.
- **Told once.** After the update, each such wallet shows a single sheet after an unlock: what the
  mark means, that a lost phone is recovered through the older sign-in on the mallow website, and
  a button to Show secrets (behind its own re-auth gate) so the keys can be saved that day. No
  banner follows it.
- **Recovery when the phone is lost, or the stored key is.** The app cannot help: a key recovery
  for such a wallet fails with `LegacySocialKeyUnavailableException`, whose message is the path —
  sign in on the mallow website with the older sign-in, export the wallet's keys there, and import
  them in the app. The result is ordinary imported-key wallets, one per chain, without the mark.
  This makes the website's older sign-in the only way back for such a wallet without a saved key.
- **Passkeys depend on the RP domain's association files**, like verified links do: the iOS
  `webcredentials:` entitlement must be matched by the domain's `apple-app-site-association`
  `webcredentials` entry, and Android's Credential Manager needs `assetlinks.json` to grant
  `delegate_permission/common.get_login_creds` to both Android application ids. Without them
  passkey creation fails and the platform slot is the only slot.

The README states this too. A wallet's custody model is the first thing a reader checks, and a
document that describes only the seed-phrase case reads as a claim about all of them.

### Hardware wallets — Ledger, Seed Vault and Keystone

Three wallet types hold no key in this app at all. `WalletType.ledger` signs on a Ledger over BLE; `WalletType.seedVault` signs in the device's own Seed Vault (Solana Mobile, Android); `WalletType.keystone` signs on a Keystone, an air-gapped device reached only by QR codes. `WalletType.isHardware` covers all three, `needsDeviceForSigning` is an alias of it, and any code assuming it can produce a signature silently fails on any of them.

- **Seed Vault is Android-only and Solana-only.** Solana-only is not a scoping choice we made: the vault defines exactly one purpose, signing Solana transactions, so there is no secp256k1 and no Tezos path to reach. `WalletManager`'s Ethereum and Tezos arms refuse a `seedVault` row rather than fall through to a key that cannot exist.
- **The feature is gated on a runtime availability probe, never on the device model.** `SeedVaultService.isAvailable()` asks the platform whether a Seed Vault implementation is installed; the probe checks that the implementation's permission is signature-protected by the platform key. A device-model string is spoofable by any ROM and decides nothing here. The probe is the only fail-soft call on the service — any failure answers `false`, which hides the feature rather than breaking the screen that asked. One consequence worth knowing: the runtime permission can be *permanently* denied while the probe still answers true, so the import flow has to offer an app-settings route rather than re-request.
- 🛑 **The app never rebuilds a derivation path in order to sign.** It signs under the path the device itself reported for the account, and asserts the resolved account's public key equals the address it was asked to sign for, refusing loudly when it does not. A reconstructed path that is wrong by one component yields a *valid signature from a different address* — no error, nothing to notice downstream. The assertion cannot fire while resolution matches strictly on the vault's own public key, which is the point: it is there to stop the day someone adds a "they only have one seed, just use the first account" fallback.
- **`root` derivation is deliberately not offered for Seed Vault.** The vault pre-derives the common Solana paths on first authorization but not the index-less `m/44'/501'`, so offering it would cost a password prompt for an account almost nobody holds. Standard and legacy are both offered; the import picker refuses to build a root path at all.
- 🛑 **Background login and session resume must never sign with a hardware wallet.** `AuthService._verifySignatureIfPossible` — the post-login warm-up, the resume path and `verifySessionWallet` — skips both hardware types. None of its callers has a user action behind it, and a Seed Vault signature raises a full-screen OS approval: unprompted, on every cold start and every resume, that reads as a system-level security event rather than as a wallet asking for something. The wallet-sig handshake is deferred until the user does something that needs it. The 401 `Signature required` retry is trigger-blind — it can arrive from a background refresh as easily as from a tap — so it takes consent on the app's own sheet *before* anything reaches the device.
- **A Keystone row stores a public key, a path and a fingerprint — nothing else.** The account export the user scans carries the device's master fingerprint and its public keys; the row keeps the address, the derivation index and scheme the export reported, and the fingerprint (`masterFingerprint`, on both the wallet and its account). None of it is secret and none of it is in either secret store. The fingerprint is still load-bearing: every sign request names it, the device refuses a request whose fingerprint is not its own, and the recovery graph carries it so a restored row can still sign. Keystone accounts are keyed by (fingerprint, index), because two Keystones both export index 0.
- 🛑 **Every Keystone signature is verified before it is used.** The device's reply carries no public key, so a request that named the wrong path or the wrong device would come back with a *valid signature from a different address*. `KeystoneSignService` accepts a reply only when its request id matches the request just shown and the signature verifies with Ed25519 against the wallet's own address over the exact bytes sent; anything else is refused on the sheet and never reaches a transaction. An Ethereum reply gets the secp256k1 equivalent: the firmware ignores the request's address and signs by path, so `signEthereum` recovers the signer over the digest the app computed itself — the transaction hash, the EIP-191 digest, or the EIP-712 digest the review showed — and accepts the reply only when it is the row's address.
- **Everything scanned off a Keystone's screen is untrusted input.** A QR is whatever the camera sees. The decoder (`packages/keystone_ur`) checks the UR type against what the screen asked for, caps every length and count, and rejects malformed CBOR as a typed error rather than a crash; the account export must carry 32-byte Solana keys on one of the three known path shapes. An Ethereum key is used only in the BIP-44 standard layout. One import takes codes from one device only: a code with another master fingerprint is refused, and an Ethereum key adds rows only to accounts of the device whose fingerprint it carries.
- **Keystone signs Solana and Ethereum, never Tezos.** Its firmware has no Tezos support at all, so `WalletManager`'s Tezos arms refuse a Keystone row like the Seed Vault one. Ethereum transactions must be EIP-1559; a legacy transaction is refused before any QR is shown.
- 🛑 **There is deliberately no app-lock suppression around the approval Activity.** Leaving the app for Seed Vault's approval screen backgrounds mallow, so a slow approval trips the 60-second background lock and returns to the lock screen. That is left alone on purpose. The lock is an overlay above the app's routes, so the in-flight signing future survives underneath it and completes once the user unlocks; and a *working* suppression flag would be an authentication bypass — anyone picking up a phone parked on the approval screen could cancel out of it and land in an unlocked wallet that may also hold seed-derived keys. Seed Vault's approval protects the signature, not this app's contents. The Google and Apple sign-in sheets and the passkey prompt already cross the same boundary with no suppression.

## Database

`lib/core/database/database.dart` uses a SQLite DB encrypted with **ChaCha20-Poly1305**. The encryption key lives in Keychain via `SecureWalletStorage.storeDbEncryptionKey`. The DB file itself is at `getApplicationDocumentsDirectory()/mallow.sqlite` (eligible for iCloud backup), but holds only non-secret metadata — a backup-only attacker has nothing useful and no key. It also holds the last known copy of the viewer's block list and of what they reported, per signed-in address (`ModerationCache`, `lib/features/moderation/services/moderation_cache.dart`): the block list can only be read from the server with a signed login, which a hardware, Seed Vault or social session often cannot produce without asking, and a report is never read back at all. The copy is what keeps a block applied while that proof is missing and a reported item hidden after a restart. It is private rather than secret, which is why it is in the encrypted database and not in plain preferences; signing out deletes that address's copy and a reset deletes all of them.

## Auth model

Two factors, with a mandatory floor: **at least one of PIN or biometrics must be active** once onboarding completes.

### Onboarding

Order: Biometric Setup → PIN Setup. Skip rules:
- Biometric Setup: skippable.
- PIN Setup: skip is only available if biometrics is enabled (`pin_setup_screen.dart` reads `loadBiometricEnabled()` in `initState` and conditionally renders the skip button; the modal sheet's confirm path re-checks defensively).

Result: it is impossible to leave onboarding with no auth at all.

### Settings (Security & Privacy)

`lib/features/settings/screens/security_privacy_screen.dart` exposes:
- **Change PIN** → routes to `change_pin_screen.dart` (PIN-gated current-PIN check).
- **Biometric authentication** toggle.
  - Enabling: prompts `BiometricAuthService.authenticate` first; only flips on success.
  - Disabling: blocked with a "Set a PIN first" dialog if no PIN exists. Disabling otherwise dispatches `AppLockEvent.disableBiometric()`.
- **Show recovery phrase** → biometric-first, PIN fallback (see below).

The toggle reads from `SecureWalletStorage.loadBiometricEnabled()` and refreshes on `AppLifecycleState.resumed` so a return from the system biometric prompt or the Change PIN screen reflects the latest flag.

## App lock

`lib/core/security/app_lock_bloc.dart` owns lock state.

States: `uninitialized`, `noPinSet`, `locked`, `unlocked`, `error`.

`_onInit` (cold launch / DI-init):
- **DB-empty gate first.** If the local DB holds no wallet (`_db.hasAnyWallets()` is false) → `noPinSet`, returning **before** the PIN/biometric flags are read. This is deliberate: on iOS the Keychain (PIN hash + `biometricEnabled`) survives an uninstall/reinstall while the DB does not, so locking on a still-empty install would auto-fire the biometric prompt before the user has re-onboarded or opted in. See *Reinstall recovery* below for why this does **not** leave the restored wallet ungated.
- Otherwise, if PIN exists OR biometrics enabled → `locked(biometricEnabled: ...)`.
- Otherwise (an install predating the mandatory app-lock floor) → `noPinSet` — but not on the first look. Onboarding cannot finish without one of the two factors, so an absent PIN on a device that holds wallets is far more likely a transient secure-storage miss than a real state, and believing it drops the lock for the whole session, opens the re-auth gate in Settings and lets the recovery-phrase screen reveal a mnemonic. All three read the pair through `SecureWalletStorage.loadAuthFactors`, which re-reads while `hasPin` is false — up to three times, 150 ms apart — the same shape as the database-key read's retry. The retry follows the PIN alone: `hasPin: false` with biometrics on is the miss that strands the user on a blur with no PIN pad.
- **A read that throws is a lock, not an absence.** These reads go through `MnemonicVault`, which reports an unreadable Keychain/Keystore item as an error rather than as null, and an uncaught throw emits no state at all — leaving the app on its splash for the rest of the launch. `_onInit` catches (the factor read and the `hasAnyWallets` read both) and emits `locked(hasPin: true)`; an attempt whose `verifyPin` throws is refused without advancing the cooldown ladder (`PinAttemptVerifier`), since an unreadable store is no evidence against the user. `requireReauth` denies on a throw and the recovery-phrase gate falls back to demanding the PIN.

`_onLock` (synchronous): unlocked → locked.

`_onUnlockWithPin`: short-circuits when no PIN is stored (biometric-only mode), so the failed-attempts counter doesn't tick on a non-existent PIN.

### Cold-launch flicker prevention

`lib/app.dart`'s `_AppWithLockScreen` builder treats `uninitialized` as splash — the routed app is **never** rendered before the lock bloc resolves its state. The cold-launch sequence is: native splash → Flutter splash (router future) → Flutter splash (lock-bloc init) → lock screen → unlocked app.

### Cooldown ladder

5 wrong PIN attempts (`kMaxFailedPinAttempts`) → 30s → 60s → 5m → 15m → 30m (`kPinCooldownTiers`; tier selection in `pinCooldownAfter`, all in `pin_attempt_verifier.dart`). Every failure from the fifth on arms a cooldown, and each further five move it up a tier. Counters and `cooldownUntil` are persisted via `SecureWalletStorage`, and `_onInit` and `_onLock` read them back, so neither a force-close nor a background lock resets the ladder. The lock screen disables the number pad during cooldown and shows a countdown.

**Every check of the app PIN spends this one budget.** `PinAttemptVerifier` is the only caller of `SecureWalletStorage.verifyPin`, which has no memory of its own. A surface that called it directly would be a free oracle for the same six digits, and a correct guess reaches Show secrets. So the lock screen, the re-auth and step-up `PinPromptSheet` and the Change PIN current-PIN step all read the counter and deadline from the store on every attempt, and a wrong PIN on any of them advances the same ladder. During a cooldown even the correct PIN is neither checked nor counted, and the sheet and Change PIN show the same countdown with the pad frozen. The sheet still closes after three wrong attempts, but reopening it buys nothing. A correct PIN on any of them clears the lockout. The biometric paths do not consult the PIN cooldown: they are not a guess at the PIN.

**A stored deadline never counts for more than the top tier.** The ladder cannot arm more than 30 minutes, so a deadline further ahead than that can only come from a clock that has since moved back, whether it was wrong or was set forward on purpose before the failures. `PinAttemptVerifier.boundCooldown` rewrites such a deadline to 30 minutes from now wherever one is read back (each PIN attempt, `_onInit`, `_onLock`, and a PIN surface opening). The lock screen holds its deadline in memory, so the same check runs on that one when the app resumes and on a PIN attempt. The cooldown still runs and the PIN is still refused during it, but it ends in 30 minutes rather than when the clock catches up.

The two kinds of surface differ when the store misbehaves. Behind the lock screen `verify` fails closed: if the counter or deadline cannot be read, or the attempt cannot be counted, the PIN is not evaluated and the check is refused, because the lock screen remains the way back in. The lock screen itself (`verifyForUnlock`) has nothing behind it, so its bookkeeping is best-effort and a correct PIN still opens the app.

Below the countdown it says what the way out is, because there is no in-app PIN reset — nothing could verify one without the PIN. **The hint is platform-branched, because what a reinstall costs differs by platform and the difference is the wallet itself.** On iOS the Keychain outlives the uninstall, so the reinstall lands on the Restore screen and the copy points at it: *"You will need your recovery phrase: reinstall the app, choose Start fresh, then import it."* On Android nothing survives the uninstall — app storage, the plugin store and every Keystore alias go with the app — so there is no Restore screen to land on and a reinstall without the phrase destroys the only copy of the wallet. The copy says so: *"Your recovery phrase is the only way back. Reinstalling the app erases the wallet stored on this device, so make sure you have the phrase first."*

### Background lock — 60-second threshold

`lib/app.dart` tracks `_backgroundedAt` on `paused`/`hidden` and dispatches `AppLockEvent.lock()` on `resumed` only if elapsed time ≥ 60s. Short trips (control center peek, app-switcher glance, quick reply) don't force re-auth.

### Biometric-first

The lock screen (`lib/shared/widgets/lock_screen.dart`) auto-prompts `BiometricAuthService.authenticateToUnlock()` on mount when `state.biometricEnabled` is true. PIN entry is the fallback.

### Reinstall recovery — the lock re-arms before the wallet is reachable

On iOS the Keychain vault (mnemonic + imported keys, all `WhenUnlockedThisDeviceOnly`) plus the PIN hash and biometric flag survive an app uninstall/reinstall, but the Drift DB does not. On the first cold start after a reinstall, `_onInit` sees an empty DB and emits `noPinSet` (unlocked), and `AuthStateNotifier` detects the recoverable Keychain data and routes to `WalletRecoveryScreen` (`lib/features/onboarding/screens/wallet_recovery_screen.dart`). The same screen appears after the database was quarantined or re-keyed on a device that was never reinstalled — so it must assume the user did nothing to get there.

"Restore wallet" rehydrates the wallet straight from the surviving Keychain (no seed-phrase re-entry). It is **all-or-nothing**: before writing a row, `WalletRepository.restoreFromGraph` checks that every seed phrase and every imported-key wallet in the graph has its secret readable from the vault; one miss — a nil read or a read error — aborts with nothing written (`RestoreAborted`), the screen says how many could not be read and offers Try again.

That default does not change, but it is no longer the only way forward. After an abort, and **only** when something on the device actually is readable (`RestoreAborted.hasReadable`), the screen offers a second button, **Restore what can be read**. It re-runs the restore with `readableOnly: true`, which writes every seed phrase and imported key whose secret reads plus every social, Ledger, Seed Vault, Keystone and view-only row, and skips the rest along with their accounts and wallets. An account of a restored seed is kept even when no wallet references it — an import whose every selection was already taken leaves one behind, and the full restore writes it. It writes **nothing** to the graph, so the skipped entries stay listed there: the boot-time dormant restore retries them at every launch, and a later full restore can still take them. Without it a single unreadable entry blocked every restore forever and the only other action, Start fresh, erased the readable seeds too.

🛑 **`hasReadable` counts only entries that could sign afterwards** — a readable seed, a readable imported key, or a social row: one linked to a social vault, whose key reopening the vault stores again, or one without a vault (a wallet from the older sign-in, or a vault wallet whose backup was deleted) whose stored key reads. Hardware rows — Ledger, Seed Vault and Keystone alike — and view-only rows are excluded even though a partial restore does write them: a graph of one unreadable seed plus one watch-only address must not offer a partial restore, because that restore would put a wallet in the database, report success, and take the Restore screen away from a user whose seed is still unrecovered.

**A restore re-points a dangling selection rather than leaving it dangling.** The graph's own `selectedWalletId` is taken when its row is there; otherwise the stored id is kept if *it* resolves. When neither does — a graph written before the prune validated its selection, or a partial restore that skipped the selected row — the selection is re-pointed at a restored wallet that binds the global signer (Solana), else at the first restored row, and a restore that wrote no wallet at all deletes the selection. Leaving it alone was not enough: the stored id lives in the plugin store, which survives an iOS reinstall, so it can outlive the row it names and leave `getActiveWallet` answering null forever with nothing but a manual wallet switch to repair it. The rows that do get written go in one transaction. Social keys are exempt: a vault wallet's come back by reopening its social vault (from the platform slot without a prompt where the device still has one), and a social wallet without a vault is restored as a row whether or not its stored key reads — when it does not, signing fails with the way to bring the wallet back; Ledger ids, Keystone master fingerprints and view-only rows hold no secret, and a Seed Vault row holds none of ours at all — restoring one writes an address whose signing capability comes back when the user re-authorizes the seed on that device. Because the app booted into `noPinSet`, restoring must **not** be treated as proof of authentication. After the restore completes, `_restoreWallet` re-fires `AppLockEvent.init()`: the DB now holds a wallet, so `_onInit` re-evaluates the surviving PIN/biometric and emits `locked`. The user therefore hits the canonical lock screen — biometric-first, PIN fallback, cooldown ladder — before the wallet is usable, and background locking is re-established for the session.

"Start fresh" is the one place a user can wipe the device **before** proving they hold the phrase. It therefore expands an in-place gate — copy, an "I have my recovery phrase saved" checkbox, an Erase button that is inert until the box is ticked, Cancel — and then runs the same factory reset as Settings → Reset app (`AppResetService`): secrets by enumeration (every vault key via `MnemonicVault.listKeys`, every plugin-store item under the app's service — not just the ids the app still knows), both DB-key copies, the database *file* (closed, deleted, reopened lazily), preferences and the analytics device id. It is deliberately **not** gated on the surviving PIN/biometric: a user who forgot the PIN has no other way to start over, and the lock screen's cooldown hint points them here. The wipe clears the database **rows before it erases any secret**, for the same reason every removal path puts rows first: a reset the user kills part-way must not leave wallet rows on disk whose secrets are gone. That state boots into a session with wallets, and the eager backfill then writes a recovery graph naming secrets that no longer exist — every restore from then on aborts on entries nothing can satisfy. The file delete still runs after, so the file and its key go together. Both wipe callers then dispatch `AppLockEvent.reset()` on the app-provided `AppLockBloc`. The PIN hash the lock verifies against has just been deleted, so a bloc left holding `unlocked(hasPin: true)` would raise the LockScreen on the next backgrounding past the threshold — over Welcome, on a device where no PIN can dismiss it. It is dispatched from the two screens rather than from `AppResetService` because `AppLockBloc` is registered as a DI *factory*: only the instance `app.dart` created and provided into the widget tree is live, so a service-side `sl<AppLockBloc>()` would reset a throwaway bloc and change nothing. `AuthStateNotifier.onLogout` is best-effort — it never throws and always notifies listeners — and both screens call it unconditionally after the wipe, not behind a `mounted` guard: a back tap can unmount Reset app mid-wipe, and the logout is what routes the wiped device to Welcome. The reset handler itself only deletes the PIN, biometric flag and lockout counters, so nothing is written back into the store the sweep has just emptied. It emits `noPinSet` **first** and then runs each delete best-effort: the vault reports a refused delete instead of swallowing it, and one refusal must not leave the lock bloc holding `unlocked(hasPin: true)` — that raises the LockScreen on the next backgrounding, with the PIN that would dismiss it already deleted.

> **Why this matters (regression guard):** without the re-init, a reinstall left the session stuck in `noPinSet`, so anyone holding a momentarily-unlocked device could delete + reinstall the app, tap "Restore wallet," and reach a fully spendable wallet without ever entering the PIN/biometric that still exist in the Keychain — the exact "unlocked phone in the wrong hands" threat the app lock defends against. Do not remove the post-restore `init()` without replacing it with an equivalent challenge against the persisted `hasPin()`/`loadBiometricEnabled()` credentials. Android is unaffected: nothing there survives an uninstall — the vault's `mallow_vault_prefs` ciphertext, the plugin's own SharedPreferences file, and every AndroidKeystore alias the two of them created all go with the app data, alongside the DB.

### The recovery graph carries what the database forgets

The graph (`mallow_account_graph`) is what Restore rebuilds from, and it is rewritten on every wallet mutation. It lives in the **vault**, not the plugin store: it is the only index of the vault's per-seed mnemonics and imported keys, so a store whose overwrite deletes the old item first (see *Everything else* above) could orphan every seed it names. It is **not** a mirror of the database: `_syncWalletGraph` carries over every stored entry the database lacks, unconditionally — and the read it carries from is guarded (`loadAccountGraph` waits on iOS protected data and throws rather than reporting an inaccessible item as absent), so an unreadable keystore leaves the stored graph exactly as it was instead of triggering a database-only rewrite. The write is deliberately *not* behind the same guard, because it does not need to be: the vault write is update-or-add on both platforms, so a failed write leaves the stored graph as it was. Additive wallet mutations nevertheless fail with `GraphSyncException` when that write fails, because creating or importing signing material must not report success until the graph durably indexes it; an imported-key, view-only or hardware add refused as a duplicate first runs a best-effort sync, so a retry of an add whose first graph write failed still indexes it, and the refusal stays a duplicate whatever that sync does; cosmetic refreshes keep the old graph and retry on a later mutation. A pruning sync also aborts the removal with nothing deleted. A database that does not know a seed is not proof the seed is gone — after a transient keystore misread routed a launch to onboarding, the first new seed used to overwrite the graph with just itself and orphan every other seed in the vault. An entry leaves the graph only when the code path that deletes its secret names it (graph-first: `removeWallet` / `removeWallets` / `removeAccount` write **one** pruned graph naming everything that is going *before* deleting anything; a failed write throws `GraphSyncException` with nothing removed — as does a failed *read* of the graph on that path). A signing import reaches that path too: importing an address a view-only wallet holds supersedes the view-only row through `removeWallet`, so the import itself can fail with `GraphSyncException`, and the caller reports it and adds nothing. That pruned graph is the only write on the removal path — it carries the replacement selection (decided before the prune, stored right after it), its `selectedWalletId` always names a wallet present in the same write or is null, a restore re-points a selection no restored wallet matches (see *Reinstall recovery*), and accounts the removal empties leave with their wallets. Dormant entries — in the graph, not in the database — come back on the next cold start (`restoreDormantFromGraph`), which reads no secret at all when the graph and the database already agree: an entry is restored when its secret reads back, skipped when it does not, and dropped as a duplicate only when the same secret is provably already live. For a seed that means an equal live mnemonic *and* every live mnemonic readable — one nil live read skips every dormant seed that launch, because restoring on an unanswerable comparison writes a second seed row nothing ever merges. For an imported key it means a live row at the same address that itself holds a readable signing secret; a view-only or Ledger row at that address proves nothing, and deleting the key on that evidence would destroy the only copy. A nil read never decides anything destructive, and one malformed entry is skipped without stopping the rest. What a pass restores counts as live for the decisions after it — a second dormant seed with the same phrase is then a duplicate, and a restored seed's wallet whose address is already live is not written (its entry is pruned; nothing else goes with it). Every duplicate a launch finds is pruned by one graph write after both passes, and the vault copies go only once that write has landed; the boot path reads the graph once and hands it to the restore.

**Every mutation of the wallet set is serialized by one repository-level lock.** The graph is rebuilt from the *whole* database on each write, so two mutations in flight un-prune each other: a removal writes its pruned graph, then deletes rows and secrets, and a plain sync (a rename, a reorder, a wallet switch) landing in that gap rebuilds the graph from a database that still holds the row — writing the pruned entry straight back, now indexing a secret the removal is about to delete. That entry is a zombie: the restore pre-check counts it as missing forever, so every reinstall restore aborts on it, and the only other action erases the readable seeds too. `WalletRepository` therefore takes the lock at each public mutation — create, import, add, set-active, rename, reorder, remove, sync, restore, reset — and nothing below them may take it again (a nested take waits for its own caller). Reads are not serialized; they never write the graph.

## Sensitive in-app operations

This table is the authoritative map of *when* re-auth is demanded. The semantics of each gate (biometric-only vs. PIN-fallback, device-passcode vs. app-PIN) differ per row — read the notes.

| Operation | Gate | Where |
|---|---|---|
| Cold-start launch (PIN or biometric set) | Lock screen — biometric-first, app-PIN fallback | `app.dart` + `AppLockBloc._onInit` |
| Resume after ≥60s background | Lock screen | `_AppWithLockScreenState.didChangeAppLifecycleState` (`app.dart`) |
| **Sign transaction above the configured USD threshold (or unknown value)** — *only when the user has enabled step-up auth; off by default* | Step-up: biometric → **app-PIN sheet** fallback | `TransactionAuthGate.authorize`, from the ten call sites listed under *Transaction signing* |
| View recovery phrases and private keys | The Security & Privacy entry gate (`requireReauth`); Show secrets trusts it on the in-app tap and gates itself when reached any other way | `ShowSecretsScreen` (the `recoveryPhrase` route) |
| Open the Sign-in keys screen | `requireReauth` on every way in: the Security & Privacy entry gate for its row; the screen's own challenge when reached any other way (the Home banner, the new-key notice) | `SignInKeysScreen` (`preAuthenticated`, as for Show secrets) |
| Add a passkey to, or remove a sign-in key from, a Google or Apple wallet's social vault | `requireReauth` at the action, on top of the screen's entry gate; the last key cannot be removed | `SignInKeysScreen._addPasskey` / `_remove` |
| Replace a wallet's sign-in keys after its phone backup was unprotected (Android) | `requireReauth`, after the confirmation that lists what is kept and dropped; refused while the phone has no screen lock | `SignInKeysScreen._replaceKeys` → `_rotateRemoving` |
| Add a passkey from the offer that follows a Google or Apple sign-in | `requireReauth`, after the offer is accepted and before the passkey is created | `SocialAuthService._afterOpen` → `SocialVaultPrompts.reauthenticate` |
| Delete a Google or Apple wallet's backup (its social vault) | `requireReauth`, then a confirmation that offers the recovery phrase first | `SignInKeysScreen._deleteBackup` → `SocialAuthService.deleteWalletBackup` |
| Delete profile (never touches a wallet's social vault) | The active wallet's signed-session check | `deleteMallowAccount` (`account_deletion.dart`) |
| Change PIN | Current-PIN entry, on the shared attempt budget | `ChangePinScreen._validateCurrentPin` |
| Disable PIN (turn off) | Current-PIN entry + confirm dialog | `ChangePinScreen._confirmTurnOffPin` — only offered once `_validateCurrentPin` has advanced past the current-PIN step, and only when biometrics are enabled to take over |
| Disable app lock entirely | PIN entry (`AppLockEvent.disable(pin)`) — **handler only; nothing in the app dispatches this event**, so there is no surface that turns the lock off. Turning the PIN off (above) leaves biometrics on and still locks | `AppLockBloc._onDisable` |
| Toggle biometric on | Biometric prompt | `SecurityPrivacyScreen._enableBiometrics` |
| Toggle biometric off | None if PIN set; blocked if no PIN | `security_privacy_screen.dart` |
| Reset app | Checkbox confirmation, then `requireReauth` right before the wipe | `ResetAppScreen._resetApp` |
| Remove a wallet or account whose key is stored here (seed-derived, imported, social) | Confirmation sheet, then `requireReauthForRemoval` | `EditWalletScreen._onRemoveWallet`, `EditAccountScreen._onRemove`, the swipe in `EditAccountsScreen._confirmRemoveAccount` |
| Remove a watch-only, Ledger, Seed Vault or Keystone wallet | Confirmation sheet only — nothing unrecoverable is stored here | same call sites; `WalletType.storesKeyOnDevice` is false |
| Turn a chain off (Edit Account → Done) | None — the account always keeps one address, so its seed phrase stays on the device; Done refuses a diff that would empty it | `EditAccountScreen._applyAddressToggles` |
| Start fresh (reinstall restore screen) | Checkbox confirmation only — deliberately: a user who forgot the PIN must be able to start over | `WalletRecoveryScreen._startFresh` |

Gate-semantics cheat sheet (`biometric_auth.dart`):
- `authenticate(reason:)` — `biometricOnly: false` (default). Biometric with **OS device-passcode** fallback (not the app PIN). Used for unlock, transaction signing, and enabling biometrics.
- `authenticateForSeedPhrase()` — `biometricOnly: true`. No device-passcode fallback; the app-PIN fallback is a separate in-screen path in `recovery_phrase_screen.dart`.
- `authenticateForReauth()` — `biometricOnly: true`, reason "Authenticate to continue". The biometric half of `requireReauth` (`reauth_gate.dart`), which is the canonical re-auth gate for entering a protected surface: it prompts here first and falls back to `PinPromptSheet` when biometrics are off, cancelled, or unavailable. Its callers: opening **Settings → Security & Privacy**; **Reset app**, which gates itself again right before the wipe rather than trusting that entry gate (it may have run long ago, and any other way onto the route skips it); **Show secrets**, which trusts the entry gate on the in-app tap and gates itself only when reached any other way; and the wallet and account removals above, through `requireReauthForRemoval`, which prompts only when a removed wallet's key is stored on this device. Note its one deliberate pass-through: with *neither* biometrics nor a PIN configured there is nothing to challenge with, so the gate returns true rather than locking the user out of a wallet that has no lock.
- `authenticateForTransaction()` / `authenticateToUnlock()` — thin wrappers over `authenticate()` with fixed reason strings; both `biometricOnly: false`.

There is **no** "recently authenticated" cache in `BiometricAuthService` — each call is an independent OS prompt.

## Transaction signing — the kill switch and the value gate

Signing is gated by a **single entry point**, `TransactionAuthGate.authorize` (`transaction_auth_gate.dart`), which runs at the orchestration layer *before* any key material is touched. One entry point, but **two independent checks in a fixed order**: a server-controlled kill switch first, then the local value gate. The first is not under the user's control, so read that subsection even if step-up auth is off.

### Where the gate is called

`authorize` is reached from **ten** call sites. Every one of them threads a required `FlowKey` (chain × flow), which is what makes the kill-switch lookup below exhaustive — a missed cell would be a compile error, not a silent hole.

| Call site | Covers | `usdValue` passed |
|---|---|---|
| `signSendConfirm` (`transaction_signing.dart`) | mint, fixed-price, auction, market, raffle — every backend-built tx | caller-supplied; **`null`** for a flow that gives up an NFT (see below) |
| `SendBloc._onExecute` | SOL / SPL send | computed from the price feed |
| `SendBloc._executeTezos` | XTZ / FA1.2 / FA2 send | **`null`** unless the token is affirmatively priced at `$0` |
| `SendBloc._executeEthereum` | ETH / ERC-20 send | **`null`** unless the token is affirmatively priced at `$0` |
| `SwapBloc._onExecute` | Jupiter / Orca swap | computed net outflow |
| `TokenBurnBloc._onConfirmAndSign` | SPL burn-and-close | token value, or `0` when affirmatively priced at `$0` |
| `EvmArtworkTransferService.execute` | ERC-721 / ERC-1155 transfer | **`null`** — NFTs carry no reliable USD value |
| `MagicEdenPurchaseService` (`magic_eden_purchase.dart`) | Magic Eden listing purchase (Solana) | **`null`** |
| `OpenSeaPurchaseService` (`opensea_purchase.dart`) | OpenSea listing purchase (Ethereum) | **`null`** |
| `BrowserSigningService._authorize` | every website transaction and message, on Solana, Ethereum and Tezos | the review's estimated outflow for a transaction, **`null`** when it cannot be priced; always **`null`** for a message |

🛑 **A flow that gives up an NFT always fails closed.** Listing (`fixed-price-create`), repricing (`fixed-price-update`), starting an auction (`auction-create`), accepting an offer (`offer-accept`), burning (`nft-burn`) and a direct transfer (`nft-transfer`) all pass `null`. Any amount such a transaction names is what the other side pays, chosen by whoever is signing, and says nothing about what the NFT is worth: valued at that amount, a listing at the minimum price from a stranger's hands would pass under any threshold. Cancels, settles, claims and refunds are not in this list. They recover a position rather than give one up, and they pass their own outflow, normally `0`.

🛑 **The Tezos, EVM, EVM-NFT and marketplace-purchase arms always fail closed.** They have no reliable price reference, so they pass `null`, which the value gate treats as "unknown" and prompts on. The single exception is a token the balance feed *affirmatively* prices at `$0` — known-worthless dust, which passes `0` instead of "unknown". Once step-up auth is enabled, that makes every Tezos and Ethereum outbound transfer a prompting transaction regardless of amount.

### The remote kill switch — a server can block signing

⚠️ **This is a trust dependency, and for a self-custody wallet it is a first-order one.** Ahead of the opt-in check and before any value is read, `authorize` looks the transaction's `(chain, flow)` cell up in `RemoteConfigService`, an in-memory cache of `GET /v2/config/mobile`. If an operator has killed that cell, `authorize` returns `TransactionAuthOutcome.flowDisabled` and the caller aborts. **An operator can therefore remotely prevent signing for a given (chain, flow) pair, on a device that is otherwise working normally.** The ordering is load-bearing and is called out in the code: both later early-returns yield `allowed`, so a kill check placed after either would be inert for every user who has not enabled step-up auth — which is most of them.

The bounds of that power, stated plainly:

- **It can block a signature. It cannot cause one.** The kill switch has exactly one effect — turning `authorize` into a refusal. There is no path by which a remote-config response weakens a gate, lowers a threshold, skips a prompt, or produces a signature. Nothing in the payload can make the wallet sign anything.
- **It reaches no key material.** The check runs before the gate touches storage, so a killed flow never loads a mnemonic or private key.
- **It is off by default and fails open.** The cold-start value is `RemoteConfig.permissive` — nothing killed. The payload is sparse (only *currently-disabled* cells appear), and a failed fetch is swallowed, so a backend outage cannot brick signing. The accepted tradeoff is stated in `RemoteConfigService`: a killed flow comes back if the very first fetch fails from cold. A *failed refresh* keeps the last known value rather than resetting to permissive, so a flapping backend cannot re-open a flow mid-incident.
- **Nothing is persisted.** The config is never written to disk, so a kill cannot outlive the incident on a device that stays offline.
- **The rejection copy is the server's, rendered verbatim.** `TransactionAuthOutcome.disabledMessage` carries the operator's message straight to the user, because it is the only thing that can tell them whether their funds are safe. An operator who saves an empty message still produces a visible rejection (`kFlowDisabledFallbackMessage`), never a blank error.
- **A second, local arm shares the same outcome.** Before the remote lookup, `authorize` rejects any `(chain, flow)` cell **this build** does not implement (`AppFlow.isImplemented`), with `kUnsupportedFlowMessage` and a Sentry report. That arm is a bug backstop — the UI should never have offered the action — and is deliberately client-side: a server-driven support list would let a newer backend convince an old build that a flow it cannot perform is available.
- **A third, compile-time arm: the store gate.** After the remote lookup, `authorize` rejects any cell `storeHidesFlow` answers true for (`lib/core/config/store_build.dart`), with `kStoreGatedFlowMessage` and the same Sentry report. Two compile-time flags feed that predicate, and only the iOS App Store build turns either off: `kShowNftCommerce` hides `kStoreCommerceFlows` — the paid side of the marketplace, buy/bid/offer/sell/list/mint/raffle entry (Guideline 3.1.1) — and `kShowSwap` hides `kStoreSwapFlows`, `token-swap` and `stake-liquid` (Guideline 3.1.5(ii)). Every entry point to a hidden flow is hidden in that build, so reaching this arm means a missed entry point. Marketplace escape hatches — cancelling a listing or offer, settling or claiming an auction or raffle, native unstake and withdraw — are in neither set and are never refused by this arm. `stake-liquid` is the one deliberate exception: both directions of the liquid path are that single cell, so hiding the swap hides the mallowSOL redemption with it. mallowSOL stays visible, sendable and transferable, and any build that shows swap redeems it.

**Outcome vocabulary.** `authorize` returns one of `allowed`, `cancelled`, `unavailable`, or `flowDisabled`. The first three are const singletons; `flowDisabled` is the one that carries a message, which is why `TransactionAuthOutcome` is a class rather than an enum. A killed cell throws `TransactionFlowDisabledException` — deliberately *not* `TransactionAuthCancelledException`, because several surfaces render cancels silently and would swallow the operator's copy. `AppFailure.from` maps it onto `AppFailureKind.flowDisabled`, and `handleFlowDisabled` is its one presentation.

### The value gate

🛑 **The gate is opt-in, and the opt-in is OFF by default.** `authorize` reads
`SecureWalletStorage.loadTransactionAuthEnabled()` (default `false`, written only by the
Security & Privacy toggle) *before* it looks at any value, and returns `allowed` when the user has
never turned it on. So on a default install **no transaction of any value prompts** — the app lock
(cold launch + ≥60s background) is the whole of the per-signature story until the user opts in.
Everything below describes what happens once they have. State this plainly wherever the gate is
summarised: describing the threshold without the opt-in reads as "high-value transactions always
prompt", which is not what a default install does.

Once enabled, `authorize({usdValue, flow})` prompts only when the transaction's net USD outflow exceeds
the user's configured threshold:

- **Configurable threshold.** The effective threshold is read from `SecureWalletStorage.loadTransactionAuthThresholdUsd()`, set in **Security & Privacy → "Require auth over"** (`security_privacy_screen.dart`, `_editTxAuthThreshold` → `storeTransactionAuthThresholdUsd`). When the user has never changed it, the gate falls back to `kTransactionAuthThresholdUsd` (default **$100**). The check is strict `>`, so a transaction *exactly at* the threshold passes without a prompt. Setting the threshold to `0` makes every transaction with any positive or unknown value prompt. A transaction valued at exactly `0` still does not: see *Known gaps*.
- **Fail-closed.** A `null` `usdValue` (price unavailable / uncomputable) always forces the prompt — we can't classify a transaction as "small" without a price reference. This is why the send/burn flows only skip the gate for a token the balance feed **affirmatively** prices at `$0` (`TokenBalance.hasKnownZeroValue`, which is `totalUsdValue == 0`). An *unpriced* token — absent `price_info` from a feed outage, indexer gap, or newly-listed-but-valuable mint — leaves `totalUsdValue` null, which is treated as unknown and fails closed, so a valuable token whose price lookup missed can never be sent or burned without the prompt.
- **Fallback order.** Biometric → **app-PIN sheet** (`PinPromptSheet`, on the shared attempt budget described under *Cooldown ladder*), with one nuance: a *user-cancelled* biometric prompt is respected as a cancel (no PIN re-prompt), while biometric *unavailable / not-enrolled / error* falls through to PIN. If neither biometric nor an app PIN exists, `authorize` returns `unavailable` and the caller aborts — it never signs without a second factor.

**Behavior:**
- A transaction **at or below the threshold** signs with **no prompt** on an already-unlocked device. This is the deliberate tradeoff of a value-gate model: the app-lock (cold launch + ≥60s background) is the floor; per-transaction re-auth is reserved for higher-value outflows.
- A transaction **above the threshold** (or with unknown value) prompts exactly **once** (biometric, or the app-PIN sheet on fallback).
- **Hardware wallets get the same gate — every kind.** Above the threshold the `TransactionAuthGate` prompt fires first, and only then does the device confirm: a Ledger's on-button press, Seed Vault's own full-screen approval, or the review on a Keystone's screen. The gate was deliberately left unchanged when Seed Vault landed. It is opt-in and off by default, so exempting hardware would quietly remove the only per-signature check from the users who went and turned it on — and the device's own approval is not a substitute for it, because it proves possession of the phone, not knowledge of this app's PIN or a match against its biometric.

> **History (resolved).** Two gates briefly coexisted: an unconditional per-signature prompt (`_authenticateForSigning` in `WalletManager`) and this threshold gate. They landed 3 hours apart and stacked — every transaction prompted, and high-value ones double-prompted. The per-signature gate was removed in favour of the single configurable value gate; the wallet's signing methods (`signTransaction`, `signTransactionWithAdditionalSigners`, `signCompiledTx`) no longer self-prompt. Every transaction-signing path is reached only *through* `TransactionAuthGate` (`send_bloc` → `sendSol`/`sendSplToken` → `signTransaction`; `signSendConfirm` → `signCompiledTx`), so removing the floor gate did not open an ungated path.

Operations that are **not** value-gated: the app's own `signMessage*` calls (`wallet_manager.dart`), such as the backend sign-in. These rely on the app already being unlocked. A message a *website* asks for is different: it goes through `BrowserSigningService._authorize` with no value, so it is gated like an unpriced transaction.

## Privacy on backgrounding

Three layers of defense, applied in order of which fires first on a given device:

### 1. Flutter widget blur (`lib/app.dart`)
`_PrivacyBlurOverlay` — `BackdropFilter(sigma 30)` + 60% background tint + centered logo. Toggled by `_isObscured`, which flips on any `AppLifecycleState != resumed/detached`. The `setState` runs synchronously in `didChangeAppLifecycleState` so the blur paints in the same frame as the OS captures its app-switcher snapshot.

### 2. iOS native (`ios/Runner/AppDelegate.swift`)
`applicationWillResignActive` adds a `UIVisualEffectView(systemMaterial)` over `self.window`; `applicationDidBecomeActive` removes it. Reliable for the iOS app-switcher snapshot.

### 3. Android native (`android/app/src/main/kotlin/.../MainActivity.kt`)
`FLAG_SECURE` set in **both** `onUserLeaveHint` (fires before the system snapshot when the user explicitly leaves) and `onPause` (covers the rest), cleared in `onResume`. Result: blank recents thumbnail, but in-foreground screenshots still work.

There's no native API on Android for an actual blur — `FLAG_SECURE` only blanks. The Flutter blur layer fills that gap.

> Native code changes do not hot-reload. `flutter clean && flutter run` is required after editing `MainActivity.kt` or `AppDelegate.swift`.

## Derivation paths

Paths are **per-account-index**. `$index` is the account index shown in the import picker. Canonical source: [`lib/core/crypto/derivation.dart`](../lib/core/crypto/derivation.dart) (`MultiChainDerivation`).

| Chain | Path | Curve |
|---|---|---|
| Solana (standard) | `m/44'/501'/$index'/0'` | Ed25519 — matches Phantom and Solflare |
| Solana (legacy) | `m/44'/501'/$index'` | Ed25519 — import only |
| Solana (root) | `m/44'/501'` | Ed25519 — index-less, so index 0 only |
| Ethereum / EVM | `m/44'/60'/0'/0/$index` | secp256k1 — index is the **last** component |
| Tezos (tz1) | `m/44'/1729'/$index'/0'` | SLIP-0010 Ed25519, then Base58Check(`tz1` + Blake2b-160(pubkey)) |

🛑 **The Solana scheme is part of a wallet's identity.** `SolanaDerivationScheme` (`standard` / `legacy` / `root`, mapped by `MultiChainDerivation.solanaHdPath`) must round-trip through the stored wallet record. Derive with the wrong one and you produce a *valid signature from a different address* — it does not throw and it does not look broken.

Seed Vault expresses the same two Solana paths as URIs (`bip32:/m'/44'/501'/$index'/0'` and the legacy form without the trailing level). The app builds one only to *offer* an account at import; it never builds one to sign with — see *Hardware wallets* above for why, and for why the root path is not offered there at all.

## Key-derivation pattern

Derive on demand, never cache wallet objects. Let GC reclaim the keypair as soon as the operation completes.

```dart
Future<SignedTx> signTransaction(Transaction tx) async {
  final mnemonic = await _secureStorage.loadMnemonic();
  final wallet = await Ed25519HDKeyPair.fromMnemonic(mnemonic!);
  return wallet.signMessage(
    message: tx.message,
    recentBlockhash: tx.blockhash,
  );
  // wallet goes out of scope — no manual zeroing needed; Dart GC handles it.
}
```

Don't store derived keys in fields, providers, or service singletons. Read mnemonic → derive → use → drop.

## Known gaps

These are explicitly **not** gated today. Each is its own follow-up.

- **Idle-while-foregrounded timeout.** `loginToken` and `sessionExpiry` are stored but no middleware enforces expiry on sensitive ops once the app is unlocked. With the value-gate model, a foregrounded, already-unlocked wallet **can** sign transactions at or below the configured threshold with no prompt — and with step-up auth left at its default (off), at *any* value — while the API session (`loginToken`) isn't expired on idle. The lock screen only re-arms on the next ≥60s backgrounding. Users who want the most challenges the gate can give must enable step-up auth **and** set the "Require auth over" threshold to `0`. That still leaves a transaction valued at exactly `0` unprompted: cancels, settles, claims, refunds and other flows with no outflow, dust a token feed affirmatively prices at `$0`, and the later transactions of a batch whose first one already prompted.
- **The PIN cooldown trusts the device clock.** The deadline is a wall-clock time, so someone who can change the system clock can end a cooldown early. The counter survives that, so the next wrong PIN arms the next cooldown at once, but the waits themselves are only as good as the clock. In the other direction the damage is bounded when the deadline is read back from the store: see *Cooldown ladder*. A re-auth prompt or Change PIN already open when the clock moves back keeps its deadline until it is reopened. A store that accepts the counter but refuses the deadline leaves that one cooldown enforced only by the screen in front of the user.
- **The recovery graph can list wallets the database does not show.** By design (carry-over, see *The recovery graph carries what the database forgets*): dormant entries wait for the next cold start. There is no UI that surfaces them between launches.
- **Two dormant-restore paths lose wallet *metadata*, never key material.** A restored dormant seed's wallet whose address is already held by a live row — a view-only row is the realistic case — is not written and its graph entry is pruned; the seed and its mnemonic are restored, so the address is re-derivable, but that wallet's name and ordering are gone. A dormant seed judged a duplicate of a live seed is pruned whole, so its accounts' and wallets' names, avatars and ordering go with it while the phrase itself stays live under the other id. Both are accepted: the alternative is a second signing row at one address, which nothing later merges.
- **The mutation lock does not serialize reads.** It covers every public mutation of `WalletRepository` (which is what keeps two graph writes from un-pruning each other); a read running alongside one can observe the database mid-removal. No read writes the graph or deletes a secret, so the exposure is a stale list, not lost material.
- **Post-commit secret deletes cannot be surfaced as a failed removal.** After a removal's graph prune and row deletes have committed, a failed private-key / Ledger-id / wallet-sig / mnemonic delete emits a sanitized production error through `AppLogger.error` and `SentryService`, then continues: rethrowing would tell the user nothing was removed after the removal already happened. The report contains only the material category and exception type, never an id, address, key, mnemonic or platform exception message. What remains is an orphan nothing indexes, collected by the next explicit wipe's sweep — but it is still encrypted key material on the device until then.
- **The Android vault reports an undecryptable item as absent in one case, deliberately.** `vaultRead` answers `null` when the ciphertext is present but its Keystore alias is gone (uninstall, key invalidation), rather than raising `decrypt_failed`. The alias is unrecoverable, so there is nothing to retry — and that null is never acted on destructively: callers retry, and the DB key is minted only when no database file exists.
- **A PIN attempt refused by a storage failure looks like a wrong PIN.** When `verifyPin` throws, `_onUnlockWithPin` refuses without advancing the cooldown ladder — the right call, since an unreadable store is no evidence against the user — but `wrongPinAttempt` is the only signal `AppLockState.locked` carries, so the lock screen says "Wrong PIN" for what is actually a read failure. A second identical failure also re-emits an identical state, so the shake/message does not re-render. Accepted: the alternative is a new state field for a case the user cannot act on differently.
- **`WalletType.fromDbString` defaults to `hd` instead of failing.** An unknown wallet-type string from a graph or a database row is read as a seed-derived wallet rather than rejected. Consistent with every other `fromDbString` in `core/models/`, and no path derives a key from that value alone, but a corrupt row is silently reinterpreted rather than surfaced.
- **`storeLoginToken`'s iOS `-25299` retry is dead code.** It matches `PlatformException.code == '-25299'`, and the plugin puts the OSStatus in `details`, not `code`. Harmless — a duplicate-item write on that key is re-created by the next login — but it is not the protection it reads as.
- **iOS recovery phrase screenshot.** The Flutter privacy blur covers the app-switcher snapshot but does not prevent an on-screen screenshot of the seed-phrase grid. iOS has no public API to fully block screenshots — mitigations would be `userDidTakeScreenshot` detection + clear-on-detect, or rendering words behind tap-and-hold.
- **Secret clipboard copy has no auto-clear (product decision).** The settings "Show recovery phrase" screen (`recovery_phrase_words_screen.dart`) and the "Show private key" screen (`private_key_reveal_screen.dart`) both do a plain `Clipboard.setData` with **no** expiration — the copied secret persists in the clipboard until overwritten and, on iOS, may propagate via Universal Clipboard to the user's other Apple devices. This is a deliberate product choice (users routinely paste their phrase/key into another password manager or wallet). The auto-clearing path (`SecurityUtils.copyToClipboardWithClear` — OS-enforced 1-minute expiration, `localOnly: true`) still exists and is used by the **onboarding** seed-phrase display (`seed_phrase_display_screen.dart`). If the product decision is revisited, switch the two settings screens back to `copyToClipboardWithClear`.
- **`noPinSet` PIN entry UI.** The lock screen still renders the number pad in biometric-only mode; the bloc no-ops PIN attempts but the UI could be tightened to hide the pad when no PIN exists.
- **A provider key placed directly in an RPC URL is recoverable.** No RPC credential is compiled into the app today — `RPC_PROXY_BASE_URL` is expected to point at a proxy that injects the upstream key server-side. But nothing *stops* an operator from putting `?api-key=…` in that URL, and if they do it is not a secret: a `--dart-define` value is compiled into the binary and recoverable from the snapshot, and the URL also flows to the Solana client where it may surface in stack traces. Keep provider credentials behind the proxy.

> Website signing, in the in-app browser and over WalletConnect, is described under *Website requests* above, not in this list. Mobile Wallet Adapter is not supported; adding it is a new signing surface that needs the same review.

## Adding a new sensitive operation

1. Identify the gate. App-lock-level (already covered) or operation-level (biometric prompt at the action).
2. For operation-level, call `sl<BiometricAuthService>().authenticate(reason: ...)` and short-circuit on non-`success`. Use `biometricOnly: true` only when there's a corresponding app-PIN fallback path. To gate a screen or a destructive action, use `requireReauth` (or `requireReauthForRemoval` for a wallet or account removal) right before the action, not only on the route that leads to it.
3. If reading mnemonic/private key, do it inside the gated branch and let the value go out of scope.
4. Never log the value, never put it in error messages, never include it in Sentry breadcrumbs.
5. Any text field that receives wallet key material (a recovery phrase or a private key) sets `autocorrect: false`, `enableSuggestions: false`, `enableIMEPersonalizedLearning: false` and `autofillHints: null`, so the keyboard neither suggests nor learns it and no autofill service is offered it.

## Files of record

- `lib/core/security/secure_storage.dart` — single source of truth for secrets at rest; routes mnemonics, private keys, the recovery graph, the PIN hash and the biometric flag to the vault and everything re-creatable to `flutter_secure_storage`
- `lib/core/security/mnemonic_vault.dart` — the `art.mallow.wallet/mnemonic_vault` platform channel the mnemonic/private-key paths actually use
- `ios/Runner/MnemonicVaultChannel.swift` — iOS vault: Keychain service `art.mallow.vault`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, no access control
- `android/app/src/main/kotlin/com/mallow/wallet/android/MnemonicVaultChannel.kt` — Android vault: per-secret AES-256-GCM AndroidKeystore key, ciphertext + IV in `mallow_vault_prefs`
- `lib/core/services/seed_vault_service.dart` — the Seed Vault signer: live auth-token resolution, the typed failures, and the assertion that refuses to sign for an address the vault did not resolve
- `android/app/src/main/kotlin/com/mallow/wallet/android/SeedVaultChannel.kt` — the Android half of it: availability probe, runtime permission, content-provider reads off the platform thread, one approval intent in flight at a time
- `lib/core/services/keystone_sign_service.dart` — the Keystone signer: builds the device's sign request from the row's own fingerprint and path, and accepts a reply only after the request-id check and an Ed25519 verification (Solana) or signer recovery (Ethereum) against the row's address
- `packages/keystone_ur/` — the QR codec: UR fountain coding and the Keystone message types, with the decoder's limits on untrusted input
- `lib/core/social_vault/social_vault_crypto.dart` — the social vault format: payload seal, slot wrap, vault key and request signing, pinned by `test/assets/social_vault_vectors.json`
- `lib/core/social_vault/social_vault_service.dart` — opens, creates and edits vaults; the only code that holds a data key in memory
- `lib/core/social_vault/platform_slot_store.dart`, `ios/Runner/SocialVaultSlotChannel.swift`, `android/app/src/main/kotlin/com/mallow/wallet/android/SocialVaultSlotChannel.kt` — the platform slot: iCloud Keychain (synchronizable, `WhenUnlocked`, its own service) and Block Store (end-to-end encrypted backup only)
- `lib/core/social_vault/platform_backup_guard.dart` — re-checks that Block Store backup's encryption on every foreground, pulls entries out of an unencrypted backup and puts them back
- `lib/core/social_vault/apple_web_sign_in.dart` — Sign in with Apple on Android: Apple's web flow in a Custom Tab, answered through the verified `/auth/apple` App Link
- `lib/core/social_vault/passkey_prf.dart` — passkey PRF evaluation; refuses a passkey that yields no PRF output
- `lib/core/security/biometric_auth.dart` — biometric prompts and result enum
- `lib/core/security/transaction_auth_gate.dart` — the remote kill-switch backstop and the configurable value gate, `TransactionAuthOutcome`, default `kTransactionAuthThresholdUsd`
- `lib/core/config/remote_config_service.dart`, `lib/core/config/remote_config.dart` — the kill switch's source: the `GET /v2/config/mobile` cache, the `(chain, flow)` matrix, and the fail-open / last-known-good rules
- `lib/core/services/transaction_signing.dart` — `signSendConfirm`, where the value gate runs before signing
- `lib/core/crypto/wallet_manager.dart` — signing methods (`signTransaction`/`signCompiledTx`); no longer self-prompt — gating is the caller's responsibility via `TransactionAuthGate`
- `lib/shared/widgets/pin_prompt_sheet.dart` — app-PIN fallback sheet for the value gate
- `lib/core/security/app_lock_bloc.dart` — lock state machine
- `lib/shared/widgets/lock_screen.dart` — lock UI
- `lib/app.dart` — lifecycle handling, splash, lock overlay, privacy blur
- `lib/features/onboarding/screens/biometric_setup_screen.dart`, `pin_setup_screen.dart` — onboarding floor
- `lib/features/settings/screens/security_privacy_screen.dart` — runtime toggles + "Require auth over" threshold editor
- `lib/core/security/reauth_gate.dart` — `requireReauth` (biometric, then the app-PIN sheet) and `requireReauthForRemoval`
- `lib/features/settings/screens/show_secrets_screen.dart` — the live recovery-phrase and private-key reveal; self-gates when not reached through the gated in-app tap
- `lib/features/settings/screens/recovery_phrase_screen.dart` — the seed picker for import; its biometric-first view mode is not routed
- `ios/Runner/AppDelegate.swift`, `android/app/src/main/kotlin/.../MainActivity.kt` — native privacy hooks
