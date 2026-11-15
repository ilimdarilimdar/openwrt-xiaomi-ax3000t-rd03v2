# RD03v2 GitHub Actions validation

This workflow separates cheap source/configuration checks from a full signed firmware build.

## Automatic static checks

A push to `work/rd03v2-dualwan-mwan3-baseline` and a pull request targeting `main` run:

- `git diff --check` and branch ancestry check;
- Bash syntax checks for shell scripts;
- Python bytecode compilation for `tools/`;
- disposable P-256 signing-key helper test: install, idempotent resume, mismatch rejection and partial-pair rejection;
- static guard for the RD03v2-only `luci-app-nss` dependency patch;
- RD03v2 target, NSS profile, mwan3 package and image manifest assertions;
- check that no `private-key.pem` is tracked.

These checks do **not** compile OpenWrt, do not validate downloaded feeds, do not build ECM, and do not prove that an image boots.

Documentation-only pushes and pull requests (changes limited to Markdown files and `docs/**`) are excluded by `paths-ignore` in the workflow. A mixed change that also touches source, configuration, scripts or workflow files still triggers validation. This avoids consuming the serialized firmware-validation slot for README/manual edits while keeping CI on changes that can affect the image.

## Automatic PREPARE_ONLY job

After static checks pass, GitHub Actions runs the normal project `build.sh` with `PREPARE_ONLY=1` on an Ubuntu runner. This stage:

- fetches the exact commits pinned in `upstream.lock` and `feeds.lock`;
- applies the repository tree patches and overlay;
- installs the pinned feeds and the feed overlay;
- runs `make defconfig` and verifies requested symbols;
- writes `.config` and `diffconfig.txt`;
- uploads the generated `tmp/.config-package.in` when present, so Kconfig dependency cycles can be traced to exact generated symbols;
- stops before package compilation, image compilation and signing.

The preparation stage does not require the private signing key. The project build script skips signing-key validation and installation only for `PREPARE_ONLY=1`; all full builds still require the matching private key. A green preparation job is **not** a full firmware build. The preparation tree's generated `tmp/.config-package.in` is diagnostic evidence, not an image artifact.

## Full build

The full build job runs only on a push whose commit message contains `[full-build]`.

A full-build run does not use the owner's release key. It generates a disposable P-256 EC keypair on the ephemeral GitHub runner, substitutes the public key only in that runner's checkout, and uses it to sign the temporary package index. The private key is not committed, printed, or uploaded. It disappears when the runner is destroyed.

The build is stamped with an `example.invalid` package-repository URL. This deliberately makes the CI image unsuitable for installation as a user-facing release. The workflow uploads logs and configuration only; it never publishes sysupgrade images or package repositories. A real release still requires the owner's long-term signing key, a real package repository URL, release artifacts, and separate review.

## Resource caveat

The workflow uses the standard GitHub-hosted Ubuntu runner with two build jobs. The project requires at least 4 GiB of available RAM during the final build. Disk capacity and run duration may still be limiting; a failed runner build must be classified by its actual log, not silently treated as a source-code failure.

## Current state

Adding this workflow does not mean a build has run. A green static-check job is not a firmware compilation result. Report separately:

- STATIC PASS/FAIL;
- PREPARE_ONLY PASS/FAIL;
- FULL BUILD PASS/FAIL;
- `verify-v2.sh` PASS/FAIL;
- hardware validation PASS/FAIL/NOT TESTED.

## NSS Kconfig cycle investigation

The first successful PREPARE_ONLY artifact showed four Kconfig recursive-dependency diagnostics. The final `.config` did not select the Qt5 GUI, fwknopd/LuCI fwknopd, or squeezelite-custom packages; the NSS diagnostic did involve packages selected in the RD03v2 image.

The pinned upstream base already contains OpenWrt's `package-metadata.pl` correction from [openwrt/openwrt#25091](https://github.com/openwrt/openwrt/pull/25091), commit `87215b42ce7cfd2f43a9423788184a74e09917f0`. Do **not** port that correction again.

The NSS cycle in the generated Kconfig is a separate dependency path: `luci-app-nss` selects the IPQ50xx `nss-tools-dwmac` package but also contains a conditional legacy `nss-tools` fallback. The DWMAC package conflicts with the legacy package and pulls in the NSS kernel stack. The RD03v2 fork now carries `tree-patches/0014-luci-app-nss-use-ipq50xx-runtime-dependency-only.patch`, which removes the unused fallback for this IPQ50xx-only fork while leaving NSS kernel modules and runtime code unchanged.

