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

## Historical validation snapshot — 2026-11-15
_Last live GitHub Actions check: 2026-11-15._

- Working branch: `work/rd03v2-dualwan-mwan3-baseline`.
- Latest code/test HEAD before the documentation-only refresh: `a0e72ce6fa04a243849a96825f4891e0f0608b39` (test-only callback guard).
- Documentation-only updates after that checkpoint: `a8d15e9` and `0b5bf9f`; firmware source unchanged.
- Functional firmware-source revision: `006e14a5d0348528a021943b1fd595cc233451db`; later commits `eba9d02` and `a0e72ce` modify regression tests only.
- Pinned target tree: `c36db6321c11595dc45a160cdab36b5c2d787744`; the kernel version file pins Linux **6.18.55**.
- Pinned QSDK ECM: `7894b769eeb64f1c44fde547a107a8b866997590`; QSDK archive SHA-256 is checked by the preflight script.

### Latest workflow results

- Workflow [#105](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43729221924), source `d51baa7`: Static and PREPARE_ONLY **PASS**; the corrected raw ECM patch apply and full pinned feed-series preflight passed.
- Workflow [#106](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43729319036), functional source `006e14a`: Static **PASS**, PREPARE_ONLY **PASS**, ECM preflight **PASS**. The log confirms 9 diff file sections, 19 valid hunks, exact QSDK archive checksum, and patch 9002 applying after all 31 pinned ECM feed patches including 9001. Stop-counter lock alignment, six packet-hook reads, RTNL pending-bit snapshot, stop-gate plus `synchronize_net()` ordering, notifier init/unwind/exit and worker-drain checks all passed.
- Workflow [#107](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43729849069), test-only commit `eba9d02`: Static/PREPARE_ONLY and atomic callback regression guard **PASS**. At that historical checkpoint, the full build was still running; later runs superseded it.
- Workflow [#108](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43729952928), test-only commit `a0e72ce`: historical queued callback-guard revision; it is not the current code/test HEAD.
- Earlier runs #100–#104 failed or were cancelled while correcting patch context and unified-diff hunk counts. They are superseded by the successful #105/#106 raw source and full-series preflight; do not report those early failures as the current patch status.

### Source-level and configuration findings

- The pinned kernel is Linux 6.18.55. In the v6.18 FIB-rule path, `fib_newrule()` and `fib_delrule()` hold the matching per-net RTNL while notifying and publishing ADD/DEL changes. Patch 9002's `rtnl_net_lock(&init_net)` snapshot therefore waits until the live rule update has completed. Release RTNL before `synchronize_net()` and ECM DB traversal.
- FIB notifier dispatch uses an atomic notifier chain. The callback may not block; patch 9002 only sets family pending bits and queues work. `atomic_notifier_chain_unregister()` synchronizes with in-flight callbacks through RCU; `cancel_work_sync()` then drains the deferred worker before ECM DB/frontend teardown.
- The worker closes the affected frontend stop gate before `synchronize_net()`, then defuncts connections of that address family. Temporary-stop counter updates are serialized with the same family lock used by packet-hook stop checks. This is broad invalidation; it neither rewrites conntrack marks nor guarantees session continuity across different public WAN addresses.
- The pinned generic kernel config fragment enables `CONFIG_FIB_RULES`, `CONFIG_IP_ADVANCED_ROUTER` and `CONFIG_IP_MULTIPLE_TABLES`; the project config requests IPv6 multiple tables. `verify-v2.sh` checks these symbols in the final built kernel config.
- PREPARE_ONLY selects `mwan3`, `luci-app-mwan3`, `kmod-qca-nss-ecm`, NSS DWMAC helper, iptables/ip6tables nft frontends, xtables-nft and ipset.
- Three Kconfig recursive-dependency diagnostics remain for Qt5 GUI, fwknopd/LuCI fwknopd and squeezelite-custom. These packages are unset in final `.config`; the previous selected NSS dependency cycle is absent after tree patch 0014. Keep warnings visible and re-check when feeds change.
- PREPARE_ONLY and patch preflight do **not** prove C compilation, presence of the notifier marker in built `ecm.ko`, successful `verify-v2.sh`, safe module loading, NSS acceleration or Dual-WAN behavior.

### Required gates still open

1. Finish the full build of the exact functional revision and inspect per-package NSS/ECM compile logs if it fails.
2. Confirm `kmod-qca-nss-ecm` compilation and the expected FIB notifier marker inside the built `ecm.ko`.
3. Confirm `verify-v2.sh` passes against the generated root filesystem/image and inspect its target/profile/manifests.
4. Run module load/unload, FIB rule churn, mwan3 restart, tracker `disconnected`, real `ifdown`/cable-pull, IPv4 and IPv6 separately on a second RD03v2.
5. Measure conntrack marks, route selection for new/existing flows, NSS/ECM counters, throughput, CPU, RTT and packet loss.
6. Do not flash the primary router. CI full-build uses a disposable signing key and `example.invalid`; it uploads logs only and never publishes a usable release image.

Hardware validation remains **NOT TESTED**. A successful source preflight, build or `verify-v2.sh` is not a hardware stability claim.

## Current validation snapshot — 2026-11-16

Historical run #124 status for branch `work/rd03v2-dualwan-mwan3-baseline`, built from code/test
HEAD `bb3d25b8d80844cd32d5bb71ec1bb090f286bc10`. The current code/test HEAD is `49d3579437389e2ffc111b94a08839ef7bd29ae7`:

- **Static checks: PASS** — repository ancestry/whitespace, shell syntax,
  Python tools, signing-key helper, RD03v2 config/manifest and private-key guard.
- **PREPARE_ONLY: PASS** — pinned sources/feeds, defconfig and exact QSDK
  source preflight.
- **ECM preflight: PASS** — the SHA-256-checked QSDK source accepts patch 9002
  with the real `patch -f -p1` operation, both on the pristine source and after
  the complete sorted queue of 32 ECM feed patches. Lifecycle ordering,
  worker drain and atomic callback guards pass.
- PREPARE_ONLY artifact `14181217573` confirms the RD03v2
  `qualcommax/ipq50xx` target and expected mwan3/NSS package selections.
  Three unrelated Kconfig recursive-dependency diagnostics remain for
  Qt5 GUI, fwknopd/LuCI fwknopd and squeezelite-custom; all three packages are
  unset in final `.config`. The selected NSS cycle is absent after patch 0014.
- The userspace `conntrack` CLI is not selected; selective mark-aware cleanup
  is not implemented.
- **Run #124 full build: COMPLETED; final verify-v2: FAIL.** qca-nss-ecm compiled; both images were created; FIB notifier marker found in ecm.ko; rootfs count 223 packages. Three verifier failures were recorded (watchdog suite 20 passed / 26 failed; ECM 9001/9002 source fingerprints false-negative after AUTOREMOVE). See artifact `14184373198` and the post-build audit below.
- CI uses a temporary P-256 key and `example.invalid`, and uploads
  logs/configuration only. CI artifacts are not user-installable releases.
- Dual-WAN/NSS hardware validation remains **NOT TESTED**; the primary home
  router remains on stock MiWiFi.

Report these stages separately. PREPARE_ONLY and a successful patch preflight
are not a full firmware build, final image verification or hardware test.

## Follow-up audit — 2026-11-16, after run #124

The full build did complete image generation. The workflow conclusion is FAIL only at the final verifier stage; do not describe this as an ECM compiler failure.

Evidence from run [#124](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43762944141), build-log artifact 14184373198:

- qca-nss-ecm compile log completed successfully; the image contains kmod-qca-nss-ecm.
- Both sysupgrade and initramfs-factory images were created.
- The rootfs has 223 packages. The final verifier found the FIB notifier marker in the image's ecm.ko.
- The final verifier recorded three failures: watchdog scenario test (20 passed / 26 failed) and the source fingerprints for ECM patches 9001 and 9002.
- The watchdog failure is explained by BusyBox applet dispatch bypassing PATH stubs: dmesg, rmmod, modprobe and reboot could hit host applets instead of the fake-board commands. The watchdog test-only command wrapper was added in commit f372d519; the harness now passes WD_TEST_STUB_DIR in commit 0d2aeadb. These fixes have not yet received a completed CI run.
- The ECM fingerprint failure is explained by CONFIG_AUTOREMOVE=y: OpenWrt left the package build-directory name but removed ecm_db/ecm_db.c. Commit e7846a1 changed the verifier to inspect patched source only when it exists, otherwise compare the exact patch copies in the prepared feed. Commit e398b3f requested another full build to exercise that path.
- The prepared config artifact confirms CONFIG_AUTOREMOVE=y. Commit 49d3579 adds an explicit verifier check for that setting before accepting the feed-copy fallback.

Current branch HEAD is 49d3579437389e2ffc111b94a08839ef7bd29ae7. The attempted runs #127–#129 were cancelled; #126 was a whitespace-only static failure caused by a trailing blank line in the handoff and was corrected by commit e31ca88. A live Actions lookup by HEAD 49d3579 currently returns no associated workflow run and no commit status, so the new verifier guard and watchdog stub fixes remain NOT CI-VALIDATED.

Next required action: trigger a fresh CI run through an Actions-enabled push or workflow dispatch, then verify that static checks, PREPARE_ONLY, the watchdog suite and final verify-v2 all pass on the exact new HEAD. Rebuild is still needed because #124 predates the final fixes. Inspect the build artifact and all test summaries. Do not flash CI artifacts: they use a disposable signing key and example.invalid package repository.

Dual-WAN/NSS hardware validation remains NOT TESTED; keep the primary router on stock MiWiFi.

### ECM patch-application fuzz note — 2026-11-16

The real #124 qca-nss-ecm compile log shows GNU patch applied parts of 9002 with fuzz: ecm_db/ecm_db.c hunks #1/#2/#4 at fuzz 1/1/2, and ecm_init.c hunks #2/#4 at fuzz 1/2. In particular, the ecm_init.c hunk #4 is the ecm_exit() teardown insertion. Do not describe the actual application as fuzz-free.

This does not show that the insertion landed incorrectly: PREPARE_ONLY's test-ecm-fib-rule-patch.sh reproduces the real sorted feed patch queue using patch -f -p1, then parses both the pristine-patch result and the full-series result. Its lifecycle guard requires exactly one ecm_db_fib_rule_notifier_stop() inside ecm_exit(), immediately followed by DEBUG_INFO("stop conntrack notifier\n"), and requires the stop before conntrack/frontend teardown. CI #124's PREPARE_ONLY job and lifecycle guards passed. The exact package build used the same pinned source and patch order.

Residual status: the patch's build-time placement is source-guarded, but module load/unload and runtime teardown stress remain NOT TESTED on hardware. The compiler also emitted non-fatal warnings for an unused init_cleanup_1 label and missing MODULE_DESCRIPTION(); they did not prevent linking ecm.ko.
