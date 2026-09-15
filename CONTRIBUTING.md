# Contributing to Yellowhammer

## Workstation prerequisites

| Prerequisite | Needed by | How `scripts/check-prerequisites.sh` verifies it |
|---|---|---|
| Apple Silicon Mac | Everyone | `uname -m` is `arm64` |
| Xcode toolchain | Everyone | `xcodebuild -version`: pass on the CI pin (see README), warn on another 26.x, fail if missing or older |
| SwiftLint | Everyone | `swiftlint --version`: pass on the CI pin, warn on another version, fail if missing |
| Orca ADE ≥ 1.4.195 (the version the feasibility probes ran against) | Everyone | `orca --version`, else `/Applications/Orca.app` `CFBundleShortVersionString` |
| At least one agent CLI, installed and authenticated | Everyone | `claude auth status` / `codex login status` — no model is ever called |
| `git` on the path a bare environment gets | Everyone | `env -i /bin/sh -c 'command -v git'` |
| Developer ID Application signing identity | Release engineering (P16.1) | `--with-signing`: `security find-identity -v -p codesigning` |
| Access to the scratch Linear team | Rehearsal work (P15.1) | `--with-linear`: reported as SKIP until the board identity lands (P5.1) |

The pinned toolchain versions live in [README.md](README.md#toolchain-pinned-in-ci).

## Check your machine

```bash
scripts/check-prerequisites.sh                              # everyone
scripts/check-prerequisites.sh --with-signing --with-linear # role-dependent checks too
```

Each prerequisite prints `PASS`, `WARN`, `FAIL` or `SKIP`. The script exits 1 if anything fails.

## Workflow

1. Branch from `main`. `main` takes changes by pull request only.
2. Before pushing, run what CI runs:
   ```bash
   swiftlint lint --strict
   swift test --package-path Packages/YellowhammerKit
   xcodebuild -project Yellowhammer.xcodeproj -scheme Yellowhammer build
   ```
   The structural checks in `scripts/ci/` (deployment target, module boundaries, `.gitignore`
   audit, glossary) run locally too.
3. Open a pull request using the template. Its body carries either
   `Spec: <epic>/<story> @ <spec commit sha>` (one line per story; `/spec-cite` builds it), or
   `Spec-Exempt: <reason>` for work that implements no story, such as DevOps. CI refuses a body with
   neither.
4. Every acceptance criterion of a cited story is covered, or listed in the pull request as not
   satisfied, with the reason.
5. All CI checks pass before merge.

The spec in `../yellowhammer-spec` is read-only from this repo: propose changes to its owners, never
edit or copy it here. Conventions for naming, modules, testing and the ubiquitous language are in
[CLAUDE.md](CLAUDE.md).
