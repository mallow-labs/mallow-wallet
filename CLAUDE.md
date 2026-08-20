# CLAUDE.md — AI Development Guidelines for mallow wallet

Agent-facing entry point. Humans read [CONTRIBUTING.md](CONTRIBUTING.md), which covers the same gates.

**Trust source over prose.** Any doc here, this file included, can lag the code. When a comment and the code disagree, the code is right — fix the comment as you pass.

---

## 🛑 Security Rules (BLOCKING)

1. **NEVER log or print private keys, mnemonics, or seeds.**
2. **NEVER store sensitive data in plain text.** Mnemonics and imported private keys go to `MnemonicVault` (`lib/core/security/mnemonic_vault.dart`); everything else sensitive goes to `flutter_secure_storage` via `SecureWalletStorage`. Never `SharedPreferences`, `NSUserDefaults`, or a plain file. [docs/security.md](docs/security.md) says which store owns what.
3. **NEVER commit API keys, secrets, or credentials.** Use `--dart-define`.
4. **NEVER send sensitive data to analytics or error tracking.**
5. **NEVER weaken an auth gate — and never overstate one.** Read the code before you assert a requirement:
   - The **app-lock floor is mandatory**: onboarding cannot finish with neither PIN nor biometrics enabled (`pin_setup_screen.dart` offers Skip only when biometrics is already on). Do not add a path out of it.
   - **Per-transaction step-up auth is opt-in and OFF by default.** `TransactionAuthGate.authorize` returns `allowed` immediately when `SecureWalletStorage.loadTransactionAuthEnabled()` is false, which is the default. Biometrics are *not* required per signature, and no document may say they are.
   - 🛑 Do not "simplify" the `usdValue == null` branch of `_exceedsThreshold`. Unknown value counts as over-threshold: the gate fails **closed** when a price is unavailable, which is the one case an attacker can arrange.
   - 🛑 Keep both flow gates — the local `AppFlow.isImplemented` arm, then the remote kill-switch lookup — **above every other statement** in `authorize`. Both early returns below them return `allowed`, so a check placed after either is inert for every user with step-up auth off — that is, most of them.

---

## 🌐 Public Mirror — Assume Every Line You Write Is Published (BLOCKING)

Every release is synced to a public open-source repository. It ships this same tree minus a short list of internal paths; everything else, this file included, goes out verbatim. Write for a stranger who cannot open anything internal.

**Keep the reason, drop the pointer.** A comment earns its place by recording *why* the code looks the way it does. A citation of a closed source is not that reason — it is a lookup a public reader cannot perform. Removing a pointer must not take the sentence with it.

Never write into `lib/`, `test/`, `packages/`, `docs/`, or published Markdown:

1. **Issue-tracker ids** — write the decision the ticket recorded instead.
2. **`§`-numbered section markers** citing internal design specs.
3. **Paths or line numbers in the closed web client or the backend** — keep the symbol name, which carries the argument, and name the source generically: "the webapp", "the backend".
4. **Names of private repositories, private npm scopes, or paths inside them.**
5. **First-party service hostnames** — name the env var (`API_BASE_URL`, `IMAGE_CDN_BASE_URL`, …), never the host.
6. **Internal infrastructure** — the CI system, the chat host, the build-config secret store, the signing-certificate repository.
7. **Links to internal-only files** — internal plan and QA directories, release plumbing, every `*.ctx.md`. They are stripped, so the link is dead once published. Inline what the reader needs.

A deny-list gate greps the stripped release tree and fails the sync on a hit, so an internal pointer blocks a release later rather than drawing a review comment now.

---

## ✅ CI Gates — Run Before Every Commit (BLOCKING)

Both gates block every PR. Run these on any change to `lib/` or `test/` and fix every file reported:

```bash
dart format lib test                                      # apply
dart format --output=none --set-exit-if-changed lib test  # verify exit 0 (matches CI)
flutter analyze --no-fatal-infos                          # exit 0; errors and warnings fatal, infos not
tool/lint/check_sensitive_debug_print.sh                  # no bare debugPrint in the guarded paths
```

⚠️ Never run `--set-exit-if-changed` without `--output=none`: that form rewrites the files *and* exits 1, so it looks like a failure you cannot reproduce on the second run.

⚠️ `check_sensitive_debug_print.sh` does not read what you print. It is a structural ban on bare `debugPrint` inside the key- and auth-handling paths listed in its own `PATHS` array, whatever the argument, and it checks nothing outside them. A pass is not "nothing sensitive is logged" — that judgement stays yours everywhere else in `lib/`. Inside a guarded path use `AppLogger` (`lib/core/observability/app_logger.dart`), which drops non-error events in release; the escape hatch is `// ignore: app_logger_only` on the same line, with a written reason.

