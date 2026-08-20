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
- The mallow logo and app icon (`assets/icon/`).
- Other material under `assets/` that identifies mallow — the loader animation
  and the mallow marks among the interface icons.

**Not ours to reserve, and not ours to license onward.** Some of `assets/` is
third-party, and this policy does not reach it:

- `assets/fonts/` — Geist, Inter and Newsreader, each under its own SIL Open
  Font License, with the terms in the accompanying `*-OFL.txt`.
- `assets/icons/` — from Streamline and Tabler, alongside the `brand_*`
  marks of other companies (Solscan, Solana Beach, Orb, Apple, Google, X,
  Instagram, Discord and YouTube), bundled to name those
  services in the interface. THIRD_PARTY_NOTICES.md lists them file by file.
  The Streamline set carries an **attribution condition the app satisfies on
  its About screen**; removing that credit breaks the licence.
- `assets/images/carousel/` — nine works minted and sold on mallow, shown in
  the ring on the welcome screen. **The copyright in each stays with its
  artist**, so nothing here licenses them onward. **A fork must replace these
  files.** Each artist is credited by title and mallow profile in
  THIRD_PARTY_NOTICES.md, and by profile on the app's About screen.
- `assets/images/tokens/` — logos of third-party tokens, protocols and
  marketplaces (Ethereum, Solana, Tezos, USDC, Jupiter, Bonk and others).
  **These are their owners' marks, not mallow's.** They are bundled to identify
  those assets in the interface.

[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) states each obligation in
full, including the licences of bundled code dependencies.

## What you must do when you fork

Before you distribute a build to anyone else:

1. **Rename the app.** Change the display name, the bundle identifier, and the
   application ID. Do not use "mallow" in the name of your app, in your store
   listing, or in a domain that suggests affiliation.
2. **Replace the brand assets.** Ship your own logo and app icon.
3. **Register your own Chromecast receiver.** Set `CAST_RECEIVER_APP_ID` to
   it. Left at the default, your build casts mallow's receiver onto your
   users' TVs — mallow's page, mallow's branding, mallow's bandwidth — which
   is the reskin failing in the one place a fork is most visible.
4. **Do not imply endorsement.** Do not describe your build as official,
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
