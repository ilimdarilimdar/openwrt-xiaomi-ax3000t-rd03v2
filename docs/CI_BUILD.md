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
- Workflow [#107](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43729849069), test-only commit `eba9d02`: Static **PASS**, PREPARE_ONLY **PASS**, atomic callback regression guard **PASS**. The full signed-image build and `verify-v2.sh` job are **IN PROGRESS** at the latest live check.
- Workflow [#108](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43729952928), test-only commit `a0e72ce`: **PENDING** behind #107. It tightens the callback assertion to require only `set_bit()` operations and `schedule_work()`; it does not introduce a new firmware-source revision.
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
