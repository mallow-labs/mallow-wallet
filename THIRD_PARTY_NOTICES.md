# Third-party notices

The MIT licence in [LICENSE](LICENSE) covers the code in this repository. It
does not cover the third-party material listed here, each item of which is
under its own terms. [TRADEMARK.md](TRADEMARK.md) covers the mallow name and
brand.

If you fork this project, these obligations travel with the material — they are
not something the MIT grant discharges for you.

## Onboarding artwork

`assets/images/carousel/` holds nine works by nine independent artists, each
one minted and sold on mallow. They are compiled into the binary as
`kDefaultCarouselAssets` and shown in the rotating ring on the welcome screen.

**The copyright in each work stays with its artist.** They are shown here to
illustrate mallow's own builds, credited by title and mallow profile; that is
not a licence to pass on, and the MIT grant in [LICENSE](LICENSE) does not
reach these files.

🛑 **If you fork this project, replace these nine files.** Shipping another
artist's work inside a build that is not mallow's is not something this
repository can grant you. Keeping them and removing the credit is worse, not
better.

| File              | Artwork         | Artist                                                       |
| ----------------- | --------------- | ------------------------------------------------------------ |
| `carousel_1.webp` | Sugar Rush      | [@trevelviz](https://mallow.art/u/trevelviz)                 |
| `carousel_2.webp` | Lover 50        | [@wetiko](https://mallow.art/u/wetiko)                       |
| `carousel_3.webp` | Perenimals #406 | [@perenimals](https://mallow.art/u/perenimals)               |
| `carousel_4.webp` | #101            | [@solfriendssociety](https://mallow.art/u/solfriendssociety) |
| `carousel_5.webp` | World           | [@degenpoet](https://mallow.art/u/degenpoet)                 |
| `carousel_6.webp` | Taipan          | [@grey](https://mallow.art/u/grey)                           |
| `carousel_7.webp` | Cadence in Gold | [@chronicpainting](https://mallow.art/u/chronicpainting)     |
| `carousel_8.webp` | ZEKE            | [@scum](https://mallow.art/u/scum)                           |
| `carousel_9.webp` | Brand new SLAY  | [@amet](https://mallow.art/u/amet)                           |

The same credit is rendered in the app by `_ArtworkCredits` in
`lib/features/settings/screens/about_screen.dart`, next to the icon credit
below.

## Icons

`assets/icons/` holds two kinds of material: icons from published icon sets,
and other companies' marks. The icon sets are under these licences, and the
full licence texts ship in `assets/icons/THIRD_PARTY_LICENSES`, which is
bundled into the app with the icons:

| Set                                     | Licence                                                                                              | Files                                                                    | Obligation                                                              |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------- |
| [Tabler Icons](https://tabler.io/icons) | MIT — Copyright (c) 2020-2026 Paweł Kuna                                                             | `notif_*.svg`, `verified.svg`, `pref_language.svg` and many other icons  | Keep the copyright and permission notice                                |
| [Streamline](https://streamlinehq.com/) | [Streamline Free licence](https://help.streamlinehq.com/en/articles/5354376-streamline-free-license) | Streamline's own free icons                                              | **Attribution required**, as hyperlinked text on an app's About surface |
| Streamline Core, Remix style, free tier | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)                                            | `alert_triangle.svg`, `no_wifi.svg`                                      | **Attribution required**, with a link to the licence                    |
| [Flagpack](https://flagpack.xyz/)       | MIT — Copyright (c) 2021 Yummygum                                                                    | the twelve `lang_*.svg` flags                                            | Keep the copyright and permission notice                                |
| [Iconoir](https://iconoir.com/)         | MIT — Copyright (c) 2021 Luca Burgio                                                                 | `brand_youtube.svg`                                                      | Keep the copyright and permission notice                                |
| [Radix Icons](https://www.radix-ui.com/icons) | MIT — Copyright (c) 2022 WorkOS                                                                | `dots_vertical.svg`                                                      | Keep the copyright and permission notice                                |
| [Material Symbols](https://github.com/google/material-design-icons) | Apache-2.0 — Google LLC                                  | `bluetooth.svg`                                                          | Ship the licence text; mark modified files                              |
| [Carbon](https://github.com/carbon-design-system/carbon) | Apache-2.0 — Copyright 2015 IBM Corp.                                               | `pref_app_theme.svg`                                                     | Ship the licence text; mark modified files                              |

Iconoir, Radix Icons, Material Symbols and Carbon reach this repository
through Streamline, which redistributes those open-source sets under their
original licences; their files keep the set's name in the root group `id`
(for example `Dots Vertical Streamline Radix`). The Material Symbols and
Carbon files are Streamline's rescaled versions of the originals, which
`assets/icons/THIRD_PARTY_LICENSES` records as the modification notice
Apache-2.0 asks for.

🛑 **The Streamline credit in the app is a licence condition, not a courtesy.**
It is rendered by `_IconCredits` in
`lib/features/settings/screens/about_screen.dart` as "Free icons from
Streamline", linked to `streamlinehq.com`. Delete that line and every
Streamline icon in the build is unlicensed. If you fork and reskin, either keep
the credit or replace the icons.

The Streamline free licence also does **not** permit shipping these icons as
assets your own users can pick from — they are interface chrome here, which is
what the licence allows.

The second kind is other companies' marks, bundled so the interface can name the
service each one belongs to:

| File                                                                                    | Owner                          | Where it appears           |
| --------------------------------------------------------------------------------------- | ------------------------------ | -------------------------- |
| `brand_solscan.svg`, `brand_solana_beach.svg`, `brand_orbmarkets.svg`                   | Solscan, Solana Beach, Orb     | the explorer picker        |
| `brand_apple.svg`, `brand_google.svg`                                                   | Apple, Google                  | the social sign-in buttons |
| `brand_x.svg`, `brand_ig.svg`, `brand_discord.svg`, `brand_youtube.svg`, `brand_yt.svg` | X, Instagram, Discord, YouTube | profile social links       |
| `brand_ledger.svg`, `brand_ledger_mark.svg`                                             | Ledger SAS                     | the Ledger wallet badge and the hardware-wallet chooser |
| `brand_keystone.svg`                                                                    | Keystone                       | the Keystone wallet badge and the hardware-wallet chooser |
| `web3auth_mark.png`                                                                     | Web3Auth                       | the badge on a wallet made by the older sign-in |

**These are their owners' marks, not mallow's**, they are here for
identification only, and the MIT grant does not license them onward. The
reasoning is the same as for the token logos below, including dropping any mark
whose owner objects.

Apple's and Google's marks additionally carry their owners' own sign-in
branding guidelines, which govern how those buttons may be drawn; a fork that
reskins the sign-in surface is responsible for staying inside them.

`web3auth_mark.png` is Web3Auth's logo, white on a transparent background,
copied unchanged from Web3Auth's own website
(`https://web3auth.io/images/web3authlogodark.png`). It is Web3Auth's
trademark. The app draws it on Web3Auth's blue, as a small badge on the Google
or Apple icon, for one purpose: to say that a wallet was created through
Web3Auth's sign-in. The app no longer contains that sign-in, and the badge
claims no partnership or endorsement. A fork keeps or removes the file on the
same reasoning as the other marks here.

## Fonts

`assets/fonts/` is third-party and is **not** covered by the MIT grant or by
the mallow trademark reservation. Each family ships its own licence text
alongside the binaries:

| Family     | Licence                                                       |
| ---------- | ------------------------------------------------------------- |
| Geist      | SIL Open Font License 1.1 — `assets/fonts/Geist-OFL.txt`      |
| Inter      | SIL Open Font License 1.1 — `assets/fonts/Inter-OFL.txt`      |
| Newsreader | SIL Open Font License 1.1 — `assets/fonts/Newsreader-OFL.txt` |

## Token logos

`assets/images/tokens/` holds logos for third-party tokens, protocols and
marketplaces — among them Ethereum, Solana, Tezos, USDC, Jupiter and Bonk.

**These are other projects' marks.** They are bundled to identify those assets
in the interface, which is nominative use. mallow claims no rights in them,
they are outside the "all rights reserved" statement in
[TRADEMARK.md](TRADEMARK.md), and the MIT grant does not license them onward.
A fork that redistributes them does so under the same nominative-use reasoning,
and should drop any mark whose owner objects.

## Public suffix list

`assets/data/public_suffix_list.dat` is Mozilla's
[Public Suffix List](https://publicsuffix.org/), bundled unmodified. The
in-app browser reads it to find a site's registrable domain (`bbc.co.uk` for
`www.bbc.co.uk`): the part of a long host the address bar always keeps visible,
and the test for whether two hosts are the same site.

It is under the **Mozilla Public License 2.0**, not MIT, and the MIT grant in
[LICENSE](LICENSE) does not cover it. The file keeps its MPL header and the
upstream version and commit it was taken from. MPL-2.0 is file-level copyleft:
it applies to this file only, not to the code that reads it. A fork that ships
the file keeps that header, and a fork that changes the file publishes its
changes under MPL-2.0.

## Vendored code

`packages/keystone_ur/` contains a Dart port of Blockchain Commons'
[bc-ur](https://github.com/BlockchainCommons/bc-ur) reference implementation of
Uniform Resources: bytewords, CRC-32, the xoshiro256\*\* sampler and the
fountain encoder and decoder under `lib/src/bc_ur/`, the `UrEncoder` and
`UrDecoder` in `lib/src/ur.dart`, and the port of bc-ur's test suite and its
vectors in `test/bc_ur_test.dart` and `test/vectors/bc_ur_vectors.dart`. Those
files are **BSD-2-Clause Plus Patent** (© 2020 Blockchain Commons, LLC), not
MIT; xoshiro256\*\* itself is CC0. bc-ur's README also lists its CRC-32
source as BSD-3-Clause, so that text is included too. The package's test
vectors from Keystone's SDKs and firmware are MIT and ISC. The licence texts
and a file-by-file account of what was ported from where are in
`packages/keystone_ur/LICENSE` and `packages/keystone_ur/NOTICE`, and a fork
that ships the package carries both.

`packages/passkeys_android/` is Corbado's
[`passkeys_android`](https://pub.dev/packages/passkeys_android) 2.15.0, the
Android half of the passkeys plugin, with two changes: a passkey response that
cannot be parsed is no longer written to the system log or into the error
returned to Dart, and two permissions the plugin cannot use are no longer
requested. It is **BSD-3-Clause** (© 2023 Corbado GmbH), not MIT. The licence
text is `packages/passkeys_android/LICENSE`, the changes are described in
the `README.md` beside it, and a fork that ships the package carries both.

## 3D model viewer

`assets/model_viewer/model-viewer-umd.min.js` is Google's
[`<model-viewer>`](https://github.com/google/model-viewer) 4.3.1, the
`dist/model-viewer-umd.min.js` file from the `@google/model-viewer` npm package,
with only its trailing source-map comment removed. The artwork screen uses it to
render 3D artworks. It is **Apache-2.0** (© Google LLC); the licence text ships
beside it as `assets/model_viewer/LICENSE` and is registered on the app's
licence page.

The bundle also compiles in other libraries: Lit (BSD-3-Clause), and three.js,
gainmap-js, fflate, the meshoptimizer decoder, ktx-parse and zstddec (all MIT),
the last with the Zstandard decoder it embeds (BSD-3-Clause). The bundle itself
does not carry their notices in full: three.js and Lit appear only as one-line
SPDX tags, and gainmap-js has no notice at all. Their full licence texts are in
`assets/model_viewer/THIRD_PARTY_LICENSES`, which sits beside the bundle and
goes into the app with it. A fork that ships the bundle keeps both `LICENSE`
and `THIRD_PARTY_LICENSES` with it.

## Dart and Flutter dependencies

Resolved packages are listed in `pubspec.lock`. The overwhelming majority are
BSD-3, MIT, or Apache-2.0 — those are not enumerated here. Two cases are worth
stating explicitly, because a licence scan will surface them and the answers
are not obvious.

### `opentype_dart` ships without a licence

`opentype_dart` arrives transitively (via `three_js_text`, used by the
onboarding animation). Its `LICENSE` file contains the placeholder text
`Add your license here.`, which is not a grant of anything. Absent a licence,
default copyright applies. This is an upstream defect rather than a choice made
here; it is recorded so nobody assumes the tree is uniformly permissive.

### Copyleft packages that never reach a build

`bluez`, `dbus` and `gtk` are **MPL-2.0** and appear in `pubspec.lock`
transitively: `universal_ble` → `bluez` → `dbus`, and `app_links_linux` → `gtk`.

They are the **Linux desktop** implementations of those plugins. This app
targets iOS and Android only, so none of them is compiled into a shipped
binary — they are resolved by `flutter pub get` and never linked. A scanner
reading `pubspec.lock` alone will flag them; this paragraph is the answer.

Some scanners report these as AGPL. That is a false positive: MPL-2.0 names the
AGPL in its "Secondary Licenses" clause, and a scanner matching on the string
rather than the licence header picks it up. Check the `LICENSE` file in the
package itself, which opens "Mozilla Public License Version 2.0".
