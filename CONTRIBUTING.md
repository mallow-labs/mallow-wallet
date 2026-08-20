# Contributing

Thanks for taking the time. Pull requests are wanted.

If you are reporting a **security** problem, stop here and read
[SECURITY.md](SECURITY.md) instead — please do not open a public issue.

## Getting it building

```bash
flutter pub get
./di.sh                       # code generation — see below, do NOT use build_runner directly
cp .env.example .env          # then read it; the RPC entry is the one that matters
touch .env.local
flutter test
```

**The Flutter SDK version is pinned to 3.44.8.** CI runs that exact version, and
`dart format` output differs between SDK releases — on a different version the
format check will fail on files you never touched. Use
[fvm](https://fvm.app) or match it manually.

**Always run `./di.sh`, never `dart run build_runner build` at the repo root.**
The root's generated mocks reference types from the packages under `packages/`,
so those have to build first. Build the root first and mockito silently falls
back to `dynamic`, and you get a wall of `invalid_override` errors that look
like your fault and are not. No generated file is checked in, so codegen is a
required step, not an optimisation.

`flutter analyze` and `flutter test` need no configuration at all — nothing
reads config from disk at runtime. You only need real values in `.env` to *run*
the app. See the README's build-variable table for what each one does, whether
you need it, and where a value comes from.

### Building for iOS

That is what the `Gemfile` and `.ruby-version` at the repository root are for,
and it is the only thing they are for. They pin **CocoaPods** — the Flutter iOS
build shells out to `pod`, and a mismatched version rewrites `Podfile.lock` and
the generated Xcode config in ways that are annoying to review. `.ruby-version`
names the Ruby (rbenv, asdf and friends read it); the `Gemfile` pins the
CocoaPods release.

```bash
bundle install                    # once, from the repository root
(cd ios && bundle exec pod install)   # before the first iOS build
```

Re-run `pod install` after any pubspec change that adds or removes a plugin with
an iOS side. Android needs none of this — Gradle resolves its own dependencies.

`Podfile.lock` is **not** part of this source release. `pod install`
writes it, and it pins the pod set *your* toolchain resolved rather than one
this source could keep current — the set changes with every plugin added or
removed, and only a machine running `pod install` can record that. Commit it
in your own fork if you want the pin; that is what the CocoaPods version
above is for.

Before a build you intend to put on a real device, also run:

```bash
tool/check_objc_dupes.sh
```

It catches third-party frameworks whose Objective-C class names collide with
Apple's private ones. That collision is invisible to `flutter analyze`,
`flutter test` and the release build itself, and only surfaces as a crash on
launch. No CI job runs it — it needs a working simulator and Xcode.

## Before you open a pull request

Run the same gates CI runs. All of them must pass:

```bash
dart format lib test                                       # then verify:
dart format --output=none --set-exit-if-changed lib test    # must exit 0
flutter analyze --no-fatal-infos                            # errors AND warnings are fatal
flutter test
for p in packages/*/; do [ -d "$p/test" ] && (cd "$p" && dart test); done
tool/lint/check_sensitive_debug_print.sh                    # no bare debugPrint in the guarded paths
tool/lint/check_openapi_yaml.sh                             # the vendored spec still parses
tool/lint/check_env_documented.sh                           # every build variable is in .env.example
```

Four of those deserve a note:

- **`flutter analyze` treats warnings as fatal**, not just errors. Only `info`
  lints are tolerated. Do not silence a finding with `// ignore:` unless you
  write down why.
- **`flutter test` does not descend into `packages/`.** It runs the root
  package's suite only, which is why the loop above exists. CI runs both, so a
  change that passes locally without it can still fail on a path package.
- **The last two are cheap and catch expensive failures.** A colon-space in an
  unquoted `description` makes the vendored spec unparseable, which emits zero
  Dart models and then surfaces as thousands of unrelated compile errors
  somewhere else; and a build variable missing from `.env.example` means a fork
  that filled in every documented key still gets a misconfigured build with
  nothing to tell them so.
- **The debugPrint guard is a real security check, not style — but know what it
  actually checks.** `debugPrint` is not stripped from release builds, so its
  output still reaches the platform log (logcat on Android, OSLog on iOS), where
  anything printed is readable off the device. The rule is therefore that
  nothing touching keys, mnemonics, seeds, or auth material may be logged.

  The script enforces a **narrower, structural** version of that rule: it fails
  on *any* bare `debugPrint` inside the key- and auth-handling paths listed in
  its `PATHS` array, regardless of what is being printed, and it looks at
  nothing outside them. (Comment lines are exempt — those files document this
  very rule, and a ban that fires on its own documentation gets the
  documentation deleted.) It cannot tell a safe log line from a leaking one, so a
  green run is not evidence that the rest of your diff is clean — that judgement
  is yours and the reviewer's. Inside a guarded path use `AppLogger`
  (`lib/core/observability/app_logger.dart`), which drops non-error events in
  release. If a `debugPrint` there is genuinely release-safe, mark it
  `// ignore: app_logger_only` on the same line and say why in the PR.

## Sign your commits off

This project requires a [Developer Certificate of Origin](https://developercertificate.org/)
sign-off on every commit. It is one line, added automatically by:

```bash
git commit -s
```

It certifies that you wrote the patch, or otherwise have the right to submit it
under this project's license. CI checks for it, and a PR without it cannot be
merged.

## House style

- **Match the surrounding code.** Conformance beats personal taste inside a
  codebase. If you think a convention here is actively harmful, say so in the
  PR rather than quietly doing it differently.
- **Explain *why* in comments, not *what*.** The code already says what it does.
  The comments that earn their place are the ones recording a decision that is
  not obvious, or a bug that is not obvious.
- **Tests should encode why the behaviour matters.** A test that cannot fail
  when the business rule changes is not testing the business rule.
- **Keep changes surgical.** Reformatting adjacent code makes a diff much harder
  to review, and review attention is the scarce resource on a wallet.

## Two things that will look odd

**This code is security-first, and some of it is deliberately awkward.**
Biometric gates, the fail-closed transfer simulation, and the derivation-scheme
plumbing all have sharp edges that exist for a reason. If a constraint looks
pointless, ask before removing it — the failure modes here are silent ones. The
worst class of bug in this codebase produces a *valid signature from the wrong
address*, which does not throw and does not look broken.

**Some comments reference decisions whose context is not public.** This
repository is published from an internal one, and three kinds of pointer into
closed material are removed on the way out:

- **Issue-tracker ids**, which named a ticket you cannot open.
- **`§`-numbered section markers**, which cited clauses of internal design
  specs.
- **Paths and line numbers in our closed-source web client and backend.**
  Where the parity argument still matters the comment names the source
  generically — "the webapp", "the reference web client", "the backend" — and
  keeps the symbol name, because that is the part that carries the reasoning;
  the file layout was never the reason for anything.

In each case the rule was the same: **keep the reason, drop the pointer.** So a
comment may read as though a citation has been snipped out of it — that is what
happened, and it is deliberate rather than sloppy. If one reads as though the
*reason* went with it, that is a bug in the strip: please open an issue and we
will write the reasoning back in.

## Reviews

Expect review to focus on correctness and on the security-sensitive paths first.
A PR that touches signing, key handling, or transaction construction will get
slower and more skeptical review than one that does not. That is not a comment
on your work.
