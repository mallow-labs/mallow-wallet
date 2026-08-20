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

`assets/icons/` holds three kinds of material. Two are icon sets, each under
its own licence:

| Set                                     | Licence                                                                                              | Obligation                                                              |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| [Streamline](https://streamlinehq.com/) | [Streamline Free licence](https://help.streamlinehq.com/en/articles/5354376-streamline-free-license) | **Attribution required**, as hyperlinked text on an app's About surface |
| [Tabler Icons](https://tabler.io/icons) | MIT — Copyright © 2020-2026 Paweł Kuna                                                               | Retain the copyright and permission notice                              |

🛑 **The Streamline credit in the app is a licence condition, not a courtesy.**
It is rendered by `_IconCredits` in
`lib/features/settings/screens/about_screen.dart` as "Free icons from
Streamline", linked to `streamlinehq.com`. Delete that line and every
Streamline icon in the build is unlicensed. If you fork and reskin, either keep
the credit or replace the icons.

The Streamline free licence also does **not** permit shipping these icons as
assets your own users can pick from — they are interface chrome here, which is
what the licence allows.

The third kind is other companies' marks, bundled so the interface can name the
service each one belongs to:

| File                                                                                    | Owner                          | Where it appears           |
| --------------------------------------------------------------------------------------- | ------------------------------ | -------------------------- |
| `brand_solscan.svg`, `brand_solana_beach.svg`, `brand_orbmarkets.svg`                   | Solscan, Solana Beach, Orb     | the explorer picker        |
| `brand_apple.svg`, `brand_google.svg`                                                   | Apple, Google                  | the social sign-in buttons |
| `brand_x.svg`, `brand_ig.svg`, `brand_discord.svg`, `brand_youtube.svg`, `brand_yt.svg` | X, Instagram, Discord, YouTube | profile social links       |

**These are their owners' marks, not mallow's**, they are here for
identification only, and the MIT grant does not license them onward. The
reasoning is the same as for the token logos below, including dropping any mark
whose owner objects.

Apple's and Google's marks additionally carry their owners' own sign-in
branding guidelines, which govern how those buttons may be drawn; a fork that
reskins the sign-in surface is responsible for staying inside them.

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