- **Fix formatting in the same commit.** One unformatted file fails the job, even on a one-line edit. There is no format-only follow-up commit.
- **No analyzer errors or warnings.** Fix unused imports, undefined symbols, and parameter mismatches; do not silence them with `// ignore:` without a documented reason.
- **Regenerate generated code, never hand-edit it.** Analyzer errors in `*.g.dart`, `*.freezed.dart` or `lib/di.config.dart` mean run `./di.sh`. Nothing generated is checked in — CI regenerates before the gates, so a stale local copy passes locally and the mismatch surfaces in review.
- **Reproduce a CI `Analyze` failure locally before pushing a fix.**

---

## 🚀 Pre-Release Check (BLOCKING)

```bash
tool/check_objc_dupes.sh    # needs a working iOS simulator and Xcode; no CI job runs it
```

Third-party frameworks whose class names collide with Apple private frameworks crash on app launch only — invisible to `flutter analyze`, `flutter test`, and the release build itself. Run it before cutting a build for a real device, and after any iOS-touching dependency bump (`flutter pub upgrade`, any pod-affecting change) even when Dart-only behavior looks fine. `is implemented in both` means do not ship: bump or replace the dependency.

---

## 🖼️ Network Images — Use MallowNetworkImage

All remote images MUST go through `MallowNetworkImage` (`lib/shared/widgets/mallow_network_image.dart`). It routes the URL through the image CDN (`IMAGE_CDN_BASE_URL`; a pass-through when unset) and sets `memCacheWidth` from `logicalSize × devicePixelRatio`, capping the decode at the rendered size — without it one 4000×4000 NFT decodes to ~64 MB of RGBA and triggers iOS watchdog kills on scroll-heavy screens.

```dart
MallowNetworkImage(
  imageUrl: rawUrl,        // RAW upstream URL — the wrapper calls MallowImage.cdnUrl itself
  logicalSize: 60,         // largest rendered logical (dp) dim — drives CDN bucket + memCacheWidth
  width: 60, height: 60,   // optional render constraints
  borderRadius: BorderRadius.circular(8),      // circle avatars: pass size / 2
  cdnFit: 'cover',         // or 'inside' for variable / native aspect ratio
  placeholderBuilder: (_) => ShimmerBox(...),  // default: a divider-coloured box
  errorBuilder: (_) => _myFallback(),          // default: the broken-image icon
)
```

1. **Never use the `CachedNetworkImage` *widget* or `Image.network` in app code.** Both bypass the decode cap; `Image.network` also bypasses the disk cache. Review rejects either.
   **`CachedNetworkImageProvider` is allowed** for the two jobs with no widget to wrap — `precacheImage` warm-ups and aspect-ratio probing (`ImageProvider.resolve`) — as in `spotlight_carousel.dart`, `artwork_sheet_image.dart` and `listing_review_artwork_header.dart`. Two conditions: pass `cacheManager: MallowImageCacheManager.instance` so the probe shares the wrapper's disk cache, and wrap in `ResizeImage` wherever the result is painted.
2. **Pass the RAW URL, not a CDN-wrapped one.** Passing `MallowImage.cdnUrl(url, ...)` double-wraps and breaks the proxy.
3. **`logicalSize` is the largest rendered dimension in dp.** Fixed thumbs: the constant (`60`, `48`). Full-width tiles: `MediaQuery.sizeOf(context).width` or the bounded width. Variable-aspect masonry: `LayoutBuilder` + `constraints.maxWidth` with `cdnFit: 'inside'`.
4. **Set `addAutomaticKeepAlives: false, addRepaintBoundaries: false`** on every `SliverChildBuilderDelegate` hosting these tiles. Off-screen retention defeats the cap and causes the same crashes.

**Exceptions** (do not migrate without discussion): `lib/features/artwork/screens/artwork_detail_screen/` — the **directory**, not the same-named file beside it, which references neither; the call sites are in its `artwork_image.dart`, which intentionally renders the full 800-bucket artwork near-full-screen. And `lib/features/cast/widgets/cast_animated_artwork.dart` + `cast_receiver_view.dart`, which use `extended_image` for animated/zoomable behavior the wrapper does not cover.

---

## Orientation

A security-first Solana / Ethereum / Tezos mobile wallet. Flutter, Clean Architecture, BLoC.

`lib/core/` holds cross-cutting machinery (crypto and derivation, secure storage, networking, router, config); `lib/features/<feature>/` holds each feature as `data/` `services/` `screens/` `widgets/` `models/`; `lib/shared/` holds the theme and reusable widgets; `packages/` holds the standalone Dart packages (`ledger_*`, `jupiter_aggregator`, `mallow_api`).

