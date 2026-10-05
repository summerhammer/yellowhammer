# Contributing to Yellowhammer

## Workstation prerequisites

| Prerequisite | Needed by | How `scripts/check-prerequisites.sh` verifies it |
|---|---|---|
| Apple Silicon Mac | Everyone | `uname -m` is `arm64` |
| Xcode toolchain | Everyone | `xcodebuild -version`: pass on the CI pin (see README), warn on another 26.x, fail if missing or older |
| SwiftLint | Everyone | `swiftlint --version`: pass on the CI pin, warn on another version, fail if missing |
| Orca ADE ≥ 1.4.195 (the version the feasibility probes ran against) | Everyone | `orca --version`, else `/Applications/Orca.app` `CFBundleShortVersionString` |
| At least one agent CLI, installed and authenticated | Everyone | `claude auth status` / `codex login status` / `agy models` — no model is ever called |
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
3. Open a pull request using the template. When its title type is `feat`, `fix`, `perf` or
   `revert`, its body carries either `Spec: <epic>/<story> @ <spec commit sha>` (one line per story;
   `/spec-cite` builds it), or `Spec-Exempt: <reason>` for a behavior change no story covers. CI
   refuses such a body with neither. `docs`, `ci`, `build`, `chore`, `test` and `refactor` PRs, and
   release PRs, need no line.
4. Every acceptance criterion of a cited story is covered, or listed in the pull request as not
   satisfied, with the reason.
5. All CI checks pass before merge.

The spec in `../yellowhammer-spec` is read-only from this repo: propose changes to its owners, never
edit or copy it here. Conventions for naming, modules, testing and the ubiquitous language are in
[AGENTS.md](AGENTS.md).

## Commits and releases

Commit messages and pull request titles follow
[Conventional Commits](https://www.conventionalcommits.org/): `type(scope): subject`, scope
optional. Allowed types: `feat`, `fix`, `perf`, `revert`, `docs`, `refactor`, `test`, `ci`,
`build`, `chore`. A breaking change is marked either with `!` after the type/scope
(`feat!: ...`) or a `BREAKING CHANGE:` footer. `.github/workflows/conventional-commits.yml`
checks both the pull request title and every non-merge commit in the pull request, so any merge
strategy (squash, rebase, or merge) is fine.

These messages drive the release version: [release-please](https://github.com/googleapis/release-please)
reads them off `main` to compute the next `X.Y.Z` and to write the changelog. Before 1.0.0 (this
repo's current state), a breaking change or a `feat` bumps the minor version and a `fix`/`perf`/
`revert` bumps the patch version; after 1.0.0, a breaking change bumps the major version instead.
`docs`, `refactor`, `test`, `ci`, `build` and `chore` commits do not appear in the changelog.

Release-please keeps one open pull request titled `chore(main): release X.Y.Z` with the computed
changelog. **Merging that pull request is the release** — it is the only way a `vX.Y.Z` tag and a
GitHub Release are created; never create or push a `v*` tag by hand. See
[doc/release-checklist.md](doc/release-checklist.md) for the full release procedure.

The `Spec:` trailer described above still goes in the pull request body/description, not the
title — release-please and the Conventional Commits check both work from commit messages and
titles, but `scripts/release/release-notes.sh` still reads `Spec:` lines from commit messages, so
keep citing them there too.
