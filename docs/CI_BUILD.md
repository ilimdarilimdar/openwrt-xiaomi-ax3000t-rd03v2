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

This is a targeted hypothesis, not yet a proven fix. The next PREPARE_ONLY artifact must be inspected to verify that the NSS recursive dependency disappears. The other optional-package diagnostics should also be rechecked, but those packages were absent from the prior final `.config`.

## Current validation snapshot

Snapshot refreshed 2026-11-15 around 08:10 UTC; re-check the live workflow before relying on these statuses:

- Workflow #15 (commit `c5a64af9a23996401eb22c2a275023c419bbe547`): static checks PASS and PREPARE_ONLY PASS. Its artifact `rd03v2-prepare-c5a64af9a23996401eb22c2a275023c419bbe547` was downloaded and inspected.
- That #15 `defconfig.log` confirms the earlier NSS recursive dependency cycle: `luci-app-nss -> kmod-qca-nss-drv -> kmod-qca-dsa-nss -> nss-tools-dwmac -> nss-tools -> luci-app-nss`. The source commit predates patch 0014, so this artifact does not test the fix.
- Workflow #16 (commit `5bcad81cfe911b91f4ac928e53f424e1580ddfd7`): static checks PASS; full build remains IN PROGRESS at `Build and run verify-v2`. Logs and artifacts are unavailable while the job is active; timeout is 360 minutes. Do not cancel it merely because it takes time.
- Runs #43–#46 were superseded/cancelled by newer pushes before yielding a complete current-source PREPARE_ONLY result.
- Workflow #57 (commit `6878d6d16ab9858a136a6c4d224e0b53d07942cc`) is PENDING; GitHub has not started its jobs yet. It contains the current ECM candidate patch, the RTNL pending-bit snapshot order assertion, pinned-source preflight, and the full-image marker gate. Run #16 remains IN PROGRESS on the earlier commit `5bcad81cfe911b91f4ac928e53f424e1580ddfd7`, which does not contain patch 9002. Cancelled runs #43–#56 were superseded by newer pushes, not classified as source/build failures. Re-query the newest run before relying on this snapshot.
- Candidate ECM patch: `feed-overlay/nss/qca-nss-ecm/patches/9002-rd03v2-defunct-ecm-flows-on-fib-policy-rule-changes.patch`. It uses the v2 `*_stop_temp()` helpers, defers the atomic FIB callback to a workqueue, unregisters the notifier and drains work before DB teardown. It is **NOT YET APPLY-VALIDATED, NOT COMPILED, NOT HARDWARE-TESTED**.
- The candidate worker includes an RTNL publication barrier and snapshots/clears pending AF bits while RTNL is held. It releases RTNL before the ECM database walk. This ordering prevents a new rule event from being swallowed by a prior worker pass. The exact Linux 6.18 event ordering and `rtnl_net_lock()` implementation are linked in `docs/ecm-policy-routing-port.md`; preflight asserts the operation order.
- PREPARE_ONLY now runs `tools/test-ecm-fib-rule-patch.sh`: read the pinned source fields from the prepared qca-nss-ecm Makefile, download the exact archive, verify its SHA-256, apply-check/apply patch 9002, and check callback/worker/teardown assertions.
- `verify-v2.sh` checks that the final sysupgrade root filesystem contains `ecm.ko` with the runtime registration message. It also checks each ECM patch fingerprint across the whole ECM source tree when the build directory remains available.
- Patch 0014's static filename check was corrected, and Markdown/docs-only pushes are filtered out of CI. Mixed source/config/docs changes still run the full validation workflow.
- CI full-build uses a disposable signing key and `example.invalid`; even a successful run is not a user-installable release. No Dual-WAN/NSS hardware validation has been performed.

Links:
- [Actions workflow](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/workflows/rd03v2-validation.yml)
- [Run #15 — PREPARE_ONLY artifact](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43686096014)
- [Run #16 — full build](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43686188656)
- [Run #57 — current ECM pending-bit snapshot checks](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43693127906)