Read before touching anything that talks to the backend:

- [docs/architecture.md](docs/architecture.md) — file structure, naming, state management.
- [docs/api.md](docs/api.md) — the `/v1` vs `/v2` split. Different services with different wire conventions; picking the wrong one is the common first mistake.

Also in `docs/`: [security.md](docs/security.md), [backend.md](docs/backend.md) (every external service and what breaks without it), [artwork_state.md](docs/artwork_state.md), [keystone.md](docs/keystone.md), [workflow.md](docs/workflow.md) (CLI, adding features, testing).

### Theme colors

Light/dark token pairs on the `MallowColors` `ThemeExtension` (`lib/shared/theme/mallow_colors.dart`) — read that file for the values. Always take them from the context; never hardcode a hex literal, and never use `MallowTheme`'s legacy `static const` color fields.

```dart
final c = context.mallowColors;
Container(color: c.bgPrimary, child: Text('hi', style: TextStyle(color: c.textPrimary)));
```

Tokens: `bgPrimary`, `bgSurface`, `surfaceMuted`, `bgTransparent`, `textPrimary`, `textSecondary`, `textTertiary`, `accent`, `textOnAccent`, `divider`, `dividerLight`, `positive`, `error` / `negative`, `warning`, `shadow`, `scrim`. `shadow` takes its alpha at the call site; `scrim` includes it. The light and dark variants of `accent` and `positive` differ deliberately — the dark values wash out on the light background — so do not collapse them.

### Derivation paths

Per-account-index, not fixed. `$index` is the account index shown in the import picker. Canonical source: `lib/core/crypto/derivation.dart` (`MultiChainDerivation`).

| Chain | Path | Curve / notes |
| ----- | ---- | ------------- |
| Solana (standard) | `m/44'/501'/$index'/0'` | Ed25519 — matches Phantom / Solflare / browser wallets |
| Solana (legacy) | `m/44'/501'/$index'` | Ed25519 — import-only, behind the legacy-derivation toggle |
| Solana (root) | `m/44'/501'` | Ed25519 — index-less, so it exists only at index 0 |
| Ethereum / EVM | `m/44'/60'/0'/0/$index` | secp256k1 (BIP32) — index is the **last** component, not the account |
| Tezos (tz1) | `m/44'/1729'/$index'/0'` | SLIP-0010 Ed25519, then Base58Check(`tz1` + Blake2b-160(pubkey)) |

🛑 **The scheme is part of a wallet's identity.** `SolanaDerivationScheme` (`standard` / `legacy` / `root`, mapped by `MultiChainDerivation.solanaHdPath`) must round-trip through the wallet row. The wrong scheme produces a **valid signature from a different address**, which fails silently rather than erroring. The enum is declared in `packages/ledger_solana/` despite being used app-wide.

### CLI

```bash
cp .env.example .env    # then fill it in — see docs/backend.md
flutter pub get
./di.sh                 # codegen — NOT bare build_runner
flutter test
./run.sh                # flutter run with .env + .env.local compiled in; extra flags pass through
```

**Always `./di.sh`, never bare `dart run build_runner build` at the root.** It builds the leaf path packages (`packages/mallow_api`, `packages/jupiter_aggregator`) first — in parallel, with `build_runner clean` — and only then the root. Root-first breaks two ways: the root's mockito mocks silently fall back to `dynamic` for leaf-package types, giving `invalid_override` analyzer errors; and `mallow_api`'s models, generated from `openapi/openapi.yaml`, are skipped by a warm incremental cache that does not reliably invalidate on spec content changes (`flutter clean` does not clear sub-package caches).

**`.env` and `.env.local` are build-time inputs, never bundled assets.** A Flutter asset ships as readable plaintext inside the IPA/APK, so config is compiled in with `--dart-define-from-file` instead (see `Config` in `lib/core/config/environment.dart`).

1. Neither file needs to exist for `flutter analyze` or `flutter test` — nothing reads config from disk at runtime. ⚠️ But when you *do* pass one, a **missing** path is a hard build error and an **empty** file is fine — the exact inverse of the old `flutter_dotenv` rule. Prefer `./run.sh` over a hand-written `flutter run`: it wires both files and creates an empty `.env.local` placeholder.
2. **Never add `.env*` back to the `assets:` list in `pubspec.yaml`.** That is the regression this guards against.
3. Tests vary a `Config` value through `Config.debugOverrides` (`--dart-define` is const, so it cannot change per-test). Clear it in `tearDown`.
