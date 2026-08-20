## What this changes

<!-- And why. The diff shows what; the reason is the part reviewers cannot recover. -->

## How it was verified

<!-- Which tests, on what device or simulator. "CI is green" is not verification
     for anything touching signing, key handling, or transaction construction. -->

## Checklist

- [ ] `dart format --output=none --set-exit-if-changed lib test` exits 0
- [ ] `flutter analyze --no-fatal-infos` exits 0 (warnings are fatal, not just errors)
- [ ] `flutter test` passes
- [ ] `tool/lint/check_sensitive_debug_print.sh` passes
- [ ] `tool/lint/check_openapi_yaml.sh` and `tool/lint/check_env_documented.sh` pass
- [ ] `dart test` passes in every `packages/*/` that has a `test/` directory
- [ ] Every commit is signed off (`git commit -s`) — see `CONTRIBUTING.md` in the repository root

## Security

- [ ] This does not log keys, mnemonics, seeds, or auth material
- [ ] This does not remove or weaken a biometric gate, a signing prompt, or the transfer simulation
- [ ] This does not change derivation paths or the derivation scheme

<!-- If you ticked none of the boxes above because the change is nowhere near
     that code, say so and delete the section — that is a fine answer. If your
     change DOES touch it, expect slower and more skeptical review. That is not
     a comment on your work; the failure modes in this area are silent ones. -->