Manual patch-context check (2026-11-15): the exact `package/nss/luci-app-nss/Makefile` was fetched from the pinned upstream tree commit `c36db6321c11595dc45a160cdab36b5c2d787744`; its Git blob SHA is `c7ac95edeb9c5147b9728573af9760d4b038d2f1`, matching the patch's `index c7ac95e`. `git apply --check` passed, and applying patch 0014 left only `+luci-base +nss-tools-dwmac` in `LUCI_DEPENDS`. This proves the patch context applies cleanly to the pinned file; it does **not** prove Kconfig generation is cycle-free.

The PREPARE_ONLY artifact from 2026-11-15 was inspected: the selected NSS recursive dependency is absent after patch 0014. Three unrelated diagnostics remain for Qt5 GUI, fwknopd/LuCI fwknopd and squeezelite-custom; all three package choices are unset in the generated final `.config`. Keep these warnings visible, but do not mistake them for a failure of the selected NSS image configuration.

## Current validation snapshot — 2026-11-15
_Last live GitHub Actions check: 2026-11-15 13:26 UTC._

- Working branch: `work/rd03v2-dualwan-mwan3-baseline`.
- Latest ECM patch/source revision: `e80f964efb78331be0c5c8c26c29a724f0c668cb`. It changes the worker's RTNL barrier to Linux 6.18's `rtnl_net_lock(&init_net)` / `rtnl_net_unlock(&init_net)` API.
- The branch's later HEAD at this check is `70f92cc24098933a252c803403368534e97ec587`. Changes after `e80f964` are documentation and the static-test quoting correction; they do not alter patch 9002 itself.

### Workflow results

- Workflow #77, [run 43708414463](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43708414463), used source revision `ac4ee43c79879c8bb557a26c252eb442aa5a3654`. Static checks and PREPARE_ONLY passed. The full build failed at `package/feeds/nss/qca-nss-ecm`. Its uploaded artifact contained only top-level logs, so the actual compiler diagnostic was not captured. The precise cause remains **UNKNOWN**; do not classify it as a source-code defect or a runner resource failure without the package log.
- Workflow #78, [run 43709621665](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43709621665), uses lifecycle revision `36149940c8eb00df46d14b7bb10e747ec9666f3b`. Static checks and PREPARE_ONLY completed successfully, including the pinned-source and complete ECM feed-series preflight. At the last live check, its full-build job was still running at `Build and run verify-v2`. This run does **not** include the later `e80f964` per-net RTNL change.
- Workflow #82, [run 43715272931](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43715272931), was triggered for HEAD `70f92cc`. At the last live check it was **Waiting** for #78 to complete because the workflow serializes runs on this branch. It will exercise the `e80f964` per-net RTNL revision and the corrected static assertion.

The current workflow now uploads the package-specific NSS logs under `openwrt-v2/logs/package/feeds/nss/**` in addition to top-level build logs. This path was verified against the pinned OpenWrt `include/subdir.mk` logging layout: `BUILD_LOG=1` stores a package's compile output beneath `logs/package/<feed>/<package>/`. Therefore a later full build should expose the actual ECM compiler output if that package fails again.

### Source-level findings

- Linux v6.18 defines `rtnl_net_lock()` and `rtnl_net_unlock()`; FIB rule changes assert the matching per-net RTNL lock before notifier dispatch. The worker snapshots/clears pending family bits under `init_net`'s lock, then releases it before walking the ECM database.
- Linux v6.18 workqueue code clears the work item's pending bit before invoking its function and handles a requeued work item without running it concurrently with itself. This supports the patch's design in which a new rule event during the database walk schedules another worker pass.
- These are source/API checks only. They do not prove successful ECM compilation, module load safety, NSS offload behavior or Dual-WAN correctness.
- FIB notifier registration replays existing rules as ADD events. As documented in `ecm-policy-routing-port.md`, loading/reloading ECM can therefore cause a broad per-family defunct/re-acceleration pass. It is not session preservation across WAN address changes.

### Required gates still open

1. A successful full build of the latest `e80f964` revision.
2. Confirmation that the built `ecm.ko` contains the expected notifier marker.
3. Successful final `verify-v2.sh` checks against the generated image/root filesystem.
4. Controlled second-router tests: ECM load/unload, FIB rule churn, mwan3 restart and cable-pull failover, IPv4/IPv6 separately, NSS/ECM counters, throughput, CPU, latency and packet loss.
5. No primary-router flashing until all source, build/image and second-router hardware gates pass.

The CI full-build job uses a disposable signing key and an `example.invalid` repository URL. It uploads logs only and does not publish a usable release image. Hardware validation remains **NOT TESTED**; keep the primary router on stock firmware.
