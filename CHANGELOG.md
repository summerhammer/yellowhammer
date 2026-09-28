# Changelog

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
