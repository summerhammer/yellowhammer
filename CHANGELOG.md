# Changelog

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
