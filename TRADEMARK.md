# Trademark and brand policy

The source in this repository is MIT-licensed (see [LICENSE](LICENSE)). Names,
logos, and brand material are **not**. This page says exactly where that line
falls.

## Why a wallet draws this line

A convincing fake wallet is a complete theft toolkit. Someone can fork this
repo, point it at a hostile backend, keep the name and the app icon, and put it
on an APK mirror — and the people who install it will believe they are running
the real thing right up until their funds are gone.

We cannot stop a fork; that is the point of publishing. What we can do is make
sure a fork cannot look like us. A reskin is a small amount of work for an
honest fork and a meaningful barrier for a dishonest one, because the fake
becomes visibly not-mallow at exactly the moment a user is deciding whether to
trust it.

## What is reserved

**All rights reserved. Not covered by the MIT grant:**

- The names **"mallow"** and **"mallow wallet"**, and the mallow wordmark.
- The mallow logo and app icon, wherever they appear in the tree:
  - `assets/icon/`;
  - the platform app icons: `ios/Runner/Assets.xcassets/AppIcon.appiconset/`,
    and the `ic_launcher*` images and adaptive-icon definitions under
    `android/app/src/main/res/` (`mipmap-*/` and `drawable-*/`);
  - the share-extension icon,
    `ios/OpenInMallow/Assets.xcassets/ActionIcon.imageset/`;
  - the copy of `assets/icon/app_icon.svg` embedded as a base64 data URI in
    `lib/features/browser/services/dapp_provider_script.dart`, which the
    in-app browser shows to websites as the wallet's icon.
- Other material under `assets/` that identifies mallow — the loader animation
  and the mallow marks among the interface icons.
- The screenshot in [README.md](README.md) (`docs/images/`). The interface in
  it is ours; the artworks in it are their artists'. Neither is licensed
  onward, so a fork takes its own screenshot of its own build.

**Not ours to reserve, and not ours to license onward.** Some of `assets/` is
third-party, and this policy does not reach it:

- `assets/fonts/` — Geist, Inter and Newsreader, each under its own SIL Open
  Font License, with the terms in the accompanying `*-OFL.txt`.
- `assets/icons/` — interface icons from Tabler, Streamline, Flagpack,
  Iconoir, Radix, Material Symbols and Carbon, alongside the `brand_*` marks
  of other companies (Solscan, Solana Beach, Orb, Apple, Google, X,
  Instagram, Discord, YouTube, Ledger and Keystone), bundled to name those
  services in the interface. THIRD_PARTY_NOTICES.md names each set and, where
  a set is small, its files, and `assets/icons/THIRD_PARTY_LICENSES` carries the licence
  texts. Streamline's icons carry an **attribution condition the app
  satisfies on its About screen**; removing that credit breaks the licence.
- `assets/images/carousel/` — nine works minted and sold on mallow, shown in
  the ring on the welcome screen. **The copyright in each stays with its
  artist**, so nothing here licenses them onward. **A fork must replace these
  files.** Each artist is credited by title and mallow profile in
  THIRD_PARTY_NOTICES.md, and by profile on the app's About screen.
- `assets/images/tokens/` — logos of third-party tokens, protocols and
  marketplaces (Ethereum, Solana, Tezos, USDC, Jupiter, Bonk and others).
  **These are their owners' marks, not mallow's.** They are bundled to identify
  those assets in the interface.
- `assets/model_viewer/` — Google's `<model-viewer>`, which renders 3D
  artworks. It is Apache-2.0, with the licence text in
  `assets/model_viewer/LICENSE`. The libraries compiled into the same bundle
  (Lit, three.js and others) keep their own licences, whose texts are in
  `assets/model_viewer/THIRD_PARTY_LICENSES`.
- `assets/data/public_suffix_list.dat` — Mozilla's Public Suffix List, under
  the Mozilla Public License 2.0. The file keeps its MPL header.

[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) states each obligation in
full, including the licences of bundled code dependencies.

## What you must do when you fork

Before you distribute a build to anyone else:

1. **Rename the app.** Change the display name, the bundle identifier, and the
   application ID. Do not use "mallow" in the name of your app, in your store
   listing, or in a domain that suggests affiliation. That includes the
   share-sheet entry "Open in mallow browser", which is set separately for
   each platform: `ios/OpenInMallow/Info.plist` and the alert title in
   `ios/OpenInMallow/OpenBrowserViewController.m` on iOS, and the
   `ShareTargetActivity` label in `android/app/src/main/AndroidManifest.xml`
   (described in `ShareTargetActivity.kt`) on Android.
2. **Replace the brand assets.** Ship your own logo and app icon, in every
   place listed under "What is reserved" above, including the embedded copy
   in `dapp_provider_script.dart`.
3. **Register your own Chromecast receiver.** Set `CAST_RECEIVER_APP_ID` to
   it. Left at the default, your build casts mallow's receiver onto your
   users' TVs — mallow's page, mallow's branding, mallow's bandwidth — which
   is the reskin failing in the one place a fork is most visible.
4. **Change the wallet identity that websites and WalletConnect peers see.**
   These values are written into the source, not read from the environment,
   so setting your own `WALLETCONNECT_PROJECT_ID` does not change them. Left
   alone, your build introduces itself to every dApp as mallow, with mallow's
   name, logo, website and reverse-DNS id:
   - the WalletConnect `metadata` (`name`, `description`, `url`, `icons`) in
     `lib/features/walletconnect/services/walletconnect_service.dart`;
   - in `lib/features/browser/services/dapp_provider_script.dart`, the
     embedded `icon`, the Wallet Standard `name`, the EIP-6963 provider info
     (`name`, `icon`, `rdns`) and the Tezos Beacon `beaconSender`
     (`id`, `name`);
   - `mallowBeaconId` and the `name` in the Beacon pairing response
     (`postmessage-pairing-response`) in
     `lib/features/browser/services/tezos_beacon_transport.dart`;
   - the Beacon `appMetadata` name in the `permission_response` built by
     `lib/features/browser/services/dapp_request_coordinator.dart`.
5. **Do not imply endorsement.** Do not describe your build as official,
   verified, endorsed by, or affiliated with mallow.

## What you may always do

Nominative use is fine and needs no permission. You may say your project is
"based on mallow wallet", "a fork of mallow wallet", or "compatible with the
mallow API". You may reference the name accurately in documentation, articles,
comparisons, talks, and academic work.

The test is whether a reasonable person could think your build **is** mallow, or
is published by us. Say what your project is; do not say it is ours.

## Official builds

Only builds distributed through the channels listed in
[SECURITY.md](SECURITY.md) are ours. If you find a build using the mallow name
or logo from anywhere else, please report it — the reporting address is in
SECURITY.md, and we would rather hear about it early.

## Questions

If you want to use the name or marks in a way this page does not clearly allow,
ask first. Permission is often granted; it just has to be asked for.
