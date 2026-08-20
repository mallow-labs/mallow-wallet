# Security policy

This is a self-custody wallet. A bug here can cost someone their funds
irreversibly. We would much rather hear about a problem from you than from the
people it happened to.

## Reporting a vulnerability

**Email [security@mallow.art](mailto:security@mallow.art).** The address is
monitored.

You may also use GitHub's [private vulnerability
reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository, which reaches the same people.

**Please do not open a public issue for a security problem.** Public issues are
indexed within minutes, and for a wallet that turns a report into a race.

### What to expect

| | |
|---|---|
| First response | Within 3 business days |
| Triage decision | Within 10 business days |
| Fix and disclosure | Coordinated with you; we will tell you our timeline and keep you updated if it slips |

### What helps

A description of the impact, the steps to reproduce it, and the version or
commit you tested. A proof of concept is welcome but never required — a clear
description of a real problem beats a vague report with an exploit attached.

Report what you find even if you are not certain it is exploitable. Deciding
that is our job, and we would rather assess ten non-issues than miss one.

### Please do not

Test against other people's wallets or funds, or against our production
infrastructure in a way that degrades it for real users. Use your own wallets
and your own test funds. Everything you need to run the app against your own
backend is in the README.

## Scope

**In scope:** this repository. The app's key handling, derivation, signing
gates, storage, transaction construction, local state, and the Dart packages
under `packages/`.

**Out of scope, but still worth reporting to the same address:** the backend
services this app talks to. Those are separate, private systems and are not part
of this repository. Report them to us anyway — we own them, we just cannot show
you the source.

Also out of scope: findings in third-party dependencies that we merely consume
(report those upstream, though a heads-up is appreciated), and reports whose only
content is automated-scanner output with no analysis.

## Rewards

**We do not run a bug bounty.** We are saying so plainly rather than leaving you
to guess, because your time has value and you deserve to know before you spend
it.

What we do offer: we will credit you by name in the release notes and the
advisory, unless you would rather stay anonymous. Tell us which you prefer.

## Verifying you have a genuine build

**mallow wallet is not on the App Store or Google Play yet.** It will be
published to both, and this section will name the listings when it is. Saying so
matters more than it looks: a document that points you at two listings that do
not exist would have you accept *any* build claiming to be the store one.

Until the listings are live, these are the only official builds:

- **iOS** — **TestFlight**, through an invitation from mallow.
- **Android** — **Google Play closed testing**, through an invitation from
  mallow.

Both are invitation-based. If you did not get the link from us, it is not ours.

A build from anywhere else is not ours either, whatever it is called and
whatever logo it carries. Anyone can fork this repository, point it at a backend
they control, and publish the result — that is a normal consequence of open
source, and it is exactly why the name and the brand are not covered by the MIT
license (see [TRADEMARK.md](TRADEMARK.md)).

Builds are **not** bit-for-bit reproducible today, so you cannot verify a
binary against this source yourself. The guarantee we offer is narrower and we
would rather state it accurately: the source is here to audit, and the channels
above are the only places we publish.

If you find a build using the mallow name or logo from any other source, please
report it to the address above.
