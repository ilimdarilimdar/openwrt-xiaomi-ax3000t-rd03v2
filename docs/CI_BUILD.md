# RD03v2 GitHub Actions validation

This workflow separates cheap source/configuration checks from a full signed firmware build.

## Automatic static checks

A push to `work/rd03v2-dualwan-mwan3-baseline` and a pull request targeting `main` run:

- `git diff --check` and branch ancestry check;
- Bash syntax checks for shell scripts;
- Python bytecode compilation for `tools/`;
- RD03v2 target, NSS profile, mwan3 package and image manifest assertions;
- check that no `private-key.pem` is tracked.

These checks do **not** compile OpenWrt, do not validate downloaded feeds, do not build ECM, and do not prove that an image boots.

## Automatic PREPARE_ONLY job

After static checks pass, GitHub Actions runs the normal project `build.sh` with `PREPARE_ONLY=1` on an Ubuntu runner. This stage:

- fetches the exact commits pinned in `upstream.lock` and `feeds.lock`;
- applies the repository tree patches and overlay;
- installs the pinned feeds and the feed overlay;
- runs `make defconfig` and verifies requested symbols;
- writes `.config` and `diffconfig.txt`;
- stops before package compilation, image compilation and signing.

The preparation stage does not require the private signing key. The project build script skips signing-key validation and installation only for `PREPARE_ONLY=1`; all full builds still require the matching private key. A green preparation job is **not** a full firmware build.

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
