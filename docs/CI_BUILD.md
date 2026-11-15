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
_Last live GitHub Actions check: 2026-11-15 14:00 UTC._

- Working branch: `work/rd03v2-dualwan-mwan3-baseline`.
- Last checked code/patch HEAD before this docs refresh: `d7be58a9e306a7fc565163c5104257f348163a12`. Functional patch update `eada97d` adds an RCU/network grace-period barrier; `d7be58a` recalculates hunk counts/diffstat. Preflight update `c3261c7` checks the new ordering.
- Patch 9002 retains the atomic nesting fix for the original QSDK plain 0/1 `stop_temp()` flags: `atomic_inc()`, `atomic_dec_if_positive()`, and `atomic_read()` at all six IPv4/IPv6 packet-hook checks.
- The FIB worker now closes all affected front-end gates, releases `init_net`'s per-net RTNL lock, calls `synchronize_net()` once, then defuncts the selected family connections and releases its gates. This drains pre-existing Netfilter hook readers before the ECM DB walk. It does not add a global mutex around unrelated route/interface notifier DB walks or preserve conntrack/NAT sessions.

### Workflow results

- Workflow #77, [run 43708414463](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43708414463), tested source `ac4ee43c79879c8bb557a26c252eb442aa5a3654`. Static/PREPARE_ONLY passed; full build failed at `package/feeds/nss/qca-nss-ecm`. The old artifact omitted package-specific logs, so the real compiler diagnostic was not captured. Cause remains **UNKNOWN**.
- Workflow #78, [run 43709621665](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43709621665), tests lifecycle revision `36149940c8eb00df46d14b7bb10e747ec9666f3b`. Static and PREPARE_ONLY/lifecycle preflight passed; Full build remains **IN_PROGRESS** at last live check. This SHA does not include per-net RTNL, atomic stop counters or the new `synchronize_net()` barrier.
- Workflow #82 (`70f92cc`), #83 (`8ce56c7`), #84 (`2fba10a`), #85 (`bd9867c`), #86 (`6f54049`), #87 (`eada97d`) and #88 (`c3261c7`) were **CANCELLED** by later pushes before their validation jobs finished.
- Workflow #89, [run 43721964323](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43721964323), targets commit `d7be58a`. At last check it was **PENDING** behind #78 due to branch-level serialization. Its commit message does not include `[full-build]`, so it is expected to run Static + PREPARE_ONLY/preflight, not the full image build.

The workflow uploads package-specific NSS logs under `openwrt-v2/logs/package/feeds/nss/**`, matching the pinned OpenWrt `include/subdir.mk` layout when `BUILD_LOG=1`.

### Source-level findings

- Linux v6.18 FIB rule changes use the matching per-net RTNL lock; worker pending-bit snapshots are taken under `rtnl_net_lock(&init_net)`, then RTNL is released before waiting or walking ECM DB.
- The exact pinned QSDK 14.0 baseline implements frontend `stop_temp()` as plain flag assignment. Patch 9002 converts those shared flags to atomic nesting counters so concurrent route notifier, interface notifier and FIB worker callers cannot prematurely clear each other's stop state.
- Linux v6.18 `nf_hook()` holds `rcu_read_lock()` across the complete hook chain ([source](https://github.com/torvalds/linux/blob/v6.18/include/linux/netfilter.h#L227-L277)). `synchronize_net()` waits for pre-existing network RCU readers ([implementation](https://github.com/torvalds/linux/blob/v6.18/net/core/dev.c#L12108-L12121)). Patch 9002 raises every affected stop gate before this grace period and runs the DB defunct pass only afterwards. Preflight checks this ordering on raw pinned source and after the complete ECM feed patch series.
- These source/API and prepare-time assertions do not prove successful ECM compilation, module load safety, NSS offload behavior or Dual-WAN correctness.
- FIB notifier registration replays existing rules as ADD events. Loading/reloading ECM can therefore trigger a broad family-wide defunct/re-acceleration pass; this is not session preservation across WAN address changes.

### Required gates still open

1. CI #89 successful Static + PREPARE_ONLY, including pinned QSDK hash, full feed-series apply and the new hook-quiescence ordering assertions.
2. A separate successful full build of that exact functional patch revision, including `qca-nss-ecm` compilation.
3. Confirmation that the built `ecm.ko` contains the expected notifier marker.
4. Successful final `verify-v2.sh` against the generated root filesystem/image.
5. Controlled second-router tests: overlapping route/interface/FIB stop events, Netfilter hook drain, module load/unload, FIB rule churn, mwan3 restart and cable-pull failover; IPv4/IPv6 separately; NSS/ECM counters, throughput, CPU, latency and packet loss.
6. No primary-router flashing until source, full build/image and second-router hardware gates pass.

CI full-build jobs use a disposable signing key and an `example.invalid` repository URL. They upload logs only and do not publish a usable release image. Hardware validation remains **NOT TESTED**; keep the primary router on stock firmware.
