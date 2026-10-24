# Changelog

## [0.28.0](https://github.com/summerhammer/yellowhammer/compare/v0.27.0...v0.28.0) (2026-10-24)


### Features

* **engine:** hand usage-limited work and Rounds to the next Attempt ([6798127](https://github.com/summerhammer/yellowhammer/commit/679812748ae42cd446a243bf2f4191a0c4321713))
* **engine:** held same-repository Work Cards must not keep the land trigger unmet (OQ182 item 4) ([dc141d8](https://github.com/summerhammer/yellowhammer/commit/dc141d8cf5e741d80889dcf92f59de8955cb16bd)), closes [#680](https://github.com/summerhammer/yellowhammer/issues/680)
* **feature-authoring:** Refuse adopting a later sequence member whose earlier members are neither merged nor adopted ahead of it ([4138ae6](https://github.com/summerhammer/yellowhammer/commit/4138ae6736ec7e6c3469f662ef39f34c0ef8e16a))
* **landing:** Land a Repo Lane past its held Work Cards and name each in the Partial Landing ([9fd5d6d](https://github.com/summerhammer/yellowhammer/commit/9fd5d6d09f81340f224d891add94fd8fe97c9f98))
* **landing:** Name each held Work Card, with the Work Card it waits on, in the Feature closure comments ([10c0ff1](https://github.com/summerhammer/yellowhammer/commit/10c0ff1f5b48db13a342b6897b302da6bfedc418))
* **night-summary:** name Work Cards held by a usage limit (OQ180) ([65d3a6a](https://github.com/summerhammer/yellowhammer/commit/65d3a6ac93c821610b18fddd31280a79316aa1a7)), closes [#662](https://github.com/summerhammer/yellowhammer/issues/662)


### Bug Fixes

* **engine:** let a periodic author firing through while the in-flight Cycle has landed (OQ177) ([8532559](https://github.com/summerhammer/yellowhammer/commit/8532559aa4dfd812fd7e2d9cb4ccff4cb3044ca5)), closes [#681](https://github.com/summerhammer/yellowhammer/issues/681)
* **engine:** record stagger_minutes and regenerate stale LaunchAgents from each Act ([#682](https://github.com/summerhammer/yellowhammer/issues/682)) ([e58423e](https://github.com/summerhammer/yellowhammer/commit/e58423efb6c0d926522991f1488d299467afa6fe))
* **feature-authoring:** name repair and Todo gesture in Authoring Halt comments ([20ff649](https://github.com/summerhammer/yellowhammer/commit/20ff649edce3172a67e09a1421274771d0080e30)), closes [#677](https://github.com/summerhammer/yellowhammer/issues/677)
* **feature-authoring:** Re-run pinned selection on repairing repositories-undetermined halt ([60e7ed9](https://github.com/summerhammer/yellowhammer/commit/60e7ed916fbe95fd054538d6989ae700b6e20242))

## [0.27.0](https://github.com/summerhammer/yellowhammer/compare/v0.26.0...v0.27.0) (2026-10-23)


### Features

* **graph-execution:** Hold later same-repository Work Cards behind an unfinished earlier one ([#669](https://github.com/summerhammer/yellowhammer/issues/669)) ([2484087](https://github.com/summerhammer/yellowhammer/commit/2484087c3bc0702b57cfd7337a188fa83ae4d17c))


### Bug Fixes

* **cli-adapters:** State the never-search rule in every pass's boundary ([3b7485c](https://github.com/summerhammer/yellowhammer/commit/3b7485cde173506d48b34cdf862db26c20698a0d)), closes [#668](https://github.com/summerhammer/yellowhammer/issues/668)

## [0.26.0](https://github.com/summerhammer/yellowhammer/compare/v0.25.0...v0.26.0) (2026-10-22)


### Features

* **board-projection:** preserve and explain cancellation of unmerged Features ([#666](https://github.com/summerhammer/yellowhammer/issues/666)) ([ae87ada](https://github.com/summerhammer/yellowhammer/commit/ae87ada20e61b9e149c4d6c4e041d238a3e67104))
* **domain:** guide breakdown authoring for sequential same-repository Work Cards ([4928e04](https://github.com/summerhammer/yellowhammer/commit/4928e04a8a1fb5e9d5e39dc532cac4a4878d6365))
* **engine:** render Feature return clauses as labelled nested bullets ([68d10d0](https://github.com/summerhammer/yellowhammer/commit/68d10d0712871f0755afea130fdf1bd9588b7580)), closes [#647](https://github.com/summerhammer/yellowhammer/issues/647)
* **engine:** thread in-lane base commit and completed-card stack context into CardRun ([ed7a26e](https://github.com/summerhammer/yellowhammer/commit/ed7a26eea2abfd9baf465f4d33febebf489ad889))


### Bug Fixes

* **cli-adapters:** read every claude result turn and never a previous Round's stdout ([ccf62e3](https://github.com/summerhammer/yellowhammer/commit/ccf62e357af6d95acc1c23ab7b023bffcab92d72)), closes [#643](https://github.com/summerhammer/yellowhammer/issues/643)
* **cli-adapters:** refuse an agy model whose effort suffix conflicts with the Route's effort ([018af95](https://github.com/summerhammer/yellowhammer/commit/018af9563a1e8345968e9c30e0aa6dea2e95b2f5)), closes [#649](https://github.com/summerhammer/yellowhammer/issues/649)
* **cli-adapters:** run Codex workers without a sandbox ([ddfcc5b](https://github.com/summerhammer/yellowhammer/commit/ddfcc5b8bdbb1485ad6a6e019a983efe39a6affc))
* **engine:** decode authoring_invariant_violation from architect and worker result files ([4d5f046](https://github.com/summerhammer/yellowhammer/commit/4d5f04601ee8bddbbee4c2c0de360d7f82434cd4)), closes [#644](https://github.com/summerhammer/yellowhammer/issues/644)
* **engine:** honour the zoned usage-limit reset hint and add a cadence grace ([0502d76](https://github.com/summerhammer/yellowhammer/commit/0502d76bf00570d3c818b54c8105a9d6153493f7)), closes [#645](https://github.com/summerhammer/yellowhammer/issues/645)
* **engine:** scope ContractOverlapCheck to cross-repository contracts ([b3bc479](https://github.com/summerhammer/yellowhammer/commit/b3bc479fc28ab661350e446dc7c5b8ef0a7fa757)), closes [#611](https://github.com/summerhammer/yellowhammer/issues/611)

## [0.25.0](https://github.com/summerhammer/yellowhammer/compare/v0.24.0...v0.25.0) (2026-10-21)


### Features

* **app:** Pulse lists the Features awaiting merge and a skip on a full stack ([2d56947](https://github.com/summerhammer/yellowhammer/commit/2d56947806e6442693ef920fa3e59fcc1e090fd3))
* **prototypes:** Pulse scenarios and a Stack Ladder variant for the Unmerged Feature Stack ([170c0a5](https://github.com/summerhammer/yellowhammer/commit/170c0a5a812793817a887c491fedda402f218b2a))
* **pulse:** read the Unmerged Feature Stack beside the in-flight Feature ([72b0a7d](https://github.com/summerhammer/yellowhammer/commit/72b0a7d65d77785df37314cbeb8abe91c31b52fb))


### Bug Fixes

* **app:** put the awaiting-merge detail's repo identifier on its row ([fa07fe8](https://github.com/summerhammer/yellowhammer/commit/fa07fe81ff62306d8a9b60bf6fcf16ec8b46bd67))
* **landing:** open a complete landing's pull request body with the Roll-up sentence ([48692dd](https://github.com/summerhammer/yellowhammer/commit/48692dd6a90273d49d9de8198af6fb44f1593a97)), closes [#628](https://github.com/summerhammer/yellowhammer/issues/628)
* **morning-report:** standing line names the Unmerged Feature Stack and shows identifiers ([c394c66](https://github.com/summerhammer/yellowhammer/commit/c394c66ff0c373199723ea68383c522cdcc01e56))

## [0.24.0](https://github.com/summerhammer/yellowhammer/compare/v0.23.0...v0.24.0) (2026-10-21)


### Features

* **config:** add the unmerged_features_max Bound ([b4d05e0](https://github.com/summerhammer/yellowhammer/commit/b4d05e077f7c6cd13071d09502d731df69f5804e))
* **config:** fire the author job after every periodic land tick ([52a3de7](https://github.com/summerhammer/yellowhammer/commit/52a3de710dcd1dd1d7c280178c0bbe5e57ee3ccc))
* **engine:** author the next Feature against effective_base(R) ([500b0b7](https://github.com/summerhammer/yellowhammer/commit/500b0b7f4d9798f2ffc13e52d17c3524a44f2d29))
* **engine:** count every Feature a Night landed and list the Unmerged Feature Stack ([a25a83d](https://github.com/summerhammer/yellowhammer/commit/a25a83d014a49cbabc91f6c61d3fab254fb1c3ae))
* **engine:** cut a stacked Feature's Worktree from its recorded base ([31e705d](https://github.com/summerhammer/yellowhammer/commit/31e705de5c7ee374923c3beb9d61462413d9d94a))
* **engine:** fire the author Act only with no Cycle in flight, or first in the Night ([903c9b5](https://github.com/summerhammer/yellowhammer/commit/903c9b5ebf2f465c5ee4a1424e8570fe247d97a9))
* **engine:** gate authoring on the Unmerged Feature Stack ([b6054e6](https://github.com/summerhammer/yellowhammer/commit/b6054e6085552aa267b942f22489e4e5ef92cf43))
* **engine:** keep a landed pin while an open Cycle's base names it ([25dcd73](https://github.com/summerhammer/yellowhammer/commit/25dcd73c1a9e87835d9e22cd08ee4eada0f226bf))
* **engine:** open stacked pull requests against the predecessor's Feature Branch ([2ec39cc](https://github.com/summerhammer/yellowhammer/commit/2ec39cceefce5fb7af8437a809a040ac0a1a4871))
* **journal:** read the Unmerged Feature Stack and record effective bases ([40097ca](https://github.com/summerhammer/yellowhammer/commit/40097ca648fa290a5dd4162d317aae2c1fae9744))
* **pulse:** count every Feature verified tonight ([41f92ac](https://github.com/summerhammer/yellowhammer/commit/41f92ace16e9ccfbff79077874f3886e3ca59371))

## [0.23.0](https://github.com/summerhammer/yellowhammer/compare/v0.22.0...v0.23.0) (2026-10-21)


### Features

* **authoring:** repair a halted Feature's draft Work Cards on the Board ([1b507ac](https://github.com/summerhammer/yellowhammer/commit/1b507ace2f6e1bfae3f6bb0f538262aa3a88ecec))
* **board:** migrate tracked legacy Board taxonomy and retire the settle-state bridge ([29642f8](https://github.com/summerhammer/yellowhammer/commit/29642f82068219cb3627d5f7f761e0c3291590c0))
* **board:** provision two custom states and select native states by category ([7f44d76](https://github.com/summerhammer/yellowhammer/commit/7f44d76fff7c21453ee0655f4f62e13eb171d62a))
* **board:** render Block Reason as card content, not a label ([ffc8639](https://github.com/summerhammer/yellowhammer/commit/ffc86392ec9595f380d724e23ac31c3542343b38))
* **doctor:** write the Board Mapping for already-provisioned states on --fix ([b52f14e](https://github.com/summerhammer/yellowhammer/commit/b52f14eb61e96e0ef316fff6fb20cdc13eab7c99))
* **routing:** read the Card override from a description field, not a label ([51de46b](https://github.com/summerhammer/yellowhammer/commit/51de46bd59345229a2342f82e64d669e667dcceb))


### Bug Fixes

* **authoring:** resume a repaired halted Feature instead of authoring a duplicate ([b2dd519](https://github.com/summerhammer/yellowhammer/commit/b2dd5195fb0b433bed9299d6602ec05eb2595c04))
* **board:** hold the legacy migration open on multiple open Cycles and cover conditioned writes ([5d002de](https://github.com/summerhammer/yellowhammer/commit/5d002deffd06e1308c0cfbc82f3ef03460e07711))
* **board:** read every Delta Read page once and reconcile in every Act ([2bde853](https://github.com/summerhammer/yellowhammer/commit/2bde8538b600a7980dc6f791ab1fbf44c2f8df01))
* **board:** resume an over-cap Delta Read across Acts ([042a986](https://github.com/summerhammer/yellowhammer/commit/042a986335c420c58995467478df373fb112cb63))
* **board:** revalidate queued Board writes and keep Operator edits in the Managed Block ([5ef1b37](https://github.com/summerhammer/yellowhammer/commit/5ef1b37993147c9b7edb3c81be2ca14ff98d9478))
* **routing:** read a Card override through Linear's Markdown escapes ([52129b9](https://github.com/summerhammer/yellowhammer/commit/52129b9bf4eb139c3cafeed613ce9a711087ce66))
* **settle:** settle Features by native Done and Cancelled, drop the daily reset ([bbab0c1](https://github.com/summerhammer/yellowhammer/commit/bbab0c1fe54d2138e0b4c9cf02001a40026c8841))

## [0.22.0](https://github.com/summerhammer/yellowhammer/compare/v0.21.0...v0.22.0) (2026-10-19)


### Features

* **agents:** add investigate-night-outcome skill ([044b9b2](https://github.com/summerhammer/yellowhammer/commit/044b9b2fe3b0c3be9f4ee7e94b733f7757eec749))
* **agents:** add investigate-night-readiness skill and Night Readiness Auditor agent ([37e43a5](https://github.com/summerhammer/yellowhammer/commit/37e43a5b95d415d16fe7d5f01fc86b27069ddb84)), closes [#587](https://github.com/summerhammer/yellowhammer/issues/587)
* **agents:** tighten investigate-night-readiness against a live run ([22d8033](https://github.com/summerhammer/yellowhammer/commit/22d8033c38e170f257d59628e3adc376dcfef627))
* **app:** Pulse shows the next scheduled Act and when the upcoming Night starts ([4df0be6](https://github.com/summerhammer/yellowhammer/commit/4df0be6985cac5cdfba89fa0081182c98c9e0c76)), closes [#588](https://github.com/summerhammer/yellowhammer/issues/588)
* **app:** Setup wizard footer tells the Operator to answer Deny to an agent pass's Keychain dialog ([dcbfbed](https://github.com/summerhammer/yellowhammer/commit/dcbfbed3af10ca79d13b0544d72e3592d11ef0ac))
* **verification:** attribute 'not checked' clauses to a Repo's declared check = none ([a687642](https://github.com/summerhammer/yellowhammer/commit/a6876424bf7e5751ab614e565df511b0c78c7c53))


### Bug Fixes

* **ci:** prevent spec checker from hanging on usage ([a104e21](https://github.com/summerhammer/yellowhammer/commit/a104e21e6ceedac282ad2282cf5e1a3914150b5a)), closes [#589](https://github.com/summerhammer/yellowhammer/issues/589)

## [0.21.0](https://github.com/summerhammer/yellowhammer/compare/v0.20.0...v0.21.0) (2026-10-18)


### Features

* **engine:** give the selection pass the Project's board state from the Journal ([02c9883](https://github.com/summerhammer/yellowhammer/commit/02c98831399e7897ec8cda25ecf8e766d8d1aca8)), closes [#556](https://github.com/summerhammer/yellowhammer/issues/556)
* **probe:** measure whether read-only passes can reach the Keychain, Yellowhammer's state or Linear ([46bc8ab](https://github.com/summerhammer/yellowhammer/commit/46bc8ab2c70713b6dfad6f9b47cfdb85cfe1e49f)), closes [#557](https://github.com/summerhammer/yellowhammer/issues/557)
* **verification:** report clauses that could not be checked ([#586](https://github.com/summerhammer/yellowhammer/issues/586)) ([3f8f195](https://github.com/summerhammer/yellowhammer/commit/3f8f195d1058671c69027de30b1b5d92f7a4c6fa))


### Bug Fixes

* **app:** surface open authoring halts and refusals in Pulse ([b947ec0](https://github.com/summerhammer/yellowhammer/commit/b947ec0cb3716fe3874ce273dd9dc312080d3c2f)), closes [#572](https://github.com/summerhammer/yellowhammer/issues/572)
* **dispatch:** deny codex read-only passes the configuration directory ([ee97472](https://github.com/summerhammer/yellowhammer/commit/ee97472b94a1336d734474d7fe365dcb44358797)), closes [#557](https://github.com/summerhammer/yellowhammer/issues/557)
* **dispatch:** end a pass at once when a macOS Keychain prompt is attributed to it ([603462f](https://github.com/summerhammer/yellowhammer/commit/603462f4006eda1250de1f71b043db0f2f876e5d)), closes [#555](https://github.com/summerhammer/yellowhammer/issues/555)
* **dispatch:** end a pass's log stream when yh dies without cleanup ([c5f4fce](https://github.com/summerhammer/yellowhammer/commit/c5f4fce3241164fd7bbcd40cacc8dc87ec078659)), closes [#579](https://github.com/summerhammer/yellowhammer/issues/579)
* **doctor:** report a dev.yellowhammer Keychain item whose access or partition list was widened ([2b3225f](https://github.com/summerhammer/yellowhammer/commit/2b3225fee8d2aa609362dbf3a58d5474a46e8889)), closes [#573](https://github.com/summerhammer/yellowhammer/issues/573)
* **probe:** default the probe Route to one the Routing Table names ([bfa30ed](https://github.com/summerhammer/yellowhammer/commit/bfa30ed36562bf71e3360c30bf18566ab9f45072))

## [0.20.0](https://github.com/summerhammer/yellowhammer/compare/v0.19.0...v0.20.0) (2026-10-17)


### Features

* **app:** list Tonight's unrecovered Failure Notices, each opening the Night's account at its failure ([c73cffe](https://github.com/summerhammer/yellowhammer/commit/c73cffedbadccc2f3a41fd68574f79f0d2dccbf9)), closes [#533](https://github.com/summerhammer/yellowhammer/issues/533)
* **app:** offer a failed item's Act log with Reveal in Finder ([83a2e99](https://github.com/summerhammer/yellowhammer/commit/83a2e993685647167eb577f78f914128657480e2)), closes [#549](https://github.com/summerhammer/yellowhammer/issues/549)
* **engine:** carry the Night's failure line on the closed notification ([7f22230](https://github.com/summerhammer/yellowhammer/commit/7f2223051947caa90d9a01f71522f1d0244f8967)), closes [#549](https://github.com/summerhammer/yellowhammer/issues/549)
* **engine:** state the Night's failures on the Night Card, under verdict_line ([92973ef](https://github.com/summerhammer/yellowhammer/commit/92973ef0f2d6048715fa01b2022b8779e3de02fe)), closes [#549](https://github.com/summerhammer/yellowhammer/issues/549)
* **pulse:** word every failure event in the Night's account ([bc87a30](https://github.com/summerhammer/yellowhammer/commit/bc87a307293eb4885af13fb3b10b6955e7d26762)), closes [#549](https://github.com/summerhammer/yellowhammer/issues/549)
* **settings:** show and edit a Board Connection's description budget ([0345077](https://github.com/summerhammer/yellowhammer/commit/03450774fd278828c6051e4ea7c80284a142d03b)), closes [#549](https://github.com/summerhammer/yellowhammer/issues/549)
* **status:** read a failed last run as `failed: <headline>`, never `ended` ([b009d93](https://github.com/summerhammer/yellowhammer/commit/b009d939e8345d7e19c91905117bf8fa05a71112)), closes [#549](https://github.com/summerhammer/yellowhammer/issues/549)


### Bug Fixes

* **app:** show an authoring fault as a failure in Health, Tonight and the Sidebar ([#548](https://github.com/summerhammer/yellowhammer/issues/548)) ([a77f2cd](https://github.com/summerhammer/yellowhammer/commit/a77f2cddec0e0d24288a4eb691106ed5a1a64ee5)), closes [#533](https://github.com/summerhammer/yellowhammer/issues/533)
* **dispatch:** keep agent passes out of the Keychain and Yellowhammer's state ([4b5a90f](https://github.com/summerhammer/yellowhammer/commit/4b5a90f23c1d1c825c6add56ca5a8b0823a265be)), closes [#546](https://github.com/summerhammer/yellowhammer/issues/546)
* **engine:** defer agent CLI usage-limit refusals ([38bd05e](https://github.com/summerhammer/yellowhammer/commit/38bd05ece5c593642acb611aa66a9a876c86ecbf)), closes [#547](https://github.com/summerhammer/yellowhammer/issues/547)
* **engine:** open a re-selected Feature's stop on its own Feature Issue ([bc8d7a7](https://github.com/summerhammer/yellowhammer/commit/bc8d7a74ede56d0eeddcbf79943b9e24d9e1ce4a))
* **engine:** read a landed Cycle's board before the author Act settles or selects ([cfe0bd2](https://github.com/summerhammer/yellowhammer/commit/cfe0bd21aa3cefbdbe83b26694bfcd90c270d8d2)), closes [#559](https://github.com/summerhammer/yellowhammer/issues/559)
* **engine:** record each Route the verifier's walk excludes ([3f46ed3](https://github.com/summerhammer/yellowhammer/commit/3f46ed3ed8f4628af55a4d3d714ede9602c7964e)), closes [#549](https://github.com/summerhammer/yellowhammer/issues/549)
* **engine:** recover the Night Summary's failed Acts by cause ([07e9c77](https://github.com/summerhammer/yellowhammer/commit/07e9c774b7677255f530abfe5c0e80f5bff964c7)), closes [#549](https://github.com/summerhammer/yellowhammer/issues/549)

## [0.19.0](https://github.com/summerhammer/yellowhammer/compare/v0.18.2...v0.19.0) (2026-10-17)


### Features

* **app:** draw the Night's timeline as tracks and make its log navigable ([11a527b](https://github.com/summerhammer/yellowhammer/commit/11a527b4b9fe2ed1597b5a65ea324897de6ff36d))


### Bug Fixes

* **app:** flag a rejected Feature breakdown as a problem in the Night's account ([65615c3](https://github.com/summerhammer/yellowhammer/commit/65615c32fd5921ffc71ba0cb60fb9e3308978074)), closes [#533](https://github.com/summerhammer/yellowhammer/issues/533)
* **engine:** give every authoring transaction its own Outbox keys ([#541](https://github.com/summerhammer/yellowhammer/issues/541)) ([c67574a](https://github.com/summerhammer/yellowhammer/commit/c67574a1e348fcbc70965ec8afe27c96afb2b5be))
* **linear:** repair board provisioning from doctor and Health ([5452a5b](https://github.com/summerhammer/yellowhammer/commit/5452a5b98354fa679f8dfe72b8351a2a21c491c5))

## [0.18.2](https://github.com/summerhammer/yellowhammer/compare/v0.18.1...v0.18.2) (2026-10-16)


### Bug Fixes

* **engine:** grant workers writable Git metadata directories ([1770ae3](https://github.com/summerhammer/yellowhammer/commit/1770ae37b1c22d8c779e836b931caef73c4567aa)), closes [#534](https://github.com/summerhammer/yellowhammer/issues/534)
* **engine:** tell the breakdown what a Work Card's description is measured in ([566968e](https://github.com/summerhammer/yellowhammer/commit/566968e8fb147e85d8293ce426e6edae3538b372)), closes [#532](https://github.com/summerhammer/yellowhammer/issues/532)

## [0.18.1](https://github.com/summerhammer/yellowhammer/compare/v0.18.0...v0.18.1) (2026-10-16)


### Bug Fixes

* **app:** run every yh the app spawns with the app's environment, not an empty one ([28c499d](https://github.com/summerhammer/yellowhammer/commit/28c499db80dcca19ab893d5d2553705f66c4027f))

## [0.18.0](https://github.com/summerhammer/yellowhammer/compare/v0.17.0...v0.18.0) (2026-10-16)


### Features

* **graph-execution:** Block missing-upstream Work Cards as authoring defects ([#525](https://github.com/summerhammer/yellowhammer/issues/525)) ([75b0867](https://github.com/summerhammer/yellowhammer/commit/75b08675418f5528d5a7320a246e813c04dc469d))


### Bug Fixes

* **app:** show Act runs that stood down during a Night in its account ([c437589](https://github.com/summerhammer/yellowhammer/commit/c437589a1c30c21e77b472bf0d9a505fd2871223)), closes [#522](https://github.com/summerhammer/yellowhammer/issues/522)
* **app:** show the Night's stored times in Settings, not shifted by the Mac's zone ([f2287fd](https://github.com/summerhammer/yellowhammer/commit/f2287fd214eeb67b298f3c641498425cb57825ab))
* **engine:** tell the breakdown a contract path must be tracked at mainline ([9a82ba8](https://github.com/summerhammer/yellowhammer/commit/9a82ba87f8f4392df1106c10bced0457b6f4a514)), closes [#523](https://github.com/summerhammer/yellowhammer/issues/523)
* **health:** distinguish gh authentication failures ([772dbab](https://github.com/summerhammer/yellowhammer/commit/772dbabad54a2b4948950987150f0085693a2b2c)), closes [#520](https://github.com/summerhammer/yellowhammer/issues/520)

## [0.17.0](https://github.com/summerhammer/yellowhammer/compare/v0.16.0...v0.17.0) (2026-10-15)


### Features

* **engine:** declare Repo Dependencies and halt a Feature that spans one ([#513](https://github.com/summerhammer/yellowhammer/issues/513)) ([0141d8e](https://github.com/summerhammer/yellowhammer/commit/0141d8e1ae4083eb4c7e67504804e4b7b6653c9b))
* **engine:** halt a breakdown that consumes its own Feature's work ([#515](https://github.com/summerhammer/yellowhammer/issues/515)) ([e12b0ce](https://github.com/summerhammer/yellowhammer/commit/e12b0ce5e337cc376963099ecc53e41ec3d33a63))
* **engine:** hold a `tag` consumer until the producer has an Observed Release ([#514](https://github.com/summerhammer/yellowhammer/issues/514)) ([e4c285c](https://github.com/summerhammer/yellowhammer/commit/e4c285c510a7737acbe73213cf524baf743f656f))
* **engine:** make the pass timeout configurable, record a timeout as a hard failure, and tell the worker the limit ([#519](https://github.com/summerhammer/yellowhammer/issues/519)) ([e788890](https://github.com/summerhammer/yellowhammer/commit/e78889028e761b2a92dcb5db12979d3f7a174994))
* **engine:** name the spec commit and forbid searching outside the Worktree in the worker instruction ([#510](https://github.com/summerhammer/yellowhammer/issues/510)) ([019ebae](https://github.com/summerhammer/yellowhammer/commit/019ebaeee8c71e422e51999a14f41ce719daa121))
* **setup:** propose Repo Dependencies at setup for the Operator to confirm ([#516](https://github.com/summerhammer/yellowhammer/issues/516)) ([8f77a06](https://github.com/summerhammer/yellowhammer/commit/8f77a067ebd1be951b79b3e9fe0aa0d476318728))


### Bug Fixes

* **app:** run job-writing yh setup with the login shell's PATH ([#509](https://github.com/summerhammer/yellowhammer/issues/509)) ([dcf55cf](https://github.com/summerhammer/yellowhammer/commit/dcf55cf0da687cdb69ced5dbb04399ffda95d101))
* **pulse:** explain when returned Feature choices are recorded ([936d971](https://github.com/summerhammer/yellowhammer/commit/936d97126aa776a52eb3b888c0f0f22f230a7064)), closes [#508](https://github.com/summerhammer/yellowhammer/issues/508)

## [0.16.0](https://github.com/summerhammer/yellowhammer/compare/v0.15.1...v0.16.0) (2026-10-14)


### Features

* **authoring:** transcribe only a contract path's named line ranges, and keep lines off the card ([#497](https://github.com/summerhammer/yellowhammer/issues/497)) ([1d50612](https://github.com/summerhammer/yellowhammer/commit/1d50612f27abee88d891c237be0f8613d73df120))
* **bounds:** halt Features after repeated authoring faults ([58ee6dd](https://github.com/summerhammer/yellowhammer/commit/58ee6ddf59316f6a86d31e1eecb0c8e00cc24b1c))
* **engine:** honour an Operator's edit to a Transcription Block reference as a new reference ([3d2b514](https://github.com/summerhammer/yellowhammer/commit/3d2b5140d95db630540c524556c289b08b036320)), closes [#491](https://github.com/summerhammer/yellowhammer/issues/491)


### Bug Fixes

* **authoring:** tell the breakdown the description budget, apart from how a contract path is read ([c061525](https://github.com/summerhammer/yellowhammer/commit/c061525e310a42912773eb65823675abf63524cb)), closes [#486](https://github.com/summerhammer/yellowhammer/issues/486)
* **author:** refuse directory and non-regular contract paths ([#495](https://github.com/summerhammer/yellowhammer/issues/495)) ([5470473](https://github.com/summerhammer/yellowhammer/commit/547047329b1dbb64ba27be463bf0132e885264f1))
* **cli-adapters:** preserve agy output after recovered API errors ([89e6088](https://github.com/summerhammer/yellowhammer/commit/89e608887e6083534cff8f1d99d19b82395eae14)), closes [#484](https://github.com/summerhammer/yellowhammer/issues/484)
* **engine:** correct authoring fault wording and trim trailing period ([#494](https://github.com/summerhammer/yellowhammer/issues/494)) ([6e2aac4](https://github.com/summerhammer/yellowhammer/commit/6e2aac4c01d8b22d93b98e344b326f8311faadf5)), closes [#489](https://github.com/summerhammer/yellowhammer/issues/489)
* **engine:** keep every board description within the Board Connection's description budget ([7fbdbaf](https://github.com/summerhammer/yellowhammer/commit/7fbdbaf742cf79f38a3e171572ad8aee109bcbb2)), closes [#485](https://github.com/summerhammer/yellowhammer/issues/485)
* **engine:** preserve the full Operator Architectural Brief ([#500](https://github.com/summerhammer/yellowhammer/issues/500)) ([a3e4e4c](https://github.com/summerhammer/yellowhammer/commit/a3e4e4c126a1e6ca12bbc067df384dec2a1a1bf2))

## [0.15.1](https://github.com/summerhammer/yellowhammer/compare/v0.15.0...v0.15.1) (2026-10-13)


### Bug Fixes

* **dispatch:** drop the missing-result-file crash wording from every pass ([5771a96](https://github.com/summerhammer/yellowhammer/commit/5771a96abe63bb7ac2ae7f61019a53fc2c9531b6))
* **dispatch:** name the CLI Adapter by its glossary term in every pass prompt ([f209051](https://github.com/summerhammer/yellowhammer/commit/f209051e01fa84f1e55bc8a3dbcf25cfd1fb556c))
* **dispatch:** return structured results without tool writes ([fd8d5f2](https://github.com/summerhammer/yellowhammer/commit/fd8d5f296e2055fbb7aaf17321178bbad1b46e6f))

## [0.15.0](https://github.com/summerhammer/yellowhammer/compare/v0.14.0...v0.15.0) (2026-10-13)


### Features

* **app:** add the Yellowhammer app icon as an Icon Composer bundle ([38c41da](https://github.com/summerhammer/yellowhammer/commit/38c41da61959d2b1a34491cc5f206894c87ca1e6))
* **app:** read a Night's account along a playhead in place of the Pulse ([#475](https://github.com/summerhammer/yellowhammer/issues/475)) ([d2fec1f](https://github.com/summerhammer/yellowhammer/commit/d2fec1f834a3a052cbf32e9d17daa92a5ee29d74))
* **config:** declare Repo Roles in the machine file and offer them in every picker ([fe7c38c](https://github.com/summerhammer/yellowhammer/commit/fe7c38c4aaa4317e2a8eab1374f5855c2c4c2e26))
* **feature-authoring:** Squash and rebase merges open the predecessor gate: content merge test, Observed Merge record, landed-tip pin ([aaa2f20](https://github.com/summerhammer/yellowhammer/commit/aaa2f203c795862d8cc4519737248af5c43c0de4))
* **gate:** open the predecessor gate on squash and rebase merges, record Observed Merge evidence ([509f2e2](https://github.com/summerhammer/yellowhammer/commit/509f2e215e2aa11a5dfb8b77c5b489ce5b896a3d))
* **land:** recommend a merge commit and say why, on the pull request body and the Night Card ([0751918](https://github.com/summerhammer/yellowhammer/commit/0751918bbfd5c2ad046c850ae03c435094de6ef4))
* **land:** record the pushed tip and pin it at refs/yellowhammer/landed/&lt;branch&gt; ([bb8e8b7](https://github.com/summerhammer/yellowhammer/commit/bb8e8b7b070191e6cfa21e54131a1c51bb42afe1))


### Bug Fixes

* **app:** head the Night's account with the Project's name ([ba9efea](https://github.com/summerhammer/yellowhammer/commit/ba9efea15cee2dfa6a9fabf6ee9ae7a8c054c26e)), closes [#476](https://github.com/summerhammer/yellowhammer/issues/476)
* **dispatch:** keep the commit-message request when the result file path is stamped ([4183c48](https://github.com/summerhammer/yellowhammer/commit/4183c48d4dc2b6a06e0a3dbb389e8c1efb08c2a7))
* **gate:** test the recorded commit alone, and fault a repository with no recorded Feature Branch ([6e548b1](https://github.com/summerhammer/yellowhammer/commit/6e548b1f882ec7e42a0672da0e2f4f395db9d170))
* **pulse:** show a returned Feature in Needs you, the Feature group and the Night line ([65e93b1](https://github.com/summerhammer/yellowhammer/commit/65e93b15c47397bd283c525635d0b90981a86f47))

## [0.14.0](https://github.com/summerhammer/yellowhammer/compare/v0.13.0...v0.14.0) (2026-10-12)


### Features

* **app:** edit a Project's Night window and build interval in Settings ([4cd847f](https://github.com/summerhammer/yellowhammer/commit/4cd847fc58ca0ee89709df304668bf51e758f1a2))
* **app:** read a Night's account from the Journal in the Inspector ([#470](https://github.com/summerhammer/yellowhammer/issues/470)) ([c3c9a9a](https://github.com/summerhammer/yellowhammer/commit/c3c9a9a8555f233ea4494b01eb2880b78a095923))


### Bug Fixes

* **engine:** record a verified Feature's merge as its landing Night's triage ([6818f52](https://github.com/summerhammer/yellowhammer/commit/6818f52fd674826b585f9882a06d4776b0008847)), closes [#447](https://github.com/summerhammer/yellowhammer/issues/447)
* **settings:** show readable Linear workspace and identity names ([f683f39](https://github.com/summerhammer/yellowhammer/commit/f683f39989a96090f748fadeae89453003d6c556))

## [0.13.0](https://github.com/summerhammer/yellowhammer/compare/v0.12.0...v0.13.0) (2026-10-11)


### Features

* **morning-report:** lead the Night verdict with halted or crashed only for an abnormal ending ([f889ebd](https://github.com/summerhammer/yellowhammer/commit/f889ebdf15f3325a1df0e6f6ab58bd065ec2e69b))
* **morning-report:** page a board-unreachable halt at the 2nd consecutive one, and always on the closing Act ([295518c](https://github.com/summerhammer/yellowhammer/commit/295518c49781d6ca5463de9683d3773b987ac21c))


### Bug Fixes

* **authoring:** explain a squash-merged predecessor on the Night Card and pull request ([4947b6e](https://github.com/summerhammer/yellowhammer/commit/4947b6ec12e8f4d4c4071e56bc780ffbaa5ab3be)), closes [#448](https://github.com/summerhammer/yellowhammer/issues/448)
* **authoring:** keep a Card's brief from contradicting the worker contract ([#459](https://github.com/summerhammer/yellowhammer/issues/459)) ([0ee78ee](https://github.com/summerhammer/yellowhammer/commit/0ee78ee0b840b4783473b03697daf861004de706))
* **delta-read:** ignore transcription and code blocks when reading repository line ([#461](https://github.com/summerhammer/yellowhammer/issues/461)) ([b23fd0d](https://github.com/summerhammer/yellowhammer/commit/b23fd0dd8c91ab46494c63cf88598642cec9daa3))
* **doctor:** verify LaunchAgent executables and gate repointing ([#453](https://github.com/summerhammer/yellowhammer/issues/453)) ([67ee1e2](https://github.com/summerhammer/yellowhammer/commit/67ee1e242b5dfc145496ed02ba7c2913db979579))
* **engine:** classify a result file that breaks its contract as a hard failure, not Crashed-Unknown ([#465](https://github.com/summerhammer/yellowhammer/issues/465)) ([7d524e9](https://github.com/summerhammer/yellowhammer/commit/7d524e95ff0384877451e993b4c8040b01db9380))
* **engine:** exit 0 when an Act stands down on the Project Lease ([#454](https://github.com/summerhammer/yellowhammer/issues/454)) ([96ce77d](https://github.com/summerhammer/yellowhammer/commit/96ce77d134c15d7e30b6baa72f16774f19022011)), closes [#435](https://github.com/summerhammer/yellowhammer/issues/435)
* **engine:** stop reporting a Worktree holder that predates the run as a leftover ([e9b8d13](https://github.com/summerhammer/yellowhammer/commit/e9b8d1322b12cdaaa5202e9655506956ac3a7b84)), closes [#438](https://github.com/summerhammer/yellowhammer/issues/438)
* **instruction:** put the Work Card trailer in the worker's commit-message format ([d7dd689](https://github.com/summerhammer/yellowhammer/commit/d7dd689d9fda6428161e80bada9cfc1d7e832bf7))
* **readiness:** treat Linear's Markdown rewrite of a Card description as unchanged ([47346d8](https://github.com/summerhammer/yellowhammer/commit/47346d88faa3a13c4b267414db2b7c68b58cc20c)), closes [#433](https://github.com/summerhammer/yellowhammer/issues/433)
* **rehearsal:** answer authoring fixtures with the Project's own repos and stories ([#464](https://github.com/summerhammer/yellowhammer/issues/464)) ([b8fc8e4](https://github.com/summerhammer/yellowhammer/commit/b8fc8e45119e19f2a74c56a58274a46b13c10ab6))
* **routing:** warn when a route lists itself among its fallbacks ([#460](https://github.com/summerhammer/yellowhammer/issues/460)) ([a06cb75](https://github.com/summerhammer/yellowhammer/commit/a06cb75fa2ec8e3375a4257fa6e8eb3468ef69a9))
* **setup:** reuse saved configuration when installing jobs ([7b855e2](https://github.com/summerhammer/yellowhammer/commit/7b855e29db8a08fd11a2b5550f99f43275a8d1bb))
* **setup:** use in-memory credential stores in tests to prevent Keychain leaks ([#455](https://github.com/summerhammer/yellowhammer/issues/455)) ([0531ca0](https://github.com/summerhammer/yellowhammer/commit/0531ca053338791dca7fd69406709d894c73ae7a))
* **summary:** count Authoring Halt Cards as waiting decisions ([#457](https://github.com/summerhammer/yellowhammer/issues/457)) ([2fd636c](https://github.com/summerhammer/yellowhammer/commit/2fd636c2f3800f9bb6e1dcf0a268f7ad9bdcc409))

## [0.12.0](https://github.com/summerhammer/yellowhammer/compare/v0.11.0...v0.12.0) (2026-10-11)


### Features

* **doctor:** report installed job firings that differ from the schedule and regenerate them with --fix ([5c33da9](https://github.com/summerhammer/yellowhammer/commit/5c33da9fab6306d1a5d3ed352b64f87d54c7ab5f))
* **engine:** closed notification says the Night Card is not updated yet while its completion is pending ([0d03348](https://github.com/summerhammer/yellowhammer/commit/0d033482b58ee91db141f1c7385f2d4d08cc8f2e))
* **engine:** flush firings after night_end deliver pending writes and close an open Night ([b018a4d](https://github.com/summerhammer/yellowhammer/commit/b018a4dd57490cb2a07f0ba34665d5d5f03702cd))
* **shift-scheduling:** build fires one minute after land, and flush firings close the Night after night_end ([#430](https://github.com/summerhammer/yellowhammer/issues/430)) ([4b75ed7](https://github.com/summerhammer/yellowhammer/commit/4b75ed7af12967fcf859bd230245eea9c04a48de))


### Bug Fixes

* **config:** fire each periodic build one minute after its land tick ([f0e2d36](https://github.com/summerhammer/yellowhammer/commit/f0e2d36696aad4f8e0f12871516015419374a6ef))
* **doctor:** keep each job's installed yh on --fix, and report Weekday, Day or Month constraints ([bf322c6](https://github.com/summerhammer/yellowhammer/commit/bf322c659842473fa2b328bb0f1818a7202bb4b3))
* **engine:** a flush firing accepts a Night Card completion the closing land never accepted ([6feda4b](https://github.com/summerhammer/yellowhammer/commit/6feda4b96a09730b07fa9c17f370c94b623e3a3b))
* **engine:** a staggered flush firing before the next Night's author belongs to the previous Night ([be30938](https://github.com/summerhammer/yellowhammer/commit/be309389fae031ff185f6dd483f44aa238204cdb))

## [0.11.0](https://github.com/summerhammer/yellowhammer/compare/v0.10.1...v0.11.0) (2026-10-09)


### Features

* **doctor:** Verification route reachability warning in Check 1 (OQ154) ([#420](https://github.com/summerhammer/yellowhammer/issues/420)) ([#428](https://github.com/summerhammer/yellowhammer/issues/428)) ([be4435c](https://github.com/summerhammer/yellowhammer/commit/be4435c2b9129f563c44be4c00377bd9195dc07d))
* **engine:** register each Repo with Orca ADE in setup; add yh doctor Check 8 orca ([a973f2e](https://github.com/summerhammer/yellowhammer/commit/a973f2e0022b0b9317a5c64777feebe4c3a2e646))


### Bug Fixes

* **app:** show undelivered writes and recovered failures in Pulse ([#423](https://github.com/summerhammer/yellowhammer/issues/423)) ([9c0890c](https://github.com/summerhammer/yellowhammer/commit/9c0890c00ee38a0e03f582fd5d6f88e0d8aa824e))
* **engine:** authenticate the Mainline fetch with the Project's Code Hosting Connection ([#426](https://github.com/summerhammer/yellowhammer/issues/426)) ([fdd928d](https://github.com/summerhammer/yellowhammer/commit/fdd928df2b4d64ec902ec37903a7864a1ec734fc))
* **engine:** push over HTTPS with the Project's Code Hosting Connection when origin is SSH ([27e0f33](https://github.com/summerhammer/yellowhammer/commit/27e0f3383b65f79abc39ccabe91c585261cccc4d)), closes [#421](https://github.com/summerhammer/yellowhammer/issues/421)
* **engine:** report a Card's last Check run, Attempt results and end state on the Night Card ([#427](https://github.com/summerhammer/yellowhammer/issues/427)) ([eb8478a](https://github.com/summerhammer/yellowhammer/commit/eb8478a4f704a20b6c2ab8cfc5ecb004b0418681))
* **engine:** retry transient Linear failures inside the Act; record a deferred Night-closing write ([bcaa79c](https://github.com/summerhammer/yellowhammer/commit/bcaa79cb1f67671cf3370fcbd8b1ef5a52fa03d3)), closes [#409](https://github.com/summerhammer/yellowhammer/issues/409)
* **engine:** show display identifiers, deduplicate clauses, and name Operator turns ([#424](https://github.com/summerhammer/yellowhammer/issues/424)) ([dc31156](https://github.com/summerhammer/yellowhammer/commit/dc31156b0085d4f1c3befc43ee4a9c25d2711542))

## [0.10.1](https://github.com/summerhammer/yellowhammer/compare/v0.10.0...v0.10.1) (2026-10-09)


### Bug Fixes

* **engine:** keep the Cycle unlanded while a push or pull request is outstanding ([#405](https://github.com/summerhammer/yellowhammer/issues/405)) ([898122e](https://github.com/summerhammer/yellowhammer/commit/898122e350f2fe59f002f064b5643d28870df493))
* **engine:** resolve path.md#anchor citations and specify citation forms in breakdown ([#406](https://github.com/summerhammer/yellowhammer/issues/406)) ([#415](https://github.com/summerhammer/yellowhammer/issues/415)) ([1f6405c](https://github.com/summerhammer/yellowhammer/commit/1f6405cb286bd33de447785fa7b91b9e794801d0))
* **settings:** refresh live Code Hosting identity and refusals ([#414](https://github.com/summerhammer/yellowhammer/issues/414)) ([74e4ad0](https://github.com/summerhammer/yellowhammer/commit/74e4ad08455212f97621a35fa08d7f3c486c9034))
* **setup:** preserve running and unchanged LaunchAgents ([#412](https://github.com/summerhammer/yellowhammer/issues/412)) ([78f6be2](https://github.com/summerhammer/yellowhammer/commit/78f6be2e8928490789f0a8fd87b4f486e65f9e05)), closes [#407](https://github.com/summerhammer/yellowhammer/issues/407)

## [0.10.0](https://github.com/summerhammer/yellowhammer/compare/v0.9.0...v0.10.0) (2026-10-08)


### ⚠ BREAKING CHANGES

* **config:** Replace yh setup --install-github and --print-github with named yh config connection commands and check-code-hosting-credential.
* **config:** `config.toml`'s `[github]` table and a Project file's `[github] credential` are refused. Reconnect with `yh setup --install-github` and add `[code_hosting] connection` to each Project file.

### Features

* **app:** Pulse Health flag for a refused Code Hosting Connection ([#394](https://github.com/summerhammer/yellowhammer/issues/394)) ([e204cfb](https://github.com/summerhammer/yellowhammer/commit/e204cfb4c2473228b2f4700ce1c3d4afef43e927))
* **app:** wizard Code Hosting step and Configuration picker ([#403](https://github.com/summerhammer/yellowhammer/issues/403)) ([ec4b0b1](https://github.com/summerhammer/yellowhammer/commit/ec4b0b1ca53c330d10fc6dab171d8bd89ffceb99))
* **cli:** install Command Line Tool symlink at /usr/local/bin/yh ([#382](https://github.com/summerhammer/yellowhammer/issues/382)) ([778f476](https://github.com/summerhammer/yellowhammer/commit/778f476682cb7ad515d0293baf78dda46e30fb7a))
* **config:** Code Hosting Connection registry and Project selection ([8f14e41](https://github.com/summerhammer/yellowhammer/commit/8f14e415630ac7e19101fbf59182b5c04171836a))
* **config:** gh CLI Code Hosting Connection type ([#391](https://github.com/summerhammer/yellowhammer/issues/391)) ([#401](https://github.com/summerhammer/yellowhammer/issues/401)) ([b3a4352](https://github.com/summerhammer/yellowhammer/commit/b3a4352d96dd9ffaf3e6cf3252fe11f06de5dbbb))
* **config:** manage Code Hosting Connection tokens ([e287a4f](https://github.com/summerhammer/yellowhammer/commit/e287a4fa5a3343c6c9908a76c4178ac30cf252d9))
* **doctor:** Check 5: Code Hosting Connections ([#390](https://github.com/summerhammer/yellowhammer/issues/390)) ([bd5ac4e](https://github.com/summerhammer/yellowhammer/commit/bd5ac4e893038227ab2a7dffd112a0062f4a0248))
* **project:** select and change a Project's Code Hosting Connection ([#389](https://github.com/summerhammer/yellowhammer/issues/389)) ([#400](https://github.com/summerhammer/yellowhammer/issues/400)) ([39fc70b](https://github.com/summerhammer/yellowhammer/commit/39fc70bbd002284d73e94bc744a7edc1124adbc1))
* **settings:** discover CLI models for Route dropdowns ([#380](https://github.com/summerhammer/yellowhammer/issues/380)) ([06c9f4f](https://github.com/summerhammer/yellowhammer/commit/06c9f4ffb27a5e42063fd5218a1f2dbd49ce2a6d))
* **settings:** Settings › Code Hosting section ([#402](https://github.com/summerhammer/yellowhammer/issues/402)) ([74a1bdc](https://github.com/summerhammer/yellowhammer/commit/74a1bdc880e212bbf6055822c3e21829637b350a))
* **setup:** capture and validate the GitHub credential ([#385](https://github.com/summerhammer/yellowhammer/issues/385)) ([c46967c](https://github.com/summerhammer/yellowhammer/commit/c46967cf0fac0d9b06b231fb8b5cf6feb08453c6))

## [0.9.0](https://github.com/summerhammer/yellowhammer/compare/v0.8.0...v0.9.0) (2026-10-07)


### Features

* **settings:** autodetect Claude Code, Codex and Antigravity CLIs ([#379](https://github.com/summerhammer/yellowhammer/issues/379)) ([7248510](https://github.com/summerhammer/yellowhammer/commit/724851077de6bc0c97812e4162d46dfe5c46f7f4))


### Bug Fixes

* **app:** refuse and flag an agent CLI executable that cannot run ([5b1f13c](https://github.com/summerhammer/yellowhammer/commit/5b1f13c7c88e46d3ae24add77cd0c21908926988)), closes [#377](https://github.com/summerhammer/yellowhammer/issues/377)

## [0.8.0](https://github.com/summerhammer/yellowhammer/compare/v0.7.0...v0.8.0) (2026-10-07)


### Features

* **app:** the Project's workspace label links to its Board Connection (OQ145) ([#370](https://github.com/summerhammer/yellowhammer/issues/370)) ([eebb560](https://github.com/summerhammer/yellowhammer/commit/eebb560ab5b1ea06b8750f475af7554b38f8c8f8))
* **engine:** a trashed or archived Work Card is set aside, never recreated, and named in the Night Summary (OQ142) ([#374](https://github.com/summerhammer/yellowhammer/issues/374)) ([40a8254](https://github.com/summerhammer/yellowhammer/commit/40a8254d20c35c81ac17409f5c180ec9d3991fea))
* **engine:** Cancelled → Shelved in the Work Card state, the Roll-up member group and the Journal values (OQ128, OQ144) ([#371](https://github.com/summerhammer/yellowhammer/issues/371)) ([3348f7e](https://github.com/summerhammer/yellowhammer/commit/3348f7e18a46dfa8e21688e29c4224bde60a3c27))
* **engine:** recover a Feature Branch that is already gone, and name the loss in the Night Summary (OQ133) ([e4399a8](https://github.com/summerhammer/yellowhammer/commit/e4399a8383b3bf6558757024d31b17fc0a6f0c61)), closes [#355](https://github.com/summerhammer/yellowhammer/issues/355)
* **engine:** replace archived Night Cards without unarchiving ([6cca544](https://github.com/summerhammer/yellowhammer/commit/6cca5442505f5020427d8d57bb2031f3b1a2ad2b)), closes [#354](https://github.com/summerhammer/yellowhammer/issues/354)
* **engine:** resolve the board scope before any work; a refused Night spends no overdue_nights_max (OQ85, OQ136) ([#373](https://github.com/summerhammer/yellowhammer/issues/373)) ([c21bc77](https://github.com/summerhammer/yellowhammer/commit/c21bc77d6bb815e4e5e52fa629db0207ba73efb8))
* **engine:** scrub narrative text before it leaves the Mac (OQ146, OQ147) ([8663b64](https://github.com/summerhammer/yellowhammer/commit/8663b64c198d130d069290230d82e021ba8ccf6a)), closes [#358](https://github.com/summerhammer/yellowhammer/issues/358)


### Bug Fixes

* **engine:** a Rehearsal Night runs in its Project's own rehearsal Journal and Linear project (OQ149) ([#367](https://github.com/summerhammer/yellowhammer/issues/367)) ([1ea49b2](https://github.com/summerhammer/yellowhammer/commit/1ea49b26eb9496f0193051963d534cad5aba5c1a))
* **engine:** accept re-ready for every Block Reason ([9c2f44b](https://github.com/summerhammer/yellowhammer/commit/9c2f44b80ee818350db6259f2c9b56c0ebfc892c)), closes [#352](https://github.com/summerhammer/yellowhammer/issues/352)
* **engine:** acknowledge overreach replies and prioritize Divergence ([#363](https://github.com/summerhammer/yellowhammer/issues/363)) ([34b027d](https://github.com/summerhammer/yellowhammer/commit/34b027d220b5ea8ee30a57b2afdb317d34d50a42))
* **engine:** exclude rehearsal Nights from instrumented rates (OQ140) ([#365](https://github.com/summerhammer/yellowhammer/issues/365)) ([fec94b3](https://github.com/summerhammer/yellowhammer/commit/fec94b367598041164bc3d905e6bf14c83e5793a))
* **setup:** a collision on a provisioned label is an unfinished step, and `yh doctor` fails on it ([#366](https://github.com/summerhammer/yellowhammer/issues/366)) ([a70dca1](https://github.com/summerhammer/yellowhammer/commit/a70dca15fa75171ea0017cce502622e006d622c0))

## [0.7.0](https://github.com/summerhammer/yellowhammer/compare/v0.6.0...v0.7.0) (2026-10-06)


### ⚠ BREAKING CHANGES

* **config:** rename Linear installations to Board Connections ([#349](https://github.com/summerhammer/yellowhammer/issues/349))
* **engine:** hard rename, with no migration (sponsor ruling, 2026-10-05). Labels provisioned on a team under the old names are not recognised. A Journal holding an old `block_reason` value reads as Blocked with no known reason. The `block_reason` column has no CHECK constraint, so there is no schema bump.

### Features

* **config:** rename Linear installations to Board Connections ([#349](https://github.com/summerhammer/yellowhammer/issues/349)) ([62c3506](https://github.com/summerhammer/yellowhammer/commit/62c35065550b863a706e97de227971acacbf61ab))
* **engine:** Block Reason labels in the subject + issue form, plus `failure recurrence` (OQ128, OQ127) ([#345](https://github.com/summerhammer/yellowhammer/issues/345)) ([e3cf633](https://github.com/summerhammer/yellowhammer/commit/e3cf633f6c1eec1ed0e56e084824823eed8b45f2))
* **engine:** settle value Released → Abandoned, gesture release → abandon (OQ128) ([aee2bfe](https://github.com/summerhammer/yellowhammer/commit/aee2bfe3c116ad6e0c6ade7bb21484a206c53c4b)), closes [#335](https://github.com/summerhammer/yellowhammer/issues/335)
* **engine:** use waiting and partial Roll-up words ([#341](https://github.com/summerhammer/yellowhammer/issues/341)) ([260e1e7](https://github.com/summerhammer/yellowhammer/commit/260e1e7427124e8f432d1af3dec50a862559556b))


### Bug Fixes

* **engine:** an expired `overreach` Work Card Blocks under `decision overdue`, not the reply reason (OQ89, OQ128) ([#348](https://github.com/summerhammer/yellowhammer/issues/348)) ([9930009](https://github.com/summerhammer/yellowhammer/commit/99300098e22bd674fe6371503b69a15ac812d028))
* **engine:** pin whole Routes with one Override label group and pre-flight them ([#347](https://github.com/summerhammer/yellowhammer/issues/347)) ([1bac4db](https://github.com/summerhammer/yellowhammer/commit/1bac4dbda433d83937e91eb6645bf71899cadd8a))
* **setup:** provision the `Card Type` label group — `Feature Card`, `Work Card`, `Night Card` ([e3f3382](https://github.com/summerhammer/yellowhammer/commit/e3f3382d76519df39ce936475a43b07d054de80f)), closes [#334](https://github.com/summerhammer/yellowhammer/issues/334)

## [0.6.0](https://github.com/summerhammer/yellowhammer/compare/v0.5.0...v0.6.0) (2026-10-05)


### Features

* **app:** remove a Project from Settings ([113c6a0](https://github.com/summerhammer/yellowhammer/commit/113c6a00217f57c7e1b6bb3d0b7ccbd8af23bdfe))
* **app:** remove a refused Project from Refused Files ([620c182](https://github.com/summerhammer/yellowhammer/commit/620c182c3b977c7517068ec3d53ed9be0ed044d7))
* **app:** start the author Act on demand ([fe53863](https://github.com/summerhammer/yellowhammer/commit/fe53863ad0867a6c30d1fba43a663032fc604813))
* **app:** verify a pasted Linear project id on Board step ([#299](https://github.com/summerhammer/yellowhammer/issues/299)) ([a044502](https://github.com/summerhammer/yellowhammer/commit/a04450205892d90585f9c89ee13bb9b05d1619d3))
* **db:** extend DB schema with readable values for display ([bb4f26c](https://github.com/summerhammer/yellowhammer/commit/bb4f26c7287f644b8a2a69c37cf72ac3d91133b8)), closes [#326](https://github.com/summerhammer/yellowhammer/issues/326)


### Bug Fixes

* **ci:** accept a prefixed Feature Branch in the spec check and rehearsal suite ([510956e](https://github.com/summerhammer/yellowhammer/commit/510956e76d9f77c0f997f14989f89843aecad5e3)), closes [#318](https://github.com/summerhammer/yellowhammer/issues/318)
* **config:** expand home paths before engine dispatch ([1333b9f](https://github.com/summerhammer/yellowhammer/commit/1333b9fc62df82a65a9e174890abcff5d9f4e22d)), closes [#314](https://github.com/summerhammer/yellowhammer/issues/314)
* **engine:** a Worktree branch-name collision halts the build Act ([20efc16](https://github.com/summerhammer/yellowhammer/commit/20efc168646e6fd37a2149f94c24e5559d67d4ca)), closes [#318](https://github.com/summerhammer/yellowhammer/issues/318)
* **engine:** address the Layer 1 review of the recorded Feature Branch ([ce8c164](https://github.com/summerhammer/yellowhammer/commit/ce8c164a7a66051d8f712e7dd1e762da5d1a7999)), closes [#318](https://github.com/summerhammer/yellowhammer/issues/318)
* **engine:** pin the Feature Branch before a ghost-Worktree purge ([2b223a9](https://github.com/summerhammer/yellowhammer/commit/2b223a9985c4a794cf65ee653f72488875e489e0)), closes [#325](https://github.com/summerhammer/yellowhammer/issues/325)
* **engine:** record the Feature Branch Orca ADE reports per repo ([6a7fe0f](https://github.com/summerhammer/yellowhammer/commit/6a7fe0fc8d0de98951d24e4cf808cf122fe42a1e)), closes [#318](https://github.com/summerhammer/yellowhammer/issues/318)
* **engine:** resolve the Feature Branch per repo in every consumer ([bb63feb](https://github.com/summerhammer/yellowhammer/commit/bb63feb04f635a910e3a22d4fe2b24e34cd70905)), closes [#318](https://github.com/summerhammer/yellowhammer/issues/318)
* **journal:** serialise creating and migrating a Journal across processes ([#322](https://github.com/summerhammer/yellowhammer/issues/322)) ([b565e12](https://github.com/summerhammer/yellowhammer/commit/b565e12641eeabb07768534b6cf048a5b8ef655f)), closes [#316](https://github.com/summerhammer/yellowhammer/issues/316)
* **pulse:** show running Acts from the Journal lease ([70fbb53](https://github.com/summerhammer/yellowhammer/commit/70fbb537bab5c6c43ca3ab3ea3a27614cf4948f4)), closes [#315](https://github.com/summerhammer/yellowhammer/issues/315)
* **pulse:** surface failed Acts and idle lanes ([7d77e22](https://github.com/summerhammer/yellowhammer/commit/7d77e22ffdf5f39102cee0767b4850a29b606008)), closes [#319](https://github.com/summerhammer/yellowhammer/issues/319)

## [0.5.0](https://github.com/summerhammer/yellowhammer/compare/v0.4.0...v0.5.0) (2026-10-04)


### ⚠ BREAKING CHANGES

* **setup:** `yh setup --linear-credential` is removed; `--installation <name>` names the Linear App Installation a run acts on. The credential is always
* **config:** config.toml's [linear] table is replaced by [board.linear.installations.<name>] tables, and a Project file's top-level linear_project by [board.linear] installation and project. A file in the old shape is refused at load; there is no migration.

### Features

* **app:** each Project's Health shows only its own installation's flags ([c5031af](https://github.com/summerhammer/yellowhammer/commit/c5031af4535df7df007cef181c48ea892c7e008f))
* **app:** move Hub4's step bodies and a readiness panel into the app ([abd0dd4](https://github.com/summerhammer/yellowhammer/commit/abd0dd45ba3dbe0b63f0b99cee34790435dcf10e))
* **app:** move the Add Project draft and its rules into Config ([b1d039a](https://github.com/summerhammer/yellowhammer/commit/b1d039aeb68eca009185c58e2fecd551dd314ece))
* **app:** restyle the Overview window's Pulse, Inspector and Sidebar ([#274](https://github.com/summerhammer/yellowhammer/issues/274)) ([8007b4c](https://github.com/summerhammer/yellowhammer/commit/8007b4c57bfb9ebc2e0174f17cdf68ead6f52f29))
* **app:** swap the Add Project sheet to Hub4 ([bc8bdff](https://github.com/summerhammer/yellowhammer/commit/bc8bdff23a0600679ea7b215381ccf9ca7d48bb2))
* **cli-adapters:** add Antigravity (agy) as an agent CLI ([4412dd2](https://github.com/summerhammer/yellowhammer/commit/4412dd232340f5250ae692051a1f69305c2b463d))
* **config:** ask a draft Routing Table which entry routes a Card ([3772938](https://github.com/summerhammer/yellowhammer/commit/37729383b255f14fce4fccba9581e1328d53e2e9))
* **config:** select each Project's Linear App Installation from a registry ([89e1a48](https://github.com/summerhammer/yellowhammer/commit/89e1a48d6ad155aef5ede0eb30ab1c153cba650a))
* **config:** yh config operator and yh config remove-installation ([ee6a03d](https://github.com/summerhammer/yellowhammer/commit/ee6a03dd11ce4d029a813118b68810080ab89fe2))
* **doctor:** yh doctor Check 4 runs per Linear App Installation ([6e69a50](https://github.com/summerhammer/yellowhammer/commit/6e69a50208a38be4e20add9309409b5a15908615))
* **engine:** one refresh lock, budget record and halt per Linear App Installation ([4607126](https://github.com/summerhammer/yellowhammer/commit/4607126278422f43dcf58eecc2d534b8b66d6d05))
* **engine:** record each App Installation token refresh in the Act's Journal ([e853c3d](https://github.com/summerhammer/yellowhammer/commit/e853c3d6bf2fb6e87b80f75374eb8aeb2a2dc998))
* **engine:** timestamp the error line an Act writes to its diagnostic log ([9c0f7b1](https://github.com/summerhammer/yellowhammer/commit/9c0f7b173211d96f782c88eb044ca191be44d4ce))
* **journal:** record the Linear workspace a Journal is built against ([de7d9ca](https://github.com/summerhammer/yellowhammer/commit/de7d9ca00a7b7112efb19e1ccd3fb5d5fd10d3a0))
* **pulse:** open the Night Card, Linear issues and pull requests from the Pulse ([64bd54e](https://github.com/summerhammer/yellowhammer/commit/64bd54ed2c55cca25d719d6770369cc9945691bb)), closes [#230](https://github.com/summerhammer/yellowhammer/issues/230)
* **settings:** lay the Agent CLIs pane out in two columns ([bb3aff6](https://github.com/summerhammer/yellowhammer/commit/bb3aff66af7659f59e264933738dc3cbcb2cd4db))
* **settings:** rebuild the Base Routing Table pane as Cards, Author and Verification ([927a9f2](https://github.com/summerhammer/yellowhammer/commit/927a9f20ba56728de51b8ad7b421918db6055e27))
* **settings:** restyle Settings, add a Boards section, remove agent CLIs ([#301](https://github.com/summerhammer/yellowhammer/issues/301)) ([28c109d](https://github.com/summerhammer/yellowhammer/commit/28c109d69258b885ac7537cd832922077336ca84))
* **settings:** Settings → General lists the Linear workspaces ([ef31917](https://github.com/summerhammer/yellowhammer/commit/ef31917d86ae6e7ee1d7bb595cbb940861cd7502))
* **setup:** Add Project's Linear step chooses the Linear workspace ([558d0c7](https://github.com/summerhammer/yellowhammer/commit/558d0c754057222956806799baf0051272aa2e5d))
* **setup:** let yh setup --init and the Add Project sheet set the Night window ([bdb3ba7](https://github.com/summerhammer/yellowhammer/commit/bdb3ba7787120afcfbda551133548a97d1f6e69e))
* **setup:** list active Linear projects in yh setup --print-choices and the sheet ([6bf2465](https://github.com/summerhammer/yellowhammer/commit/6bf246570b4decf0a595497c9e9ad770e1b89ba9))
* **setup:** make Add Project work on a first run and guide it step by step ([#300](https://github.com/summerhammer/yellowhammer/issues/300)) ([1f7922a](https://github.com/summerhammer/yellowhammer/commit/1f7922abc6fc7f11331b9b16cfa1eab41311a188))
* **setup:** name a new Linear installation and remove a refused one anyway ([#304](https://github.com/summerhammer/yellowhammer/issues/304)) ([6901a10](https://github.com/summerhammer/yellowhammer/commit/6901a10c743001367a0d7bc429c033bedb12b7af))
* **setup:** yh setup connects, re-connects and selects from the App Installation registry ([a628aef](https://github.com/summerhammer/yellowhammer/commit/a628aefa287f2decbc3977275c61543a547450cd))


### Bug Fixes

* **app:** keep each Pulse row's own accessibility identifier ([3b78774](https://github.com/summerhammer/yellowhammer/commit/3b7877433be6b520348e14e0c3aeca5cb02ac8c2))
* **app:** let Settings declare an agent CLI ([687329a](https://github.com/summerhammer/yellowhammer/commit/687329ab0933e71e1979432b8c8bee07b4d4ffea)), closes [#281](https://github.com/summerhammer/yellowhammer/issues/281)
* **app:** start the agent CLI picker on an offered name ([422513a](https://github.com/summerhammer/yellowhammer/commit/422513a06cfb72461ee48502d6f5c9780b512941))
* **app:** the Setup wizard acts on the App Installation its Linear step installed into ([78a5b8f](https://github.com/summerhammer/yellowhammer/commit/78a5b8f66187a98d4b552dd719c8395fba001dfb))
* **linear:** page the Linear projects list by 50 so Linear accepts it ([82d2c49](https://github.com/summerhammer/yellowhammer/commit/82d2c49851f9497d5238dd55be09fbf3b5250f1f))
* **overview:** keep a Project's status when its Journal cannot be read ([#313](https://github.com/summerhammer/yellowhammer/issues/313)) ([8838567](https://github.com/summerhammer/yellowhammer/commit/88385679840e5c9f0bb3b84883af4167011c2176))
* **pulse:** read a Project's working status from its launchd Act jobs ([#309](https://github.com/summerhammer/yellowhammer/issues/309)) ([7813783](https://github.com/summerhammer/yellowhammer/commit/78137830efd085fc2d3764bdc594e580c04be030))
* **setup:** warn when --print-choices cannot list the Linear projects ([6758dc4](https://github.com/summerhammer/yellowhammer/commit/6758dc4e45e7b6180fc6b95c0c51a59c55c6f66c))


### Performance

* **overview:** make openPulseDestination an Equatable action ([2f653f3](https://github.com/summerhammer/yellowhammer/commit/2f653f3f821daa65d952d156d0a6d5ce455c6c37)), closes [#227](https://github.com/summerhammer/yellowhammer/issues/227)

## [0.4.0](https://github.com/summerhammer/yellowhammer/compare/v0.3.0...v0.4.0) (2026-10-02)


### ⚠ BREAKING CHANGES

* **journal:** Journals created by earlier builds are refused by both the engine and the app; delete and recreate them.

### Features

* **app:** add a Project through the Add Project sheet ([9ce4d60](https://github.com/summerhammer/yellowhammer/commit/9ce4d60105767e9c6f6744b7b8465bf0ffa3a3d5))
* **app:** add the toolbar's Inspector toggle and Stop the engine ([4f5cb8e](https://github.com/summerhammer/yellowhammer/commit/4f5cb8e8a440240910cc2d4bf2881fdc007855e0))
* **app:** agent CLIs and base Routing Table in the Settings window ([6cf2b8d](https://github.com/summerhammer/yellowhammer/commit/6cf2b8d6e90ab316e996d7ae8116778436656b80))
* **app:** build the Inspector's Card detail ([9fadff7](https://github.com/summerhammer/yellowhammer/commit/9fadff7d71f0d8f0128a5b47b39a5f4eac5977c7))
* **app:** build the Inspector's Feature, Attempt and Repo detail ([d7ed078](https://github.com/summerhammer/yellowhammer/commit/d7ed078d6fe4bd3afc16e2c6cd98c0c0a03d01de))
* **app:** build the Pulse Feature group ([7afdb1c](https://github.com/summerhammer/yellowhammer/commit/7afdb1cc49e7ef0880b3d50b3586a7671cb8038a))
* **app:** build the Pulse Health group ([24a9492](https://github.com/summerhammer/yellowhammer/commit/24a94926e7252510dee1493a9f3923c6d9fb16d8))
* **app:** build the Pulse Tonight / last Night group ([3a70f29](https://github.com/summerhammer/yellowhammer/commit/3a70f29681a658a632338ffc796a427e80635f3d))
* **app:** build the Settings window shell ([062c7a5](https://github.com/summerhammer/yellowhammer/commit/062c7a57a8076fa9c6a47e3ff61c2c207bb9aace))
* **app:** build the three-column Overview window ([c973ae9](https://github.com/summerhammer/yellowhammer/commit/c973ae9555188e09bce1210c35061ff650b993c9))
* **app:** edit a Project's Configuration in the Settings window ([b798dbc](https://github.com/summerhammer/yellowhammer/commit/b798dbce0f7974e4b44a04999841e633ba8db981))
* **app:** Linear installation, Operator identity and Orca ADE in Settings ([446d80f](https://github.com/summerhammer/yellowhammer/commit/446d80f4f14add47a879d2aa69d779690586b0f3))
* **app:** offer Abort Attempt on a running Attempt ([c6e873b](https://github.com/summerhammer/yellowhammer/commit/c6e873b889dca705ae74a97f1a918b7a867aab5d))
* **app:** prototype the Pulse landing screen in Xcode Previews ([#223](https://github.com/summerhammer/yellowhammer/issues/223)) ([97aa58b](https://github.com/summerhammer/yellowhammer/commit/97aa58bbbe9344a2eab9e00de3ca251b97b83147))
* **app:** recalibrate in the Settings window ([6187885](https://github.com/summerhammer/yellowhammer/commit/61878857af1da8800c24349ea6f148bde633a1a2))
* **config:** Change Type and Message Templates in Project configuration ([e946395](https://github.com/summerhammer/yellowhammer/commit/e9463959ea278b47197188de312638ad6449f761))
* **engine:** abort every running Attempt of a Project on yh stop ([cb5bc2b](https://github.com/summerhammer/yellowhammer/commit/cb5bc2b5c13eebd12497c3c1bf17286254d62b40))
* **engine:** abort one running Attempt with yh abort ([1ffab45](https://github.com/summerhammer/yellowhammer/commit/1ffab45fc5a701aa8d8f4108d954db2dea97fad3))
* **engine:** ask the worker for the commit-message template and record a missing Yellowhammer-Work-Card trailer ([b978ec1](https://github.com/summerhammer/yellowhammer/commit/b978ec1488e8de82d6fd8fee4e1209947c539d9b))
* **engine:** record the No-Pushed-Branch Outcome and count N over pushed branches ([0195e7f](https://github.com/summerhammer/yellowhammer/commit/0195e7f13a16f7cc68a7ec3a189867ac66b603ea))
* **engine:** render each pull request title from its Message Template ([4780b58](https://github.com/summerhammer/yellowhammer/commit/4780b581fd2a27ffa12a03b4a2ed850c9efaff65))
* **engine:** reset the lane when a question puts its Card in Waiting on You ([27f6b82](https://github.com/summerhammer/yellowhammer/commit/27f6b82ddf4c65d863e4631bd1a12905dd641c6a))
* **engine:** show [no pull request: &lt;repo&gt;] beside the Roll-up sentence ([67dc29f](https://github.com/summerhammer/yellowhammer/commit/67dc29f57dcd45fdb34965686d8cbb861b5ad9f1))
* **engine:** write every WIP Commit from its Message Template, with trailer and author ([9270b9a](https://github.com/summerhammer/yellowhammer/commit/9270b9a1408be7b2115bb3ff3c9573d62b7efc39))
* **pulse:** add the Pulse module ([#226](https://github.com/summerhammer/yellowhammer/issues/226)) ([a596ef8](https://github.com/summerhammer/yellowhammer/commit/a596ef8248b29e64a682a6d5c66082b117578baf))


### Bug Fixes

* **app:** drop a window value whose Project no longer exists ([f5ba051](https://github.com/summerhammer/yellowhammer/commit/f5ba0510c7b6780aa9e00bb3e23760aea36c311d))
* **app:** drop an activation while the window's read still runs ([b029f2b](https://github.com/summerhammer/yellowhammer/commit/b029f2b4d58700639cba3e21088c9d11437be387))
* **app:** guard subprocess exit and debug updater ([59f5753](https://github.com/summerhammer/yellowhammer/commit/59f5753395e237d7920f611d92ba172c8f8d3400))
* **app:** read the Card account off the main actor ([#234](https://github.com/summerhammer/yellowhammer/issues/234)) ([6f1498f](https://github.com/summerhammer/yellowhammer/commit/6f1498fefaec1ebbf78f7cc7b4c545fcad20e42a))
* **app:** show the onboarding view on a fresh install ([4baddab](https://github.com/summerhammer/yellowhammer/commit/4baddab743ade89fe74c9feeed3604447c63fd90)), closes [#232](https://github.com/summerhammer/yellowhammer/issues/232)
* **engine:** admit one TerminationSignals.run at a time ([144f8ee](https://github.com/summerhammer/yellowhammer/commit/144f8ee2c77baac0ae636f61a0a474425f067612)), closes [#215](https://github.com/summerhammer/yellowhammer/issues/215)
* **journal:** tell a Journal from an earlier build from a newer one ([95d5aa7](https://github.com/summerhammer/yellowhammer/commit/95d5aa707f0f08694016c5fa86188dfddc69b22c))


### Refactoring

* **journal:** squash Journal migrations into one ([c6961fb](https://github.com/summerhammer/yellowhammer/commit/c6961fb8ddef2680725e1ce6b85df4b10ee659a2))

## [0.3.0](https://github.com/summerhammer/yellowhammer/compare/v0.2.0...v0.3.0) (2026-09-28)


### Features

* **app:** request Linear approval from an admin in the Setup window ([98e207b](https://github.com/summerhammer/yellowhammer/commit/98e207b72a3d9071ffe822de7afc6a65ab3e21ab))
* **setup:** request Linear install approval from a remote admin via the Code Relay ([6bea632](https://github.com/summerhammer/yellowhammer/commit/6bea632556de30c1e7a6fb4e8eefdc59d2af86cb))


### Bug Fixes

* **engine:** avoid restoring SIG_DFL after real signals in test host ([0337659](https://github.com/summerhammer/yellowhammer/commit/03376593dea9c5ce4f80546d94962903c3bddbd8))
* **engine:** launch the enclosing app for headless posts, not any copy ([652a5a2](https://github.com/summerhammer/yellowhammer/commit/652a5a2484a5dd0f971bb4a4d46059050f432150))
* **setup:** line-buffer stdout so progress and the approval link arrive live ([5cbc122](https://github.com/summerhammer/yellowhammer/commit/5cbc122f93672b545f6b4a133c3439126aab4c9f))

## [0.2.0](https://github.com/summerhammer/yellowhammer/compare/v0.1.1...v0.2.0) (2026-09-27)


### ⚠ BREAKING CHANGES

* **linear:** a config.toml naming [linear].client_id no longer loads; re-run the Linear step of yh setup to install Yellowhammer's app.

### Features

* **app:** install Yellowhammer's Linear app from the Setup view ([75f3452](https://github.com/summerhammer/yellowhammer/commit/75f3452f928d0d831193712b31a2ac9bd9251953))
* **config:** add the machine-wide refresh lock and the Keychain token pair store ([8b15577](https://github.com/summerhammer/yellowhammer/commit/8b15577da3a0f2f251caf02bc5a1b2e6e83a6362))
* **engine:** halt an Act on a Linear authorization failure (OQ93) ([0a15601](https://github.com/summerhammer/yellowhammer/commit/0a156017cb5177cc3df6cfc5c19d30e43180a95b))
* **engine:** post the halted notification when the halt is not on the Night Card (OQ71) ([c36f5cb](https://github.com/summerhammer/yellowhammer/commit/c36f5cb7f055057925b05154cd6bfbd41223a04d))
* **linear:** add the App Installation client and refresh-based tokens (ADR-005) ([9e15a94](https://github.com/summerhammer/yellowhammer/commit/9e15a94a7fac72df65a6c3788edb26414f37b04e))
* **setup:** add the install event contract and repair a legacy Linear block ([4ed89fc](https://github.com/summerhammer/yellowhammer/commit/4ed89fcfff51d0b768f1baa7870096577c8fb780))
* **setup:** add the loopback install flow for Yellowhammer's Linear app ([648bf95](https://github.com/summerhammer/yellowhammer/commit/648bf95de03fe2b218e7a353128c3c55ca3456e9))
* **setup:** check team membership before provisioning creates (OQ80) ([d9b0ee0](https://github.com/summerhammer/yellowhammer/commit/d9b0ee011acc985f54f360771dac52afa251a736))
* **setup:** install Yellowhammer's Linear app from yh setup (OQ93, OQ94) ([494bd46](https://github.com/summerhammer/yellowhammer/commit/494bd466ca72ad2692c877d9e64975dc103b721f))


### Bug Fixes

* **app:** keep the busy-ports view and start no updater under UI tests ([773c787](https://github.com/summerhammer/yellowhammer/commit/773c787ceda302f9c69e77410655c997b82236b4))


### Refactoring

* **linear:** replace the client-credentials identity with the App Installation ([054bb27](https://github.com/summerhammer/yellowhammer/commit/054bb27e8a3de209d013dff8ef79421e93c4eef8))
