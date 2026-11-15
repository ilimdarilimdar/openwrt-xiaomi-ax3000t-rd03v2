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

This is a targeted hypothesis, not yet a proven fix. The next PREPARE_ONLY artifact must be inspected to verify that the NSS recursive dependency disappears. The other optional-package diagnostics should also be rechecked, but those packages were absent from the prior final `.config`.

## Current validation snapshot

Snapshot checked 2026-11-15 around 07:40 UTC; refresh GitHub before relying on it:

- Workflow #15 (commit `c5a64af9a23996401eb22c2a275023c419bbe547`): static checks PASS and PREPARE_ONLY PASS. Its artifact `rd03v2-prepare-c5a64af9a23996401eb22c2a275023c419bbe547` was downloaded and inspected.
- That #15 `defconfig.log` confirms the NSS recursive dependency cycle: `luci-app-nss -> kmod-qca-nss-drv -> kmod-qca-dsa-nss -> nss-tools-dwmac -> nss-tools -> luci-app-nss`. It also reports optional Qt5, fwknopd and squeezelite diagnostics. The NSS loop is the one relevant to selected RD03v2 packages.
- The #15 source commit predates `tree-patches/0014-luci-app-nss-use-ipq50xx-runtime-dependency-only.patch`; therefore #15 does **not** validate that patch. It also predates the cleanup that removed duplicate local 256 MiB choice symbols. Its warnings must not be reported as the current branch's final state.
- Workflow #16 (commit `5bcad81cfe911b91f4ac928e53f424e1580ddfd7`): Static PASS; full build job remained IN PROGRESS at the last API check. The active step is `Build and run verify-v2`; logs/artifacts are not available until the job finishes. Do not cancel this job just because it is long: the configured timeout is 360 minutes.
- Workflow #29 (source commit `f5e828f`) and later queued documentation runs were cancelled by newer pushes before a confirmed result for the current PREPARE_ONLY was obtained.
- Workflow #35 (commit `472ed0ce1b2f2fa68c78f362edfc5b5f388bc7c7`) is queued behind #16. It should exercise the corrected static check and run PREPARE_ONLY for the current source tree once the serialized slot is free.
- A static-check path typo was found and fixed: the workflow now references the exact patch filename `0014-luci-app-nss-use-ipq50xx-runtime-dependency-only.patch`. Before the fix it referenced a nonexistent shorter filename.
- Documentation-only changes are now excluded with `paths-ignore`; mixed code/config/docs changes still trigger validation. This avoids burning the serialized build slot on README/manual edits.
- The full-build CI job uses a disposable key and `example.invalid`; it is not a user-installable release. No result in this snapshot establishes hardware validation of Dual-WAN/NSS.

