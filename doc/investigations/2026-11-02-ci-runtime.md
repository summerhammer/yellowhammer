# CI Test and Build runtime investigation, 2026-11-02

The longest recent checks were caused by unavailable GitHub macOS arm64 runners.
Test execution and compilation have also become more expensive. Successful Build
execution has stayed approximately flat; its apparent regression is mostly queueing.

## Evidence

Sample: the latest 100 runs of `ci.yml`, created October 26–November 2, retrieved
through the Actions REST API. The table includes successful jobs only, both pushes
and pull requests, and measures job start to completion, excluding queue time.
Cancelled jobs and documentation-only skips are excluded.

| UTC dates | Test jobs | Median Test | Build jobs | Median Build |
| --- | ---: | ---: | ---: | ---: |
| Oct 26–27 | 14 | 6m 05s | 18 | 3m 11s |
| Oct 28–29 | 11 | 10m 03s | 11 | 3m 27s |
| Oct 30–31 | 29 | 10m 45s | 39 | 3m 18s |
| Nov 1–2 | 17 | 11m 13s | 20 | 3m 25s |

### Runner availability is a confirmed problem

[PR #747's Build job](https://github.com/summerhammer/yellowhammer/actions/runs/41501351319/job/125469486373)
spent 15m 02s without acquiring a runner (`runner_id: 0`, no steps). Its check
annotations explicitly say:

> The job was not acquired by Runner of type hosted even after multiple attempts

Another annotation identifies capacity constraints on macOS arm64 runners. The
[PR #745 Test job](https://github.com/summerhammer/yellowhammer/actions/runs/41492151128/job/125437824705)
similarly spent 25m 33s without a runner. These durations are not build or test
execution, even though the Jobs API supplies `started_at` and `completed_at`.
Workflow changes cannot eliminate GitHub's runner capacity shortages.

### Test time combines compilation, fixtures, and runner variability

The `Run tests` step previously included compilation, obscuring the distinction.
The logs provide the following breakdown:

| Run | Compile | Parallel test execution | Parallel tests | Serial execution |
| --- | ---: | ---: | ---: | ---: |
| [Oct 29, warm cache](https://github.com/summerhammer/yellowhammer/actions/runs/40930949922) | 7.83s | 112.51s | 4,629 | 96.39s |
| [Oct 30, release PR](https://github.com/summerhammer/yellowhammer/actions/runs/41106155268) | 418.81s | 185.04s | 4,831 | 99.99s |
| [Nov 2, PR #747](https://github.com/summerhammer/yellowhammer/actions/runs/41501351319) | 231.94s | 237.48s | 4,964 | 102.57s |
| [Nov 2, release PR](https://github.com/summerhammer/yellowhammer/actions/runs/41520817446) | 309.13s | 249.84s | 4,964 | 102.93s |

All four serial runs execute 136 tests. The two November 2 runs restore the same
cache and report the same 14 changed package files, yet compilation differs by
77 seconds. This demonstrates variability beyond the source diff.

Relevant code changes:

- October 28: `7b4d981b`, landing gates, changed 53 files. Successful Test jobs
  were already slower before the later OQ191 work.
- October 30: [#721](https://github.com/summerhammer/yellowhammer/pull/721)
  introduced the OQ191 test harness; [#722](https://github.com/summerhammer/yellowhammer/pull/722)
  implemented it across 117 files, including core modules and test fixtures.
  [#723](https://github.com/summerhammer/yellowhammer/pull/723) added merge observation.
- November 1: cancellation pinning expanded those real-git fixtures further.

`OQ191LandWorld.make` creates clone and bare repositories, commits, pushes and
Worktrees. These suites are serialized internally but still overlap other suites
in the parallel run. In the latest log, OQ191 publication retry is the last suite,
at 249.81 seconds. This identifies an execution hotspot; it does not establish a
runner-independent per-test regression or justify removing coverage.

Runner images also changed: the sampled October 29 warm run used
`20261013.0424.1`; later samples use `20261021.0445.8` or `20261026.0455.2`.
That correlation alone does not prove an image defect. Xcode remains pinned to 26.6.
No recent PR changed Test/Build workflow behavior: the October 26 workflow edit
only pinned Lint's Linux image.

## Implemented optimizations

- Compile tests separately with indexing disabled; both existing test groups use
  `--skip-build`. Compilation gets its own timeout and uploaded log.
- Save successful compilation before running tests, so a failing test no longer
  prevents the cache from advancing.
- Let subsequent revisions of a PR restore that PR's compiled cache, in addition
  to main's. Previously only successful pushes to main saved compiled output.
  GitHub isolates PR caches from main and other PRs.
- Key compiled caches by OS, architecture, Xcode pin, dependency lockfile and
  commit, with a compatible prefix fallback. Remove the broad SwiftPM fallback
  that could restore an incompatible toolchain cache.
- Cache Xcode DerivedData as well as dependency checkouts. Restore unchanged
  tracked source timestamps so the build can actually reuse compiled output.
  Disable indexing and print Xcode's build timing summary.
- Exclude Git symlinks and submodules from timestamp recording/restoration. The
  repository contains skill symlinks outside the checkout; the root-level Xcode
  timestamp manifest must never follow them.

The full test selection, serial process tests, app build and bundle checks remain.

## Follow-up: execution concurrency experiment

The pinned Swift 6.3.3 implementation defaults to unbounded concurrency:
[`defaultParallelizationWidth`](https://github.com/swiftlang/swift-testing/blob/swift-6.3.3-RELEASE/Sources/Testing/Support/Serializer.swift)
returns `Int.max` unless explicitly configured. Swift Testing and SwiftPM both
support `--experimental-maximum-parallelization-width` in that release.
`--num-workers` controls XCTest and does not set this Swift Testing limit.

Benchmarked the existing parallel selection, excluding exactly the same
`PROCESS_SUITES`, after one successful compilation:

| Concurrency | Total wall time | EngineCommandTests | RepositoriesTests | Result |
| --- | ---: | ---: | ---: | --- |
| Existing unbounded | 149.88s | 74.55s | 39.64s | 4,964 passed |
| Eight | 83.51s | 52.84s | 16.75s | 4,964 passed |
| Sixteen | 101.81s | 73.05s | 14.45s | 4,964 passed |
| Existing unbounded, warmed repeat | 79.02s | 53.66s | 12.74s | 4,964 passed |
| Eight, warmed repeat | 74.64s | 51.71s | 11.49s | 4,964 passed |

The first eight-wide run appears 44.3% faster than the first baseline, but the
warmed baseline is faster still. This invalidates interpreting that initial
difference as a concurrency improvement: cold filesystem state and other local
workload confound it. The warmed pair improves by only 5.54%, within plausible
noise from the shared machine. A provisional cap of eight was reverted; the
workflow retains its original execution parallelism. All five runs execute the
same selected tests and pass. The separate serial process-timing step is unchanged.

These timings use local Swift 6.4.2 on a 10-core Mac with 32 GB RAM. This toolchain
executes eleven separate test products, unlike CI's combined Swift 6.3.3 run.
Another project's test process was also active on the machine. The measurements
do not establish a hosted speedup. A controlled A/B comparison on CI's pinned,
smaller runner is needed before changing its execution concurrency. Further
fixture optimization should profile and reduce repeated real-git setup while
retaining independent test state and every existing assertion.

## Validation and limits

`actionlint`, the source-mtime regression tests and `git diff --check` pass.
An isolated Swift Testing package also verified `swift build --build-tests
--disable-index-store` followed by the two filtered `swift test --skip-build`
invocations under `script`: each selected exactly one intended test, generated its
Swift Testing XML report and performed no rebuild. That command check used the
local Swift 6.4.2 toolchain, not CI's pinned Xcode 26.6. The full app and package
suite were not run for the initial workflow changes. The follow-up compiled all
package test targets and ran the 4,964-test parallel selection five times; the
unchanged serial process-timing selection and the app build were not rerun locally.
Hosted performance after these changes has not yet been measured. The new cache
namespaces need a cold build initially. Subsequent warm runs should save compilation;
they still execute all fixtures and still depend on runner availability.

At investigation time the repository had 13 caches using approximately 10 GB,
mostly old main SwiftPM snapshots of about 800 MB each. Additional PR and Xcode
caches will increase eviction pressure. Track restore hits and transfer time when
assessing the improvement; per-commit caches are immutable and older entries are
evicted. No remote caches were deleted during this investigation.

Compare the next few hosted runs using Compile tests, Run tests, Run process-timing
tests, Build app, cache transfer timings and runner queue time separately. Evaluate
a bounded test width on the pinned hosted toolchain before adopting one.
