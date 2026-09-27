# Yellowhammer

The Yellowhammer macOS app and its Engine, shipped as one Developer ID signed `.app`, distributed
directly. The app is a bounded local control surface; the Engine (`yh`) runs short-lived
`author | build | land` invocations, each scoped to exactly one Project. Apple Silicon only.

## Layout

- **`Yellowhammer/`** — the app target (SwiftUI, not sandboxed).
- **`Engine/`** — the `Engine` command-line target, product `yh`, embedded in the app at
  `Contents/MacOS/yh`.
- **`Packages/YellowhammerKit/`** — all logic, as a local Swift package tested with Swift Testing.
- **`Yellowhammer.xcodeproj`** — a thin project holding only the two targets above.
- **`scripts/ci/`** — the checks CI runs; each can be run locally.

## Build, test, lint

```bash
swift test --package-path Packages/YellowhammerKit
xcodebuild -project Yellowhammer.xcodeproj -scheme Yellowhammer build
swiftlint lint --strict
```

## Toolchain (pinned in CI)

| Tool | Version |
|------|---------|
| CI runner image | `macos-26` (arm64); lint runs on `ubuntu-latest` |
| Xcode | 26.6 (17F113) |
| Swift | 6.3.3 (bundled with Xcode 26.6) |
| SwiftLint | 0.65.0 |

`.github/workflows/ci.yml` is the source of truth (`XCODE_VERSION`, `SWIFTLINT_VERSION`). Change this
table in the same commit as the workflow.

## Relationship to the spec

The authoritative product spec lives in a separate repository, checked out next to this one as
`../yellowhammer-spec`. It is **read-only from here**:

- Read it at the time you need it (the `spec` MCP server, or the repo directly). Do not copy spec
  content into this repo.
- Never edit the spec from this repo. If it is wrong or incomplete, propose the change to its owners.
- A pull request titled `feat`, `fix`, `perf` or `revert` carries `Spec: <epic>/<story> @ <spec commit sha>`,
  or `Spec-Exempt: <reason>` when it implements no story. CI checks for one of them. Other title types
  and release PRs need neither.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
